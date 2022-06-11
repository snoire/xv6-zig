const std = @import("std");
const sys = @import("usys.zig");
const fprint = @import("print.zig").fprint;

export fn main(argc: c_int, argv: [*]?[*:0]u8) noreturn {
    if (argc < 2) {
        fprint(2, "Usage: sleep <secs>\n", .{});
        sys.exit(1);
    }

    _ = sys.sleep(std.fmt.parseInt(u8, std.mem.sliceTo(argv[1].?, 0), 0) catch |err| {
        fprint(2, "{s}\n", .{@errorName(err)});
        sys.exit(1);
    });

    sys.exit(0);
}
