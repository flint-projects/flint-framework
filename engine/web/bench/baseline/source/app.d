/// Direct pinned llhttp control for the fixed request and arena fixture.
module app;

import flint.arena : RequestArena, Status;
import web_probe : Example, measure, observe;

@safe:

private struct NativeParser;

version (FlintNativeLlhttp)
{
    extern (C) private @system nothrow @nogc
    {
        NativeParser* flint_web_probe_open();
        void flint_web_probe_close(NativeParser*);
        int flint_web_probe_read(NativeParser*, scope const(char)*, size_t, scope ubyte*, size_t,
                scope size_t*, scope size_t*);
    }
}

private struct DirectParser
{
    NativeParser* state;

    // SAFETY: The control owns this opaque parser on its only running thread.
    bool open() @trusted nothrow @nogc
    {
        version (FlintNativeLlhttp)
        {
            state = flint_web_probe_open();
            return state !is null;
        }
        else
            return false;
    }

    // SAFETY: Both buffers are sized, synchronous, and retained only by the owner during this call.
    size_t read(scope string request, scope ubyte[] target, out size_t body) @trusted nothrow @nogc
    {
        version (FlintNativeLlhttp)
        {
            size_t written;
            const status = flint_web_probe_read(state, request.ptr, request.length, target.ptr,
                    target.length, &written, &body);
            return status == 0 && written <= target.length ? written : 0;
        }
        else
            return 0;
    }

    // SAFETY: The control has returned from every native parse before releasing its unique parser.
    void close() @trusted nothrow @nogc
    {
        version (FlintNativeLlhttp)
        {
            flint_web_probe_close(state);
            state = null;
        }
    }
}

private uint directRoute(scope const(ubyte)[] path) pure nothrow @nogc
{
    if (path == cast(const(ubyte)[]) "/health")
        return 1;
    if (path == cast(const(ubyte)[]) "/users/42")
        return 2;
    if (path == cast(const(ubyte)[]) "/assets/icons/a.svg")
        return 3;
    return 4;
}

/// Parse through llhttp's C API and consume the same observed corpus result.
int main()
{
    ubyte[4096] storage;
    scope arena = RequestArena(storage[]);
    DirectParser control;
    if (!control.open())
        return 1;
    scope (exit)
        control.close();

    return measure((scope const Example input) @safe nothrow @nogc {
        if (arena.reset() != Status.ok)
            return 0;
        ubyte[64] target;
        size_t body;
        const length = control.read(input.request, target[], body);
        if (length == 0)
            return 0;
        return observe(arena, directRoute(target[0 .. length]), body);
    }) ? 0 : 1;
}
