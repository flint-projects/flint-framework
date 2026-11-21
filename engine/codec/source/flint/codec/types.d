/// Public value and callback types for bounded compression and archives.
module flint.codec.types;

import flint.arena : Buffer, Error, Result;

@safe:

/// Supported compression formats.
enum Codec : ubyte
{
    gzip,
    zstd,
    brotli
}

/// How much of the stream the caller has supplied.
enum Finish : ubyte
{
    /// More input may follow.
    more,
    /// Emit buffered data without closing. Repeat with empty input until a flush makes no progress.
    flush,
    /// Complete the frame using this input and drain any remaining output.
    end
}

/// Provider selection and cumulative resource limits.
struct CodecOptions
{
    /// Wire format.
    Codec codec = Codec.gzip;
    /// Provider-specific encoder level. Decoders ignore it.
    int level = 3;
    /// Maximum total output across the entire stream.
    ulong maxOutputBytes = 64 * 1024 * 1024;
    /// Maximum decoded output per input byte, with a 1024-byte denominator floor.
    uint maxExpansionRatio = 100;
}

/// Progress in one streaming call.
struct CodecStep
{
    /// Input prefix used by the codec.
    size_t consumed;
    /// Output prefix filled by the codec.
    size_t produced;
    /// The one permitted frame or member has completed.
    bool finished;
}

/// Supported archive formats. Outer compression filters are never enabled.
enum ArchiveFormat : ubyte
{
    zip,
    tar
}

/// A validated entry and its declared decoded size.
struct ArchiveEntry
{
    /// A UTF-8 path relative to the archive root, copied into the supplied arena.
    Buffer path;
    /// Number of decoded data bytes in the entry.
    ulong uncompressedBytes;
    /// Whether the entry is a directory.
    bool directory;
}

/// Fill a scoped archive input buffer. A successful zero count indicates EOF.
alias ArchiveSource = Result!size_t delegate(scope ubyte[] output) @safe nothrow @nogc;
/// Consume a scoped archive output buffer.
alias ArchiveSink = Error delegate(scope const(ubyte)[] input) @safe nothrow @nogc;

/// Reader admission and decoded output ceilings.
struct ArchiveOptions
{
    /// Largest number of exposed entries.
    uint maxEntries = 10_000;
    /// Largest cumulative decoded output, including skipped entries.
    ulong maxTotalBytes = 1024UL * 1024 * 1024;
    /// Maximum validated UTF-8 entry path length.
    size_t maxPathBytes = 4096;
    /// Links are unsupported because the entry API cannot describe their targets.
    bool allowSymlinks = false;
}
