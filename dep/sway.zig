const std = @import("std");
const log = std.log.scoped(.swayipc);
const native_endian = @import("builtin").cpu.arch.endian();

pub const IpcMsgType = packed struct(u32) {
    pub const Msg = enum(u30) {
        RunCommands = 0,
        GetWorkspaces = 1,
        Subscribe = 2,
        GetOutputs,
        GetTree,
        GetMarks,
        GetBarConfig,
        GetVersion,
        GetBindingModes,
        GetConfig,
        SendTick,
        Sync,
        GetBindingState,
        GetInputs = 100,
        GetSeats = 101,
    };
    pub const Event = enum(u30) {
        Workspace = 0,
        Output = 1,
        Mode = 2,
        Window = 3,
        BarConfigUpdate = 4,
        Binding = 5,
        Shutdown = 6,
        Tick = 7,
        Lock = 15,
        BarStateUpdate = 20,
        Input = 21,
        Node = 28,
        ClientFilter = 29,
        Message = 30,

        pub fn jsonStringify(self: Event, jw: anytype) !void {
            const string = switch (self) {
                .Workspace => "workspace",
                .Output => "output",
                .Mode => "mode",
                .Window => "window",
                .BarConfigUpdate => "barconfig_update",
                .Binding => "binding",
                .Shutdown => "shutdown",
                .Tick => "tick",
                .BarStateUpdate => "bar_state_update",
                .Input => "input",
                .ClientFilter => "clientfilter",
                .Message => "message",
                .Node => "node",
                .Lock => "lock",
            };
            try jw.write(string);
        }

        pub fn toUint(self: Event) u32 {
            return @as(u32, @intCast(@intFromEnum(self))) | (1 << 31);
        }
    };

    pub const Kind = enum(u2) {
        msg = 0,
        event = 2,
    };
    type: packed union {
        msg: Msg,
        event: Event,
    },
    kind: Kind,

    pub fn format(value: IpcMsgType, writer: *std.Io.Writer) !void {
        switch (value.kind) {
            .msg => {
                try writer.writeAll("msg:");
                try writer.writeAll(@tagName(value.type.msg));
            },
            .event => {
                try writer.writeAll("event:");
                try writer.writeAll(@tagName(value.type.event));
            },
        }
    }
};

pub const IpcMsg = struct {
    msgtype: IpcMsgType,
    content: []const u8,
};

pub const IpcMsgHeader = struct { msgtype: IpcMsgType, length: usize };

pub fn parseHeader(msg: []const u8) !IpcMsgHeader {
    if (msg.len < 14) {
        return error.InvalidHeader;
    }
    // Check for "i3-ipc"?
    const length = std.mem.readInt(u32, msg[6..10], native_endian);
    const msgtype = std.mem.readInt(u32, msg[10..14], native_endian);
    return .{ .msgtype = @bitCast(msgtype), .length = length };
}

pub const IpcConnection = struct {
    reader: std.Io.net.Stream.Reader,

    fn writeHeader(dest: []u8, msgtype: IpcMsgType, payload_len: u32) void {
        @memcpy(dest[0..6], "i3-ipc");
        std.mem.writeInt(u32, dest[10..14], @bitCast(msgtype), native_endian);
        std.mem.writeInt(u32, dest[6..10], payload_len, native_endian);
    }

    pub fn sendMsg(self: *IpcConnection, msgtype: IpcMsgType.Msg, payload: ?[]const u8) !void {
        var header: [14]u8 = undefined;
        writeHeader(&header, .{ .type = .{ .msg = msgtype }, .kind = .msg }, if (payload) |p| @intCast(p.len) else 0);
        var writer = self.reader.stream.writer(self.reader.io, &.{});
        if (payload) |p| {
            _ = try writer.interface.writeVec(&.{ &header, p });
            log.info("Sent {t} \"{s}\"", .{ msgtype, p });
        } else {
            _ = try writer.interface.writeVec(&.{&header});
            log.info("Sent {t}", .{msgtype});
        }
    }

    pub fn subscribe(self: *IpcConnection, events: []const IpcMsgType.Event) !void {
        var buf: [512]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        var stringer: std.json.Stringify = .{ .writer = &fbs };
        try stringer.write(events);
        try self.sendMsg(.Subscribe, buf[0..fbs.end]);
    }

    pub fn sendMsgWait(self: *IpcConnection, allocator: std.mem.Allocator, msgtype: IpcMsgType.Msg, payload: ?[]const u8) !IpcMsg {
        try self.sendMsg(msgtype, payload);
        return try self.readMsg(allocator);
    }

    pub fn readMsg(self: *IpcConnection, allocator: std.mem.Allocator) !IpcMsg {
        var headerbuf: [14]u8 = undefined;
        try self.reader.interface.readSliceAll(&headerbuf);
        const head = try parseHeader(&headerbuf);
        const content = try self.reader.interface.readAlloc(allocator, head.length);
        return .{ .msgtype = head.msgtype, .content = content };
    }
};

pub fn connect(io: std.Io, address: ?[]const u8, read_buffer: []u8) !IpcConnection {
    const swaysock = address orelse std.posix.getenv("SWAYSOCK") orelse return error.NoSwaySock;
    const uaddress = try std.Io.net.UnixAddress.init(swaysock);
    var stream = try uaddress.connect(io);
    log.info("Connected to {s}", .{swaysock});
    return .{ .reader = stream.reader(io, read_buffer) };
}
