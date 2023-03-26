const std = @import("std");
const nwl = @import("nwl");
const swayipc = @import("sway");
const use_uring = @import("options").uring;
pub const wayland = @import("wayland");
const c = @cImport(
    @cInclude("cairo.h")
);

const ModeIndicatorState = struct {
    bufferman:nwl.ShmBufferMan = .{
        .impl = &MultiRenderBufferImpl
    },
    sway:swayipc.IpcConnection,
    nwl:nwl.State,
    allocator:std.mem.Allocator,
    rec_surface:?*c.cairo_surface_t = null,
    cur_buffer:?*nwl.ShmBuffer = null,
    scale:c_int = 1,
};

fn bufferCreate(buffer:*nwl.ShmBuffer, bufferman:*nwl.ShmBufferMan) callconv(.C) void {
    buffer.data = c.cairo_image_surface_create_for_data(buffer.bufferdata, c.CAIRO_FORMAT_ARGB32, @intCast(c_int, bufferman.width), @intCast(c_int, bufferman.height), @intCast(c_int, bufferman.stride));
}

fn bufferDestroy(buffer:*nwl.ShmBuffer, bufferman:*nwl.ShmBufferMan) callconv(.C) void {
    _ = bufferman;
    var cairo_surface = @ptrCast(*c.cairo_surface_t, @alignCast(@alignOf(*c.cairo_surface_t), buffer.data));
    c.cairo_surface_destroy(cairo_surface);
}

const MultiRenderBufferImpl = nwl.ShmBufferMan.BufferRendererImpl{
    .buffer_create = bufferCreate,
    .buffer_destroy = bufferDestroy
};

fn renderNoOp(surface:*nwl.Surface) callconv(.C) void {
    _ = surface;
}

