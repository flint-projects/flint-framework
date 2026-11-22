module codec_replay;

import core.memory : GC;
import core.time : MonoTime;
import flint.arena : Error, Result, Status;
import core.stdc.stdio : printf;

@safe:

/// Success remains observable in release builds.
void require(bool condition) pure nothrow @nogc
{
    if (!condition)
        assert(0, "codec probe invariant failed");
}

/// Encode and decode one known payload in both implementation and reference lanes.
alias CodecRun = size_t function(scope const(ubyte)[], scope ubyte[], scope ubyte[]) @safe nothrow @nogc;
/// Build and read a one-entry archive entirely in owned memory.
alias ArchiveRun = size_t function(scope const(ubyte)[], ArchiveMemory) @safe nothrow @nogc;

/// Shared owned storage for the archive provider workload.
final class ArchiveMemory
{
    /// Wire archive.
    ubyte[] wire;
    /// Decoded body.
    ubyte[] body;
    /// Bytes accumulated in wire.
    size_t encoded;
    /// Bytes copied into body.
    size_t decoded;
    private size_t supplied;

    /// Allocate fixed fixture capacity before timings.
    this(size_t capacity)
    {
        wire = new ubyte[2 * capacity + 16_384];
        body = new ubyte[capacity + 1];
    }

    /// Clear logical lengths before a replay.
    void reset() nothrow @nogc
    {
        encoded = 0;
        decoded = 0;
        supplied = 0;
    }

    /// Save the next encoded prefix.
    Error save(scope const(ubyte)[] bytes) nothrow @nogc
    {
        return copyBytes(wire, encoded, bytes);
    }

    /// Fill the source span with owned wire bytes.
    Result!size_t source(scope ubyte[] bytes) nothrow @nogc
    {
        const available = encoded - supplied;
        const count = available < bytes.length ? available : bytes.length;
        bytes[0 .. count] = wire[supplied .. supplied + count];
        supplied += count;
        return Result!size_t(count);
    }

    /// Collect the checked decoded body.
    Error collect(scope const(ubyte)[] bytes) nothrow @nogc
    {
        return copyBytes(body, decoded, bytes);
    }

    private static Error copyBytes(scope ubyte[] dest, ref size_t index, scope const(ubyte)[] bytes) nothrow @nogc
    {
        if (bytes.length > dest.length - index)
            return Error(Status.outOfMemory, "probe buffer exhausted");
        dest[index .. index + bytes.length] = bytes[];
        index += bytes.length;
        return Error.init;
    }
}

private ubyte[] payload(size_t count)
{
    auto bytes = new ubyte[count];
    uint state = 0x792046fa;
    foreach (index, ref value; bytes)
    {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        value = index % 64 < 16 ? cast(ubyte) state : cast(ubyte)(index % 29);
    }
    return bytes;
}

private ulong checksum(scope const(ubyte)[] encoded, scope const(ubyte)[] decoded) pure nothrow @nogc
{
    ulong value = 0x14650fb0739d0383;
    foreach (byte_; encoded)
        value = (value ^ byte_) * 0x100000001b3;
    foreach (byte_; decoded)
        value = (value ^ byte_) * 0x100000001b3;
    return value;
}

/// Measure level-3 replay rates and observe exact encoded and decoded bytes.
void benchmark(string name, CodecRun execute, bool measure)
{
    foreach (const size; [1_024, 65_536, 1_048_576])
    {
        auto input = payload(size);
        auto wire = new ubyte[2 * size + 1024];
        auto plain = new ubyte[size + 1];
        const start = MonoTime.currTime;
        const allocated = GC.stats().allocatedInCurrentThread;
        const rounds = measure ? 256 * 1024 * 1024 / size : 1;
        size_t length;
        foreach (_; 0 .. rounds)
        {
            length = execute(input, wire, plain);
            require(length != 0 && plain[0 .. size] == input);
        }
        const elapsed = (MonoTime.currTime - start).total!"msecs";
        const bytes = GC.stats().allocatedInCurrentThread - allocated;
        printCodec(name, size, length, checksum(wire[0 .. length], input));
        if (measure)
            printRepetitions(name, rounds, elapsed, bytes);
    }
}

/// Exercise identical 64 KiB archive write/read operations through both callers.
void archiveReplay(string name, ArchiveRun execute, bool measure)
{
    enum size = 65_536;
    auto input = payload(size);
    auto memory = new ArchiveMemory(size);
    const start = MonoTime.currTime;
    const steadyRounds = name == "tar" ? 65_536 : 8192;
    const rounds = measure ? steadyRounds : 1;
    foreach (_; 0 .. rounds)
    {
        memory.reset();
        const count = execute(input, memory);
        require(count == memory.encoded && memory.decoded == input.length && memory.body[0 .. memory.decoded] == input);
    }
    const elapsed = (MonoTime.currTime - start).total!"msecs";
    printArchive(name, size, memory.encoded, checksum(memory.wire[0 .. memory.encoded], input));
    if (measure)
        printArchiveRepetitions(name, rounds, elapsed);
}

// SAFETY: Each C format string below is a fixed NUL-terminated literal; names are printed with
// their explicit length and every scalar matches its conversion.
private void printCodec(string name, int size, size_t length, ulong sum) @trusted nothrow @nogc
{
    printf("%.*s level=3 input=%d encoded=%zu checksum=%llu\n", cast(int) name.length, name.ptr, size, length, sum);
}

// SAFETY: As above: fixed literal format, explicit name length, matching scalar arguments.
private void printRepetitions(string name, int rounds, long elapsed, ulong bytes) @trusted nothrow @nogc
{
    printf("%.*s repetitions=%d elapsed_ms=%lld gc_bytes=%llu\n", cast(int) name.length, name.ptr,
            rounds, elapsed, bytes);
}

// SAFETY: As above: fixed literal format, explicit name length, matching scalar arguments.
private void printArchive(string name, int size, size_t encoded, ulong sum) @trusted nothrow @nogc
{
    printf("%.*s input=%d encoded=%zu checksum=%llu\n", cast(int) name.length, name.ptr, size, encoded, sum);
}

// SAFETY: As above: fixed literal format, explicit name length, matching scalar arguments.
private void printArchiveRepetitions(string name, int rounds, long elapsed) @trusted nothrow @nogc
{
    printf("%.*s repetitions=%d elapsed_ms=%lld\n", cast(int) name.length, name.ptr, rounds, elapsed);
}
