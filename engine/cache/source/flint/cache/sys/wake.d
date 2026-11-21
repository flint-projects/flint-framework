module flint.cache.sys.wake;

import core.sys.linux.sys.eventfd : EFD_CLOEXEC, EFD_NONBLOCK, eventfd, eventfd_read, eventfd_write;
import core.sys.posix.poll : POLLIN, poll, pollfd;
import core.sys.posix.unistd : close;
import flint.arena : Error, Status;

@safe:

package(flint.cache) struct Wake
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
