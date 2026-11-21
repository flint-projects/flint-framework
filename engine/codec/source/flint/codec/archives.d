/// Bounded streamed archive sessions and validated arena-owned entry paths.
module flint.codec.archives;

import flint.arena : Error, RequestArena, Result, Status;
import flint.codec.ffi.archive : Header, NativeArchive, archiveByteLimit, archiveEntryLimit, archivePathLimit;
import flint.codec.ffi.shim : NativeStatus;
import flint.codec.runtime : Token, nextGeneration;
import flint.codec.types : ArchiveEntry, ArchiveFormat, ArchiveOptions, ArchiveSink, ArchiveSource;

@safe:

/// Thread-confined ZIP or TAR reader. Entry bodies are consumed through scoped callbacks.
struct ArchiveReader
{
    private Token owner;

    /// Root the reader callback until close. ZIP input is buffered up to 128 MiB for seekable validation.
    Error open(ArchiveFormat format, ArchiveOptions options, ArchiveSource source) nothrow @nogc
    {
        return openArchive(owner, format, options, source, null);
    }

    /// Fetch and copy one entry into the arena. Retry with more space on arena exhaustion.
    Result!ArchiveEntry next(ref scope RequestArena arena) nothrow @nogc
    {
        if (!live(owner, false))
            return Result!ArchiveEntry(ArchiveEntry.init, wrongState);
        return archives[owner.index].next(arena);
    }

    /// Consume the current entry body. A null sink discards the body under the same limits.
    Error read(scope ArchiveSink sink) nothrow @nogc
    {
        return live(owner, false) ? archives[owner.index].read(sink) : wrongState;
    }

    /// Release the reader. Every copy is invalidated.
    Error close() nothrow @nogc
    {
        return closeArchive(owner, false);
    }
}

/// Thread-confined ZIP or TAR writer. Entries declare their precise byte count.
struct ArchiveWriter
{
    private Token owner;

    /// Root the archive sink until close.
    Error open(ArchiveFormat format, ArchiveSink sink) nothrow @nogc
    {
        return openArchive(owner, format, ArchiveOptions.init, null, sink);
    }

    /// Begin one regular file or directory with a validated path and known size.
    Error entry(scope const(char)[] relativePath, ulong size, bool directory) nothrow @nogc
    {
        if (!live(owner, true))
            return wrongState;
        return archives[owner.index].entry(relativePath, size, directory);
    }

    /// Supply a chunk of the current entry. The sum must match the declared size.
    Error write(scope const(ubyte)[] bytes) nothrow @nogc
    {
        return live(owner, true) ? archives[owner.index].write(bytes) : wrongState;
    }

    /// Finish the archive and release ownership. A short entry or sink error fails close.
    Error close() nothrow @nogc
    {
        return closeArchive(owner, true);
    }
}

private enum wrongState = Error(Status.invalidArgument, "archive is closed, failed or owned by another thread");
private enum busyState = Error(Status.conflict, "archive callback is active");
private enum endOfArchive = Error(Status.notFound, "end of archive");

private struct ArchiveSlot
{
nothrow @nogc:

    ulong generation;
    bool writer;
    bool busy;
    bool pending;
    bool body;
    bool ended;
    bool failed;
    NativeArchive archive;
    ubyte[archivePathLimit] path;
    Header header;

    Error fail(Error reason)
    {
        failed = true;
        archive.close(true);
        return reason;
    }

    Result!ArchiveEntry next(ref scope RequestArena arena)
    {
        if (busy || body)
            return Result!ArchiveEntry(ArchiveEntry.init, busy ? busyState : Error(Status.conflict,
                    "consume or skip this archive entry before requesting another"));
        if (failed || ended)
            return Result!ArchiveEntry(ArchiveEntry.init, ended ? endOfArchive : wrongState);
        busy = true;
        scope (exit)
            busy = false;
        if (!pending)
        {
            const issue = lookup();
            if (issue.code != Status.ok)
                return Result!ArchiveEntry(ArchiveEntry.init, issue);
        }

        const copied = arena.copyIn(path[0 .. header.length]);
        if (!copied.ok())
            return Result!ArchiveEntry(ArchiveEntry.init, copied.error);
        pending = false;
        body = true;
        return Result!ArchiveEntry(ArchiveEntry(copied.value, header.bytes, header.directory != 0));
    }

