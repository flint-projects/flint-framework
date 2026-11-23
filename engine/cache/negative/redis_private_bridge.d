module application.redis_private_bridge;

import flint.engine.cache.ffi.hiredis : Bridge;

private Bridge attempt() @safe
{
    return Bridge.init;
}
