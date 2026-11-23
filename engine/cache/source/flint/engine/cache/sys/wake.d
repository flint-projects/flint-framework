module flint.engine.cache.sys.wake;

import flint.arena : Error, Status;

@safe:

version (Windows)
{
    import core.sys.windows.winbase : CloseHandle, CreateEventW, INFINITE, SetEvent, WaitForSingleObject;
    import core.sys.windows.windef : FALSE, HANDLE;

    // An auto-reset event: notifications before a wait collapse into one wake-up, as an eventfd drain does
    // (ADR-026).
    package(flint.engine.cache) struct Wake
    {
        private HANDLE event;

        // SAFETY: CreateEventW creates a new owned, unnamed, non-inheritable event and retains no caller memory.
        Error open() @trusted nothrow @nogc
        {
            event = CreateEventW(null, FALSE, FALSE, null);
            return event !is null ? Error.init : Error(Status.ioError, "could not open cache wake event");
        }

        // SAFETY: The caller holds the monitor lock through the signal and the handle lifetime.
        void notify() @trusted nothrow @nogc
        {
            if (event !is null)
                SetEvent(event);
        }

        // SAFETY: Only the owner thread waits or closes. A negative timeout waits without limit, as poll does.
        void wait(int millis) @trusted nothrow @nogc
        {
            WaitForSingleObject(event, millis < 0 ? INFINITE : cast(uint) millis);
        }

        // SAFETY: The monitor has stopped waiting and producers hold the same lock when notifying.
        void release() @trusted nothrow @nogc
        {
            if (event !is null)
            {
                CloseHandle(event);
                event = null;
            }
        }
    }
}
else version (OSX)
{
    import core.sys.posix.poll : POLLIN, poll, pollfd;
    import core.sys.posix.unistd : close;
    import core.sys.posix.fcntl : FD_CLOEXEC, F_SETFD, F_SETFL, O_NONBLOCK, fcntl;
    import core.sys.posix.unistd : pipe, read, write;

    // Darwin has no eventfd: a nonblocking pipe pair, read end polled, write end signalled (ADR-024).
    package(flint.engine.cache) struct Wake
    {
        private int fd = -1;
        private int writer = -1;

        // SAFETY: pipe initializes both local slots, and both are closed if either cannot be configured.
        Error open() @trusted nothrow @nogc
        {
            int[2] ends;
            if (pipe(ends) != 0)
                return Error(Status.ioError, "could not open cache wake descriptor");
            foreach (end; ends)
            {
                if (fcntl(end, F_SETFD, FD_CLOEXEC) != 0 || fcntl(end, F_SETFL, O_NONBLOCK) != 0)
                {
                    close(ends[0]);
                    close(ends[1]);
                    return Error(Status.ioError, "could not open cache wake descriptor");
                }
            }
            fd = ends[0];
            writer = ends[1];
            return Error.init;
        }

        // SAFETY: The caller holds the monitor lock through the nonblocking write and descriptor lifetime.
        // A full pipe already holds a pending wake-up.
        void notify() @trusted nothrow @nogc
        {
            const ubyte signal = 1;
            if (writer >= 0)
                cast(void) write(writer, &signal, 1);
        }

        // SAFETY: Only the owner thread waits or closes. Poll and read borrow local storage.
        void wait(int millis) @trusted nothrow @nogc
        {
            pollfd watched = pollfd(fd, POLLIN, 0);
            if (poll(&watched, 1, millis) > 0)
            {
                ubyte[64] signals;
                while (read(fd, signals.ptr, signals.length) > 0)
                {
                }
            }
        }

        // SAFETY: The monitor has stopped waiting and producers hold the same lock when notifying.
        void release() @trusted nothrow @nogc
        {
            if (fd >= 0)
            {
                close(fd);
                close(writer);
                fd = writer = -1;
            }
        }
    }
}
else
{
    import core.sys.linux.sys.eventfd : EFD_CLOEXEC, EFD_NONBLOCK, eventfd, eventfd_read, eventfd_write;
    import core.sys.posix.poll : POLLIN, poll, pollfd;
    import core.sys.posix.unistd : close;

    package(flint.engine.cache) struct Wake
    {
        private int fd = -1;

        // SAFETY: eventfd returns one owned descriptor and retains no caller memory.
        Error open() @trusted nothrow @nogc
        {
            fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
            return fd >= 0 ? Error.init : Error(Status.ioError, "could not open cache wake descriptor");
        }

        // SAFETY: The caller holds the monitor lock through the nonblocking write and descriptor lifetime.
        void notify() @trusted nothrow @nogc
        {
            if (fd >= 0)
                eventfd_write(fd, 1);
        }

        // SAFETY: Only the owner thread waits or closes. Poll and eventfd_read borrow local storage.
        void wait(int millis) @trusted nothrow @nogc
        {
            pollfd watched = pollfd(fd, POLLIN, 0);
            if (poll(&watched, 1, millis) > 0)
            {
                ulong signals;
                eventfd_read(fd, &signals);
            }
        }

        // SAFETY: The monitor has stopped waiting and producers hold the same lock when notifying.
        void release() @trusted nothrow @nogc
        {
            if (fd >= 0)
            {
                close(fd);
                fd = -1;
            }
        }
    }
}
