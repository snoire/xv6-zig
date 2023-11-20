const std = @import("std");
const c = @import("../c.zig");
const xv6 = @import("../xv6.zig");
const syscall = @import("../syscall.zig");
const proc = @import("../proc.zig");
const execv = @import("exec.zig").exec;
const Proc = proc.Proc;
const O = xv6.O;

/// Fetch the uint64 at addr from the current process.
fn fetchAddr(addr: usize) !usize {
    const p: *Proc = Proc.myproc().?;
    if (addr >= p.sz or addr + @sizeOf(usize) > p.sz) {
        return error.overflow;
    }

    var ip: usize = undefined;
    try p.pagetable.copyin(@ptrCast(&ip), @bitCast(addr), @sizeOf(usize));
    return ip;
}

/// Fetch the nul-terminated string at addr from the current process.
/// Returns length of string, not including nul, or -1 for error.
fn fetchStr(addr: usize, buf: []u8) ![:0]const u8 {
    const p: *Proc = Proc.myproc().?;
    return p.pagetable.copyinstr(buf, @bitCast(addr));
}

/// Fetch the nth word-sized system call argument as a null-terminated string.
/// Copies into buf, at most max.
/// Returns string length if OK (including nul), panic if error.
fn argstr(n: u8, buf: []u8) ![:0]const u8 {
    const addr = syscall.argaddr(n);
    return fetchStr(addr, buf);
}

/// Fetch the nth word-sized system call argument as a file descriptor
/// and return both the descriptor and the corresponding struct file.
fn argfile(n: u8) !struct { u32, *c.File } {
    const fd = try syscall.argint(n);
    const f = Proc.myproc().?.ofile[fd];

    if (fd >= xv6.NOFILE or f == null)
        return error.argfile;

    return .{ fd, f.? };
}

/// Allocate a file descriptor for the given file.
/// Takes over file reference from caller on success.
fn fdalloc(f: *c.File) !u32 {
    const p = Proc.myproc().?;

    return for (&p.ofile, 0..) |*ofile, i| {
        if (ofile.* == null) {
            ofile.* = f;
            break @intCast(i);
        }
    } else error.fdalloc;
}

pub fn dup() !isize {
    _, const f = try argfile(0);
    const fd = try fdalloc(f);
    _ = f.dup();
    return fd;
}

pub fn read() !isize {
    _, const f = try argfile(0);
    const p = syscall.argaddr(1);
    const n = syscall.arg(2);
    return f.read(p, n);
}

pub fn write() !isize {
    _, const f = try argfile(0);
    const p = syscall.argaddr(1);
    const n = syscall.arg(2);
    return f.write(p, n);
}

pub fn close() !isize {
    const fd, const f = try argfile(0);
    Proc.myproc().?.ofile[fd] = null;
    f.close();
    return 0;
}

pub fn fstat() !isize {
    _, const f = try argfile(0);
    const st = syscall.argaddr(1); // user pointer to struct stat
    return f.stat(st);
}

/// Create the path new as a link to the same inode as old.
pub fn link() !isize {
    var old_buf: [xv6.MAXPATH]u8 = undefined;
    var new_buf: [xv6.MAXPATH]u8 = undefined;

    const old = try argstr(0, &old_buf);
    const new = try argstr(1, &new_buf);

    c.begin_op();
    defer c.end_op();

    const ip = c.namei(old) orelse return error.BadLink;
    errdefer {
        ip.ilock();
        ip.nlink -= 1;
        ip.update();
        ip.unlockput();
    }
    {
        ip.ilock();
        defer ip.unlock();

        if (ip.type == .dir) return error.BadLink;
        ip.nlink += 1;
        ip.update();
    }

    var name: [c.Dirent.DIRSIZ]u8 = undefined;
    const dp = c.nameiparent(new, &name) orelse return error.BadLink;
    {
        dp.ilock();
        defer dp.unlockput();

        if (dp.dev != ip.dev or dp.dirlink(&name, ip.inum) < 0)
            return error.BadLink;
    }

    ip.put();
    return 0;
}

/// Is the directory dp empty except for "." and ".." ?
fn isdirempty(dp: *c.Inode) bool {
    var de: c.Dirent = undefined;
    var off: usize = 2 * @sizeOf(c.Dirent); // skip "." and ".."

    while (off < dp.size) : (off += @sizeOf(c.Dirent)) {
        const nbytes = dp.read(false, @intFromPtr(&de), @intCast(off), @sizeOf(c.Dirent));
        if (nbytes != @sizeOf(c.Dirent)) @panic("isdirempty: readi");
        if (de.inum != 0) return false;
    } else {
        return true;
    }
}

