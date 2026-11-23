module flint.engine.cache.redis_reply_escape;

import flint.arena : RequestArena;
import flint.engine.cache : Cache;
import flint.conc : Context;

private const(ubyte)[] leaked;

private void attempt(ref Cache cache, ref scope RequestArena arena, ref Context context) @safe
{
    const value = cache.get(null, arena, context);
    auto visitor = delegate void(scope const(ubyte)[] bytes) @safe nothrow @nogc { leaked = bytes; };
    if (value.ok)
        arena.read(value.value, visitor);
}
