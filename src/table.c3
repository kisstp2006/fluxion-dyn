// SPDX-License-Identifier: CC0-1.0

// Filling a struct of function pointers with the entry points an
// implementation actually has.
//
// A table is a plain struct whose fields are function pointers, and the field
// names are the names to ask for:
//
//     alias MaskFn = fn void(uint mask);
//     alias ColorFn = fn void(float r, float g, float b, float a);
//     alias ArrayFn = fn void(uint array);
//
//     struct Minimal
//     {
//         MaskFn clear;
//         ColorFn clearColor;
//         ArrayFn bindVertexArray @tag("optional", true);
//     }
//
//     Minimal api;
//     table::load(&api, &get_proc_address, { .prefix = "gl" })!;
//
// which asks for `glClear`, `glClearColor` and `glBindVertexArray`. The struct
// is both the declaration and the list of what to fetch, so there is no second
// list to fall out of step with it, and nothing is generated: loading is a
// compile-time walk over the fields.
//
// **Optionality is a tag on the field, and that is the whole version policy.**
// In Zig it was in the type: a `?*const fn` could be null and a `*const fn`
// could not. Every C3 function pointer can be null, so the distinction moves
// to a `@tag("optional", true)` on the field, which the load reads at compile
// time. A required field missing fails the load and names it; an optional one
// is left null, and the call site checks before it calls - which puts "does
// this driver have compute shaders?" exactly where the answer matters.
//
// **A field may also be a `void*`**, which says "this entry point exists and
// this program does not describe how to call it". Presence alone is worth
// knowing, and a signature nobody calls is a way to get one wrong.
//
// **Three names, in order:** the name derived from the field, then the
// `@tag("alias", "...")` the field declares, then the derived name with each
// of `Naming.suffixes` on the end. Specific before blanket. A field can also
// name its symbol outright with `@tag("symbol", "D3D12CreateDevice")`, for an
// export whose spelling no rule would produce.
//
// Where the entry points come from is `resolver`'s business, so the same call
// loads out of a `Library`, a `wglGetProcAddress`, or a `vkGetInstanceProcAddr`
// holding its instance.
module fluxion::dyn::table;
import fluxion::dyn::resolver;
import std::io;

// Loading failed because an entry point the table requires was not there.
// `Status.missing` names it; `try_load` reports rather than fails.
faultdef SYMBOL_NOT_FOUND;

// Whether the first letter of a field name is raised on the way to the symbol
// name.
enum Capitalize
{
	// Raised when there is a prefix, left alone when there is not - which is
	// right for two of the three shapes that turn up in practice. `gl` and
	// `clear` are `glClear`; `vk` and `cmdDraw` are `vkCmdDraw`; no prefix
	// and `getpid` is `getpid`.
	AUTO,
	// Always, even with no prefix. For a DLL export table, whose names are
	// capitalised and which C3 will not let a field be: `getTickCount64` is
	// `GetTickCount64`.
	ALWAYS,
	// Never. For a library whose exports are `snake_case`, where raising the
	// first letter would name nothing at all.
	NEVER,
}

<*
 How field names are turned into the names the implementation knows. Passed
 to `load` and friends as a compile-time constant, since the names are built
 while the program is compiled.
*>
struct Naming
{
	// Put in front of the field name: `gl` for OpenGL and OpenGL ES, `vk` for
	// Vulkan, `egl`, `wgl` or `glX` for the window-system tables, which load
	// exactly the same way. Empty for a library whose exports are already
	// spelled the way the fields are.
	String prefix;

	// See `Capitalize`.
	Capitalize capitalize;

	// Tried, in order, when neither the derived name nor an alias is there:
	// `glBindVertexArray` first, then `glBindVertexArrayOES`.
	//
	// Empty by default, and worth leaving that way unless you know the
	// extension you are naming. An extension entry point is usually the same
	// function under an older name, but not always - `glBindFramebufferEXT`
	// belongs to a different object model than `glBindFramebuffer`, and
	// substituting one for the other produces a program that draws nothing:
	//
	//     // Vertex arrays on an ES 2.0 context, where they are an extension.
	//     table::load(&api, get, { .prefix = "gl", .suffixes = { "OES" } })!;
	String[] suffixes;
}

<*
 What a load found. `try_load` returns one; `load` turns anything but a clean
 one into `SYMBOL_NOT_FOUND`.
