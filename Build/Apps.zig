const std = @import("std");
const Build = std.Build;
const Self = @This();

step: Build.Step,
output_apps: []Build.LazyPath,

pub const App = struct {
    name: []const u8,
    type: union(enum) {
        /// c application
        c,
        /// zig application
        link_c: bool,
    },
};

pub const AppOptions = struct {
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .Debug,
    strip: ?bool = null,
    omit_frame_pointer: ?bool = false,
    kernel_module: *Build.Module,
};

pub fn create(owner: *Build, apps: []const App, options: AppOptions) *Self {
    const self = owner.allocator.create(Self) catch @panic("OOM");
    const output_apps = owner.allocator.alloc(Build.LazyPath, apps.len) catch @panic("OOM");
    self.* = .{
        .step = Build.Step.init(.{
            .id = .custom,
            .name = "Build User Applications",
            .owner = owner,
        }),
        .output_apps = output_apps,
    };

    const usys_obj = owner.addObject(.{
        .name = "usys",
        .root_source_file = .{ .path = "user/usys.zig" },
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip,
        .omit_frame_pointer = options.omit_frame_pointer,
    });
    usys_obj.root_module.addImport("kernel", options.kernel_module);

    for (apps, 0..) |app, i| {
        const exe = owner.addExecutable(.{
            .name = app.name,
            .root_source_file = if (app.type == .c)
                null
            else
                .{ .path = owner.fmt("{s}{s}{s}", .{ "user/", app.name, ".zig" }) },
            .target = options.target,
            .optimize = options.optimize,
            .strip = options.strip,
            .omit_frame_pointer = options.omit_frame_pointer,
        });

        if (app.type == .c) {
            exe.addIncludePath(.{ .path = "./" });
            exe.addObject(usys_obj);
            exe.addCSourceFiles(.{
                .files = &.{
                    owner.fmt("{s}{s}{s}", .{ "user/", app.name, ".c" }),
                    "user/ulib.c",
                    "user/printf.c",
                    "user/umalloc.c",
                },
            });
        } else {
            if (app.type.link_c) {
                exe.addIncludePath(.{ .path = "./" });
                exe.addCSourceFile(.{
                    .file = .{ .path = "user/umalloc.c" },
                    .flags = &.{},
                });
            }
            exe.root_module.addImport("kernel", options.kernel_module);
        }

        exe.root_module.code_model = .medium;
        exe.entry = .{ .symbol_name = "main" };
        exe.setLinkerScript(.{ .path = "user/app.ld" });

        const install_app = owner.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "apps/" } },
        });

        self.step.dependOn(&install_app.step);
        self.output_apps[i] = exe.getEmittedBin();
    }

    return self;
}

pub fn getOutput(self: *Self) []Build.LazyPath {
    return self.output_apps;
}
