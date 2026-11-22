module flint.codec.archive_tests;

import core.memory : GC;
import flint.arena : Error, RequestArena, Result, Status;
import flint.codec : ArchiveFormat, ArchiveOptions, ArchiveReader, ArchiveSource, ArchiveWriter;

@safe:

version (FlintNativeLibarchive)
{
    @("Both archive types preserve directories and file bytes with retryable arena capacity")
    unittest
    {
        foreach (format; [ArchiveFormat.zip, ArchiveFormat.tar])
            verifyArchive(format);
    }

    @("Archive metadata rejects traversal, invalid UTF-8, links, devices, and raw ZIP NUL")
    unittest
    {
        foreach (path; ["../sample", "/sample", "C:/sample", "a/../b", "a\\..\\b", "bad\xff"])
            assert(headerStatus(ArchiveFormat.tar, tarFixture(path), ArchiveOptions.init) == Status.invalidArgument);
        foreach (kind; ['1', '2', '3', '4', '6'])
            assert(headerStatus(ArchiveFormat.tar, tarFixture("special", kind),
                    ArchiveOptions.init) == Status.invalidArgument);

        foreach (invalid; ['\0', '\\', '/'])
        {
            auto zip = normalZip();
            zip[30] = cast(ubyte) invalid;
            assert(headerStatus(ArchiveFormat.zip, zip, ArchiveOptions.init) == Status.invalidArgument);
        }
        auto link = normalZip();
        const central = centralOffset(link);
        link[central + 5] = 3;
        link[central + 41] = 0xa0;
        assert(headerStatus(ArchiveFormat.zip, link, ArchiveOptions.init) == Status.invalidArgument);
    }

    @("Archive hard limits reject entry 10001, path byte 4097, and decoded byte 1073741825")
    unittest
    {
        auto fixture = new ubyte[10_001 * 512 + 1024];
        foreach (entry; 0 .. 10_001)
            tarHeader(fixture[entry * 512 .. (entry + 1) * 512], "file", '0', 0);
        ArchiveReader reader;
        assert(reader.open(ArchiveFormat.tar, ArchiveOptions.init, chunks(fixture, 113)).code == Status.ok);
        ubyte[32] storage;
        scope arena = RequestArena(storage[]);
        foreach (_; 0 .. 10_000)
        {
            assert(reader.next(arena).ok());
            assert(reader.read(null).code == Status.ok);
            assert(arena.reset() == Status.ok);
        }
        assert(reader.next(arena).error.code == Status.resourceExhausted && arena.stats().used == 0);
        assert(reader.close().code == Status.ok);

        const tooBig = tarFixture("large", '0', 1024UL * 1024 * 1024 + 1);
        assert(headerStatus(ArchiveFormat.tar, tooBig, ArchiveOptions.init) == Status.resourceExhausted);
        auto name = new ubyte[4097];
        name[] = 'p';
        assert(headerStatus(ArchiveFormat.tar, longTar(name), ArchiveOptions.init) == Status.resourceExhausted);
        assert(headerStatus(ArchiveFormat.tar, tarFixture("abc"), ArchiveOptions(10, 10, 2)) == Status
                .resourceExhausted);

        assert(reader.open(ArchiveFormat.tar, ArchiveOptions(10, 10, 10, true), chunks(tooBig, 1))
                .code == Status.unsupported);
    }

    @("archive_paths_zip: ZIP entries with traversal and drive prefixes are rejected before exposure")
    unittest
    {
        foreach (invalid; ["../yy", "xx/..", "C:/yy", "c:\\yy", "/x/yy"])
        {
            auto zip = namedZip("xx/yy");
            renameZip(zip, "xx/yy", invalid);
            assert(headerStatus(ArchiveFormat.zip, zip, ArchiveOptions.init) == Status.invalidArgument, invalid);
        }
        auto plain = namedZip("xx/yy");
        assert(headerStatus(ArchiveFormat.zip, plain, ArchiveOptions.init) == Status.ok);
    }

    @("archive_limit_boundaries: 4096 path bytes and exactly 1 GiB declared bytes are accepted")
    unittest
    {
        auto name = new ubyte[4096];
        name[] = 'p';
        assert(headerStatus(ArchiveFormat.tar, longTar(name), ArchiveOptions.init) == Status.ok);
        const exact = tarFixture("large", '0', 1024UL * 1024 * 1024);
        assert(headerStatus(ArchiveFormat.tar, exact, ArchiveOptions.init) == Status.ok);
        assert(headerStatus(ArchiveFormat.tar, tarFixture("ab"), ArchiveOptions(10, 10, 2)) == Status.ok);
    }

    @("Archive source and sink errors, reentry, stale aliases, and partial writes")
    unittest
    {
        callbackFailures();
        earlyZipSinkFailure();
    }
}
else
{
    @("Archives report unsupported without the selected libarchive provider")
    unittest
    {
        ArchiveReader reader;
        assert(reader.open(ArchiveFormat.zip, ArchiveOptions.init, chunks([], 1)).code == Status.unsupported);
    }
}

