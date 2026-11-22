module flint.reactor.internal.queues;

import core.atomic : atomicStore, cas;
import core.lifetime : move;
import flint.reactor.sys.workers : yieldWorker;
import flint.arena : Error, Result, Status;
import flint.conc : Deadline;
import flint.reactor.types : ConnectionId, TaskContext, TaskDelegate, TaskFn, TimerId;

@safe:

package(flint.reactor) struct Message
{
    TaskFn task;
    ConnectionId close;
    TaskContext context;
    TaskDelegate boundTask;
    bool invokeIfCancelled;
}

/// Bound tasks enter and leave their owner worker's ring. Cross-worker messages use function pointers.
package(flint.reactor) struct Mailbox
{
    private shared bool held;
    private bool closed;
    private size_t head;
    private size_t depth;
    private Message[] slots;

    @disable this(this);

    void initialize(uint capacity)
    {
        slots = new Message[capacity];
    }

    Status enqueue(Message message) nothrow @nogc
    {
        while (!cas(&held, false, true))
            yieldWorker();
        scope (exit)
            atomicStore(held, false);
        if (closed)
            return Status.unavailable;
        if (depth == slots.length)
            return Status.resourceExhausted;

        slots[(head + depth) % slots.length] = move(message);
        ++depth;
        return Status.ok;
    }

    void seal() nothrow @nogc
    {
        while (!cas(&held, false, true))
            yieldWorker();
        scope (exit)
            atomicStore(held, false);
        closed = true;
        while (depth != 0)
        {
            slots[head] = Message.init;
            head = (head + 1) % slots.length;
            --depth;
        }
    }

    /// Whether a message is waiting. A concurrent producer may add one immediately afterwards.
    bool pending() nothrow @nogc
    {
        while (!cas(&held, false, true))
            yieldWorker();
        scope (exit)
            atomicStore(held, false);
        return depth != 0;
    }

    bool dequeue(out Message message) nothrow @nogc
    {
        while (!cas(&held, false, true))
            yieldWorker();
        scope (exit)
            atomicStore(held, false);
        if (depth == 0)
            return false;

        message = move(slots[head]);
        head = (head + 1) % slots.length;
        --depth;
        return true;
    }
}

private struct TimedTask
{
    Deadline deadline;
    TaskFn callback;
    TimerId id;
}

/// The owning worker alone accesses this bounded priority queue.
package(flint.reactor) struct Timers
{
    private TimedTask[] entries;
    private size_t length;

    @disable this(this);

    void initialize(uint capacity)
    {
        entries = new TimedTask[capacity];
    }

    Status schedule(TimerId id, Deadline deadline, TaskFn callback) nothrow @nogc
    {
        if (length == entries.length)
            return Status.resourceExhausted;

        entries[length] = TimedTask(deadline, callback, id);
        moveUp(length);
        ++length;
        return Status.ok;
    }

    Status cancel(TimerId timer) nothrow @nogc
    {
        foreach (index; 0 .. length)
        {
            if (entries[index].id == timer)
            {
                remove(index);
                return Status.ok;
            }
        }
        return Status.notFound;
    }

    TaskFn takeDue(Deadline now) nothrow @nogc
    {
        if (length == 0 || entries[0].deadline.monotonicNanoseconds > now.monotonicNanoseconds)
            return null;
        auto callback = entries[0].callback;
        remove(0);
        return callback;
    }

    uint waitMillis(Deadline now, uint cap) const nothrow @nogc
    {
        if (length == 0)
            return cap;
        const target = entries[0].deadline.monotonicNanoseconds;
        if (target <= now.monotonicNanoseconds)
            return 0;
        const remaining = cast(ulong) target - cast(ulong) now.monotonicNanoseconds;
        const millis = remaining / 1_000_000 + (remaining % 1_000_000 != 0);
        return millis < cap ? cast(uint) millis : cap;
    }

    void clear() nothrow @nogc
    {
        length = 0;
    }

    bool empty() const pure nothrow @nogc
    {
        return length == 0;
    }

    private void remove(size_t index) nothrow @nogc
    {
        --length;
        if (index == length)
            return;

        entries[index] = entries[length];
        index = moveUp(index);
        for (;;)
        {
            const left = index * 2 + 1;
            if (left >= length)
                break;
            const right = left + 1;
            const child = right < length && precedes(entries[right], entries[left]) ? right : left;
            if (!precedes(entries[child], entries[index]))
                break;
            exchange(index, child);
            index = child;
        }
    }

    private size_t moveUp(size_t index) nothrow @nogc
    {
        while (index != 0)
        {
            const parent = (index - 1) / 2;
            if (!precedes(entries[index], entries[parent]))
                break;
            exchange(index, parent);
            index = parent;
        }
        return index;
    }

    private void exchange(size_t first, size_t second) nothrow @nogc
    {
        const entry = entries[first];
        entries[first] = entries[second];
        entries[second] = entry;
    }

    private static bool precedes(ref const TimedTask first, ref const TimedTask second) pure nothrow @nogc
    {
        return first.deadline.monotonicNanoseconds < second.deadline.monotonicNanoseconds
            || (first.deadline == second.deadline && first.id.generation < second.id.generation);
    }
}
