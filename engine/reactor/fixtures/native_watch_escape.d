module native_watch_escape;

import flint.engine.reactor : NativeInterest, Reactor;

@safe:

/// The registry retains delegates, so a borrowed slice must fail to compile here.
void reject(ref Reactor reactor, int fd, scope ubyte[] borrowed)
{
    reactor.watchNative(fd, NativeInterest.read, (int, NativeInterest) @safe nothrow @nogc {
        borrowed[0] = 1;
    });
}
