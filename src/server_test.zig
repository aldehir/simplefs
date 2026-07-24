const std = @import("std");
const linux = std.os.linux;
const proto = @import("proto.zig");
const server = @import("server.zig");
const client = @import("client.zig");

var next_id: u32 = 0;

const Fixture = struct {
    root: [64]u8,
    root_len: usize,
    thread: std.Thread,
    cl: client.Client,

    fn rootPath(self: *const Fixture) [:0]const u8 {
        return self.root[0 .. self.root_len :0];
    }

    fn serveThread(gpa: std.mem.Allocator, root: [:0]const u8, t: proto.Transport) void {
        var sess = server.Session.init(gpa, root, t) catch unreachable;
        defer sess.deinit();
        sess.run() catch {};
        t.close();
    }

    fn start(self: *Fixture) !void {
        var counter_buf: [64]u8 = undefined;
        next_id += 1;
        const unique = std.fmt.bufPrint(&counter_buf, "{d}-{d}", .{ linux.getpid(), next_id }) catch unreachable;
        const path = std.fmt.bufPrintZ(&self.root, "/tmp/simplefs-test-{s}", .{unique}) catch unreachable;
        self.root_len = path.len;
        _ = linux.mkdirat(linux.AT.FDCWD, path, 0o700);

        var fds: [2]i32 = undefined;
        try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds));

        self.thread = try std.Thread.spawn(.{}, serveThread, .{
            std.testing.allocator, self.rootPath(), proto.Transport.fromSocket(fds[0]),
        });
        self.cl = try client.Client.init(std.testing.allocator, proto.Transport.fromSocket(fds[1]));
        try self.cl.hello();
    }

    fn stop(self: *Fixture) void {
        self.cl.t.close();
        self.thread.join();
        self.cl.deinit();
        var buf: [80]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&buf, "rm -rf {s}", .{self.rootPath()}) catch unreachable;
        _ = runShell(cmd);
    }

    fn writeLocalFile(self: *Fixture, name: []const u8, contents: []const u8) !void {
        var buf: [128]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ self.rootPath(), name }) catch unreachable;
        const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var off: usize = 0;
        while (off < contents.len) {
            const wrc = linux.write(fd, contents[off..].ptr, contents.len - off);
            try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(wrc));
            off += wrc;
        }
    }
};

fn runShell(cmd: [:0]const u8) i32 {
    const pid = linux.fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd };
        const envp = [_:null]?[*:0]const u8{};
        _ = linux.execve("/bin/sh", &argv, &envp);
        linux.exit(127);
    }
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    return @intCast(status);
}

fn lookup(cl: *client.Client, parent: u64, name: []const u8) !proto.EntryResp {
    const req: proto.LookupReq = .{ .parent = parent };
    const f = try cl.call(.lookup, &.{ std.mem.asBytes(&req), name });
    if (f.status() != 0) {
        std.debug.print("lookup {s} failed: {t}\n", .{ name, @as(linux.E, @enumFromInt(-f.status())) });
        return error.LookupFailed;
    }
    return (f.fixed(proto.EntryResp) orelse return error.BadReply).*;
}

test "lookup and getattr" {
    var fx: Fixture = undefined;
    try fx.start();
    defer fx.stop();
    try fx.writeLocalFile("hello.txt", "hello world\n");

    const entry = try lookup(&fx.cl, 1, "hello.txt");
    try std.testing.expectEqual(@as(u64, 12), entry.attr.size);
    try std.testing.expect(entry.attr.mode & linux.S.IFMT == linux.S.IFREG);

    const req: proto.GetattrReq = .{ .node = entry.node };
    const f = try fx.cl.call(.getattr, &.{std.mem.asBytes(&req)});
    try std.testing.expectEqual(@as(i32, 0), f.status());
    const resp = f.fixed(proto.AttrResp).?;
    try std.testing.expectEqual(entry.attr.ino, resp.attr.ino);

    const missing: proto.LookupReq = .{ .parent = 1 };
    const mf = try fx.cl.call(.lookup, &.{ std.mem.asBytes(&missing), "nope" });
    try std.testing.expectEqual(-@as(i32, @intFromEnum(linux.E.NOENT)), mf.status());
}

