// SPDX-License-Identifier: CC0-1.0

//! Opening a shared library at run time, and getting entry points out of it.
//!
//! A graphics API is not a library you link against. `d3d12.dll` is absent
//! before Windows 10, `libvulkan.so.1` comes from a GPU driver, `opengl32.dll`
//! exports the commands of 1997 and nothing since. A program that imports any
//! of those the ordinary way does not start at all where one is missing: the
//! loader fails before `main`, with no way to fall back. So it asks at run
//! time instead, and decides for itself what a missing entry point means.
//!
//! ```zig
//! var lib = try Library.openSystem("vulkan-1.dll");
//! defer lib.close();
//!
//! const entry = lib.lookup(PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse
//!     return error.NotAVulkanLoader;
//! ```
//!
//! Four ways in, and the choice is about where the file may come from:
//!
//!   `openSystem`  a bare name, from the system's own directories and nowhere
//!                 else. For `vulkan-1.dll`, `opengl32.dll`, `d3d12.dll`.
//!   `open`        one name or path, searched however this platform searches.
//!                 For a library shipping beside the program: ANGLE's
//!                 `libGLESv2.dll`, a MoltenVK inside an app bundle.
//!   `openAny`     the first of a list that opens.
//!   `fromHandle`  a handle somebody else opened.
//!
//! **Why `openSystem` is not just `open` with a shorter name.** On Windows,
//! `LoadLibrary("d3d12.dll")` searches the program's own directory first, so
//! anyone who can write a file next to the executable can have it loaded with
//! the process's privileges. This is old, it has a name (DLL planting), and
//! the fix is one flag: `LOAD_LIBRARY_SEARCH_SYSTEM32`. On POSIX `dlopen`
//! already has that property. What is the same on both is the rule:
//! `openSystem` refuses a name with a path in it.
//!
//! **A `Library` is itself a resolver.** It has a `get`, so `table.load(&api,
//! &lib)` reads a whole table straight out of the export table, and `Chain`
//! puts one behind a context's `getProcAddress`.
//!
//! **Where a platform has no run-time loading** - `wasm32`, and anything else
//! `std.DynLib` does not cover - `backend` is `.none` and every entry point
//! returns `error.NotSupported`, rather than refusing to build. A program
//! there gets its entry points from somewhere else entirely.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const resolver = @import("resolver.zig");
const table = @import("table.zig");

const windows = std.os.windows;

const Proc = resolver.Proc;

/// How this platform opens a library at run time.
pub const Backend = enum {
    /// `LoadLibraryExW`, `GetProcAddress`, `FreeLibrary`, declared at the
    /// bottom of this file because `std.DynLib` does not cover Windows.
    windows,
    /// `std.DynLib`: `dlopen` where there is a libc, and a hand-rolled ELF
    /// walker where there is not.
    posix,
    /// Nothing. Not a gap in this library - the platform has no run-time
    /// loading to reach, so there is nothing to open and the entry points have
    /// to come from somewhere else.
    none,
};

/// Which one this build got. The `.posix` list is the list `std.DynLib`
/// supports; anything outside it is `.none` rather than a compile error, so
/// that a cross-platform build matrix still builds.
pub const backend: Backend = switch (builtin.os.tag) {
    .windows => .windows,
    .linux,
    .driverkit,
    .ios,
    .maccatalyst,
    .macos,
    .tvos,
    .visionos,
    .watchos,
    .freebsd,
    .netbsd,
    .openbsd,
    .dragonfly,
    .illumos,
    => .posix,
    else => .none,
};

pub const OpenError = error{
    /// Nothing opened under that name. Usually it is not installed - this is
    /// the answer on a machine with no GPU driver - but a library that fails
    /// its own initialisation arrives here too, and the platform does not say
    /// which of the two it was.
    LibraryNotFound,
    /// `openSystem` was given something that is not a bare file name: empty,
    /// too long, or with a directory separator in it.
    InvalidName,
    /// Windows only: a path longer than this library converts to UTF-16 in.
    /// Said rather than truncated: a truncated path can name a real file.
    NameTooLong,
    /// This platform has no run-time library loading at all - see `backend`.
    NotSupported,
};

/// The longest name `openSystem` takes, in bytes. A system library name is a
/// dozen characters; this is generous.
pub const max_name_len = 128;

/// The longest path `open` takes on Windows, where the name is converted to
/// UTF-16 in a buffer on the stack. Windows itself allows longer; `open` says
/// so rather than truncating.
pub const max_path_len = 1024;

