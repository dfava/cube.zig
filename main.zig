const std = @import("std");
const core = @import("core");
const gpu = core.gpu;
const zm = @import("zmath");
const Vertex = @import("cube_mesh.zig").Vertex;
const vertices = @import("cube_mesh.zig").vertices;
const expect = @import("std").testing.expect;

const Vec3 = @Vector(3, f32);

pub const App = @This();

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const UniformBufferObject = struct {
    mat: zm.Mat,
};

timer: core.Timer,
pipeline: *gpu.RenderPipeline,
vertex_buffer: *gpu.Buffer,
uniform_buffer: *gpu.Buffer,
bind_group: *gpu.BindGroup,
direction: Vec3,
rotate: Vec3,
stepGranularity: f32,
state: KeyboardAnimationState,
prevState: KeyboardAnimationState,
animationIteration: f32,

const KeyboardAnimationState = enum {
    Initial,
    ShiftPressed,
    MoveKeyPressed,
    StartAnimation,
    Animating,

    pub fn print(self: KeyboardAnimationState) void {
        switch (self) {
            KeyboardAnimationState.Initial => std.debug.print("{s}", .{"Initial"}),
            KeyboardAnimationState.ShiftPressed => std.debug.print("{s}", .{"ShiftPressed"}),
            KeyboardAnimationState.MoveKeyPressed => std.debug.print("{s}", .{"MoveKeyPressed"}),
            KeyboardAnimationState.StartAnimation => std.debug.print("{s}", .{"StartAnimation"}),
            KeyboardAnimationState.Animating => std.debug.print("{s}", .{"Animating"}),
        }
    }
};

pub fn init(app: *App) !void {
    try core.init(.{});

    const shader_module = core.device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));

    const vertex_attributes = [_]gpu.VertexAttribute{
        .{ .format = .float32x4, .offset = @offsetOf(Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "uv"), .shader_location = 1 },
    };
    const vertex_buffer_layout = gpu.VertexBufferLayout.init(.{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attributes = &vertex_attributes,
    });

    const blend = gpu.BlendState{};
    const color_target = gpu.ColorTargetState{
        .format = core.descriptor.format,
        .blend = &blend,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };
    const fragment = gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "frag_main",
        .targets = &.{color_target},
    });

    const bgle = gpu.BindGroupLayout.Entry.buffer(0, .{ .vertex = true }, .uniform, true, 0);
    const bgl = core.device.createBindGroupLayout(
        &gpu.BindGroupLayout.Descriptor.init(.{
            .entries = &.{bgle},
        }),
    );

    const bind_group_layouts = [_]*gpu.BindGroupLayout{bgl};
    const pipeline_layout = core.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .bind_group_layouts = &bind_group_layouts,
    }));

    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .fragment = &fragment,
        .layout = pipeline_layout,
        .vertex = gpu.VertexState.init(.{
            .module = shader_module,
            .entry_point = "vertex_main",
            .buffers = &.{vertex_buffer_layout},
        }),
        .primitive = .{
            .cull_mode = .back,
        },
    };

    const vertex_buffer = core.device.createBuffer(&.{
        .usage = .{ .vertex = true },
        .size = @sizeOf(Vertex) * vertices.len,
        .mapped_at_creation = true,
    });
    var vertex_mapped = vertex_buffer.getMappedRange(Vertex, 0, vertices.len);
    std.mem.copy(Vertex, vertex_mapped.?, vertices[0..]);
    vertex_buffer.unmap();

    const uniform_buffer = core.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = @sizeOf(UniformBufferObject),
        .mapped_at_creation = false,
    });
    const bind_group = core.device.createBindGroup(
        &gpu.BindGroup.Descriptor.init(.{
            .layout = bgl,
            .entries = &.{
                gpu.BindGroup.Entry.buffer(0, uniform_buffer, 0, @sizeOf(UniformBufferObject)),
            },
        }),
    );

    app.direction = Vec3{ 0, 0, 0 };
    app.rotate = Vec3{ 0, 0, 0 };
    app.stepGranularity = 1000.0;
    app.timer = try core.Timer.start();
    app.pipeline = core.device.createRenderPipeline(&pipeline_descriptor);
    app.vertex_buffer = vertex_buffer;
    app.uniform_buffer = uniform_buffer;
    app.bind_group = bind_group;
    app.state = KeyboardAnimationState.Initial;
    app.prevState = KeyboardAnimationState.Initial;
    app.animationIteration = 0;

    shader_module.release();
    pipeline_layout.release();
    bgl.release();
}

pub fn reset(app: *App) void {
    app.direction = Vec3{ 0, 0, 0 };
    app.rotate = Vec3{ 0, 0, 0 };
}

pub fn deinit(app: *App) void {
    defer _ = gpa.deinit();
    defer core.deinit();

    app.vertex_buffer.release();
    app.uniform_buffer.release();
    app.bind_group.release();
}

