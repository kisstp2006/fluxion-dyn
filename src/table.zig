// SPDX-License-Identifier: CC0-1.0

//! Filling a struct of function pointers with the entry points an
//! implementation actually has.
//!
//! A table is a plain struct whose fields are function pointers, and the field
//! names are the names to ask for:
//!
//! ```zig
//! const Minimal = struct {
//!     clear: *const fn (mask: c_uint) callconv(.c) void,
//!     clearColor: *const fn (r: f32, g: f32, b: f32, a: f32) callconv(.c) void,
//!     bindVertexArray: ?*const fn (array: c_uint) callconv(.c) void,
//!
//!     pub const naming: Naming = .{ .prefix = "gl" };
//! };
//!
//! var api: Minimal = undefined;
//! try load(&api, getProcAddress);
//! ```
//!
//! which asks for `glClear`, `glClearColor` and `glBindVertexArray`. The struct
//! is both the declaration and the list of what to fetch, so there is no second
//! list to fall out of step with it, and nothing is generated: loading is a
//! comptime walk over the fields.
//!
//! **Optionality is in the type, and that is the whole version policy.** A
//! `*const fn ...` field is required and loading fails naming it; a
//! `?*const fn ...` field may be absent, is left `null`, and the compiler makes
//! the call site unwrap it - which puts "does this driver have compute
//! shaders?" exactly where the answer matters.
//!
//! **A field may also be `*const anyopaque`**, which says "this entry point
//! exists and this program does not describe how to call it". Presence alone is
//! worth knowing, and a signature nobody calls is a way to get one wrong.
//!
//! **Three names, in order:** the name derived from the field, then any
//! `aliases` the table declares for it, then the derived name with each of
//! `Naming.suffixes` on the end. Specific before blanket.
//!
//! Where the entry points come from is `resolver`'s business, so the same call
//! loads out of a `library.Library`, a `wglGetProcAddress`, or a
//! `vkGetInstanceProcAddr` holding its instance.

const std = @import("std");
const testing = std.testing;

const resolver = @import("resolver.zig");

const Proc = resolver.Proc;

/// Loading failed because an entry point the table requires was not there.
/// `Status.missing` names it; `tryLoad` reports rather than fails.
pub const Error = error{SymbolNotFound};

/// Whether the first letter of a field name is raised on the way to the symbol
/// name.
pub const Capitalize = enum {
    /// Raised when there is a prefix, left alone when there is not - which is
    /// right for all three of the shapes that turn up in practice. `gl` and
    /// `clear` are `glClear`; `vk` and `cmdDraw` are `vkCmdDraw`; no prefix
    /// and `D3D12CreateDevice` is `D3D12CreateDevice`.
    auto,
    /// Always, even with no prefix.
    always,
    /// Never. For a library whose exports are `snake_case`, where raising the
    /// first letter would name nothing at all.
    never,
};

/// How field names are turned into the names the implementation knows.
///
/// A table declares its own as `pub const naming: Naming = ...`, which `load`
/// picks up; `loadWith` overrides it for one call.
pub const Naming = struct {
    /// Put in front of the field name: `gl` for OpenGL and OpenGL ES, `vk` for
    /// Vulkan, `egl`, `wgl` or `glX` for the window-system tables, which load
    /// exactly the same way. Empty for a library whose exports are already
    /// spelled the way the fields are.
    prefix: []const u8 = "",

    /// See `Capitalize`.
    capitalize: Capitalize = .auto,

    /// Tried, in order, when neither the derived name nor an alias is there:
    /// `glBindVertexArray` first, then `glBindVertexArrayOES`.
    ///
    /// Empty by default, and worth leaving that way unless you know the
    /// extension you are naming. An extension entry point is usually the same
    /// function under an older name, but not always - `glBindFramebufferEXT`
    /// belongs to a different object model than `glBindFramebuffer`, and
    /// substituting one for the other produces a program that draws nothing:
    ///
    /// ```zig
    /// // Vertex arrays on an ES 2.0 context, where they are an extension.
    /// try loadWith(&api, get, .{ .prefix = "gl", .suffixes = &.{"OES"} });
    /// ```
    suffixes: []const []const u8 = &.{},
};