*>
struct Status (Printable)
{
	// Fields in the table.
	sz requested;
	// Fields the implementation had an address for.
	sz loaded;
	// Optional fields it had not; those are null.
	sz absent;
	// Required fields it had not. Those were left exactly as they were.
	sz lacking;
	// The first required field it had not, under the name it was asked for.
	// Empty when nothing was.
	String missing;
}

<*
 Is the table safe to call?
*>
fn bool Status.ok(&self)
{
	return self.lacking == 0;
}

fn sz? Status.to_format(&self, Formatter* f) @dynamic
{
	sz n = f.printf("%d/%d loaded", self.loaded, self.requested)!;
	if (self.absent > 0) n += f.printf(", %d optional absent", self.absent)!;
	if (self.missing.len > 0) n += f.printf(", %d required missing, first %s", self.lacking, self.missing)!;
	return n;
}

// -------------------------------------------------------------------------
// Loading
// -------------------------------------------------------------------------

<*
 Fill `table` - a pointer to a struct of function pointers - from `from`,
 under `$naming`.

 Where the entry points come from a context rather than a library, that
 context has to be current on the calling thread already: without one, some
 drivers return null and others return addresses for a context you are not
 using.
*>
macro void? load(table, from, Naming $naming = {})
{
	if (!try_load(table, from, $naming).ok()) return SYMBOL_NOT_FOUND~;
}

<*
 Fill `table` and report, rather than fail.

 Every field is attempted, including those after a missing required one, so
 the counts describe the whole table. Use it where a missing entry point is
 something to work around or to print in a startup log.

 The walk is `$foreach` over the struct's members, so the loop is unrolled
 while the program is compiled: each field gets its own lookup with its own
 candidate names spelled out as literals, and nothing is left of the
 reflection at run time.
*>
macro Status try_load(table, from, Naming $naming = {})
{
	var $Table = $Typeof(*table);
	@validate($Table);

	Status status = { .requested = $Table::members.len };

	// The braces matter: a `$foreach` body is pasted once per member, not
	// scoped once per member, so without them the second copy of `found`
	// would shadow the first.
	$foreach $member : $Table::members:
	{
		Proc found = null;
		$foreach $candidate : @candidates($member, $naming):
			if (found == null) found = resolver::get(from, $candidate);
		$endforeach

		if (found != null)
		{
			table.$member = ($Typefrom($member.type))found;
			status.loaded++;
		}
		else
		{
			$if @is_optional($member):
				table.$member = null;
				status.absent++;
			$else
				status.lacking++;
				if (status.missing.len == 0) status.missing = @candidates($member, $naming)[0];
			$endif
		}
	}
	$endforeach

	return status;
}

<*
 `load` into a fresh table, returned by value. For a table that is built once
 and kept, where there is nothing to fill in beforehand.
*>
macro bind($Table, from, Naming $naming = {})
{
	$Table table;
	load(&table, from, $naming)!;
	return table;
}

<*
 The name of the first required entry of `$Table` that `from` has not got, or
 the empty string if it has them all. "This driver has no vkCreateInstance"
 is worth printing; "SYMBOL_NOT_FOUND" is not.
*>
macro String first_missing($Table, from, Naming $naming = {})
{
	@validate($Table);
	$foreach $member : $Table::members:
		$if !@is_optional($member):
		{
			bool found = false;
			$foreach $candidate : @candidates($member, $naming):
				if (!found) found = resolver::get(from, $candidate) != null;
			$endforeach
			if (!found) return @candidates($member, $naming)[0];
		}
		$endif
	$endforeach
	return "";
}

<*
 Is every required entry of `$Table` there? For checking an implementation
 before committing to it.
*>
macro bool available($Table, from, Naming $naming = {})
{
	return first_missing($Table, from, $naming).len == 0;
}

// -------------------------------------------------------------------------
// Names
// -------------------------------------------------------------------------

// The capital of each lower-case letter, as one-character strings, because
// the only string operation available at compile time is concatenation.
const String[26] CAPITALS = {
	"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
	"N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
};

<*
 The name a field resolves to: the prefix, then the field name with its
 first letter raised if `Naming` says so.

 Compile time, and public because code that looks an entry point up by hand
 should spell it the same way the table does. The result is a string
 literal, so it is zero-terminated and `(ZString)name.ptr` is safe.
*>
macro String symbol_name(String $field, Naming $naming = {})
{
	return symbol_name_suffixed($field, $naming, "");
}

<*
 `symbol_name` with an extension suffix on the end: `bindVertexArray` and
 `OES` become `glBindVertexArrayOES`.
