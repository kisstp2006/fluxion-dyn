# Fluxion Dyn

Shared libraries found at run time, and their entry points turned into a struct
of function pointers. For C3 0.8.

| Module | What it is |
| --- | --- |
| `resolver` | Where a name becomes a pointer: a `getProcAddress`, or anything with a `get` method. Duck-typed, so a context, a library and a fallback chain are all the same thing to a caller. |
| `library` | Opening the platform's shared libraries - by system name, by path, or the first of a list that opens - and taking one symbol out. Windows, POSIX, and a graceful nothing where the platform has neither. |
| `table` | A whole struct of function pointers, filled in by field name, where a tag on the field says whether the entry point is allowed to be missing. |

Everything an operating system will not let you link against arrives this way:
`d3d12.dll` is missing before Windows 10, `libvulkan.so.1` comes from a GPU
driver, `opengl32.dll` exports the commands of 1997 and nothing since. A program
that imports any of those the ordinary way does not start at all where one is
missing - the loader fails before `main`, with no way to fall back.

So the library is opened by name, every entry point is fetched by name, and the
program decides for itself what a missing one means.

```c3
alias CreateDeviceFn = fn int(...);
alias DebugFn = fn int(...);

struct Entries
{
    CreateDeviceFn createDevice @tag("symbol", "D3D12CreateDevice");
    // Absent without the Graphics Tools feature installed, and that is not a
    // reason to refuse to run.
    DebugFn getDebugInterface @tag("symbol", "D3D12GetDebugInterface") @tag("optional", true);
}

Library lib = dyn::open_system("d3d12.dll")!;
defer lib.close();

Entries entries = lib.bind(Entries)!;
```

**Optionality is a tag on the field, and that is the whole version policy.** A
plain function pointer must be found, or loading fails and says which one was
missing. One tagged `optional` may be absent and is left null, so the call site
has to ask - which is the check for "does this driver have compute shaders?"
happening exactly where the answer matters.

Nothing here allocates past the temporary allocator, and nothing here is
generated: a table is an ordinary struct, and loading it is a compile-time walk
over its fields.

## Install

The library is the `fluxion_dyn.c3l` directory in this repository. For a
checkout next to your project, add to `project.json`:

```json
"dependency-search-paths": ["../fluxion-dyn"],
"dependencies": ["fluxion_dyn"]
```

Then, in the code:

```c3
import fluxion::dyn;
```

## Platforms

| `BACKEND` | Where | How |
| --- | --- | --- |
| `WINDOWS` | Windows | `LoadLibraryExW`, `GetProcAddress`, `FreeLibrary` |
| `POSIX` | Linux, Android, macOS, the BSDs - anywhere with a libc | `dlopen`, `dlsym`, `dlclose` |
| `NONE` | `wasm32`, and any target without a libc | Nothing. Every open returns `NOT_SUPPORTED`, and `table` still works on entry points that arrived some other way. |

`NONE` is a value rather than a compile error on purpose: a program on such a
platform gets its entry points from somewhere else entirely - something in the
process already loaded the API, or it is statically linked - and should not
have to work around a library that refuses to build. The three backends are
three `@feat` module sections in one file; the compiler keeps the one that
matches the target.

## Tour

### library

Four ways in, and the choice is about where the file is allowed to come from:

```c3
Library d3d12 = dyn::open_system("d3d12.dll")!;   // the system's own directories, and nowhere else
Library angle = dyn::open("libGLESv2.dll")!;      // however this platform searches
Library vulkan = dyn::open_any({                  // the first of these that opens
    "libvulkan.so.1",
    "libvulkan.so",
})!;
Library borrowed = library::from_handle(handle, "already open");
```

**`open_system` is not just `open` with a shorter name.** On Windows,
`LoadLibrary("d3d12.dll")` searches the program's own directory first, so anyone
who can write a file next to the executable can have their `d3d12.dll` loaded
with the process's privileges. This is old, it has a name (DLL planting), and
the fix is one flag: `LOAD_LIBRARY_SEARCH_SYSTEM32`.

On POSIX `dlopen` already has that property, so there the two are the same
call. What is the same on both is the rule: `open_system` refuses a name with a
path in it on every platform.

```c3
dyn::open_system("C:\\Windows\\System32\\kernel32.dll");  // INVALID_NAME
dyn::open_system("../libc.so.6");                         // INVALID_NAME
```

One symbol at a time, typed or not:

