const std = @import("std");
const linux = std.os.linux;

pub const VERSION: u32 = 1;

pub const max_data = 1 << 20;
pub const max_frame = max_data + 4096;

pub const Op = enum(u16) {
    hello = 1,
    lookup,
    forget,
    getattr,
    setattr,
    opendir,
    readdir,
    releasedir,
    open,
    create,
    read,
    write,
    release,
    flush,
    fsync,
    mkdir,
    unlink,
    rmdir,
    rename,
    symlink,
    readlink,
    statfs,
    _,
};

pub const Attr = extern struct {
    ino: u64,
    size: u64,
    blocks: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atimensec: u32,
    mtimensec: u32,
    ctimensec: u32,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u32,
    blksize: u32,
    flags: u32,
};

pub const HelloReq = extern struct { version: u32 };
pub const HelloResp = extern struct { version: u32 };

pub const LookupReq = extern struct { parent: u64 };

pub const EntryResp = extern struct {
    node: u64,
    generation: u64,
    attr: Attr,
};

pub const ForgetReq = extern struct { node: u64, nlookup: u64 };

pub const GetattrReq = extern struct { node: u64 };
pub const AttrResp = extern struct { attr: Attr };

pub const valid_mode: u32 = 1 << 0;
pub const valid_uid: u32 = 1 << 1;
pub const valid_gid: u32 = 1 << 2;
pub const valid_size: u32 = 1 << 3;
pub const valid_atime: u32 = 1 << 4;
pub const valid_mtime: u32 = 1 << 5;
pub const valid_fh: u32 = 1 << 6;
pub const valid_atime_now: u32 = 1 << 7;
pub const valid_mtime_now: u32 = 1 << 8;

pub const SetattrReq = extern struct {
    node: u64,
    valid: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    atime: u64,
    mtime: u64,
    atimensec: u32,
    mtimensec: u32,
    fh: u64,
};

pub const OpendirReq = extern struct { node: u64 };
pub const OpenReq = extern struct { node: u64, flags: u32, _pad: u32 = 0 };
pub const OpenResp = extern struct { fh: u64 };

pub const ReaddirReq = extern struct { fh: u64, offset: u64, size: u32, _pad: u32 = 0 };

pub const Dirent = extern struct {
    ino: u64,
    off: u64,
    type: u32,
    namelen: u32,
};

pub const CreateReq = extern struct { parent: u64, flags: u32, mode: u32 };
pub const CreateResp = extern struct {
    node: u64,
    generation: u64,
    attr: Attr,
    fh: u64,
};

pub const ReadReq = extern struct { fh: u64, offset: u64, size: u32, _pad: u32 = 0 };
pub const WriteReq = extern struct { fh: u64, offset: u64 };
pub const WriteResp = extern struct { size: u32 };

pub const ReleaseReq = extern struct { fh: u64 };
pub const FlushReq = extern struct { fh: u64 };
pub const FsyncReq = extern struct { fh: u64, datasync: u32, _pad: u32 = 0 };

pub const MkdirReq = extern struct { parent: u64, mode: u32, _pad: u32 = 0 };
pub const UnlinkReq = extern struct { parent: u64 };
pub const RmdirReq = extern struct { parent: u64 };

pub const RenameReq = extern struct {
    parent: u64,
    newparent: u64,
    flags: u32,
    namelen: u16,
    newnamelen: u16,
};

pub const SymlinkReq = extern struct {
    parent: u64,
    namelen: u16,
    targetlen: u16,
    _pad: u32 = 0,
};

pub const ReadlinkReq = extern struct { node: u64 };
pub const StatfsReq = extern struct { node: u64 };

pub const StatfsResp = extern struct {
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    bsize: u32,
    namelen: u32,
    frsize: u32,
    _pad: u32 = 0,
};

pub const FrameHeader = extern struct {
    len: u32,
    id: u64 align(4),
    code: u16,
    _pad: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(FrameHeader) == 16);
}

pub const TransportError = error{
    ConnectionClosed,
    InputOutput,
};