fn renderSurface(cairo_surface:*c.cairo_surface_t, string:[:0]const u8) void {
    var cr = c.cairo_create(cairo_surface);
    c.cairo_select_font_face(cr, "sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, 16);
    var extents:c.cairo_text_extents_t = undefined;
    c.cairo_text_extents(cr, string, &extents);
    c.cairo_rectangle(cr, 0, 0, extents.width + 12.0, 32);
    c.cairo_set_source_rgba(cr, 0.7, 0.05, 0.05, 0.8);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_fill(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
    c.cairo_rectangle(cr, 1, 1, extents.width + 11.0, 30);
    c.cairo_set_source_rgba(cr, 0.3, 0.05, 0.05, 0.9);
    c.cairo_stroke(cr);
    c.cairo_move_to(cr, 6.0, 21);
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0);
    c.cairo_show_text(cr, string);
    c.cairo_destroy(cr);
}

fn multiRenderRender(surface:*nwl.Surface) callconv(.C) void {
    const mistate = @fieldParentPtr(ModeIndicatorState, "nwl", surface.state);
    surface.renderer.rendering = true;
    defer surface.renderer.rendering = false;
    if (mistate.cur_buffer == null and mistate.rec_surface != null) {
        const scaled_width = surface.width * @intCast(u32, mistate.scale);
        const scaled_height = surface.height * @intCast(u32, mistate.scale);
        if (mistate.bufferman.width != scaled_width) {
            mistate.bufferman.resize(surface.state, scaled_width, scaled_height, scaled_width*4, 0);
        }
        mistate.cur_buffer = mistate.bufferman.getNext();
        if (mistate.cur_buffer == null) {
            mistate.bufferman.setSlots(surface.state, mistate.bufferman.num_slots+1);
            mistate.cur_buffer = mistate.bufferman.getNext();
            if (mistate.cur_buffer == null) {
                std.log.err("ARGH! CAN'T GET A BUFFER! Giving up!", .{});
                surface.state.run_with_zero_surfaces = false;
                surface.state.num_surfaces = 0;
                return;
            }
        }
        var cairo_surface = @ptrCast(*c.cairo_surface_t, @alignCast(@alignOf(*c.cairo_surface_t), mistate.cur_buffer.?.data));
        var cr = c.cairo_create(cairo_surface);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_scale(cr, @intToFloat(f64, mistate.scale), @intToFloat(f64, mistate.scale));
        c.cairo_set_source_surface(cr, mistate.rec_surface, 0, 0);
        c.cairo_paint(cr);
        c.cairo_destroy(cr);
    }
    if (mistate.cur_buffer != null) {
        surface.swapBuffers(0, 0);
    } else {
        surface.wl.surface.attach(null, 0, 0);
        surface.commit();
    }
}

fn renderSwapBuffers(surface:*nwl.Surface, x:i32, y:i32) callconv(.C) void {
    _ = x;
    _ = y;
    var mistate = @fieldParentPtr(ModeIndicatorState, "nwl", surface.state);
    if (mistate.cur_buffer) |buf| {
        if (mistate.scale != surface.scale) {
            surface.scale = mistate.scale;
            surface.wl.surface.setBufferScale(surface.scale);
        }
        surface.wl.surface.attach(buf.wl_buffer, 0, 0);
        surface.wl.surface.damageBuffer(0, 0, @intCast(i32, surface.width)*surface.scale, @intCast(i32, surface.height)*surface.scale);
        surface.commit();
    } else {
        std.log.err("BUG BUG BUG! Swap buffers without buffer!", .{});
    }
}

const MultiSurfaceRenderImpl = nwl.RendererImpl {
    .apply_size = renderNoOp,
    .surface_destroy = renderNoOp,
    .swap_buffers = renderSwapBuffers,
    .render = multiRenderRender,
    .destroy = renderNoOp
};

fn handleSurfaceDestroy(surface:*nwl.Surface) callconv(.C) void {
    const state = @fieldParentPtr(ModeIndicatorState, "nwl", surface.state);
    if (!surface.flags.nwl_frees) {
        state.allocator.destroy(surface);
    }
    std.log.info("flags {}", .{surface.flags});
}

fn createBindSurface(state:*ModeIndicatorState, output:*nwl.Output) !void {
    var surface = try state.allocator.create(nwl.Surface);
    surface.init(&state.nwl, "bindmodeindicator");
    try surface.roleLayershell(output.output, 3);
    surface.setSize(128, 32);
    surface.role.layer.wl.setAnchor(.{.top = true, .left = true});
    surface.renderer.impl = &MultiSurfaceRenderImpl;
    surface.userdata = output;
    surface.impl.destroy = handleSurfaceDestroy;
    surface.flags.no_autoscale = true;
    var region = try surface.state.wl.compositor.?.createRegion();
    surface.wl.surface.setInputRegion(region);
    defer region.destroy();
    surface.commit();
}

fn handleNewOutput(output:*nwl.Output) callconv(.C) void {
    const mistate = @fieldParentPtr(ModeIndicatorState, "nwl", output.state);
    if (output.scale > mistate.scale) {
        mistate.scale = output.scale;
    }
    createBindSurface(mistate, output) catch |err| {
        std.log.err("error creating surface: {s}", .{@errorName(err)});
    };
}

fn handleDestroyOutput(output:*nwl.Output) callconv(.C) void {
    var it = output.state.surfaces.iterator();
    while (it.next()) |surf| {
        if (surf.userdata == @ptrCast(*anyopaque, output)) {
            surf.destroyLater();
            break;
        }
    }
    var oit = output.state.outputs.iterator();
    const mistate = @fieldParentPtr(ModeIndicatorState, "nwl", output.state);
    mistate.scale = 1;
    while (oit.next()) |o| {
        if (o == output) {
            continue;
        }
        if (o.scale > mistate.scale) {
            mistate.scale = o.scale;
        }
    }
}

const SwayBindMode = struct {
    change:[:0]const u8
};
const SwayMsg = struct {
    content:[]u8,
    msgtype:swayipc.IpcMsgType
};

fn handleSwayMsg(state:*nwl.State, data:?*const anyopaque) callconv(.C) void {
    var mistate = @fieldParentPtr(ModeIndicatorState, "nwl", state);
    var arena = std.heap.ArenaAllocator.init(mistate.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();
    // uring passes msg in data
    var msg = blk: {
        if (use_uring) {
            break :blk @ptrCast(*const SwayMsg, @alignCast(@alignOf(*SwayMsg), data));
        } else {
            break :blk mistate.sway.readMsg(allocator) catch |err| {
                std.log.err("failed parsing sway msg: {s}", .{@errorName(err)});
                return;
            };
        }
    };
    var tok = std.json.TokenStream.init(msg.content);
    const mode = std.json.parse(SwayBindMode, &tok, .{.allocator = allocator, .ignore_unknown_fields = true}) catch return;
    if (mistate.rec_surface != null) {
        c.cairo_surface_destroy(mistate.rec_surface);
        mistate.rec_surface = null;
    }
    mistate.cur_buffer = null;
    std.log.info("switch to mode {s}", .{mode.change});
    if (!std.mem.eql(u8, mode.change, "default")) {
        mistate.rec_surface = c.cairo_recording_surface_create(c.CAIRO_CONTENT_COLOR_ALPHA, null);
        renderSurface(mistate.rec_surface.?, mode.change);
    }
    var rect:c.cairo_rectangle_t = undefined;
    if (mistate.rec_surface != null) {
        c.cairo_recording_surface_ink_extents(mistate.rec_surface, &rect.x, &rect.y, &rect.width, &rect.height);
    }
    var it = state.surfaces.iterator();
    while (it.next()) |surf| {
        if (mistate.rec_surface != null) {
            surf.setSize(@floatToInt(u32, @floor(rect.width)), 32);
            // Force slam the width here, to work around nwl
            surf.width = surf.desired_width;
        }
        surf.setNeedDraw(false);
    }
}

fn multishotPoll(uring:*std.os.linux.IO_Uring, fd:std.os.fd_t, poll_mask:u32, data:u64) !void {
    var sqe = try uring.poll_add(data, fd, poll_mask);
    sqe.len = std.os.linux.IORING_POLL_ADD_MULTI;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var mistate = ModeIndicatorState{
        .allocator = gpa.allocator(),
        .sway = try swayipc.connect(null),
        .nwl = .{
            .xdg_app_id = "bindindicator",
            .events = .{
                .output_new = handleNewOutput,
                .output_destroy = handleDestroyOutput
            },
            .run_with_zero_surfaces = true,
        }
    };
    defer _ = gpa.deinit();
    try mistate.sway.sendMsg(.MsgSubscribe, "[\"mode\"]");
    try mistate.nwl.waylandInit();
    defer mistate.nwl.waylandUninit();
    std.log.info("using {s} event loop", .{if (use_uring) "uring" else "nwl_poll"});
    if (use_uring) {
        var ring = try std.os.linux.IO_Uring.init(8, 0);
        defer ring.deinit();
        try multishotPoll(&ring, mistate.nwl.getFd(), std.os.POLL.IN, 0);
        // todo: use provided buffer with a multishot recv.
        var readbuf:[512]u8 = undefined;
        var buf = std.os.linux.IO_Uring.RecvBuffer{
            .buffer = &readbuf
        };
        while (mistate.nwl.num_surfaces > 0) {
            _ = try ring.recv(1, mistate.sway.stream.handle, buf, 0);
            _ = mistate.nwl.wl.display.?.flush();
            _ = try ring.submit_and_wait(1);
            const numevents = ring.cq_ready();
            if (numevents > 0) {
                var cqes:[8]std.os.linux.io_uring_cqe = undefined;
                const numcopied = try ring.copy_cqes(&cqes, 0);
                for (cqes[0..numcopied]) |cqe| {
                    if (cqe.err() != .SUCCESS) {
                        break;
                    }
                    switch (cqe.user_data) {
                        0 => _ = mistate.nwl.dispatch(0),
                        1 => {
                            const header = try swayipc.parseHeader(&readbuf);
                            const msg = SwayMsg{
                                .msgtype = header.msgtype,
                                .content = readbuf[14.. header.length+14]
                            };
                            handleSwayMsg(&mistate.nwl, &msg);
                        },
                        else => unreachable,
                    }
                }
            }
        }
    } else {
        mistate.nwl.addFd(mistate.sway.stream.handle, handleSwayMsg, null);
        mistate.nwl.run();
    }
}