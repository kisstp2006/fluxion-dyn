// SPDX-License-Identifier: CC0-1.0

// Opening a shared library at run time, and getting entry points out of it.
//
// A graphics API is not a library you link against. `d3d12.dll` is absent
// before Windows 10, `libvulkan.so.1` comes from a GPU driver, `opengl32.dll`
// exports the commands of 1997 and nothing since. A program that imports any
// of those the ordinary way does not start at all where one is missing: the
// loader fails before `main`, with no way to fall back. So it asks at run
// time instead, and decides for itself what a missing entry point means.
//
//     Library lib = library::open_system("vulkan-1.dll")!;
//     defer lib.close();
//
//     PfnGetInstanceProcAddr entry = lib.lookup(PfnGetInstanceProcAddr, "vkGetInstanceProcAddr");
//     if (entry == null) return NOT_A_VULKAN_LOADER~;
//
// Four ways in, and the choice is about where the file may come from:
//
//   `open_system`  a bare name, from the system's own directories and nowhere
//                  else. For `vulkan-1.dll`, `opengl32.dll`, `d3d12.dll`.
//   `open`         one name or path, searched however this platform searches.
//                  For a library shipping beside the program: ANGLE's
//                  `libGLESv2.dll`, a MoltenVK inside an app bundle.
//   `open_any`     the first of a list that opens.
//   `from_handle`  a handle somebody else opened.
//
// **Why `open_system` is not just `open` with a shorter name.** On Windows,
// `LoadLibrary("d3d12.dll")` searches the program's own directory first, so
// anyone who can write a file next to the executable can have it loaded with
// the process's privileges. This is old, it has a name (DLL planting), and
// the fix is one flag: `LOAD_LIBRARY_SEARCH_SYSTEM32`. On POSIX `dlopen`
// already has that property. What is the same on both is the rule:
// `open_system` refuses a name with a path in it.
//
// **A `Library` is itself a resolver.** It has a `get`, so `table::load(&api,
// &lib)` reads a whole table straight out of the export table, and `Chain`
// puts one behind a context's `getProcAddress`.
//
// **Where a platform has no run-time loading** - `wasm32`, a POSIX target
// without a libc - `BACKEND` is `NONE` and every open returns
// `NOT_SUPPORTED`, rather than refusing to build. A program there gets its
// entry points from somewhere else entirely.
//
// The platform calls live in three module sections at the bottom of this
// file, each under `@feat`: the compiler keeps the one section whose feature
// list matches the target and drops the others, which is how one file
// declares `LoadLibraryExW` for Windows and `dlopen` for POSIX without either
// seeing the other's headers.
module fluxion::dyn::library;
import fluxion::dyn::resolver, fluxion::dyn::table;

// How this platform opens a library at run time.
enum Backend
{
	// `LoadLibraryExW`, `GetProcAddress`, `FreeLibrary`.
	WINDOWS,
	// `dlopen`, `dlsym`, `dlclose`, which need a libc.
	POSIX,
	// Nothing. Not a gap in this library - the platform has no run-time
	// loading to reach, so there is nothing to open and the entry points have
	// to come from somewhere else.
	NONE,
}

// Which one this build got. Anything outside the two is `NONE` rather than a
// compile error, so that a cross-platform build matrix still builds.
const Backend BACKEND = env::WIN32 ? WINDOWS : (env::POSIX && env::LIBC ? POSIX : NONE);

// Nothing opened under that name. Usually it is not installed - this is the
// answer on a machine with no GPU driver - but a library that fails its own
// initialisation arrives here too, and the platform does not say which.
faultdef LIBRARY_NOT_FOUND;

// `open_system` was given something that is not a bare file name: empty, too
// long, or with a directory separator in it.
faultdef INVALID_NAME;

// A path longer than `MAX_PATH_LEN`. Said rather than truncated: a truncated
// path can name a real file.
faultdef NAME_TOO_LONG;

// This platform has no run-time library loading at all - see `BACKEND`.
faultdef NOT_SUPPORTED;

// The longest name `open_system` takes, in bytes. A system library name is a
// dozen characters; this is generous.
const sz MAX_NAME_LEN = 128;

// The longest path `open` takes. Windows itself allows longer; a path this
// long is a mistake, and `open` says so rather than passing it on.
const sz MAX_PATH_LEN = 1024;

