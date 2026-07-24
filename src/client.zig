const std = @import("std");
const proto = @import("proto.zig");

const Allocator = std.mem.Allocator;

pub const Client = struct {
    t: proto.Transport,
    buf: []u8,
    next_id: u64,
    gpa: Allocator,

    pub fn init(gpa: Allocator, t: proto.Transport) !Client {
        const buf = try gpa.alloc(u8, proto.max_frame);
        return .{ .t = t, .buf = buf, .next_id = 1, .gpa = gpa };
    }

    pub fn deinit(self: *Client) void {
        self.gpa.free(self.buf);
    }

    pub fn hello(self: *Client) !void {
        const req: proto.HelloReq = .{ .version = proto.VERSION };
        const f = try self.call(.hello, &.{std.mem.asBytes(&req)});
        if (f.status() != 0) return error.HandshakeFailed;
        const resp = f.fixed(proto.HelloResp) orelse return error.HandshakeFailed;
        if (resp.version != proto.VERSION) return error.VersionMismatch;
    }

    pub fn call(self: *Client, op: proto.Op, parts: []const []const u8) proto.TransportError!proto.Frame {
        const id = self.next_id;
        self.next_id += 1;
        try proto.writeRequest(self.t, id, op, parts);
        while (true) {
            const f = try proto.readFrame(self.t, self.buf);
            if (f.id == id) return f;
        }
    }

    pub fn send(self: *Client, op: proto.Op, parts: []const []const u8) proto.TransportError!void {
        const id = self.next_id;
        self.next_id += 1;
        try proto.writeRequest(self.t, id, op, parts);
    }
};
