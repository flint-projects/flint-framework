module flint.tui.contract_tests;

import core.atomic : atomicLoad, atomicStore;
import core.thread.osthread : Thread;
import core.time : dur;
import flint.arena : Error, Status;
import flint.conc : Deadline;
import flint.style : Color, Style;
import flint.term : ColorProfile;
import flint.tui : CommandId, Effects, Event, EventKind, Frame, Size, run;
import flint.tui.commands : Commands;
import flint.tui.effects : Control, now;
import flint.tui.grid : Grid;
import flint.tui.internal : Loop;
import std.string : indexOf;

@safe:

private string view(Grid grid, scope void delegate(ref Frame) @safe paint)
{
    auto frame = Frame(grid, grid.begin());
    paint(frame);
    grid.end();
    string output;
    const drawn = grid.diff((scope const(char)[] bytes) @safe {
        output = bytes.idup;
        return Error.init;
    });
    assert(drawn.code == Status.ok);
    return output;
}

@("The second equal view emits zero bytes, and adjacent changed cells form one span")
unittest
{
    auto grid = new Grid(ColorProfile.none);
    assert(grid.resize(Size(8, 2)).code == Status.ok);
    void first(ref Frame target) @safe
    {
        assert(target.put(1, 0, "AB").code == Status.ok);
    }

    assert(view(grid, &first) == "\x1b[0m\x1b[2J\x1b[1;1H AB     \x1b[2;1H        ");
    assert(view(grid, &first).length == 0);
    const changed = view(grid, (ref Frame target) @safe {
        assert(target.put(1, 0, "CD").code == Status.ok);
    });
    assert(changed == "\x1b[1;2HCD" && changed.length < 64);
}

@("Wide and combining graphemes retain intact bytes and clear obsolete continuation cells")
unittest
{
    auto grid = new Grid(ColorProfile.none);
    assert(grid.resize(Size(8, 2)).code == Status.ok);
    enum combining = "e\u0301";
    enum emoji = "👩‍🔬";
    const first = view(grid, (ref Frame target) @safe {
        assert(target.put(1, 0, "界").code == Status.ok);
        assert(target.put(4, 0, combining ~ emoji).code == Status.ok);
    });
    assert(first == "\x1b[0m\x1b[2J\x1b[1;1H 界 " ~ combining ~ emoji ~ " \x1b[2;1H        ");
    const changed = view(grid, (ref Frame target) @safe {
        assert(target.put(1, 0, "x").code == Status.ok);
        assert(target.put(4, 0, combining ~ emoji).code == Status.ok);
    });
    assert(changed == "\x1b[1;2Hx ");
    const overlap = view(grid, (ref Frame target) @safe {
        assert(target.put(1, 0, "界").code == Status.ok);
        assert(target.put(2, 0, "Y").code == Status.ok);
        assert(target.put(4, 0, combining ~ emoji).code == Status.ok);
        assert(target.put(7, 0, "界Z\no").code == Status.ok);
    });
    assert(overlap == "\x1b[1;2H Y\x1b[2;8Ho");
}

@("Resize invalidates both surfaces, bounds are checked, and stale handles never touch storage")
unittest
{
    auto grid = new Grid(ColorProfile.none);
    assert(grid.resize(Size(uint.max, 2)).code == Status.invalidArgument);
    assert(grid.resize(Size(0, 1)).code == Status.invalidArgument);
    assert(grid.resize(Size(8, 2)).code == Status.ok);
    Frame retained;
    auto first = view(grid, (ref Frame frame) @safe {
        retained = frame;
        frame.columns = uint.max;
        assert(frame.put(8, 0, "out of range").code == Status.invalidArgument);
        assert(frame.put(0, 0, "x").code == Status.ok);
    });
    assert(first.indexOf("\x1b[2J") >= 0);
    assert(retained.put(0, 0, "late").code == Status.invalidArgument);
    assert(grid.resize(Size(9, 3)).code == Status.ok);
    const resized = view(grid, (ref Frame frame) @safe {
        assert(frame.columns == 9 && frame.rows == 3);
        assert(retained.clear().code == Status.invalidArgument);
        assert(frame.put(0, 0, "x").code == Status.ok);
    });
    assert(resized.indexOf("\x1b[2J") >= 0);
    assert(retained.clear().code == Status.invalidArgument);
    assert(view(grid, (ref Frame frame) @safe { frame.put(0, 0, "x"); }).length == 0);
    grid.close();
    assert(retained.clear().code == Status.invalidArgument);
}

