module flint.engine.cache.flight;

import core.atomic : atomicLoad, atomicOp;
import core.lifetime : move;
import core.sync.mutex : Mutex;
import core.thread.fiber : Fiber;
import core.thread.osthread : Thread;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.engine.cache.sys.bytes : OwnedBytes;
import flint.engine.cache.sys.wake : Wake;
import flint.conc : Background, CancelSource, Context, Deadline, startBackground;

@safe:

private enum flightCount = 1024;
private enum maxParticipants = 8192;

package(flint.engine.cache) struct Admission
{
    uint participant;
    bool leader;
}

private struct Flight
{
    OwnedBytes data;
    CancelSource cancellation;
    ulong hash;
    uint present;
    uint interested;
    Error outcome;
    Thread ownerThread;
    Fiber ownerFiber;
    bool settled;
    bool invalidated;
}

private struct Lookup
{
    uint match;
    uint vacancy;
}

private struct Participant
{
    Context context;
    uint flight;
    uint next;
    uint previous;
    bool departed;
}

package(flint.engine.cache) final class Flights
{
    private Mutex gate;
    private Background worker;
    private Flight[] flights;
    private Participant[] people;
    private uint firstActive;
    private uint firstFree;
    private size_t capacity;
    private size_t bytes;
    private bool closing;
    private Wake wake;
    // Flights from preparation until release. Written only under the gate.
    private shared uint live;
    // Flights ever prepared. Written only under the gate after live increases.
    private shared ulong started;

    this(size_t limit)
    {
        gate = new Mutex;
        capacity = limit;
        flights = new Flight[flightCount + 1];
        people = new Participant[maxParticipants + 1];
        firstFree = 1;
        foreach (index; 1 .. maxParticipants)
            people[index].next = index + 1;
    }

    Error start()
    {
        const opened = wake.open();
        if (opened.code != Status.ok)
            return opened;
        const started = startBackground(&monitor, worker);
        if (started.code != Status.ok)
            wake.release();
        return started;
    }

    Result!Admission enter(ulong hash, scope const(ubyte)[] key, ref Context context) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        const ready = context.check();
        if (ready.code != Status.ok)
            return Result!Admission(Admission.init, ready);
        if (closing || firstFree == 0)
            return rejected(closing ? Status.unavailable : Status.resourceExhausted);
        const located = locate(hash, key);
        uint match = located.match;
        const leader = match == 0;
        if (leader)
        {
            if (located.vacancy == 0 || key.length > capacity - bytes)
                return rejected(Status.resourceExhausted);
            const started = prepare(located.vacancy, hash, key);
            if (started.code != Status.ok)
                return Result!Admission(Admission.init, started);
            match = located.vacancy;
        }
        else if (!flights[match].settled && flights[match].ownerThread is Thread.getThis()
                && flights[match].ownerFiber is Fiber.getThis())
            return rejected(Status.conflict);
        return Result!Admission(Admission(addParticipant(match, context), leader));
    }

    private Lookup locate(ulong hash, scope const(ubyte)[] key) nothrow @nogc
    {
        Lookup result;
        uint remaining = atomicLoad(live);
        foreach (index; 1 .. flights.length)
        {
            const flight = &flights[index];
            if (flight.present == 0)
            {
                if (result.vacancy == 0)
                    result.vacancy = cast(uint) index;
                if (remaining == 0)
                    break;
            }
            else
            {
                --remaining;
                if (!flight.invalidated && flight.hash == hash && flight.data.matches(key))
                {
                    result.match = cast(uint) index;
                    break;
                }
            }
        }
        return result;
    }

    /// Snapshot for an explicit mutation made without the gate. Zero means a flight may be running.
    ulong idleMark() nothrow @nogc
    {
        const mark = atomicLoad(started);
        return atomicLoad(live) == 0 ? mark + 1 : 0;
    }

    /// Whether no flight was prepared since idleMark. A mutation between the two observations
    /// cannot then be overwritten by a load whose read preceded it.
    bool stillIdle(ulong mark) nothrow @nogc
    {
        return mark != 0 && atomicLoad(started) + 1 == mark;
    }

    private Error prepare(uint index, ulong hash, scope const(ubyte)[] key) nothrow @nogc
    {
        auto flight = &flights[index];
        auto source = CancelSource.create(Context.init, Deadline.none());
        if (!source.ok)
            return source.error;
        const allocated = flight.data.replace(key, null);
        if (allocated != Status.ok)
            return Error(allocated, "could not retain cache load key");
        flight.cancellation = move(source.value);
        flight.hash = hash;
        flight.ownerThread = Thread.getThis();
        flight.ownerFiber = Fiber.getThis();
        bytes += key.length;
        atomicOp!"+="(live, 1U);
        atomicOp!"+="(started, 1UL);
        wake.notify();
        return Error.init;
    }

    private static Result!Admission rejected(Status status) pure nothrow @nogc
    {
        return Result!Admission(Admission.init, Error(status, "cache load cannot be admitted"));
    }

    private uint addParticipant(uint index, ref Context owned) nothrow @nogc
    {
        const id = firstFree;
        auto person = &people[id];
        firstFree = person.next;
        person.context = owned;
        person.flight = index;
        if (firstActive != 0)
            people[firstActive].previous = id;
        person.next = firstActive;
        firstActive = id;
        ++flights[index].present;
        ++flights[index].interested;
        return id;
    }

    Context loadContext(Admission admission) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        return flights[people[admission.participant].flight].cancellation.context();
    }

    void lock() nothrow @nogc
    {
        gate.lock_nothrow();
    }

    void unlock() nothrow @nogc
    {
        gate.unlock_nothrow();
    }

    bool canPublish(Admission admission) nothrow @nogc
    {
        const target = people[admission.participant].flight;
        auto flight = &flights[target];
        for (auto participant = firstActive; participant != 0; participant = people[participant].next)
        {
            auto person = &people[participant];
            if (person.flight == target && person.context.cancelled())
                removeInterest(*person, *flight);
        }
        return !closing && !flight.invalidated && flight.interested != 0;
    }

    version (unittest) uint participants() nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        uint count;
        for (auto i = firstActive; i != 0; i = people[i].next)
            ++count;
        return count;
    }

    void settle(Admission admission, scope const(ubyte)[] key, scope const(ubyte)[] value, Error outcome) nothrow @nogc
    {
        auto flight = &flights[people[admission.participant].flight];
        if (outcome.code == Status.ok)
        {
            const saved = value.length > capacity - bytes ? Status.resourceExhausted : flight.data.replace(key, value);
            if (saved == Status.ok)
                bytes += value.length;
            else
                outcome = Error(saved, "cache load result exceeds the flight copy budget");
        }
        flight.outcome = outcome;
        flight.settled = true;
        flight.cancellation.close();
    }

    bool get(Admission admission, ref scope RequestArena arena, out Result!Buffer result) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        const person = &people[admission.participant];
        const ready = person.context.check();
        if (ready.code != Status.ok || closing)
        {
            result.error = ready.code == Status.ok ? Error(Status.cancelled, "cache shut down") : ready;
            return true;
        }
        const flight = &flights[person.flight];
        if (!flight.settled)
            return false;
        result = flight.outcome.code == Status.ok
            ? flight.data.copyValue(arena) : Result!Buffer(Buffer.init, flight.outcome);
        return true;
    }

    void invalidate(ulong hash, scope const(ubyte)[] key) nothrow @nogc
    {
        if (atomicLoad(live) == 0)
            return;
        const match = locate(hash, key).match;
        if (match != 0)
            flights[match].invalidated = true;
    }

    void invalidateAll() nothrow @nogc
    {
        foreach (ref flight; flights)
        {
            if (flight.present != 0)
                flight.invalidated = true;
        }
    }

    void leave(Admission admission) nothrow @nogc
    {
        gate.lock_nothrow();
        scope (exit)
            gate.unlock_nothrow();
        const index = admission.participant;
        auto person = &people[index];
        auto flight = &flights[person.flight];
        removeInterest(*person, *flight);
        if (person.previous == 0)
            firstActive = person.next;
        else
            people[person.previous].next = person.next;
        if (person.next != 0)
            people[person.next].previous = person.previous;
        if (--flight.present == 0)
            release(*flight);
        *person = Participant.init;
        person.next = firstFree;
        firstFree = index;
    }

    void close() nothrow @nogc
    {
        {
            gate.lock_nothrow();
            scope (exit)
                gate.unlock_nothrow();
            if (closing)
                return;
            closing = true;
            foreach (ref flight; flights)
            {
                if (flight.present != 0 && !flight.settled)
                    flight.cancellation.cancel();
            }
            wake.notify();
        }
        // The monitor returns once it observes `closing` under the gate.
        worker.join();
    }

    private static void removeInterest(ref Participant person, ref Flight flight) nothrow @nogc
    {
        if (person.departed)
            return;
        person.departed = true;
        if (--flight.interested == 0 && !flight.settled)
        {
            flight.invalidated = true;
            flight.cancellation.cancel();
        }
    }

    private void release(ref Flight flight) nothrow @nogc
    {
        atomicOp!"-="(live, 1U);
        bytes -= flight.data.bytes;
        flight.data.release();
        flight.cancellation.close();
        flight = Flight.init;
    }

    private void monitor() nothrow @nogc
    {
        for (;;)
        {
            gate.lock_nothrow();
            if (closing)
            {
                wake.release();
                gate.unlock_nothrow();
                return;
            }
            bool pending;
            for (auto participant = firstActive; participant != 0; participant = people[participant].next)
            {
                auto person = &people[participant];
                auto flight = &flights[person.flight];
                if (person.context.cancelled())
                    removeInterest(*person, *flight);
                pending = pending || !flight.settled;
            }
            gate.unlock_nothrow();
            wake.wait(pending ? 2 : -1);
        }
    }
}