```c3
if (lib.get("vkGetInstanceProcAddr") != null) { ... }        // untyped, or null

PfnGetInstanceProcAddr entry = lib.lookup(PfnGetInstanceProcAddr, "vkGetInstanceProcAddr");
if (entry == null) return NOT_A_VULKAN_LOADER~;
```

Nothing checks the type against what the library actually exports - there is
nothing to check it against - so a wrong signature is a corrupt stack later
rather than an error, and worth reading twice. By name, and never by ordinal:
the ordinals in a system library are not a documented interface and have moved
between releases.

`name` is kept, for the times when which one opened matters:

```c3
Library vulkan = dyn::open_any({ "libvulkan.dylib", "libMoltenVK.dylib" })!;
io::printfn("Vulkan from %s", vulkan.name);  // MoltenVK is a different answer
```

### table

A table is a plain struct. The field names are the names to ask for, and a tag
on the field says what is required. A function pointer type has to be named
with an `alias` before a field can have it:

```c3
alias MaskFn = fn void(uint mask);
alias ColorFn = fn void(float r, float g, float b, float a);
alias ArrayFn = fn void(uint array);

struct Api
{
    MaskFn clear;
    ColorFn clearColor;
    ArrayFn bindVertexArray @tag("optional", true);
}

Api api;
table::load(&api, &get_proc_address, { .prefix = "gl" })!;
```

which asks for `glClear`, `glClearColor` and `glBindVertexArray`. The struct is
both the declaration and the list of what to fetch, so there is no second list
to fall out of step with the first.

Three shapes a field can take:

| Field | Means |
| --- | --- |
| `SomeFn name;` | Required. Missing is `SYMBOL_NOT_FOUND`. |
| `SomeFn name @tag("optional", true);` | Optional. Missing is null, and the call site checks before it calls. |
| `void* name @tag("optional", true);` | Present or not, and this program does not describe how to call it. |

That last one is worth having. Whether an entry point exists is an answer on its
own - it is one way to tell one version of an operating system from another -
and writing out a signature nobody calls is a way to get one wrong.

**Four calls, and the difference is what happens when something is missing:**

```c3
table::load(&api, resolver, naming)!;                // fill in place, fail on the first required miss
Api api = table::bind(Api, resolver, naming)!;       // the same, into a fresh table returned by value
Status status = table::try_load(&api, resolver, naming);   // fill and report, never fail
table::first_missing(Api, resolver, naming)          // just the name, for the message
```

`try_load` attempts every field, including the ones after a required entry point
that was missing, so the counts describe the whole table rather than the part
before the first problem - which is what makes the status worth printing:

```c3
Status status = table::try_load(&api, resolver, { .prefix = "gl" });
io::printfn("%s", status);
// 209/211 loaded, 1 optional absent, 1 required missing, first glGetError
```

And `first_missing` is what turns a failure into something a person can act on.
"this driver has no `vkCreateInstance`" is worth printing; `SYMBOL_NOT_FOUND`
is not.

### Naming

`Naming` is how a field name becomes a symbol name, and it is all compile time:

```c3
table::symbol_name("clear", { .prefix = "gl" })                  // glClear
table::symbol_name("cmdDraw", { .prefix = "vk" })                // vkCmdDraw
table::symbol_name("getDisplay", { .prefix = "egl" })            // eglGetDisplay
table::symbol_name("getTickCount64", { .capitalize = ALWAYS })   // GetTickCount64
```

`Capitalize.AUTO` - the default - raises the first letter when there is a
prefix and leaves it alone when there is not, which is right for a GL or Vulkan
table and for a libc export table. A DLL export table is the third case: its
names are capitalised, which a C3 field cannot be, so it loads with `ALWAYS`.
`NEVER` is there for the library that is neither.

A field is looked up under its derived name, then under the **alias** the field
declares, then under the derived name with each of **suffixes** on the end.
Specific before blanket: an alias is a statement about one entry point, a
suffix list is a policy for all of them. A field can also spell its export
outright with a `symbol` tag, for a name no rule would produce.

```c3
struct Commands
{
    // Core in Vulkan 1.1, and an extension before that.
    PropsFn getPhysicalDeviceProperties2 @tag("optional", true) @tag("alias", "vkGetPhysicalDeviceProperties2KHR");
    CreateFn createDevice @tag("symbol", "D3D12CreateDevice");
}
```

Suffixes are worth leaving empty unless you know the extension you are naming.
An extension entry point is usually the same function under an older name, but
not always - `glBindFramebufferEXT` belongs to a different object model than
core `glBindFramebuffer`, and a loader that quietly substitutes one for the
other produces a program that runs and draws nothing.

