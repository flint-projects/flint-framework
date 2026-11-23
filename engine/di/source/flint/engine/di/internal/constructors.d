/// Validate explicit constructor injection and record its exact argument types.
module flint.engine.di.internal.constructors;

import flint.engine.di.internal.registrations : Inject;
import std.meta : AliasSeq;

@safe:

/// A bare abstract type can be supplied externally.
enum bool externalOnly(T) = is(T == interface) || (is(T == class) && __traits(isAbstractClass, T));

/// There is no explicit constructor for the type.
enum noConstructor = size_t.max;

private size_t selectConstructor(T)()
{
    alias candidates = __traits(getOverloads, T, "__ctor", true);
    size_t count;
    size_t selected = noConstructor;
    size_t marked = noConstructor;
    static foreach (index, candidate; candidates)
    {
        {
            enum visibility = __traits(getVisibility, candidate);
            static if (is(typeof(candidate) == function) && !__traits(isDisabled, candidate)
                    && (visibility == "public" || visibility == "export"))
            {
                ++count;
                selected = index;
                static foreach (attribute; __traits(getAttributes, candidate))
                {
                    static if (is(attribute == Inject) || is(typeof(attribute) == Inject))
                    {
                        assert(marked == noConstructor, "DI has multiple @Inject constructors for " ~ T.stringof);
                        marked = index;
                    }
                }
            }
        }
    }
    assert(count != 0, "DI has no eligible public constructor for " ~ T.stringof);
    if (marked != noConstructor)
        return marked;
    assert(count == 1, "DI has an ambiguous constructor for " ~ T.stringof ~ ". Use one @Inject constructor.");
    return selected;
}

/// The only callable constructor for an automated bean, if it declares one.
template Constructor(T)
{
    static if (!externalOnly!T && __traits(hasMember, T, "__ctor"))
    {
        /// Position of the chosen declaration in its overload set.
        enum index = selectConstructor!T();
        /// Whether exact argument coercion is needed to select the declaration.
        enum overloaded = __traits(getOverloads, T, "__ctor", true).length > 1;
        /// Exact chosen constructor symbol.
        alias symbol = __traits(getOverloads, T, "__ctor", true)[index];
        /// Its declared parameter types.
        static if (is(typeof(symbol) Parameters == function))
            alias Args = Parameters;

        static assert(!__traits(getFunctionVariadicStyle, symbol).length || __traits(getFunctionVariadicStyle,
                symbol) == "none", "variadic DI constructor is unsupported for " ~ T.stringof);
    }
    else
    {
        /// No supplied type has an applicable declared constructor.
        enum index = noConstructor;
        /// No argument coercion is needed for an implicit constructor.
        enum overloaded = false;
        /// An implicit or externally provided bean consumes no constructor parameters.
        alias Args = AliasSeq!();
    }
}
