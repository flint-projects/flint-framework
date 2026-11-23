module flint.engine.reactor.sys.completion;

import flint.arena : Error, Result, Status;

@safe:

version (linux)
{
    import flint.engine.reactor.sys.sockets : Socket, acceptError, socketError;
    import core.stdc.errno : EAGAIN, ENOENT, EPERM, ENOSYS, ECANCELED, EOPNOTSUPP, EINVAL, ENOMEM;

package(flint.engine.reactor):

    struct CompletionPort
    {
        private void* owner;

        bool valid() const pure nothrow @nogc
        {
            return owner !is null;
        }
    }

    struct KernelEvent
    {
        bool received;
        ulong token;
        Status status;
        size_t bytes;
        Socket accepted;
    }

    version (FlintNativeLiburing)
    {
        private extern (C)
        {
            int flint_uring_open(uint entries, void** result) @system nothrow @nogc;
            void flint_uring_close(void* owner) @system nothrow @nogc;
            uint flint_uring_setup_flags(void* owner) @system nothrow @nogc;
            int flint_uring_accept(void* owner, int fd, ulong token) @system nothrow @nogc;
            int flint_uring_recv(void* owner, int fd, ubyte* output, uint length, ulong token) @system nothrow @nogc;
            int flint_uring_send(void* owner, int fd, const(ubyte)* input, uint len, ulong tag) @system nothrow @nogc;
            int flint_uring_poll_readable(void* owner, int fd, ulong token) @system nothrow @nogc;
            int flint_uring_cancel(void* owner, ulong token) @system nothrow @nogc;
            int flint_uring_wait(void* owner, uint millis, ulong* token, int* result) @system nothrow @nogc;
        }
    }

    private Status completionStatus(int result) pure nothrow @nogc
    {
        if (result >= 0)
            return Status.ok;
        switch (-result)
        {
        case ENOENT:
            return Status.notFound;
        case ECANCELED:
            return Status.cancelled;
        case ENOSYS:
        case EOPNOTSUPP:
            return Status.unsupported;
        case ENOMEM:
            return Status.outOfMemory;
        case EPERM:
            return Status.permissionDenied;
        case EAGAIN:
            return Status.unavailable;
        default:
            return socketError(-result);
        }
    }

    // SAFETY: The one local pointer is fully initialized by the shim. A successful caller owns the port.
    Result!CompletionPort openCompletionPort(uint entries) @trusted nothrow @nogc
    {
        version (FlintNativeLiburing)
        {
            CompletionPort port;
            const code = flint_uring_open(entries, &port.owner);
            if (code == 0)
                return Result!CompletionPort(port);
            return Result!CompletionPort(CompletionPort.init, Error(completionStatus(code),
                    "io_uring setup or capability probe failed"));
        }
        else
        {
            return Result!CompletionPort(CompletionPort.init, Error(Status.unsupported,
                    "liburing provider not prepared"));
        }
    }

    // SAFETY: Reads one field of the shim's owner record, which lives until closeCompletionPort; null is answered 0.
    uint completionSetupFlags(ref const CompletionPort port) @trusted nothrow @nogc
    {
        version (FlintNativeLiburing)
            return flint_uring_setup_flags(cast(void*) port.owner);
        else
            return 0;
    }

    // SAFETY: The worker drained all original and cancellation CQEs, and no other thread can use its port.
    void closeCompletionPort(ref CompletionPort port) @trusted nothrow @nogc
    {
        version (FlintNativeLiburing)
        {
            if (port.valid)
            {
                flint_uring_close(port.owner);
                port.owner = null;
            }
        }
    }

    // SAFETY: The listener remains owned until the accept CQE. No user-space data pointer is retained.
    Status submitAccept(ref CompletionPort port, Socket listener) @trusted nothrow @nogc
    {
        version (FlintNativeLiburing)
            return completionStatus(flint_uring_accept(port.owner, listener.descriptor, 1));
        else
            return Status.unsupported;
    }

    // SAFETY: The loop submits only its preallocated slot buffer, retained through final CQE and callback return.
    Status submitRead(ref CompletionPort port, Socket socket, ubyte[] buffer, ulong token) @trusted nothrow @nogc
    {
        version (FlintNativeLiburing)
        {
            if (buffer.length == 0 || buffer.length > uint.max)
                return Status.invalidArgument;
            return completionStatus(flint_uring_recv(port.owner, socket.descriptor, buffer.ptr,
                    cast(uint) buffer.length, token));
        }
        else
            return Status.unsupported;
    }

    // SAFETY: The copied input stays owned through the original CQE and callback return, including cancellation.
    Status submitWrite(ref CompletionPort port, Socket fd, const(ubyte)[] data, ulong tag) @trusted nothrow @nogc
    {
        version (FlintNativeLiburing)
        {
            if (data.length == 0 || data.length > uint.max)
                return Status.invalidArgument;
            return completionStatus(flint_uring_send(port.owner, fd.descriptor, data.ptr, cast(uint) data.length, tag));
        }
        else
            return Status.unsupported;
    }

    // SAFETY: The loop retains its epoll descriptor until the poll CQE. The kernel retains no user pointer.
    Status submitReadable(ref CompletionPort port, int fd, ulong token) @trusted nothrow @nogc
    {
        version (FlintNativeLiburing)
            return completionStatus(flint_uring_poll_readable(port.owner, fd, token));
        else
            return Status.unsupported;
    }

    // SAFETY: Only an integer token is copied into the bounded ring, and the original request stays live.
    Status cancelKernel(ref CompletionPort port, ulong token) @trusted nothrow @nogc
    {
        version (FlintNativeLiburing)
            return completionStatus(flint_uring_cancel(port.owner, token));
        else
            return Status.unsupported;
    }

    // SAFETY: The shim writes at most one token and one completion integer synchronously into owned locals.
    Result!KernelEvent pollCompletion(ref CompletionPort port, uint millis) @trusted nothrow @nogc
    {
        version (FlintNativeLiburing)
        {
            ulong token;
            int result;
            const code = flint_uring_wait(port.owner, millis, &token, &result);
            if (code < 0)
                return Result!KernelEvent(KernelEvent.init, Error(completionStatus(code), "io_uring wait failed"));
            if (code == 0)
                return Result!KernelEvent(KernelEvent.init);
            if (token == 1 && result >= 0)
                return Result!KernelEvent(KernelEvent(true, token, Status.ok, 0, Socket(result)));
            // Accept failures share the readiness backend's classification; cancellation stays distinct.
            if (token == 1 && result != -ECANCELED)
                return Result!KernelEvent(KernelEvent(true, token, acceptError(-result)));
            return Result!KernelEvent(KernelEvent(true, token, completionStatus(result),
                    result >= 0 ? cast(size_t) result : 0));
        }
        else
            return Result!KernelEvent(KernelEvent.init, Error(Status.unsupported, "liburing provider not prepared"));
    }
}