@("Terminal text sanitizes controls and uses capability-aware styles")
unittest
{
    auto grid = new Grid(ColorProfile.trueColor);
    assert(grid.resize(Size(12, 2)).code == Status.ok);
    const painted = view(grid, (ref Frame frame) @safe {
        Style style;
        style.bold = true;
        style.foreground = Color(250, 9, 2);
        assert(frame.put(0, 0, "x\x1b[2J\u0301", style).code == Status.ok);
        assert(frame.put(0, 1, "\u0301").code == Status.ok);
    });
    assert(painted.indexOf("\x1b[0;1;38;2;250;9;2m") >= 0);
    assert(painted.indexOf("x\uFFFD[2J\u0301") >= 0);
    assert(painted.indexOf("\u25CC\u0301") >= 0);
    assert(painted[10 .. $].indexOf("\x1b[2J") < 0);
}

private final class Latch
{
    shared bool ready;

    Event block()
    {
        while (!atomicLoad(ready))
            Thread.sleep(dur!"msecs"(1));
        return Event.init;
    }

    void release()
    {
        atomicStore(ready, true);
    }
}

private Event joined(Commands commands)
{
    const deadline = Deadline.afterMillis(3000).monotonicNanoseconds;
    Event event;
    while (!commands.poll(event))
    {
        assert(now() < deadline, "TUI command did not publish before its deadline");
        Thread.sleep(dur!"msecs"(1));
    }
    return event;
}

private void stopped(Commands commands)
{
    const deadline = Deadline.afterMillis(3000).monotonicNanoseconds;
    commands.stop();
    while (!commands.stopped())
    {
        assert(now() < deadline, "TUI command worker did not finish");
        Thread.sleep(dur!"msecs"(1));
    }
}

@("A 256-command registry refuses overflow and retires both queued and running identities")
unittest
{
    auto commands = new Commands(256);
    auto latch = new Latch;
    scope (exit)
    {
        latch.release();
        stopped(commands);
    }
    CommandId[256] ids;
    foreach (ref id; ids)
    {
        const submitted = commands.submit(&latch.block);
        assert(submitted.ok(), submitted.error.message);
        id = submitted.value;
    }
    assert(commands.submit(&latch.block).error.code == Status.resourceExhausted);
    assert(commands.cancel(ids[0]).code == Status.ok);
    assert(commands.cancel(ids[0]).code == Status.notFound);
    assert(commands.cancel(ids[$ - 1]).code == Status.ok);
    const replacement = commands.submit(&latch.block);
    assert(replacement.ok() && replacement.value != ids[$ - 1]);
    assert(commands.cancel(ids[$ - 1]).code == Status.notFound);
    latch.release();

    foreach (_; 0 .. 255)
    {
        const event = joined(commands);
        assert(event.kind == EventKind.command && event.commandId != 0);
        assert(event.commandId != ids[0].value && event.commandId != ids[$ - 1].value);
        assert(commands.cancel(CommandId(event.commandId)).code == Status.notFound);
    }
    const deadline = Deadline.afterMillis(3000).monotonicNanoseconds;
    while (commands.active())
    {
        assert(now() < deadline, "cancelled worker did not retire its lease");
        Thread.sleep(dur!"msecs"(1));
    }
    Event unexpected;
    assert(!commands.poll(unexpected));
}

@("Owned payloads are copied, limits checked, and thrown command diagnostics stay bounded")
unittest
{
    auto commands = new Commands(1);
    scope (exit)
        stopped(commands);
    auto payload = new ubyte[65_536];
    payload[0] = 11;
    const submitted = commands.submit(() @safe { Event result; result.payload = payload; return result; });
    assert(submitted.ok());
    const worked = joined(commands);
    payload[0] = 0;
    assert(worked.payload.length == 65_536 && worked.payload[0] == 11);
    assert(worked.commandId == submitted.value.value);

    assert(commands.submit(() @safe { Event result; result.payload = new ubyte[65_537]; return result; }).ok());
    const oversized = joined(commands);
    assert(oversized.payload is null && oversized.error.code == Status.resourceExhausted);

    Event privateFailure() @safe
    {
        throw new Exception("raw private failure text");
    }

    assert(commands.submit(&privateFailure).ok());
    const failed = joined(commands);
    assert(failed.error.code == Status.ioError && failed.error.message == "TUI command failed");
}

