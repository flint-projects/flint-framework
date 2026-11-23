/// A typed model for terminal conformance under a real Linux pseudo-terminal.
module tui_interactive;

import core.atomic : atomicLoad, atomicStore;
import core.thread.osthread : Thread;
import core.time : dur;
import flint.arena : Status;
import flint.engine.tui : Effects, Event, EventKind, Frame, KeyCode, TimerId, run;
import std.conv : to;
import std.stdio : stdout, writeln;

@safe:

private shared bool lateFinished;

private enum Mode
{
    resize,
    autoQuit,
    late,
    saturated
}

private struct Model
{
    Mode mode;
    uint columns;
    uint rows;
    uint focus = 1;
    uint pasted;
    uint completed;
    TimerId exitTimer;
    Thread owner;

    void update(Event event, ref Effects effects)
    {
        if (owner is null)
            owner = Thread.getThis();
        assert(owner is Thread.getThis());
        switch (event.kind)
        {
        case EventKind.resize:
            resize(event, effects);
            break;
        case EventKind.command:
            assert(event.commandId != 0 && event.error.code == Status.ok && event.payload == [
                12, 30
            ]);
            ++completed;
            if (mode == Mode.autoQuit)
                effects.quit(7);
            break;
        case EventKind.key:
            if (event.key.code == KeyCode.tab)
                focus = focus == 1 ? 2 : 1;
            if (event.key.character == 'q')
                effects.quit();
            break;
        case EventKind.paste:
            ++pasted;
            break;
        case EventKind.timer:
            assert(event.timerId == exitTimer.value);
            assert(effects.cancelTimer(exitTimer).code == Status.ok);
            effects.quit(9);
            break;
        case EventKind.interrupt:
            effects.quit(130);
            break;
        default:
            break;
        }
    }

    private void resize(Event event, ref Effects effects)
    {
        const initial = columns == 0;
        columns = event.size.columns;
        rows = event.size.rows;
        if (!initial)
            return;
        const selected = mode;
        if (selected == Mode.saturated)
        {
            foreach (_; 0 .. 256)
                assert(effects.submit(() @safe => work(selected)).ok());
            assert(effects.submit(() @safe => work(selected)).error.code == Status.resourceExhausted);
        }
        else
            assert(effects.submit(() @safe => work(selected)).ok());
        if (mode == Mode.late)
        {
            const timer = effects.tick(100_000_000);
            assert(timer.ok());
            exitTimer = timer.value;
        }
    }

    void view(ref Frame frame) const
    {
        if (mode == Mode.resize)
            Thread.sleep(dur!"msecs"(30));
        assert(frame.put(0, 0, "READY " ~ columns.to!string ~ "x" ~ rows.to!string).code == Status.ok);
        assert(frame.put(0, 1, "FOCUS=" ~ focus.to!string).code == Status.ok);
        assert(frame.put(0, 2, "PASTES=" ~ pasted.to!string).code == Status.ok);
        assert(frame.put(0, 3, "COMPLETED=" ~ completed.to!string).code == Status.ok);
        assert(frame.put(0, 4, "界 e\u0301 👩‍🔬").code == Status.ok);
        if (mode == Mode.saturated)
            assert(frame.put(0, 5, "QUEUE=256").code == Status.ok);
    }
}

private Event work(Mode mode)
{
    Event result;
    if (mode == Mode.late)
    {
        Thread.sleep(dur!"msecs"(3300));
        atomicStore(lateFinished, true);
    }
    else
        Thread.sleep(dur!"msecs"(360));
    result.payload = [12, 30];
    return result;
}

int main(string[] args) @system
{
    Model model;
    if (args.length > 1)
    {
        switch (args[1])
        {
        case "late":
            model.mode = Mode.late;
            break;
        case "saturated":
            model.mode = Mode.saturated;
            break;
        default:
            model.mode = Mode.autoQuit;
            break;
        }
    }
    const status = run(model);
    writeln("RETURN=", status);
    stdout.flush();
    if (model.mode == Mode.late)
    {
        assert(model.completed == 0 && !atomicLoad(lateFinished));
        foreach (_; 0 .. 400)
        {
            if (atomicLoad(lateFinished))
            {
                writeln("WORKER COMPLETE");
                return status;
            }
            Thread.sleep(dur!"msecs"(5));
        }
        return 1;
    }
    return status;
}
