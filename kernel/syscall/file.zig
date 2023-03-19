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

/// Create the path new as a link to the same inode as old.
pub fn link() callconv(.C) usize {
    var name: [c.Dirent.DIRSIZ]u8 = undefined;
    var old_buf: [xv6.MAXPATH]u8 = undefined;
    var new_buf: [xv6.MAXPATH]u8 = undefined;

    var old = syscall.argstr(0, &old_buf);
    var new = syscall.argstr(1, &new_buf);

    c.begin_op();
    defer c.end_op();

    var ip = c.namei(old).?;
    ip.ilock();

    if (ip.type == .dir) @panic("create the link of dir?");
    ip.nlink += 1;
    ip.update();
    ip.unlock();

    var dp = c.nameiparent(new, &name).?;
    dp.ilock();

    if (dp.dev != ip.dev) @panic("dp.dev != ip.dev");
    if (dp.dirlink(&name, ip.inum) < 0) @panic("dirlink");

    dp.unlockput();
    ip.put();

    return 0;
}
