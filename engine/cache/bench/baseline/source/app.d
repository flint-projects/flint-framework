module app;

import cache_probe : inspect, measure, payload;
import flint.arena : RequestArena;

@safe:

private uint operation(uint worker, uint action, size_t bytes) nothrow @nogc
{
    ubyte[4096] scratch;
    scope RequestArena arena = RequestArena(scratch[]);
    const ubyte[2] key = [0, cast(ubyte) worker];
    final switch (action)
    {
    case 0:
        return inspect(arena.copyIn(payload[0 .. bytes]), arena);
    case 1:
        return 2;
    case 2:
        return key[0] + 3;
    case 3:
        return key[0] + 4;
    }
}

private ulong[2] noLockMeasurements() pure nothrow @nogc
{
    return [0UL, 0UL];
}

@system int main()
{
    return measure((uint worker, uint action, size_t bytes) @safe nothrow @nogc => operation(worker,
            action, bytes), () @safe nothrow @nogc => noLockMeasurements());
}
