// SPDX-License-Identifier: CC0-1.0

//! Fluxion Dyn - finding a shared library at run time, and turning names into
//! function pointers.
//!
//! Three pieces:
//!
//!   `resolver`  where a name becomes a pointer, and what may act as one
//!   `library`   opening the platform's shared libraries, and one symbol at a
//!               time out of them
//!   `table`     a whole struct of function pointers, filled in by field name
//!
//! Everything an operating system will not let you link against arrives this
//! way. `d3d12.dll` is missing on Windows before 10, `libvulkan.so.1` comes
//! from a GPU driver rather than the system, `opengl32.dll` exports the
//! commands of 1997 and nothing since, and a program that imports any of those
//! symbols the ordinary way fails to start rather than falling back. So the
//! library is opened by name, every entry point is fetched by name, and the
//! program decides for itself what a missing one means.
//!
//! ```zig
//! const Entries = struct {
//!     D3D12CreateDevice: *const fn (...) callconv(dyn.system) i32,
//!     // Missing on a machine without the Graphics Tools feature, and that is
//!     // not a reason to refuse to run.
//!     D3D12GetDebugInterface: ?*const fn (...) callconv(dyn.system) i32 = null,
//! };
//!
//! var lib = try dyn.openSystem("d3d12.dll");
//! defer lib.close();
//!
//! const entries = try lib.bind(Entries);
//! ```
//!
//! **Optionality is in the type.** A plain function pointer must be found or
//! loading fails and says which one was missing; an optional one may be absent
//! and is left `null`, so the compiler makes the call site ask. That is the
//! whole version policy, and it is why one table can describe an API across
//! the versions of it a program is willing to run on.
//!
//! **A resolver is anything that answers a name.** An open `Library`, a
//! `wglGetProcAddress`, an `eglGetProcAddress`, a `vkGetInstanceProcAddr`
//! holding the instance to dispatch on, a `Chain` that tries one and then
//! another. `table.load` takes any of them, so where the entry points come
//! from is a decision the calling program makes and this library never has to
//! know.
//!
//! Nothing here allocates, and nothing here is generated: a table is an
//! ordinary struct, and loading it is a comptime walk over its fields.

const std = @import("std");
const testing = std.testing;

pub const resolver = @import("resolver.zig");
pub const library = @import("library.zig");
pub const table = @import("table.zig");

// -------------------------------------------------------------------------
// Resolving
// -------------------------------------------------------------------------

/// A function pointer of unknown signature. See `resolver`.
pub const Proc = resolver.Proc;

/// The shape most `getProcAddress` functions have. See `resolver`.
pub const GetProcAddress = resolver.GetProcAddress;

/// The convention the platform's own entry points use. See `resolver`.
pub const system = resolver.system;

// -------------------------------------------------------------------------
// Libraries
// -------------------------------------------------------------------------

/// An open shared library. See `library`.
pub const Library = library.Library;

/// A context's `getProcAddress`, with a library's exports behind it. See
/// `library`.
pub const Chain = library.Chain;

/// How this platform opens a library, if it does. See `library`.
pub const Backend = library.Backend;

/// Which one this build got. See `library`.
pub const backend = library.backend;

pub const OpenError = library.OpenError;

/// Open a library that belongs to the operating system, by bare name.
/// Shorthand for `Library.openSystem`, and the right call for `d3d12.dll`,
/// `vulkan-1.dll` and `opengl32.dll`.
pub fn openSystem(name: [:0]const u8) OpenError!Library {
    return Library.openSystem(name);
}

/// Open one library by name or path. Shorthand for `Library.open`, and the
/// right call for a library that ships beside the program.
pub fn open(path: [:0]const u8) OpenError!Library {
    return Library.open(path);
}

/// Open the first of `paths` that opens. Shorthand for `Library.openAny`.
pub fn openAny(paths: []const [:0]const u8) OpenError!Library {
    return Library.openAny(paths);
}