test "lookup same file twice returns same node" {
    var fx: Fixture = undefined;
    try fx.start();
    defer fx.stop();
    try fx.writeLocalFile("a.txt", "a");

    const e1 = try lookup(&fx.cl, 1, "a.txt");
    const e2 = try lookup(&fx.cl, 1, "a.txt");
    try std.testing.expectEqual(e1.node, e2.node);

    const freq: proto.ForgetReq = .{ .node = e1.node, .nlookup = 2 };
    try fx.cl.send(.forget, &.{std.mem.asBytes(&freq)});

    const e3 = try lookup(&fx.cl, 1, "a.txt");
    try std.testing.expect(e3.node != 0);
}

test "readdir lists entries" {
    var fx: Fixture = undefined;
    try fx.start();
    defer fx.stop();
    try fx.writeLocalFile("one", "1");
    try fx.writeLocalFile("two", "2");

    const oreq: proto.OpendirReq = .{ .node = 1 };
    var f = try fx.cl.call(.opendir, &.{std.mem.asBytes(&oreq)});
    try std.testing.expectEqual(@as(i32, 0), f.status());
    const fh = f.fixed(proto.OpenResp).?.fh;

    var found_one = false;
    var found_two = false;
    var offset: u64 = 0;
    outer: while (true) {
        const rreq: proto.ReaddirReq = .{ .fh = fh, .offset = offset, .size = 4096 };
        f = try fx.cl.call(.readdir, &.{std.mem.asBytes(&rreq)});
        try std.testing.expectEqual(@as(i32, 0), f.status());
        if (f.body.len == 0) break :outer;
        var pos: usize = 0;
        while (pos + @sizeOf(proto.Dirent) <= f.body.len) {
            const d: *align(1) proto.Dirent = @ptrCast(f.body.ptr + pos);
            const name = f.body[pos + @sizeOf(proto.Dirent) ..][0..d.namelen];
            if (std.mem.eql(u8, name, "one")) found_one = true;
            if (std.mem.eql(u8, name, "two")) found_two = true;
            offset = d.off;
            pos += @sizeOf(proto.Dirent) + d.namelen;
        }
    }
    try std.testing.expect(found_one);
    try std.testing.expect(found_two);

    const rel: proto.ReleaseReq = .{ .fh = fh };
    f = try fx.cl.call(.releasedir, &.{std.mem.asBytes(&rel)});
    try std.testing.expectEqual(@as(i32, 0), f.status());
}

test "open read write" {
    var fx: Fixture = undefined;
    try fx.start();
    defer fx.stop();
    try fx.writeLocalFile("data.txt", "initial");

    const entry = try lookup(&fx.cl, 1, "data.txt");
    const oreq: proto.OpenReq = .{ .node = entry.node, .flags = @bitCast(linux.O{ .ACCMODE = .RDWR }) };
    var f = try fx.cl.call(.open, &.{std.mem.asBytes(&oreq)});
    try std.testing.expectEqual(@as(i32, 0), f.status());
    const fh = f.fixed(proto.OpenResp).?.fh;

    const rreq: proto.ReadReq = .{ .fh = fh, .offset = 0, .size = 1024 };
    f = try fx.cl.call(.read, &.{std.mem.asBytes(&rreq)});
    try std.testing.expectEqual(@as(i32, 0), f.status());
    try std.testing.expectEqualStrings("initial", f.body);

    const wreq: proto.WriteReq = .{ .fh = fh, .offset = 0 };
    f = try fx.cl.call(.write, &.{ std.mem.asBytes(&wreq), "INIT" });
    try std.testing.expectEqual(@as(i32, 0), f.status());
    try std.testing.expectEqual(@as(u32, 4), f.fixed(proto.WriteResp).?.size);

    f = try fx.cl.call(.read, &.{std.mem.asBytes(&rreq)});
    try std.testing.expectEqualStrings("INITial", f.body);

    const rel: proto.ReleaseReq = .{ .fh = fh };
    _ = try fx.cl.call(.release, &.{std.mem.asBytes(&rel)});
}

