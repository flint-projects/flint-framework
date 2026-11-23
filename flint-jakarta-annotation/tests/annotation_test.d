/// Behaviour of the Jakarta Annotations UDAs: Java's defaults, the value-first
/// shorthand of rulebook R2, and repeated @Resource.
module annotation_test;

import flint.jakarta.annotation : Generated, Nonnull, Nullable, PostConstruct, PreDestroy,
    Priority, Resource, Resources;

@safe:

private final class Component
{
    @Resource
    string plain;
    @Resource(name: "jdbc/petclinic", shareable: false)
    string named;
    @Resource(lookup: "java:global/a")
    @Resource(lookup: "java:global/b")
    string twice;
    @Nullable
    string optional;
    @Nonnull
    string required = "x";

    @PostConstruct
    void start()
    {
    }

    @PreDestroy
    void close()
    {
    }
}

@Priority(100)
@Generated(["flint aot"], "2026-11-23T00:00:00Z")
private struct Interceptor
{
}

// A bare `@Resource` attaches the type and `@Resource(...)` a value; both read as a Resource value,
// the type as Resource.init, which is how Flint AOT reads every annotation UDA.
private template resources(alias symbol)
{
    static Resource[] collect()
    {
        Resource[] found;
        static foreach (attribute; __traits(getAttributes, symbol))
        {
            static if (is(attribute == Resource))
                found ~= Resource.init;
            else static if (is(typeof(attribute) == Resource))
                found ~= attribute;
        }
        return found;
    }

    enum resources = collect();
}

@("Resource keeps Java's element defaults")
unittest
{
    enum found = resources!(Component.plain);
    static assert(found.length == 1);
    static assert(found[0].name == "" && found[0].lookup == "" && found[0].mappedName == "" && found[0].description
            == "");
    static assert(found[0].shareable);
    static assert(found[0].authenticationType == Resource.AuthenticationType.CONTAINER);
}

@("named arguments set only the elements given")
unittest
{
    enum found = resources!(Component.named);
    static assert(found[0].name == "jdbc/petclinic" && !found[0].shareable);
    static assert(found[0].authenticationType == Resource.AuthenticationType.CONTAINER);
}

@("Resource repeats on one declaration in source order, as Resources collects it")
unittest
{
    enum found = resources!(Component.twice);
    static assert(found.length == 2 && found[0].lookup == "java:global/a" && found[1].lookup == "java:global/b");
    const holder = Resources(found.dup);
    assert(holder.value.length == 2 && holder.value[1].lookup == "java:global/b");
}

@("lifecycle and nullness markers attach to their declarations only")
unittest
{
    import std.traits : hasUDA;

    static assert(hasUDA!(Component.start, PostConstruct) && !hasUDA!(Component.start, PreDestroy));
    static assert(hasUDA!(Component.close, PreDestroy) && !hasUDA!(Component.close, PostConstruct));
    static assert(hasUDA!(Component.optional, Nullable) && !hasUDA!(Component.optional, Nonnull));
    static assert(hasUDA!(Component.required, Nonnull));
}

@("Priority and Generated take value first")
unittest
{
    import std.traits : getUDAs;

    static assert(getUDAs!(Interceptor, Priority)[0].value == 100);
    enum generated = getUDAs!(Interceptor, Generated)[0];
    static assert(generated.value == ["flint aot"] && generated.comments == "");
    static assert(Resource.AuthenticationType.APPLICATION != Resource.AuthenticationType.CONTAINER);
}
