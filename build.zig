const std = @import("std");

pub const Routes = @import("src/Routes.zig");
pub const GenerateMimeTypes = @import("src/GenerateMimeTypes.zig");
pub const TemplateFn = @import("src/jetzig.zig").TemplateFn;
pub const StaticRequest = @import("src/jetzig.zig").StaticRequest;
pub const http = @import("src/jetzig/http.zig");
pub const data = @import("src/jetzig/data.zig");
pub const views = @import("src/jetzig/views.zig");
pub const Route = views.Route;
pub const Job = @import("src/jetzig.zig").Job;

const zmpl_build = @import("zmpl");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const templates_paths = try zmpl_build.templatesPaths(
        b.allocator,
        &.{
            .{ .prefix = "views", .path = &.{ "src", "app", "views" } },
            .{ .prefix = "mailers", .path = &.{ "src", "app", "mailers" } },
        },
    );

    const lib = b.addStaticLibrary(.{
        .name = "jetzig",
        .root_source_file = b.path("src/jetzig.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mime_module = try GenerateMimeTypes.generateMimeModule(b);

    const zig_args_dep = b.dependency("args", .{ .target = target, .optimize = optimize });
    const jetzig_module = b.addModule("jetzig", .{ .root_source_file = b.path("src/jetzig.zig") });
    jetzig_module.addImport("mime_types", mime_module);
    lib.root_module.addImport("jetzig", jetzig_module);

    const zmpl_dep = b.dependency(
        "zmpl",
        .{
            .target = target,
            .optimize = optimize,
            .zmpl_templates_paths = templates_paths,
            .zmpl_auto_build = false,
            .zmpl_markdown_fragments = try generateMarkdownFragments(b),
            .zmpl_constants = try zmpl_build.addTemplateConstants(b, struct {
                jetzig_view: []const u8,
                jetzig_action: []const u8,
            }),
        },
    );

    const zmpl_module = zmpl_dep.module("zmpl");

    const jetkv_dep = b.dependency("jetkv", .{ .target = target, .optimize = optimize });
    const zmd_dep = b.dependency("zmd", .{ .target = target, .optimize = optimize });
    const httpz_dep = b.dependency("httpz", .{ .target = target, .optimize = optimize });

    // This is the way to make it look nice in the zig build script
    // If we would do it the other way around, we would have to do
    // b.dependency("jetzig",.{}).builder.dependency("zmpl",.{}).module("zmpl");
    b.modules.put("zmpl", zmpl_dep.module("zmpl")) catch @panic("Out of memory");
    b.modules.put("zmd", zmd_dep.module("zmd")) catch @panic("Out of memory");

    const smtp_client_dep = b.dependency("smtp_client", .{
        .target = target,
        .optimize = optimize,
    });

    lib.root_module.addImport("zmpl", zmpl_module);
    jetzig_module.addImport("zmpl", zmpl_module);
    jetzig_module.addImport("args", zig_args_dep.module("args"));
    jetzig_module.addImport("zmd", zmd_dep.module("zmd"));
    jetzig_module.addImport("jetkv", jetkv_dep.module("jetkv"));
    jetzig_module.addImport("smtp", smtp_client_dep.module("smtp_client"));
    jetzig_module.addImport("httpz", httpz_dep.module("httpz"));

    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const docs_step = b.step("docs", "Generate documentation");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    docs_step.dependOn(&docs_install.step);

    main_tests.root_module.addImport("zmpl", zmpl_dep.module("zmpl"));
    main_tests.root_module.addImport("jetkv", jetkv_dep.module("jetkv"));
    main_tests.root_module.addImport("httpz", httpz_dep.module("httpz"));
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}

/// Build-time options for Jetzig.
pub const JetzigInitOptions = struct {
    zmpl_version: enum { v1, v2 } = .v2,
};

pub fn jetzigInit(b: *std.Build, exe: *std.Build.Step.Compile, options: JetzigInitOptions) !void {
    if (options.zmpl_version == .v1) {
        std.debug.print("Zmpl v1 has now been removed. Please upgrade to v2.\n", .{});
        return error.ZmplVersionNotSupported;
    }

    const target = b.host;
    const optimize = exe.root_module.optimize orelse .Debug;

    if (optimize != .Debug) exe.linkLibC();

    const jetzig_dep = b.dependency(
        "jetzig",
        .{ .optimize = optimize, .target = target },
    );
    const jetzig_module = jetzig_dep.module("jetzig");
    const zmpl_module = jetzig_dep.module("zmpl");
    const zmd_module = jetzig_dep.module("zmd");

    exe.root_module.addImport("jetzig", jetzig_module);
    exe.root_module.addImport("zmpl", zmpl_module);
    exe.root_module.addImport("zmd", zmd_module);

    if (b.option(bool, "jetzig_runner", "Used internally by `jetzig server` command.")) |jetzig_runner| {
        if (jetzig_runner) {
            const file = try std.fs.cwd().createFile(".jetzig", .{ .truncate = true });
            defer file.close();
            try file.writeAll(exe.name);
        }
    }

    const root_path = b.build_root.path orelse try std.fs.cwd().realpathAlloc(b.allocator, ".");
    const templates_path: []const u8 = try std.fs.path.join(
        b.allocator,
        &[_][]const u8{ root_path, "src", "app" },
    );
    const views_path: []const u8 = try std.fs.path.join(
        b.allocator,
        &[_][]const u8{ root_path, "src", "app", "views" },
    );
    const jobs_path = try std.fs.path.join(
        b.allocator,
        &[_][]const u8{ root_path, "src", "app", "jobs" },
    );
    const mailers_path = try std.fs.path.join(
        b.allocator,
        &[_][]const u8{ root_path, "src", "app", "mailers" },
    );

    var generate_routes = try Routes.init(
        b.allocator,
        root_path,
        templates_path,
        views_path,
        jobs_path,
        mailers_path,
    );
    try generate_routes.generateRoutes();
    const routes_write_files = b.addWriteFiles();
    const routes_file = routes_write_files.add("routes.zig", generate_routes.buffer.items);
    const tests_write_files = b.addWriteFiles();
    const tests_file = tests_write_files.add("tests.zig", generate_routes.buffer.items);
    const routes_module = b.createModule(.{ .root_source_file = routes_file });

    var src_dir = try std.fs.openDirAbsolute(b.pathFromRoot("src"), .{ .iterate = true });
    defer src_dir.close();
    var walker = try src_dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            const stat = try src_dir.statFile(entry.path);
            const src_data = try src_dir.readFileAlloc(b.allocator, entry.path, @intCast(stat.size));
            defer b.allocator.free(src_data);

            const relpath = try std.fs.path.join(b.allocator, &[_][]const u8{ "src", entry.path });
            defer b.allocator.free(relpath);

            _ = routes_write_files.add(relpath, src_data);
            _ = tests_write_files.add(relpath, src_data);
        }
    }

    const exe_static_routes = b.addExecutable(.{
        .name = "static",
        .root_source_file = jetzig_dep.path("src/compile_static_routes.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("routes", routes_module);

    exe_static_routes.root_module.addImport("routes", routes_module);
    exe_static_routes.root_module.addImport("jetzig", jetzig_module);
    exe_static_routes.root_module.addImport("zmpl", zmpl_module);
    exe_static_routes.root_module.addImport("jetzig_app", &exe.root_module);

    const run_static_routes_cmd = b.addRunArtifact(exe_static_routes);
    run_static_routes_cmd.expectExitCode(0);
    exe.step.dependOn(&run_static_routes_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = tests_file,
        .target = target,
        .optimize = optimize,
        .test_runner = jetzig_dep.path("src/test_runner.zig"),
    });
    exe_unit_tests.root_module.addImport("jetzig", jetzig_module);
    exe_unit_tests.root_module.addImport("__jetzig_project", &exe.root_module);

    var it = exe.root_module.import_table.iterator();
    while (it.next()) |import| {
        routes_module.addImport(import.key_ptr.*, import.value_ptr.*);
        exe_static_routes.root_module.addImport(import.key_ptr.*, import.value_ptr.*);
        exe_unit_tests.root_module.addImport(import.key_ptr.*, import.value_ptr.*);
    }

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("jetzig:test", "Run tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_static_routes_cmd.step);
    exe_unit_tests.root_module.addImport("routes", routes_module);
}

fn generateMarkdownFragments(b: *std.Build) ![]const u8 {
    const file = std.fs.cwd().openFile(b.pathJoin(&.{ "src", "main.zig" }), .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return "",
            else => return err,
        }
    };
    const stat = try file.stat();
    const source = try file.readToEndAllocOptions(b.allocator, @intCast(stat.size), null, @alignOf(u8), 0);
    if (try getMarkdownFragmentsSource(b.allocator, source)) |markdown_fragments_source| {
        return try std.fmt.allocPrint(b.allocator,
            \\const std = @import("std");
            \\const zmd = @import("zmd");
            \\
            \\{s};
            \\
        , .{markdown_fragments_source});
    } else {
        return "";
    }
}

fn getMarkdownFragmentsSource(allocator: std.mem.Allocator, source: [:0]const u8) !?[]const u8 {
    var ast = try std.zig.Ast.parse(allocator, source, .zig);
    defer ast.deinit(allocator);

    for (ast.nodes.items(.tag), 0..) |tag, index| {
        switch (tag) {
            .simple_var_decl => {
                const decl = ast.simpleVarDecl(@intCast(index));
                const identifier = ast.tokenSlice(decl.ast.mut_token + 1);
                if (std.mem.eql(u8, identifier, "markdown_fragments")) {
                    return ast.getNodeSource(@intCast(index));
                }
            },
            else => continue,
        }
    }

    return null;
}
