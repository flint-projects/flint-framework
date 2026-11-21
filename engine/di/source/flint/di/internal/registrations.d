/// Explicit bean metadata and registration normalization.
module flint.di.internal.registrations;

import std.meta : staticMap;

@safe:

/// Marks an explicitly registered service.
struct Service
{
}

/// Marks an explicitly registered repository.
struct Repository
{
}

/// Marks an explicitly registered component.
struct Component
{
}

/// Documents singleton lifetime within the application context.
struct Singleton
{
}

/// Selects a public constructor among multiple eligible overloads.
struct Inject
{
}

/// Descriptive metadata for an explicitly registered bean.
struct Named
{
    /// Application-chosen name.
    string value;
}

/// Run an instance's startup hook after constructor injection.
struct PostConstruct
{
}

/// Run a nonthrowing instance cleanup hook before releasing ownership.
struct PreDestroy
{
}

/// Bind one context key to an explicitly named implementation.
struct Bind(Contract, Implementation)
{
    /// Type used by callers and constructor dependencies.
    alias ContractType = Contract;
    /// Type constructed when an external instance has not been supplied.
    alias ImplementationType = Implementation;
}

/// Require a startup-supplied instance without inspecting its constructors or lifecycle hooks.
struct Provided(T)
{
}

/// Identify externally supplied concrete registrations.
enum bool providedOnly(T) = is(T == Provided!Value, Value);

/// Group registrations without discovering any additional types.
struct BeanRegistrar(Bindings...)
{
}

private template expand(T)
{
    static if (is(T == BeanRegistrar!Entries, Entries...))
        alias expand = staticMap!(.expand, Entries);
    else
        alias expand = T;
}

/// Flatten the explicit lists left-to-right.
template Registrations(Entries...)
{
    private bool hasRegistrar()
    {
        static foreach (Entry; Entries)
        {
            {
                static if (is(Entry == BeanRegistrar!Nested, Nested...))
                    return true;
            }
        }
        return false;
    }

    static if (hasRegistrar())
        alias Registrations = staticMap!(expand, Entries);
    else
        alias Registrations = Entries;
}

/// Bare registrations use their types directly as both lookup keys and beans.
bool hasBinding(Entries...)() nothrow @nogc
{
    static foreach (Entry; Entries)
    {
        {
            static if (is(Entry == Bind!(Contract, Implementation), Contract, Implementation) || providedOnly!Entry)
                return true;
        }
    }
    return false;
}

/// Look up the registered key of a bare type or binding.
template Key(T)
{
    static if (is(T == Bind!(Contract, Implementation), Contract, Implementation))
        alias Key = Contract;
    else static if (is(T == Provided!Value, Value))
        alias Key = Value;
    else
        alias Key = T;
}

/// Look up the constructed implementation of an explicit binding.
template Concrete(T)
{
    static if (is(T == Bind!(Contract, Implementation), Contract, Implementation))
        alias Concrete = Implementation;
    else static if (is(T == Provided!Value, Value))
        alias Concrete = Value;
    else
        alias Concrete = T;
}

/// Sentinel for a type without a registration.
enum uint missing = uint.max;

/// Compute a typed, constant slot index.
uint keyIndex(T, Keys...)() nothrow @nogc
{
    static foreach (index, Candidate; Keys)
    {
        static if (is(T == Candidate))
            return cast(uint) index;
    }
    return missing;
}

/// Check whether a symbol has the supplied marker type, in either UDA form.
bool annotated(Marker, alias symbol)() nothrow @nogc
{
    static foreach (attribute; __traits(getAttributes, symbol))
    {
        static if (is(attribute == Marker) || is(typeof(attribute) == Marker))
            return true;
    }
    return false;
}

/// Publicly accessible callable declarations qualify for generated calls.
bool exposed(alias symbol)() nothrow @nogc
{
    enum access = __traits(getVisibility, symbol);
    return access == "public" || access == "export";
}
