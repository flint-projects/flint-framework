module flint.cache.invocation_test;

import flint.arena : Error, RequestArena, Status;
import flint.cache : Cache, Cacheable, CacheEvict, CacheOptions, evictCommitted, registerCachedCall;
import flint.conc : Context;

@safe:

private struct Query
{
    uint zone;
    uint id;
}

private struct Item
{
    uint quantity;
}

private final class Inventory
{
    uint reads;

    @Cacheable("stock")
    Error lookup(scope const ref Query input, ref Item output, ref scope RequestArena, ref Context) nothrow @nogc
    {
        output.quantity = ++reads + input.id;
        return Error.init;
    }

    @CacheEvict("stock")
    void change()
    {
    }

    @CacheEvict("stock", true)
    void reset()
    {
    }
}

unittest
{
    Cache cache;
    CacheOptions options;
    options.byteCapacity = 8192;
    options.entryCapacity = 32;
    options.stripes = 1;
    assert(cache.open(options).code == Status.ok);
    scope (exit)
        assert(cache.close().code == Status.ok);
    auto component = new Inventory;
    assert(registerCachedCall!(Inventory.lookup, "v1")(component, "other", cache).error.code == Status.invalidArgument);
    auto call = registerCachedCall!(Inventory.lookup, "v1")(component, "stock", cache);
    auto updated = registerCachedCall!(Inventory.lookup, "v2")(component, "stock", cache);
    assert(call.ok && updated.ok);
    ubyte[4096] raw, decoded;
    scope RequestArena scratch = RequestArena(raw[]);
    scope RequestArena destination = RequestArena(decoded[]);
    auto request = Query(2, 7);
    Item result;
    Context context;
    enum ttl = 60_000_000_000L;
    assert(call.value.read(request, result, ttl, scratch, destination, context).code == Status.ok);
    assert(result.quantity == 8);
    assert(call.value.read(request, result, ttl, scratch, destination, context).code == Status.ok);
    assert(result.quantity == 8 && component.reads == 1);
    alias evict = evictCommitted!(Inventory.change, Inventory.lookup, "v1", Query);
    assert(evict(cache, "stock", request, Error(Status.ioError), context).code == Status.ioError);
    assert(call.value.read(request, result, ttl, scratch, destination, context).code == Status.ok);
    assert(result.quantity == 8 && component.reads == 1);
    assert(updated.value.read(request, result, ttl, scratch, destination, context).code == Status.ok);
    assert(result.quantity == 9 && component.reads == 2);
    assert(evict(cache, "stock", request, Error.init, context).code == Status.ok);
    assert(call.value.read(request, result, ttl, scratch, destination, context).code == Status.ok);
    assert(result.quantity == 10 && component.reads == 3);
    alias clear = evictCommitted!(Inventory.reset, Inventory.lookup, "v1", Query);
    assert(clear(cache, "stock", request, Error.init, context).code == Status.ok);
    assert(updated.value.read(request, result, ttl, scratch, destination, context).code == Status.ok);
    assert(result.quantity == 11 && component.reads == 4);
}
