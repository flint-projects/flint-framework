/// Fixed local wait for owner threads outside a Reactor.
module flint.mq.ffi.socket;

import flint.arena : Error, Status;

@safe:

// Linux and macOS (ADR-024).
version (linux)
    version = FlintMqPosix;
else version (OSX)
    version = FlintMqPosix;

version (FlintMqPosix)
{
    private import core.sys.posix.time : nanosleep, timespec;
}

// SAFETY: The bounded POSIX wait uses a stack timespec with no callback or retained pointer.
package(flint.mq) Error pauseSocket() @trusted nothrow @nogc
{
    version (FlintMqPosix)
    {
        const timespec next = timespec(0, 1_000_000);
        nanosleep(&next, null);
        return Error.init;
    }
    else
        return Error(Status.unsupported, "native broker polling unavailable");
}

version (FlintMqPosix) version (FlintNativeLibrdkafka) version = FlintMqOnLinux;

private struct NativeSocket;

extern (C) private @system nothrow @nogc
{
    int flint_mq_socket_open(scope const(char)*, ushort, scope NativeSocket**);
    int flint_mq_socket_connected(NativeSocket*);
    int flint_mq_socket_tls(NativeSocket*, scope const(char)*, scope const(char)*);
    int flint_mq_socket_handshake(NativeSocket*);
    int flint_mq_socket_read(NativeSocket*, scope ubyte*, size_t, scope size_t*);
    int flint_mq_socket_write(NativeSocket*, scope const(ubyte)*, size_t, scope size_t*);
    void flint_mq_socket_close(NativeSocket*);
}

package(flint.mq) struct Socket
{
    import flint.arena : Result;
    import flint.mq.ffi.kafka : nativeError, terminated;

    private NativeSocket* handle;

nothrow @nogc:

    // SAFETY: Native resolution and socket creation borrow the bounded host only until this call returns.
    @trusted Error open(scope const(char)[] host, ushort port)
    {
        char[256] name;
        if (!terminated(host, name[]))
            return nativeError(Status.invalidArgument);
        version (FlintMqOnLinux)
            return nativeError(cast(Status) flint_mq_socket_open(name.ptr, port, &handle));
        else
            return nativeError(Status.unsupported);
    }

    Error connected() scope
    {
        return nativeError(invoke!flint_mq_socket_connected(handle));
    }

    Error startTls(scope const(char)[] host, scope const(char)[] caBundle) scope
    {
        char[256] name;
        char[2049] path;
        if (!terminated(host, name[]) || !terminated(caBundle, path[]))
            return nativeError(Status.invalidArgument);
        return nativeError(invoke!flint_mq_socket_tls(handle, &name[0], caBundle.length ? &path[0] : null));
    }

    Error handshake() scope
    {
        return nativeError(invoke!flint_mq_socket_handshake(handle));
    }

    Result!size_t read(scope ubyte[] bytes) scope
    {
        size_t received;
        const status = invoke!flint_mq_socket_read(handle, bytes.length ? &bytes[0] : null, bytes.length, &received);
        if (received > bytes.length)
            return Result!size_t(0, nativeError(Status.ioError));
        return Result!size_t(received, nativeError(status));
    }

    Result!size_t write(scope const(ubyte)[] bytes) scope
    {
        size_t written;
        const status = invoke!flint_mq_socket_write(handle, bytes.length ? &bytes[0] : null, bytes.length, &written);
        if (written > bytes.length || (status == Status.ok && written == 0))
            return Result!size_t(0, nativeError(Status.ioError));
        return Result!size_t(written, nativeError(status));
    }

    // SAFETY: Closing on the single owner retires this opaque socket after each synchronous I/O call has ended.
    @trusted void close() scope
    {
        version (FlintMqOnLinux)
            flint_mq_socket_close(handle);
        handle = null;
    }
}

// SAFETY: Inputs are bounded stack or arena spans. Socket I/O copies immediately and stores no D pointers.
private Status invoke(alias fn, Args...)(scope Args args) @trusted nothrow @nogc
{
    version (FlintMqOnLinux)
        return cast(Status) fn(args);
    else
        return Status.unsupported;
}
