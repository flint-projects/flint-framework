/// Length-delimited access to the selected native compression providers.
module flint.engine.codec.ffi.shim;

import flint.arena : Error, Status;

@safe:
nothrow @nogc:

private struct CodecState;

package(flint.engine.codec) enum NativeStatus : int
{
    ok = 0,
    finished = 1,
    needInput = 2,
    invalid = -1,
    noMemory = -2,
    dictionary = -3,
    limit = -4,
    unsupported = -5
}

package(flint.engine.codec) struct NativeStep
{
    size_t consumed;
    size_t produced;
    NativeStatus status;
}

package(flint.engine.codec) struct Allocations
{
    size_t calls;
    size_t liveBytes;
    size_t peakBytes;
}

extern (C) private @system
{
    int flint_codec_available(int);
    int flint_codec_level_valid(int, int);
    CodecState* flint_codec_new(int, int, int);
    NativeStatus flint_codec_step(CodecState*, const(ubyte)*, size_t, size_t*, ubyte*, size_t, size_t*, int);
    void flint_codec_free(CodecState*);
    Allocations flint_codec_get_allocations(const(CodecState)*);
}

version (linux)
{
    version (FlintNativeZlib)
        version = FlintCodecNative;
    else version (FlintNativeZstd)
        version = FlintCodecNative;
    else version (FlintNativeBrotli)
        version = FlintCodecNative;
}
else version (OSX)
{
    version (FlintNativeZlib)
        version = FlintCodecNative;
    else version (FlintNativeZstd)
        version = FlintCodecNative;
    else version (FlintNativeBrotli)
        version = FlintCodecNative;
}
else version (Windows)
{
    version (FlintNativeZlib)
        version = FlintCodecNative; // ADR-026
    else version (FlintNativeZstd)
        version = FlintCodecNative;
    else version (FlintNativeBrotli)
        version = FlintCodecNative;
}

package(flint.engine.codec) Error nativeError(NativeStatus status)
{
    switch (status)
    {
    case NativeStatus.noMemory:
        return Error(Status.outOfMemory, "native codec allocation failed");
    case NativeStatus.dictionary:
        return Error(Status.unsupported, "codec frame requires an external dictionary");
    case NativeStatus.limit:
        return Error(Status.resourceExhausted, "native codec resource limit exceeded");
    case NativeStatus.unsupported:
        return Error(Status.unsupported, "pinned codec provider unavailable");
    default:
        return Error(Status.invalidArgument, "invalid codec stream");
    }
}

// SAFETY: The slices are borrowed only for this comparison. Integer distances compare addresses
// without dereferencing them or advancing outside their bounds. No callbacks or exceptions occur.
package(flint.engine.codec) @trusted nothrow @nogc bool disjoint(scope const(ubyte)[] source, scope const(ubyte)[] sink)
{
    if (!source.length || !sink.length)
        return true;
    const first = cast(size_t) source.ptr;
    const second = cast(size_t) sink.ptr;
    return first <= second ? second - first >= source.length : first - second >= sink.length;
}

package(flint.engine.codec) struct NativeCodec
{
nothrow @nogc:

    private CodecState* state;

    // SAFETY: Scalar selection is checked before native ownership is established in this thread's
    // private slot. The provider retains no D memory, runs no callbacks and cannot throw a D exception.
    Error open(int codec, bool encode, int level) @trusted nothrow @nogc
    {
        version (FlintCodecNative)
        {
            if (!flint_codec_available(codec))
                return nativeError(NativeStatus.unsupported);
            if (encode && !flint_codec_level_valid(codec, level))
                return Error(Status.invalidArgument, "invalid encoder level for selected codec");
            state = flint_codec_new(codec, encode, level);
            return state is null ? nativeError(NativeStatus.noMemory) : Error.init;
        }
        else
            return nativeError(NativeStatus.unsupported);
    }

    // SAFETY: The owner's generation was checked before accessing this slot. These in-bounds spans
    // and counters live through the synchronous call. C keeps no borrowed data and calls no D code.
    NativeStep step(scope const(ubyte)[] input, scope ubyte[] output, int finish) @trusted nothrow @nogc
    {
        NativeStep result;
        version (FlintCodecNative)
            result.status = flint_codec_step(state, input.ptr, input.length, &result.consumed,
                    output.ptr, output.length, &result.produced, finish);
        else
            result.status = NativeStatus.unsupported;
        return result;
    }

    // SAFETY: The private thread-owned slot remains live throughout this scalar-only query.
    // The provider reads its own allocation counters and never retains a D borrow or calls back.
    Allocations allocations() const @trusted nothrow @nogc
    {
        version (FlintCodecNative)
            return flint_codec_get_allocations(state);
        else
            return Allocations.init;
    }

    // SAFETY: The owning slot clears its reference before destruction. There is no concurrent
    // process call, borrowed storage or D callback during the provider destructor.
    void close() @trusted nothrow @nogc
    {
        version (FlintCodecNative)
        {
            auto owned = state;
            state = null;
            flint_codec_free(owned);
        }
    }
}
