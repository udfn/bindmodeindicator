const std = @import("std");
const log = std.log.scoped(.swayipc);
const native_endian = @import("builtin").cpu.arch.endian();


pub const IpcMsgType = enum(u32) {
    MsgRunCommands = 0,
    MsgGetWorkspaces = 1,
    MsgSubscribe = 2,
    MsgGetOutputs,
    MsgGetTree,
    MsgGetMarks,
    MsgGetBarConfig,
    MsgGetVersion,
    MsgGetBindingModes,
    MsgGetConfig,
    MsgSendTick,
    MsgSync,
    MsgGetBindingState,
    MsgGetInputs = 100,
    MsgGetSeats = 101,
    EventWorkspace = ((1 << 31) | 0),
    EventOutput = ((1 << 31) | 1),
    EventMode = ((1 << 31) | 2),
    EventWindow = ((1 << 31) | 3),
    EventBarConfigUpdate = ((1 << 31) | 4),
    EventBinding = ((1 << 31) | 5),
    EventShutdown = ((1 << 31) | 6),
    EventTick = ((1 << 31) | 7),
    EventBarStateUpdate = ((1 << 31) | 20),
    EventInput = ((1 << 31) | 21),
    EventNode = ((1 << 31 | 28)),
    EventClientFilter = ((1 << 31) | 29),
    EventMessage = ((1 << 31 | 30)),

    pub fn jsonStringify(self: IpcMsgType, jw: anytype) !void {
        const string = switch (self) {
            .EventWorkspace => "workspace",
            .EventOutput => "output",
            .EventMode => "mode",
            .EventWindow => "window",
            .EventBarConfigUpdate => "barconfig_update",
            .EventBinding => "binding",
            .EventShutdown => "shutdown",
            .EventTick => "tick",
            .EventBarStateUpdate => "bar_state_update",
            .EventInput => "input",
            .EventClientFilter => "clientfilter",
            .EventMessage => "message",
            .EventNode => "node",
            else => unreachable
        };
        try jw.write(string);
    }
};

pub const IpcMsg = struct {
    msgtype: IpcMsgType,
    content: []u8,
};

pub const IpcMsgHeader = struct { msgtype: IpcMsgType, length: usize };

pub fn parseHeader(msg: []const u8) !IpcMsgHeader {
    if (msg.len < 14) {
        return error.InvalidHeader;
    }
    // Check for "i3-ipc"?
    const length = std.mem.readInt(u32, msg[6..10], native_endian);
    const msgtype = std.mem.readInt(u32, msg[10..14], native_endian);
    return .{ .msgtype = @enumFromInt(msgtype), .length = length };
}

pub const IpcConnection = struct {
    stream: std.net.Stream,

    pub fn sendMsg(self: IpcConnection, msgtype: IpcMsgType, payload: ?[]const u8) !void {
        var header: [14]u8 = undefined;
        @memcpy(header[0..6], "i3-ipc");
        std.mem.writeInt(u32, header[10..14], @intFromEnum(msgtype), native_endian);
        std.mem.writeInt(u32, header[6..10], if (payload) |p| @as(u32, @truncate(p.len)) else 0, native_endian);
        _ = try self.stream.writeAll(&header);

        if (payload) |p| {
            _ = try self.stream.writeAll(p[0..]);
            log.info("Sent {s} \"{s}\"", .{ @tagName(msgtype), p });
        }
    }

    pub fn subscribe(self: IpcConnection, events: []const IpcMsgType) !void {
        var buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try std.json.stringify(events, .{}, fbs.writer());
        try self.sendMsg(.MsgSubscribe, fbs.getWritten());
    }

    pub fn sendMsgWait(self: IpcConnection, allocator: std.mem.Allocator, msgtype: IpcMsgType, payload: ?[]const u8) !IpcMsg {
        try self.sendMsg(msgtype, payload);
        return try self.readMsg(allocator);
    }

    pub fn readMsg(self: IpcConnection, allocator: std.mem.Allocator) !IpcMsg {
        var headerbuf: [14]u8 = undefined;
        if (try self.stream.readAll(&headerbuf) != 14) {
            return error.EndOfStream;
        }
        const head = try parseHeader(&headerbuf);
        const buf = try allocator.alloc(u8, head.length);
        errdefer allocator.free(buf);
        if (try self.stream.readAll(buf) != head.length) {
            return error.IncompleteMessage;
        }
        return .{ .msgtype = head.msgtype, .content = buf };
    }
};

pub fn connect(address: ?[]const u8) !IpcConnection {
    const swaysock = address orelse std.os.getenv("SWAYSOCK") orelse return error.NoSwaySock;
    const stream = try std.net.connectUnixSocket(swaysock);
    log.info("Connected to {s}", .{swaysock});
    return .{ .stream = stream };
}
