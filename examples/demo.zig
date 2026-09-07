// SPDX-License-Identifier: CC0-1.0

//! A tour of Fluxion Dyn. Run it with `zig build example`.
//!
//! It opens a library this platform certainly has, takes one entry point out
//! of it, then a whole table of them at once - required, optional, and one
//! asked about but never called. Then it goes looking for the graphics
//! libraries, which is what this library is really for: on any given machine
//! some of them are there and some are not, and finding out which is the whole
//! job.
//!
//! Nothing here needs a GPU, and nothing here fails for want of one.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const dyn = @import("fluxion_dyn");

/// Something every process on this platform already has, and a couple of
/// things it exports. The point of the demo is not these names - it is that
/// the program asks for them instead of linking them.
const host = switch (builtin.os.tag) {
    .windows => .{
        .library = "kernel32.dll",
        .ticks = "GetTickCount64",
    },
    .macos, .ios, .tvos, .watchos, .visionos => .{
        .library = "libSystem.B.dylib",
        .ticks = "clock",
    },
    else => .{
        .library = "libc.so.6",
        .ticks = "clock",
    },
};

/// The three graphics APIs nobody links against, under the names this platform
/// keeps them by, and the one symbol that says the file is what it claims.
const graphics: []const struct { api: []const u8, names: []const [:0]const u8, entry: [:0]const u8 } =
    switch (builtin.os.tag) {
        .windows => &.{
            .{ .api = "Direct3D 12", .names = &.{"d3d12.dll"}, .entry = "D3D12CreateDevice" },
            .{ .api = "Direct3D 11", .names = &.{"d3d11.dll"}, .entry = "D3D11CreateDevice" },
            .{ .api = "DXGI", .names = &.{"dxgi.dll"}, .entry = "CreateDXGIFactory1" },
            .{ .api = "OpenGL", .names = &.{"opengl32.dll"}, .entry = "wglGetProcAddress" },
            .{ .api = "Vulkan", .names = &.{"vulkan-1.dll"}, .entry = "vkGetInstanceProcAddr" },
        },
        .macos, .ios, .tvos, .watchos, .visionos => &.{
            .{ .api = "Vulkan", .names = &.{ "libvulkan.dylib", "libvulkan.1.dylib" }, .entry = "vkGetInstanceProcAddr" },
            .{ .api = "MoltenVK", .names = &.{"libMoltenVK.dylib"}, .entry = "vkGetInstanceProcAddr" },
            .{ .api = "OpenGL ES", .names = &.{"libGLESv2.dylib"}, .entry = "glGetString" },
        },
        else => &.{
            .{ .api = "Vulkan", .names = &.{ "libvulkan.so.1", "libvulkan.so" }, .entry = "vkGetInstanceProcAddr" },
            .{ .api = "OpenGL", .names = &.{ "libGL.so.1", "libGL.so" }, .entry = "glXGetProcAddress" },
            .{ .api = "OpenGL ES", .names = &.{ "libGLESv2.so.2", "libGLESv2.so" }, .entry = "glGetString" },
        },
    };

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    if (dyn.backend == .none) {
        try out.writeAll(
            \\This platform has no run-time library loading, so there is
            \\nothing to open. Entry points have to arrive some other way,
            \\and `table` will still load them once they do.
            \\
        );
        try out.flush();
        return;
    }

    // --- one library, one entry point -------------------------------------
    //
    // `openSystem` rather than `open`: this file belongs to the operating
    // system, so it should come from the system's own directories and from
    // nowhere a program could have a file dropped into.

    var lib = dyn.openSystem(host.library) catch |err| {
        try out.print("Could not open {s}: {t}\n", .{ host.library, err });
        try out.flush();
        return;
    };
    defer lib.close();

    try out.print("--- {s} ---\n", .{lib.name});

    const Ticks = *const fn () callconv(dyn.system) u64;
    if (lib.lookup(Ticks, host.ticks)) |ticks| {
        try out.print("{s}()  {d}\n", .{ host.ticks, ticks() });
    }

    // A symbol that is not there is null, not a crash. That is the entire
    // reason to load this way rather than link.
    try out.print(
        "{s}  {s}\n\n",
        .{ "NoSuchExportExists", if (lib.get("NoSuchExportExists") == null) "absent" else "present" },
    );

    // --- a whole table at once --------------------------------------------
    //
    // The struct is the declaration and the list of what to fetch, so the two
    // cannot fall out of step. The field's type says whether the entry point
    // is required.

    try out.writeAll("--- a table, and what the machine had ---\n");
    inline for (comptime dyn.names(Exports)) |name| try out.print("  {s}\n", .{name});

    var exports: Exports = undefined;
    const status = dyn.tryLoad(&exports, &lib, .{});
    try out.print("{f}\n", .{status});

    if (status.ok()) {
        // The optional one is an optional in the type, so the compiler makes
        // this program ask before it calls - which is the version check
        // happening where the answer matters.
        try out.print("{s:<32} {}\n", .{ optional_field, @field(exports, optional_field) != null });
        // And the probe is a pointer nobody can call, which is the point of
        // it: whether it is there is the whole question.
        try out.print("{s:<32} {}\n", .{ probe_field, @field(exports, probe_field) != null });
    }
    try out.writeByte('\n');

    // --- what the naming rules do -----------------------------------------
    //
    // All of this is comptime. A table declares its own `naming`, and these
    // are the names it would ask for.

    try out.writeAll("--- field name to symbol name ---\n");
    try out.print("  {s:<24} -> {s}\n", .{ "clear (prefix gl)", comptime dyn.symbolName("clear", .{ .prefix = "gl" }) });
    try out.print("  {s:<24} -> {s}\n", .{ "cmdDraw (prefix vk)", comptime dyn.symbolName("cmdDraw", .{ .prefix = "vk" }) });
    try out.print("  {s:<24} -> {s}\n", .{ "getDisplay (prefix egl)", comptime dyn.symbolName("getDisplay", .{ .prefix = "egl" }) });
    try out.print("  {s:<24} -> {s}\n\n", .{ "D3D12CreateDevice (none)", comptime dyn.symbolName("D3D12CreateDevice", .{}) });

    // --- the graphics libraries on this machine ---------------------------
    //
    // Which is the question this library exists to answer. None of these is
    // linked, none of them is guaranteed to be installed, and a program that
    // imported their symbols the ordinary way would not have got this far on a
    // machine missing any one of them.

    try out.writeAll("--- graphics libraries on this machine ---\n");
    for (graphics) |api| {
        var found = dyn.Library.openAny(api.names) catch {
            try out.print("  {s:<14} not installed\n", .{api.api});
            continue;
        };
        defer found.close();

        const entry = if (found.get(api.entry.ptr) != null) api.entry else "(no entry point)";
        try out.print("  {s:<14} {s:<20} {s}\n", .{ api.api, found.name, entry });
    }

    try out.writeAll(
        \\
        \\Every line above is an answer rather than a crash, which is the
        \\whole of it: the library is found at run time, every entry point is
        \\fetched by name, and a missing one is something this program gets to
        \\decide about.
        \\
    );

    try out.flush();
}

