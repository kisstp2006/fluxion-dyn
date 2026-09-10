# Fluxion Dyn

Shared libraries found at run time, and their entry points turned into a struct
of function pointers. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `resolver` | Where a name becomes a pointer: a `getProcAddress`, or anything with a `get` method. Duck-typed, so a context, a library and a fallback chain are all the same thing to a caller. |
| `library` | Opening the platform's shared libraries — by system name, by path, or the first of a list that opens — and taking one symbol out. Windows, POSIX, and a graceful nothing where the platform has neither. |
| `table` | A whole struct of function pointers, filled in by field name, where the field's type says whether the entry point is allowed to be missing. |

Everything an operating system will not let you link against arrives this way:
`d3d12.dll` is missing before Windows 10, `libvulkan.so.1` comes from a GPU
driver, `opengl32.dll` exports the commands of 1997 and nothing since. A program
that imports any of those the ordinary way does not start at all where one is
missing — the loader fails before `main`, with no way to fall back.

So the library is opened by name, every entry point is fetched by name, and the
program decides for itself what a missing one means.

```zig
const Entries = struct {
    D3D12CreateDevice: *const fn (...) callconv(dyn.system) i32,
    // Absent without the Graphics Tools feature installed, and that is not a
    // reason to refuse to run.
    D3D12GetDebugInterface: ?*const fn (...) callconv(dyn.system) i32 = null,
};

var lib = try dyn.openSystem("d3d12.dll");
defer lib.close();

const entries = try lib.bind(Entries);
```

**Optionality is in the type, and that is the whole version policy.** A plain
function pointer must be found, or loading fails and says which one was missing.
An optional one may be absent and is left `null`, so the compiler makes the call
site ask — which is the check for "does this driver have compute shaders?"
happening exactly where the answer matters.

Nothing here allocates, and nothing here is generated: a table is an ordinary
struct, and loading it is a comptime walk over its fields.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-dyn
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_dyn = .{ .path = "../fluxion-dyn" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_dyn", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_dyn", fluxion.module("fluxion_dyn"));
```

```zig
const dyn = @import("fluxion_dyn");
```

## Platforms

| `backend` | Where | How |
| --- | --- | --- |
| `.windows` | Windows | `LoadLibraryExW`, `GetProcAddress`, `FreeLibrary` |
| `.posix` | Linux, Android, macOS and the rest of Apple, the BSDs, illumos | `std.DynLib` — `dlopen` where there is a libc, a hand-rolled ELF walker where there is not |
| `.none` | `wasm32`, and anything else `std.DynLib` does not cover | Nothing. Every entry point in `library` returns `error.NotSupported`, and `table` still works on entry points that arrived some other way. |

`.none` is a value rather than a compile error on purpose: a program on such a
platform gets its entry points from somewhere else entirely — something in the
process already loaded the API, or it is statically linked — and should not have
to comptime its way around a library that refuses to build.

## Tour

### library

Four ways in, and the choice is about where the file is allowed to come from:

```zig
var d3d12 = try dyn.openSystem("d3d12.dll");        // the system's own directories, and nowhere else
var angle = try dyn.open("libGLESv2.dll");          // however this platform searches
var vulkan = try dyn.openAny(&.{                    // the first of these that opens
    "libvulkan.so.1",
    "libvulkan.so",
});
var borrowed = dyn.Library.fromHandle(handle, "already open");
```

**`openSystem` is not just `open` with a shorter name.** On Windows,
`LoadLibrary("d3d12.dll")` searches the program's own directory first, so anyone
who can write a file next to the executable can have their `d3d12.dll` loaded
with the process's privileges. This is old, it has a name (DLL planting), and
the fix is one flag: `LOAD_LIBRARY_SEARCH_SYSTEM32`.

On POSIX `dlopen` already has that property, so there the two are the same call.
What is the same on both is the rule: `openSystem` refuses a name with a path in
it on every platform.

```zig
try dyn.openSystem("C:\\Windows\\System32\\kernel32.dll");  // error.InvalidName
try dyn.openSystem("../libc.so.6");                         // error.InvalidName
```

One symbol at a time, typed or not:

```zig
if (lib.get("vkGetInstanceProcAddr")) |proc| { ... }        // untyped, or null