<*
 An open shared library, and the one reference to it this value owns.

 Closing it unmaps the code every entry point taken out of it points at, so
 the order at shutdown is: let go of everything the library handed out, and
 only then `close`.
*>
struct Library
{
	// `HMODULE` on Windows, the `dlopen` handle on POSIX. Both are a pointer
	// the platform hands out and takes back, so one field serves both.
	void* handle;
	// The name it opened under, for when which one matters - `libMoltenVK`
	// is a different answer from `libvulkan`. Kept rather than copied, so a
	// path built at run time has to outlive the `Library`.
	String name;
}

<*
 Open one library by name or path, searched however this platform searches.
 For a library that ships with the program; for one that belongs to the
 system, `open_system` is the safer call.
*>
fn Library? open(String path)
{
	if (BACKEND == NONE) return NOT_SUPPORTED~;
	if (path.len > MAX_PATH_LEN) return NAME_TOO_LONG~;
	void* handle = sys_open(path, false)!;
	return { .handle = handle, .name = path };
}

<*
 Open the first of `paths` that opens. `LIBRARY_NOT_FOUND` only when none of
 them does - which is how a platform with a versioned name, an unversioned
 symlink and a fallback is handled in one call.
*>
fn Library? open_any(String[] paths)
{
	if (BACKEND == NONE) return NOT_SUPPORTED~;
	foreach (path : paths)
	{
		// `if (try lib = open(path))` runs the body only when the optional
		// holds a value, and the fault of a miss is simply dropped: the next
		// name gets its turn.
		if (try lib = open(path)) return lib;
	}
	return LIBRARY_NOT_FOUND~;
}

<*
 Open a library that belongs to the operating system, by bare name, from the
 system's own directories and nowhere else - see the module comment. A name
 with a directory separator is `INVALID_NAME` everywhere.

 The system keeps one module per process and counts references, so a second
 open is cheap and gives the same handle - and needs its `close`.
*>
fn Library? open_system(String name)
{
	if (name.len == 0 || name.len > MAX_NAME_LEN) return INVALID_NAME~;
	foreach (c : name)
	{
		if (c == '\\' || c == '/' || c == ':') return INVALID_NAME~;
	}
	if (BACKEND == NONE) return NOT_SUPPORTED~;
	// On POSIX `dlopen` of a bare name already consults the configured
	// search paths and never the program's own directory, so the flag only
	// changes anything on Windows.
	void* handle = sys_open(name, true)!;
	return { .handle = handle, .name = name };
}

<*
 Wrap a handle that came from somewhere else - a `LoadLibraryEx` with flags
 this module does not offer, or a module already in the process.

 `close` frees it either way, so only wrap a handle whose reference this
 `Library` is meant to own. A `GetModuleHandle` result is not one.
*>
fn Library from_handle(void* handle, String name)
{
	return { .handle = handle, .name = name };
}

<*
 Drop this reference. Every entry point the library handed out dies with the
 last one, so nothing may be called afterwards.
*>
fn void Library.close(&self)
{
	sys_close(self.handle);
	*self = {};
}

<*
 One exported symbol, untyped, or null if the library has not got it. This
 is the `get` that makes a `Library` a resolver.
*>
fn Proc Library.get(&self, ZString name)
{
	return sys_get(self.handle, name);
}

<*
 One exported symbol as the type you say it is, or null.

 Nothing checks `$Fn` against what the library exports, so a wrong signature
 here is a corrupt stack later and worth reading twice. By name, never by
 ordinal: ordinals move between releases.
*>
macro Library.lookup(&self, $Fn, ZString symbol)
{
	return ($Fn)self.get(symbol);
}

<*
 Resolve a whole table of entry points in one call. See `table`, which this
 hands straight to: the field names are the symbol names, and a field tagged
 optional is one the library is allowed not to have.
*>
macro Library.bind(&self, $Table, Naming $naming = {})
{
	return table::bind($Table, self, $naming);
}

<*
 The name of the first required entry of `$Table` this library does not
 export, or the empty string if it exports them all. For turning a `bind`
 failure into a message that says what is actually wrong with the machine.
*>
macro String Library.first_missing(&self, $Table, Naming $naming = {})
{
	return table::first_missing($Table, self, $naming);
}

