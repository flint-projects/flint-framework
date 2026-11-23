/// View-thread effect admission, periodic ticks, and shutdown.
module flint.engine.tui.effects;

import core.thread.osthread : Thread;
import core.time : dur;
import flint.arena : Error, Result, Status;
import flint.conc : Deadline;
import flint.term : Event, EventKind;
import flint.engine.tui.commands : Commands, issueId, slot;
import flint.engine.tui.types : Command, CommandId, TimerId;

@safe:

private enum maximumTimers = 256;
private enum expired = Error(Status.invalidArgument, "effects are outside their update callback");
private enum timerMissing = Error(Status.notFound, "unknown TUI timer");

/// Effects available to the current serial model update.
struct Effects
{
    private Control controller;
    private ulong generation;

    package(flint.engine.tui) this(Control controller, ulong generation)
    {
        this.controller = controller;
        this.generation = generation;
    }

    /// Submit a command with owned captures and receive its stable identity.
    Result!CommandId submit(Command command)
    {
        return current() ? controller.commands.submit(command) : Result!CommandId(CommandId.init, expired);
    }

    /// Cancel a pending command and ignore its eventual result.
    Error cancel(CommandId id)
    {
        return current() ? controller.commands.cancel(id) : expired;
    }

    /// Stop admission and exit the terminal application.
    void quit(int exitCode = 0)
    {
        if (current())
            controller.quit(exitCode);
    }

    /// Schedule a recurring monotonic tick, coalesced per frame.
    Result!TimerId tick(long intervalNanos)
    {
        return current() ? controller.tick(intervalNanos) : Result!TimerId(TimerId.init, expired);
    }

    /// Retire a timer so it produces no further events.
    Error cancelTimer(TimerId id)
    {
        return current() ? controller.cancelTimer(id) : expired;
    }

    private bool current() nothrow @nogc
    {
        return controller !is null && controller.current(generation);
    }
}

package(flint.engine.tui):

long now() nothrow @nogc
{
    return Deadline.afterMillis(0).monotonicNanoseconds;
}

long advance(long instant, long delta) pure nothrow @nogc
{
    return delta < long.max - instant ? instant + delta : long.max;
}

private struct Timer
{
    ulong id;
    long interval;
    long next;
    ulong delivered;
}

final class Control
{
    private Thread owner;
    private Commands commands;
    private Timer[maximumTimers] timers;
    private uint timerCount;
    private uint cursor;
    private ulong generation;
    private ulong active;
    private bool stopping;
    private int result;
    private bool preferTimers = true;

    this(uint capacity)
    {
        owner = Thread.getThis();
        commands = new Commands(capacity);
    }

    Effects begin()
    {
        if (generation == ulong.max)
        {
            quit(1);
            return Effects.init;
        }
        active = ++generation;
        return Effects(this, active);
    }

    void end() nothrow @nogc
    {
        active = 0;
    }

    bool current(ulong candidate) nothrow @nogc
    {
        return Thread.getThis() is owner && candidate != 0 && candidate == active && !stopping;
    }

    void quit(int code) nothrow
    {
        if (stopping)
            return;
        stopping = true;
        result = code;
        commands.stop();
    }

    bool stoppingNow() const pure nothrow @nogc
    {
        return stopping;
    }

    int exitCode() const pure nothrow @nogc
    {
        return result;
    }

    Result!TimerId tick(long intervalNanos) nothrow @nogc
    {
        if (intervalNanos <= 0)
            return Result!TimerId(TimerId.init, Error(Status.invalidArgument, "TUI tick interval must be positive"));
        if (timerCount == timers.length)
            return Result!TimerId(TimerId.init, Error(Status.resourceExhausted, "TUI timer table is full"));
        foreach (index, ref timer; timers)
        {
            if (timer.id != 0)
                continue;
            const id = issueId(cast(uint) index);
            if (id == 0)
                return Result!TimerId(TimerId.init, Error(Status.resourceExhausted, "TUI timer identities exhausted"));
            timer = Timer(id, intervalNanos, advance(now(), intervalNanos));
            ++timerCount;
            return Result!TimerId(TimerId(id));
        }
        assert(0, "TUI timer count is inconsistent");
    }

    Error cancelTimer(TimerId id) nothrow @nogc
    {
        const index = slot(id.value);
        if (id.value == 0 || index >= timers.length || timers[index].id != id.value)
            return timerMissing;
        timers[index] = Timer.init;
        --timerCount;
        return Error.init;
    }

    bool poll(long instant, ulong frame, out Event event) nothrow @nogc
    {
        if (preferTimers && tickReady(instant, frame, event))
        {
            preferTimers = false;
            return true;
        }
        if (commands.poll(event))
        {
            preferTimers = true;
            return true;
        }
        return tickReady(instant, frame, event);
    }

    private bool tickReady(long instant, ulong frame, out Event event) nothrow @nogc
    {
        if (timerCount == 0)
            return false;
        foreach (offset; 0 .. maximumTimers)
        {
            const index = (cursor + offset) % maximumTimers;
            ref Timer timer = timers[index];
            if (timer.id == 0 || instant < timer.next || timer.delivered == frame)
                continue;
            const remainder = (instant - timer.next) % timer.interval;
            timer.next = advance(instant, timer.interval - remainder);
            timer.delivered = frame;
            cursor = (index + 1) % maximumTimers;
            event.kind = EventKind.timer;
            event.timerId = timer.id;
            return true;
        }
        return false;
    }

    long waitNanos(long instant, ulong frame, long nextFrame, bool repaint) nothrow @nogc
    {
        long due = repaint ? nextFrame : long.max;
        if (commands.active())
        {
            const commandPoll = advance(instant, 8_000_000);
            if (commandPoll < due)
                due = commandPoll;
        }
        if (timerCount != 0)
        {
            foreach (ref const timer; timers)
            {
                if (timer.id == 0)
                    continue;
                const wake = timer.delivered == frame && timer.next < nextFrame ? nextFrame : timer.next;
                if (wake < due)
                    due = wake;
            }
        }
        return due == long.max ? -1 : due <= instant ? 0 : due - instant;
    }

    void shutdown() nothrow
    {
        end();
        commands.stop();
        const deadline = advance(now(), 2_000_000_000);
        while (!commands.stopped())
        {
            const left = deadline - now();
            if (left <= 0)
                return;
            Thread.sleep(dur!"nsecs"(left < 2_000_000 ? left : 2_000_000));
        }
    }
}