/// What a load found. `tryLoad` returns one; `load` turns anything but a clean
/// one into `error.SymbolNotFound`.
pub const Status = struct {
    /// Fields in the table.
    requested: usize = 0,
    /// Fields the implementation had an address for.
    loaded: usize = 0,
    /// Optional fields it had not; those are `null`.
    absent: usize = 0,
    /// Required fields it had not. Those were left exactly as they were, which
    /// for a fresh table means undefined.
    short: usize = 0,
    /// The first required field it had not, under the name it was asked for.
    missing: ?[:0]const u8 = null,

    /// Is the table safe to call?
    pub fn ok(self: Status) bool {
        return self.short == 0;
    }

    pub fn format(self: Status, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}/{d} loaded", .{ self.loaded, self.requested });
        if (self.absent > 0) try w.print(", {d} optional absent", .{self.absent});
        if (self.missing) |name| try w.print(", {d} required missing, first {s}", .{ self.short, name });
    }
};

// -------------------------------------------------------------------------
// Loading
// -------------------------------------------------------------------------

/// Fill `table` - a pointer to a struct of function pointers - from
/// `from`, under the table's own `naming`.
///
/// Where the entry points come from a context rather than a library, that
/// context has to be current on the calling thread already: without one, some
/// drivers return null and others return addresses for a context you are not
/// using.
pub fn load(table: anytype, from: anytype) Error!void {
    return loadWith(table, from, namingOf(Pointee(@TypeOf(table))));
}

/// `load` with the naming rules given here instead of the table's own.
pub fn loadWith(table: anytype, from: anytype, comptime naming: Naming) Error!void {
    if (!tryLoad(table, from, naming).ok()) return error.SymbolNotFound;
}

/// Fill `table` and report, rather than fail.
///
/// Every field is attempted, including those after a missing required one, so
/// the counts describe the whole table. Use it where a missing entry point is
/// something to work around or to print in a startup log.
pub fn tryLoad(table: anytype, from: anytype, comptime naming: Naming) Status {
    const Table = Pointee(@TypeOf(table));
    comptime validate(Table);

    const fields = @typeInfo(Table).@"struct".fields;
    var status: Status = .{ .requested = fields.len };

    inline for (fields) |field| {
        const Entry = EntryType(field.type);
        const required = @typeInfo(field.type) != .optional;
        const wanted = comptime candidatesFor(Table, field.name, naming);

        var found: ?Proc = null;
        inline for (wanted) |candidate| {
            if (found == null) found = resolver.get(from, candidate);
        }

        if (found) |proc| {
            @field(table, field.name) = @as(Entry, @ptrCast(proc));
            status.loaded += 1;
        } else if (required) {
            status.short += 1;
            if (status.missing == null) status.missing = wanted[0];
        } else {
            @field(table, field.name) = null;
            status.absent += 1;
        }
    }

    return status;
}

/// `load` into a fresh table, returned by value. For a table that is built
/// once and kept, where there is nothing to fill in beforehand.
pub fn bind(comptime Table: type, from: anytype) Error!Table {
    return bindWith(Table, from, namingOf(Table));
}

/// `bind` with the naming rules given here instead of the table's own.
pub fn bindWith(comptime Table: type, from: anytype, comptime naming: Naming) Error!Table {
    var table: Table = undefined;
    try loadWith(&table, from, naming);
    return table;
}

/// The name of the first required entry of `Table` that `from` has not got, or
/// null if it has them all. "This driver has no vkCreateInstance" is worth
/// printing; "SymbolNotFound" is not.
pub fn firstMissing(comptime Table: type, from: anytype) ?[:0]const u8 {
    return firstMissingWith(Table, from, namingOf(Table));
}

/// `firstMissing` with the naming rules given here instead of the table's own.
pub fn firstMissingWith(comptime Table: type, from: anytype, comptime naming: Naming) ?[:0]const u8 {
    comptime validate(Table);

    inline for (@typeInfo(Table).@"struct".fields) |field| {
        if (comptime @typeInfo(field.type) != .optional) {
            const wanted = comptime candidatesFor(Table, field.name, naming);
            var found = false;
            inline for (wanted) |candidate| {
                if (!found) found = resolver.get(from, candidate) != null;
            }
            if (!found) return wanted[0];
        }
    }
    return null;
}

