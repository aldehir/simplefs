const std = @import("std");
const linux = std.os.linux;
const proto = @import("proto.zig");

const Allocator = std.mem.Allocator;
const Transport = proto.Transport;
const Frame = proto.Frame;

const root_node: u64 = 1;

fn errnoOf(rc: usize) i32 {
    const e = linux.errno(rc);
    if (e == .SUCCESS) return 0;
    return -@as(i32, @intFromEnum(e));
}

fn errval(e: linux.E) i32 {
    return -@as(i32, @intFromEnum(e));
}

const Statfs = extern struct {
    type: i64,
    bsize: i64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    namelen: i64,
    frsize: i64,
    flags: i64,
    spare: [4]i64,
};

const Node = struct {
    fd: i32,
    dev: u64,
    ino: u64,
    nlookup: u64,
};

const InoKey = struct {
    dev: u64,
    ino: u64,
};

pub const Exporter = struct {
    gpa: Allocator,
    root_fd: i32,
    nodes: std.AutoHashMap(u64, Node),
    by_ino: std.AutoHashMap(InoKey, u64),
    next_node: u64,
    handles: std.AutoHashMap(u64, i32),
    next_fh: u64,

    pub fn init(gpa: Allocator, root_path: [:0]const u8) !Exporter {
        const rc = linux.openat(linux.AT.FDCWD, root_path, .{ .PATH = true, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.CannotOpenRoot;
        const root_fd: i32 = @intCast(rc);

        var self: Exporter = .{
            .gpa = gpa,
            .root_fd = root_fd,
            .nodes = .init(gpa),
            .by_ino = .init(gpa),
            .next_node = 2,
            .handles = .init(gpa),
            .next_fh = 1,
        };
        errdefer self.deinit();

        var stx: linux.Statx = undefined;
        if (statxFd(root_fd, &stx) != 0) return error.CannotOpenRoot;
        try self.nodes.put(root_node, .{
            .fd = root_fd,
            .dev = devOf(&stx),
            .ino = stx.ino,
            .nlookup = 1,
        });
        try self.by_ino.put(.{ .dev = devOf(&stx), .ino = stx.ino }, root_node);
        return self;
    }

    pub fn deinit(self: *Exporter) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |n| _ = linux.close(n.fd);
        var hit = self.handles.valueIterator();
        while (hit.next()) |fd| _ = linux.close(fd.*);
        self.nodes.deinit();
        self.by_ino.deinit();
        self.handles.deinit();
    }

    fn nodeFd(self: *Exporter, id: u64) ?i32 {
        const n = self.nodes.get(id) orelse return null;
        return n.fd;
    }

    fn registerNode(self: *Exporter, fd: i32, stx: *const linux.Statx) !u64 {
        const key: InoKey = .{ .dev = devOf(stx), .ino = stx.ino };
        if (self.by_ino.get(key)) |id| {
            const n = self.nodes.getPtr(id).?;
            n.nlookup += 1;
            _ = linux.close(fd);
            return id;
        }
        const id = self.next_node;
        self.next_node += 1;
        try self.nodes.put(id, .{ .fd = fd, .dev = key.dev, .ino = key.ino, .nlookup = 1 });
        try self.by_ino.put(key, id);
        return id;
    }

    fn forget(self: *Exporter, id: u64, nlookup: u64) void {
        if (id == root_node) return;
        const n = self.nodes.getPtr(id) orelse return;
        if (n.nlookup > nlookup) {
            n.nlookup -= nlookup;
            return;
        }
        _ = linux.close(n.fd);
        _ = self.by_ino.remove(.{ .dev = n.dev, .ino = n.ino });
        _ = self.nodes.remove(id);
    }

    fn addHandle(self: *Exporter, fd: i32) !u64 {
        const fh = self.next_fh;
        self.next_fh += 1;
        try self.handles.put(fh, fd);
        return fh;
    }
};

fn devOf(stx: *const linux.Statx) u64 {
    return (@as(u64, stx.dev_major) << 32) | stx.dev_minor;
}

fn statxFd(fd: i32, stx: *linux.Statx) i32 {
    return errnoOf(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, stx));
}

