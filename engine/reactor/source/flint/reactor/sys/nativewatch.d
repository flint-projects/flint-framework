module flint.reactor.sys.nativewatch;

@safe:

// Linux nests an epoll descriptor in the owner's poller; macOS nests a kqueue the same way.
version (linux)
    version = ReactorNativeWatches;
else version (OSX)
    version = ReactorNativeWatches;

version (ReactorNativeWatches)
{
    import flint.arena : Error, Status;
    import flint.reactor.sys.readiness : Readiness, ReadyEvent, destroyReadiness, poll, setNativeInterest;
    import flint.reactor.types : NativeInterest, NativeReadyFn;

    private struct Entry
    {
        ulong generation;
        int descriptor;
        NativeInterest interest;
        NativeReadyFn callback;
    }

    package(flint.reactor) struct NativeWatches
    {
        Readiness receiver;
        private Entry[] entries;
        private ulong generation;

        void reserve(uint capacity)
        {
            entries = new Entry[capacity];
        }

        bool enabled() const pure nothrow @nogc
        {
            return entries.length != 0;
        }

        Status update(int fd, NativeInterest interest, NativeReadyFn callback) nothrow @nogc
        {
            size_t empty = entries.length;
            foreach (index, ref entry; entries)
            {
                if (entry.generation == 0)
                {
                    if (empty == entries.length)
                        empty = index;
                }
                else if (entry.descriptor == fd)
                    return configure(index, Entry(entry.generation, fd, interest, callback));
            }
            if (empty == entries.length || generation == ulong.max >> 16)
                return Status.resourceExhausted;
            return configure(empty, Entry(++generation, fd, interest, callback));
        }

        Status remove(int fd) nothrow @nogc
        {
            foreach (ref entry; entries)
            {
                if (entry.generation == 0 || entry.descriptor != fd)
                    continue;
                const outcome = setNativeInterest(receiver, fd, 0, entry.interest, NativeInterest.none);
                if (outcome == Status.ok)
                    entry = Entry.init;
                return outcome;
            }
            return Status.ok;
        }

        Error notify(uint budget) nothrow @nogc
        {
            ReadyEvent[64] events;
            const count = budget < events.length ? budget : events.length;
            const observed = poll(receiver, events[0 .. count], 0);
            if (!observed.ok)
                return observed.error;
            foreach (event; events[0 .. observed.value])
            {
                const index = cast(ushort) event.token;
                if (index >= entries.length || (event.token >> 16) != entries[index].generation)
                    continue;
                const entry = entries[index];
                const observedInterest = (cast(uint) event.directions & cast(uint) entry.interest) | (event.fault
                        ? cast(uint) NativeInterest.error : 0);
                if (observedInterest != 0)
                    entry.callback(entry.descriptor, cast(NativeInterest) observedInterest);
            }
            return Error.init;
        }

        void release() nothrow @nogc
        {
            destroyReadiness(receiver);
            entries = null;
        }

        private Status configure(size_t index, Entry updated) nothrow @nogc
        {
            const token = (updated.generation << 16) | index;
            const status = setNativeInterest(receiver, updated.descriptor, token,
                    entries[index].interest, updated.interest);
            if (status == Status.ok)
                entries[index] = updated;
            return status;
        }
    }
}
