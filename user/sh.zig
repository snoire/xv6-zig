const std = @import("std");
const kernel = @import("kernel");
const sys = @import("usys.zig");
const lib = @import("ulib.zig");
const Ast = @import("shell/Ast.zig");
const print = lib.print;

const O = kernel.O;
const MAXARG = kernel.MAXARG;
const PIPESIZE = kernel.c.Pipe.SIZE;

const color = struct {
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const none = "\x1b[m";
};

var arena_allocator = std.heap.ArenaAllocator.init(lib.heap.raw_c_allocator);
const allocator = arena_allocator.allocator();

export fn main() noreturn {
    // Ensure that three file descriptors are open.
    while (true) {
        const fd = sys.open("console", 0x002); // TODO
        if (fd >= 3) {
            _ = sys.close(fd);
            break;
        }
    }

    // Read and run input commands.
    while (true) {
        run() catch |err| @panic(@errorName(err));
    }
}

fn run() !void {
    _ = arena_allocator.reset(.retain_capacity);

    const cmd = try getcmd();
    var tree = try Ast.parse(allocator, cmd) orelse return;
    defer tree.deinit(allocator);

    if (tree.error_token != null) {
        parseError(tree);
        return;
    }

    runcmd(tree, 0) catch |err| switch (err) {
        error.Overflow => print("sh: too many args\n", .{}),
        else => return err,
    };
}

fn getcmd() ![:0]u8 {
    print(color.yellow ++ "$ " ++ color.none, .{});

    var buf = try allocator.alloc(u8, 256);
    const cmd = try lib.gets(buf) orelse unreachable;
    buf[cmd.len] = 0; // chop \n
    return buf[0..cmd.len :0];
}

