/// Scoped archive calls and callback bridges for the selected libarchive profile.
module flint.engine.codec.ffi.archive;

import core.stdc.stdlib : abort;
import flint.arena : Error, Status;
import flint.engine.codec.types : ArchiveFormat, ArchiveOptions, ArchiveSink, ArchiveSource;
import flint.engine.codec.ffi.shim : NativeStatus, nativeError;

@safe:
nothrow @nogc:

private struct ArchiveState;

private alias ReadCallback = extern (C) int function(void*, ubyte*, size_t, size_t*) nothrow @nogc;
private alias WriteCallback = extern (C) int function(void*, const(ubyte)*, size_t) nothrow @nogc;

extern (C) private @system
{
    int flint_archive_available();
    ArchiveState* flint_archive_reader_new(int, ReadCallback, void*, ulong);
    ArchiveState* flint_archive_writer_new(int, WriteCallback, void*);
    NativeStatus flint_archive_reader_limits(ArchiveState*, size_t, uint);
    NativeStatus flint_archive_next(ArchiveState*, ubyte*, size_t, size_t*, ulong*, int*);
    NativeStatus flint_archive_read(ArchiveState*, ubyte*, size_t, size_t*);
    NativeStatus flint_archive_entry(ArchiveState*, const(char)*, ulong, int);
    NativeStatus flint_archive_write(ArchiveState*, const(ubyte)*, size_t);
    NativeStatus flint_archive_close(ArchiveState*);
    void flint_archive_abort(ArchiveState*);
}

version (linux)
{
    version (FlintNativeLibarchive) version = FlintArchiveNative;
}
else version (OSX)
{
    version (FlintNativeLibarchive) version = FlintArchiveNative; // ADR-024
}

package(flint.engine.codec) enum archivePathLimit = 4096;
package(flint.engine.codec) enum archiveEntryLimit = 10_000;
package(flint.engine.codec) enum archiveByteLimit = 1024UL * 1024 * 1024;

package(flint.engine.codec) struct Header
{
    size_t length;
    ulong bytes;
    int directory;
    NativeStatus status;
}

package(flint.engine.codec) struct Chunk
{
    size_t length;
    NativeStatus status;
}

