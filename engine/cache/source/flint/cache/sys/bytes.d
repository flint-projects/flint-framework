module flint.cache.sys.bytes;

import core.stdc.stdlib : free, realloc;
import flint.arena : Buffer, RequestArena, Result, Status;

@safe:

package(flint.cache) struct OwnedBytes
{
    private ubyte[] storage;
    private size_t keyLength;

    @disable this(this);

    size_t bytes() const pure nothrow @nogc
    {
        return storage.length;
    }

    bool matches(scope const(ubyte)[] key) const pure nothrow @nogc
    {
        return key.length == keyLength && storage[0 .. keyLength] == key;
    }

    Result!Buffer copyValue(ref scope RequestArena arena) const nothrow @nogc
    {
        return arena.copyIn(storage[keyLength .. $]);
    }

    // SAFETY: This is the unique owner of its native allocation. Callers serialize mutation and
    // keep its bytes internal. The two input slices are borrowed only for the copy.
    Status replace(scope const(ubyte)[] key, scope const(ubyte)[] value) @trusted nothrow @nogc
    {
        if (value.length > size_t.max - key.length)
            return Status.resourceExhausted;
        const count = key.length + value.length;
        if (count == 0)
        {
            release();
            return Status.ok;
        }
        auto next = cast(ubyte*) realloc(storage.ptr, count);
        if (next is null)
            return Status.outOfMemory;
        storage = next[0 .. count];
        storage[0 .. key.length] = key[];
        storage[key.length .. $] = value[];
        keyLength = key.length;
        return Status.ok;
    }

    // SAFETY: This owner releases its one allocation after its last use under the owning lock.
    void release() @trusted nothrow @nogc
    {
        free(storage.ptr);
        storage = null;
        keyLength = 0;
    }
}