/// Is every required entry of `Table` there? For checking an implementation
/// before committing to it.
pub fn available(comptime Table: type, from: anytype) bool {
    return firstMissing(Table, from) == null;
}

// -------------------------------------------------------------------------
// Names
// -------------------------------------------------------------------------

/// The name a field resolves to: the prefix, then the field name with its
/// first letter raised if `Naming` says so.
///
/// Comptime, and public because code that looks an entry point up by hand
/// should spell it the same way the table does.
pub fn symbolName(comptime field: []const u8, comptime naming: Naming) [:0]const u8 {
    return symbolNameSuffixed(field, naming, "");
}

/// `symbolName` with an extension suffix on the end: `bindVertexArray` and
/// `OES` become `glBindVertexArrayOES`.
pub fn symbolNameSuffixed(
    comptime field: []const u8,
    comptime naming: Naming,
    comptime suffix: []const u8,
) [:0]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        if (field.len == 0) @compileError("fluxion-dyn: a table field must have a name");

        const raise = switch (naming.capitalize) {
            .auto => naming.prefix.len > 0,
            .always => true,
            .never => false,
        };
        const head = if (raise)
            [_]u8{std.ascii.toUpper(field[0])} ++ field[1..]
        else
            field;

        const spelled = naming.prefix ++ head ++ suffix ++ [_]u8{0};
        return spelled[0 .. spelled.len - 1 :0];
    }
}

/// Every name a table asks for first, in field order. Comptime, so it costs
/// nothing at run time: it is for printing what an implementation was asked
/// for next to what it answered.
pub fn names(comptime Table: type) []const [:0]const u8 {
    return namesWith(Table, namingOf(Table));
}

/// `names` with the naming rules given here instead of the table's own.
pub fn namesWith(comptime Table: type, comptime naming: Naming) []const [:0]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        validate(Table);
        var list: []const [:0]const u8 = &.{};
        for (@typeInfo(Table).@"struct".fields) |field| {
            list = list ++ [_][:0]const u8{symbolName(field.name, naming)};
        }
        return list;
    }
}

/// How many entry points a table has.
pub fn count(comptime Table: type) usize {
    return @typeInfo(Table).@"struct".fields.len;
}

/// How many of them are optional - the width of the gap between the version a
/// table requires and the version it can use.
pub fn optionalCount(comptime Table: type) usize {
    comptime {
        var n: usize = 0;
        for (@typeInfo(Table).@"struct".fields) |field| {
            if (@typeInfo(field.type) == .optional) n += 1;
        }
        return n;
    }
}

// -------------------------------------------------------------------------
// The parts that only exist at compile time
// -------------------------------------------------------------------------

/// A table may declare other names to try when the derived one is not there:
///
/// ```zig
/// const Commands = struct {
///     getPhysicalDeviceProperties2: ?*const fn (...) callconv(.c) void,
///
///     /// Core in Vulkan 1.1, and an extension before that.
///     pub const aliases = .{
///         .getPhysicalDeviceProperties2 = .{"vkGetPhysicalDeviceProperties2KHR"},
///     };
/// };
/// ```
///
/// Which is what a promoted extension looks like: the same function under two
/// names, and which one an implementation answers to depends on its age. An
/// alias is written out in full, since the point of one is that it is not what
/// the derived name would be.
fn candidatesFor(
    comptime Table: type,
    comptime field: []const u8,
    comptime naming: Naming,
) []const [:0]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var list: []const [:0]const u8 = &.{symbolName(field, naming)};

        if (@hasDecl(Table, "aliases") and @hasField(@TypeOf(Table.aliases), field)) {
            for (@field(Table.aliases, field)) |alias| {
                list = list ++ [_][:0]const u8{alias};
            }
        }

        for (naming.suffixes) |suffix| {
            list = list ++ [_][:0]const u8{symbolNameSuffixed(field, naming, suffix)};
        }

        return list;
    }
}

