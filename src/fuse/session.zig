const std = @import("std");
const linux = std.os.linux;
const kernel = @import("kernel.zig");

const fusermount_paths = [_][*:0]const u8{
    "/usr/bin/fusermount3",
    "/bin/fusermount3",
    "/usr/local/bin/fusermount3",
};

pub const MountError = error{
    SocketPairFailed,
    ForkFailed,
    FusermountFailed,
    NoFdReceived,
};

var got_signal: std.atomic.Value(bool) = .init(false);

fn onSignal(_: linux.SIG) callconv(.c) void {
    got_signal.store(true, .monotonic);
}

pub fn interrupted() bool {
    return got_signal.load(.monotonic);
}

pub fn installSignalHandlers() void {
    var act: linux.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.INT, &act, null);
    _ = linux.sigaction(.TERM, &act, null);
    var ign: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.PIPE, &ign, null);
}

fn execFusermount(args: []const ?[*:0]const u8, envp: []const ?[*:0]const u8) noreturn {
    for (fusermount_paths) |path| {
        var argv_buf: [16]?[*:0]const u8 = undefined;
        argv_buf[0] = path;
        for (args, 1..) |a, i| argv_buf[i] = a;
        argv_buf[args.len + 1] = null;
        _ = linux.execve(path, @ptrCast(&argv_buf), @ptrCast(envp.ptr));
    }
    linux.exit(127);
}

pub fn mount(mountpoint: [*:0]const u8) MountError!i32 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) != .SUCCESS)
        return error.SocketPairFailed;

    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return error.ForkFailed;
    }
    if (pid_rc == 0) {
        _ = linux.close(fds[0]);
        var env_buf: [32]u8 = undefined;
        const env = std.fmt.bufPrintZ(&env_buf, "_FUSE_COMMFD={d}", .{fds[1]}) catch unreachable;
        const envp = [_:null]?[*:0]const u8{ env.ptr, "PATH=/usr/bin:/bin" };
        const args = [_]?[*:0]const u8{
            "-o", "rw,nosuid,nodev,default_permissions,fsname=simplefs,subtype=simplefs",
            "--", mountpoint,
        };
        execFusermount(&args, envp[0 .. envp.len + 1]);
    }
    const pid: i32 = @intCast(pid_rc);
    _ = linux.close(fds[1]);
    defer _ = linux.close(fds[0]);

    const fuse_fd = recvFd(fds[0]);

    var status: u32 = 0;
    _ = linux.waitpid(pid, &status, 0);

    if (fuse_fd) |fd| {
        if (linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0) return fd;
        _ = linux.close(fd);
    }
    return error.FusermountFailed;
}

fn recvFd(sock: i32) ?i32 {
    var data: [1]u8 = undefined;
    var iov: [1]std.posix.iovec = .{.{ .base = &data, .len = 1 }};
    var cmsg_buf: [64]u8 align(8) = @splat(0);
    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = cmsg_buf.len,
        .flags = 0,
    };
    while (true) {
        const rc = linux.recvmsg(sock, &msg, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null;
                break;
            },
            .INTR => continue,
            else => return null,
        }
    }
    const cmsg: *align(8) linux.cmsghdr = @ptrCast(&cmsg_buf);
    if (cmsg.level != linux.SOL.SOCKET or cmsg.type != linux.SCM.RIGHTS) return null;
    if (cmsg.len < @sizeOf(linux.cmsghdr) + @sizeOf(i32)) return null;
    const fd: *align(4) i32 = @ptrCast(cmsg_buf[@sizeOf(linux.cmsghdr)..][0..4]);
    return fd.*;
}

pub fn unmount(mountpoint: [*:0]const u8) void {
    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) return;
    if (pid_rc == 0) {
        const envp = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
        const args = [_]?[*:0]const u8{ "-u", "-z", "-q", "--", mountpoint };
        execFusermount(&args, envp[0 .. envp.len + 1]);
    }
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid_rc), &status, 0);
}

pub const Request = struct {
    header: *align(1) const kernel.InHeader,
    body: []const u8,

    pub fn opcode(r: Request) kernel.Opcode {
        return @enumFromInt(r.header.opcode);
    }

    pub fn fixed(r: Request, comptime T: type) ?*align(1) const T {
        if (r.body.len < @sizeOf(T)) return null;
        return @ptrCast(r.body.ptr);
    }

    pub fn rest(r: Request, comptime T: type) []const u8 {
        return r.body[@sizeOf(T)..];
    }

    pub fn name(r: Request, comptime T: type) ?[]const u8 {
        const raw = r.rest(T);
        const end = std.mem.indexOfScalar(u8, raw, 0) orelse return null;
        return raw[0..end];
    }
};

pub const ReadResult = union(enum) {
    request: Request,
    retry,
    unmounted,
    interrupted,
    err: linux.E,
};

pub const Device = struct {
    fd: i32,

    pub fn readRequest(dev: Device, buf: []align(8) u8) ReadResult {
        const rc = linux.read(dev.fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => return if (interrupted()) .interrupted else .retry,
            .AGAIN => return .retry,
            .NODEV => return .unmounted,
            .NOENT => return .retry,
            else => |e| return .{ .err = e },
        }
        if (rc < @sizeOf(kernel.InHeader)) return .{ .err = .INVAL };
        const header: *align(8) const kernel.InHeader = @ptrCast(buf.ptr);
        if (header.len > rc) return .{ .err = .INVAL };
        return .{ .request = .{
            .header = header,
            .body = buf[@sizeOf(kernel.InHeader)..header.len],
        } };
    }

    pub fn reply(dev: Device, unique: u64, err: i32, parts: []const []const u8) void {
        var total: usize = @sizeOf(kernel.OutHeader);
        for (parts) |p| total += p.len;
        var hdr: kernel.OutHeader = .{
            .len = @intCast(total),
            .@"error" = err,
            .unique = unique,
        };
        var iov_buf: [8]std.posix.iovec_const = undefined;
        iov_buf[0] = .{ .base = @ptrCast(std.mem.asBytes(&hdr)), .len = @sizeOf(kernel.OutHeader) };
        var n: usize = 1;
        for (parts) |p| {
            if (p.len == 0) continue;
            iov_buf[n] = .{ .base = p.ptr, .len = p.len };
            n += 1;
        }
        while (true) {
            const rc = linux.writev(dev.fd, &iov_buf, n);
            if (linux.errno(rc) == .INTR) continue;
            return;
        }
    }

    pub fn close(dev: Device) void {
        _ = linux.close(dev.fd);
    }
};
