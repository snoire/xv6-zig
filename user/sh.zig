const std = @import("std");
const sys = @import("usys.zig");
const lib = @import("ulib.zig");

const color = struct {
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const none = "\x1b[m";
};

const out = lib.getStdErr();

const Cmd = union(enum) {
    Exec: Exec,
    Back: Back,
    List: List,
    Pipe: Pipe,
    Redir: Redir,

    const MAXARGS = 10;
    const Exec = struct {
        argv: [MAXARGS]?[*:0]const u8,
    };

    const Back = struct {
        cmd: *Cmd,
    };

    const List = struct {
        left: *Cmd,
        right: *Cmd,
    };

    const Pipe = struct {
        left: *Cmd,
        right: *Cmd,
    };

    const Redir = struct {
        cmd: *Cmd,
        file: []const u8,
        efile: []const u8,
        mode: usize,
        fd: sys.fd_t,
    };

    fn parse(str: []u8) Cmd {
        var parser = Parser{ .buf = str };

        // TODO: other type of cmd
        var cmd = Cmd{
            .Exec = .{ .argv = .{null} ** MAXARGS },
        };

        var i: usize = 0;
        while (parser.token()) |t| : (i += 1) {
            cmd.Exec.argv[i] = t.cmd;
        }

        return cmd;
    }
};

const Parser = struct {
    buf: []u8,
    pos: usize = 0,

    const Token = union(enum) {
        sym: u8,
        cmd: [*:0]const u8,
    };

    const whitespace = " \t\r\n\x0b";
    const symbols = "<|>&;()";

    // Returns true if `char` is in `string` else false
    fn in(char: u8, string: []const u8) bool {
        return std.mem.indexOfScalar(u8, string, char) != null;
    }

    fn maybe(self: *@This(), string: []const u8) bool {
        if (self.pos < self.buf.len and in(self.buf[self.pos], string)) {
            self.buf[self.pos] = 0; // NUL-terminate the string.
            self.pos += 1;
            return true;
        }
        return false;
    }

    // Returns a token or null if there is no valid token
    pub fn token(self: *@This()) ?Token {
        // skip whitespace
        while (self.pos < self.buf.len) {
            if (!self.maybe(whitespace)) break;
        }

        if (self.maybe(">") and self.maybe(">"))
            return Token{ .sym = '+' };

        if (self.pos >= self.buf.len) return null;
        const ch = self.buf[self.pos];
        if (self.maybe(symbols)) {
            return Token{ .sym = ch };
        }

        const start = self.pos;
        while (self.pos < self.buf.len) : (self.pos += 1) {
            if (in(self.buf[self.pos], whitespace ++ symbols)) break;
        }

        // The string is not currently null-terminated, although we cast it
        // to `[*:0]const u8`. Do not use it until the whole cmd is parsed.
        return Token{ .cmd = @ptrCast([*:0]const u8, self.buf[start..self.pos]) };
    }
};

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, return_addr: ?usize) noreturn {
    @setCold(true);
    out.print(color.red ++ "PANIC: {s}!\n" ++ color.none, .{msg}) catch {};

    const first_ret_addr = return_addr orelse @returnAddress();
    var it = std.debug.StackIterator.init(first_ret_addr, null);

    try out.print("Stack Trace:\n", .{});
    while (it.next()) |ret_addr| {
        try out.print(" 0x{x}\n", .{ret_addr});
    }
    while (true) {}
}

export fn main() noreturn {
    // Ensure that three file descriptors are open.
    while (true) {
        const fd = sys.open("console", 0x002); // TODO
        if (fd >= 3) {
            _ = sys.close(fd);
            break;
        }
    }

    run() catch |e| {
        @panic(@errorName(e));
    };

    sys.exit(0);
}

fn run() !void {
    // Read and run input commands.
    var buf: [100]u8 = .{0} ** 100;
    while (true) {
        const cmd = (try getcmd(&buf)).?;
        if (cmd.len >= 3 and std.mem.eql(u8, cmd[0..3], "cd ")) {
            // Chdir must be called by the parent, not the child.
            const path = @ptrCast([*:0]u8, buf[3..cmd.len :0]);
            if (sys.chdir(path) < 0)
                try out.print("cannot cd {s}\n", .{cmd[3..]});

            continue;
        }

        if (fork() == 0) runcmd(Cmd.parse(cmd));
        _ = sys.wait(null);
    }
}

fn getcmd(buf: []u8) !?[]u8 {
    std.mem.set(u8, buf, 0);
    try out.writeAll(color.yellow ++ "$ " ++ color.none);

    var cmd = (try lib.gets(buf)) orelse return null;
    buf[cmd.len] = 0; // chop \n
    return cmd;
}

// Execute cmd.  Never returns.
fn runcmd(cmd: Cmd) noreturn {
    switch (cmd) {
        .Exec => |exec| {
            if (exec.argv[0] == null) sys.exit(0);
            const argv = @ptrCast([*:null]const ?[*:0]const u8, &exec.argv);
            _ = sys.exec(exec.argv[0].?, argv);

            try out.print("exec {?s} failed\n", .{exec.argv[0]});
        },
        else => {
            try out.print("unsupported cmd: {any}\n", .{cmd});
        },
    }

    sys.exit(0);
}

fn fork() sys.pid_t {
    const pid = sys.fork();
    if (pid == -1) @panic("fork");
    return pid;
}
