#ifndef FLINT_WAKE_H
#define FLINT_WAKE_H

/* Darwin's replacement for the eventfd wake-ups the shims use (ADR-024), and Windows' (ADR-026). Linux keeps eventfd;
   nothing here is compiled there. */
#if defined(_WIN32)

#include "flint_port.h"

/* A connected loopback TCP pair in place of an eventfd (ADR-026): the read end is a nonblocking SOCKET the reactor
   watches with WSAPoll, the write end stays private to the signalling side. A full buffer already holds a pending
   wake-up, so a signal that cannot be sent loses nothing. The SOCKET values travel as int descriptors. */
static inline void flint_wake_start_winsock(void)
{
    WSADATA data;
    (void) WSAStartup(MAKEWORD(2, 2), &data); /* Process-lifetime reference; a failure surfaces as socket()'s. */
}

static inline int flint_wake_open(int *reader, int *writer)
{
    static pthread_once_t winsock = PTHREAD_ONCE_INIT;
    pthread_once(&winsock, flint_wake_start_winsock);
    *reader = *writer = -1;
    const SOCKET listener = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, WSA_FLAG_NO_HANDLE_INHERIT);
    if (listener == INVALID_SOCKET)
        return -1;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int length = (int) sizeof(address);
    SOCKET sender = INVALID_SOCKET, receiver = INVALID_SOCKET;
    if (bind(listener, (struct sockaddr *) &address, length) == 0 && listen(listener, 1) == 0
        && getsockname(listener, (struct sockaddr *) &address, &length) == 0) {
        sender = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, WSA_FLAG_NO_HANDLE_INHERIT);
        if (sender != INVALID_SOCKET && connect(sender, (struct sockaddr *) &address, length) == 0)
            receiver = accept(listener, NULL, NULL);
    }
    closesocket(listener);
    u_long nonblocking = 1;
    const int enabled = 1;
    if (receiver == INVALID_SOCKET || ioctlsocket(receiver, FIONBIO, &nonblocking) != 0
        || ioctlsocket(sender, FIONBIO, &nonblocking) != 0
        || setsockopt(sender, IPPROTO_TCP, TCP_NODELAY, (const char *) &enabled, sizeof(enabled)) != 0) {
        if (sender != INVALID_SOCKET)
            closesocket(sender);
        if (receiver != INVALID_SOCKET)
            closesocket(receiver);
        return -1;
    }
    *reader = (int) receiver;
    *writer = (int) sender;
    return 0;
}

static inline void flint_wake_signal(int writer)
{
    const char wake = 1;
    if (writer >= 0)
        (void) send((SOCKET) writer, &wake, 1, 0);
}

/* Consume every pending signal, as one eventfd read resets the counter. */
static inline void flint_wake_drain(int reader)
{
    char signals[64];
    while (reader >= 0 && recv((SOCKET) reader, signals, (int) sizeof(signals), 0) > 0) {
    }
}

static inline void flint_wake_close(int reader, int writer)
{
    if (reader >= 0)
        closesocket((SOCKET) reader);
    if (writer >= 0 && writer != reader)
        closesocket((SOCKET) writer);
}

#elif defined(__APPLE__)

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
