/// Inspect and invoke only the lifecycle methods on explicitly registered types.
module flint.di.internal.lifecycle;

import flint.arena : Error;
import flint.di.internal.registrations : PostConstruct, PreDestroy, annotated, exposed;
import std.traits : Parameters, ReturnType;

@safe:

/// Metadata for one declared hook, including the exact overload.
struct Hook
{
    /// Empty for types without that hook.
    string name;
    /// Position in the declared overload set.
    size_t index;
    /// Whether the startup hook returns an operational error.
    bool reportsFailure;
}

/// A type's at most one startup and one cleanup hook.
struct Lifecycle
{
    /// Startup hook.
    Hook startup;
    /// Cleanup hook.
    Hook cleanup;
}

private bool isNothrow(alias method)() nothrow @nogc
{
    static foreach (attribute; __traits(getFunctionAttributes, method))
    {
        static if (attribute == "nothrow")
            return true;
    }
    return false;
}

private bool isHook(alias member)() nothrow @nogc
{
    return annotated!(PostConstruct, member)() || annotated!(PreDestroy, member)();
}

/// Validate a registered type's annotated lifecycle overloads.
Lifecycle inspect(T)()
{
    Lifecycle result;
    static foreach (name; __traits(allMembers, T))
    {
        {
            static if ((!__traits(compiles, __traits(getOverloads, T, name, true))
                    || __traits(getOverloads, T, name, true).length == 0) && __traits(compiles,
                    __traits(getAttributes, __traits(getMember, T, name))))
            {
                static foreach (attribute; __traits(getAttributes, __traits(getMember, T, name)))
                {
                    static if (is(attribute == PostConstruct) || is(typeof(attribute) == PostConstruct)
                            || is(attribute == PreDestroy) || is(typeof(attribute) == PreDestroy))
                    {
                        static assert(is(typeof(__traits(getMember, T, name)) == function)
                                && exposed!(__traits(getMember, T, name))(),
                                "DI lifecycle hook must be a public instance method: " ~ T.stringof ~ "." ~ name);
                    }
                }
            }
            static if (__traits(compiles, __traits(getOverloads, T, name, true)))
            {
                static foreach (index, member; __traits(getOverloads, T, name, true))
                {
                    {
                        static if (__traits(compiles, __traits(getAttributes, member))
                                && __traits(getAttributes, member).length != 0)
                        {
                            static if (isHook!member())
                                addHook!(T, member)(result, name, index);
                        }
                    }
                }
            }
        }
    }
    return result;
}

private void addHook(T, alias member)(ref Lifecycle result, string name, size_t index)
{
    enum startup = annotated!(PostConstruct, member)();
    enum cleanup = annotated!(PreDestroy, member)();
    static assert(is(typeof(member) == function) && exposed!member() && !__traits(isStaticFunction,
            member) && !__traits(isDisabled, member),
            "DI lifecycle hook must be a public instance method on " ~ T.stringof);
    static assert(Parameters!member.length == 0 && __traits(getFunctionVariadicStyle,
            member) == "none", "DI lifecycle hook must take no arguments on " ~ T.stringof);
    static assert(!(startup && cleanup), "DI lifecycle method cannot serve as both startup and cleanup on " ~ T
            .stringof);

    alias Output = ReturnType!member;
    static if (startup)
    {
        static assert(is(Output == Error) || is(Output == void), "DI PostConstruct must return Error or void");
        assert(result.startup.name.length == 0, "duplicate DI PostConstruct hook on " ~ T.stringof);
        result.startup = Hook(name, index, is(Output == Error));
    }
    else
    {
        static assert(is(Output == void) && isNothrow!member(), "DI PreDestroy must return void and be nothrow");
        assert(result.cleanup.name.length == 0, "duplicate DI PreDestroy hook on " ~ T.stringof);
        result.cleanup = Hook(name, index, false);
    }
}