fn statxToAttr(stx: *const linux.Statx) proto.Attr {
    return .{
        .ino = stx.ino,
        .size = stx.size,
        .blocks = stx.blocks,
        .atime = @bitCast(stx.atime.sec),
        .mtime = @bitCast(stx.mtime.sec),
        .ctime = @bitCast(stx.ctime.sec),
        .atimensec = stx.atime.nsec,
        .mtimensec = stx.mtime.nsec,
        .ctimensec = stx.ctime.nsec,
        .mode = stx.mode,
        .nlink = stx.nlink,
        .uid = stx.uid,
        .gid = stx.gid,
        .rdev = (stx.rdev_major << 20) | stx.rdev_minor,
        .blksize = stx.blksize,
        .flags = 0,
    };
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| if (c == '/' or c == 0) return false;
    return true;
}

fn nameZ(buf: *[256]u8, name: []const u8) [:0]const u8 {
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return buf[0..name.len :0];
}

fn procFdPath(buf: *[64]u8, fd: i32) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "/proc/self/fd/{d}", .{fd}) catch unreachable;
}

pub const Session = struct {
    exp: Exporter,
    t: Transport,
    buf: []u8,
    data: []u8,

    pub fn init(gpa: Allocator, root_path: [:0]const u8, t: Transport) !Session {
        const buf = try gpa.alloc(u8, proto.max_frame);
        errdefer gpa.free(buf);
        const data = try gpa.alloc(u8, proto.max_data + 512);
        errdefer gpa.free(data);
        return .{
            .exp = try Exporter.init(gpa, root_path),
            .t = t,
            .buf = buf,
            .data = data,
        };
    }

    pub fn deinit(self: *Session) void {
        const gpa = self.exp.gpa;
        self.exp.deinit();
        gpa.free(self.buf);
        gpa.free(self.data);
    }

    pub fn run(self: *Session) !void {
        while (true) {
            const f = proto.readFrame(self.t, self.buf) catch |err| switch (err) {
                error.ConnectionClosed => return,
                else => return err,
            };
            try self.dispatch(f);
        }
    }

    fn reply(self: *Session, id: u64, status: i32, parts: []const []const u8) proto.TransportError!void {
        return proto.writeReply(self.t, id, status, parts);
    }

    fn replyErr(self: *Session, id: u64, status: i32) proto.TransportError!void {
        return self.reply(id, status, &.{});
    }

    fn dispatch(self: *Session, f: Frame) !void {
        switch (f.op()) {
            .hello => try self.opHello(f),
            .lookup => try self.opLookup(f),
            .forget => self.opForget(f),
            .getattr => try self.opGetattr(f),
            .setattr => try self.opSetattr(f),
            .opendir => try self.opOpendir(f),
            .readdir => try self.opReaddir(f),
            .releasedir, .release => try self.opRelease(f),
            .open => try self.opOpen(f),
            .create => try self.opCreate(f),
            .read => try self.opRead(f),
            .write => try self.opWrite(f),
            .flush => try self.opFlush(f),
            .fsync => try self.opFsync(f),
            .mkdir => try self.opMkdir(f),
            .unlink => try self.opUnlink(f, false),
            .rmdir => try self.opUnlink(f, true),
            .rename => try self.opRename(f),
            .symlink => try self.opSymlink(f),
            .readlink => try self.opReadlink(f),
            .statfs => try self.opStatfs(f),
            _ => try self.replyErr(f.id, errval(.NOSYS)),
        }
    }

    fn opHello(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.HelloReq) orelse return self.replyErr(f.id, errval(.INVAL));
        if (req.version != proto.VERSION) return self.replyErr(f.id, errval(.PROTO));
        const resp: proto.HelloResp = .{ .version = proto.VERSION };
        try self.reply(f.id, 0, &.{std.mem.asBytes(&resp)});
    }

    fn lookupEntry(self: *Session, parent_fd: i32, name: []const u8) union(enum) { err: i32, entry: proto.EntryResp } {
        var zbuf: [256]u8 = undefined;
        const rc = linux.openat(parent_fd, nameZ(&zbuf, name), .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return .{ .err = errnoOf(rc) };
        const fd: i32 = @intCast(rc);

        var stx: linux.Statx = undefined;
        const serr = statxFd(fd, &stx);
        if (serr != 0) {
            _ = linux.close(fd);
            return .{ .err = serr };
        }
        const id = self.exp.registerNode(fd, &stx) catch {
            _ = linux.close(fd);
            return .{ .err = errval(.NOMEM) };
        };
        return .{ .entry = .{ .node = id, .generation = 0, .attr = statxToAttr(&stx) } };
    }

    fn opLookup(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.LookupReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const name = f.rest(proto.LookupReq);
        if (!validName(name)) return self.replyErr(f.id, errval(.NOENT));
        const parent_fd = self.exp.nodeFd(req.parent) orelse return self.replyErr(f.id, errval(.STALE));
        switch (self.lookupEntry(parent_fd, name)) {
            .err => |e| try self.replyErr(f.id, e),
            .entry => |entry| try self.reply(f.id, 0, &.{std.mem.asBytes(&entry)}),
        }
    }

    fn opForget(self: *Session, f: Frame) void {
        const req = f.fixed(proto.ForgetReq) orelse return;
        self.exp.forget(req.node, req.nlookup);
    }

    fn opGetattr(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.GetattrReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const fd = self.exp.nodeFd(req.node) orelse return self.replyErr(f.id, errval(.STALE));
        var stx: linux.Statx = undefined;
        const serr = statxFd(fd, &stx);
        if (serr != 0) return self.replyErr(f.id, serr);
        const resp: proto.AttrResp = .{ .attr = statxToAttr(&stx) };
        try self.reply(f.id, 0, &.{std.mem.asBytes(&resp)});
    }

    fn opSetattr(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.SetattrReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const fd = self.exp.nodeFd(req.node) orelse return self.replyErr(f.id, errval(.STALE));
        var pbuf: [64]u8 = undefined;

        if (req.valid & proto.valid_mode != 0) {
            const rc = linux.fchmodat(linux.AT.FDCWD, procFdPath(&pbuf, fd), @intCast(req.mode & 0o7777));
            const e = errnoOf(rc);
            if (e != 0) return self.replyErr(f.id, e);
        }

        if (req.valid & (proto.valid_uid | proto.valid_gid) != 0) {
            const uid: linux.uid_t = if (req.valid & proto.valid_uid != 0) req.uid else @bitCast(@as(i32, -1));
            const gid: linux.gid_t = if (req.valid & proto.valid_gid != 0) req.gid else @bitCast(@as(i32, -1));
            const rc = linux.fchownat(fd, "", uid, gid, linux.AT.EMPTY_PATH);
            const e = errnoOf(rc);
            if (e != 0) return self.replyErr(f.id, e);
        }

        if (req.valid & proto.valid_size != 0) {
            var tfd: i32 = undefined;
            var opened = false;
            if (req.valid & proto.valid_fh != 0) {
                tfd = self.exp.handles.get(req.fh) orelse return self.replyErr(f.id, errval(.BADF));
            } else {
                const orc = linux.openat(linux.AT.FDCWD, procFdPath(&pbuf, fd), .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
                if (linux.errno(orc) != .SUCCESS) return self.replyErr(f.id, errnoOf(orc));
                tfd = @intCast(orc);
                opened = true;
            }
            const rc = linux.ftruncate(tfd, @intCast(req.size));
            const e = errnoOf(rc);
            if (opened) _ = linux.close(tfd);
            if (e != 0) return self.replyErr(f.id, e);
        }

        if (req.valid & (proto.valid_atime | proto.valid_mtime | proto.valid_atime_now | proto.valid_mtime_now) != 0) {
            var times: [2]linux.timespec = .{ linux.UTIME.OMIT, linux.UTIME.OMIT };
            if (req.valid & proto.valid_atime_now != 0) {
                times[0] = linux.UTIME.NOW;
            } else if (req.valid & proto.valid_atime != 0) {
                times[0] = .{ .sec = @intCast(@as(i64, @bitCast(req.atime))), .nsec = req.atimensec };
            }
            if (req.valid & proto.valid_mtime_now != 0) {
                times[1] = linux.UTIME.NOW;
            } else if (req.valid & proto.valid_mtime != 0) {
                times[1] = .{ .sec = @intCast(@as(i64, @bitCast(req.mtime))), .nsec = req.mtimensec };
            }
            const rc = linux.utimensat(linux.AT.FDCWD, procFdPath(&pbuf, fd), &times, 0);
            const e = errnoOf(rc);
            if (e != 0) return self.replyErr(f.id, e);
        }

        var stx: linux.Statx = undefined;
        const serr = statxFd(fd, &stx);
        if (serr != 0) return self.replyErr(f.id, serr);
        const resp: proto.AttrResp = .{ .attr = statxToAttr(&stx) };
        try self.reply(f.id, 0, &.{std.mem.asBytes(&resp)});
    }

    fn opOpendir(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.OpendirReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const fd = self.exp.nodeFd(req.node) orelse return self.replyErr(f.id, errval(.STALE));
        const rc = linux.openat(fd, ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return self.replyErr(f.id, errnoOf(rc));
        const dfd: i32 = @intCast(rc);
        const fh = self.exp.addHandle(dfd) catch {
            _ = linux.close(dfd);
            return self.replyErr(f.id, errval(.NOMEM));
        };
        const resp: proto.OpenResp = .{ .fh = fh };
        try self.reply(f.id, 0, &.{std.mem.asBytes(&resp)});
    }

    fn opReaddir(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.ReaddirReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const fd = self.exp.handles.get(req.fh) orelse return self.replyErr(f.id, errval(.BADF));
        const want = @min(req.size, proto.max_data);

        const lrc = linux.lseek(fd, @intCast(req.offset), linux.SEEK.SET);
        const lerr = errnoOf(lrc);
        if (lerr != 0) return self.replyErr(f.id, lerr);

        var dents: [8192]u8 align(8) = undefined;
        var out: []u8 = self.data[0..0];
        outer: while (out.len < want) {
            const rc = linux.getdents64(fd, &dents, dents.len);
            const e = linux.errno(rc);
            if (e != .SUCCESS) {
                if (out.len > 0) break;
                return self.replyErr(f.id, errnoOf(rc));
            }
            if (rc == 0) break;
            var pos: usize = 0;
            while (pos < rc) {
                const d: *align(1) linux.dirent64 = @ptrCast(&dents[pos]);
                const dname = std.mem.sliceTo(dents[pos + 19 .. pos + d.reclen], 0);
                const need = @sizeOf(proto.Dirent) + dname.len;
                if (out.len + need > want) break :outer;
                const ent: proto.Dirent = .{
                    .ino = d.ino,
                    .off = d.off,
                    .type = d.type,
                    .namelen = @intCast(dname.len),
                };
                const base = out.len;
                out = self.data[0 .. base + need];
                @memcpy(out[base..][0..@sizeOf(proto.Dirent)], std.mem.asBytes(&ent));
                @memcpy(out[base + @sizeOf(proto.Dirent) ..][0..dname.len], dname);
                pos += d.reclen;
            }
        }
        try self.reply(f.id, 0, &.{out});
    }

    fn opRelease(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.ReleaseReq) orelse return self.replyErr(f.id, errval(.INVAL));
        if (self.exp.handles.fetchRemove(req.fh)) |kv| {
            _ = linux.close(kv.value);
            try self.replyErr(f.id, 0);
        } else {
            try self.replyErr(f.id, errval(.BADF));
        }
    }

    fn sanitizeFlags(wire_flags: u32) linux.O {
        const flags: linux.O = @bitCast(wire_flags);
        var clean: linux.O = .{ .ACCMODE = flags.ACCMODE, .CLOEXEC = true };
        clean.APPEND = flags.APPEND;
        clean.TRUNC = flags.TRUNC;
        clean.NONBLOCK = flags.NONBLOCK;
        clean.DSYNC = flags.DSYNC;
        clean.SYNC = flags.SYNC;
        clean.NOATIME = flags.NOATIME;
        return clean;
    }

    fn opOpen(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.OpenReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const fd = self.exp.nodeFd(req.node) orelse return self.replyErr(f.id, errval(.STALE));
        var pbuf: [64]u8 = undefined;
        const rc = linux.openat(linux.AT.FDCWD, procFdPath(&pbuf, fd), sanitizeFlags(req.flags), 0);
        if (linux.errno(rc) != .SUCCESS) return self.replyErr(f.id, errnoOf(rc));
        const ffd: i32 = @intCast(rc);
        const fh = self.exp.addHandle(ffd) catch {
            _ = linux.close(ffd);
            return self.replyErr(f.id, errval(.NOMEM));
        };
        const resp: proto.OpenResp = .{ .fh = fh };
        try self.reply(f.id, 0, &.{std.mem.asBytes(&resp)});
    }

    fn opCreate(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.CreateReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const name = f.rest(proto.CreateReq);
        if (!validName(name)) return self.replyErr(f.id, errval(.PERM));
        const parent_fd = self.exp.nodeFd(req.parent) orelse return self.replyErr(f.id, errval(.STALE));

        var zbuf: [256]u8 = undefined;
        var flags = sanitizeFlags(req.flags);
        flags.CREAT = true;
        flags.EXCL = @as(linux.O, @bitCast(req.flags)).EXCL;
        flags.NOFOLLOW = true;
        const rc = linux.openat(parent_fd, nameZ(&zbuf, name), flags, @intCast(req.mode & 0o7777));
        if (linux.errno(rc) != .SUCCESS) return self.replyErr(f.id, errnoOf(rc));
        const ffd: i32 = @intCast(rc);

        var stx: linux.Statx = undefined;
        const serr = statxFd(ffd, &stx);
        if (serr != 0) {
            _ = linux.close(ffd);
            return self.replyErr(f.id, serr);
        }

        switch (self.lookupEntry(parent_fd, name)) {
            .err => |e| {
                _ = linux.close(ffd);
                try self.replyErr(f.id, e);
            },
            .entry => |entry| {
                const fh = self.exp.addHandle(ffd) catch {
                    _ = linux.close(ffd);
                    return self.replyErr(f.id, errval(.NOMEM));
                };
                const resp: proto.CreateResp = .{
                    .node = entry.node,
                    .generation = 0,
                    .attr = entry.attr,
                    .fh = fh,
                };
                try self.reply(f.id, 0, &.{std.mem.asBytes(&resp)});
            },
        }
    }

    fn opRead(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.ReadReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const fd = self.exp.handles.get(req.fh) orelse return self.replyErr(f.id, errval(.BADF));
        const want = @min(req.size, proto.max_data);
        var out: usize = 0;
        while (out < want) {
            const rc = linux.pread(fd, self.data[out..].ptr, want - out, @intCast(req.offset + out));
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) {
                if (out > 0) break;
                return self.replyErr(f.id, errnoOf(rc));
            }
            if (rc == 0) break;
            out += rc;
        }
        try self.reply(f.id, 0, &.{self.data[0..out]});
    }

    fn opWrite(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.WriteReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const data = f.rest(proto.WriteReq);
        const fd = self.exp.handles.get(req.fh) orelse return self.replyErr(f.id, errval(.BADF));
        var done: usize = 0;
        while (done < data.len) {
            const rc = linux.pwrite(fd, data[done..].ptr, data.len - done, @intCast(req.offset + done));
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) {
                if (done > 0) break;
                return self.replyErr(f.id, errnoOf(rc));
            }
            done += rc;
        }
        const resp: proto.WriteResp = .{ .size = @intCast(done) };
        try self.reply(f.id, 0, &.{std.mem.asBytes(&resp)});
    }

    fn opFlush(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.FlushReq) orelse return self.replyErr(f.id, errval(.INVAL));
        _ = self.exp.handles.get(req.fh) orelse return self.replyErr(f.id, errval(.BADF));
        try self.replyErr(f.id, 0);
    }

    fn opFsync(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.FsyncReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const fd = self.exp.handles.get(req.fh) orelse return self.replyErr(f.id, errval(.BADF));
        const rc = if (req.datasync != 0) linux.fdatasync(fd) else linux.fsync(fd);
        try self.replyErr(f.id, errnoOf(rc));
    }

    fn opMkdir(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.MkdirReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const name = f.rest(proto.MkdirReq);
        if (!validName(name)) return self.replyErr(f.id, errval(.PERM));
        const parent_fd = self.exp.nodeFd(req.parent) orelse return self.replyErr(f.id, errval(.STALE));
        var zbuf: [256]u8 = undefined;
        const rc = linux.mkdirat(parent_fd, nameZ(&zbuf, name), @intCast(req.mode & 0o7777));
        const e = errnoOf(rc);
        if (e != 0) return self.replyErr(f.id, e);
        switch (self.lookupEntry(parent_fd, name)) {
            .err => |le| try self.replyErr(f.id, le),
            .entry => |entry| try self.reply(f.id, 0, &.{std.mem.asBytes(&entry)}),
        }
    }

    fn opUnlink(self: *Session, f: Frame, dir: bool) !void {
        const req = f.fixed(proto.UnlinkReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const name = f.rest(proto.UnlinkReq);
        if (!validName(name)) return self.replyErr(f.id, errval(.PERM));
        const parent_fd = self.exp.nodeFd(req.parent) orelse return self.replyErr(f.id, errval(.STALE));
        var zbuf: [256]u8 = undefined;
        const flags: u32 = if (dir) linux.AT.REMOVEDIR else 0;
        const rc = linux.unlinkat(parent_fd, nameZ(&zbuf, name), flags);
        try self.replyErr(f.id, errnoOf(rc));
    }

    fn opRename(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.RenameReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const names = f.rest(proto.RenameReq);
        if (names.len != @as(usize, req.namelen) + req.newnamelen)
            return self.replyErr(f.id, errval(.INVAL));
        const name = names[0..req.namelen];
        const newname = names[req.namelen..];
        if (!validName(name) or !validName(newname)) return self.replyErr(f.id, errval(.PERM));
        const parent_fd = self.exp.nodeFd(req.parent) orelse return self.replyErr(f.id, errval(.STALE));
        const newparent_fd = self.exp.nodeFd(req.newparent) orelse return self.replyErr(f.id, errval(.STALE));
        var zbuf: [256]u8 = undefined;
        var zbuf2: [256]u8 = undefined;
        const rc = if (req.flags == 0)
            linux.renameat(parent_fd, nameZ(&zbuf, name), newparent_fd, nameZ(&zbuf2, newname))
        else
            linux.renameat2(parent_fd, nameZ(&zbuf, name), newparent_fd, nameZ(&zbuf2, newname), @bitCast(req.flags));
        try self.replyErr(f.id, errnoOf(rc));
    }

    fn opSymlink(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.SymlinkReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const payload = f.rest(proto.SymlinkReq);
        if (payload.len != @as(usize, req.namelen) + req.targetlen)
            return self.replyErr(f.id, errval(.INVAL));
        const name = payload[0..req.namelen];
        const target = payload[req.namelen..];
        if (!validName(name)) return self.replyErr(f.id, errval(.PERM));
        if (target.len == 0 or target.len > 4095) return self.replyErr(f.id, errval(.INVAL));
        const parent_fd = self.exp.nodeFd(req.parent) orelse return self.replyErr(f.id, errval(.STALE));
        var zbuf: [256]u8 = undefined;
        var tbuf: [4096]u8 = undefined;
        @memcpy(tbuf[0..target.len], target);
        tbuf[target.len] = 0;
        const rc = linux.symlinkat(tbuf[0..target.len :0], parent_fd, nameZ(&zbuf, name));
        const e = errnoOf(rc);
        if (e != 0) return self.replyErr(f.id, e);
        switch (self.lookupEntry(parent_fd, name)) {
            .err => |le| try self.replyErr(f.id, le),
            .entry => |entry| try self.reply(f.id, 0, &.{std.mem.asBytes(&entry)}),
        }
    }

    fn opReadlink(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.ReadlinkReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const fd = self.exp.nodeFd(req.node) orelse return self.replyErr(f.id, errval(.STALE));
        var tbuf: [4096]u8 = undefined;
        const rc = linux.readlinkat(fd, "", &tbuf, tbuf.len);
        const e = linux.errno(rc);
        if (e != .SUCCESS) return self.replyErr(f.id, errnoOf(rc));
        try self.reply(f.id, 0, &.{tbuf[0..rc]});
    }

    fn opStatfs(self: *Session, f: Frame) !void {
        const req = f.fixed(proto.StatfsReq) orelse return self.replyErr(f.id, errval(.INVAL));
        const fd = self.exp.nodeFd(req.node) orelse return self.replyErr(f.id, errval(.STALE));
        var sfs: Statfs = undefined;
        const rc = linux.syscall2(.fstatfs, @as(usize, @bitCast(@as(isize, fd))), @intFromPtr(&sfs));
        const e = errnoOf(rc);
        if (e != 0) return self.replyErr(f.id, e);
        const resp: proto.StatfsResp = .{
            .blocks = sfs.blocks,
            .bfree = sfs.bfree,
            .bavail = sfs.bavail,
            .files = sfs.files,
            .ffree = sfs.ffree,
            .bsize = @intCast(sfs.bsize),
            .namelen = @intCast(sfs.namelen),
            .frsize = @intCast(sfs.frsize),
        };
        try self.reply(f.id, 0, &.{std.mem.asBytes(&resp)});
    }
};
