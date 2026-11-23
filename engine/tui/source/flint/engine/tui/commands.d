/// Bounded FIFO command and completion ownership.
module flint.engine.tui.commands;

import core.atomic : atomicLoad, casWeak;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import flint.arena : Error, Result, Status;
import flint.term : Event, EventKind;
import flint.engine.tui.sys.worker : launch, park, wake;
import flint.engine.tui.types : Command, CommandId;

@safe:
package(flint.engine.tui):

enum slotBits = 12;
enum maximumCommands = 1 << slotBits;
private enum maximumThreads = 4;
private enum maximumPayload = 65_536;
private enum maximumMessage = 512;
private shared ulong idCounter;

ulong issueId(uint index) nothrow @nogc
{
    for (;;)
    {
        const observed = atomicLoad(idCounter);
        if (observed == ulong.max >> slotBits)
            return 0;
        if (casWeak(&idCounter, observed, observed + 1))
            return ((observed + 1) << slotBits) | index;
    }
}

uint slot(ulong id) pure nothrow @nogc
{
    return cast(uint)(id & (maximumCommands - 1));
}

private enum Phase : ubyte
{
    free,
    queued,
    running,
    ready
}

private struct Entry
{
    ulong id;
    Phase phase;
    bool cancelled;
    Command work;
    Event event;
}

private struct Queue
{
    uint[] contents;
    uint first;
    uint count;

    void push(uint value) nothrow @nogc
    {
        assert(count < contents.length);
        contents[(first + count) % contents.length] = value;
        ++count;
    }

    uint pull() nothrow @nogc
    {
        assert(count != 0);
        const value = contents[first];
        first = cast(uint)((first + 1) % contents.length);
        --count;
        return value;
    }

    void remove(uint value) nothrow @nogc
    {
        uint index;
        while (index < count && contents[(first + index) % contents.length] != value)
            ++index;
        assert(index < count);
        --count;
        for (; index < count; ++index)
            contents[(first + index) % contents.length] = contents[(first + index + 1) % contents.length];
    }
}

final class Commands
{
    private Mutex gate;
    private Condition available;
    private Entry[] entries;
    private uint[] free;
    private uint freeCount;
    private Queue pending;
    private Queue finished;
    private uint threadCount;
    private bool closed;

    this(uint capacity)
    {
        gate = new Mutex;
        available = new Condition(gate);
        entries = new Entry[capacity];
        free = new uint[capacity];
        pending.contents = new uint[capacity];
        finished.contents = new uint[capacity];
        freeCount = capacity;
        foreach (index, ref item; free)
            item = cast(uint)(capacity - 1 - index);
    }

    Result!CommandId submit(Command task)
    {
        if (task is null)
            return Result!CommandId(CommandId.init, Error(Status.invalidArgument, "missing TUI command"));
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        if (closed)
            return Result!CommandId(CommandId.init, Error(Status.cancelled, "TUI command intake closed"));
        if (freeCount == 0)
            return Result!CommandId(CommandId.init, Error(Status.resourceExhausted, "TUI command queue is full"));
        if (threadCount == 0 && !start())
            return Result!CommandId(CommandId.init, Error(Status.unavailable, "TUI worker startup failed"));

        const index = free[freeCount - 1];
        const id = issueId(index);
        if (id == 0)
            return Result!CommandId(CommandId.init, Error(Status.resourceExhausted,
                    "TUI command identities exhausted"));
        --freeCount;
        entries[index] = Entry(id, Phase.queued, false, task);
        pending.push(index);
        wake(available);
        return Result!CommandId(CommandId(id));
    }

    Error cancel(CommandId id) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        const index = slot(id.value);
        if (id.value == 0 || index >= entries.length || entries[index].id != id.value)
            return Error(Status.notFound, "unknown TUI command");
        if (entries[index].cancelled || entries[index].phase == Phase.ready)
            return Error(Status.notFound, "TUI command is no longer pending");
        if (entries[index].phase == Phase.queued)
        {
            pending.remove(index);
            release(index);
        }
        else
            entries[index].cancelled = true;
        return Error.init;
    }

    bool poll(out Event completed) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        if (finished.count == 0)
            return false;
        const index = finished.pull();
        completed = entries[index].event;
        release(index);
        return true;
    }

    bool active() nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        return freeCount != entries.length;
    }

    bool stopped() nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        return threadCount == 0;
    }

    void stop() nothrow
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        closed = true;
        while (pending.count != 0)
            release(pending.pull());
        while (finished.count != 0)
            release(finished.pull());
        wake(available);
    }

    private bool start()
    {
        const target = entries.length < maximumThreads ? entries.length : maximumThreads;
        while (threadCount < target && launch(&work))
            ++threadCount;
        return threadCount != 0;
    }

    private bool take(out uint index, out Command task, out ulong id) nothrow
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        while (!closed && pending.count == 0)
        {
            if (!park(available))
                return false;
        }
        if (closed)
            return false;
        index = pending.pull();
        entries[index].phase = Phase.running;
        task = entries[index].work;
        id = entries[index].id;
        return true;
    }

    private void work() nothrow
    {
        scope (exit)
        {
            gate.lock_nothrow();
            --threadCount;
            gate.unlock_nothrow();
        }
        uint index;
        Command task;
        ulong id;
        while (take(index, task, id))
        {
            publish(index, execute(task, id));
            task = null;
        }
    }

    private void publish(uint index, Event event) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        if (closed || entries[index].cancelled)
            release(index);
        else
        {
            entries[index].work = null;
            entries[index].event = event;
            entries[index].phase = Phase.ready;
            finished.push(index);
        }
    }

    private void release(uint index) nothrow @nogc
    {
        entries[index] = Entry.init;
        free[freeCount++] = index;
    }
}

private Event execute(Command command, ulong id) nothrow
{
    Event event;
    event.kind = EventKind.command;
    event.commandId = id;
    try
    {
        auto completed = command();
        if (completed.payload.length > maximumPayload || completed.paste.length > maximumPayload)
        {
            event.error = Error(Status.resourceExhausted, "TUI command payload exceeds 65536 bytes");
            return event;
        }
        completed.kind = EventKind.command;
        completed.commandId = id;
        completed.timerId = 0;
        completed.payload = completed.payload.dup;
        completed.paste = completed.paste.idup;
        completed.error.message = completed.error.message.length > maximumMessage
            ? "TUI command error exceeds diagnostic limit" : completed.error.message.idup;
        return completed;
    }
    catch (Exception)
    {
        event.error = Error(Status.ioError, "TUI command failed");
        return event;
    }
}
