// SPDX-License-Identifier: CC0-1.0

// Where a name becomes a function pointer.
//
// An entry point is found either by looking the symbol up in a shared library
// - `GetProcAddress`, `dlsym`, which is what `Library` does - or by asking a
// function the API hands out: `wglGetProcAddress`, `eglGetProcAddress`,
// `vkGetInstanceProcAddr`.
//
// A *resolver* is anything that answers the second kind of question, and it is
// duck-typed on purpose so that all of these work with no adapter:
//
//   * a `getProcAddress` function, passed by address
//   * a pointer to any struct with a `get(ZString name)` method returning a
//     `Proc` - an open `Library`, a fallback `Chain`, a Vulkan resolver holding
//     its instance
//
// Duck-typing rather than one interface type is what keeps the calling
// convention out of this library's hands: passed to a macro with no declared
// type and called directly, each is called exactly as it was declared.
module fluxion::dyn::resolver;

<*
 A function pointer of unknown signature, which is all any lookup promises to
 return. Null when the name was not found.

 Nothing ever calls a `Proc`. Each is cast to its field's type on the way
 into a table, and it is that declaration which carries the real signature -
 which is why the tables in a binding are worth reading twice.
*>
alias Proc = fn void();

<*
 The shape of most `getProcAddress` functions in the wild: `wglGetProcAddress`,
 `glXGetProcAddressARB`, `eglGetProcAddress`, `glfwGetProcAddress`,
 `SDL_GL_GetProcAddress`.

 A convenience, not a requirement - see the module comment. One that takes an
 extra handle is passed as a struct holding it.

 On 32-bit Windows `wglGetProcAddress` is `stdcall`, which C3 can put on a
 function but not on a function pointer type; on 64-bit Windows and
 everywhere else `stdcall` and the C convention are the same thing. This
 library is only tested where they are.
*>
alias GetProcAddress = fn Proc(ZString name);

<*
 Ask one resolver for one name, or null if it has not got it.

 `$defined` asks whether an expression would compile, without compiling it:
 the first branch is kept for a struct pointer with a `get` method, the
 second for a function pointer, and anything else is a compile error naming
 the type. The `$if` is decided per call site, so a table load over a
 `Library` and one over a `wglGetProcAddress` are two different functions by
 the time the program runs.
*>
macro Proc get(from, ZString name)
{
	$if $defined(from.get(name)):
		return (Proc)from.get(name);
	$else
		$if $defined(from(name)):
			return (Proc)from(name);
		$else
			$error("fluxion-dyn: a resolver is a getProcAddress function pointer, or a pointer to a struct with a `get(ZString) Proc` method, not " +++ $Typeof(from).name);
		$endif
	$endif
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void stub() {}

fn Proc driver_get(ZString name)
{
	if (name.str_view() == "present") return (Proc)&stub;
	return null;
}

fn void test_a_resolver_can_be_a_plain_function() @test
{
	test::@check(get(&driver_get, "present") != null);
	test::@check(get(&driver_get, "absent") == null);

	// And as a typed pointer, which is what a C library hands back.
	GetProcAddress pointer = &driver_get;
	test::@check(get(pointer, "present") != null);
	test::@check(get(pointer, "absent") == null);
}

struct Holder
{
	uint handle;
	sz asked;
}

fn Proc Holder.get(&self, ZString name)
{
	self.asked++;
	// The handle is the point: this is the shape a Vulkan instance or device
	// resolver has, and it needs somewhere to keep it.
	if (self.handle == 7 && name.str_view() == "present") return (Proc)&stub;
	return null;
}

fn void test_a_resolver_can_carry_state() @test
{
	Holder holder = { .handle = 7 };
	test::@check(get(&holder, "present") != null);
	test::@check(get(&holder, "absent") == null);
	test::eq(holder.asked, 2);
}
