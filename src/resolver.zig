// SPDX-License-Identifier: CC0-1.0

//! Where a name becomes a function pointer.
//!
//! An entry point is found either by looking the symbol up in a shared library
//! - `GetProcAddress`, `dlsym`, which is what `library.Library` does - or by
//! asking a function the API hands out: `wglGetProcAddress`,
//! `eglGetProcAddress`, `vkGetInstanceProcAddr`.
//!
//! A *resolver* is anything that answers the second kind of question, and it is
//! duck-typed on purpose so that all of these work with no adapter:
//!
//!   * a plain `getProcAddress` function, or a pointer to one
//!   * any value with a `get(name: [*:0]const u8) ?Proc` method - an open
//!     `Library`, a fallback `Chain`, a Vulkan resolver holding its instance
//!   * a pointer to one of those
//!
//! Duck-typing rather than one interface type keeps the calling convention out
//! of this library's hands: `wglGetProcAddress` is `stdcall` on 32-bit Windows
//! and `eglGetProcAddress` is `cdecl`. Passed as `anytype` and called directly,
//! each is called exactly as it was declared.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// A function pointer of unknown signature, which is all any lookup promises
/// to return.
///
/// The convention written here is a placeholder: nothing ever calls a `Proc`.
/// Each is cast to its field's type on the way into a table, and it is that
/// declaration which carries the real signature - which is why the tables in a
/// binding are worth reading twice.
pub const Proc = *const fn () callconv(.c) void;

/// The convention the platform's own entry points use: `stdcall` on Windows,
/// the C one everywhere else.
///
/// On 64-bit Windows the two are the same, so this only starts to matter on a
/// 32-bit build - which is exactly when nobody is testing. Declare tables with
/// it rather than `.c` when the API being loaded is the platform's own.
pub const system: std.builtin.CallingConvention = if (builtin.os.tag == .windows)
    .winapi
else
    .c;

/// The shape of most `getProcAddress` functions in the wild: `wglGetProcAddress`,
/// `glXGetProcAddressARB`, `eglGetProcAddress`, `glfwGetProcAddress`,
/// `SDL_GL_GetProcAddress`.
///
/// A convenience, not a requirement - see the module comment. One that takes
/// an extra handle, or uses a convention of its own, is passed as it is.
pub const GetProcAddress = *const fn (name: [*:0]const u8) callconv(system) ?Proc;

/// Ask one resolver for one name, or null if it has not got it.
///
/// A function is called; a value with a `get` method has that called. The `get`
/// has to be `pub`, since it is called from here. Anything that is neither
/// shape fails at compile time with a message naming the type.
pub fn get(from: anytype, name: [:0]const u8) ?Proc {
    const From = @TypeOf(from);
    const returned = switch (@typeInfo(From)) {
        .@"fn" => from(name.ptr),
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => from(name.ptr),
            .@"struct", .@"union", .@"enum", .@"opaque" => from.get(name.ptr),
            else => @compileError(notAResolver(From)),
        },
        .@"struct", .@"union", .@"enum" => from.get(name.ptr),
        // Worth catching by name: an unwrapped optional would be read as a
        // resolver that answers nothing, which looks exactly like an
        // implementation that has no entry points at all.
        .optional => @compileError("fluxion-dyn: the resolver is optional (" ++ @typeName(From) ++
            "); unwrap it, so that a missing getProcAddress is not read as an implementation " ++
            "with no entry points"),
        .null => @compileError("fluxion-dyn: the resolver is null; there is nothing to ask"),
        else => @compileError(notAResolver(From)),
    };
    // Whatever shape the resolver declared its return in - a `?*anyopaque`, a
    // convention of its own - the pointer itself is the same pointer.
    return @ptrCast(returned);
}

/// Is this type usable as a resolver? For a `comptime` check in code that takes
/// one, so the error names the caller's type rather than a line in here.
pub fn isResolver(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"fn" => true,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => true,
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(pointer.child, "get"),
            else => false,
        },
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "get"),
        else => false,
    };
}

fn notAResolver(comptime T: type) []const u8 {
    return "fluxion-dyn: a resolver is a getProcAddress function, or a value with a public " ++
        "`get(name: [*:0]const u8) ?Proc` method, not " ++ @typeName(T);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn stub() callconv(.c) void {}

test "a resolver can be a plain function" {
    const Driver = struct {
        fn get(name: [*:0]const u8) callconv(system) ?Proc {
            if (std.mem.eql(u8, std.mem.span(name), "present")) return @ptrCast(&stub);
            return null;
        }
    };

    try testing.expect(get(Driver.get, "present") != null);
    try testing.expect(get(Driver.get, "absent") == null);

    // And as a pointer to one, which is what a C library hands back.
    const pointer: GetProcAddress = &Driver.get;
    try testing.expect(get(pointer, "present") != null);
    try testing.expect(get(pointer, "absent") == null);
}

test "a resolver can carry state" {
    const Holder = struct {
        handle: u32,
        asked: usize = 0,

        pub fn get(self: *@This(), name: [*:0]const u8) ?Proc {
            self.asked += 1;
            // The handle is the point: this is the shape a Vulkan instance or
            // device resolver has, and it needs somewhere to keep it.
            if (self.handle == 7 and std.mem.eql(u8, std.mem.span(name), "present")) {
                return @ptrCast(&stub);
            }
            return null;
        }
    };

    var holder: Holder = .{ .handle = 7 };
    try testing.expect(get(&holder, "present") != null);
    try testing.expect(get(&holder, "absent") == null);
    try testing.expectEqual(@as(usize, 2), holder.asked);
}

test "what is and is not a resolver" {
    const Driver = struct {
        fn get(name: [*:0]const u8) callconv(system) ?Proc {
            _ = name;
            return null;
        }
    };
    const Stateful = struct {
        pub fn get(self: *@This(), name: [*:0]const u8) ?Proc {
            _ = self;
            _ = name;
            return null;
        }
    };

    try testing.expect(isResolver(@TypeOf(Driver.get)));
    try testing.expect(isResolver(GetProcAddress));
    try testing.expect(isResolver(*Stateful));
    try testing.expect(!isResolver(u32));
    try testing.expect(!isResolver([]const u8));
}
