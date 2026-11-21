module flint.cache.invocation;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.cache : Cache, getOrLoad;
import flint.cache.types : Cacheable, CacheEvict;
import flint.conc : Context;
import flint.serde : EncodeOptions, decodeInto, encodeJson;
import std.traits : Parameters, Unqual, fullyQualifiedName, getUDAs;

@safe:

private enum keyCapacity = 4096;
private alias Arena = RequestArena;
private alias Ctx = Context;
private alias Operation(A, V) = Error delegate(scope const ref A, ref V, ref scope Arena, ref Ctx) @safe nothrow @nogc;

private template prefix(alias Read, string schema, Params)
{
    static assert(schema.length != 0 && schema.length <= 64, "a cache key schema version is required");
    static assert(() {
        foreach (char value; schema)
            if (value < 33 || value == 127)
                return false;
        return true;
    }(), "invalid cache key schema version");
    alias markers = getUDAs!(Read, Cacheable);
    static assert(markers.length == 1, "registered reads require exactly one Cacheable annotation");
    enum annotation = markers[0];
    static assert(annotation.cache.length != 0, "Cacheable requires a named cache");
    enum prefix = fullyQualifiedName!Read ~ "\0" ~ fullyQualifiedName!Params ~ "\0" ~ schema ~ "\0";
    static assert(prefix.length <= keyCapacity / 2, "cache key descriptor is too long");
}

private Result!size_t encodeKey(string identity, Args)(scope const ref Args args, scope ubyte[] key) nothrow @nogc
{
    ubyte[keyCapacity] temporary;
    scope RequestArena arena = RequestArena(temporary[]);
    const json = encodeJson(args, arena, EncodeOptions(true));
    if (!json.ok)
        return Result!size_t(0, json.error);
    const length = identity.length + json.value.length;
    if (length > key.length)
        return Result!size_t(0, Error(Status.resourceExhausted, "serialized cache key exceeds limit"));
    key[0 .. identity.length] = cast(const(ubyte)[]) identity;
    const copied = arena.read(json.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        key[identity.length .. length] = bytes;
    });
    return Result!size_t(length, Error(copied));
}

/// Explicit adapter for one startup-bound application method.
struct CachedCall(alias Read, string schema, Args, Value)
{
    private alias Invoke = Operation!(Args, Value);
    private enum identity = prefix!(Read, schema, Args);
    private Cache cache;
    private Invoke invoke;

    /// Use a scratch arena for serialized bytes and a separate arena for the decoded result.
    Error read(scope const ref Args args, ref Value output, long ttl, ref scope RequestArena scratch,
            ref scope RequestArena result, ref Context context) nothrow @nogc
    {
        if (invoke is null)
            return Error(Status.unavailable, "cached method is not registered");
        if (&scratch is &result)
            return Error(Status.invalidArgument, "cached method requires separate scratch and result arenas");
        ubyte[keyCapacity] key;
        const encoded = encodeKey!identity(args, key[]);
        if (!encoded.ok)
            return encoded.error;
        const cached = getOrLoad(cache, key[0 .. encoded.value], ttl, scratch, context,
                (ref scope RequestArena arena, ref Context loadContext) @safe nothrow @nogc {
            Value loaded;
            const loadedError = invoke(args, loaded, arena, loadContext);
            return loadedError.code == Status.ok ? encodeJson(loaded, arena,
                EncodeOptions(true)) : Result!Buffer(Buffer.init, loadedError);
        });
        if (!cached.ok)
            return cached.error;
        Error decoded;
        const checked = scratch.read(cached.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            decoded = decodeInto(bytes, output, result);
        });
        return checked == Status.ok ? decoded : Error(checked, "cached response expired");
    }
}

/// Register an annotated method on a startup-owned service instance, such as a DI bean.
auto registerCachedCall(alias Read, string schema, Component)(Component instance, string name, Cache cache)
        if (is(Component == class) || is(Component == interface))
{
    alias Owner = __traits(parent, Read);
    static assert(is(Component : Owner), "cached method must belong to the registered component");
    alias Args = Unqual!(Parameters!Read[0]);
    alias Value = Unqual!(Parameters!Read[1]);
    alias Call = CachedCall!(Read, schema, Args, Value);
    alias markers = getUDAs!(Read, Cacheable);
    static assert(markers.length == 1, "registered reads require exactly one Cacheable annotation");
    static assert(is(typeof(&__traits(getMember, instance, __traits(identifier,
            Read))) : Call.Invoke), "cached method must match the typed cache invocation signature");
    if (instance is null || name != markers[0].cache)
        return Result!Call(Call.init, Error(Status.invalidArgument, "invalid cached method registration"));
    return Result!Call(Call(cache, &__traits(getMember, instance, __traits(identifier, Read))));
}

/// Invalidate the registered read after the application reports transaction commit success.
Error evictCommitted(alias Mutation, alias Read, string schema, Args)(ref Cache cache, string name,
        scope const ref Args args, Error commit, ref Context context) nothrow @nogc
{
    alias mutation = getUDAs!(Mutation, CacheEvict);
    alias read = getUDAs!(Read, Cacheable);
    static assert(mutation.length == 1 && read.length == 1 && mutation[0].cache == read[0].cache,
            "CacheEvict must target the same named cache as Cacheable");
    static assert(is(Args == Unqual!(Parameters!Read[0])), "eviction parameters must match the registered read");
    enum identity = prefix!(Read, schema, Args);
    if (commit.code != Status.ok)
        return commit;
    if (name != mutation[0].cache)
        return Error(Status.invalidArgument, "invalid cache eviction registration");
    static if (mutation[0].allEntries)
        return cache.clear(context);
    else
    {
        ubyte[keyCapacity] key;
        const encoded = encodeKey!identity(args, key[]);
        return encoded.ok ? cache.evict(key[0 .. encoded.value], context) : encoded.error;
    }
}