fn namingOf(comptime Table: type) Naming {
    return if (@hasDecl(Table, "naming")) Table.naming else .{};
}

/// The struct behind a `*Table`, with a readable error for the common slip of
/// passing the table itself.
fn Pointee(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
        @compileError("fluxion-dyn: load wants a mutable pointer to the table (`&api`), not " ++
            @typeName(T));
    }
    return info.pointer.child;
}

/// The pointer type a field holds, with the optional taken off.
fn EntryType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
}

/// Every field must be a single-item pointer to a function, or to `anyopaque`,
/// or the optional of one. Anything else is a mistake worth catching at
/// compile time rather than a pointer cast that happens to go through.
fn validate(comptime Table: type) void {
    comptime {
        const info = @typeInfo(Table);
        if (info != .@"struct") @compileError(
            "fluxion-dyn: an entry point table must be a struct, not " ++ @typeName(Table),
        );

        for (info.@"struct".fields) |field| {
            const inner = EntryType(field.type);
            const ok = switch (@typeInfo(inner)) {
                .pointer => |pointer| pointer.size == .one and
                    (@typeInfo(pointer.child) == .@"fn" or pointer.child == anyopaque),
                else => false,
            };
            if (!ok) @compileError(
                "fluxion-dyn: field '" ++ field.name ++ "' of " ++ @typeName(Table) ++ " is " ++
                    @typeName(field.type) ++ ", but an entry point table holds function pointers - " ++
                    "`*const fn (...) callconv(...) T` when the entry point is required, the optional " ++
                    "of one when it may be absent, and `*const anyopaque` when its presence is all " ++
                    "the program wants to know",
            );
        }
    }
}

// -------------------------------------------------------------------------
// Tests
//
// Against a fake implementation rather than a real one: which entry points a
// driver has is not something a test can arrange, and every rule in this file
// is about what happens when one is missing.
// -------------------------------------------------------------------------

fn stub() callconv(.c) void {}

/// An implementation that has exactly the entry points it was told to have,
/// and remembers what it was asked for.
const Fake = struct {
    have: []const []const u8,
    asked: [32][]const u8 = undefined,
    asked_len: usize = 0,

    pub fn get(self: *Fake, name: [*:0]const u8) ?Proc {
        const wanted = std.mem.span(name);
        if (self.asked_len < self.asked.len) {
            self.asked[self.asked_len] = wanted;
            self.asked_len += 1;
        }
        for (self.have) |entry| {
            if (std.mem.eql(u8, entry, wanted)) return @ptrCast(&stub);
        }
        return null;
    }

    fn askedFor(self: *const Fake) []const []const u8 {
        return self.asked[0..self.asked_len];
    }
};

const Basic = struct {
    clear: *const fn (mask: c_uint) callconv(.c) void,
    getError: *const fn () callconv(.c) c_uint,
    bindVertexArray: ?*const fn (array: c_uint) callconv(.c) void,

    pub const naming: Naming = .{ .prefix = "gl" };
};

test "field names become symbol names" {
    try testing.expectEqualStrings("glClear", comptime symbolName("clear", .{ .prefix = "gl" }));
    try testing.expectEqualStrings("glGetError", comptime symbolName("getError", .{ .prefix = "gl" }));
    // The underscore a few of them carry in the middle survives untouched.
    try testing.expectEqualStrings(
        "glGetIntegeri_v",
        comptime symbolName("getIntegeri_v", .{ .prefix = "gl" }),
    );
    // A different API, loaded by the same machinery.
    try testing.expectEqualStrings("vkCmdDraw", comptime symbolName("cmdDraw", .{ .prefix = "vk" }));
    try testing.expectEqualStrings("eglGetDisplay", comptime symbolName("getDisplay", .{ .prefix = "egl" }));
    try testing.expectEqualStrings(
        "glBindVertexArrayOES",
        comptime symbolNameSuffixed("bindVertexArray", .{ .prefix = "gl" }, "OES"),
    );
}

