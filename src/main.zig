const std = @import("std");
const linux = std.os.linux;
const proto = @import("proto.zig");
const server = @import("server.zig");
const client = @import("client.zig");
const fs = @import("fs.zig");

const usage =
    \\usage:
    \\  simplefs serve <dir> [--listen HOST:PORT] [--stdio]
    \\  simplefs mount <target> <mountpoint>
    \\  simplefs dbg <HOST:PORT> <cmd> [args]
    \\
    \\mount targets:
    \\  HOST:PORT        TCP connection to a running server
    \\  user@host:/dir   spawns: ssh user@host simplefs serve /dir --stdio
    \\  exec:CMD         spawns CMD with the protocol on stdin/stdout
    \\
    \\dbg commands: stat <path> | ls <path> | cat <path> | statfs
    \\
;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

const Addr = struct {
    ip: [4]u8,
    port: u16,

    fn parse(text: []const u8) !Addr {
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.MissingPort;
        const host = text[0..colon];
        const port = try std.fmt.parseInt(u16, text[colon + 1 ..], 10);
        const ip4 = try std.Io.net.Ip4Address.parse(host, port);
        return .{ .ip = ip4.bytes, .port = port };
    }

    fn sockaddr(a: Addr) linux.sockaddr.in {
        return .{
            .port = std.mem.nativeToBig(u16, a.port),
            .addr = @bitCast(a.ip),
        };
    }
};

fn checked(rc: usize, what: []const u8) usize {
    const e = linux.errno(rc);
    if (e != .SUCCESS) fatal("{s}: {t}", .{ what, e });
    return rc;
}

fn setNodelay(fd: i32) void {
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), 4);
}

fn tcpListen(addr: Addr) i32 {
    const sfd: i32 = @intCast(checked(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0), "socket"));
    const one: u32 = 1;
    _ = linux.setsockopt(sfd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
    var sa = addr.sockaddr();
    _ = checked(linux.bind(sfd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)), "bind");
    _ = checked(linux.listen(sfd, 1), "listen");
    return sfd;
}

fn tcpConnect(addr: Addr) !i32 {
    const sfd: i32 = @intCast(checked(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0), "socket"));
    var sa = addr.sockaddr();
    const rc = linux.connect(sfd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
    if (linux.errno(rc) != .SUCCESS) {
        _ = linux.close(sfd);
        return error.ConnectFailed;
    }
    setNodelay(sfd);
    return sfd;
}

fn cmdServe(gpa: std.mem.Allocator, it: *std.process.Args.Iterator) !void {
    var dir: ?[:0]const u8 = null;
    var listen_addr: Addr = .{ .ip = .{ 127, 0, 0, 1 }, .port = 7070 };
    var stdio = false;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--listen")) {
            const v = it.next() orelse fatal("--listen requires HOST:PORT", .{});
            listen_addr = Addr.parse(v) catch fatal("bad address: {s}", .{v});
        } else if (std.mem.eql(u8, arg, "--stdio")) {
            stdio = true;
        } else if (dir == null) {
            dir = arg;
        } else {
            fatal("unexpected argument: {s}", .{arg});
        }
    }
    const root = dir orelse fatal("serve: missing <dir>\n{s}", .{usage});

    if (stdio) {
        var sess = server.Session.init(gpa, root, .{ .rfd = 0, .wfd = 1 }) catch |err|
            fatal("serve: {t}", .{err});
        defer sess.deinit();
        try sess.run();
        return;
    }

    const sfd = tcpListen(listen_addr);
    std.debug.print("serving {s} on {d}.{d}.{d}.{d}:{d}\n", .{
        root, listen_addr.ip[0], listen_addr.ip[1], listen_addr.ip[2], listen_addr.ip[3], listen_addr.port,
    });
    while (true) {
        const rc = linux.accept(sfd, null, null);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS) fatal("accept: {t}", .{linux.errno(rc)});
        const cfd: i32 = @intCast(rc);
        setNodelay(cfd);
        std.debug.print("client connected\n", .{});
        var sess = server.Session.init(gpa, root, proto.Transport.fromSocket(cfd)) catch |err| {
            std.debug.print("session init failed: {t}\n", .{err});
            _ = linux.close(cfd);
            continue;
        };
        sess.run() catch |err| std.debug.print("session error: {t}\n", .{err});
        sess.deinit();
        _ = linux.close(cfd);
        std.debug.print("client disconnected\n", .{});
    }
}

