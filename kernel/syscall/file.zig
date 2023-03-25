const std = @import("std");
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

    var name: [c.Dirent.DIRSIZ]u8 = undefined;
    var dp = c.nameiparent(new, &name).?;
    dp.ilock();

    if (dp.dev != ip.dev) @panic("dp.dev != ip.dev");
    if (dp.dirlink(&name, ip.inum) < 0) @panic("dirlink");

    dp.unlockput();
    ip.put();

    return 0;
}

/// Is the directory dp empty except for "." and ".." ?
fn isdirempty(dp: *c.Inode) bool {
    var de: c.Dirent = undefined;
    var off: usize = 2 * @sizeOf(c.Dirent); // skip "." and ".."

    while (off < dp.size) : (off += @sizeOf(c.Dirent)) {
        var nbytes = dp.read(false, @ptrToInt(&de), @intCast(u32, off), @sizeOf(c.Dirent));
        if (nbytes != @sizeOf(c.Dirent)) @panic("isdirempty: readi");
        if (de.inum != 0) return false;
    } else {
        return true;
    }
}

pub fn unlink() callconv(.C) usize {
    var path_buf: [xv6.MAXPATH]u8 = undefined;
    var path = syscall.argstr(0, &path_buf);

    c.begin_op();
    defer c.end_op();

    var name: [c.Dirent.DIRSIZ]u8 = undefined;
    var dp = c.nameiparent(path, &name).?;
    dp.ilock();

    if (std.mem.eql(u8, &name, ".") or std.mem.eql(u8, &name, "..")) {
        @panic("Cannot unlink `.` or `..`");
    }

    var off: u32 = undefined;
    var ip = dp.dirlookup(&name, &off).?;
    ip.ilock();

    if (ip.nlink < 1) {
        @panic("unlink: nlink < 1");
    }

    if (ip.type == .dir and !isdirempty(ip)) {
        @panic("ip.type == .dir and !isdirempty(ip)");
    }

    var de = std.mem.zeroes(c.Dirent);
    var nbytes = dp.write(false, @ptrToInt(&de), off, @sizeOf(c.Dirent));

    if (nbytes != @sizeOf(c.Dirent)) {
        @panic("unlink: writei");
    }

    if (ip.type == .dir) {
        dp.nlink -= 1;
        dp.update();
    }
    dp.unlockput();

    ip.nlink -= 1;
    ip.update();
    ip.unlockput();

    return 0;
}

fn create(path: [*:0]const u8, file_type: c.Stat.Type, major: c_short, minor: c_short) ?*c.Inode {
    var name: [c.Dirent.DIRSIZ]u8 = undefined;
    var dp = c.nameiparent(path, &name).?;
    dp.ilock();

    var inode = dp.dirlookup(&name, null);
    if (inode) |ip| {
        dp.unlockput();
        ip.ilock();

        if (file_type == .file and (ip.type == .file or ip.type == .device)) {
            return ip;
        }
        ip.unlockput();
        return null;
    }

    var ip = c.Inode.alloc(dp.dev, file_type).?;
    ip.ilock();
    ip.major = major;
    ip.minor = minor;
    ip.nlink = 1;
    ip.update();

    if (file_type == .dir) {
        if (ip.dirlink(".", ip.inum) < 0) @panic("dirlink");
        if (ip.dirlink("..", dp.inum) < 0) @panic("dirlink");
    }

    if (dp.dirlink(&name, ip.inum) < 0) @panic("dirlink");

    if (file_type == .dir) {
        dp.nlink += 1;
        dp.update();
    }

    dp.unlockput();
    return ip;
}

const O = struct {
    const RDONLY = 0x000;
    const WRONLY = 0x001;
    const RDWR = 0x002;
    const CREATE = 0x200;
    const TRUNC = 0x400;
};

pub fn open() callconv(.C) usize {
    var path_buf: [xv6.MAXPATH]u8 = undefined;
    var path = syscall.argstr(0, &path_buf);

    var omode = syscall.argint(1);

    c.begin_op();
    defer c.end_op();

    var ip: *c.Inode = undefined;
    if (omode & O.CREATE != 0) {
        ip = create(path, .file, 0, 0).?;
    } else {
        ip = c.namei(path) orelse {
            return @truncate(usize, -1);
        };
        ip.ilock();

        if (ip.type == .dir and omode != O.RDONLY) {
            @panic("ip.type == .dir and omode != O.RDONLY");
        }
    }

    if (ip.type == .device and (ip.major < 0 or ip.major >= xv6.NDEV)) {
        @panic("ip.type == .device and (ip.major < 0 or ip.major >= xv6.NDEV)");
    }

    var f = c.File.alloc().?;
    var fd = fdalloc(f);

    if (ip.type == .device) {
        f.type = .device;
        f.major = ip.major;
    } else {
        f.type = .inode;
        f.off = 0;
    }

    f.ip = ip;
    f.readable = @boolToInt(!(omode & O.WRONLY != 0));
    f.writable = @boolToInt((omode & O.WRONLY != 0) or (omode & O.RDWR != 0));

    if ((omode & O.TRUNC != 0) and ip.type == .file) {
        ip.trunc();
    }

    ip.unlock();
    return fd;
}

pub fn mkdir() callconv(.C) usize {
    c.begin_op();
    defer c.end_op();

    var path_buf: [xv6.MAXPATH]u8 = undefined;
    var path = syscall.argstr(0, &path_buf);

    var ip = create(path, .dir, 0, 0).?;
    ip.unlockput();
    return 0;
}

pub fn mknod() callconv(.C) usize {
    c.begin_op();
    defer c.end_op();

    var path_buf: [xv6.MAXPATH]u8 = undefined;
    var path = syscall.argstr(0, &path_buf);

    var major = @intCast(c_short, syscall.argint(1));
    var minor = @intCast(c_short, syscall.argint(2));

    var ip = create(path, .device, major, minor).?;
    ip.unlockput();
    return 0;
}

pub fn chdir() callconv(.C) usize {
    var p = proc.myproc().?;

    c.begin_op();

    var path_buf: [xv6.MAXPATH]u8 = undefined;
    var path = syscall.argstr(0, &path_buf);

    var ip = c.namei(path).?;
    ip.ilock();

    if (ip.type != .dir) @panic("chdir");
    ip.unlock();
    p.cwd.?.put();
    c.end_op();

    p.cwd = ip;
    return 0;
}