package(flint.engine.codec) struct NativeArchive
{
nothrow @nogc:

    private ArchiveState* state;
    private ArchiveSource source;
    private ArchiveSink sink;
    private Error callbackError;

    Error error(NativeStatus status)
    {
        return callbackError.code == Status.ok ? nativeError(status) : callbackError;
    }

    // SAFETY: This busy owner-thread TLS slot has a fixed address and roots its source. The
    // synchronous readBridge bounds the C borrow and prevents D errors from crossing the ABI.
    Error openReader(ArchiveFormat format, ArchiveOptions options, ArchiveSource callback) @trusted nothrow @nogc
    {
        version (FlintArchiveNative)
        {
            if (!flint_archive_available())
                return nativeError(NativeStatus.unsupported);
            source = callback;
            state = flint_archive_reader_new(format, &readBridge, &this, options.maxTotalBytes);
            if (state is null)
                return error(NativeStatus.noMemory);
            const status = flint_archive_reader_limits(state, options.maxPathBytes, options.maxEntries);
            return status == NativeStatus.ok ? Error.init : error(status);
        }
        else
            return nativeError(NativeStatus.unsupported);
    }

    // SAFETY: This busy owner-thread TLS slot has a fixed address and roots its sink. The
    // synchronous writeBridge bounds the C borrow and prevents D errors from crossing the ABI.
    Error openWriter(ArchiveFormat format, ArchiveSink callback) @trusted nothrow @nogc
    {
        version (FlintArchiveNative)
        {
            if (!flint_archive_available())
                return nativeError(NativeStatus.unsupported);
            sink = callback;
            state = flint_archive_writer_new(format, &writeBridge, &this);
            return state is null ? error(NativeStatus.noMemory) : Error.init;
        }
        else
            return nativeError(NativeStatus.unsupported);
    }

    // SAFETY: The busy owner slot holds the live provider; path and counters are valid for the
    // synchronous call and never retained. Any source callback uses the bounded readBridge.
    Header next(scope ubyte[] path) @trusted nothrow @nogc
    {
        Header header;
        version (FlintArchiveNative)
            header.status = flint_archive_next(state, path.ptr, path.length, &header.length,
                    &header.bytes, &header.directory);
        else
            header.status = NativeStatus.unsupported;
        return header;
    }

    // SAFETY: The busy owner slot holds the live provider. The writable span and count last
    // through the call and are never retained. Any callback uses the bounded readBridge.
    Chunk read(scope ubyte[] output) @trusted nothrow @nogc
    {
        Chunk chunk;
        version (FlintArchiveNative)
            chunk.status = flint_archive_read(state, output.ptr, output.length, &chunk.length);
        else
            chunk.status = NativeStatus.unsupported;
        return chunk;
    }

    // SAFETY: The path is copied into a bounded NUL-terminated value before the synchronous call.
    // Native retains its own metadata, and any sink borrow is limited to writeBridge.
    NativeStatus entry(scope const(char)[] path, ulong size, bool directory) @trusted nothrow @nogc
    {
        version (FlintArchiveNative)
        {
            if (path.length > archivePathLimit)
                return NativeStatus.limit;
            char[archivePathLimit + 1] name = 0;
            name[0 .. path.length] = path[];
            return flint_archive_entry(state, &name[0], size, directory);
        }
        else
            return NativeStatus.unsupported;
    }

    // SAFETY: Native consumes just the passed input bounds and keeps no borrow after return.
    // The owner slot is busy through any synchronous callback, which writeBridge contains.
    NativeStatus write(scope const(ubyte)[] bytes) @trusted nothrow @nogc
    {
        version (FlintArchiveNative)
            return flint_archive_write(state, bytes.ptr, bytes.length);
        else
            return NativeStatus.unsupported;
    }

    // SAFETY: Clear the owner pointer before synchronously releasing the provider. The busy slot
    // keeps its delegates rooted during optional trailer callbacks. Abort performs no I/O.
    Error close(bool abort) @trusted nothrow @nogc
    {
        version (FlintArchiveNative)
        {
            auto owned = state;
            state = null;
            if (owned !is null)
            {
                if (abort)
                    flint_archive_abort(owned);
                else
                {
                    const result = flint_archive_close(owned);
                    if (result != NativeStatus.ok)
                        return error(result);
                }
            }
        }
        return Error.init;
    }
}

// SAFETY: C supplies its live TLS bridge address and bounded writable buffer and count.
// The caller callback's scope cannot retain the provider buffer, and a fatal D error terminates before crossing C.
extern (C) private int readBridge(void* user, ubyte* bytes, size_t capacity, size_t* written) @trusted nothrow @nogc
{
    auto bridge = cast(NativeArchive*) user;
    scope (failure)
        abort();
    const outcome = bridge.source(bytes[0 .. capacity]);
    if (outcome.ok() && outcome.value <= capacity)
    {
        *written = outcome.value;
        return 0;
    }
    bridge.callbackError = outcome.ok() ? Error(Status.invalidArgument,
            "archive source wrote beyond its supplied buffer") : outcome.error;
    return -1;
}

// SAFETY: C supplies its live TLS bridge address and a bounded input span valid for this call.
// The delegate receives a scoped borrow and a fatal D error terminates before crossing C.
extern (C) private int writeBridge(void* user, const(ubyte)* bytes, size_t length) @trusted nothrow @nogc
{
    auto bridge = cast(NativeArchive*) user;
    scope (failure)
        abort();
    bridge.callbackError = bridge.sink(bytes[0 .. length]);
    return bridge.callbackError.code == Status.ok ? 0 : -1;
}
