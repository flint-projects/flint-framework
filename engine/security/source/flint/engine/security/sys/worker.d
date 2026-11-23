/// Linux, macOS and Windows wake-ups and druntime ownership for the private JWKS worker.
module flint.engine.security.sys.worker;

import flint.arena : Error, Status;

@safe:

version (Windows)
{
    import core.sys.windows.winbase : CloseHandle, CreateEventW, INFINITE, SetEvent, WaitForSingleObject;
    import core.sys.windows.windef : FALSE, HANDLE;

    // An auto-reset event: signals before a wait collapse into one wake-up, as an eventfd drain does (ADR-026).
    package(flint.engine.security) struct Wake
    {
        private HANDLE event;

        // SAFETY: CreateEventW creates a new owned, unnamed, non-inheritable event and receives no borrowed memory.
        Error open() @trusted nothrow @nogc
        {
            event = CreateEventW(null, FALSE, FALSE, null);
            return event !is null ? Error.init : Error(Status.ioError, "unable to start the JWKS wake event");
        }

        // SAFETY: The caller serializes signaling and release, so the handle is live.
        void signal() @trusted nothrow @nogc
        {
            if (event !is null)
                SetEvent(event);
        }

        // SAFETY: Only the owner waits. Release runs after its final wait.
        void listen() @trusted nothrow @nogc
        {
            WaitForSingleObject(event, INFINITE);
        }

        // SAFETY: The owner has stopped waiting and signaling is serialized with handle retirement.
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
    import core.stdc.errno : EINTR, errno;
    import core.sys.posix.poll : POLLIN, poll, pollfd;
    import core.sys.posix.unistd : close;
    import core.sys.posix.fcntl : FD_CLOEXEC, F_SETFD, F_SETFL, O_NONBLOCK, fcntl;
    import core.sys.posix.unistd : pipe, read, write;

    // Darwin has no eventfd: a nonblocking pipe pair, read end polled, write end signalled (ADR-024).
    package(flint.engine.security) struct Wake
    {
        private int descriptor = -1;
        private int writer = -1;

        // SAFETY: pipe initializes both local slots, and both are closed if either cannot be configured.
        Error open() @trusted nothrow @nogc
        {
            int[2] ends;
            if (pipe(ends) != 0)
                return Error(Status.ioError, "unable to start the JWKS wake descriptor");
            foreach (end; ends)
            {
                if (fcntl(end, F_SETFD, FD_CLOEXEC) != 0 || fcntl(end, F_SETFL, O_NONBLOCK) != 0)
                {
                    close(ends[0]);
                    close(ends[1]);
                    return Error(Status.ioError, "unable to start the JWKS wake descriptor");
                }
            }
            descriptor = ends[0];
            writer = ends[1];
            return Error.init;
        }

        // SAFETY: The caller serializes signaling and release. A full pipe already holds a pending wake-up.
        void signal() @trusted nothrow @nogc
        {
            if (writer < 0)
                return;
            const ubyte one = 1;
            while (write(writer, &one, 1) < 0 && errno == EINTR)
            {
            }
        }

        // SAFETY: Only the owner waits, with stack-local poll and read storage. Release runs after its final wait.
        void listen() @trusted nothrow @nogc
        {
            pollfd watched = pollfd(descriptor, POLLIN, 0);
            if (poll(&watched, 1, -1) > 0)
            {
                ubyte[64] signals;
                while (read(descriptor, signals.ptr, signals.length) > 0)
                {
                }
            }
        }

        // SAFETY: The owner has stopped waiting and signaling is serialized with descriptor retirement.
        void release() @trusted nothrow @nogc
        {
            if (descriptor >= 0)
            {
                close(descriptor);
                close(writer);
                descriptor = writer = -1;
            }
        }
    }
}
else
{
    import core.stdc.errno : EINTR, errno;
    import core.sys.linux.sys.eventfd : EFD_CLOEXEC, EFD_NONBLOCK, eventfd, eventfd_read, eventfd_write;
    import core.sys.posix.poll : POLLIN, poll, pollfd;
    import core.sys.posix.unistd : close;

    package(flint.engine.security) struct Wake
    {
        private int descriptor = -1;

        // SAFETY: eventfd creates a new owned descriptor and receives no borrowed memory.
        Error open() @trusted nothrow @nogc
        {
            descriptor = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
            return descriptor >= 0 ? Error.init : Error(Status.ioError, "unable to start the JWKS wake descriptor");
        }

        // SAFETY: The caller serializes signaling and release. The nonblocking write holds no D references.
        void signal() @trusted nothrow @nogc
        {
            if (descriptor < 0)
                return;
            while (eventfd_write(descriptor, 1) != 0 && errno == EINTR)
            {
            }
        }

        // SAFETY: Only the owner waits, with stack-local poll storage. Release runs after its final wait.
        void listen() @trusted nothrow @nogc
        {
            pollfd watched = pollfd(descriptor, POLLIN, 0);
            if (poll(&watched, 1, -1) > 0)
            {
                ulong signals;
                eventfd_read(descriptor, &signals);
            }
        }

        // SAFETY: The owner has stopped waiting and signaling is serialized with descriptor retirement.
        void release() @trusted nothrow @nogc
        {
            if (descriptor >= 0)
            {
                close(descriptor);
                descriptor = -1;
            }
        }
    }
}
