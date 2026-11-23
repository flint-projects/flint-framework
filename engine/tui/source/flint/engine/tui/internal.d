/// Monomorphic terminal scheduling and serialized application callbacks.
module flint.engine.tui.internal;

import core.thread.osthread : Thread;
import core.time : dur;
import flint.arena : Error, Status;
import flint.term : Event, EventKind, Session, Size;
import flint.engine.tui.commands : maximumCommands;
import flint.engine.tui.effects : Control, Effects, advance, now;
import flint.engine.tui.grid : Frame, Grid, Sink;
import flint.engine.tui.types : RuntimeOptions;

@safe:
package(flint.engine.tui):

alias Update = void delegate(Event, ref Effects) @safe;
alias View = void delegate(ref Frame) @safe;

int runTerminal(scope Update update, scope View view, RuntimeOptions options)
{
    if (options.maxFramesPerSecond == 0 || options.maxEventsPerFrame == 0 || options.maxPendingCommands
            > maximumCommands)
        return 1;
    auto opened = Session.open();
    if (!opened.ok())
        return 1;
    scope (exit)
        opened.value.close();
    return runSession(opened.value, update, view, options, true);
}

int runSession(ref Session session, scope Update update, scope View view, RuntimeOptions options,
        bool closeOwned = false)
{
    if (options.maxFramesPerSecond == 0 || options.maxEventsPerFrame == 0 || options.maxPendingCommands
            > maximumCommands)
        return 1;
    try
        return serve(session, update, view, options, closeOwned);
    catch (Exception)
        return 1;
}

private int serve(ref Session session, scope Update update, scope View view, RuntimeOptions options, bool closeOwned)
{
    const dimensions = session.size();
    if (!dimensions.ok())
        return 1;
    auto grid = new Grid(session.colors());
    auto effects = new Control(options.maxPendingCommands);
    scope (exit)
    {
        grid.close();
        session.write("\x1b[0m\x1b[?25h");
        if (closeOwned)
            session.close();
        effects.shutdown();
    }
    if (session.write("\x1b[?25l").code != Status.ok)
        return 1;
    const period = (1_000_000_000L + options.maxFramesPerSecond - 1) / options.maxFramesPerSecond;
    Loop loop = Loop(grid, effects, period, options.maxEventsPerFrame);
    loop.queueResize(dimensions.value);
    const handled = loop.run(session, update, view);
    return handled.code == Status.ok ? effects.exitCode() : 1;
}

struct Loop
{
    Grid grid;
    Control effects;
    long period;
    uint budget;
    private ulong frame;
    private long nextFrame;
    private uint left;
    private Size pendingSize;
    private bool pendingResize;
    private bool pendingInvalidate;
    private bool repaint;
    private bool preferInput = true;

    void queueResize(Size size) nothrow @nogc
    {
        // A burst can shrink and restore the terminal before one frame; the reflowed screen needs a repaint.
        pendingInvalidate = pendingInvalidate || size != grid.size();
        pendingSize = size;
        pendingResize = true;
        repaint = true;
    }

    Error run(ref Session session, scope Update update, scope View view)
    {
        Event incoming;
        bool pending;
        while (!effects.stoppingNow())
        {
            const instant = now();
            if (instant >= nextFrame)
            {
                const refreshed = refresh(instant, (scope const(char)[] bytes) @safe => session.write(bytes),
                        update, view);
                if (refreshed.code != Status.ok)
                    return refreshed;
            }
            if (effects.stoppingNow())
                break;
            if (!hasBudget())
                continue;
            if (pending)
            {
                pending = false;
                dispatch(incoming, update);
                incoming = Event.init;
                continue;
            }
            if (!preferInput)
            {
                Event local;
                if (effects.poll(instant, frame, local))
                {
                    dispatch(local, update);
                    preferInput = true;
                    continue;
                }
            }
            const timeout = preferInput ? 0 : effects.waitNanos(instant, frame, nextFrame, repaint);
            preferInput = false;
            const captured = capture(session, timeout, incoming, pending);
            if (captured.code != Status.ok)
                return captured;
        }
        return Error.init;
    }

    private Error capture(ref Session session, long timeout, out Event incoming, out bool pending)
    {
        auto input = session.next(timeout);
        if (!input.ok())
            return input.error.code == Status.timedOut ? Error.init : input.error;
        if (input.value.kind == EventKind.resize)
            queueResize(input.value.size);
        else
        {
            incoming = input.value;
            pending = true;
        }
        return Error.init;
    }

    private bool hasBudget() nothrow @nogc
    {
        if (left != 0)
            return true;
        const wait = nextFrame - now();
        if (wait > 0)
            Thread.sleep(dur!"nsecs"(wait));
        return false;
    }

    private void dispatch(Event event, scope Update update)
    {
        --left;
        auto active = effects.begin();
        scope (exit)
            effects.end();
        if (effects.stoppingNow())
            return;
        update(event, active);
        if (event.kind == EventKind.eof)
            effects.quit(0);
        repaint = true;
    }

    Error refresh(long instant, scope Sink write, scope Update update, scope View view)
    {
        left = budget;
        nextFrame = advance(instant, period);
        ++frame;
        if (pendingResize)
        {
            pendingResize = false;
            const resized = grid.resize(pendingSize);
            if (resized.code != Status.ok)
                return resized;
            if (pendingInvalidate)
                grid.invalidate();
            pendingInvalidate = false;
            Event event;
            event.kind = EventKind.resize;
            event.size = pendingSize;
            dispatch(event, update);
        }
        if (!repaint || effects.stoppingNow())
            return Error.init;
        repaint = false;
        const generation = grid.begin();
        if (generation == 0)
            return Error(Status.resourceExhausted, "TUI frame identities exhausted");
        {
            scope (exit)
                grid.end();
            auto target = Frame(grid, generation);
            view(target);
        }
        return grid.diff(write);
    }
}