*>
macro String symbol_name_suffixed(String $field, Naming $naming, String $suffix)
{
	$if $field.len == 0:
		$error("fluxion-dyn: a table field must have a name");
	$endif
	$switch $naming.capitalize:
		$case ALWAYS:
			return $naming.prefix +++ @capitalized($field) +++ $suffix;
		$case NEVER:
			return $naming.prefix +++ $field +++ $suffix;
		$default:
			$if $naming.prefix.len > 0:
				return $naming.prefix +++ @capitalized($field) +++ $suffix;
			$else
				return $naming.prefix +++ $field +++ $suffix;
			$endif
	$endswitch
}

macro String @capitalized(String $field) @const @private
{
	$if $field[0] >= 'a' &&& $field[0] <= 'z':
		return CAPITALS[$field[0] - 'a'] +++ $field[1..];
	$else
		return $field;
	$endif
}

<*
 How many entry points a table has.
*>
macro sz count($Table)
{
	return $Table::members.len;
}

<*
 How many of them are optional - the width of the gap between the version a
 table requires and the version it can use.
*>
macro sz optional_count($Table)
{
	sz n = 0;
	$foreach $member : $Table::members:
		$if @is_optional($member):
			n++;
		$endif
	$endforeach
	return n;
}

// -------------------------------------------------------------------------
// The parts that only exist at compile time
// -------------------------------------------------------------------------

macro bool @is_optional($member) @const @private
{
	$if $member.has_tag("optional"):
		return $member.get_tag("optional");
	$else
		return false;
	$endif
}

// Every name to try for one field, in order: the derived name or the
// `symbol` tag, then the `alias` tag, then the suffixed forms. A compile-time
// list, so `$foreach` can walk it and `[0]` names the first.
macro @candidates($member, Naming $naming) @const @private
{
	// Declared before the `$if`, which is a scope of its own for `$`-variables.
	var $list = { symbol_name($member.name, $naming) };
	$if $member.has_tag("symbol"):
		$list = { $member.get_tag("symbol") };
	$endif
	$if $member.has_tag("alias"):
		$list = $list +++ { $member.get_tag("alias") };
	$endif
	$foreach $suffix : $naming.suffixes:
		$list = $list +++ { symbol_name_suffixed($member.name, $naming, $suffix) };
	$endforeach
	return $list;
}

// Every field must be a function pointer or a `void*`. Anything else is a
// mistake worth catching at compile time rather than a pointer cast that
// happens to go through.
macro void @validate($Table) @private
{
	$if $Table::kind != STRUCT:
		$error("fluxion-dyn: an entry point table must be a struct, not " +++ $Table::name);
	$endif
	$foreach $member : $Table::members:
		$switch $member.type.kind:
			$case FUNC:
				// A function pointer, which is what the table is for. The
				// `$assert` is there so the case is not empty: an empty `$case`
				// falls through to the next one, as in C.
				$assert(true);
			$case POINTER:
				var $Pointer = $Typefrom($member.type);
				$if $Pointer::inner != void::typeid:
					$error("fluxion-dyn: field '" +++ $member.name +++ "' of " +++ $Table::name +++ " is a pointer to something other than void; an entry point table holds function pointers, or `void*` when its presence is all the program wants to know");
				$endif
			$default:
				$error("fluxion-dyn: field '" +++ $member.name +++ "' of " +++ $Table::name +++ " is " +++ $member.type.name +++ ", but an entry point table holds function pointers - a `fn` type when the entry point is required, the same with @tag(\"optional\", true) when it may be absent, and `void*` when its presence is all the program wants to know");
		$endswitch
	$endforeach
}

// -------------------------------------------------------------------------
// Tests
//
// Against a fake implementation rather than a real one: which entry points a
// driver has is not something a test can arrange, and every rule in this file
// is about what happens when one is missing.
// -------------------------------------------------------------------------

fn void stub() {}

// An implementation that has exactly the entry points it was told to have,
// and remembers what it was asked for.
struct Fake
{
	String[] have;
	String[32] asked;
	sz asked_len;
}

fn Proc Fake.get(&self, ZString name)
{
	String wanted = name.str_view();
	if (self.asked_len < self.asked.len)
	{
		self.asked[self.asked_len] = wanted;
		self.asked_len++;
	}
	foreach (entry : self.have)
	{
		if (entry == wanted) return (Proc)&stub;
	}
	return null;
}