/// An open shared library, and the one reference to it this value owns.
///
/// Closing it unmaps the code every entry point taken out of it points at, so
/// the order at shutdown is: let go of everything the library handed out, and
/// only then `close`.
pub const Library = struct {
    handle: Handle,
    /// The name it opened under, for when which one matters - `libMoltenVK`
    /// is a different answer from `libvulkan`. Kept rather than copied, so a
    /// path built at run time has to outlive the `Library`.
    name: [:0]const u8,

    pub const Handle = switch (backend) {
        .windows => windows.HMODULE,
        .posix => std.DynLib,
        .none => noreturn,
    };

    /// Open one library by name or path, searched however this platform
    /// searches. For a library that ships with the program; for one that
    /// belongs to the system, `openSystem` is the safer call.
    pub fn open(path: [:0]const u8) OpenError!Library {
        switch (backend) {
            .none => return error.NotSupported,
            .windows => {
                const handle = try loadWide(path, 0);
                return .{ .handle = handle, .name = path };
            },
            .posix => {
                const handle = std.DynLib.openZ(path.ptr) catch return error.LibraryNotFound;
                return .{ .handle = handle, .name = path };
            },
        }
    }

    /// Open the first of `paths` that opens. `LibraryNotFound` only when none
    /// of them does - which is how a platform with a versioned name, an
    /// unversioned symlink and a fallback is handled in one call.
    pub fn openAny(paths: []const [:0]const u8) OpenError!Library {
        if (backend == .none) return error.NotSupported;
        for (paths) |path| {
            return open(path) catch continue;
        }
        return error.LibraryNotFound;
    }

    /// Open a library that belongs to the operating system, by bare name, from
    /// the system's own directories and nowhere else - see the module comment.
    /// A name with a directory separator is `error.InvalidName` everywhere.
    ///
    /// The system keeps one module per process and counts references, so a
    /// second open is cheap and gives the same handle - and needs its `close`.
    pub fn openSystem(name: [:0]const u8) OpenError!Library {
        if (name.len == 0 or name.len > max_name_len) return error.InvalidName;
        for (name) |char| {
            if (char == '\\' or char == '/' or char == ':') return error.InvalidName;
        }

        switch (backend) {
            .none => return error.NotSupported,
            .windows => {
                const handle = try loadWide(name, search_system32);
                return .{ .handle = handle, .name = name };
            },
            // `dlopen` of a bare name already consults the configured search
            // paths and never the program's own directory.
            .posix => {
                const handle = std.DynLib.openZ(name.ptr) catch return error.LibraryNotFound;
                return .{ .handle = handle, .name = name };
            },
        }
    }

    /// Wrap a handle that came from somewhere else - a `LoadLibraryEx` with
    /// flags this module does not offer, or a module already in the process.
    ///
    /// `close` frees it either way, so only wrap a handle whose reference this
    /// `Library` is meant to own. A `GetModuleHandle` result is not one.
    pub fn fromHandle(handle: Handle, name: [:0]const u8) Library {
        return .{ .handle = handle, .name = name };
    }

    /// Drop this reference. Every entry point the library handed out dies with
    /// the last one, so nothing may be called afterwards.
    pub fn close(self: *Library) void {
        switch (backend) {
            // Unreachable: with no backend there is no way to have opened one.
            .none => unreachable,
            .windows => _ = FreeLibrary(self.handle),
            .posix => self.handle.close(),
        }
        self.* = undefined;
    }

    /// One exported symbol, untyped, or null if the library has not got it.
    /// This is the `get` that makes a `Library` a resolver.
    pub fn get(self: *Library, name: [*:0]const u8) ?Proc {
        return switch (backend) {
            .none => unreachable,
            .windows => blk: {
                const symbol = GetProcAddress(self.handle, name) orelse break :blk null;
                // `FARPROC` is an opaque pointer and carries no alignment,
                // while a function pointer on ARM64 wants four. The assertion
                // holds: the loader will not hand back an entry point the
                // processor cannot jump to.
                break :blk @ptrCast(@alignCast(symbol));
            },
            .posix => self.handle.lookup(Proc, std.mem.span(name)),
        };
    }

    /// One exported symbol as the type you say it is, or null.
    ///
    /// Nothing checks `T` against what the library exports, so a wrong
    /// signature here is a corrupt stack later and worth reading twice. By
    /// name, never by ordinal: ordinals move between releases.
    pub fn lookup(self: *Library, comptime T: type, symbol: [:0]const u8) ?T {
        const found = self.get(symbol.ptr) orelse return null;
        return @ptrCast(found);
    }

    /// Resolve a whole table of entry points in one call. See `table`, which
    /// this hands straight to: the field names are the symbol names, and an
    /// optional field is one the library is allowed not to have.
    pub fn bind(self: *Library, comptime Table: type) table.Error!Table {
        return table.bind(Table, self);
    }

    /// The name of the first required entry of `Table` this library does not
    /// export, or null if it exports them all. For turning a `bind` failure
    /// into a message that says what is actually wrong with the machine.
    pub fn firstMissing(self: *Library, comptime Table: type) ?[:0]const u8 {
        return table.firstMissing(Table, self);
    }
};

