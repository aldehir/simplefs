const std = @import("std");
const linux = std.os.linux;
const proto = @import("proto.zig");
const client = @import("client.zig");
const kernel = @import("fuse/kernel.zig");
const session = @import("fuse/session.zig");

const read_buf_size = proto.max_data + 64 * 1024;

const Fs = struct {
    cl: *client.Client,
    dev: session.Device,
    mountpoint: [:0]const u8,
    uid: u32,
    gid: u32,
    connected: bool,
    unmount_requested: bool,
    scratch: []u8,

    fn attrFromProto(self: *Fs, a: proto.Attr) kernel.Attr {
        return .{
            .ino = a.ino,
            .size = a.size,
            .blocks = a.blocks,
            .atime = a.atime,
            .mtime = a.mtime,
            .ctime = a.ctime,
            .atimensec = a.atimensec,
            .mtimensec = a.mtimensec,
            .ctimensec = a.ctimensec,
            .mode = a.mode,
            .nlink = a.nlink,
            .uid = self.uid,
            .gid = self.gid,
            .rdev = a.rdev,
            .blksize = a.blksize,
            .flags = 0,
        };
    }

    fn entryOut(self: *Fs, e: proto.EntryResp) kernel.EntryOut {
        return .{
            .nodeid = e.node,
            .generation = e.generation,
            .entry_valid = 0,
            .attr_valid = 0,
            .entry_valid_nsec = 0,
            .attr_valid_nsec = 0,
            .attr = self.attrFromProto(e.attr),
        };
    }

    fn call(self: *Fs, op: proto.Op, parts: []const []const u8) !proto.Frame {
        if (!self.connected) return error.NotConnected;
        return self.cl.call(op, parts) catch |err| {
            self.connected = false;
            std.debug.print("simplefs: server connection lost, lazy-unmounting\n", .{});
            session.unmount(self.mountpoint);
            self.unmount_requested = true;
            return err;
        };
    }

    fn reply(self: *Fs, unique: u64, err: i32, parts: []const []const u8) void {
        self.dev.reply(unique, err, parts);
    }

    fn replyFrameStatus(self: *Fs, unique: u64, f: proto.Frame) ?proto.Frame {
        if (f.status() != 0) {
            self.reply(unique, f.status(), &.{});
            return null;
        }
        return f;
    }

    fn dispatch(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const nodeid = r.header.nodeid;
        switch (r.opcode()) {
            .init => self.opInit(r),
            .destroy => self.reply(unique, 0, &.{}),
            .forget => {
                if (r.fixed(kernel.ForgetIn)) |in| self.forgetNode(nodeid, in.nlookup);
            },
            .batch_forget => self.opBatchForget(r),
            .interrupt => {},
            .lookup => self.opLookup(r),
            .getattr => self.opGetattr(r),
            .setattr => self.opSetattr(r),
            .readlink => self.opReadlink(r),
            .symlink => self.opSymlink(r),
            .mkdir => self.opMkdir(r),
            .unlink => self.opUnlink(r, .unlink),
            .rmdir => self.opUnlink(r, .rmdir),
            .rename => self.opRename(r),
            .rename2 => self.opRename2(r),
            .open => self.opOpen(r, .open),
            .opendir => self.opOpen(r, .opendir),
            .read => self.opRead(r),
            .readdir => self.opReaddir(r),
            .write => self.opWrite(r),
            .release => self.opRelease(r, .release),
            .releasedir => self.opRelease(r, .releasedir),
            .flush => self.opFlush(r),
            .fsync, .fsyncdir => self.opFsync(r),
            .statfs => self.opStatfs(r),
            .create => self.opCreate(r),
            .mknod => self.reply(unique, errval(.NOSYS), &.{}),
            .link => self.reply(unique, errval(.NOSYS), &.{}),
            .access => self.reply(unique, errval(.NOSYS), &.{}),
            .getxattr, .setxattr, .listxattr, .removexattr => self.reply(unique, errval(.OPNOTSUPP), &.{}),
            else => self.reply(unique, errval(.NOSYS), &.{}),
        }
    }

    fn opInit(self: *Fs, r: session.Request) void {
        const in = r.fixed(kernel.InitIn) orelse return self.reply(r.header.unique, errval(.INVAL), &.{});
        if (in.major != 7 or in.minor < kernel.kernel_minor_version) {
            std.debug.print("simplefs: unsupported FUSE protocol {d}.{d}\n", .{ in.major, in.minor });
            self.reply(r.header.unique, errval(.PROTO), &.{});
            return;
        }
        const wanted = kernel.init_big_writes | kernel.init_max_pages | kernel.init_atomic_o_trunc;
        const out: kernel.InitOut = .{
            .major = 7,
            .minor = @min(in.minor, 36),
            .max_readahead = in.max_readahead,
            .flags = in.flags & wanted,
            .max_background = 16,
            .congestion_threshold = 12,
            .max_write = proto.max_data,
            .time_gran = 1,
            .max_pages = proto.max_data / std.heap.page_size_min,
            .map_alignment = 0,
            .flags2 = 0,
            .max_stack_depth = 0,
            .unused = @splat(0),
        };
        self.reply(r.header.unique, 0, &.{std.mem.asBytes(&out)});
    }

    fn forgetNode(self: *Fs, nodeid: u64, nlookup: u64) void {
        if (!self.connected) return;
        const req: proto.ForgetReq = .{ .node = nodeid, .nlookup = nlookup };
        self.cl.send(.forget, &.{std.mem.asBytes(&req)}) catch {
            self.connected = false;
        };
    }

    fn opBatchForget(self: *Fs, r: session.Request) void {
        const in = r.fixed(kernel.BatchForgetIn) orelse return;
        const raw = r.rest(kernel.BatchForgetIn);
        var i: usize = 0;
        while (i < in.count and (i + 1) * @sizeOf(kernel.ForgetOne) <= raw.len) : (i += 1) {
            const one: *align(1) const kernel.ForgetOne = @ptrCast(raw.ptr + i * @sizeOf(kernel.ForgetOne));
            self.forgetNode(one.nodeid, one.nlookup);
        }
    }

    fn opLookup(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const raw = r.body;
        const end = std.mem.indexOfScalar(u8, raw, 0) orelse return self.reply(unique, errval(.INVAL), &.{});
        const name = raw[0..end];
        const req: proto.LookupReq = .{ .parent = r.header.nodeid };
        const f = self.call(.lookup, &.{ std.mem.asBytes(&req), name }) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        const ok = self.replyFrameStatus(unique, f) orelse return;
        const entry = ok.fixed(proto.EntryResp) orelse return self.reply(unique, errval(.IO), &.{});
        const out = self.entryOut(entry.*);
        self.reply(unique, 0, &.{std.mem.asBytes(&out)});
    }

    fn opGetattr(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const req: proto.GetattrReq = .{ .node = r.header.nodeid };
        const f = self.call(.getattr, &.{std.mem.asBytes(&req)}) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        const ok = self.replyFrameStatus(unique, f) orelse return;
        const resp = ok.fixed(proto.AttrResp) orelse return self.reply(unique, errval(.IO), &.{});
        const out: kernel.AttrOut = .{
            .attr_valid = 0,
            .attr_valid_nsec = 0,
            .dummy = 0,
            .attr = self.attrFromProto(resp.attr),
        };
        self.reply(unique, 0, &.{std.mem.asBytes(&out)});
    }

    fn opSetattr(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const in = r.fixed(kernel.SetattrIn) orelse return self.reply(unique, errval(.INVAL), &.{});
        const supported = kernel.fattr_mode | kernel.fattr_uid | kernel.fattr_gid |
            kernel.fattr_size | kernel.fattr_atime | kernel.fattr_mtime | kernel.fattr_fh |
            kernel.fattr_atime_now | kernel.fattr_mtime_now;
        const req: proto.SetattrReq = .{
            .node = r.header.nodeid,
            .valid = in.valid & supported,
            .mode = in.mode,
            .uid = in.uid,
            .gid = in.gid,
            .size = in.size,
            .atime = in.atime,
            .mtime = in.mtime,
            .atimensec = in.atimensec,
            .mtimensec = in.mtimensec,
            .fh = in.fh,
        };
        const f = self.call(.setattr, &.{std.mem.asBytes(&req)}) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        const ok = self.replyFrameStatus(unique, f) orelse return;
        const resp = ok.fixed(proto.AttrResp) orelse return self.reply(unique, errval(.IO), &.{});
        const out: kernel.AttrOut = .{
            .attr_valid = 0,
            .attr_valid_nsec = 0,
            .dummy = 0,
            .attr = self.attrFromProto(resp.attr),
        };
        self.reply(unique, 0, &.{std.mem.asBytes(&out)});
    }

    fn opReadlink(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const req: proto.ReadlinkReq = .{ .node = r.header.nodeid };
        const f = self.call(.readlink, &.{std.mem.asBytes(&req)}) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        const ok = self.replyFrameStatus(unique, f) orelse return;
        self.reply(unique, 0, &.{ok.body});
    }

    fn opSymlink(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const raw = r.body;
        const name_end = std.mem.indexOfScalar(u8, raw, 0) orelse return self.reply(unique, errval(.INVAL), &.{});
        const name = raw[0..name_end];
        const target_raw = raw[name_end + 1 ..];
        const target_end = std.mem.indexOfScalar(u8, target_raw, 0) orelse return self.reply(unique, errval(.INVAL), &.{});
        const target = target_raw[0..target_end];
        if (name.len > std.math.maxInt(u16) or target.len > std.math.maxInt(u16))
            return self.reply(unique, errval(.NAMETOOLONG), &.{});
        const req: proto.SymlinkReq = .{
            .parent = r.header.nodeid,
            .namelen = @intCast(name.len),
            .targetlen = @intCast(target.len),
        };
        const f = self.call(.symlink, &.{ std.mem.asBytes(&req), name, target }) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        const ok = self.replyFrameStatus(unique, f) orelse return;
        const entry = ok.fixed(proto.EntryResp) orelse return self.reply(unique, errval(.IO), &.{});
        const out = self.entryOut(entry.*);
        self.reply(unique, 0, &.{std.mem.asBytes(&out)});
    }

    fn opMkdir(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const in = r.fixed(kernel.MkdirIn) orelse return self.reply(unique, errval(.INVAL), &.{});
        const name = r.name(kernel.MkdirIn) orelse return self.reply(unique, errval(.INVAL), &.{});
        const req: proto.MkdirReq = .{ .parent = r.header.nodeid, .mode = in.mode & ~in.umask };
        const f = self.call(.mkdir, &.{ std.mem.asBytes(&req), name }) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        const ok = self.replyFrameStatus(unique, f) orelse return;
        const entry = ok.fixed(proto.EntryResp) orelse return self.reply(unique, errval(.IO), &.{});
        const out = self.entryOut(entry.*);
        self.reply(unique, 0, &.{std.mem.asBytes(&out)});
    }

    fn opUnlink(self: *Fs, r: session.Request, which: enum { unlink, rmdir }) void {
        const unique = r.header.unique;
        const raw = r.body;
        const end = std.mem.indexOfScalar(u8, raw, 0) orelse return self.reply(unique, errval(.INVAL), &.{});
        const name = raw[0..end];
        const req: proto.UnlinkReq = .{ .parent = r.header.nodeid };
        const op: proto.Op = if (which == .rmdir) .rmdir else .unlink;
        const f = self.call(op, &.{ std.mem.asBytes(&req), name }) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        self.reply(unique, f.status(), &.{});
    }

    fn renameCommon(self: *Fs, r: session.Request, newdir: u64, flags: u32, names: []const u8) void {
        const unique = r.header.unique;
        const name_end = std.mem.indexOfScalar(u8, names, 0) orelse return self.reply(unique, errval(.INVAL), &.{});
        const name = names[0..name_end];
        const newname_raw = names[name_end + 1 ..];
        const newname_end = std.mem.indexOfScalar(u8, newname_raw, 0) orelse return self.reply(unique, errval(.INVAL), &.{});
        const newname = newname_raw[0..newname_end];
        if (name.len > std.math.maxInt(u16) or newname.len > std.math.maxInt(u16))
            return self.reply(unique, errval(.NAMETOOLONG), &.{});
        const req: proto.RenameReq = .{
            .parent = r.header.nodeid,
            .newparent = newdir,
            .flags = flags,
            .namelen = @intCast(name.len),
            .newnamelen = @intCast(newname.len),
        };
        const f = self.call(.rename, &.{ std.mem.asBytes(&req), name, newname }) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        self.reply(unique, f.status(), &.{});
    }

    fn opRename(self: *Fs, r: session.Request) void {
        const in = r.fixed(kernel.RenameIn) orelse return self.reply(r.header.unique, errval(.INVAL), &.{});
        self.renameCommon(r, in.newdir, 0, r.rest(kernel.RenameIn));
    }

    fn opRename2(self: *Fs, r: session.Request) void {
        const in = r.fixed(kernel.Rename2In) orelse return self.reply(r.header.unique, errval(.INVAL), &.{});
        self.renameCommon(r, in.newdir, in.flags, r.rest(kernel.Rename2In));
    }

    fn opOpen(self: *Fs, r: session.Request, which: enum { open, opendir }) void {
        const unique = r.header.unique;
        const f = blk: {
            if (which == .opendir) {
                const req: proto.OpendirReq = .{ .node = r.header.nodeid };
                break :blk self.call(.opendir, &.{std.mem.asBytes(&req)});
            } else {
                const in = r.fixed(kernel.OpenIn) orelse return self.reply(unique, errval(.INVAL), &.{});
                const req: proto.OpenReq = .{ .node = r.header.nodeid, .flags = in.flags };
                break :blk self.call(.open, &.{std.mem.asBytes(&req)});
            }
        } catch return self.reply(unique, errval(.NOTCONN), &.{});
        const ok = self.replyFrameStatus(unique, f) orelse return;
        const resp = ok.fixed(proto.OpenResp) orelse return self.reply(unique, errval(.IO), &.{});
        const out: kernel.OpenOut = .{ .fh = resp.fh, .open_flags = 0, .backing_id = 0 };
        self.reply(unique, 0, &.{std.mem.asBytes(&out)});
    }

    fn opRead(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const in = r.fixed(kernel.ReadIn) orelse return self.reply(unique, errval(.INVAL), &.{});
        const req: proto.ReadReq = .{
            .fh = in.fh,
            .offset = in.offset,
            .size = @min(in.size, proto.max_data),
        };
        const f = self.call(.read, &.{std.mem.asBytes(&req)}) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        const ok = self.replyFrameStatus(unique, f) orelse return;
        self.reply(unique, 0, &.{ok.body});
    }

    fn opWrite(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const in = r.fixed(kernel.WriteIn) orelse return self.reply(unique, errval(.INVAL), &.{});
        const data_all = r.rest(kernel.WriteIn);
        if (in.size > data_all.len) return self.reply(unique, errval(.INVAL), &.{});
        const data = data_all[0..in.size];
        const req: proto.WriteReq = .{ .fh = in.fh, .offset = in.offset };
        const f = self.call(.write, &.{ std.mem.asBytes(&req), data }) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        const ok = self.replyFrameStatus(unique, f) orelse return;
        const resp = ok.fixed(proto.WriteResp) orelse return self.reply(unique, errval(.IO), &.{});
        const out: kernel.WriteOut = .{ .size = resp.size, .padding = 0 };
        self.reply(unique, 0, &.{std.mem.asBytes(&out)});
    }

    fn opReaddir(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const in = r.fixed(kernel.ReadIn) orelse return self.reply(unique, errval(.INVAL), &.{});
        const want: u32 = @min(in.size, proto.max_data);
        const req: proto.ReaddirReq = .{ .fh = in.fh, .offset = in.offset, .size = want };
        const f = self.call(.readdir, &.{std.mem.asBytes(&req)}) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        const ok = self.replyFrameStatus(unique, f) orelse return;

        var out_len: usize = 0;
        var pos: usize = 0;
        const body = ok.body;
        while (pos + @sizeOf(proto.Dirent) <= body.len) {
            const d: *align(1) const proto.Dirent = @ptrCast(body.ptr + pos);
            const name = body[pos + @sizeOf(proto.Dirent) ..][0..d.namelen];
            const rec_len = kernel.direntAlign(@sizeOf(kernel.Dirent) + name.len);
            if (out_len + rec_len > want) break;
            const kd: kernel.Dirent = .{
                .ino = d.ino,
                .off = d.off,
                .namelen = d.namelen,
                .type = d.type,
            };
            @memcpy(self.scratch[out_len..][0..@sizeOf(kernel.Dirent)], std.mem.asBytes(&kd));
            @memcpy(self.scratch[out_len + @sizeOf(kernel.Dirent) ..][0..name.len], name);
            @memset(self.scratch[out_len + @sizeOf(kernel.Dirent) + name.len ..][0 .. rec_len - @sizeOf(kernel.Dirent) - name.len], 0);
            out_len += rec_len;
            pos += @sizeOf(proto.Dirent) + d.namelen;
        }
        self.reply(unique, 0, &.{self.scratch[0..out_len]});
    }

    fn opRelease(self: *Fs, r: session.Request, which: enum { release, releasedir }) void {
        const unique = r.header.unique;
        const in = r.fixed(kernel.ReleaseIn) orelse return self.reply(unique, errval(.INVAL), &.{});
        const req: proto.ReleaseReq = .{ .fh = in.fh };
        const op: proto.Op = if (which == .releasedir) .releasedir else .release;
        const f = self.call(op, &.{std.mem.asBytes(&req)}) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        self.reply(unique, f.status(), &.{});
    }

    fn opFlush(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const in = r.fixed(kernel.FlushIn) orelse return self.reply(unique, errval(.INVAL), &.{});
        const req: proto.FlushReq = .{ .fh = in.fh };
        const f = self.call(.flush, &.{std.mem.asBytes(&req)}) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        self.reply(unique, f.status(), &.{});
    }

    fn opFsync(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const in = r.fixed(kernel.FsyncIn) orelse return self.reply(unique, errval(.INVAL), &.{});
        const req: proto.FsyncReq = .{ .fh = in.fh, .datasync = in.fsync_flags & 1 };
        const f = self.call(.fsync, &.{std.mem.asBytes(&req)}) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        self.reply(unique, f.status(), &.{});
    }

    fn opStatfs(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const node = if (r.header.nodeid == 0) 1 else r.header.nodeid;
        const req: proto.StatfsReq = .{ .node = node };
        const f = self.call(.statfs, &.{std.mem.asBytes(&req)}) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        const ok = self.replyFrameStatus(unique, f) orelse return;
        const resp = ok.fixed(proto.StatfsResp) orelse return self.reply(unique, errval(.IO), &.{});
        const out: kernel.StatfsOut = .{ .st = .{
            .blocks = resp.blocks,
            .bfree = resp.bfree,
            .bavail = resp.bavail,
            .files = resp.files,
            .ffree = resp.ffree,
            .bsize = resp.bsize,
            .namelen = resp.namelen,
            .frsize = resp.frsize,
            .padding = 0,
            .spare = @splat(0),
        } };
        self.reply(unique, 0, &.{std.mem.asBytes(&out)});
    }

    fn opCreate(self: *Fs, r: session.Request) void {
        const unique = r.header.unique;
        const in = r.fixed(kernel.CreateIn) orelse return self.reply(unique, errval(.INVAL), &.{});
        const name = r.name(kernel.CreateIn) orelse return self.reply(unique, errval(.INVAL), &.{});
        const req: proto.CreateReq = .{
            .parent = r.header.nodeid,
            .flags = in.flags,
            .mode = in.mode & ~in.umask,
        };
        const f = self.call(.create, &.{ std.mem.asBytes(&req), name }) catch
            return self.reply(unique, errval(.NOTCONN), &.{});
        const ok = self.replyFrameStatus(unique, f) orelse return;
        const resp = ok.fixed(proto.CreateResp) orelse return self.reply(unique, errval(.IO), &.{});
        const entry = self.entryOut(.{
            .node = resp.node,
            .generation = resp.generation,
            .attr = resp.attr,
        });
        const open_out: kernel.OpenOut = .{ .fh = resp.fh, .open_flags = 0, .backing_id = 0 };
        self.reply(unique, 0, &.{ std.mem.asBytes(&entry), std.mem.asBytes(&open_out) });
    }
};