    private Error lookup()
    {
        header = archive.next(path[]);
        if (header.status == NativeStatus.finished)
        {
            ended = true;
            return endOfArchive;
        }
        if (header.status != NativeStatus.ok)
            return fail(archive.error(header.status));
        pending = true;
        return Error.init;
    }

    Error read(scope ArchiveSink sink)
    {
        if (busy)
            return busyState;
        if (failed || !body)
            return wrongState;

        busy = true;
        scope (exit)
            busy = false;

        ubyte[16_384] chunk;
        for (;;)
        {
            const progress = archive.read(chunk[]);
            if (progress.status == NativeStatus.finished)
            {
                body = false;
                return Error.init;
            }
            if (progress.status != NativeStatus.ok)
                return fail(archive.error(progress.status));
            if (sink is null)
                continue;
            const issue = sink(chunk[0 .. progress.length]);
            if (issue.code != Status.ok)
                return fail(issue);
        }
    }

    Error entry(scope const(char)[] relativePath, ulong size, bool directory)
    {
        if (busy)
            return busyState;
        if (failed)
            return wrongState;
        if (relativePath.length > archivePathLimit)
            return Error(Status.resourceExhausted, "archive path exceeds 4096 bytes");
        foreach (byte_; relativePath)
        {
            if (byte_ == 0)
                return Error(Status.invalidArgument, "archive path contains a NUL byte");
        }

        busy = true;
        scope (exit)
            busy = false;
        const status = archive.entry(relativePath, size, directory);
        return status == NativeStatus.ok ? Error.init : archive.error(status);
    }

    Error write(scope const(ubyte)[] bytes)
    {
        if (busy)
            return busyState;
        if (failed)
            return wrongState;

        busy = true;
        scope (exit)
            busy = false;
        const status = archive.write(bytes);
        return status == NativeStatus.ok ? Error.init : archive.error(status);
    }
}

private ArchiveSlot[32] archives;

private Error openArchive(ref Token owner, ArchiveFormat format, ArchiveOptions options,
        ArchiveSource source, ArchiveSink sink) nothrow @nogc
{
    const writer = source is null;
    if (live(owner, writer))
        return Error(Status.conflict, "archive session is already open");
    if (format > ArchiveFormat.max || (writer && sink is null) || !limits(options))
        return Error(Status.invalidArgument, "invalid archive profile, limits or callback");
    if (options.allowSymlinks)
        return Error(Status.unsupported, "archive link entries are disabled");

    foreach (index, ref slot; archives)
    {
        if (slot.generation != 0)
            continue;
        const generation = nextGeneration();
        if (generation == 0)
            break;
        slot.generation = generation;
        slot.writer = writer;
        slot.busy = true;
        owner = Token(index, generation);

        const issue = writer ? slot.archive.openWriter(format, sink) : slot.archive.openReader(format, options, source);
        if (issue.code != Status.ok)
        {
            slot.archive.close(true);
            slot = ArchiveSlot.init;
            owner = Token.init;
            return issue;
        }
        slot.busy = false;
        return Error.init;
    }
    return Error(Status.resourceExhausted, "archive slots exhausted");
}

private bool limits(ArchiveOptions options) nothrow @nogc
{
    return options.maxEntries > 0 && options.maxEntries <= archiveEntryLimit && options.maxPathBytes > 0
        && options.maxPathBytes <= archivePathLimit && options.maxTotalBytes > 0
        && options.maxTotalBytes <= archiveByteLimit;
}

private Error closeArchive(ref Token owner, bool writer) nothrow @nogc
{
    if (!live(owner, writer))
    {
        owner = Token.init;
        return Error.init;
    }
    ref ArchiveSlot slot = archives[owner.index];
    if (slot.busy)
        return busyState;

    slot.busy = true;
    const status = slot.archive.close(slot.failed);
    slot = ArchiveSlot.init;
    owner = Token.init;
    return status;
}

private bool live(Token owner, bool writer) nothrow @nogc
{
    if (owner.generation == 0 || owner.index >= archives.length)
        return false;
    const ref ArchiveSlot slot = archives[owner.index];
    return slot.generation == owner.generation && slot.writer == writer;
}

static ~this() nothrow @nogc
{
    foreach (ref slot; archives)
        slot.archive.close(true);
}