test "create mkdir unlink rmdir rename symlink" {
    var fx: Fixture = undefined;
    try fx.start();
    defer fx.stop();

    const creq: proto.CreateReq = .{
        .parent = 1,
        .flags = @bitCast(linux.O{ .ACCMODE = .WRONLY }),
        .mode = 0o644,
    };
    var f = try fx.cl.call(.create, &.{ std.mem.asBytes(&creq), "new.txt" });
    try std.testing.expectEqual(@as(i32, 0), f.status());
    const cresp = f.fixed(proto.CreateResp).?.*;
    const wreq: proto.WriteReq = .{ .fh = cresp.fh, .offset = 0 };
    f = try fx.cl.call(.write, &.{ std.mem.asBytes(&wreq), "x" });
    try std.testing.expectEqual(@as(i32, 0), f.status());
    const rel: proto.ReleaseReq = .{ .fh = cresp.fh };
    _ = try fx.cl.call(.release, &.{std.mem.asBytes(&rel)});

    const mreq: proto.MkdirReq = .{ .parent = 1, .mode = 0o755 };
    f = try fx.cl.call(.mkdir, &.{ std.mem.asBytes(&mreq), "subdir" });
    try std.testing.expectEqual(@as(i32, 0), f.status());
    const dentry = f.fixed(proto.EntryResp).?.*;
    try std.testing.expect(dentry.attr.mode & linux.S.IFMT == linux.S.IFDIR);

    var rnreq: proto.RenameReq = .{
        .parent = 1,
        .newparent = dentry.node,
        .flags = 0,
        .namelen = 7,
        .newnamelen = 9,
    };
    f = try fx.cl.call(.rename, &.{ std.mem.asBytes(&rnreq), "new.txt", "moved.txt" });
    try std.testing.expectEqual(@as(i32, 0), f.status());
    _ = try lookup(&fx.cl, dentry.node, "moved.txt");

    const sreq: proto.SymlinkReq = .{ .parent = 1, .namelen = 4, .targetlen = 16 };
    f = try fx.cl.call(.symlink, &.{ std.mem.asBytes(&sreq), "link", "subdir/moved.txt" });
    try std.testing.expectEqual(@as(i32, 0), f.status());
    const lentry = f.fixed(proto.EntryResp).?.*;
    try std.testing.expect(lentry.attr.mode & linux.S.IFMT == linux.S.IFLNK);

    const rlreq: proto.ReadlinkReq = .{ .node = lentry.node };
    f = try fx.cl.call(.readlink, &.{std.mem.asBytes(&rlreq)});
    try std.testing.expectEqual(@as(i32, 0), f.status());
    try std.testing.expectEqualStrings("subdir/moved.txt", f.body);

    const ureq: proto.UnlinkReq = .{ .parent = 1 };
    f = try fx.cl.call(.unlink, &.{ std.mem.asBytes(&ureq), "link" });
    try std.testing.expectEqual(@as(i32, 0), f.status());

    const mvnode = try lookup(&fx.cl, dentry.node, "moved.txt");
    _ = mvnode;
    f = try fx.cl.call(.unlink, &.{ std.mem.asBytes(&ureq), "nope" });
    try std.testing.expectEqual(-@as(i32, @intFromEnum(linux.E.NOENT)), f.status());

    const ureq2: proto.UnlinkReq = .{ .parent = dentry.node };
    f = try fx.cl.call(.unlink, &.{ std.mem.asBytes(&ureq2), "moved.txt" });
    try std.testing.expectEqual(@as(i32, 0), f.status());

    const rmreq: proto.RmdirReq = .{ .parent = 1 };
    f = try fx.cl.call(.rmdir, &.{ std.mem.asBytes(&rmreq), "subdir" });
    try std.testing.expectEqual(@as(i32, 0), f.status());
}

test "setattr truncate and chmod" {
    var fx: Fixture = undefined;
    try fx.start();
    defer fx.stop();
    try fx.writeLocalFile("t.txt", "0123456789");

    const entry = try lookup(&fx.cl, 1, "t.txt");
    var sreq: proto.SetattrReq = std.mem.zeroes(proto.SetattrReq);
    sreq.node = entry.node;
    sreq.valid = proto.valid_size | proto.valid_mode;
    sreq.size = 4;
    sreq.mode = 0o600;
    const f = try fx.cl.call(.setattr, &.{std.mem.asBytes(&sreq)});
    try std.testing.expectEqual(@as(i32, 0), f.status());
    const resp = f.fixed(proto.AttrResp).?;
    try std.testing.expectEqual(@as(u64, 4), resp.attr.size);
    try std.testing.expectEqual(@as(u32, 0o600), resp.attr.mode & 0o7777);
}

test "escape attempts rejected" {
    var fx: Fixture = undefined;
    try fx.start();
    defer fx.stop();

    const req: proto.LookupReq = .{ .parent = 1 };
    var f = try fx.cl.call(.lookup, &.{ std.mem.asBytes(&req), ".." });
    try std.testing.expect(f.status() < 0);
    f = try fx.cl.call(.lookup, &.{ std.mem.asBytes(&req), "a/b" });
    try std.testing.expect(f.status() < 0);
    f = try fx.cl.call(.lookup, &.{ std.mem.asBytes(&req), "/etc/passwd" });
    try std.testing.expect(f.status() < 0);
}
