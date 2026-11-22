#ifndef FLINT_SOCKET_H
#define FLINT_SOCKET_H

/* Darwin's replacement for SOCK_NONBLOCK | SOCK_CLOEXEC and MSG_NOSIGNAL (ADR-024). Linux keeps its
   socket flags; nothing here is compiled there. */
#if defined(__APPLE__)

#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>

/* A nonblocking, close-on-exec stream socket that reports EPIPE instead of raising SIGPIPE: Darwin has
   neither SOCK_NONBLOCK | SOCK_CLOEXEC nor MSG_NOSIGNAL. */
static inline int flint_stream_socket(int family)
{
    const int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    const int enabled = 1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0
            || setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0) {
        const int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

#endif
#endif
