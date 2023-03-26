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

const MsgParseError = error {
    InvalidHeader,
};

pub fn parseHeader(msg:[]const u8) !IpcMsgHeader {
    if (msg.len < 14) {
        return MsgParseError.InvalidHeader;
    }
    // Check for "i3-ipc"?
    const length = std.mem.readIntNative(u32, msg[6..10]);
    const msgtype = @intToEnum(IpcMsgType, std.mem.readIntNative(u32, msg[10..14]));
    return .{
        .msgtype = msgtype,
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
    const stackbufsize = 512;
    pub fn readMsg(self:IpcConnection, allocator:std.mem.Allocator) !IpcMsg {
        var buf:[stackbufsize]u8 = undefined;
        const readAmt = try self.stream.read(&buf);
        if (readAmt < 14) {
            // End of stream..?
            return error.IncorrectReadAmount;
        }
        const header = try parseHeader(&buf);
        const msgbuf = try allocator.alloc(u8, header.length);
        std.mem.copy(u8, msgbuf, buf[14..readAmt]);
        if (header.length > stackbufsize-14) {
            // long message: read more
            _ = self.stream.readAll(msgbuf[stackbufsize-14..]) catch |err| {
                log.err("failed: {s}", .{@errorName(err)});
                return err;
            };
        }
        return .{
            .msgtype = header.msgtype,
            .content = msgbuf
        };
    }
};

pub fn connect(address:?[]const u8) !IpcConnection {
    const swaysock = address orelse std.os.getenv("SWAYSOCK") orelse return error.NoSwaySock;
    const stream = try std.net.connectUnixSocket(swaysock);
    log.info("Connected to {s}", .{swaysock});
    return .{.stream=stream};
}