fn spawnStdio(argv: []const ?[*:0]const u8) proto.Transport {
    var to_child: [2]i32 = undefined;
    var from_child: [2]i32 = undefined;
    _ = checked(linux.pipe2(&to_child, .{}), "pipe");
    _ = checked(linux.pipe2(&from_child, .{}), "pipe");

    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) fatal("fork: {t}", .{linux.errno(pid_rc)});
    if (pid_rc == 0) {
        _ = linux.dup2(to_child[0], 0);
        _ = linux.dup2(from_child[1], 1);
        _ = linux.close(to_child[0]);
        _ = linux.close(to_child[1]);
        _ = linux.close(from_child[0]);
        _ = linux.close(from_child[1]);
        const envp = [_:null]?[*:0]const u8{"PATH=/usr/local/bin:/usr/bin:/bin"};
        _ = linux.execve("/bin/sh", @ptrCast(argv.ptr), @ptrCast(&envp));
        linux.exit(127);
    }
    _ = linux.close(to_child[0]);
    _ = linux.close(from_child[1]);
    return .{ .rfd = from_child[0], .wfd = to_child[1] };
}

fn mountTransport(gpa: std.mem.Allocator, target: [:0]const u8) proto.Transport {
    if (std.mem.startsWith(u8, target, "exec:")) {
        const cmd = target["exec:".len..];
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd.ptr };
        return spawnStdio(&argv);
    }
    if (Addr.parse(target)) |addr| {
        const sfd = tcpConnect(addr) catch fatal("cannot connect to {s}", .{target});
        return proto.Transport.fromSocket(sfd);
    } else |_| {}
    const colon = std.mem.indexOfScalar(u8, target, ':') orelse
        fatal("bad mount target: {s} (want HOST:PORT, user@host:/dir, or exec:CMD)", .{target});
    const host = target[0..colon];
    const path = target[colon + 1 ..];
    if (path.len == 0) fatal("bad mount target: {s} (missing remote path)", .{target});
    const cmd = std.fmt.allocPrintSentinel(gpa, "exec ssh {s} simplefs serve {s} --stdio", .{ host, path }, 0) catch
        fatal("out of memory", .{});
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd.ptr };
    const t = spawnStdio(&argv);
    gpa.free(cmd);
    return t;
}

fn cmdMount(gpa: std.mem.Allocator, it: *std.process.Args.Iterator) !void {
    const target = it.next() orelse fatal("mount: missing <target>\n{s}", .{usage});
    const mountpoint = it.next() orelse fatal("mount: missing <mountpoint>\n{s}", .{usage});

    const t = mountTransport(gpa, target);
    var cl = try client.Client.init(gpa, t);
    defer cl.deinit();
    cl.hello() catch |err| fatal("handshake failed: {t}", .{err});

    try fs.mount(gpa, &cl, mountpoint);
}

fn writeOut(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(1, bytes[off..].ptr, bytes.len - off);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS) return;
        off += rc;
    }
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeOut(s);
}

fn dbgResolve(cl: *client.Client, path: []const u8) !u64 {
    var node: u64 = 1;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |name| {
        const req: proto.LookupReq = .{ .parent = node };
        const f = try cl.call(.lookup, &.{ std.mem.asBytes(&req), name });
        if (f.status() != 0) {
            print("lookup {s}: {t}\n", .{ name, @as(linux.E, @enumFromInt(-f.status())) });
            return error.LookupFailed;
        }
        const entry = f.fixed(proto.EntryResp) orelse return error.BadReply;
        node = entry.node;
    }
    return node;
}