fn String[] Fake.asked_for(&self)
{
	return self.asked[:self.asked_len];
}

// A function pointer type has to be named before a struct field can have
// it: `fn void(uint) clear;` is not a declaration C3 accepts, but
// `MaskFn clear;` is.
alias MaskFn = fn void(uint mask);
alias GetErrorFn = fn uint();
alias ArrayFn = fn void(uint array);
alias VoidFn = fn void();
alias TicksFn = fn ulong();

struct Basic
{
	MaskFn clear;
	GetErrorFn getError;
	ArrayFn bindVertexArray @tag("optional", true);
}

const Naming GL = { .prefix = "gl" };

fn void test_field_names_become_symbol_names() @test
{
	test::eq(symbol_name("clear", GL), "glClear");
	test::eq(symbol_name("getError", GL), "glGetError");
	// The underscore a few of them carry in the middle survives untouched.
	test::eq(symbol_name("getIntegeri_v", GL), "glGetIntegeri_v");
	// A different API, loaded by the same machinery.
	test::eq(symbol_name("cmdDraw", { .prefix = "vk" }), "vkCmdDraw");
	test::eq(symbol_name("getDisplay", { .prefix = "egl" }), "eglGetDisplay");
	test::eq(symbol_name_suffixed("bindVertexArray", GL, "OES"), "glBindVertexArrayOES");
}

fn void test_no_prefix_means_the_field_name_as_it_is_written() @test
{
	// A library whose exports are lower case keeps them that way, which `AUTO`
	// gets right and `ALWAYS` would not.
	test::eq(symbol_name("getpid"), "getpid");
	test::eq(symbol_name("getpid", { .capitalize = ALWAYS }), "Getpid");
	test::eq(symbol_name("clear", { .prefix = "gl", .capitalize = NEVER }), "glclear");

	// And a DLL export table, whose names are capitalised where a C3 field
	// cannot be, asks for `ALWAYS`.
	test::eq(symbol_name("getTickCount64", { .capitalize = ALWAYS }), "GetTickCount64");
}

fn void test_the_names_of_a_whole_table() @test
{
	test::eq(count(Basic), 3);
	test::eq(optional_count(Basic), 1);
}

fn void test_an_implementation_with_everything() @test
{
	Fake fake = { .have = { "glClear", "glGetError", "glBindVertexArray" } };
	Basic api;
	load(&api, &fake, GL)!!;

	// Asked for in field order, once each.
	test::eq(fake.asked_for().len, 3);
	test::eq(fake.asked_for()[0], "glClear");
	test::eq(fake.asked_for()[2], "glBindVertexArray");
	test::@check(api.bindVertexArray != null);
}

fn void test_an_implementation_missing_an_optional_entry_point() @test
{
	Fake fake = { .have = { "glClear", "glGetError" } };
	Basic api;
	Status status = try_load(&api, &fake, GL);

	test::@check(status.ok());
	test::eq(status.requested, 3);
	test::eq(status.loaded, 2);
	test::eq(status.absent, 1);
	test::@check(api.bindVertexArray == null);

	// Which is not an error, so the plain call goes through as well.
	load(&api, &fake, GL)!!;
	test::@check(available(Basic, &fake, GL));
}

fn void test_an_implementation_missing_a_required_entry_point() @test
{
	Fake fake = { .have = { "glClear" } };
	Basic api;

	Status status = try_load(&api, &fake, GL);
	test::@check(!status.ok());
	test::eq(status.lacking, 1);
	test::eq(status.missing, "glGetError");

	test::@error(load(&api, &fake, GL), SYMBOL_NOT_FOUND);
	test::@error(bind(Basic, &fake, GL), SYMBOL_NOT_FOUND);

	// Which one, for the message. `SYMBOL_NOT_FOUND` on its own says nothing
	// about the machine it happened on.
	test::eq(first_missing(Basic, &fake, GL), "glGetError");
	test::@check(!available(Basic, &fake, GL));
}

fn void test_every_field_is_attempted_not_just_the_ones_before_the_first_failure() @test
{
	// A required entry point missing in the middle does not stop the walk, so
	// the counts describe the whole table - which is what makes the status
	// worth printing rather than just testing.
	Fake fake = { .have = { "glClear" } };
	Basic api;
	Status status = try_load(&api, &fake, GL);

	test::eq(status.requested, 3);
	test::eq(status.loaded, 1);
	test::eq(status.lacking, 1);
	test::eq(status.absent, 1);
	test::eq(fake.asked_for().len, 3);
}