// -------------------------------------------------------------------------
// Tables
// -------------------------------------------------------------------------

/// How field names become symbol names. See `table`.
pub const Naming = table.Naming;

/// Whether the first letter of a field name is raised. See `table`.
pub const Capitalize = table.Capitalize;

/// What a load found. See `table`.
pub const Status = table.Status;

/// A required entry point was not there. See `table`.
pub const Error = table.Error;

/// Fill a table from a resolver, under the table's own `naming`. See `table`.
pub const load = table.load;

/// `load` with naming given at the call site. See `table`.
pub const loadWith = table.loadWith;

/// Fill a table and report rather than fail. See `table`.
pub const tryLoad = table.tryLoad;

/// `load` into a fresh table, returned by value. See `table`.
pub const bind = table.bind;

/// The first required entry point a resolver has not got. See `table`.
pub const firstMissing = table.firstMissing;

/// Has this resolver every required entry point of a table? See `table`.
pub const available = table.available;

/// The name a field resolves to. See `table`.
pub const symbolName = table.symbolName;

/// Every name a table asks for, in field order. See `table`.
pub const names = table.names;

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test {
    // Pull each module in so `zig build test` runs its tests too.
    _ = resolver;
    _ = library;
    _ = table;
}

test "the pieces compose" {
    // The whole library in one go: open something the platform certainly has,
    // describe some of what it exports, and load that description.
    if (backend == .none) return error.SkipZigTest;

    const Exports = switch (@import("builtin").os.tag) {
        .windows => struct {
            GetTickCount64: *const fn () callconv(system) u64,
            GetCurrentProcessId: *const fn () callconv(system) u32,
            // There, and deliberately not described: this table only wants to
            // know whether it exists.
            CreateFileW: ?*const anyopaque = null,
            // Not there, and allowed not to be.
            ThisWasNeverAnExport: ?*const fn () callconv(system) u64 = null,
        },
        else => struct {
            getpid: *const fn () callconv(system) i32,
            abort: ?*const anyopaque = null,
            this_was_never_an_export: ?*const fn () callconv(system) u64 = null,
        },
    };

    const name = switch (@import("builtin").os.tag) {
        .windows => "kernel32.dll",
        .macos, .ios, .tvos, .watchos, .visionos => "libSystem.B.dylib",
        else => "libc.so.6",
    };

    var lib = openSystem(name) catch return error.SkipZigTest;
    defer lib.close();

    // Every required entry point is there, so there is nothing to report.
    try testing.expectEqual(@as(?[:0]const u8, null), lib.firstMissing(Exports));

    const exports = try lib.bind(Exports);
    switch (@import("builtin").os.tag) {
        .windows => {
            try testing.expect(exports.GetTickCount64() > 0);
            try testing.expect(exports.GetCurrentProcessId() != 0);
            try testing.expect(exports.CreateFileW != null);
            try testing.expectEqual(null, exports.ThisWasNeverAnExport);
        },
        else => {
            try testing.expect(exports.getpid() != 0);
            try testing.expect(exports.abort != null);
            try testing.expectEqual(null, exports.this_was_never_an_export);
        },
    }
}

test "a table that wants more than the machine has" {
    if (backend == .none) return error.SkipZigTest;

    const TooMuch = struct {
        ThisWasNeverAnExport: *const fn () callconv(system) u64,
    };

    const name = switch (@import("builtin").os.tag) {
        .windows => "kernel32.dll",
        .macos, .ios, .tvos, .watchos, .visionos => "libSystem.B.dylib",
        else => "libc.so.6",
    };

    var lib = openSystem(name) catch return error.SkipZigTest;
    defer lib.close();

    try testing.expectError(error.SymbolNotFound, lib.bind(TooMuch));
    // Which is where a message worth printing comes from.
    try testing.expectEqualStrings("ThisWasNeverAnExport", lib.firstMissing(TooMuch).?);
}