const entry = lib.lookup(PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse
    return error.NotAVulkanLoader;
```

Nothing checks the type against what the library actually exports — there is
nothing to check it against — so a wrong signature is a corrupt stack later
rather than an error, and worth reading twice. By name, and never by ordinal:
the ordinals in a system library are not a documented interface and have moved
between releases.

`name` is kept, for the times when which one opened matters:

```zig
var vulkan = try dyn.openAny(&.{ "libvulkan.dylib", "libMoltenVK.dylib" });
std.log.info("Vulkan from {s}", .{vulkan.name});  // MoltenVK is a different answer
```

### table

A table is a plain struct. The field names are the names to ask for, and the
field types say what is required:

```zig
const Api = struct {
    clear: *const fn (mask: c_uint) callconv(.c) void,
    clearColor: *const fn (r: f32, g: f32, b: f32, a: f32) callconv(.c) void,
    bindVertexArray: ?*const fn (array: c_uint) callconv(.c) void,

    pub const naming: dyn.Naming = .{ .prefix = "gl" };
};

var api: Api = undefined;
try dyn.load(&api, getProcAddress);
```

which asks for `glClear`, `glClearColor` and `glBindVertexArray`. The struct is
both the declaration and the list of what to fetch, so there is no second list
to fall out of step with the first.

Three shapes a field can take:

| Field | Means |
| --- | --- |
| `*const fn (...) callconv(...) T` | Required. Missing is `error.SymbolNotFound`. |
| `?*const fn (...) callconv(...) T` | Optional. Missing is `null`, and the compiler makes the call site unwrap it. |
| `?*const anyopaque` | Present or not, and this program does not describe how to call it. |

That last one is worth having. Whether an entry point exists is an answer on its
own — it is one way to tell one version of an operating system from another —
and writing out a signature nobody calls is a way to get one wrong.

**Four calls, and the difference is what happens when something is missing:**

```zig
try dyn.load(&api, resolver);              // fill in place, fail on the first required miss
const api = try dyn.bind(Api, resolver);   // the same, into a fresh table returned by value
const status = dyn.tryLoad(&api, resolver, .{});   // fill and report, never fail
dyn.firstMissing(Api, resolver)            // just the name, for the message
```

`tryLoad` attempts every field, including the ones after a required entry point
that was missing, so the counts describe the whole table rather than the part
before the first problem — which is what makes the status worth printing:

```zig
const status = dyn.tryLoad(&api, resolver, .{ .prefix = "gl" });
std.log.info("{f}", .{status});
// 209/211 loaded, 1 optional absent, 1 required missing, first glGetError
```

And `firstMissing` is what turns a failure into something a person can act on.
"this driver has no `vkCreateInstance`" is worth printing; `SymbolNotFound` is
not.

### Naming

`Naming` is how a field name becomes a symbol name, and it is all comptime:

```zig
dyn.symbolName("clear", .{ .prefix = "gl" })              // glClear
dyn.symbolName("cmdDraw", .{ .prefix = "vk" })            // vkCmdDraw
dyn.symbolName("getDisplay", .{ .prefix = "egl" })        // eglGetDisplay
dyn.symbolName("D3D12CreateDevice", .{})                  // D3D12CreateDevice
```

`Capitalize.auto` — the default — raises the first letter when there is a
prefix and leaves it alone when there is not, which is right for all three
shapes that turn up: a GL or Vulkan table written the way Zig spells functions,
and a DLL export table whose names are already capitalised. `.always` and
`.never` are there for the library that is neither.

A field is looked up under its derived name, then under any **aliases** the
table declares for it, then under the derived name with each of **suffixes** on
the end. Specific before blanket: an alias is a statement about one entry point,
a suffix list is a policy for all of them.

```zig
const Commands = struct {
    getPhysicalDeviceProperties2: ?*const fn (...) callconv(dyn.system) void,

    pub const naming: dyn.Naming = .{ .prefix = "vk" };

    /// Core in Vulkan 1.1, and an extension before that.
    pub const aliases = .{
        .getPhysicalDeviceProperties2 = .{"vkGetPhysicalDeviceProperties2KHR"},
    };
};
```

Suffixes are worth leaving empty unless you know the extension you are naming.
An extension entry point is usually the same function under an older name, but
not always — `glBindFramebufferEXT` belongs to a different object model than
core `glBindFramebuffer`, and a loader that quietly substitutes one for the
other produces a program that runs and draws nothing.

### resolver

A resolver is anything that answers a name. There is no interface type to
implement and nothing to register — a value qualifies by having a public
`get(name: [*:0]const u8) ?Proc` method, or by being a `getProcAddress`
function:

```zig
try dyn.load(&api, glfwGetProcAddress);   // a plain function
try dyn.load(&api, &lib);                 // an open Library, which has a `get`
try dyn.load(&api, &chain);               // a fallback, which also has one
try dyn.load(&api, &vulkan_resolver);     // one carrying the instance to dispatch on
```

Duck-typing rather than one interface type is what keeps the calling convention
out of this library's hands. `wglGetProcAddress` is `stdcall` on 32-bit Windows,
`eglGetProcAddress` is `cdecl`, and Vulkan on Android's 32-bit ARM is neither.
Because the resolver is passed as `anytype` and called directly, each is called
exactly as it was declared, and nothing here ever has to name a convention it
might get wrong.

`dyn.system` is the one convention this library does name — `.winapi` on
Windows, `.c` everywhere else — for tables that load the platform's own entry
points. On 64-bit Windows the two are the same, so the distinction only starts
to matter on a 32-bit build, which is exactly when nobody is testing.

### Chain

`Chain` asks a context's `getProcAddress` first and a library's exports second.

On Windows this is not an optimisation. `wglGetProcAddress` answers only for
commands newer than OpenGL 1.1: ask it for `glClear`, `glViewport` or
`glDrawArrays` — the ones every frame calls — and it returns null, because those
are exported from `opengl32.dll` directly and the loader expects you to have
linked them. A program that asks only the context ends up with a table full of
holes in the oldest and most-used commands, on the one platform where that
happens.

```zig
var opengl32 = try dyn.openSystem("opengl32.dll");
defer opengl32.close();

var chain: dyn.Chain = .{ .context = wglGetProcAddress, .library = &opengl32 };
try dyn.load(&api, &chain);
```

Elsewhere the fallback is harmless and occasionally useful: GLX answers for
everything it knows whether or not a context is current, and EGL is required to,
so the chain never reaches its second link. Both links are optional, which is
also how a program says "just the library" before it has a context, or "just the
context" where the fallback is pointless.

## Everything together

What a loader actually does, start to finish — find it, check it is what it
claims, take the table:

```zig
const dyn = @import("fluxion_dyn");

const Entries = struct {
    vkGetInstanceProcAddr: *const fn (?*anyopaque, [*:0]const u8) callconv(dyn.system) ?dyn.Proc,
};

pub fn main() !void {
    var lib = dyn.openAny(&.{ "libvulkan.so.1", "libvulkan.so" }) catch {
        // An answer, not a crash. Usually it means no GPU driver is
        // installed, rather than that there is no GPU.
        std.log.warn("no Vulkan on this machine", .{});
        return;
    };
    defer lib.close();

    const entries = lib.bind(Entries) catch {
        std.log.err("{s} has no {s}", .{ lib.name, lib.firstMissing(Entries).? });
        return error.NotAVulkanLoader;
    };

    // From here everything else comes out of that one function.
    _ = entries;
}
```

## Examples

```bash
zig build example
```

The demo opens the library this platform certainly has, takes one entry point
out of it, loads a table of three in the three shapes a field can take, prints
what the naming rules do, and then goes looking for every graphics library this
platform might keep — Direct3D 11 and 12, DXGI, OpenGL and Vulkan on Windows;
Vulkan, MoltenVK and OpenGL ES elsewhere — reporting which are installed and
which are not. Nothing in it needs a GPU, and nothing in it fails for want of
one.

## Build

```bash
zig build test        # run the test suite
zig build example     # build and run the demo tour
zig build docs        # generate API docs into zig-out/docs
```

The tests load tables against a fake implementation rather than a real one:
which entry points a driver has is not something a test can arrange, and every
rule in `table` is about what happens when one is missing. So there are fakes
with everything, fakes missing an optional entry point, fakes missing a required
one, and fakes that answer only to an alias or a suffix — and the tests check
what was asked for, in what order, as well as what came back.

The rest run against the library this platform is guaranteed to already have —
on Windows `kernel32.dll`, which is in every process there has ever been — and
skip rather than fail where there is no such guarantee, because a missing libc
says nothing about the code under test.

## Requirements

Zig 0.16.0.

## License

`SPDX-License-Identifier: CC0-1.0`

[CC0 1.0 Universal](LICENSE) — public domain dedication. Do whatever you like
with this, no attribution required.