/// A context's `getProcAddress` first, a library's exports second.
///
/// On Windows this is not an optimisation. `wglGetProcAddress` returns null
/// for everything that was in OpenGL 1.1 - `glClear`, `glViewport`,
/// `glDrawArrays`, the ones every frame calls - because those are exported
/// from `opengl32.dll` directly. Asking only the context leaves a table full
/// of holes in the oldest and most-used commands.
///
/// ```zig
/// var opengl32 = try Library.openSystem("opengl32.dll");
/// defer opengl32.close();
///
/// var chain: Chain = .{ .context = wglGetProcAddress, .library = &opengl32 };
/// try table.load(&api, &chain);
/// ```
///
/// Elsewhere the fallback is harmless: GLX and EGL answer for everything they
/// know, so the chain never reaches its second link. Both links are optional,
/// which is how a program says "just the library" or "just the context".
pub const Chain = struct {
    /// What the window system gave you: `wglGetProcAddress`,
    /// `glXGetProcAddressARB`, `eglGetProcAddress`.
    context: ?resolver.GetProcAddress = null,
    /// The library to fall back to, still open for as long as the chain is
    /// used.
    library: ?*Library = null,

    /// The `get` that makes this a resolver.
    pub fn get(self: Chain, name: [*:0]const u8) ?Proc {
        if (self.context) |from_context| {
            if (from_context(name)) |proc| return proc;
        }
        if (self.library) |from_library| return from_library.get(name);
        return null;
    }
};

// -------------------------------------------------------------------------
// Windows
// -------------------------------------------------------------------------
//
// `std.DynLib` covers POSIX and stops there, so Windows gets the three calls
// it needs declared here. Nothing else in this library is platform-specific.

/// `LOAD_LIBRARY_SEARCH_SYSTEM32`: look in the system directory and stop.
const search_system32: u32 = 0x00000800;

/// The conversion both Windows paths share.
///
/// Checked before converting rather than after: `utf8ToUtf16Le` writes as it
/// goes and would run off the end. A UTF-8 string never needs more UTF-16
/// units than it has bytes - a surrogate pair costs two units and four bytes -
/// so its length is a sound bound, with one more for the terminator.
fn loadWide(path: [:0]const u8, flags: u32) OpenError!windows.HMODULE {
    var wide: [max_path_len]u16 = undefined;
    if (path.len + 1 > wide.len) return error.NameTooLong;
    const len = std.unicode.utf8ToUtf16Le(&wide, path) catch return error.LibraryNotFound;
    wide[len] = 0;
    return LoadLibraryExW(wide[0..len :0].ptr, null, flags) orelse error.LibraryNotFound;
}

extern "kernel32" fn LoadLibraryExW(
    lpLibFileName: [*:0]const u16,
    hFile: ?windows.HANDLE,
    dwFlags: u32,
) callconv(.winapi) ?windows.HMODULE;

extern "kernel32" fn GetProcAddress(
    hModule: windows.HMODULE,
    lpProcName: [*:0]const u8,
) callconv(.winapi) ?*const anyopaque;

extern "kernel32" fn FreeLibrary(
    hLibModule: windows.HMODULE,
) callconv(.winapi) windows.BOOL;

// -------------------------------------------------------------------------
// Tests
//
// Against whatever library this platform is guaranteed to have already: on
// Windows `kernel32.dll`, which is in every process there has ever been. Where
// there is no such guarantee the test skips rather than failing, because a
// missing libc says nothing about the code under test.
// -------------------------------------------------------------------------

