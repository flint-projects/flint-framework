module flint.reactor.sys.readiness;

import flint.arena : Error, Result, Status;

@safe:

version (Posix)
{
    import core.stdc.errno : EINTR, errno;
    import core.sys.posix.unistd : close;
    import flint.reactor.sys.sockets : Socket, socketError;

    package(flint.reactor) enum Interest : ubyte
    {
        none = 0,
        read = 1,
        write = 2,
    }

    package(flint.reactor) struct ReadyEvent
    {
        ulong token;
        Interest directions;
        bool fault;
    }

    package(flint.reactor) struct Readiness
    {
        int descriptor = -1;

        bool valid() const pure nothrow @nogc
        {
            return descriptor >= 0;
        }
    }

    // SAFETY: The owner invalidates its only live readiness descriptor before releasing the OS resource.
    package(flint.reactor) void destroyReadiness(ref Readiness poller) @trusted nothrow @nogc
    {
        if (poller.valid)
        {
            const descriptor = poller.descriptor;
            poller.descriptor = -1;
            close(descriptor);
        }
    }
}

version (linux)
{
    import core.stdc.errno : EBADF, ENOENT;
    import core.sys.linux.epoll : EPOLLIN, EPOLLOUT, EPOLLERR, EPOLLHUP, EPOLLRDHUP, EPOLLEXCLUSIVE,
        EPOLL_CLOEXEC, EPOLL_CTL_ADD, EPOLL_CTL_DEL, EPOLL_CTL_MOD, epoll_create1, epoll_ctl, epoll_event, epoll_wait;
    import flint.reactor.types : NativeInterest;

    // SAFETY: epoll_create1 has no pointer input and on success returns one owned descriptor.
    package(flint.reactor) Result!Readiness openReadiness() @trusted nothrow @nogc
    {
        const descriptor = epoll_create1(EPOLL_CLOEXEC);
        if (descriptor < 0)
            return Result!Readiness(Readiness.init, Error(socketError(errno), "epoll_create1 failed"));
        return Result!Readiness(Readiness(descriptor));
    }

    // SAFETY: The owner passes a valid poller/socket pair. epoll_ctl retains only the integer token.
    @trusted package(flint.reactor) Status setInterest(Readiness poller, Socket socket, ulong token,
            Interest previous, Interest desired) nothrow @nogc
    {
        if (previous == desired)
            return Status.ok;
        epoll_event event;
        event.data.u64 = token;
        if (token == 1)
            event.events |= EPOLLEXCLUSIVE;
        if (desired & Interest.read)
            event.events |= token == 1 ? EPOLLIN : EPOLLIN | EPOLLRDHUP;
        if (desired & Interest.write)
            event.events |= EPOLLOUT;

        const change = desired == Interest.none ? EPOLL_CTL_DEL : (previous == Interest.none
                ? EPOLL_CTL_ADD : EPOLL_CTL_MOD);
        if (epoll_ctl(poller.descriptor, change, socket.descriptor, desired == Interest.none ? null : &event) != 0)
            return socketError(errno);
        return Status.ok;
    }

    // SAFETY: epoll borrows the caller-owned descriptor and copies only an integer token and flags.
    package(flint.reactor) Status setNativeInterest(Readiness poller, int fd, ulong token,
            NativeInterest previous, NativeInterest desired) @trusted nothrow @nogc
    {
        if (previous == desired)
            return Status.ok;
        epoll_event event;
        event.data.u64 = token;
        event.events = EPOLLRDHUP;
        if (desired & NativeInterest.read)
            event.events |= EPOLLIN;
        if (desired & NativeInterest.write)
            event.events |= EPOLLOUT;
        const change = desired == NativeInterest.none ? EPOLL_CTL_DEL
            : (previous == NativeInterest.none ? EPOLL_CTL_ADD : EPOLL_CTL_MOD);
        if (epoll_ctl(poller.descriptor, change, fd, change == EPOLL_CTL_DEL ? null : &event) == 0)
            return Status.ok;
        const failure = errno;
        if (change == EPOLL_CTL_DEL && (failure == EBADF || failure == ENOENT))
            return Status.ok;
        return socketError(failure);
    }

    // SAFETY: The wait uses bounded local storage and returns synchronously. Only entries reported by epoll are read.
    @trusted package(flint.reactor) Result!size_t poll(Readiness port, scope ReadyEvent[] ready, uint ms) nothrow @nogc
    {
        if (ready.length == 0 || ms > int.max)
            return Result!size_t(0, Error(Status.invalidArgument, "invalid epoll wait bounds"));
        epoll_event[64] nativeEvents;
        const capacity = ready.length < nativeEvents.length ? ready.length : nativeEvents.length;
        const count = epoll_wait(port.descriptor, nativeEvents.ptr, cast(int) capacity, cast(int) ms);
        if (count < 0)
            return errno == EINTR ? Result!size_t(0) : Result!size_t(0, Error(socketError(errno),
                    "epoll wait failed"));
        foreach (i; 0 .. count)
        {
            const flags = nativeEvents[i].events;
            const readable = (flags & (EPOLLIN | EPOLLERR | EPOLLHUP | EPOLLRDHUP)) != 0;
            const writable = (flags & (EPOLLOUT | EPOLLERR | EPOLLHUP)) != 0;
            const fault = (flags & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) != 0;
            ready[i] = ReadyEvent(nativeEvents[i].data.u64, directions(readable, writable), fault);
        }
        return Result!size_t(cast(size_t) count);
    }
}
else version (OSX)
{
    import core.stdc.errno : EBADF, ENOENT;
    import core.sys.darwin.sys.event : EV_ADD, EV_DELETE, EV_ENABLE, EV_EOF, EV_ERROR, EVFILT_READ,
        EVFILT_WRITE, NOTE_LOWAT, kevent64, kevent64_s, kqueue;
    import core.sys.posix.fcntl : FD_CLOEXEC, F_SETFD, fcntl;
    import core.sys.posix.time : timespec;
    import flint.reactor.types : NativeInterest;

    // SAFETY: kqueue returns a newly owned descriptor, released on close-on-exec setup failure.
    package(flint.reactor) Result!Readiness openReadiness() @trusted nothrow @nogc
    {
        const descriptor = kqueue();
        if (descriptor < 0)
            return Result!Readiness(Readiness.init, Error(socketError(errno), "kqueue failed"));
        if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0)
        {
            close(descriptor);
            return Result!Readiness(Readiness.init, Error(Status.ioError, "kqueue setup failed"));
        }
        return Result!Readiness(Readiness(descriptor));
    }

    // SAFETY: kevent64 synchronously copies each change, retaining only the integer token. An errored change is fatal
    // to the owner loop, which closes its socket before releasing the slot.
    @trusted package(flint.reactor) Status setInterest(Readiness poller, Socket socket, ulong token,
            Interest previous, Interest desired) nothrow @nogc
    {
        kevent64_s[2] changes;
        int count;
        if ((previous & Interest.read) != (desired & Interest.read))
            changes[count++] = kevent64_s(cast(ulong) socket.descriptor, EVFILT_READ,
                    (desired & Interest.read) ? EV_ADD | EV_ENABLE : EV_DELETE, 0, 0, token);
        if ((previous & Interest.write) != (desired & Interest.write))
            changes[count++] = kevent64_s(cast(ulong) socket.descriptor, EVFILT_WRITE,
                    (desired & Interest.write) ? EV_ADD | EV_ENABLE : EV_DELETE, 0, 0, token);
        if (count != 0 && kevent64(poller.descriptor, changes.ptr, count, null, 0, 0, null) < 0)
            return socketError(errno);
        return Status.ok;
    }

    // SAFETY: kevent64 writes at most capacity entries into the local typed buffer and retains no pointer.
    @trusted package(flint.reactor) Result!size_t poll(Readiness port, scope ReadyEvent[] ready, uint ms) nothrow @nogc
    {
        if (ready.length == 0 || ms > int.max)
            return Result!size_t(0, Error(Status.invalidArgument, "invalid kqueue wait bounds"));
        kevent64_s[64] nativeEvents;
        const capacity = ready.length < nativeEvents.length ? ready.length : nativeEvents.length;
        const timeout = timespec(ms / 1_000, (ms % 1_000) * 1_000_000);
        const count = kevent64(port.descriptor, null, 0, nativeEvents.ptr, cast(int) capacity, 0, &timeout);
        if (count < 0)
            return errno == EINTR ? Result!size_t(0) : Result!size_t(0, Error(socketError(errno),
                    "kqueue wait failed"));
        foreach (i; 0 .. count)
        {
            const event = nativeEvents[i];
            // EOF (peer shutdown or a pending socket error) is readiness of its filter, as epoll's
            // HUP/RDHUP/ERR are; the caller's next receive or send observes it.
            const fault = (event.flags & (EV_EOF | EV_ERROR)) != 0;
            ready[i] = ReadyEvent(event.udata, directions(event.filter == EVFILT_READ,
                    event.filter == EVFILT_WRITE), fault);
        }
        return Result!size_t(cast(size_t) count);
    }

    // Error readiness is always delivered, as epoll's EPOLLRDHUP/ERR/HUP are. Without read interest
    // the read filter stays registered with an unreachable low-water mark, so it fires only on EOF
    // or a pending error, never for ordinary data.
    private enum long eofOnly = int.max;

    private kevent64_s readFilter(int fd, ulong token, NativeInterest desired) pure nothrow @nogc
    {
        const reading = (desired & NativeInterest.read) != 0;
        return kevent64_s(cast(ulong) fd, EVFILT_READ, EV_ADD | EV_ENABLE, reading ? 0 : NOTE_LOWAT,
                reading ? 0 : eofOnly, token);
    }

    // SAFETY: kevent64 synchronously copies the one local change and retains only its integer token.
    private Status applyChange(Readiness poller, kevent64_s change) @trusted nothrow @nogc
    {
        if (kevent64(poller.descriptor, &change, 1, null, 0, 0, null) == 0)
            return Status.ok;
        const failure = errno;
        // The kernel already dropped the filters of a closed descriptor.
        if ((change.flags & EV_DELETE) && (failure == EBADF || failure == ENOENT))
            return Status.ok;
        return socketError(failure);
    }

    package(flint.reactor) Status setNativeInterest(Readiness poller, int fd, ulong token,
            NativeInterest previous, NativeInterest desired) nothrow @nogc
    {
        if (previous == desired)
            return Status.ok;
        if (desired == NativeInterest.none)
        {
            const read = applyChange(poller, kevent64_s(cast(ulong) fd, EVFILT_READ, EV_DELETE));
            if (!(previous & NativeInterest.write))
                return read;
            const write = applyChange(poller, kevent64_s(cast(ulong) fd, EVFILT_WRITE, EV_DELETE));
            return read != Status.ok ? read : write;
        }
        // The read filter is always registered: for data with read interest, otherwise for EOF and errors.
        if (previous == NativeInterest.none || ((previous ^ desired) & NativeInterest.read))
        {
            const read = applyChange(poller, readFilter(fd, token, desired));
            if (read != Status.ok)
                return read;
        }
        if (!((previous ^ desired) & NativeInterest.write))
            return Status.ok;
        const writing = (desired & NativeInterest.write) != 0;
        return applyChange(poller, kevent64_s(cast(ulong) fd, EVFILT_WRITE, writing
                ? EV_ADD | EV_ENABLE : EV_DELETE, 0, 0, token));
    }
}

version (Posix)
{
    package(flint.reactor) Interest directions(bool readable, bool writable) pure nothrow @nogc
    {
        const read = readable ? Interest.read : Interest.none;
        const write = writable ? Interest.write : Interest.none;
        return cast(Interest)(read | write);
    }
}