/// A few of the host library's exports, in the three shapes a field can take.
const Exports = switch (builtin.os.tag) {
    .windows => struct {
        /// Required: this program will not run without it.
        GetCurrentProcessId: *const fn () callconv(dyn.system) u32,
        /// Optional, and present since Windows 8 - so the field is how a
        /// program says it can run on Windows 7 as well.
        GetSystemTimePreciseAsFileTime: ?*const fn (*anyopaque) callconv(dyn.system) void = null,
        /// Present, and deliberately not described: whether it exists is the
        /// only question this table is asking.
        CreateFileW: ?*const anyopaque = null,

        pub const naming: dyn.Naming = .{};
    },
    else => struct {
        getpid: *const fn () callconv(dyn.system) i32,
        // Glibc has it; a musl or a BSD libc may not, so it is optional.
        gettid: ?*const fn () callconv(dyn.system) i32 = null,
        abort: ?*const anyopaque = null,

        pub const naming: dyn.Naming = .{};
    },
};

/// The two fields worth pointing at afterwards, named here so the printing
/// above does not need a switch of its own.
const optional_field = switch (builtin.os.tag) {
    .windows => "GetSystemTimePreciseAsFileTime",
    else => "gettid",
};

const probe_field = switch (builtin.os.tag) {
    .windows => "CreateFileW",
    else => "abort",
};
