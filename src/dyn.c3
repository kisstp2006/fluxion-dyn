// SPDX-License-Identifier: CC0-1.0

// Fluxion Dyn - finding a shared library at run time, and turning names into
// function pointers.
//
// Three pieces, each its own module under `fluxion::dyn`:
//
//   `resolver`  where a name becomes a pointer, and what may act as one
//   `library`   opening the platform's shared libraries, and one symbol at a
//               time out of them
//   `table`     a whole struct of function pointers, filled in by field name
//
// Everything an operating system will not let you link against arrives this
// way: `d3d12.dll` is missing before Windows 10, `libvulkan.so.1` comes from a
// GPU driver, `opengl32.dll` exports the commands of 1997 and nothing since.
// A program that imports any of those the ordinary way fails to start rather
// than falling back. So the library is opened by name, every entry point is
// fetched by name, and the program decides what a missing one means.
//
//     struct Entries
//     {
//         CreateDeviceFn createDevice @tag("symbol", "D3D12CreateDevice");
//         // Missing on a machine without the Graphics Tools feature, and that
//         // is not a reason to refuse to run.
//         DebugFn getDebugInterface @tag("symbol", "D3D12GetDebugInterface") @tag("optional", true);
//     }
//
//     Library lib = dyn::open_system("d3d12.dll")!;
//     defer lib.close();
//
//     Entries entries = lib.bind(Entries)!;
//
// **Optionality is a tag on the field.** A plain function pointer field must
// be found or loading fails and says which one was missing; one tagged
// optional may be absent and is left null, so the call site has to ask. That
// is the whole version policy, and why one table can describe an API across
// every version of it a program is willing to run on.
//
// **A resolver is anything that answers a name**: an open `Library`, a
// `wglGetProcAddress`, a `vkGetInstanceProcAddr` holding its instance, a
// `Chain` that tries one and then another. `table::load` takes any of them.
//
// Nothing here allocates past the temporary allocator, and nothing here is
// generated: a table is an ordinary struct, and loading it is a compile-time
// walk over its fields. This module holds the shorthands; importing
// `fluxion::dyn` imports the three sub-modules with it.
module fluxion::dyn;
import fluxion::dyn::resolver, fluxion::dyn::library, fluxion::dyn::table;

<*
 Open a library that belongs to the operating system, by bare name.
 Shorthand for `library::open_system`, and the right call for `d3d12.dll`,
 `vulkan-1.dll` and `opengl32.dll`.
*>
fn Library? open_system(String name)
{
	return library::open_system(name);
}

<*
 Open one library by name or path. Shorthand for `library::open`, and the
 right call for a library that ships beside the program.
*>
fn Library? open(String path)
{
	return library::open(path);
}

<*
 Open the first of `paths` that opens. Shorthand for `library::open_any`.
*>
fn Library? open_any(String[] paths)
{
	return library::open_any(paths);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const String HOST_LIBRARY = env::WIN32 ? "kernel32.dll" : (env::DARWIN ? "libSystem.B.dylib" : "libc.so.6");

// A few of the host library's exports, in the three shapes a field can take.
// The Windows names are capitalised, which a C3 field cannot be, so the table
// loads with `ALWAYS` and `getCurrentProcessId` asks for `GetCurrentProcessId`.
alias TicksFn = fn ulong();
alias PidFn = fn uint();
alias GetpidFn = fn int();

struct WindowsExports
{
	TicksFn getTickCount64;
	PidFn getCurrentProcessId;
	// There, and deliberately not described: this table only wants to know
	// whether it exists.
	void* createFileW @tag("optional", true);
	// Not there, and allowed not to be.
	TicksFn thisWasNeverAnExport @tag("optional", true);
}

struct PosixExports
{
	GetpidFn getpid;
	void* abort @tag("optional", true);
	TicksFn this_was_never_an_export @tag("optional", true);
}

fn void test_the_pieces_compose() @test
{
	// The whole library in one go: open something the platform certainly has,
	// describe some of what it exports, and load that description.
	if (try lib = open_system(HOST_LIBRARY))
	{
		defer lib.close();
		$if env::WIN32:
			// Every required entry point is there, so there is nothing to report.
			test::eq(lib.first_missing(WindowsExports, { .capitalize = ALWAYS }), "");
			WindowsExports exports = lib.bind(WindowsExports, { .capitalize = ALWAYS })!!;
			test::@check(exports.getTickCount64() > 0);
			test::@check(exports.getCurrentProcessId() != 0);
			test::@check(exports.createFileW != null);
			test::@check(exports.thisWasNeverAnExport == null);
		$else
			test::eq(lib.first_missing(PosixExports), "");
			PosixExports exports = lib.bind(PosixExports)!!;
			test::@check(exports.getpid() != 0);
			test::@check(exports.abort != null);
			test::@check(exports.this_was_never_an_export == null);
		$endif
	}
}

struct TooMuch
{
	TicksFn thisWasNeverAnExport;
}

fn void test_a_table_that_wants_more_than_the_machine_has() @test
{
	if (try lib = open_system(HOST_LIBRARY))
	{
		defer lib.close();
		test::@error(lib.bind(TooMuch, { .capitalize = ALWAYS }), table::SYMBOL_NOT_FOUND);
		// Which is where a message worth printing comes from.
		test::eq(lib.first_missing(TooMuch, { .capitalize = ALWAYS }), "ThisWasNeverAnExport");
	}
}
