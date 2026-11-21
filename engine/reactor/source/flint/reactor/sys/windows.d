module flint.reactor.sys.windows;

import flint.arena : Error, Result, Status;

@safe:

version (Windows)
{
    import core.stdc.stdlib : calloc, free;
    import core.sys.windows.basetsd : ULONG_PTR;
    import core.sys.windows.basetyps : GUID;
    import core.sys.windows.mswsock : WSAID_ACCEPTEX;
    import core.sys.windows.winbase : CancelIoEx, CloseHandle, CreateIoCompletionPort, GetLastError,
        GetQueuedCompletionStatus, INVALID_HANDLE_VALUE, OVERLAPPED;
    import core.sys.windows.windef : BOOL, DWORD, HANDLE;
    import core.sys.windows.winerror : ERROR_ACCESS_DENIED, ERROR_NOT_ENOUGH_MEMORY,
        ERROR_NOT_FOUND, ERROR_OPERATION_ABORTED, WAIT_TIMEOUT;
    import core.sys.windows.winsock2 : AF_INET, AF_INET6, AF_UNSPEC, INVALID_SOCKET, SOCKET, SOCK_STREAM,
        SOL_SOCKET, SO_EXCLUSIVEADDRUSE, WSACleanup, WSADATA, WSAEACCES, WSAEADDRINUSE, WSAEMFILE,
        WSAENOBUFS, WSAEWOULDBLOCK,
        WSAGetLastError, WSAIoctl, WSAStartup, addrinfo, bind, closesocket, freeaddrinfo, getaddrinfo,
        getsockname, listen, ntohs, setsockopt, sockaddr, sockaddr_in, sockaddr_in6, sockaddr_storage;

    private enum uint socketFlags = 0x01 | 0x80; // WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT
    private enum uint getExtensionFunction = 0xC8000006; // SIO_GET_EXTENSION_FUNCTION_POINTER
    private enum updateAcceptContext = 0x700B; // SO_UPDATE_ACCEPT_CONTEXT
    private enum wsaIoPending = 997; // WSA_IO_PENDING
    private enum uint acceptAddressBytes = sockaddr_storage.sizeof + 16;
    private enum ulong acceptToken = 1;

    private struct WsaBuffer
    {
        uint length;
        char* bytes;
    }

    private extern (Windows) alias AcceptSocket = BOOL function(SOCKET, SOCKET, void*, DWORD,
            DWORD, DWORD, DWORD*, OVERLAPPED*) @system nothrow @nogc;

    private extern (Windows) @system nothrow @nogc
    {
        SOCKET WSASocketW(int family, int type, int protocol, void* protocolInfo, uint group, uint flags);
        int WSARecv(SOCKET socket, WsaBuffer* buffers, DWORD count, DWORD* transferred, DWORD* flags,
                OVERLAPPED* overlapped, void* routine);
        int WSASend(SOCKET socket, WsaBuffer* buffers, DWORD count, DWORD* transferred, DWORD flags,
                OVERLAPPED* overlapped, void* routine);
    }

    package(flint.reactor) struct Socket
    {
        private SOCKET descriptor = INVALID_SOCKET;
        private HANDLE port;
        private int family;
        private bool ownsWinsock;

        bool valid() const pure nothrow @nogc
        {
            return descriptor != INVALID_SOCKET;
        }
    }

    private struct PendingIo
    {
        OVERLAPPED overlapped;
        ulong token;
        SOCKET socket;
        Socket accepted;
        WsaBuffer buffer;
        DWORD transferred;
        DWORD flags;
        ubyte[2 * acceptAddressBytes] addresses;
    }

    static assert(PendingIo.overlapped.offsetof == 0);

    package(flint.reactor) struct CompletionPort
    {
        private HANDLE handle;
        private PendingIo[] slots;
        private size_t active;
        private AcceptSocket acceptSocket;

        bool valid() const pure nothrow @nogc
        {
            return handle !is null;
        }
    }

    package(flint.reactor) struct KernelEvent
    {
        bool received;
        ulong token;
        Status status;
        size_t bytes;
        Socket accepted;
    }

    private Status windowsError(uint code) pure nothrow @nogc
    {
        switch (code)
        {
        case ERROR_OPERATION_ABORTED:
            return Status.cancelled;
        case ERROR_NOT_FOUND:
            return Status.notFound;
        case ERROR_ACCESS_DENIED:
        case WSAEACCES:
            return Status.permissionDenied;
        case WSAEADDRINUSE:
            return Status.conflict;
        case ERROR_NOT_ENOUGH_MEMORY:
        case WSAEMFILE:
            return Status.resourceExhausted;
        case WSAENOBUFS:
        case WSAEWOULDBLOCK:
            return Status.unavailable;
        default:
            return Status.ioError;
        }
    }

    // SAFETY: WSAStartup writes only to the local WSADATA, and each successful call has one cleanup owner.
    private Status startWinsock() @trusted nothrow @nogc
    {
        WSADATA data;
        const result = WSAStartup(0x0202, &data);
        if (result != 0)
            return windowsError(result);
        if (data.wVersion != 0x0202)
        {
            WSACleanup();
            return Status.unsupported;
        }
        return Status.ok;
    }

    package(flint.reactor) void closeSocket(ref Socket socket) nothrow @nogc
    {
        if (!socket.valid)
            return;
        auto owned = socket;
        socket = Socket.init;
        closesocket(owned.descriptor);
        if (owned.ownsWinsock)
            WSACleanup();
    }

    package(flint.reactor) Result!Socket bindListener(string host, ushort port, uint backlog) nothrow @nogc
    {
        char[254] node = 0;
        if (host.length == 0 || host.length >= node.length || backlog == 0 || backlog > int.max)
            return Result!Socket(Socket.init, Error(Status.invalidArgument, "invalid listener options"));
        foreach (index, ch; host)
        {
            if (ch == '\0')
                return Result!Socket(Socket.init, Error(Status.invalidArgument, "NUL in listener host"));
            node[index] = ch;
        }

        char[6] service = 0;
        size_t digit = service.length;
        --digit; // Reserve the terminating NUL.
        uint number = port;
        do
        {
            service[--digit] = cast(char)('0' + number % 10);
            number /= 10;
        }
        while (number != 0);

        const startup = startWinsock();
        if (startup != Status.ok)
            return Result!Socket(Socket.init, Error(startup, "Winsock startup failed"));
        auto result = bindResolved(node, service[digit .. $], backlog);
        if (result.ok)
            result.value.ownsWinsock = true;
        else
            WSACleanup();
        return result;
    }

    // The resolver owns each entry until freeaddrinfo. Unsuccessful sockets close before advancing.
    // SAFETY: The strings are NUL-terminated locals and bind copies only the selected address synchronously.
    @trusted nothrow @nogc private Result!Socket bindResolved(scope const(char)[] host,
            scope const(char)[] service, uint backlog)
    {
        addrinfo hints;
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        addrinfo* addresses;
        if (getaddrinfo(host.ptr, service.ptr, &hints, &addresses) != 0)
            return Result!Socket(Socket.init, Error(Status.invalidArgument, "could not resolve listener host"));
        scope (exit)
            freeaddrinfo(addresses);

        Status failure = Status.ioError;
        for (auto address = addresses; address !is null; address = address.ai_next)
        {
            if (address.ai_family != AF_INET && address.ai_family != AF_INET6)
                continue;
            const descriptor = WSASocketW(address.ai_family, SOCK_STREAM, address.ai_protocol, null, 0, socketFlags);
            if (descriptor == INVALID_SOCKET)
            {
                failure = windowsError(WSAGetLastError());
                continue;
            }
            const int enabled = 1;
            if (address.ai_addrlen <= int.max && setsockopt(descriptor, SOL_SOCKET,
                    SO_EXCLUSIVEADDRUSE, &enabled, enabled.sizeof) == 0 && bind(descriptor, address.ai_addr,
                    cast(int) address.ai_addrlen) == 0 && listen(descriptor, cast(int) backlog) == 0)
                return Result!Socket(Socket(descriptor, null, address.ai_family));
            failure = windowsError(WSAGetLastError());
            closesocket(descriptor);
        }
        return Result!Socket(Socket.init, Error(failure, "could not bind listener"));
    }

    // SAFETY: The scratch sockaddr is aligned for both supported families. getsockname writes at most
    // the provided length, and the family and returned length are checked before reading the port.
    package(flint.reactor) Result!ushort socketPort(Socket socket) @trusted nothrow @nogc
    {
        if (!socket.valid)
            return Result!ushort(0, Error(Status.invalidArgument, "invalid listener"));
        sockaddr_storage address;
        int length = sockaddr_storage.sizeof;
        if (getsockname(socket.descriptor, cast(sockaddr*)&address, &length) != 0)
            return Result!ushort(0, Error(windowsError(WSAGetLastError()), "socket address unavailable"));
        if (address.ss_family == AF_INET && length >= sockaddr_in.sizeof)
            return Result!ushort(ntohs((cast(sockaddr_in*)&address).sin_port));
        if (address.ss_family == AF_INET6 && length >= sockaddr_in6.sizeof)
            return Result!ushort(ntohs((cast(sockaddr_in6*)&address).sin6_port));
        return Result!ushort(0, Error(Status.unsupported, "unsupported listener family"));
    }

    // SAFETY: This loop owns the freshly created completion port and bounded non-GC slot allocation. A slot's
    // addresses do not change between preparation and dequeue of its original completion packet.
    package(flint.reactor) Result!CompletionPort openCompletionPort(uint entries) @trusted nothrow @nogc
    {
        if (entries == 0 || entries >= size_t.max / PendingIo.sizeof)
            return Result!CompletionPort(CompletionPort.init, Error(Status.invalidArgument, "invalid IOCP size"));
        const startup = startWinsock();
        if (startup != Status.ok)
            return Result!CompletionPort(CompletionPort.init, Error(startup, "Winsock startup failed"));
        HANDLE handle = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 1);
        if (handle is null)
        {
            const failure = windowsError(GetLastError());
            WSACleanup();
            return Result!CompletionPort(CompletionPort.init, Error(failure, "could not create completion port"));
        }
        // The extra slot is reserved for the listener, independent of application I/O capacity.
        const size_t count = cast(size_t) entries + 1;
        auto slots = cast(PendingIo*) calloc(count, PendingIo.sizeof);
        if (slots is null)
        {
            CloseHandle(handle);
            WSACleanup();
            return Result!CompletionPort(CompletionPort.init, Error(Status.outOfMemory,
                    "could not allocate IOCP slots"));
        }
        return Result!CompletionPort(CompletionPort(handle, slots[0 .. count]));
    }

    // SAFETY: The owner releases these memory and Win32 resources only after all original completion
    // packets have been dequeued. A live port with in-flight operations retains all of its storage.
    package(flint.reactor) void closeCompletionPort(ref CompletionPort port) @trusted nothrow @nogc
    {
        if (!port.valid || port.active != 0)
            return;
        auto owned = port;
        port = CompletionPort.init;
        CloseHandle(owned.handle);
        free(owned.slots.ptr);
        WSACleanup();
    }

    // SAFETY: A socket is attached by its owner once before any submissions. The OS retains only the
    // handles and integer completion key. The socket cannot change to another loop after attachment.
    private Status associate(ref CompletionPort port, ref Socket socket) @trusted nothrow @nogc
    {
        if (!port.valid || !socket.valid)
            return Status.invalidArgument;
        if (socket.port is port.handle)
            return Status.ok;
        if (socket.port !is null)
            return Status.conflict;
        if (CreateIoCompletionPort(cast(HANDLE) socket.descriptor, port.handle, 0, 0) is null)
            return windowsError(GetLastError());
        socket.port = port.handle;
        return Status.ok;
    }

    private size_t slotFor(ref const CompletionPort port, ulong token) pure nothrow @nogc
    {
        if (!port.valid)
            return size_t.max;
        size_t listenerIndex = port.slots.length;
        --listenerIndex; // A valid port always has a final reserved accept slot.
        if (token == acceptToken)
            return listenerIndex;
        const slot = cast(uint) token;
        return (token >> 32) != 0 && slot < listenerIndex ? slot : size_t.max;
    }

    // SAFETY: The synchronous WSAIoctl copies the GUID and writes one function pointer into a live local.
    private bool loadAcceptExtension(ref CompletionPort port, Socket listener) @trusted nothrow @nogc
    {
        if (port.acceptSocket !is null)
            return true;
        GUID extension = WSAID_ACCEPTEX;
        DWORD transferred;
        AcceptSocket entry;
        const result = WSAIoctl(listener.descriptor, getExtensionFunction, &extension,
                extension.sizeof, &entry, entry.sizeof, &transferred, null, null);
        if (result != 0 || transferred != entry.sizeof || entry is null)
            return false;
        port.acceptSocket = entry;
        return true;
    }

    // SAFETY: AcceptEx uses only the dedicated stable slot and a newly owned accept socket. The port
    // or its owner retains both to the original completion, including after requesting cancellation.
    package(flint.reactor) Status submitAccept(ref CompletionPort port, ref Socket listener) @trusted nothrow @nogc
    {
        const status = associate(port, listener);
        if (status != Status.ok)
            return status;
        auto slot = &port.slots[$ - 1];
        if (slot.token != 0)
            return Status.unavailable;
        if (!loadAcceptExtension(port, listener))
            return Status.unsupported;

        const accepted = WSASocketW(listener.family, SOCK_STREAM, 0, null, 0, socketFlags);
        if (accepted == INVALID_SOCKET)
            return windowsError(WSAGetLastError());
        *slot = PendingIo.init;
        slot.socket = listener.descriptor;
        slot.accepted = Socket(accepted, null, listener.family);
        const success = port.acceptSocket(listener.descriptor, accepted, slot.addresses.ptr, 0,
                acceptAddressBytes, acceptAddressBytes, &slot.transferred, &slot.overlapped);
        const failure = success ? 0 : WSAGetLastError();
        if (success || failure == wsaIoPending)
        {
            slot.token = acceptToken;
            ++port.active;
            return Status.ok;
        }
        closeSocket(slot.accepted);
        return windowsError(failure);
    }

    nothrow @nogc package(flint.reactor) Status submitRead(ref CompletionPort port, ref Socket socket,
            ubyte[] buffer, ulong token)
    {
        return submitSocketIo!(false)(port, socket, buffer, token);
    }

    package(flint.reactor) Status submitWrite(ref CompletionPort port, ref Socket socket,
            const(ubyte)[] buffer, ulong token) nothrow @nogc
    {
        return submitSocketIo!(true)(port, socket, buffer, token);
    }

    // The slot retains its WSABUF and OVERLAPPED until dequeue. WSASend reads despite the mutable API type.
    // SAFETY: The worker owns the bytes at a stable address until the original completion is consumed.
    private Status submitSocketIo(bool sending, Buffer)(ref CompletionPort port, ref Socket socket,
            Buffer buffer, ulong token) @trusted nothrow @nogc
    {
        const index = slotFor(port, token);
        if (index == size_t.max || token == acceptToken || buffer.length == 0 || buffer.length > uint.max)
            return Status.invalidArgument;
        auto slot = &port.slots[index];
        if (slot.token != 0)
            return Status.unavailable;
        const status = associate(port, socket);
        if (status != Status.ok)
            return status;

        *slot = PendingIo.init;
        slot.socket = socket.descriptor;
        slot.buffer = WsaBuffer(cast(uint) buffer.length, cast(char*) buffer.ptr);
        static if (sending)
            const result = WSASend(socket.descriptor, &slot.buffer, 1, null, 0, &slot.overlapped, null);
        else
            const result = WSARecv(socket.descriptor, &slot.buffer, 1, null, &slot.flags, &slot.overlapped, null);
        const failure = result == 0 ? 0 : WSAGetLastError();
        if (result != 0 && failure != wsaIoPending)
            return windowsError(failure);
        // Even synchronous success generates an IOCP packet with this configuration.
        slot.token = token;
        ++port.active;
        return Status.ok;
    }

    // SAFETY: The exact token identifies a stable live slot on this port. CancelIoEx does not retire it.
    package(flint.reactor) Status cancelKernel(ref CompletionPort port, ulong token) @trusted nothrow @nogc
    {
        const index = slotFor(port, token);
        if (index == size_t.max || port.slots[index].token != token)
            return Status.notFound;
        auto slot = &port.slots[index];
        if (CancelIoEx(cast(HANDLE) slot.socket, &slot.overlapped) != 0)
            return Status.ok;
        return windowsError(GetLastError());
    }

    // SAFETY: Winsock copies the listener descriptor synchronously. The new socket transfers to
    // the worker only if its accept context is ready. Any unsuccessful accept closes the new socket.
    private void finishAccept(ref PendingIo slot, ref KernelEvent event) @trusted nothrow @nogc
    {
        if (event.status == Status.ok && setsockopt(slot.accepted.descriptor, SOL_SOCKET,
                updateAcceptContext, &slot.socket, SOCKET.sizeof) != 0)
            event.status = windowsError(WSAGetLastError());
        if (event.status == Status.ok)
        {
            event.accepted = slot.accepted;
            slot.accepted = Socket.init;
        }
        else
            closeSocket(slot.accepted);
    }

    // SAFETY: The port only carries packets for this owner's submissions. The returned pointer must be
    // aligned to a slot in the live allocation before interpreting the packet. Each CQE retires that slot once.
    package(flint.reactor) Result!KernelEvent pollCompletion(ref CompletionPort port, uint ms) @trusted nothrow @nogc
    {
        if (!port.valid)
            return Result!KernelEvent(KernelEvent.init, Error(Status.invalidArgument, "invalid completion port"));
        DWORD bytes;
        ULONG_PTR key;
        OVERLAPPED* overlapped;
        const completed = GetQueuedCompletionStatus(port.handle, &bytes, &key, &overlapped,
                ms == uint.max ? uint.max - 1 : ms);
        const failure = completed ? 0 : GetLastError();
        if (overlapped is null)
        {
            if (failure == WAIT_TIMEOUT)
                return Result!KernelEvent(KernelEvent.init);
            return Result!KernelEvent(KernelEvent.init, Error(windowsError(failure), "IOCP polling failed"));
        }

        const address = cast(size_t) overlapped;
        const base = cast(size_t) port.slots.ptr;
        if (address < base || (address - base) % PendingIo.sizeof != 0)
            return Result!KernelEvent(KernelEvent.init, Error(Status.ioError, "unexpected IOCP packet address"));
        const index = (address - base) / PendingIo.sizeof;
        if (index >= port.slots.length || port.slots[index].token == 0)
            return Result!KernelEvent(KernelEvent.init, Error(Status.ioError, "unexpected IOCP packet identity"));

        auto slot = &port.slots[index];
        KernelEvent event = KernelEvent(true, slot.token, completed ? Status.ok : windowsError(failure), bytes);
        if (slot.token == acceptToken)
            finishAccept(*slot, event);
        *slot = PendingIo.init;
        --port.active;
        return Result!KernelEvent(event);
    }

    version (unittest)
    {
        import core.sys.windows.winsock2 : IPPROTO_TCP, connect, htonl, htons, send;

        private extern (Windows) BOOL WSAGetOverlappedResult(SOCKET socket, OVERLAPPED* overlapped,
                DWORD* transferred, BOOL wait, DWORD* flags) @system nothrow @nogc;

        @("IOCP retains a completed read when CancelIoEx reports ERROR_NOT_FOUND")
        @system unittest
        {
            auto port = openCompletionPort(1);
            assert(port.ok);
            scope (exit)
                closeCompletionPort(port.value);

            auto listener = bindListener("127.0.0.1", 0, 4);
            assert(listener.ok);
            scope (exit)
                closeSocket(listener.value);
            const localPort = socketPort(listener.value);
            assert(localPort.ok && localPort.value != 0);
            assert(submitAccept(port.value, listener.value) == Status.ok);

            Socket client = Socket(WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, null, 0, socketFlags));
            assert(client.valid);
            scope (exit)
                closeSocket(client);
            sockaddr_in address;
            address.sin_port = htons(localPort.value);
            address.sin_addr.s_addr = htonl(0x7f000001);
            assert(connect(client.descriptor, cast(sockaddr*)&address, sockaddr_in.sizeof) == 0);
            auto event = pollCompletion(port.value, 5000);
            assert(event.ok && event.value.received);
            assert(event.value.token == acceptToken && event.value.status == Status.ok);
            auto server = event.value.accepted;
            scope (exit)
                closeSocket(server);

            enum first = 1UL << 32;
            ubyte[1] buffer;
            assert(submitRead(port.value, server, buffer[], first) == Status.ok);
            closeCompletionPort(port.value);
            assert(port.value.valid);
            ubyte payload = 42;
            assert(send(client.descriptor, &payload, 1, 0) == 1);
            DWORD transferred, flags;
            auto slot = &port.value.slots[0];
            assert(WSAGetOverlappedResult(server.descriptor, &slot.overlapped, &transferred, 1, &flags));
            assert(cancelKernel(port.value, first) == Status.notFound);
            event = pollCompletion(port.value, 5000);
            assert(event.ok && event.value.received && event.value.token == first);
            assert(event.value.status == Status.ok && event.value.bytes == 1 && buffer[0] == payload);
            assert(!pollCompletion(port.value, 0).value.received);

            enum second = 2UL << 32;
            assert(submitRead(port.value, server, buffer[], second) == Status.ok);
            assert(cancelKernel(port.value, second) == Status.ok);
            event = pollCompletion(port.value, 5000);
            assert(event.ok && event.value.received && event.value.token == second);
            assert(event.value.status == Status.cancelled);
        }
    }
}