fn void test_the_suffix_fallback_and_only_when_it_is_asked_for() @test
{
	String[] have = { "glClear", "glGetError", "glBindVertexArrayOES" };

	Fake without = { .have = have };
	Basic api;
	test::eq(try_load(&api, &without, GL).absent, 1);

	Fake with = { .have = have };
	Status status = try_load(&api, &with, { .prefix = "gl", .suffixes = { "OES" } });
	test::eq(status.absent, 0);
	test::@check(api.bindVertexArray != null);

	// The plain name is still tried first, so a core entry point is never
	// quietly answered by an extension.
	test::eq(with.asked_for()[2], "glBindVertexArray");
	test::eq(with.asked_for()[3], "glBindVertexArrayOES");
}

struct Promoted
{
	// Core in Vulkan 1.1, and an extension before that.
	VoidFn getPhysicalDeviceProperties2 @tag("optional", true) @tag("alias", "vkGetPhysicalDeviceProperties2KHR");
}

const Naming VK_EXT = { .prefix = "vk", .suffixes = { "EXT" } };

fn void test_an_alias_is_tried_before_a_suffix_and_after_the_derived_name() @test
{
	// A driver old enough that the command is still an extension.
	Fake old = { .have = { "vkGetPhysicalDeviceProperties2KHR" } };
	Promoted api;
	Status status = try_load(&api, &old, VK_EXT);
	test::@check(status.ok());
	test::eq(status.loaded, 1);
	test::@check(api.getPhysicalDeviceProperties2 != null);

	// Derived name first, then the alias, then the suffixed form - and the
	// walk stops as soon as one answers, so the suffix is never reached here.
	test::eq(old.asked_for().len, 2);
	test::eq(old.asked_for()[0], "vkGetPhysicalDeviceProperties2");
	test::eq(old.asked_for()[1], "vkGetPhysicalDeviceProperties2KHR");

	// On a driver that has none of them, all three are tried in that order.
	Fake none = { .have = {} };
	try_load(&api, &none, VK_EXT);
	test::eq(none.asked_for().len, 3);
	test::eq(none.asked_for()[2], "vkGetPhysicalDeviceProperties2EXT");
}

struct Probe
{
	// No signature, so nothing can call it and nothing can get the signature
	// wrong - but its presence is still an answer, and often the one a
	// program is actually asking for. The `symbol` tag spells the export
	// outright, since no rule turns a C3 field name into `D3D12CreateDevice`.
	void* create_device @tag("optional", true) @tag("symbol", "D3D12CreateDevice");
	void* get_debug_interface @tag("optional", true) @tag("symbol", "D3D12GetDebugInterface");
}

fn void test_a_field_that_is_only_asked_whether_it_exists() @test
{
	Fake fake = { .have = { "D3D12CreateDevice" } };
	Probe probe = bind(Probe, &fake)!!;

	test::@check(probe.create_device != null);
	test::@check(probe.get_debug_interface == null);
	test::eq(fake.asked_for()[0], "D3D12CreateDevice");
}

fn Proc driver_get(ZString name)
{
	if (name.str_view() == "glBindVertexArray") return null;
	return (Proc)&stub;
}

fn void test_a_resolver_that_is_a_plain_get_proc_address() @test
{
	Basic api;
	load(&api, &driver_get, GL)!!;
	test::@check(api.bindVertexArray == null);
	test::@check(api.clear != null);

	// The C type is the same function, so the typed pointer form works too.
	GetProcAddress pointer = &driver_get;
	load(&api, pointer, GL)!!;
}

fn void test_the_status_prints_as_one_line_for_a_startup_log() @test
{
	Fake fake = { .have = { "glClear" } };
	Basic api;
	Status status = try_load(&api, &fake, GL);
	@pool()
	{
		test::eq(string::tformat("%s", status), "1/3 loaded, 1 optional absent, 1 required missing, first glGetError");
	};
}

struct Exports
{
	TicksFn getTickCount64;
	void* noSuchExport @tag("optional", true);
}

fn void test_a_capitalised_export_table() @test
{
	Fake fake = { .have = { "GetTickCount64" } };
	Exports t = bind(Exports, &fake, { .capitalize = ALWAYS })!!;
	test::@check(t.noSuchExport == null);
	test::eq(fake.asked_for()[0], "GetTickCount64");
	test::eq(fake.asked_for()[1], "NoSuchExport");
}