@("Timer IDs coalesce each frame and stale effects cannot restart intake")
unittest
{
    auto control = new Control(0);
    scope (exit)
        control.shutdown();
    auto effects = control.begin();
    assert(effects.tick(0).error.code == Status.invalidArgument);
    const timer = effects.tick(10);
    assert(timer.ok());
    const instant = now() + 10_000;
    Event event;
    assert(control.poll(instant, 1, event));
    assert(event.kind == EventKind.timer && event.timerId == timer.value.value);
    assert(!control.poll(instant + 1_000, 1, event));
    assert(control.poll(instant + 1_000, 2, event));
    assert(effects.cancelTimer(timer.value).code == Status.ok);
    assert(effects.cancelTimer(timer.value).code == Status.notFound);
    assert(!control.poll(instant + 2_000, 3, event));
    control.end();
    assert(effects.tick(1).error.code == Status.invalidArgument);
    auto next = control.begin();
    const replacement = next.tick(1);
    assert(replacement.ok() && replacement.value != timer.value);
    assert(next.cancelTimer(timer.value).code == Status.notFound);
    next.quit(7);
    assert(control.exitCode() == 7);
    assert(next.tick(1).error.code == Status.invalidArgument);
}

@("A resize burst that returns to the displayed size still repaints the reflowed terminal once")
unittest
{
    auto grid = new Grid(ColorProfile.none);
    auto control = new Control(0);
    scope (exit)
        control.shutdown();
    auto loop = Loop(grid, control, 1, 16);
    Size[] resized;
    string output;
    void frame(Size[] burst...)
    {
        foreach (size; burst)
            loop.queueResize(size);
        output = null;
        const status = loop.refresh(now(), (scope const(char)[] bytes) @safe {
            output ~= bytes;
            return Error.init;
        }, (Event event, ref Effects effects) @safe {
            if (event.kind == EventKind.resize)
                resized ~= event.size;
        }, (ref Frame target) @safe { assert(target.put(0, 0, "AB").code == Status.ok); });
        assert(status.code == Status.ok, status.message);
    }

    frame(Size(8, 2));
    assert(output.indexOf("\x1b[2J") >= 0);
    frame(Size(8, 2));
    assert(output.length == 0, "a duplicate same-size notification needs no repaint");
    frame(Size(5, 2), Size(8, 2));
    assert(output.indexOf("\x1b[2J") >= 0 && output.indexOf("AB") >= 0,
            "a coalesced shrink and restore must invalidate the reflowed screen");
    frame();
    assert(output.length == 0);
    assert(resized == [Size(8, 2), Size(8, 2), Size(8, 2)]);
}

@("Printable ASCII clips at the right edge and clears the wide graphemes it overwrites")
unittest
{
    auto grid = new Grid(ColorProfile.none);
    assert(grid.resize(Size(6, 1)).code == Status.ok);
    assert(view(grid, (ref Frame frame) @safe {
            assert(frame.put(3, 0, "abcdef").code == Status.ok);
            assert(frame.put(0, 0, "").code == Status.ok);
        }) == "\x1b[0m\x1b[2J\x1b[1;1H   abc");
    const wide = view(grid, (ref Frame frame) @safe {
        assert(frame.put(0, 0, "界界界").code == Status.ok);
        assert(frame.put(1, 0, "x").code == Status.ok);
        assert(frame.put(4, 0, "yz").code == Status.ok);
    });
    assert(wide == "\x1b[1;2Hx界yz", wide);
    assert(view(grid, (ref Frame frame) @safe {
            assert(frame.put(0, 0, "界界界").code == Status.ok);
            assert(frame.put(1, 0, "x").code == Status.ok);
            assert(frame.put(4, 0, "yz").code == Status.ok);
        }).length == 0);
}

private struct SpecCounter
{
    uint count;

    void update(Event event, ref Effects effects) @safe
    {
        if (event.kind == EventKind.interrupt)
            effects.quit();
    }

    void view(ref Frame frame) const @safe
    {
        frame.put(0, 0, "Counter");
    }
}

// The specification's usage fixture must keep compiling against the public runtime entry.
static assert(__traits(compiles, () @safe { SpecCounter model; return run!SpecCounter(model); }));
