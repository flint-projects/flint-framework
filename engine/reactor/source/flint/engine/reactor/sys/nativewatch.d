module flint.engine.reactor.sys.nativewatch;

@safe:

// Linux nests an epoll descriptor in the owner's poller; macOS nests a kqueue the same way. Windows polls the watched
// sockets with WSAPoll on every loop pass, and the owner caps its completion-port wait at 1 ms while any is watched.
version (linux)
    version = ReactorNestedWatches;
else version (OSX)
    version = ReactorNestedWatches;

version (Windows)
{
    import core.sys.windows.winsock2 : SOCKET;
    import flint.arena : Error, Status;
    import flint.engine.reactor.types : NativeInterest, NativeReadyFn;

    private struct PollEntry
    {
        SOCKET fd;
        short events;
        short revents;
    }

    private enum short pollRead = 0x0100 | 0x0200; // POLLRDNORM | POLLRDBAND
    private enum short pollWrite = 0x0010; // POLLWRNORM
    private enum short pollFault = 0x0001 | 0x0002 | 0x0004; // POLLERR | POLLHUP | POLLNVAL

    private extern (Windows) int WSAPoll(PollEntry* descriptors, uint count, int timeout) @system nothrow @nogc;

    private struct Entry
    {
        bool live;
        int descriptor;
        NativeInterest interest;
        NativeReadyFn callback;
    }

    package(flint.engine.reactor) struct NativeWatches
    {
        private Entry[] entries;
        private PollEntry[] polled;
        private uint[] owners;
        private size_t live;

        void reserve(uint capacity)
        {
            entries = new Entry[capacity];
            polled = new PollEntry[capacity];
            owners = new uint[capacity];
        }

        bool enabled() const pure nothrow @nogc
        {
            return entries.length != 0;
        }

        /// Whether any socket is watched, so the owner must not block in its completion port for long.
        bool active() const pure nothrow @nogc
        {
            return live != 0;
        }

        Status update(int fd, NativeInterest interest, NativeReadyFn callback) nothrow @nogc
        {
            size_t empty = entries.length;
            foreach (index, ref entry; entries)
            {
                if (!entry.live)
                {
                    if (empty == entries.length)
                        empty = index;
                }
                else if (entry.descriptor == fd)
                {
                    entry = Entry(true, fd, interest, callback);
                    return Status.ok;
                }
            }
            if (empty == entries.length)
                return Status.resourceExhausted;
            entries[empty] = Entry(true, fd, interest, callback);
            ++live;
            return Status.ok;
        }

        Status remove(int fd) nothrow @nogc
        {
            foreach (ref entry; entries)
            {
                if (entry.live && entry.descriptor == fd)
                {
                    entry = Entry.init;
                    --live;
                }
            }
            return Status.ok;
        }

        Error notify(uint budget) nothrow @nogc
        {
            const count = gather();
            if (count == 0)
                return Error.init;
            if (!pollSockets(count))
                return Error(Status.ioError, "native socket poll failed");
            uint delivered;
            foreach (position; 0 .. count)
            {
                if (delivered == budget)
                    break;
                if (deliver(position))
                    ++delivered;
            }
            return Error.init;
        }

        /// Fill the poll array from the live watches; returns how many it holds.
        private uint gather() nothrow @nogc
        {
            uint count;
            foreach (index, ref entry; entries)
            {
                if (!entry.live || count == polled.length)
                    continue;
                const short wanted = cast(short)((entry.interest & NativeInterest.read ? pollRead
                        : 0) | (entry.interest & NativeInterest.write ? pollWrite : 0));
                polled[count] = PollEntry(cast(SOCKET) entry.descriptor, wanted, 0);
                owners[count++] = cast(uint) index;
            }
            return count;
        }

        // SAFETY: WSAPoll reads and updates only the preallocated array, for the count gather filled, during the call.
        private bool pollSockets(uint count) @trusted nothrow @nogc
        {
            return WSAPoll(polled.ptr, count, 0) >= 0;
        }

        /// Run the callback of a polled socket that became ready; returns whether one ran.
        private bool deliver(uint position) nothrow @nogc
        {
            const revents = polled[position].revents;
            if (revents == 0)
                return false;
            const entry = entries[owners[position]];
            // A callback may already have removed or replaced this watch.
            if (!entry.live || entry.descriptor != cast(int) polled[position].fd)
                return false;
            uint observed;
            if (revents & pollRead)
                observed |= NativeInterest.read;
            if (revents & pollWrite)
                observed |= NativeInterest.write;
            if (revents & pollFault)
                observed |= NativeInterest.error;
            const wanted = cast(uint) entry.interest | cast(uint) NativeInterest.error;
            if ((observed & wanted) == 0)
                return false;
            entry.callback(entry.descriptor, cast(NativeInterest)(observed & wanted));
            return true;
        }

        void release() nothrow @nogc
        {
            entries = null;
            polled = null;
            owners = null;
            live = 0;
        }
    }
}
else version (ReactorNestedWatches)
{
    import flint.arena : Error, Status;
    import flint.engine.reactor.sys.readiness : Readiness, ReadyEvent, destroyReadiness, poll, setNativeInterest;
    import flint.engine.reactor.types : NativeInterest, NativeReadyFn;

    private struct Entry
    {
        ulong generation;
        int descriptor;
        NativeInterest interest;
        NativeReadyFn callback;
    }

    package(flint.engine.reactor) struct NativeWatches
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