private class Destination
{
@safe:

    private ubyte[] output;
    private size_t used;

    this()
    {
        output = new ubyte[86_016];
    }

    Error append(scope const(ubyte)[] bytes) nothrow @nogc
    {
        if (bytes.length > output.length - used)
            return Error(Status.resourceExhausted, "test sink has no remaining capacity");
        output[used .. used + bytes.length] = bytes[];
        used += bytes.length;
        return Error.init;
    }

    ubyte[] bytes() nothrow @nogc
    {
        return output[0 .. used];
    }
}

private ArchiveSource chunks(const(ubyte)[] content, size_t limit)
{
    size_t cursor;
    return (scope ubyte[] output) @safe nothrow @nogc {
        size_t count = content.length - cursor;
        if (count > output.length)
            count = output.length;
        if (count > limit)
            count = limit;
        output[0 .. count] = content[cursor .. cursor + count];
        cursor += count;
        return Result!size_t(count);
    };
}

private void verifyArchive(ArchiveFormat format)
{
    auto destination = new Destination;
    ArchiveWriter writer;
    assert(writer.open(format, &destination.append).code == Status.ok);
    assert(writer.entry("folder/", 0, true).code == Status.ok);
    assert(writer.entry("folder/naïve.txt", 6, false).code == Status.ok);
    assert(writer.entry("folder/other", 0, false).code == Status.invalidArgument);
    assert(writer.write(cast(const(ubyte)[]) "sample!").code == Status.invalidArgument);
    assert(writer.write(cast(const(ubyte)[]) "sam").code == Status.ok);
    assert(writer.write(cast(const(ubyte)[]) "ple").code == Status.ok);
    assert(writer.close().code == Status.ok);
    assert(writer.close().code == Status.ok);

    ArchiveReader reader;
    assert(reader.open(format, ArchiveOptions.init, chunks(destination.bytes(), 7)).code == Status.ok);
    GC.collect();
    assertEntry(reader, true, "folder/", 0);
    assertEntry(reader, false, "folder/naïve.txt", 6);
    auto stale = reader;
    ubyte[16] store;
    scope arena = RequestArena(store[]);
    assert(reader.next(arena).error.code == Status.notFound);
    assert(reader.close().code == Status.ok);
    assert(stale.next(arena).error.code == Status.invalidArgument);
    assert(stale.close().code == Status.ok);
}

private void assertEntry(ref ArchiveReader reader, bool directory, scope const(char)[] path, ulong size)
{
    ubyte[1] tiny;
    scope shortArena = RequestArena(tiny[]);
    assert(reader.next(shortArena).error.code == Status.outOfMemory);
    ubyte[128] store;
    scope arena = RequestArena(store[]);
    const entry = reader.next(arena);
    assert(entry.ok(), entry.error.message);
    assert(entry.value.uncompressedBytes == size && entry.value.directory == directory);
    assert(arena.read(entry.value.path, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(bytes == cast(const(ubyte)[]) path);
        }) == Status.ok);
    assert(reader.next(arena).error.code == Status.conflict);
    auto body = new Destination;
    assert(reader.read(&body.append).code == Status.ok);
    assert(body.bytes() == cast(const(ubyte)[])(directory ? "" : "sample"));
}

private ubyte[] normalZip()
{
    auto destination = new Destination;
    ArchiveWriter writer;
    assert(writer.open(ArchiveFormat.zip, &destination.append).code == Status.ok);
    assert(writer.entry("plain", 0, false).code == Status.ok);
    assert(writer.close().code == Status.ok);
    return destination.bytes();
}

private ubyte[] namedZip(scope const(char)[] path)
{
    auto destination = new Destination;
    ArchiveWriter writer;
    assert(writer.open(ArchiveFormat.zip, &destination.append).code == Status.ok);
    assert(writer.entry(path, 0, false).code == Status.ok);
    assert(writer.close().code == Status.ok);
    return destination.bytes();
}

/// Rewrite every same-length copy of an entry name (local header and central directory).
private void renameZip(scope ubyte[] zip, scope const(char)[] from, scope const(char)[] to) pure nothrow @nogc
{
    assert(from.length == to.length);
    size_t copies;
    foreach (index; 0 .. zip.length - from.length + 1)
    {
        if (zip[index .. index + from.length] == cast(const(ubyte)[]) from)
        {
            zip[index .. index + to.length] = cast(const(ubyte)[]) to;
            ++copies;
        }
    }
    assert(copies >= 2);
}

private size_t centralOffset(scope const(ubyte)[] zip) pure nothrow @nogc
{
    const trailer = zip.length;
    const at = trailer - (22 - 16);
    return cast(size_t) zip[at] | cast(size_t) zip[at + 1] << 8 | cast(size_t) zip[at + 2] << 16 | cast(
            size_t) zip[at + 3] << 24;
}