fn runcmd(ast: Ast, index: Ast.Node.Index) !void {
    const node = ast.nodes.get(index);
    switch (node.tag) {
        .list => {
            const cmds = ast.extra_data[node.data.lhs..node.data.rhs];
            for (cmds) |cmd| {
                switch (ast.nodes.get(cmd).tag) {
                    .builtin, .list => try runcmd(ast, cmd),
                    .exec, .pipe, .redir, .redir_pipe, .back => {
                        if (fork() == 0) try runcmd(ast, cmd);
                        _ = sys.wait(null);
                    },
                    else => unreachable,
                }
            }
        },
        .pipe => {
            var p: [2]c_int = undefined;
            _ = sys.pipe(&p);

            for ([2]Ast.Node.Index{ node.data.lhs, node.data.rhs }, [2]u8{ 1, 0 }) |cmd, fd| {
                if (fork() == 0) {
                    _ = sys.close(fd);
                    _ = sys.dup(p[fd]);
                    _ = sys.close(p[0]);
                    _ = sys.close(p[1]);
                    try runcmd(ast, cmd);
                }
            }

            _ = sys.close(p[0]);
            _ = sys.close(p[1]);
            _ = sys.wait(null);
            _ = sys.wait(null);
            sys.exit(0);
        },
        .redir, .redir_pipe => {
            const extra = ast.extraData(node.data.rhs, Ast.Node.Redirection);
            const FdList = std.ArrayList(c_int);

            const stdio_pipe, const fd_list = blk: {
                var pipes: [3]?[2]c_int = undefined;
                var fds: [3]?FdList = undefined;

                for (0..3, [3]bool{
                    extra.stdin != 0,
                    extra.stdout != 0 or extra.stdout_append != 0 or node.tag == .redir_pipe,
                    extra.stderr != 0 or extra.stderr_append != 0,
                }) |i, exist| {
                    if (exist) {
                        pipes[i] = pipe: {
                            var p: [2]c_int = undefined;
                            _ = sys.pipe(&p);
                            break :pipe p;
                        };
                        fds[i] = FdList.init(allocator);
                    } else {
                        pipes[i] = null;
                        fds[i] = null;
                    }
                }

                if (node.tag == .redir_pipe) try fds[1].?.append(1);
                break :blk .{ pipes, fds };
            };

            // fork a new process to run the command
            if (fork() == 0) {
                for (stdio_pipe, 0.., [3]usize{ 0, 1, 1 }) |pipe, stdio, pipe_i| {
                    if (pipe) |p| {
                        _ = sys.close(@intCast(stdio));
                        _ = sys.dup(p[pipe_i]);
                        _ = sys.close(p[0]);
                        _ = sys.close(p[1]);
                    }
                }
                try runcmd(ast, node.data.lhs);
            }

            // open input/output files
            inline for (
                std.meta.fields(Ast.Node.Redirection),
                .{
                    O.RDONLY, // <
                    O.WRONLY | O.CREATE | O.TRUNC, // >
                    O.WRONLY | O.CREATE | O.APPEND, // >>
                    O.WRONLY | O.CREATE | O.TRUNC, // 2>
                    O.WRONLY | O.CREATE | O.APPEND, // 2>>
                },
                .{ 0, 1, 1, 2, 2 },
            ) |field, mode, i| {
                const field_index = @field(extra, field.name);
                if (field_index != 0) {
                    const field_node = ast.nodes.get(field_index);
                    const files = ast.extra_data[field_node.data.lhs..field_node.data.rhs];
                    const tokens = ast.tokens.items(.lexeme);

                    for (files) |file| {
                        const path = try allocator.dupeZ(u8, tokens[file]);
                        defer allocator.free(path);
                        try fd_list[i].?.append(sys.open(path, mode));
                    }
                }
            }

            // pipe data between child and input/output files
            {
                const buf = try allocator.alloc(u8, PIPESIZE);
                defer allocator.free(buf);

                // read from input files and write to child stdin pipe
                if (stdio_pipe[0]) |p| {
                    _ = sys.close(p[0]);
                    defer _ = sys.close(p[1]);

                    for (fd_list[0].?.items) |fd| {
                        while (true) {
                            const nbytes = sys.read(fd, buf.ptr, PIPESIZE);
                            if (nbytes <= 0) break;
                            _ = sys.write(p[1], buf.ptr, @intCast(nbytes));
                        }
                    }
                }

                // read from child stdout/stderr pipes and write to output files
                for (stdio_pipe[1..], fd_list[1..]) |pipe, list| {
                    if (pipe) |p| {
                        _ = sys.close(p[1]);
                        defer _ = sys.close(p[0]);

                        const fds = list.?.items;
                        while (true) {
                            const nbytes = sys.read(p[0], buf.ptr, PIPESIZE);
                            if (nbytes <= 0) break;

                            for (fds) |fd| {
                                _ = sys.write(fd, buf.ptr, @intCast(nbytes));
                            }
                        }
                    }
                }
            }

            _ = sys.wait(null);
            sys.exit(0);
        },
        .exec => {
            var list = std.BoundedArray(?[*:0]const u8, MAXARG){};

            const tokens = ast.tokens.items(.lexeme)[node.data.lhs..node.data.rhs];
            for (tokens) |token| {
                try list.append(try allocator.dupeZ(u8, token));
            }
            try list.append(null);

            const argv = list.slice();
            _ = sys.exec(argv[0].?, @ptrCast(argv));
            print("sh: exec {s} failed\n", .{argv[0].?});
            sys.exit(0);
        },
        .builtin => {
            // chdir must be called by the parent, not the child.
            const tokens = ast.tokens.items(.lexeme)[node.data.lhs..node.data.rhs];
            const path = try allocator.dupeZ(u8, tokens[1]);
            defer allocator.free(path);
            if (sys.chdir(path) < 0)
                print("sh: cannot cd {s}\n", .{path});
        },
        .back => {
            if (fork() == 0) try runcmd(ast, node.data.lhs);
            sys.exit(0); // Let parent exit before child.
        },
        else => unreachable,
    }
}

fn fork() sys.pid_t {
    const pid = sys.fork();
    if (pid == -1) @panic("fork");
    return pid;
}

fn parseError(tree: Ast) void {
    const error_token = tree.error_token.?;
    const position = @intFromPtr(error_token.ptr) - @intFromPtr(tree.source.ptr);
    print("{s:[2]}{s:~<[3]}\n", .{ "", "^", position + 2, error_token.len });
    print("sh: parse error near `{s}'\n", .{error_token});
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @setCold(true);
    print(color.red ++ "PANIC: {s}!\n" ++ color.none, .{msg});

    const first_ret_addr = ret_addr orelse @returnAddress();
    var it = std.debug.StackIterator.init(first_ret_addr, null);

    print("Stack Trace:\n", .{});
    while (it.next()) |addr| {
        print(" 0x{x}\n", .{addr});
    }

    @trap();
}