<*
 A context's `getProcAddress` first, a library's exports second.

 On Windows this is not an optimisation. `wglGetProcAddress` returns null for
 everything that was in OpenGL 1.1 - `glClear`, `glViewport`, `glDrawArrays`,
 the ones every frame calls - because those are exported from `opengl32.dll`
 directly. Asking only the context leaves a table full of holes in the oldest
 and most-used commands.

     Library opengl32 = library::open_system("opengl32.dll")!;
     defer opengl32.close();

     Chain chain = { .context = &wglGetProcAddress, .library = &opengl32 };
     table::load(&api, &chain)!;

 Elsewhere the fallback is harmless: GLX and EGL answer for everything they
 know, so the chain never reaches its second link. Both links may be null,
 which is how a program says "just the library" or "just the context".
*>
struct Chain
{
	// What the window system gave you: `wglGetProcAddress`,
	// `glXGetProcAddressARB`, `eglGetProcAddress`.
	GetProcAddress context;
	// The library to fall back to, still open for as long as the chain is
	// used.
	Library* library;
}

<*
 The `get` that makes this a resolver.
*>
fn Proc Chain.get(&self, ZString name)
{
	if (self.context != null)
	{
		Proc from_context = self.context(name);
		if (from_context != null) return from_context;
	}
	if (self.library != null) return self.library.get(name);
	return null;
}

// -------------------------------------------------------------------------
// Windows
// -------------------------------------------------------------------------

module fluxion::dyn::library @feat(WIN32);
import fluxion::dyn::resolver;
import std::os::win32;

// `LOAD_LIBRARY_SEARCH_SYSTEM32`: look in the system directory and stop.
const uint SEARCH_SYSTEM32 = 0x00000800;

fn void*? sys_open(String path, bool system_only)
{
	// The wide-character call, because the ANSI one cannot spell every path
	// a user's home directory may be under. The conversion lives in the
	// temporary allocator, which `@pool` opens for this block and frees at
	// its end - by which time `LoadLibraryExW` has copied what it needs.
	@pool()
	{
		WString? wide = path.to_wstring(tmem);
		if (catch wide) return LIBRARY_NOT_FOUND~;
		Win32_HMODULE handle = win32::loadLibraryExW(wide, null, system_only ? SEARCH_SYSTEM32 : 0);
		if (handle == null) return LIBRARY_NOT_FOUND~;
		return handle;
	};
}

fn void sys_close(void* handle)
{
	win32::freeLibrary(handle);
}

fn Proc sys_get(void* handle, ZString name)
{
	return (Proc)win32::getProcAddress(handle, (Win32_LPCSTR)name);
}

// -------------------------------------------------------------------------
// POSIX
// -------------------------------------------------------------------------

module fluxion::dyn::library @feat(POSIX & LIBC);
import fluxion::dyn::resolver;

fn void*? sys_open(String path, bool system_only)
{
	@pool()
	{
		void* handle = libc::dlopen(path.zstr_tcopy(), libc::RTLD_NOW);
		if (handle == null) return LIBRARY_NOT_FOUND~;
		return handle;
	};
}

fn void sys_close(void* handle)
{
	libc::dlclose(handle);
}

fn Proc sys_get(void* handle, ZString name)
{
	return (Proc)libc::dlsym(handle, name);
}

// -------------------------------------------------------------------------
// Everywhere else
// -------------------------------------------------------------------------

module fluxion::dyn::library @feat(!WIN32 & !(POSIX & LIBC));
import fluxion::dyn::resolver;

fn void*? sys_open(String path, bool system_only)
{
	return NOT_SUPPORTED~;
}

fn void sys_close(void* handle)
{
	// Unreachable in practice: with no backend there is no way to have
	// opened one. Harmless if reached.
}

fn Proc sys_get(void* handle, ZString name)
{
	return null;
}

// -------------------------------------------------------------------------
// Tests
//
// Against whatever library this platform is guaranteed to have already: on
// Windows `kernel32.dll`, which is in every process there has ever been. Where
// there is no such guarantee the test skips rather than failing, because a
// missing libc says nothing about the code under test.
// -------------------------------------------------------------------------

module fluxion::dyn::library;
import fluxion::dyn::resolver;

// A library every process on this platform already has, and one symbol it
// certainly exports.
const String KNOWN_LIBRARY = env::WIN32 ? "kernel32.dll" : (env::DARWIN ? "libSystem.B.dylib" : "libc.so.6");
const String KNOWN_SYMBOL = env::WIN32 ? "GetTickCount64" : "getpid";