pub fn unlink() !isize {
    var path_buf: [xv6.MAXPATH]u8 = undefined;
    const path = try argstr(0, &path_buf);

    c.begin_op();
    defer c.end_op();

    var name: [c.Dirent.DIRSIZ]u8 = undefined;
    const dp = c.nameiparent(path, &name) orelse return error.Unlink;

    dp.ilock();
    errdefer dp.unlockput();

    // if name.len == DIRSIZ, it's not null-terminated string.
    const dirname: []const u8 = n: {
        const end = std.mem.indexOfScalar(u8, &name, 0) orelse
            break :n name[0..name.len];
        break :n name[0..end];
    };

    // Cannot unlink "." or "..".
    if (std.mem.eql(u8, dirname, ".") or std.mem.eql(u8, dirname, "..")) {
        return error.Invalid;
    }

    var off: u32 = undefined;
    const ip = dp.dirlookup(&name, &off) orelse return error.NotFound;
    ip.ilock();
    errdefer ip.unlockput();

    if (ip.nlink < 1) {
        @panic("unlink: nlink < 1");
    }

    if (ip.type == .dir and !isdirempty(ip)) {
        return error.DirIsNotEmpty;
    }

    const de = std.mem.zeroes(c.Dirent);
    const nbytes = dp.write(false, @intFromPtr(&de), off, @sizeOf(c.Dirent));
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

fn create(path: [*:0]const u8, file_type: c.Stat.Type, major: c_short, minor: c_short) !*c.Inode {
    var name: [c.Dirent.DIRSIZ]u8 = undefined;

    const dp = c.nameiparent(path, &name) orelse return error.Create;
    dp.ilock();
    defer dp.unlockput();

    const inode = dp.dirlookup(&name, null);
    if (inode) |ip| {
        ip.ilock();
        errdefer ip.unlockput();

        if (file_type == .file and (ip.type == .file or ip.type == .device)) {
            return ip;
        }
        return error.Create;
    }

    const ip = c.Inode.alloc(dp.dev, file_type) orelse return error.Create;
    ip.ilock();
    // something went wrong. de-allocate ip.
    errdefer {
        ip.nlink = 0;
        ip.update();
        ip.unlockput();
    }

    ip.major = major;
    ip.minor = minor;
    ip.nlink = 1;
    ip.update();

    // Create . and .. entries.
    if (file_type == .dir) {
        if (ip.dirlink(".", ip.inum) < 0 or ip.dirlink("..", dp.inum) < 0)
            return error.Create;
    }

    if (dp.dirlink(&name, ip.inum) < 0)
        return error.Create;

    if (file_type == .dir) {
        dp.nlink += 1; // for ".."
        dp.update();
    }

    return ip;
}

pub fn open() !isize {
    var path_buf: [xv6.MAXPATH]u8 = undefined;
    const path = try argstr(0, &path_buf);

    const omode = try syscall.argint(1);

    c.begin_op();
    defer c.end_op();

    var ip: *c.Inode = undefined;
    if (omode & O.CREATE != 0) {
        ip = try create(path, .file, 0, 0);
    } else {
        ip = c.namei(path) orelse return -1;

        ip.ilock();
        errdefer ip.unlockput();

        if (ip.type == .dir and omode != O.RDONLY) {
            return error.Invalid;
        }
    }
    errdefer ip.unlockput();

    if (ip.type == .device and (ip.major < 0 or ip.major >= xv6.NDEV)) {
        return error.Invalid;
    }

    const f = c.File.alloc() orelse return error.Failed;
    const fd = try fdalloc(f);

    if (ip.type == .device) {
        f.type = .device;
        f.major = ip.major;
    } else {
        f.type = .inode;
        f.off = 0;
    }

    f.ip = ip;
    f.readable = @intFromBool(!(omode & O.WRONLY != 0));
    f.writable = @intFromBool((omode & O.WRONLY != 0) or (omode & O.RDWR != 0));

    if ((omode & O.TRUNC != 0) and ip.type == .file) {
        ip.trunc();
    }

    ip.unlock();
    return fd;
}

pub fn mkdir() !isize {
    c.begin_op();
    defer c.end_op();

    var path_buf: [xv6.MAXPATH]u8 = undefined;
    const path = try argstr(0, &path_buf);

    const ip = try create(path, .dir, 0, 0);
    ip.unlockput();
    return 0;
}

pub fn mknod() !isize {
    c.begin_op();
    defer c.end_op();

    var path_buf: [xv6.MAXPATH]u8 = undefined;
    const path = try argstr(0, &path_buf);

    const major: c_short = @intCast(try syscall.argint(1));
    const minor: c_short = @intCast(try syscall.argint(2));

    const ip = try create(path, .device, major, minor);
    ip.unlockput();
    return 0;
}

pub fn chdir() !isize {
    const p = Proc.myproc().?;

    c.begin_op();
    defer c.end_op();

    var path_buf: [xv6.MAXPATH]u8 = undefined;
    const path = try argstr(0, &path_buf);

    const ip = c.namei(path) orelse return error.Chdir;
    ip.ilock();
    errdefer ip.unlockput();

    if (ip.type != .dir) return error.Chdir;
    ip.unlock();
    p.cwd.?.put();

    p.cwd = ip;
    return 0;
}

pub fn exec() !isize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var list = std.BoundedArray(?[*:0]const u8, xv6.MAXARG){};
    var path_buf: [xv6.MAXPATH]u8 = undefined;
    const path = try argstr(0, &path_buf);

    const uargv = syscall.argaddr(1);

    for (0..xv6.MAXARG) |i| {
        const uarg = try fetchAddr(uargv + i * @sizeOf(usize));
        if (uarg == 0) break;

        const buf = try allocator.create([xv6.MAXPATH]u8);
        const arg = try fetchStr(uarg, buf);
        try list.append(arg);
    }

    const argv = list.slice();
    return execv(path, @ptrCast(argv));
}

pub fn pipe() !isize {
    var rf: *c.File = undefined;
    var wf: *c.File = undefined;

    if (c.Pipe.alloc(&rf, &wf) < 0) return error.pipe_alloc;
    errdefer {
        rf.close();
        wf.close();
    }

    const p = Proc.myproc().?;

    const fd0 = try fdalloc(rf);
    errdefer p.ofile[fd0] = null;
    const fd1 = try fdalloc(wf);
    errdefer p.ofile[fd1] = null;

    const fdarray = syscall.argaddr(0);
    const fd_size: usize = @sizeOf(@TypeOf(fd0, fd1));
    try p.pagetable.copyout(@bitCast(fdarray), @ptrCast(&fd0), fd_size);
    try p.pagetable.copyout(@bitCast(fdarray + fd_size), @ptrCast(&fd1), fd_size);

    return 0;
}
