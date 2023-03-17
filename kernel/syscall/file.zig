const c = @import("../c.zig");
const xv6 = @import("../xv6.zig");
const syscall = @import("../syscall.zig");
const proc = @import("../proc.zig");

/// Fetch the nth word-sized system call argument as a file descriptor
/// and return the corresponding struct file.
fn argfile(n: u8) *c.File {
    var fd = syscall.argint(n);
    var f = proc.myproc().?.ofile[fd];

    if (fd < 0 or fd >= xv6.NOFILE or f == null)
        @panic("argfile");

    return f.?;
}

/// Allocate a file descriptor for the given file.
/// Takes over file reference from caller on success.
fn fdalloc(f: *c.File) u32 {
    var p = proc.myproc().?;

    return for (&p.ofile, 0..) |*ofile, i| {
        if (ofile.* == null) {
            ofile.* = f;
            break @intCast(u32, i);
        }
    } else @panic("fdalloc");
}

pub fn dup() callconv(.C) usize {
    var f = argfile(0);
    var fd = fdalloc(f);
    _ = f.dup();
    return fd;
}

pub fn read() callconv(.C) usize {
    var f = argfile(0);
    var p = syscall.argaddr(1);
    var n = syscall.argint(2);
    return f.read(p, n);
}

pub fn write() callconv(.C) usize {
    var f = argfile(0);
    var p = syscall.argaddr(1);
    var n = syscall.argint(2);
    return f.write(p, n);
}

pub fn close() callconv(.C) usize {
    var fd = syscall.argint(0);
    var f = argfile(0); // user pointer to struct stat
    proc.myproc().?.ofile[fd] = null;
    f.close();
    return 0;
}

pub fn fstat() callconv(.C) usize {
    var f = argfile(0);
    var st = syscall.argaddr(1);
    return f.stat(st);
}
