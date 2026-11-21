module app;

import flint.arena : Buffer, RequestArena, Status;
import probe_workload : exercise;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.string : toStringz;

extern (C) private int flint_mail_probe_control(scope const(char)* endpoint, scope const(char)* ca,
        scope const(ubyte)* data, size_t length) nothrow @nogc;

private alias NativeString = const(char)*;

// SAFETY: The upstream reference borrows NUL-terminated strings and a scoped arena range, cleans up all
// libcurl handles before returning and invokes no D callbacks.
@trusted nothrow @nogc private bool submit(scope NativeString url, scope NativeString ca, scope const(ubyte)[] data)
{
    return flint_mail_probe_control(url, ca, data.ptr, data.length) == 0;
}

@safe:

private long deliver(scope string endpoint, scope string ca, ref scope RequestArena arena, Buffer attachment)
{
    const safeEndpoint = endpoint.idup.toStringz;
    const safeCA = ca.idup.toStringz;
    bool accepted;
    const watch = StopWatch(AutoStart.yes);
    const status = arena.read(attachment, (scope const(ubyte)[] bytes) {
        accepted = submit(safeEndpoint, safeCA, bytes);
    });
    const elapsed = watch.peek.total!"msecs";
    return status == Status.ok && accepted ? elapsed : -1;
}

int main(string[] args)
{
    return exercise(args, &deliver);
}
