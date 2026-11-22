module app;

import core.time : MonoTime;
import flint.arena : Buffer, RequestArena, Status;
import probe_workload : exercise;

extern (C) private int flint_mail_probe_control(scope const(char)* endpoint, scope const(char)* ca,
        scope const(ubyte)* data, size_t length) nothrow @nogc;

private alias NativeString = const(char)*;

// SAFETY: The upstream reference borrows NUL-terminated strings and a scoped arena range, cleans up all
// libcurl handles before returning and invokes no D callbacks.
@trusted nothrow @nogc private bool submit(scope NativeString url, scope NativeString ca, scope const(ubyte)[] data)
{
    return flint_mail_probe_control(url, ca, data.ptr, data.length) == 0;
}

// SAFETY: The pointer addresses a fresh NUL-terminated GC copy that the collector keeps alive while
// referenced; no caller memory is retained.
@trusted pure nothrow private NativeString nativeString(scope const(char)[] text)
{
    return (text ~ '\0').ptr;
}

@safe:

private long deliver(scope string endpoint, scope string ca, ref scope RequestArena arena, Buffer attachment)
{
    const safeEndpoint = nativeString(endpoint);
    const safeCA = nativeString(ca);
    bool accepted;
    const started = MonoTime.currTime;
    const status = arena.read(attachment, (scope const(ubyte)[] bytes) {
        accepted = submit(safeEndpoint, safeCA, bytes);
    });
    const elapsed = (MonoTime.currTime - started).total!"msecs";
    return status == Status.ok && accepted ? elapsed : -1;
}

int main(string[] args)
{
    return exercise(args, &deliver);
}