test "no prefix means the field name as it is written" {
    // Which is what a DLL export table looks like: the names are already
    // capitalised, and raising the first letter of one is a no-op that would
    // still be wrong to rely on.
    try testing.expectEqualStrings("D3D12CreateDevice", comptime symbolName("D3D12CreateDevice", .{}));
    try testing.expectEqualStrings("GetTickCount64", comptime symbolName("GetTickCount64", .{}));

    // And a library whose exports are lower case keeps them that way, which
    // `.auto` gets right and `.always` would not.
    try testing.expectEqualStrings("getpid", comptime symbolName("getpid", .{}));
    try testing.expectEqualStrings("Getpid", comptime symbolName("getpid", .{ .capitalize = .always }));
    try testing.expectEqualStrings(
        "glclear",
        comptime symbolName("clear", .{ .prefix = "gl", .capitalize = .never }),
    );
}

test "the names of a whole table, in field order" {
    const expected = [_][]const u8{ "glClear", "glGetError", "glBindVertexArray" };
    inline for (comptime names(Basic), expected) |asked, want| {
        try testing.expectEqualStrings(want, asked);
    }
    try testing.expectEqual(3, comptime count(Basic));
    try testing.expectEqual(1, comptime optionalCount(Basic));
}

test "an implementation with everything" {
    var fake: Fake = .{ .have = &.{ "glClear", "glGetError", "glBindVertexArray" } };
    var api: Basic = undefined;
    try load(&api, &fake);

    // Asked for in field order, once each.
    try testing.expectEqual(3, fake.askedFor().len);
    try testing.expectEqualStrings("glClear", fake.askedFor()[0]);
    try testing.expectEqualStrings("glBindVertexArray", fake.askedFor()[2]);
    try testing.expect(api.bindVertexArray != null);
}

test "an implementation missing an optional entry point" {
    var fake: Fake = .{ .have = &.{ "glClear", "glGetError" } };
    var api: Basic = undefined;
    const status = tryLoad(&api, &fake, Basic.naming);

    try testing.expect(status.ok());
    try testing.expectEqual(3, status.requested);
    try testing.expectEqual(2, status.loaded);
    try testing.expectEqual(1, status.absent);
    try testing.expectEqual(null, api.bindVertexArray);

    // Which is not an error, so the plain call goes through as well.
    try load(&api, &fake);
    try testing.expect(available(Basic, &fake));
}

test "an implementation missing a required entry point" {
    var fake: Fake = .{ .have = &.{"glClear"} };
    var api: Basic = undefined;

    const status = tryLoad(&api, &fake, Basic.naming);
    try testing.expect(!status.ok());
    try testing.expectEqual(1, status.short);
    try testing.expectEqualStrings("glGetError", status.missing.?);

    try testing.expectError(error.SymbolNotFound, load(&api, &fake));
    try testing.expectError(error.SymbolNotFound, bind(Basic, &fake));

    // Which one, for the message. `SymbolNotFound` on its own says nothing
    // about the machine it happened on.
    try testing.expectEqualStrings("glGetError", firstMissing(Basic, &fake).?);
    try testing.expect(!available(Basic, &fake));
}

test "every field is attempted, not just the ones before the first failure" {
    // A required entry point missing in the middle does not stop the walk, so
    // the counts describe the whole table - which is what makes the status
    // worth printing rather than just testing.
    var fake: Fake = .{ .have = &.{"glClear"} };
    var api: Basic = undefined;
    const status = tryLoad(&api, &fake, Basic.naming);

    try testing.expectEqual(3, status.requested);
    try testing.expectEqual(1, status.loaded);
    try testing.expectEqual(1, status.short);
    try testing.expectEqual(1, status.absent);
    try testing.expectEqual(3, fake.askedFor().len);
}

test "the suffix fallback, and only when it is asked for" {
    const have = [_][]const u8{ "glClear", "glGetError", "glBindVertexArrayOES" };

    var without: Fake = .{ .have = &have };
    var api: Basic = undefined;
    try testing.expectEqual(1, tryLoad(&api, &without, .{ .prefix = "gl" }).absent);

    var with: Fake = .{ .have = &have };
    const status = tryLoad(&api, &with, .{ .prefix = "gl", .suffixes = &.{"OES"} });
    try testing.expectEqual(0, status.absent);
    try testing.expect(api.bindVertexArray != null);

    // The plain name is still tried first, so a core entry point is never
    // quietly answered by an extension.
    try testing.expectEqualStrings("glBindVertexArray", with.askedFor()[2]);
    try testing.expectEqualStrings("glBindVertexArrayOES", with.askedFor()[3]);
}