/// A library every process on this platform already has, and one symbol it
/// certainly exports.
const known = switch (builtin.os.tag) {
    .windows => .{ .name = "kernel32.dll", .symbol = "GetTickCount64" },
    .macos, .ios, .tvos, .watchos, .visionos => .{ .name = "libSystem.B.dylib", .symbol = "getpid" },
    else => .{ .name = "libc.so.6", .symbol = "getpid" },
};

fn openKnown() !Library {
    if (backend == .none) return error.SkipZigTest;
    return Library.openSystem(known.name) catch error.SkipZigTest;
}

test "opening a system library and calling something out of it" {
    var lib = try openKnown();
    defer lib.close();

    const call = lib.lookup(*const fn () callconv(resolver.system) u64, known.symbol).?;
    try testing.expect(call() != 0);
}

test "a symbol that is not there is null, not a crash" {
    var lib = try openKnown();
    defer lib.close();

    try testing.expect(lib.get("fluxion_dyn_no_such_export") == null);
    try testing.expectEqual(
        @as(?*const fn () callconv(resolver.system) u64, null),
        lib.lookup(*const fn () callconv(resolver.system) u64, "fluxion_dyn_no_such_export"),
    );
}

test "a library that is not there" {
    if (backend == .none) return error.SkipZigTest;

    // Not an assertion about this machine: no platform loads a library under
    // this name, whatever happens to be installed on it.
    try testing.expectError(
        error.LibraryNotFound,
        Library.open("fluxion-dyn-no-such-library-0000"),
    );
    try testing.expectError(error.LibraryNotFound, Library.openAny(&.{
        "fluxion-dyn-no-such-library-0000.so",
        "fluxion-dyn-no-such-library-0000.dll",
    }));
}

test "openSystem refuses anything that is not a bare name" {
    // Each of these would either bypass the system-only search or be taken
    // literally, and quietly loading the wrong file is the failure worth
    // preventing.
    try testing.expectError(error.InvalidName, Library.openSystem("C:\\Windows\\System32\\kernel32.dll"));
    try testing.expectError(error.InvalidName, Library.openSystem("..\\kernel32.dll"));
    try testing.expectError(error.InvalidName, Library.openSystem("/usr/lib/libc.so.6"));
    try testing.expectError(error.InvalidName, Library.openSystem("sub/libc.so.6"));
    try testing.expectError(error.InvalidName, Library.openSystem(""));
    try testing.expectError(error.InvalidName, Library.openSystem("x" ** (max_name_len + 1)));
}

test "a path too long to convert is refused rather than truncated" {
    // Windows is the only platform that converts the path at all, and the one
    // place a fixed buffer could be overrun.
    if (backend != .windows) return error.SkipZigTest;

    // The buffer holds the path and a terminator, so the longest that fits is
    // one shorter than the buffer - and one past that is refused.
    try testing.expectError(error.NameTooLong, Library.open("x" ** max_path_len));
    try testing.expectError(error.LibraryNotFound, Library.open("x" ** (max_path_len - 1)));
}

test "the module is shared and counted" {
    // Two opens of one library are one module: the operating system keeps a
    // table per process and hands back the same handle with the count raised.
    // Which is why each open needs its own close, and why closing one of them
    // leaves the other perfectly usable.
    if (backend != .windows) return error.SkipZigTest;

    var first = try openKnown();
    defer first.close();

    var second = try openKnown();
    try testing.expectEqual(first.handle, second.handle);
    second.close();

    try testing.expect(first.get(known.symbol) != null);
}

test "a library is a resolver, and a chain puts one behind another" {
    const Context = struct {
        fn get(name: [*:0]const u8) callconv(resolver.system) ?Proc {
            if (std.mem.eql(u8, std.mem.span(name), "only_from_the_context")) {
                return @ptrCast(&stub);
            }
            return null;
        }
        fn stub() callconv(.c) void {}
    };

    // With neither link there is nothing to ask, and that is not a crash.
    const empty: Chain = .{};
    try testing.expect(empty.get("anything") == null);

    const context_only: Chain = .{ .context = Context.get };
    try testing.expect(context_only.get("only_from_the_context") != null);
    try testing.expect(context_only.get(known.symbol) == null);

    var lib = try openKnown();
    defer lib.close();

    // And with a library behind it, the symbol the context has not got is
    // found anyway - which is the whole point on Windows.
    const chain: Chain = .{ .context = Context.get, .library = &lib };
    try testing.expect(chain.get("only_from_the_context") != null);
    try testing.expect(chain.get(known.symbol) != null);
    try testing.expect(chain.get("fluxion_dyn_no_such_export") == null);
}