fn errval(e: linux.E) i32 {
    return -@as(i32, @intFromEnum(e));
}

pub fn mount(gpa: std.mem.Allocator, cl: *client.Client, mountpoint: [:0]const u8) !void {
    session.installSignalHandlers();

    const fuse_fd = try session.mount(mountpoint);
    var fsys: Fs = .{
        .cl = cl,
        .dev = .{ .fd = fuse_fd },
        .mountpoint = mountpoint,
        .uid = linux.getuid(),
        .gid = linux.getgid(),
        .connected = true,
        .unmount_requested = false,
        .scratch = try gpa.alloc(u8, proto.max_data),
    };
    defer gpa.free(fsys.scratch);
    defer fsys.dev.close();

    const buf = try gpa.alignedAlloc(u8, .@"8", read_buf_size);
    defer gpa.free(buf);

    std.debug.print("simplefs: mounted on {s}\n", .{mountpoint});

    while (true) {
        switch (fsys.dev.readRequest(buf)) {
            .request => |r| fsys.dispatch(r),
            .retry => continue,
            .unmounted => {
                std.debug.print("simplefs: unmounted\n", .{});
                return;
            },
            .interrupted => {
                std.debug.print("simplefs: signal received, unmounting\n", .{});
                session.unmount(mountpoint);
                return;
            },
            .err => |e| {
                std.debug.print("simplefs: /dev/fuse read error: {t}\n", .{e});
                session.unmount(mountpoint);
                return;
            },
        }
        if (session.interrupted()) {
            std.debug.print("simplefs: signal received, unmounting\n", .{});
            session.unmount(mountpoint);
            return;
        }
    }
}
