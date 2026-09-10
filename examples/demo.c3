// SPDX-License-Identifier: CC0-1.0

// A tour of Fluxion Dyn. Run it with `c3c run demo`.
//
// It opens a library this platform certainly has, takes one entry point out
// of it, then a whole table of them at once - required, optional, and one
// asked about but never called. Then it goes looking for the graphics
// libraries, which is what this library is really for: on any given machine
// some of them are there and some are not, and finding out which is the whole
// job.
//
// Nothing here needs a GPU, and nothing here fails for want of one.
module demo;
import std::io;
import fluxion::dyn;

// Something every process on this platform already has, and a couple of
// things it exports. The point of the demo is not these names - it is that
// the program asks for them instead of linking them.
const String HOST_LIBRARY = env::WIN32 ? "kernel32.dll" : (env::DARWIN ? "libSystem.B.dylib" : "libc.so.6");
const String HOST_TICKS = env::WIN32 ? "GetTickCount64" : "clock";

alias TicksFn = fn ulong();

struct Api
{
	String api;
	String[] names;
	String entry;
}

// The three graphics APIs nobody links against, under the names this platform
// keeps them by, and the one symbol that says the file is what it claims.
const Api[] GRAPHICS_WINDOWS = {
	{ "Direct3D 12", { "d3d12.dll" }, "D3D12CreateDevice" },
	{ "Direct3D 11", { "d3d11.dll" }, "D3D11CreateDevice" },
	{ "DXGI", { "dxgi.dll" }, "CreateDXGIFactory1" },
	{ "OpenGL", { "opengl32.dll" }, "wglGetProcAddress" },
	{ "Vulkan", { "vulkan-1.dll" }, "vkGetInstanceProcAddr" },
};
const Api[] GRAPHICS_DARWIN = {
	{ "Vulkan", { "libvulkan.dylib", "libvulkan.1.dylib" }, "vkGetInstanceProcAddr" },
	{ "MoltenVK", { "libMoltenVK.dylib" }, "vkGetInstanceProcAddr" },
	{ "OpenGL ES", { "libGLESv2.dylib" }, "glGetString" },
};
const Api[] GRAPHICS_ELSEWHERE = {
	{ "Vulkan", { "libvulkan.so.1", "libvulkan.so" }, "vkGetInstanceProcAddr" },
	{ "OpenGL", { "libGL.so.1", "libGL.so" }, "glXGetProcAddress" },
	{ "OpenGL ES", { "libGLESv2.so.2", "libGLESv2.so" }, "glGetString" },
};

// A few of the host library's exports, in the three shapes a field can take.
alias PidFn = fn uint();
alias FileTimeFn = fn void(void*);
alias GetpidFn = fn int();

struct WindowsExports
{
	// Required: this program will not run without it.
	PidFn getCurrentProcessId;
	// Optional, and present since Windows 8 - so the tag is how a program
	// says it can run on Windows 7 as well.
	FileTimeFn getSystemTimePreciseAsFileTime @tag("optional", true);
	// Present, and deliberately not described: whether it exists is the only
	// question this table is asking.
	void* createFileW @tag("optional", true);
}

struct PosixExports
{
	GetpidFn getpid;
	// Glibc has it; a musl or a BSD libc may not, so it is optional.
	GetpidFn gettid @tag("optional", true);
	void* abort @tag("optional", true);
}

fn void main()
{
	if (library::BACKEND == NONE)
	{
		io::printn("This platform has no run-time library loading, so there is\nnothing to open. Entry points have to arrive some other way,\nand `table` will still load them once they do.");
		return;
	}

	// --- one library, one entry point -------------------------------------
	//
	// `open_system` rather than `open`: this file belongs to the operating
	// system, so it should come from the system's own directories and from
	// nowhere a program could have a file dropped into.

	Library? opened = dyn::open_system(HOST_LIBRARY);
	if (catch err = opened)
	{
		io::printfn("Could not open %s: %s", HOST_LIBRARY, err);
		return;
	}
	Library lib = opened;
	defer lib.close();

	io::printfn("--- %s ---", lib.name);

	TicksFn ticks = lib.lookup(TicksFn, (ZString)HOST_TICKS.ptr);
	if (ticks != null) io::printfn("%s()  %d", HOST_TICKS, ticks());

	// A symbol that is not there is null, not a crash. That is the entire
	// reason to load this way rather than link.
	io::printfn("%s  %s\n", "NoSuchExportExists", lib.get("NoSuchExportExists") == null ? "absent" : "present");

	// --- a whole table at once --------------------------------------------
	//
	// The struct is the declaration and the list of what to fetch, so the two
	// cannot fall out of step. The field's tag says whether the entry point
	// is required.

	io::printn("--- a table, and what the machine had ---");
	$if env::WIN32:
		WindowsExports exports;
		Status status = table::try_load(&exports, &lib, { .capitalize = ALWAYS });
		io::printfn("%s", status);
		if (status.ok())
		{
			// The optional one may be null, so the program has to ask before
			// it calls - which is the version check happening where the
			// answer matters.
			io::printfn("%-32s %s", "GetSystemTimePreciseAsFileTime", exports.getSystemTimePreciseAsFileTime != null);
			// And the probe is a pointer nobody can call, which is the point
			// of it: whether it is there is the whole question.
			io::printfn("%-32s %s", "CreateFileW", exports.createFileW != null);
		}
	$else
		PosixExports exports;
		Status status = table::try_load(&exports, &lib);
		io::printfn("%s", status);
		if (status.ok())
		{
			io::printfn("%-32s %s", "gettid", exports.gettid != null);
			io::printfn("%-32s %s", "abort", exports.abort != null);
		}
	$endif
	io::printn("");

	// --- what the naming rules do -----------------------------------------
	//
	// All of this is compile time: these are the names a table would ask for.

	io::printn("--- field name to symbol name ---");
	io::printfn("  %-24s -> %s", "clear (prefix gl)", table::symbol_name("clear", { .prefix = "gl" }));
	io::printfn("  %-24s -> %s", "cmdDraw (prefix vk)", table::symbol_name("cmdDraw", { .prefix = "vk" }));
	io::printfn("  %-24s -> %s", "getDisplay (prefix egl)", table::symbol_name("getDisplay", { .prefix = "egl" }));
	io::printfn("  %-24s -> %s\n", "getTickCount64 (ALWAYS)", table::symbol_name("getTickCount64", { .capitalize = ALWAYS }));

	// --- the graphics libraries on this machine ---------------------------
	//
	// Which is the question this library exists to answer. None of these is
	// linked, none of them is guaranteed to be installed, and a program that
	// imported their symbols the ordinary way would not have got this far on a
	// machine missing any one of them.

	io::printn("--- graphics libraries on this machine ---");
	Api[] graphics = env::WIN32 ? GRAPHICS_WINDOWS : (env::DARWIN ? GRAPHICS_DARWIN : GRAPHICS_ELSEWHERE);
	foreach (api : graphics)
	{
		Library? found = dyn::open_any(api.names);
		if (catch found)
		{
			io::printfn("  %-14s not installed", api.api);
			continue;
		}
		Library open = found;
		defer open.close();

		@pool()
		{
			String entry = open.get(api.entry.zstr_tcopy()) != null ? api.entry : "(no entry point)";
			io::printfn("  %-14s %-20s %s", api.api, open.name, entry);
		};
	}

	io::printn("\nEvery line above is an answer rather than a crash, which is the\nwhole of it: the library is found at run time, every entry point is\nfetched by name, and a missing one is something this program gets to\ndecide about.");
}
