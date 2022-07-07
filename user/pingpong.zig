const std = @import("std");
const sys = @import("usys.zig");
const lib = @import("ulib.zig");

const print = lib.print;
const fprint = lib.fprint;

//        read                                write
//       <----- parent_fd[0] -- parent_fd[1] <------
// child                                             parent
//       ------> child_fd[1] -- child_fd[0]  ------->
//        write                                read

export fn main() noreturn {
    var buf: [7:0]u8 = undefined;
    var parent_fd: [2]c_int = undefined;
    var child_fd: [2]c_int = undefined;

    _ = sys.pipe(&parent_fd);
    _ = sys.pipe(&child_fd);

    const pid = sys.fork();
    switch (pid) {
        -1 => fprint(2, "failed to fork\n", .{}),
        0 => { // child process
            _ = sys.close(parent_fd[1]); // close the write end of the parent pipe
            _ = sys.close(child_fd[0]); // close the read end of the child pipe

            const nbytes = blk: {
                const n = sys.read(parent_fd[0], &buf, buf.len);
                if (n < 0) sys.exit(0);
                break :blk @intCast(usize, n);
            };
            print("{}: received {s}\n", .{ sys.getpid(), buf[0..nbytes] });
            _ = sys.write(child_fd[1], "pong", 5);
        },
        else => { // parent process
            _ = sys.close(parent_fd[0]);
            _ = sys.close(child_fd[1]);

            _ = sys.write(parent_fd[1], "ping", 5);
            const nbytes = blk: {
                const n = sys.read(child_fd[0], &buf, buf.len);
                if (n < 0) sys.exit(0);
                break :blk @intCast(usize, n);
            };
            _ = sys.read(child_fd[0], &buf, buf.len);
            print("{}: received {s}\n", .{ sys.getpid(), buf[0..nbytes] });
        },
    }

    sys.exit(0);
}
