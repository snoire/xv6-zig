const std = @import("std");
const c = @import("../c.zig");
const xv6 = @import("../xv6.zig");
const syscall = @import("../syscall.zig");
const proc = @import("../proc.zig");
const execv = @import("exec.zig").exec;
const Proc = proc.Proc;

/// Fetch the uint64 at addr from the current process.
fn fetchAddr(addr: usize) usize {
    var p: *Proc = Proc.myproc().?;
    if (addr >= p.sz or addr + @sizeOf(usize) > p.sz) {
        @panic("fetchAddr");
    }

    var ip: usize = undefined;
    _ = p.pagetable.copyin(@ptrCast([*]u8, &ip), .{ .addr = addr }, @sizeOf(usize));
    return ip;
}

/// Fetch the nul-terminated string at addr from the current process.
/// Returns length of string, not including nul, or -1 for error.
fn fetchStr(addr: usize, buf: []u8) [:0]const u8 {
    var p: *Proc = Proc.myproc().?;
    return p.pagetable.copyinstr(buf, .{ .addr = addr }) catch unreachable;
}

/// Fetch the nth word-sized system call argument as a null-terminated string.
/// Copies into buf, at most max.
/// Returns string length if OK (including nul), panic if error.
fn argstr(n: u8, buf: []u8) [:0]const u8 {
    var addr = syscall.argaddr(n);
    return fetchStr(addr, buf);
}

/// Fetch the nth word-sized system call argument as a file descriptor
/// and return the corresponding struct file.
fn argfile(n: u8) *c.File {
    var fd = syscall.argint(n);
    var f = Proc.myproc().?.ofile[fd];

    if (fd < 0 or fd >= xv6.NOFILE or f == null)
        @panic("argfile");

    return f.?;
}

/// Allocate a file descriptor for the given file.
/// Takes over file reference from caller on success.
fn fdalloc(f: *c.File) u32 {
    var p = Proc.myproc().?;

    return for (&p.ofile, 0..) |*ofile, i| {
        if (ofile.* == null) {
            ofile.* = f;
            break @intCast(u32, i);
        }
    } else @panic("fdalloc");
}

pub fn dup() callconv(.C) isize {
    var f = argfile(0);
    var fd = fdalloc(f);
    _ = f.dup();
    return fd;
}

pub fn read() callconv(.C) isize {
    var f = argfile(0);
    var p = syscall.argaddr(1);
    var n = syscall.argint(2);
    return @intCast(isize, f.read(p, n));
}

pub fn write() callconv(.C) isize {
    var f = argfile(0);
    var p = syscall.argaddr(1);
    var n = syscall.argint(2);
    return @intCast(isize, f.write(p, n));
}

pub fn close() callconv(.C) isize {
    var fd = syscall.argint(0);
    var f = argfile(0); // user pointer to struct stat
    Proc.myproc().?.ofile[fd] = null;
    f.close();
    return 0;
}

pub fn fstat() callconv(.C) isize {
    var f = argfile(0);
    var st = syscall.argaddr(1);
    return @intCast(isize, f.stat(st));
}

/// Create the path new as a link to the same inode as old.
pub fn link() callconv(.C) isize {
    var old_buf: [xv6.MAXPATH]u8 = undefined;
    var new_buf: [xv6.MAXPATH]u8 = undefined;

    var old = argstr(0, &old_buf);
    var new = argstr(1, &new_buf);

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

pub fn unlink() callconv(.C) isize {
    var path_buf: [xv6.MAXPATH]u8 = undefined;
    var path = argstr(0, &path_buf);

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

pub fn open() callconv(.C) isize {
    var path_buf: [xv6.MAXPATH]u8 = undefined;
    var path = argstr(0, &path_buf);

    var omode = syscall.argint(1);

    c.begin_op();
    defer c.end_op();

    var ip: *c.Inode = undefined;
    if (omode & O.CREATE != 0) {
        ip = create(path, .file, 0, 0).?;
    } else {
        ip = c.namei(path) orelse {
            return -1;
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

pub fn mkdir() callconv(.C) isize {
    c.begin_op();
    defer c.end_op();

    var path_buf: [xv6.MAXPATH]u8 = undefined;
    var path = argstr(0, &path_buf);

    var ip = create(path, .dir, 0, 0).?;
    ip.unlockput();
    return 0;
}

pub fn mknod() callconv(.C) isize {
    c.begin_op();
    defer c.end_op();

    var path_buf: [xv6.MAXPATH]u8 = undefined;
    var path = argstr(0, &path_buf);

    var major = @intCast(c_short, syscall.argint(1));
    var minor = @intCast(c_short, syscall.argint(2));

    var ip = create(path, .device, major, minor).?;
    ip.unlockput();
    return 0;
}

pub fn chdir() callconv(.C) isize {
    var p = Proc.myproc().?;

    c.begin_op();

    var path_buf: [xv6.MAXPATH]u8 = undefined;
    var path = argstr(0, &path_buf);

    var ip = c.namei(path).?;
    ip.ilock();

    if (ip.type != .dir) @panic("chdir");
    ip.unlock();
    p.cwd.?.put();
    c.end_op();

    p.cwd = ip;
    return 0;
}

pub fn exec() callconv(.C) isize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var path_buf: [xv6.MAXPATH]u8 = undefined;
    var path = argstr(0, &path_buf);

    var uargv = syscall.argaddr(1);

    var argv: [xv6.MAXARG - 1:null]?[*:0]u8 = .{null} ** xv6.MAXARG;

    for (0..xv6.MAXARG) |i| {
        var uarg = fetchAddr(uargv + i * @sizeOf(usize));
        if (uarg == 0) break;

        argv[i] = @constCast(fetchStr(
            uarg,
            allocator.create([128]u8) catch unreachable,
        ));
    }

    return execv(path, &argv) catch |err| @panic(@errorName(err));
}

pub fn pipe() callconv(.C) isize {
    var rf: *c.File = undefined;
    var wf: *c.File = undefined;
    if (c.Pipe.alloc(&rf, &wf) < 0) @panic("pipe alloc");

    var fd0 = fdalloc(rf);
    if (fd0 < 0) @panic("fd0 < 0");

    var fd1 = fdalloc(wf);
    if (fd1 < 0) @panic("fd1 < 0");

    var p = Proc.myproc().?;
    var fdarray = syscall.argaddr(0);

    var ret = p.pagetable.copyout(
        .{ .addr = fdarray },
        @ptrCast([*]u8, &fd0),
        @sizeOf(@TypeOf(fd0)),
    );
    if (ret < 0) @panic("copyout");

    ret = p.pagetable.copyout(
        .{ .addr = fdarray + @sizeOf(@TypeOf(fd0)) },
        @ptrCast([*]u8, &fd1),
        @sizeOf(@TypeOf(fd1)),
    );
    if (ret < 0) @panic("copyout");

    return 0;
}
