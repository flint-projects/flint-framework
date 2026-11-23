module app;

import codec_replay : ArchiveMemory, archiveReplay, benchmark, require;
import flint.arena : RequestArena, Result, Status;
import flint.engine.codec : ArchiveFormat, ArchiveOptions, ArchiveReader, ArchiveWriter, Codec,
    CodecOptions, Decoder, Encoder, Finish;

@safe:

private size_t transform(Stream)(ref Stream stream, scope const(ubyte)[] input, scope ubyte[] output) nothrow @nogc
{
    size_t consumed;
    size_t produced;
    for (;;)
    {
        const step = stream.process(input[consumed .. $], output[produced .. $], Finish.end);
        require(step.ok());
        consumed += step.value.consumed;
        produced += step.value.produced;
        if (step.value.finished)
            break;
        require(step.value.consumed || step.value.produced);
    }
    require(consumed == input.length);
    return produced;
}

private size_t run(Codec codec)(scope const(ubyte)[] input, scope ubyte[] wire, scope ubyte[] output) nothrow @nogc
{
    const options = CodecOptions(codec);
    Encoder writer;
    require(writer.open(options).code == Status.ok);
    const size = transform(writer, input, wire);
    require(writer.close().code == Status.ok);

    Decoder decoder;
    require(decoder.open(options).code == Status.ok);
    require(transform(decoder, wire[0 .. size], output) == input.length);
    require(decoder.close().code == Status.ok);
    return size;
}

private size_t archive(ArchiveFormat format)(scope const(ubyte)[] input, ArchiveMemory memory) nothrow @nogc
{
    ArchiveWriter writer;
    require(writer.open(format, &memory.save).code == Status.ok);
    require(writer.entry("fixture.bin", input.length, false).code == Status.ok);
    require(writer.write(input).code == Status.ok);
    require(writer.close().code == Status.ok);

    ubyte[32] pathBuffer;
    scope arena = RequestArena(pathBuffer[]);
    ArchiveReader reader;
    require(reader.open(format, ArchiveOptions.init, &memory.source).code == Status.ok);
    const entry = reader.next(arena);
    require(entry.ok() && !entry.value.directory && entry.value.uncompressedBytes == input.length);
    require(arena.read(entry.value.path, (scope const(ubyte)[] name) @safe nothrow @nogc {
            require(name == cast(const(ubyte)[]) "fixture.bin");
        }) == Status.ok);
    require(reader.read(&memory.collect).code == Status.ok && reader.next(arena).error.code == Status.notFound);
    require(reader.close().code == Status.ok);
    return memory.encoded;
}

private bool selected(Codec codec) nothrow @nogc
{
    Encoder stream;
    const result = stream.open(CodecOptions(codec));
    if (result.code == Status.unsupported)
        return false;
    require(result.code == Status.ok && stream.close().code == Status.ok);
    return true;
}

private bool archivesSelected() nothrow @nogc
{
    ArchiveReader stream;
    const source = delegate(scope ubyte[]) @safe nothrow @nogc { return Result!size_t.init; };
    const result = stream.open(ArchiveFormat.zip, ArchiveOptions.init, source);
    if (result.code == Status.unsupported)
        return false;
    require(result.code == Status.ok && stream.close().code == Status.ok);
    return true;
}

void main(string[] args)
{
    require(args.length == 1 || (args.length == 2 && args[1] == "--measure"));
    const measure = args.length == 2;
    bool ran;
    static foreach (index, codec; [Codec.gzip, Codec.zstd, Codec.brotli])
    {
        if (selected(codec))
        {
            benchmark(["gzip", "zstd", "brotli"][index], &run!codec, measure);
            ran = true;
        }
    }
    if (archivesSelected())
    {
        archiveReplay("zip", &archive!(ArchiveFormat.zip), measure);
        archiveReplay("tar", &archive!(ArchiveFormat.tar), measure);
        ran = true;
    }
    require(ran);
}
