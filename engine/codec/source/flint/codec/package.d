/// Bounded native compression and archive streams.
module flint.codec;

import flint.arena : Error, Result;
public import flint.codec.archives : ArchiveReader, ArchiveWriter;
public import flint.codec.types : ArchiveEntry, ArchiveFormat, ArchiveOptions, ArchiveSink,
    ArchiveSource, Codec, CodecOptions, CodecStep, Finish;
import flint.codec.runtime : Token, closeStream, openStream, processStream;

@safe:

/// Thread-confined encoder. Closing it invalidates all copies.
struct Encoder
{
    private Token owner;

    /// Allocate a provider stream using the selected encoder settings.
    Error open(CodecOptions options) nothrow @nogc
    {
        return openStream(owner, options, true);
    }

    /// Encode into caller-owned output. Re-supply any unconsumed input.
    Result!CodecStep process(scope const(ubyte)[] input, scope ubyte[] output, Finish finish) nothrow @nogc
    {
        return processStream(owner, input, output, finish);
    }

    /// Release the state and invalidate all copies. May be called repeatedly.
    Error close() nothrow @nogc
    {
        return closeStream(owner);
    }
}

/// Thread-confined decoder. Closing it invalidates all copies.
struct Decoder
{
    private Token owner;

    /// Allocate a stream with the selected decoder budgets.
    Error open(CodecOptions options) nothrow @nogc
    {
        return openStream(owner, options, false);
    }

    /// Decode a single frame into caller-owned output. Re-supply any unconsumed input.
    Result!CodecStep process(scope const(ubyte)[] input, scope ubyte[] output, Finish finish) nothrow @nogc
    {
        return processStream(owner, input, output, finish);
    }

    /// Release the state and invalidate all copies. May be called repeatedly.
    Error close() nothrow @nogc
    {
        return closeStream(owner);
    }
}
