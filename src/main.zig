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
    cur_buffer:?c_uint = null,
    scale:c_int = 1,
    cairo_surfaces:[4]*c.cairo_surface_t = undefined
};

fn bufferCreate(buf_idx:c_uint, bufferman:*nwl.ShmBufferMan) callconv(.C) void {
    const state = @fieldParentPtr(ModeIndicatorState, "bufferman", bufferman);
    state.cairo_surfaces[buf_idx] = c.cairo_image_surface_create_for_data(bufferman.buffers[buf_idx].bufferdata,
        c.CAIRO_FORMAT_ARGB32, @intCast(bufferman.width),
        @intCast(bufferman.height), @intCast(bufferman.stride)).?;
}

fn bufferDestroy(buf_idx:c_uint, bufferman:*nwl.ShmBufferMan) callconv(.C) void {
    const state = @fieldParentPtr(ModeIndicatorState, "bufferman", bufferman);
    c.cairo_surface_destroy(state.cairo_surfaces[buf_idx]);
}

const MultiRenderBufferImpl = nwl.ShmBufferMan.RendererImpl{
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
        const scaled_width = surface.width * @as(u32, @intCast(mistate.scale));
        const scaled_height = surface.height * @as(u32, @intCast(mistate.scale));
        if (mistate.bufferman.width != scaled_width) {
            mistate.bufferman.resize(surface.state, scaled_width, scaled_height, scaled_width*4, 0);
        }
        mistate.cur_buffer = mistate.bufferman.getNext() catch null;
        if (mistate.cur_buffer == null) {
            mistate.bufferman.setSlots(surface.state, mistate.bufferman.num_slots+1);
            mistate.cur_buffer = mistate.bufferman.getNext() catch {
                std.log.err("ARGH! CAN'T GET A BUFFER! Giving up!", .{});
                surface.state.run_with_zero_surfaces = false;
                surface.state.num_surfaces = 0;
                return;
            };
        }
        var cairo_surface = mistate.cairo_surfaces[mistate.cur_buffer.?];
        var cr = c.cairo_create(cairo_surface);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_scale(cr, @floatFromInt(mistate.scale), @floatFromInt(mistate.scale));
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
    if (mistate.cur_buffer) |buf_idx| {
        const buf = &mistate.bufferman.buffers[buf_idx];
        if (mistate.scale != surface.scale) {
            surface.scale = mistate.scale;
            surface.wl.surface.setBufferScale(surface.scale);
        }
        surface.wl.surface.attach(buf.wl_buffer, 0, 0);
        surface.wl.surface.damageBuffer(0, 0, @as(i32, @intCast(surface.width))*surface.scale, @as(i32, @intCast(surface.height))*surface.scale);
        surface.commit();
    } else {
        std.log.err("BUG BUG BUG! Swap buffers without buffer!", .{});
    }
}

const MultiSurfaceRenderImpl = nwl.Surface.Renderer.Impl {
    .apply_size = renderNoOp,
    .swap_buffers = renderSwapBuffers,
    .render = multiRenderRender,
    .destroy = renderNoOp
};

const BindModeSurface = struct {
    nwl:nwl.Surface = .{
        .renderer = .{.impl = &MultiSurfaceRenderImpl},
        .impl = .{
            .destroy = handleSurfaceDestroy
        },
        .flags = .{
            .no_autoscale = true
        }
    },
    output:*nwl.Output
};

fn handleSurfaceDestroy(surface:*nwl.Surface) callconv(.C) void {
    const state = @fieldParentPtr(ModeIndicatorState, "nwl", surface.state);
    const bindsurface = @fieldParentPtr(BindModeSurface, "nwl", surface);
    state.allocator.destroy(bindsurface);
}

fn createBindSurface(state:*ModeIndicatorState, output:*nwl.Output) !void {
    var surface = try state.allocator.create(BindModeSurface);
    surface.* = .{
        .output = output,
    };
    surface.nwl.init(&state.nwl, "bindmodeindicator");
    try surface.nwl.roleLayershell(output.output, 3);
    surface.nwl.setSize(128, 32);
    surface.nwl.role.layer.wl.setAnchor(.{.top = true, .left = true});
    var region = try surface.nwl.state.wl.compositor.?.createRegion();
    surface.nwl.wl.surface.setInputRegion(region);
    defer region.destroy();
    surface.nwl.commit();
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
        const bindsurface = @fieldParentPtr(BindModeSurface, "nwl", surf);
        if (bindsurface.output == output) {
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
    var msg:*const SwayMsg = blk: {
        if (use_uring) {
            break :blk @alignCast(@ptrCast(data));
        } else {
            break :blk mistate.sway.readMsg(allocator) catch |err| {
                std.log.err("failed parsing sway msg: {s}", .{@errorName(err)});
                return;
            };
        }
    };
    const mode = std.json.parseFromSliceLeaky(SwayBindMode, allocator, msg.content, .{.ignore_unknown_fields = true}) catch return;
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
            surf.setSize(@intFromFloat(@floor(rect.width)), 32);
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
    try mistate.sway.subscribe(&.{.EventMode});
    try mistate.nwl.waylandInit();
    defer mistate.nwl.waylandUninit();
    defer mistate.bufferman.finish();
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