fn cmdDbg(gpa: std.mem.Allocator, it: *std.process.Args.Iterator) !void {
    const addr_str = it.next() orelse fatal("dbg: missing <HOST:PORT>\n{s}", .{usage});
    const cmd = it.next() orelse fatal("dbg: missing <cmd>\n{s}", .{usage});
    const addr = Addr.parse(addr_str) catch fatal("bad address: {s}", .{addr_str});

    const sfd = tcpConnect(addr) catch fatal("cannot connect to {s}", .{addr_str});
    var cl = try client.Client.init(gpa, proto.Transport.fromSocket(sfd));
    defer cl.deinit();
    try cl.hello();

    if (std.mem.eql(u8, cmd, "stat")) {
        const path = it.next() orelse fatal("dbg stat: missing <path>", .{});
        const node = try dbgResolve(&cl, path);
        const req: proto.GetattrReq = .{ .node = node };
        const f = try cl.call(.getattr, &.{std.mem.asBytes(&req)});
        if (f.status() != 0) fatal("getattr: {t}", .{@as(linux.E, @enumFromInt(-f.status()))});
        const resp = f.fixed(proto.AttrResp) orelse return error.BadReply;
        const a = resp.attr;
        print("node={d} ino={d} mode={o} size={d} uid={d} gid={d} nlink={d} mtime={d}\n", .{
            node, a.ino, a.mode, a.size, a.uid, a.gid, a.nlink, a.mtime,
        });
    } else if (std.mem.eql(u8, cmd, "ls")) {
        const path = it.next() orelse "/";
        const node = try dbgResolve(&cl, path);
        const oreq: proto.OpendirReq = .{ .node = node };
        var f = try cl.call(.opendir, &.{std.mem.asBytes(&oreq)});
        if (f.status() != 0) fatal("opendir: {t}", .{@as(linux.E, @enumFromInt(-f.status()))});
        const fh = (f.fixed(proto.OpenResp) orelse return error.BadReply).fh;

        var offset: u64 = 0;
        while (true) {
            const rreq: proto.ReaddirReq = .{ .fh = fh, .offset = offset, .size = 64 * 1024 };
            f = try cl.call(.readdir, &.{std.mem.asBytes(&rreq)});
            if (f.status() != 0) fatal("readdir: {t}", .{@as(linux.E, @enumFromInt(-f.status()))});
            if (f.body.len == 0) break;
            var pos: usize = 0;
            while (pos + @sizeOf(proto.Dirent) <= f.body.len) {
                const d: *align(1) proto.Dirent = @ptrCast(f.body.ptr + pos);
                const name = f.body[pos + @sizeOf(proto.Dirent) ..][0..d.namelen];
                print("{d}\t{s}\n", .{ d.ino, name });
                offset = d.off;
                pos += @sizeOf(proto.Dirent) + d.namelen;
            }
        }
        const rel: proto.ReleaseReq = .{ .fh = fh };
        _ = try cl.call(.releasedir, &.{std.mem.asBytes(&rel)});
    } else if (std.mem.eql(u8, cmd, "cat")) {
        const path = it.next() orelse fatal("dbg cat: missing <path>", .{});
        const node = try dbgResolve(&cl, path);
        const oreq: proto.OpenReq = .{ .node = node, .flags = @bitCast(linux.O{ .ACCMODE = .RDONLY }) };
        var f = try cl.call(.open, &.{std.mem.asBytes(&oreq)});
        if (f.status() != 0) fatal("open: {t}", .{@as(linux.E, @enumFromInt(-f.status()))});
        const fh = (f.fixed(proto.OpenResp) orelse return error.BadReply).fh;

        var offset: u64 = 0;
        while (true) {
            const rreq: proto.ReadReq = .{ .fh = fh, .offset = offset, .size = 256 * 1024 };
            f = try cl.call(.read, &.{std.mem.asBytes(&rreq)});
            if (f.status() != 0) fatal("read: {t}", .{@as(linux.E, @enumFromInt(-f.status()))});
            if (f.body.len == 0) break;
            writeOut(f.body);
            offset += f.body.len;
        }
        const rel: proto.ReleaseReq = .{ .fh = fh };
        _ = try cl.call(.release, &.{std.mem.asBytes(&rel)});
    } else if (std.mem.eql(u8, cmd, "statfs")) {
        const req: proto.StatfsReq = .{ .node = 1 };
        const f = try cl.call(.statfs, &.{std.mem.asBytes(&req)});
        if (f.status() != 0) fatal("statfs: {t}", .{@as(linux.E, @enumFromInt(-f.status()))});
        const s = f.fixed(proto.StatfsResp) orelse return error.BadReply;
        print("blocks={d} bfree={d} bavail={d} files={d} ffree={d} bsize={d}\n", .{
            s.blocks, s.bfree, s.bavail, s.files, s.ffree, s.bsize,
        });
    } else {
        fatal("unknown dbg command: {s}\n{s}", .{ cmd, usage });
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.skip();
    const cmd = it.next() orelse fatal("{s}", .{usage});

    if (std.mem.eql(u8, cmd, "serve")) {
        try cmdServe(gpa, &it);
    } else if (std.mem.eql(u8, cmd, "mount")) {
        try cmdMount(gpa, &it);
    } else if (std.mem.eql(u8, cmd, "dbg")) {
        try cmdDbg(gpa, &it);
    } else {
        fatal("unknown command: {s}\n{s}", .{ cmd, usage });
    }
}

test {
    _ = @import("proto.zig");
    _ = @import("server.zig");
    _ = @import("server_test.zig");
    _ = @import("fuse/kernel.zig");
}