private Status headerStatus(ArchiveFormat format, const(ubyte)[] bytes, ArchiveOptions options)
{
    ArchiveReader reader;
    assert(reader.open(format, options, chunks(bytes, 53)).code == Status.ok);
    scope (exit)
        assert(reader.close().code == Status.ok);
    ubyte[8192] storage;
    scope arena = RequestArena(storage[]);
    const entry = reader.next(arena);
    if (!entry.ok())
        assert(arena.stats().used == 0);
    return entry.error.code;
}

private void octal(scope ubyte[] field, ulong number) pure nothrow @nogc
{
    field[] = '0';
    field[$ - 1] = '\0';
    foreach_reverse (index; 0 .. field[0 .. $ - 1].length)
    {
        field[index] = cast(ubyte)('0' + number % 8);
        number /= 8;
    }
    assert(number == 0);
}

private void tarHeader(scope ubyte[] bytes, scope const(char)[] path, char kind, ulong size) pure nothrow @nogc
{
    bytes[] = 0;
    bytes[0 .. path.length] = cast(const(ubyte)[]) path;
    octal(bytes[100 .. 108], 0x1a4);
    octal(bytes[108 .. 116], 0);
    octal(bytes[116 .. 124], 0);
    octal(bytes[124 .. 136], size);
    octal(bytes[136 .. 148], 0);
    bytes[148 .. 156] = ' ';
    bytes[156] = kind;
    bytes[257 .. 265] = cast(const(ubyte)[]) "ustar\00000";
    if (kind == '1' || kind == '2')
        bytes[157 .. 161] = cast(const(ubyte)[]) "link";
    ulong checksum;
    foreach (byte_; bytes)
        checksum += byte_;
    octal(bytes[148 .. 155], checksum);
}

private ubyte[] tarFixture(scope const(char)[] path, char type = '0', ulong length = 0)
{
    auto bytes = new ubyte[1536];
    tarHeader(bytes[0 .. 512], path, type, length);
    return bytes;
}

private ubyte[] longTar(scope const(ubyte)[] name)
{
    const blocks = (name.length + 512) / 512;
    const next = (blocks + 1) * 512;
    auto tar = new ubyte[next + 1536];
    tarHeader(tar[0 .. 512], "././@LongLink", 'L', name.length + 1);
    tar[512 .. 512 + name.length] = name;
    tarHeader(tar[next .. next + 512], "fallback", '0', 0);
    return tar;
}

private void callbackFailures()
{
    ArchiveReader reader;
    auto failed = (scope ubyte[] writable) @safe nothrow @nogc {
        assert(writable.length != 0);
        assert(reader.close().code == Status.conflict);
        return Result!size_t(0, Error(Status.cancelled, "source cancelled"));
    };
    assert(reader.open(ArchiveFormat.tar, ArchiveOptions.init, failed).code == Status.ok);
    ubyte[32] storage;
    scope arena = RequestArena(storage[]);
    const stopped = reader.next(arena);
    assert(stopped.error.code == Status.cancelled && stopped.error.message == "source cancelled");
    assert(reader.next(arena).error.code == Status.invalidArgument);
    assert(reader.close().code == Status.ok);

    auto destination = new Destination;
    ArchiveWriter writer;
    assert(writer.open(ArchiveFormat.zip, &destination.append).code == Status.ok);
    assert(writer.entry("abc\0def", 0, false).code == Status.invalidArgument);
    assert(writer.entry("part", 2, false).code == Status.ok);
    assert(writer.write(cast(const(ubyte)[]) "x").code == Status.ok);
    assert(writer.close().code == Status.invalidArgument);
    assert(writer.close().code == Status.ok);

    bool called;
    assert(writer.open(ArchiveFormat.tar, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(bytes.length != 0);
            assert(writer.close().code == Status.conflict);
            called = true;
            return Error(Status.ioError, "sink closed");
        }).code == Status.ok);
    assert(writer.entry("good", 0, false).code == Status.ok);
    assert(writer.close().code == Status.ioError && called);
}

private void earlyZipSinkFailure()
{
    auto bytes = new ubyte[400_000];
    uint state = 0x42e892b0;
    foreach (ref value; bytes)
    {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        value = cast(ubyte) state;
    }
    ArchiveWriter writer;
    uint calls;
    const sink = (scope const(ubyte)[] output) @safe nothrow @nogc {
        assert(output.length != 0);
        ++calls;
        return Error(Status.cancelled, "ZIP sink cancelled");
    };
    assert(writer.open(ArchiveFormat.zip, sink).code == Status.ok);
    assert(writer.entry("large", bytes.length, false).code == Status.ok);
    const failed = writer.write(bytes);
    assert(failed.code == Status.cancelled && calls == 1);
    assert(writer.close().code == Status.cancelled && calls == 1);
}