pub const Transport = struct {
    rfd: i32,
    wfd: i32,

    pub fn fromSocket(fd: i32) Transport {
        return .{ .rfd = fd, .wfd = fd };
    }

    pub fn close(t: Transport) void {
        _ = linux.close(t.rfd);
        if (t.wfd != t.rfd) _ = linux.close(t.wfd);
    }

    pub fn readAll(t: Transport, buf: []u8) TransportError!void {
        var off: usize = 0;
        while (off < buf.len) {
            const rc = linux.read(t.rfd, buf[off..].ptr, buf.len - off);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.ConnectionClosed;
                    off += rc;
                },
                .INTR => continue,
                else => return error.InputOutput,
            }
        }
    }

    pub fn writeAll(t: Transport, buf: []const u8) TransportError!void {
        var off: usize = 0;
        while (off < buf.len) {
            const rc = linux.write(t.wfd, buf[off..].ptr, buf.len - off);
            switch (linux.errno(rc)) {
                .SUCCESS => off += rc,
                .INTR => continue,
                .PIPE => return error.ConnectionClosed,
                else => return error.InputOutput,
            }
        }
    }

    pub fn writevAll(t: Transport, iovs: []std.posix.iovec_const) TransportError!void {
        var i: usize = 0;
        while (i < iovs.len) {
            const rc = linux.writev(t.wfd, iovs[i..].ptr, iovs.len - i);
            var n: usize = switch (linux.errno(rc)) {
                .SUCCESS => rc,
                .INTR => continue,
                .PIPE => return error.ConnectionClosed,
                else => return error.InputOutput,
            };
            while (i < iovs.len and n >= iovs[i].len) {
                n -= iovs[i].len;
                i += 1;
            }
            if (i < iovs.len and n > 0) {
                iovs[i].base += n;
                iovs[i].len -= n;
            }
        }
    }
};

pub const Frame = struct {
    id: u64,
    code: u16,
    body: []u8,

    pub fn op(f: Frame) Op {
        return @enumFromInt(f.code);
    }

    pub fn status(f: Frame) i32 {
        return @as(i16, @bitCast(f.code));
    }

    pub fn fixed(f: Frame, comptime T: type) ?*align(1) T {
        if (f.body.len < @sizeOf(T)) return null;
        return @ptrCast(f.body.ptr);
    }

    pub fn rest(f: Frame, comptime T: type) []u8 {
        return f.body[@sizeOf(T)..];
    }
};

pub fn readFrame(t: Transport, buf: []u8) TransportError!Frame {
    var hdr: FrameHeader = undefined;
    try t.readAll(std.mem.asBytes(&hdr));
    const body_len = std.math.sub(u32, hdr.len, @sizeOf(FrameHeader) - 4) catch
        return error.InputOutput;
    if (body_len > buf.len) return error.InputOutput;
    const body = buf[0..body_len];
    try t.readAll(body);
    return .{ .id = hdr.id, .code = hdr.code, .body = body };
}

pub fn writeFrame(t: Transport, id: u64, code: u16, parts: []const []const u8) TransportError!void {
    var body_len: usize = 0;
    for (parts) |p| body_len += p.len;
    var hdr: FrameHeader = .{
        .len = @intCast(@sizeOf(FrameHeader) - 4 + body_len),
        .id = id,
        .code = code,
    };
    var iovs: [8]std.posix.iovec_const = undefined;
    iovs[0] = .{ .base = @ptrCast(std.mem.asBytes(&hdr)), .len = @sizeOf(FrameHeader) };
    var n: usize = 1;
    for (parts) |p| {
        if (p.len == 0) continue;
        iovs[n] = .{ .base = p.ptr, .len = p.len };
        n += 1;
    }
    try t.writevAll(iovs[0..n]);
}

pub fn writeRequest(t: Transport, id: u64, op: Op, parts: []const []const u8) TransportError!void {
    return writeFrame(t, id, @intFromEnum(op), parts);
}

pub fn writeReply(t: Transport, id: u64, status_val: i32, parts: []const []const u8) TransportError!void {
    const code: u16 = @bitCast(@as(i16, @intCast(status_val)));
    return writeFrame(t, id, code, parts);
}

test "frame roundtrip over socketpair" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds));
    const a = Transport.fromSocket(fds[0]);
    const b = Transport.fromSocket(fds[1]);
    defer a.close();
    defer b.close();

    const req: LookupReq = .{ .parent = 1 };
    try writeRequest(a, 42, .lookup, &.{ std.mem.asBytes(&req), "hello.txt" });

    var buf: [256]u8 = undefined;
    const f = try readFrame(b, &buf);
    try std.testing.expectEqual(@as(u64, 42), f.id);
    try std.testing.expectEqual(Op.lookup, f.op());
    const got = f.fixed(LookupReq).?;
    try std.testing.expectEqual(@as(u64, 1), got.parent);
    try std.testing.expectEqualStrings("hello.txt", f.rest(LookupReq));

    try writeReply(b, 42, -@as(i32, @intFromEnum(linux.E.NOENT)), &.{});
    const r = try readFrame(a, &buf);
    try std.testing.expectEqual(@as(u64, 42), r.id);
    try std.testing.expectEqual(-@as(i32, @intFromEnum(linux.E.NOENT)), r.status());
}