test "an alias is tried before a suffix, and after the derived name" {
    const Promoted = struct {
        getPhysicalDeviceProperties2: ?*const fn () callconv(.c) void,

        pub const naming: Naming = .{ .prefix = "vk", .suffixes = &.{"EXT"} };
        pub const aliases = .{
            .getPhysicalDeviceProperties2 = .{"vkGetPhysicalDeviceProperties2KHR"},
        };
    };

    // A driver old enough that the command is still an extension.
    var old: Fake = .{ .have = &.{"vkGetPhysicalDeviceProperties2KHR"} };
    var api: Promoted = undefined;
    const status = tryLoad(&api, &old, Promoted.naming);
    try testing.expect(status.ok());
    try testing.expectEqual(1, status.loaded);
    try testing.expect(api.getPhysicalDeviceProperties2 != null);

    // Derived name first, then the alias, then the suffixed form - and the
    // walk stops as soon as one answers, so the suffix is never reached here.
    try testing.expectEqual(2, old.askedFor().len);
    try testing.expectEqualStrings("vkGetPhysicalDeviceProperties2", old.askedFor()[0]);
    try testing.expectEqualStrings("vkGetPhysicalDeviceProperties2KHR", old.askedFor()[1]);

    // On a driver that has none of them, all three are tried in that order.
    var none: Fake = .{ .have = &.{} };
    _ = tryLoad(&api, &none, Promoted.naming);
    try testing.expectEqual(3, none.askedFor().len);
    try testing.expectEqualStrings("vkGetPhysicalDeviceProperties2EXT", none.askedFor()[2]);
}

test "a field that is only asked whether it exists" {
    // No signature, so nothing can call it and nothing can get the signature
    // wrong - but its presence is still an answer, and often the one a program
    // is actually asking for.
    const Probe = struct {
        D3D12CreateDevice: ?*const anyopaque = null,
        D3D12GetDebugInterface: ?*const anyopaque = null,
    };

    var fake: Fake = .{ .have = &.{"D3D12CreateDevice"} };
    const probe = try bind(Probe, &fake);

    try testing.expect(probe.D3D12CreateDevice != null);
    try testing.expect(probe.D3D12GetDebugInterface == null);
}

test "a resolver that is a plain getProcAddress" {
    const Driver = struct {
        fn get(name: [*:0]const u8) callconv(resolver.system) ?Proc {
            if (std.mem.eql(u8, std.mem.span(name), "glBindVertexArray")) return null;
            return @ptrCast(&stub);
        }
    };

    var api: Basic = undefined;
    try load(&api, Driver.get);
    try testing.expectEqual(null, api.bindVertexArray);

    // The C type is the same function, so the pointer form works too.
    const pointer: resolver.GetProcAddress = &Driver.get;
    try load(&api, pointer);
}

test "the status prints as one line for a startup log" {
    var buf: [128]u8 = undefined;
    var fake: Fake = .{ .have = &.{"glClear"} };
    var api: Basic = undefined;
    const status = tryLoad(&api, &fake, Basic.naming);
    try testing.expectEqualStrings(
        "1/3 loaded, 1 optional absent, 1 required missing, first glGetError",
        try std.fmt.bufPrint(&buf, "{f}", .{status}),
    );
}

test "a table with no naming of its own asks for its field names" {
    const Exports = struct {
        GetTickCount64: *const fn () callconv(resolver.system) u64,
        NoSuchExport: ?*const anyopaque = null,
    };

    var fake: Fake = .{ .have = &.{"GetTickCount64"} };
    const table = try bind(Exports, &fake);
    try testing.expect(table.NoSuchExport == null);
    try testing.expectEqualStrings("GetTickCount64", fake.askedFor()[0]);
}
