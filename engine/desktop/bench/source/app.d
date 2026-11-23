module app;

import core.memory : GC;
import core.time : MonoTime;
import desktop_probe : chooseDriver, count, height, report, require, title, verifyNativeFrame, width;
import flint.arena : Error, RequestArena, Status;
import flint.conc : Context;
import flint.engine.desktop : DesktopEvent, EventKind, Window, WindowOptions;

@safe:

private immutable ubyte[] frame = [
    // Header and clear.
    0x46, 0x44, 0x4c, 1, 6, 0, 0, 0, 1, 0, 4, 0, 16, 24, 36, 255,
    // Set one clipping rectangle.
    5, 0, 16, 0, 4, 0, 0, 0, 5, 0, 0, 0, 244, 1, 0, 0, 49, 1, 0, 0,
    // Fill a rectangle, draw four glyphs and draw the tinted tile.
    2, 0, 20, 0, 8, 0, 0, 0, 10, 0, 0, 0, 40, 0, 0, 0, 20, 0, 0, 0, 56, 140, 92, 255, 3, 0, 20, 0,
    12, 0, 0, 0, 24, 0, 0, 0, 1, 0, 4, 0, 200, 208, 216, 255, 'F', 'L', 'N', 'T', 4, 0, 24, 0,
    70, 0, 0, 0, 10, 0, 0, 0, 30, 0, 0, 0, 21, 0, 0, 0, 1, 0, 0, 0, 80, 112, 184, 255,
    // Restore the previous clip.
    6, 0, 0, 0,
];

private Error queueFrame(ref Window window) nothrow @nogc
{
    const queued = window.submit(frame);
    if (queued.code != Status.ok)
        return queued;
    return window.postMessage([]);
}

void main(string[] arguments)
{
    const frames = count(arguments);
    chooseDriver();
    const start = MonoTime.currTime;
    Window window;
    require(window.open(WindowOptions(title, width, height)).code == Status.ok);

    size_t seen;
    ulong checksum;
    auto rendered = MonoTime.init;
    auto callback = (ref DesktopEvent event, ref scope RequestArena arena) @safe nothrow @nogc {
        if (event.kind != EventKind.message)
            return Error.init;
        require(arena.stats().used == 0);
        if (++seen < frames)
            return queueFrame(window);
        rendered = MonoTime.currTime;
        checksum = verifyNativeFrame();
        return window.close();
    };
    auto context = Context.init;
    const ready = MonoTime.currTime;
    const allocated = GC.stats().allocatedInCurrentThread;
    require(queueFrame(window).code == Status.ok);
    require(window.run(callback, context).code == Status.ok);
    require(seen == frames);
    report(seen, start, ready, rendered, allocated, checksum);
}
