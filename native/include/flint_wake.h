#ifndef FLINT_WAKE_H
#define FLINT_WAKE_H

/* Darwin's replacement for the eventfd wake-ups the shims use (ADR-024). Linux keeps eventfd;
   nothing here is compiled there. */
#if defined(__APPLE__)

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

/* A pollable wake-up signal: a nonblocking, close-on-exec pipe in place of an eventfd counter. The
   read end is the descriptor callers poll; the write end stays private to the signalling side. A full
   pipe already holds a pending wake-up, so a signal that cannot be written loses nothing. */
static inline int flint_wake_open(int *reader, int *writer)
{
    int ends[2];
    if (pipe(ends) < 0)
        return -1;
    for (int index = 0; index < 2; ++index) {
        if (fcntl(ends[index], F_SETFD, FD_CLOEXEC) < 0 || fcntl(ends[index], F_SETFL, O_NONBLOCK) < 0) {
            const int saved = errno;
            close(ends[0]);
            close(ends[1]);
            errno = saved;
            return -1;
        }
    }
    *reader = ends[0];
    *writer = ends[1];
    return 0;
}

static inline void flint_wake_signal(int writer)
{
    const unsigned char signal = 1;
    while (write(writer, &signal, 1) < 0 && errno == EINTR) {
    }
}

/* Consume every pending signal, as one eventfd read resets the counter. */
static inline void flint_wake_drain(int reader)
{
    unsigned char signals[64];
    for (;;) {
        const ssize_t count = read(reader, signals, sizeof(signals));
        if (count > 0 || (count < 0 && errno == EINTR))
            continue;
        return;
    }
}

static inline void flint_wake_close(int reader, int writer)
{
    if (reader >= 0)
        close(reader);
    if (writer >= 0 && writer != reader)
        close(writer);
}

#endif
#endif
