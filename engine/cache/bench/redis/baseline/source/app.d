/// Call the pinned hiredis baseline directly while sharing the feature's workload.
module app;

import redis_workload : Observation, fixture, run;
import std.conv : to;
import std.exception : enforce;
import std.string : toStringz;

@safe:

private struct Reference;

extern (C) private @system nothrow @nogc
{
    Reference* redis_probe_open(ushort port, const(char)* ca);
    int redis_probe_cycle(Reference* owner, const(ubyte)* key, size_t keySize, const(ubyte)* value,
            size_t valueSize, ulong* checksum);
    void redis_probe_close(Reference*);
}

// SAFETY: This benchmark opens one native connection on its caller thread and closes it after the
// scoped workload finishes. The CA string is copied at startup and C cannot unwind D exceptions.
/// Run a provider-equivalent TLS workload.
@trusted int main()
{
    const port = fixture("REAL_TLS_PORT").to!ushort;
    auto owner = redis_probe_open(port, fixture("CA").toStringz);
    enforce(owner !is null, "reference hiredis failed to connect");
    scope (exit)
        redis_probe_close(owner);
    return run((scope const(ubyte)[] key, scope const(ubyte)[] value) {
        return cycle(owner, key, value);
    });
}

// SAFETY: The owner and both borrowed ranges stay live throughout the synchronous reference
// cycle. Hiredis copies input and frees reply trees before this function returns.
private Observation cycle(Reference* owner, scope const(ubyte)[] key, scope const(ubyte)[] value) @trusted nothrow @nogc
{
    ulong sum;
    const worked = redis_probe_cycle(owner, key.ptr, key.length, value.ptr, value.length, &sum);
    return Observation(worked != 0, sum);
}