pub fn transition(state: KeyboardAnimationState, event: core.Event) KeyboardAnimationState {
    switch (event) {
        .key_press => |ev| {
            switch (ev.key) {
                .left_shift => {
                    switch (state) {
                        KeyboardAnimationState.Initial => return KeyboardAnimationState.ShiftPressed,
                        KeyboardAnimationState.MoveKeyPressed => return KeyboardAnimationState.StartAnimation,
                        else => return state,
                    }
                },
                .w, .s, .d, .a, .q, .e => {
                    switch (state) {
                        KeyboardAnimationState.Initial => return KeyboardAnimationState.MoveKeyPressed,
                        KeyboardAnimationState.ShiftPressed => return KeyboardAnimationState.StartAnimation,
                        else => return state,
                    }
                },
                else => return state,
            }
        },
        .key_release => |ev| {
            switch (ev.key) {
                .left_shift => {
                    switch (state) {
                        KeyboardAnimationState.ShiftPressed => return KeyboardAnimationState.Initial,
                        KeyboardAnimationState.StartAnimation => return KeyboardAnimationState.MoveKeyPressed,
                        else => return state,
                    }
                },
                .w, .s, .d, .a, .q, .e => {
                    switch (state) {
                        KeyboardAnimationState.MoveKeyPressed => return KeyboardAnimationState.Initial,
                        KeyboardAnimationState.StartAnimation => return KeyboardAnimationState.ShiftPressed,
                        else => return state,
                    }
                },
                else => return state,
            }
        },
        else => return state,
    }
}

pub fn update(app: *App) !bool {
    var exit = readInput(app);
    if (exit) {
        return true;
    }

    if (app.state == KeyboardAnimationState.StartAnimation) {
        app.animationIteration = app.stepGranularity;
        app.state = KeyboardAnimationState.Animating;
    }

    while (true) {
        draw(app);
        if (app.state == KeyboardAnimationState.Animating) {
            app.animationIteration -= 1;
            if (app.animationIteration <= 0) {
                app.state = app.prevState;
            }
        } else {
            break;
        }
    }
    return false;
}

pub fn readInput(app: *App) bool {
    var iter = core.pollEvents();
    while (iter.next()) |event| {
        app.prevState = app.state;
        app.state = transition(app.state, event); // TODO: Make this atomic
        app.state.print();
        switch (event) {
            .key_press => |ev| {
                switch (ev.key) {
                    .space => return true,
                    .w => app.rotate[0] = 1,
                    .s => app.rotate[0] = -1,
                    .d => app.rotate[2] = 1,
                    .a => app.rotate[2] = -1,
                    .q => app.rotate[1] = 1,
                    .e => app.rotate[1] = -1,
                    .r => reset(app),
                    else => {},
                }
            },
            .key_release => |ev| {
                switch (ev.key) {
                    .w => app.rotate[0] = 0,
                    .s => app.rotate[0] = 0,
                    .d => app.rotate[2] = 0,
                    .a => app.rotate[2] = 0,
                    .q => app.rotate[1] = 0,
                    .e => app.rotate[1] = 0,
                    else => {},
                }
            },
            .close => return true,
            else => {},
        }
    }
    return false;
}

pub fn draw(app: *App) void {
    const back_buffer_view = core.swap_chain.getCurrentTextureView().?;
    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .clear_value = std.mem.zeroes(gpu.Color),
        .load_op = .clear,
        .store_op = .store,
    };

    const encoder = core.device.createCommandEncoder(null);
    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .color_attachments = &.{color_attachment},
    });

    {
        app.direction[0] += (std.math.pi * 0.5) * app.rotate[0] / app.stepGranularity;
        app.direction[1] += (std.math.pi * 0.5) * app.rotate[1] / app.stepGranularity;
        app.direction[2] += (std.math.pi * 0.5) * app.rotate[2] / app.stepGranularity;
        const model = zm.mul(zm.mul(zm.rotationX(app.direction[0]), zm.rotationZ(app.direction[2])), zm.rotationY(app.direction[1]));
        const view = zm.lookAtRh(
            zm.Vec{ 0, 4, 2, 1 },
            zm.Vec{ 0, 0, 0, 1 },
            zm.Vec{ 0, 0, 1, 0 },
        );
        const proj = zm.perspectiveFovRh(
            (std.math.pi / 4.0),
            @as(f32, @floatFromInt(core.descriptor.width)) / @as(f32, @floatFromInt(core.descriptor.height)),
            0.1,
            10,
        );
        const mvp = zm.mul(zm.mul(model, view), proj);
        const ubo = UniformBufferObject{
            .mat = zm.transpose(mvp),
        };
        encoder.writeBuffer(app.uniform_buffer, 0, &[_]UniformBufferObject{ubo});
    }

    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setPipeline(app.pipeline);
    pass.setVertexBuffer(0, app.vertex_buffer, 0, @sizeOf(Vertex) * vertices.len);
    pass.setBindGroup(0, app.bind_group, &.{0});
    pass.draw(vertices.len, 1, 0, 0);
    pass.end();
    pass.release();

    var command = encoder.finish(null);
    encoder.release();

    const queue = core.queue;
    queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
    core.swap_chain.present();
    back_buffer_view.release();
}
