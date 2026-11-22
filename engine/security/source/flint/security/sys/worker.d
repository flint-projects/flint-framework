/// Linux descriptors and druntime ownership for the private JWKS worker.
module flint.security.sys.worker;

import core.stdc.errno : EINTR, errno;
import core.sys.linux.sys.eventfd : EFD_CLOEXEC, EFD_NONBLOCK, eventfd, eventfd_read, eventfd_write;
import core.sys.posix.poll : POLLIN, poll, pollfd;
import core.sys.posix.unistd : close;
import flint.arena : Error, Status;

@safe:

package(flint.security) struct Wake
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