alias KnownFn = fn ulong();

// There is no "skip" in C3's test runner, so a test that cannot run on this
// platform passes with nothing checked. `if (try lib = open_known())` is
// the shape.
fn Library? open_known()
{
	if (BACKEND == NONE) return NOT_SUPPORTED~;
	return open_system(KNOWN_LIBRARY);
}

fn void test_opening_a_system_library_and_calling_something_out_of_it() @test
{
	if (try lib = open_known())
	{
		defer lib.close();
		KnownFn call = lib.lookup(KnownFn, (ZString)KNOWN_SYMBOL.ptr);
		test::@check(call != null);
		test::@check(call() != 0);
	}
}

fn void test_a_symbol_that_is_not_there_is_null_not_a_crash() @test
{
	if (try lib = open_known())
	{
		defer lib.close();
		test::@check(lib.get("fluxion_dyn_no_such_export") == null);
		test::@check(lib.lookup(KnownFn, "fluxion_dyn_no_such_export") == null);
	}
}

fn void test_a_library_that_is_not_there() @test
{
	if (BACKEND == NONE) return;

	// Not an assertion about this machine: no platform loads a library under
	// this name, whatever happens to be installed on it.
	test::@error(open("fluxion-dyn-no-such-library-0000"), LIBRARY_NOT_FOUND);
	test::@error(open_any({ "fluxion-dyn-no-such-library-0000.so", "fluxion-dyn-no-such-library-0000.dll" }), LIBRARY_NOT_FOUND);
}

fn void test_open_system_refuses_anything_that_is_not_a_bare_name() @test
{
	// Each of these would either bypass the system-only search or be taken
	// literally, and quietly loading the wrong file is the failure worth
	// preventing.
	test::@error(open_system("C:\\Windows\\System32\\kernel32.dll"), INVALID_NAME);
	test::@error(open_system("..\\kernel32.dll"), INVALID_NAME);
	test::@error(open_system("/usr/lib/libc.so.6"), INVALID_NAME);
	test::@error(open_system("sub/libc.so.6"), INVALID_NAME);
	test::@error(open_system(""), INVALID_NAME);
	char[MAX_NAME_LEN + 1] long_name;
	long_name[..] = 'x';
	test::@error(open_system((String)long_name[..]), INVALID_NAME);
}

fn void test_a_path_too_long_is_refused_rather_than_truncated() @test
{
	if (BACKEND == NONE) return;
	char[MAX_PATH_LEN + 1] too_long;
	too_long[..] = 'x';
	test::@error(open((String)too_long[..]), NAME_TOO_LONG);
	test::@error(open((String)too_long[:MAX_PATH_LEN]), LIBRARY_NOT_FOUND);
}

fn void test_the_module_is_shared_and_counted() @test
{
	// Two opens of one library are one module: the operating system keeps a
	// table per process and hands back the same handle with the count raised.
	// Which is why each open needs its own close, and why closing one of them
	// leaves the other perfectly usable.
	if (BACKEND != WINDOWS) return;

	if (try first = open_known())
	{
		defer first.close();
		Library second = open_known()!!;
		test::@check(first.handle == second.handle);
		second.close();
		test::@check(first.get((ZString)KNOWN_SYMBOL.ptr) != null);
	}
}

fn void chain_stub() {}

fn Proc context_get(ZString name)
{
	if (name.str_view() == "only_from_the_context") return (Proc)&chain_stub;
	return null;
}

fn void test_a_library_is_a_resolver_and_a_chain_puts_one_behind_another() @test
{
	// With neither link there is nothing to ask, and that is not a crash.
	Chain empty;
	test::@check(empty.get("anything") == null);

	Chain context_only = { .context = &context_get };
	test::@check(context_only.get("only_from_the_context") != null);
	test::@check(context_only.get((ZString)KNOWN_SYMBOL.ptr) == null);

	if (try lib = open_known())
	{
		defer lib.close();
		// And with a library behind it, the symbol the context has not got is
		// found anyway - which is the whole point on Windows.
		Chain chain = { .context = &context_get, .library = &lib };
		test::@check(chain.get("only_from_the_context") != null);
		test::@check(chain.get((ZString)KNOWN_SYMBOL.ptr) != null);
		test::@check(chain.get("fluxion_dyn_no_such_export") == null);
	}
}
