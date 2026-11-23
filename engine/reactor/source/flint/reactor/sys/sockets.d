module flint.reactor.sys.sockets;

import flint.arena : Error, Result, Status;

@safe:

version (Posix)
{
    import core.stdc.errno : EACCES, EADDRINUSE, EAGAIN, ECONNABORTED, EINTR, EMFILE, ENFILE,
        ENOBUFS, ENOMEM, EPERM, EPROTO, errno;
    import core.sys.posix.arpa.inet : ntohs;
    import core.sys.posix.fcntl : FD_CLOEXEC, F_GETFL, F_SETFL, F_SETFD, O_NONBLOCK, fcntl;
    import core.sys.posix.netdb : addrinfo, freeaddrinfo, getaddrinfo;
    import core.sys.posix.netinet.in_ : sockaddr_in, sockaddr_in6;
    import core.sys.posix.sys.socket : AF_INET, AF_INET6, AF_UNSPEC, SO_REUSEADDR, SOCK_STREAM,
        SOL_SOCKET, accept, bind, getsockname, listen, recv, send, setsockopt, sockaddr,
        sockaddr_storage, socklen_t, socket;
    import core.sys.posix.unistd : close;

    version (linux)
    {
        import core.sys.posix.fcntl : O_CLOEXEC;
        import core.sys.posix.sys.socket : MSG_NOSIGNAL;

        private extern (C) int accept4(int fd, sockaddr* address, socklen_t* length, int flags) @system nothrow @nogc;

        // Linux assigns these socket creation flags the same values as the file flags.
        private enum socketFlags = O_NONBLOCK | O_CLOEXEC;
        private enum sendFlags = MSG_NOSIGNAL;
    }
    else
    {
        import core.sys.posix.sys.socket : SO_NOSIGPIPE;

        private enum socketFlags = 0;
        private enum sendFlags = 0;
    }

    package(flint.reactor) struct Socket
    {
        int descriptor = -1;

        bool valid() const pure nothrow @nogc
        {
            return descriptor >= 0;
        }
    }

    package(flint.reactor) Status socketError(int code) pure nothrow @nogc
    {
        if (code == EAGAIN || code == EINTR)
            return Status.unavailable;
        if (code == EACCES)
            return Status.permissionDenied;
        if (code == EADDRINUSE)
            return Status.conflict;
        if (code == EMFILE || code == ENFILE)
            return Status.resourceExhausted;
        return Status.ioError;
    }

    /// Classify a failed accept. Aborted handshakes and filtered peers affect only that connection and
    /// report unavailable; descriptor or buffer exhaustion reports resourceExhausted so the owner can back
    /// off and retry while the connection waits in the backlog. Other codes indicate a broken listener.
    package(flint.reactor) Status acceptError(int code) pure nothrow @nogc
    {
        if (code == EAGAIN || code == EINTR || code == ECONNABORTED || code == EPROTO || code == EPERM)
            return Status.unavailable;
        if (code == EMFILE || code == ENFILE || code == ENOBUFS || code == ENOMEM)
            return Status.resourceExhausted;
        return Status.ioError;
    }

    /// Send small writes immediately. Responses written in several parts (HTTP/2 frames, gRPC, WebSocket)
    /// otherwise wait for the peer's delayed acknowledgement under Nagle's algorithm. Go sets the same option.
    // SAFETY: setsockopt copies one local integer for the caller's live descriptor and retains no pointer.
    package(flint.reactor) Status sendImmediately(Socket socket) @trusted nothrow @nogc
    {
        import core.sys.posix.netinet.in_ : IPPROTO_TCP;
        import core.sys.posix.netinet.tcp : TCP_NODELAY;

        const int enabled = 1;
        if (setsockopt(socket.descriptor, IPPROTO_TCP, TCP_NODELAY, &enabled, enabled.sizeof) != 0)
            return socketError(errno);
        return Status.ok;
    }

    /// Whether sendImmediately is in effect for the descriptor.
    // SAFETY: getsockopt writes at most one local integer and its local length for the live descriptor.
    package(flint.reactor) bool sendsImmediately(Socket socket) @trusted nothrow @nogc
    {
        import core.sys.posix.netinet.in_ : IPPROTO_TCP;
        import core.sys.posix.netinet.tcp : TCP_NODELAY;
        import core.sys.posix.sys.socket : getsockopt;

        int enabled;
        socklen_t length = enabled.sizeof;
        return getsockopt(socket.descriptor, IPPROTO_TCP, TCP_NODELAY, &enabled, &length) == 0 && enabled != 0;
    }

    // SAFETY: The owner passes its live descriptor exactly once and invalidates it before releasing ownership.
    package(flint.reactor) void closeSocket(ref Socket socket) @trusted nothrow @nogc
    {
        if (socket.valid)
        {
            const descriptor = socket.descriptor;
            socket.descriptor = -1;
            close(descriptor);
        }
    }

    version (linux)
    {
        // SAFETY: accept4 returns a newly owned descriptor and writes no address because both outputs are null.
        package(flint.reactor) Result!Socket acceptConnection(Socket listener) @trusted nothrow @nogc
        {
            const descriptor = accept4(listener.descriptor, null, null, socketFlags);
            if (descriptor < 0)
                return Result!Socket(Socket.init, Error(acceptError(errno), "accept failed"));
            return Result!Socket(Socket(descriptor));
        }
    }
    else
    {
        // SAFETY: The descriptor is new and both calls copy the values before returning.
        private bool prepare(int descriptor) @trusted nothrow @nogc
        {
            const flags = fcntl(descriptor, F_GETFL);
            const int enabled = 1;
            return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 && fcntl(descriptor,
                    F_SETFD, FD_CLOEXEC) == 0 && setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE,
                    &enabled, enabled.sizeof) == 0;
        }

        // SAFETY: accept returns a new owned descriptor without writing address data. Failure closes it locally.
        package(flint.reactor) Result!Socket acceptConnection(Socket listener) @trusted nothrow @nogc
        {
            const descriptor = accept(listener.descriptor, null, null);
            if (descriptor < 0)
                return Result!Socket(Socket.init, Error(acceptError(errno), "accept failed"));
            if (!prepare(descriptor))
            {
                close(descriptor);
                return Result!Socket(Socket.init, Error(Status.ioError, "accepted socket setup failed"));
            }
            return Result!Socket(Socket(descriptor));
        }
    }

    private bool copyNode(string host, ref char[254] node) pure nothrow @nogc
    {
        if (host.length == 0 || host.length >= node.length)
            return false;
        foreach (i, ch; host)
        {
            if (ch == '\0')
                return false;
            node[i] = ch;
        }
        node[host.length] = '\0';
        return true;
    }

    private size_t encodePort(ushort port, ref char[6] service) pure nothrow @nogc
    {
        size_t digit = 5;
        service[digit] = '\0';
        uint number = port;
        do
        {
            service[--digit] = cast(char)('0' + number % 10);
            number /= 10;
        }
        while (number != 0);
        return digit;
    }

    /// Bind and listen, retrying for up to a second while the address is in use. A listener that a just-exited
    /// process still owns through its io_uring teardown, which the kernel finishes after the process is reaped,
    /// holds the port briefly; a restarted service (`flint watch`, a supervisor) must not fail on it.
    package(flint.reactor) Result!Socket bindListener(string host, ushort port, uint backlog) nothrow @nogc
    {
        import core.thread.osthread : Thread;
        import core.time : msecs;

        enum attempts = 40;
        foreach (attempt; 0 .. attempts)
        {
            auto bound = bindOnce(host, port, backlog);
            if (bound.ok() || bound.error.code != Status.conflict || port == 0 || attempt + 1 == attempts)
                return bound;
            Thread.sleep(25.msecs);
        }
        assert(0);
    }

    // SAFETY: Host and service are NUL-terminated owned locals. Resolver output is freed after bind copies it.
    // Each newly owned socket is closed on every failure path. Only a listening descriptor escapes.
    private Result!Socket bindOnce(string host, ushort port, uint backlog) @trusted nothrow @nogc
    {
        char[254] node;
        if (!copyNode(host, node) || backlog == 0 || backlog > int.max)
            return Result!Socket(Socket.init, Error(Status.invalidArgument, "invalid listener options"));

        char[6] service;
        const digit = encodePort(port, service);
        addrinfo hints;
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        addrinfo* addresses;
        if (getaddrinfo(node.ptr, &service[digit], &hints, &addresses) != 0)
            return Result!Socket(Socket.init, Error(Status.invalidArgument, "could not resolve listener host"));
        scope (exit)
            freeaddrinfo(addresses);

        Status failure = Status.ioError;
        for (auto address = addresses; address !is null; address = address.ai_next)
        {
            const descriptor = socket(address.ai_family, address.ai_socktype | socketFlags, address.ai_protocol);
            if (descriptor < 0)
            {
                failure = socketError(errno);
                continue;
            }
            version (linux)
                enum prepared = true;
            else
                const prepared = prepare(descriptor);
            const int enabled = 1;
            if (prepared && setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled,
                    enabled.sizeof) == 0 && bind(descriptor, address.ai_addr,
                    address.ai_addrlen) == 0 && listen(descriptor, cast(int) backlog) == 0)
                return Result!Socket(Socket(descriptor));
            failure = socketError(errno);
            close(descriptor);
        }
        return Result!Socket(Socket.init, Error(failure, "could not bind listener"));
    }

    // SAFETY: getsockname can write only into the aligned local sockaddr_storage and its local length.
    // The reported family and size are tested before reading either concrete address layout.
    package(flint.reactor) Result!ushort socketPort(Socket socket) @trusted nothrow @nogc
    {
        sockaddr_storage address;
        socklen_t length = address.sizeof;
        if (getsockname(socket.descriptor, cast(sockaddr*)&address, &length) != 0)
            return Result!ushort(0, Error(socketError(errno), "getsockname failed"));
        if (address.ss_family == AF_INET && length >= sockaddr_in.sizeof)
            return Result!ushort(ntohs((cast(sockaddr_in*)&address).sin_port));
        if (address.ss_family == AF_INET6 && length >= sockaddr_in6.sizeof)
            return Result!ushort(ntohs((cast(sockaddr_in6*)&address).sin6_port));
        return Result!ushort(0, Error(Status.unsupported, "listener address family unsupported"));
    }

    // SAFETY: A synchronous nonblocking receive writes at most output.length bytes, with no retained pointer.
    package(flint.reactor) Result!size_t receive(Socket socket, scope ubyte[] output) @trusted nothrow @nogc
    {
        const bytes = recv(socket.descriptor, output.ptr, output.length, 0);
        if (bytes < 0)
            return Result!size_t(0, Error(socketError(errno), "receive failed"));
        return Result!size_t(cast(size_t) bytes);
    }

    // SAFETY: A synchronous nonblocking send reads at most input.length bytes, with no retained pointer.
    package(flint.reactor) Result!size_t transmit(Socket socket, scope const(ubyte)[] input) @trusted nothrow @nogc
    {
        const bytes = send(socket.descriptor, input.ptr, input.length, sendFlags);
        if (bytes < 0)
            return Result!size_t(0, Error(socketError(errno), "send failed"));
        return Result!size_t(cast(size_t) bytes);
    }
}