### resolver

A resolver is anything that answers a name. There is no interface type to
implement and nothing to register - a value qualifies by being a pointer to a
struct with a `get(ZString name)` method returning a `Proc`, or by being a
`getProcAddress` function pointer:

```c3
table::load(&api, &glfwGetProcAddress)!;   // a function, by address
table::load(&api, &lib)!;                  // an open Library, which has a `get`
table::load(&api, &chain)!;                // a fallback, which also has one
table::load(&api, &vulkan_resolver)!;      // one carrying the instance to dispatch on
```

Duck-typing rather than one interface type is what keeps the calling convention
out of this library's hands. The resolver goes into a macro with no declared
type and is called directly, so each is called exactly as it was declared. The
one convention C3 cannot express on a function pointer type is `stdcall`, which
only differs from the C one on 32-bit Windows; this library is tested where the
two are the same.

### Chain

`Chain` asks a context's `getProcAddress` first and a library's exports second.

On Windows this is not an optimisation. `wglGetProcAddress` answers only for
commands newer than OpenGL 1.1: ask it for `glClear`, `glViewport` or
`glDrawArrays` - the ones every frame calls - and it returns null, because those
are exported from `opengl32.dll` directly and the loader expects you to have
linked them. A program that asks only the context ends up with a table full of
holes in the oldest and most-used commands, on the one platform where that
happens.

```c3
Library opengl32 = dyn::open_system("opengl32.dll")!;
defer opengl32.close();

Chain chain = { .context = &wglGetProcAddress, .library = &opengl32 };
table::load(&api, &chain, { .prefix = "gl" })!;
```

Elsewhere the fallback is harmless and occasionally useful: GLX answers for
everything it knows whether or not a context is current, and EGL is required to,
so the chain never reaches its second link. Both links may be null, which is
also how a program says "just the library" before it has a context, or "just the
context" where the fallback is pointless.

## Everything together

What a loader actually does, start to finish - find it, check it is what it
claims, take the table:

```c3
import fluxion::dyn;

alias GetInstanceProcAddrFn = fn Proc(void* instance, ZString name);

struct Entries
{
    GetInstanceProcAddrFn vkGetInstanceProcAddr;
}

fn void main()
{
    Library? opened = dyn::open_any({ "libvulkan.so.1", "libvulkan.so" });
    if (catch opened)
    {
        // An answer, not a crash. Usually it means no GPU driver is
        // installed, rather than that there is no GPU.
        io::printn("no Vulkan on this machine");
        return;
    }
    Library lib = opened;
    defer lib.close();

    Entries? bound = lib.bind(Entries);
    if (catch bound)
    {
        io::printfn("%s has no %s", lib.name, lib.first_missing(Entries));
        return;
    }

    // From here everything else comes out of that one function.
}
```

## Examples

```bash
c3c run demo
```

The demo opens the library this platform certainly has, takes one entry point
out of it, loads a table of three in the three shapes a field can take, prints
what the naming rules do, and then goes looking for every graphics library this
platform might keep - Direct3D 11 and 12, DXGI, OpenGL and Vulkan on Windows;
Vulkan, MoltenVK and OpenGL ES elsewhere - reporting which are installed and
which are not. Nothing in it needs a GPU, and nothing in it fails for want of
one.

## Build

```bash
c3c test          # run the test suite
c3c run demo      # build and run the demo tour
```

The tests load tables against a fake implementation rather than a real one:
which entry points a driver has is not something a test can arrange, and every
rule in `table` is about what happens when one is missing. So there are fakes
with everything, fakes missing an optional entry point, fakes missing a required
one, and fakes that answer only to an alias or a suffix - and the tests check
what was asked for, in what order, as well as what came back.

The rest run against the library this platform is guaranteed to already have -
on Windows `kernel32.dll`, which is in every process there has ever been - and
pass with nothing checked where there is no such guarantee, because a missing
libc says nothing about the code under test.

## Layout

```
fluxion_dyn.c3l/manifest.json   what a consumer's build reads
src/                            the library, one module per file
examples/demo.c3                the tour
project.json5                   this repository's own build: tests and the demo
```

## Requirements

C3 0.8.3.

## License

`SPDX-License-Identifier: CC0-1.0`

[CC0 1.0 Universal](LICENSE) - public domain dedication. Do whatever you like
with this, no attribution required.
