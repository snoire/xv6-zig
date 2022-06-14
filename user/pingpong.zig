const std = @import("std");
const sys = @import("usys.zig");
const print = @import("print.zig").print;
const fprint = @import("print.zig").fprint;

//        read                                write
//       <----- parent_fd[0] -- parent_fd[1] <------
// child                                             parent
//       ------> child_fd[1] -- child_fd[0]  ------->
//        write                                read

export fn main(_: usize, _: [*:null]const ?[*:0]const u8) noreturn {
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

            _ = sys.read(parent_fd[0], &buf, buf.len);
            print("{}: received {s}\n", .{ sys.getpid(), &buf });
            _ = sys.write(child_fd[1], "pong", 5);
        },
        else => { // parent process
            _ = sys.close(parent_fd[0]);
            _ = sys.close(child_fd[1]);

            _ = sys.write(parent_fd[1], "ping", 5);
            _ = sys.read(child_fd[0], &buf, buf.len);
            print("{}: received {s}\n", .{ sys.getpid(), &buf });
        },
    }

    sys.exit(0);
}
