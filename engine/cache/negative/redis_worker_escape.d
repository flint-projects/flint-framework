module flint.cache.redis_worker_escape;

import flint.cache.ffi.hiredis : startDriver;

private void attempt(scope const(ubyte)[] borrowed) @safe
{
    startDriver(delegate void() @safe nothrow{
        if (borrowed.length)
            assert(borrowed[0] == 4);
    });
}
