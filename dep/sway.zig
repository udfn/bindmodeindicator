const std = @import("std");
const log = std.log.scoped(.swayipc);

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
    EventWorkspace = ((1<<31) | 0),
    EventOutput = ((1<<31) | 1),
    EventMode = ((1<<31) | 2),
    EventWindow = ((1<<31) | 3),
    EventBarConfigUpdate = ((1<<31) | 4),
    EventBinding = ((1<<31) | 5),
    EventShutdown = ((1<<31) | 6),
    EventTick = ((1<<31) | 7),
    EventBarStateUpdate = ((1<<31) | 20),
    EventInput = ((1<<31) | 21),
    EventClientFilter = ((1<<31) | 29),
    EventMessage = ((1<<31 | 30))
};

pub const IpcMsg = struct {
    msgtype:IpcMsgType,
    content:[]u8,
};

pub const IpcMsgHeader = struct {
    msgtype:IpcMsgType,
    length:usize
};

pub fn parseHeader(msg:[]const u8) !IpcMsgHeader {
    if (msg.len < 14) {
        return error.InvalidHeader;
    }
    // Check for "i3-ipc"?
    const length = std.mem.readIntNative(u32, msg[6..10]);
    const msgtype = std.mem.readIntNative(u32, msg[10..14]);
    return .{
        .msgtype = @intToEnum(IpcMsgType, msgtype),
        .length = length
    };
}

pub const IpcConnection = struct {
    stream:std.net.Stream,

    pub fn sendMsg(self:IpcConnection, msgtype:IpcMsgType, payload:?[]const u8) !void {
        var header:[14]u8 = undefined;
        std.mem.copy(u8, header[0..], "i3-ipc");
        std.mem.writeIntNative(u32, header[10..14], @enumToInt(msgtype));
        std.mem.writeIntNative(u32, header[6..10], if (payload) |p| @truncate(u32, p.len) else 0);
        _ = try self.stream.writeAll(&header);
        
        if (payload) |p| {
            _ = try self.stream.writeAll(p[0..]);
            log.info("Sent {s} \"{s}\"", .{@tagName(msgtype), p});
        }
    }

    pub fn sendMsgWait(self:IpcConnection, allocator:std.mem.Allocator, msgtype:IpcMsgType, payload:?[]const u8) !IpcMsg {
        try self.sendMsg(msgtype, payload);
        return try self.readMsg(allocator);
    }

    pub fn readMsg(self:IpcConnection, allocator:std.mem.Allocator) !IpcMsg {
        var headerbuf:[14]u8 = undefined;
        if (try self.stream.readAll(&headerbuf) != 14) {
            return error.EndOfStream;
        }
        const head = try parseHeader(&headerbuf);
        var buf = try allocator.alloc(u8, head.length);
        errdefer allocator.free(buf);
        if (try self.stream.readAll(buf) != head.length) {
            return error.IncompleteMessage;
        }
        return .{
            .msgtype = head.msgtype,
            .content = buf
        };
    }
};

pub fn connect(address:?[]const u8) !IpcConnection {
    const swaysock = address orelse std.os.getenv("SWAYSOCK") orelse return error.NoSwaySock;
    const stream = try std.net.connectUnixSocket(swaysock);
    log.info("Connected to {s}", .{swaysock});
    return .{.stream=stream};
}