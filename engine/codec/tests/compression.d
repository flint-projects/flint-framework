module flint.codec.compression_tests;

import core.memory : GC;
import core.thread : Thread;
import flint.arena : Result, Status;
import flint.codec : Codec, CodecOptions, CodecStep, Decoder, Encoder, Finish;
import std.stdio : writefln;
import flint.codec.runtime : Token, closeStream, openStream, processStream, streamAllocations;

@safe:

private immutable Codec[3] codecs = [Codec.gzip, Codec.zstd, Codec.brotli];

private bool selected(Codec codec) pure nothrow @nogc
{
    final switch (codec)
    {
    case Codec.gzip:
        version (FlintNativeZlib)
            return true;
        else
            return false;
    case Codec.zstd:
        version (FlintNativeZstd)
            return true;
        else
            return false;
    case Codec.brotli:
        version (FlintNativeBrotli)
            return true;
        else
            return false;
    }
}

private size_t transform(Stream)(ref Stream stream, scope const(ubyte)[] input, scope ubyte[] output,
        size_t inputSize, size_t outputSize)
{
    size_t consumed;
    size_t produced;
    size_t turns;
    while (true)
    {
        const take = input.length - consumed < inputSize ? input.length - consumed : inputSize;
        const reserve = output.length - produced < outputSize ? output.length - produced : outputSize;
        const finish = consumed + take == input.length ? Finish.end : Finish.more;
        const step = stream.process(input[consumed .. consumed + take], output[produced .. produced + reserve], finish);
        assert(step.ok(), step.error.message);
        assert(step.value.consumed <= take && step.value.produced <= reserve);
        consumed += step.value.consumed;
        produced += step.value.produced;
        if (step.value.finished)
        {
            assert(consumed == input.length);
            return produced;
        }
        assert(step.value.consumed || step.value.produced, "stream made no progress");
        assert(++turns < 2 * (input.length + output.length + 1));
    }
}

private size_t encode(Codec codec, scope const(ubyte)[] input, scope ubyte[] output,
        size_t inputSize = size_t.max, size_t outputSize = size_t.max)
{
    Encoder encoder;
    assert(encoder.open(CodecOptions(codec, 3, 72 * 1024 * 1024)).code == Status.ok);
    scope (exit)
        encoder.close();
    return transform(encoder, input, output, inputSize, outputSize);
}

private void roundtrip(Codec codec, scope const(ubyte)[] expected, scope ubyte[] encoded, scope ubyte[] output)
{
    const size = encode(codec, expected, encoded, 512 * 1024, 512 * 1024);
    Decoder decoder;
    scope (exit)
        decoder.close();
    auto options = CodecOptions(codec, 3, 64 * 1024 * 1024, uint.max);
    assert(decoder.open(options).code == Status.ok);
    const decoded = transform(decoder, encoded[0 .. size], output, 512 * 1024, 512 * 1024);
    assert(decoded == expected.length && output[0 .. decoded] == expected);
}

private void random(uint seed, scope ubyte[] bytes) pure nothrow @nogc
{
    foreach (ref byte_; bytes)
    {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        byte_ = cast(ubyte) seed;
    }
}

@("Actual gzip, Zstandard and Brotli round trips through 64 MiB")
unittest
{
    enum maximum = 64 * 1024 * 1024;
    auto input = new ubyte[maximum];
    auto output = new ubyte[maximum + 1];
    auto encoded = new ubyte[72 * 1024 * 1024];
    random(0x79274acb, input);
    foreach (codec; codecs)
    {
        if (!selected(codec))
            continue;
        foreach (length; [0, 1, 65_536, maximum])
            roundtrip(codec, input[0 .. length], encoded, output);
    }
    input[] = 0x37;
    foreach (codec; codecs)
    {
        if (selected(codec))
            roundtrip(codec, input, encoded, output);
    }
}

@("Every 0..257 input and output capacity, short flush and backpressure")
unittest
{
    ubyte[643] payload;
    random(0x24156a8d, payload[]);
    foreach (codec; codecs)
    {
        if (!selected(codec))
            continue;
        ubyte[2048] wire;
        ubyte[644] decoded;
        foreach (size; 1 .. 258)
        {
            const capacity = 258 - size;
            const encoded = encode(codec, payload[], wire[], size, capacity);
            Decoder reader;
            assert(reader.open(CodecOptions(codec)).code == Status.ok);
            const none = reader.process(wire[0 .. encoded], decoded[0 .. 0], Finish.end);
            assert(none.ok() && none.value == CodecStep.init);
            assert(transform(reader, wire[0 .. encoded], decoded[], capacity, size) == payload.length);
            assert(decoded[0 .. payload.length] == payload[]);
            reader.close();
        }
        flushRoundtrip(codec, payload[], wire[], decoded[]);
    }
}

private void flushRoundtrip(Codec codec, scope const(ubyte)[] payload, scope ubyte[] wire, scope ubyte[] decoded)
{
    Encoder writer;
    assert(writer.open(CodecOptions(codec)).code == Status.ok);
    scope (exit)
        writer.close();
    size_t used;
    size_t written;
    const half = payload.length / 2;
    bool drained;
    foreach (_; 0 .. wire.length)
    {
        const report = writer.process(payload[used .. half], wire[written .. written + 1], Finish.flush);
        assert(report.ok(), report.error.message);
        assert(!report.value.finished);
        used += report.value.consumed;
        written += report.value.produced;
        if (report.value == CodecStep.init)
        {
            drained = true;
            break;
        }
    }
    assert(used == half && drained && written != 0);
    written += transform(writer, payload[half .. $], wire[written .. $], 73, 53);
    Decoder reader;
    assert(reader.open(CodecOptions(codec)).code == Status.ok);
    scope (exit)
        reader.close();
    assert(transform(reader, wire[0 .. written], decoded, 7, 51) == payload.length);
    assert(decoded[0 .. payload.length] == payload);
}

private Status reject(CodecOptions options, scope const(ubyte)[] bytes, scope ubyte[] output)
{
    Decoder decoder;
    assert(decoder.open(options).code == Status.ok);
    scope (exit)
        decoder.close();

    size_t at;
    size_t produced;
    foreach (_; 0 .. 100)
    {
        const report = decoder.process(bytes[at .. $], output[produced .. $], Finish.end);
        if (!report.ok())
        {
            assert(decoder.process(null, output, Finish.end).error.code == Status.invalidArgument);
            return report.error.code;
        }
        if (report.value.finished)
            return Status.ok;
        assert(report.value.consumed || report.value.produced);
        at += report.value.consumed;
        produced += report.value.produced;
    }
    assert(0, "provider never reported the end of malformed data");
}

@("Truncation, invalid headers, checksums, trailing frames and hard budgets")
unittest
{
    ubyte[16_384] repetitive;
    ubyte[16_385] output;
    ubyte[2048] wire;
    foreach (codec; codecs)
    {
        if (!selected(codec))
            continue;
        const bytes = encode(codec, repetitive[], wire[]);
        const options = CodecOptions(codec);
        foreach (length; [1, bytes / 2, bytes - 1])
            assert(reject(options, wire[0 .. length], output[]) == Status.invalidArgument);

        wire[bytes] = 0xff;
        assert(reject(options, wire[0 .. bytes + 1], output[]) == Status.invalidArgument);

        wire[bytes .. bytes * 2] = wire[0 .. bytes];
        assert(reject(options, wire[0 .. 2 * bytes], output[]) == Status.invalidArgument);
        const saved = wire[0];
        wire[0] = codec == Codec.brotli ? 0x11 : 0;
        assert(reject(options, wire[0 .. bytes], output[]) == Status.invalidArgument);
        wire[0] = saved;

        if (codec != Codec.brotli)
        {
            const checksum = codec == Codec.gzip ? bytes - 8 : bytes - 1;
            wire[checksum] ^= 1;
            assert(reject(options, wire[0 .. bytes], output[]) == Status.invalidArgument);
            wire[checksum] ^= 1;
        }
        output[] = 0xff;
        const small = CodecOptions(codec, 3, 31, uint.max);
        assert(reject(small, wire[0 .. bytes], output[]) == Status.resourceExhausted);
        assert(output[30] == 0 && output[31] == 0xff);
        const ratio = CodecOptions(codec, 3, output.length, 1);
        assert(reject(ratio, wire[0 .. bytes], output[]) == Status.resourceExhausted);
        assert(output[1023] == 0 && output[1024] == 0xff);
    }
    if (selected(Codec.zstd))
    {
        enum window = cast(immutable(ubyte)[]) "\x28\xb5\x2f\xfd\x00\x78";
        assert(reject(CodecOptions(Codec.zstd), window, output[]) == Status.resourceExhausted);
        enum dictionary = cast(immutable(ubyte)[]) "\x28\xb5\x2f\xfd\x01\x00\x01";
        assert(reject(CodecOptions(Codec.zstd), dictionary, output[]) == Status.unsupported);
    }
}

@("Generation aliases, cross-thread ownership, unsupported providers and overlapping buffers")
@system unittest
{
    ubyte[128] buffer;
    foreach (codec; codecs)
    {
        Encoder stream;
        if (!selected(codec))
        {
            assert(stream.open(CodecOptions(codec)).code == Status.unsupported);
            continue;
        }
        assert(stream.open(CodecOptions(codec, int.max)).code == Status.invalidArgument);
        assert(stream.open(CodecOptions(codec)).code == Status.ok);
        assert(stream.open(CodecOptions(codec)).code == Status.conflict);
        assert(stream.process(buffer[0 .. 4], buffer[1 .. $], Finish.more).error.code == Status.invalidArgument);
        auto copy = stream;
        Status other;
        auto thread = new Thread(() {
            ubyte[64] bytes;
            other = copy.process(null, bytes[], Finish.end).error.code;
        });
        thread.start();
        thread.join();
        assert(other == Status.invalidArgument);
        assert(stream.process(null, buffer[], Finish.end).value.finished);
        assert(copy.process(null, buffer[], Finish.end).error.code == Status.invalidArgument);
        assert(copy.close().code == Status.ok);
        assert(copy.close().code == Status.ok);
        assert(stream.process(null, buffer[], Finish.end).error.code == Status.invalidArgument);
        assert(stream.open(CodecOptions(codec)).code == Status.ok);
        assert(copy.process(null, buffer[], Finish.end).error.code == Status.invalidArgument);
        assert(stream.close().code == Status.ok);
    }
}

@("Native allocation counts distinguish startup, lazy initialization and steady state")
unittest
{
    ubyte[8192] payload;
    ubyte[8192] output;
    foreach (codec; codecs)
    {
        if (!selected(codec))
            continue;
        Token token;
        assert(openStream(token, CodecOptions(codec), true).code == Status.ok);
        const startup = streamAllocations(token);
        assert(startup.calls > 0 && startup.liveBytes > 0);
        const before = GC.stats().allocatedInCurrentThread;
        foreach (_; 0 .. 16)
            assert(processStream(token, payload[], output[], Finish.more).ok());
        const initialized = streamAllocations(token);
        assert(initialized.calls >= startup.calls && initialized.peakBytes >= initialized.liveBytes);
        foreach (_; 0 .. 32)
            assert(processStream(token, payload[], output[], Finish.more).ok());
        const steady = streamAllocations(token);
        assert(steady.peakBytes <= 512 * 1024 * 1024 && steady.calls >= initialized.calls);
        assert(GC.stats().allocatedInCurrentThread == before);
        writefln!"%s native C allocations open=%d initialized=%d steady=%d peak=%d D process bytes=0"(codec,
                startup.calls, initialized.calls, steady.calls, steady.peakBytes);
        closeStream(token);
        assert(streamAllocations(token).calls == 0);
    }
}

@("Deterministic streaming mutation corpus for every selected decoder")
unittest
{
    ubyte[192] payload;
    random(0x28f136c5, payload[]);
    foreach (codec; codecs)
    {
        if (!selected(codec))
            continue;
        ubyte[512] fixture;
        const encoded = encode(codec, payload[], fixture[]);
        foreach (trial; 0U .. 320U)
        {
            ubyte[512] bytes = fixture;
            const size = fuzzInput(bytes[], encoded, trial);
            replayMutation(codec, bytes[0 .. size], trial);
        }
    }
}

private size_t fuzzInput(scope ubyte[] bytes, size_t length, uint trial) pure nothrow @nogc
{
    switch (trial % 5)
    {
    case 0:
        return trial % length;
    case 1:
        bytes[(trial * 31) % length] ^= cast(ubyte) trial;
        return length;
    case 2:
        random(0x73c79500 + trial, bytes);
        return trial % bytes.length;
    case 3:
        bytes[length] = cast(ubyte) trial;
        return length + 1;
    default:
        return length;
    }
}

private void replayMutation(Codec codec, scope const(ubyte)[] bytes, uint trial)
{
    Decoder decoder;
    assert(decoder.open(CodecOptions(codec, 3, 2048, 2)).code == Status.ok);
    scope (exit)
        decoder.close();
    size_t offset;
    size_t total;
    ubyte[257] workspace;
    assert(decoder.process(bytes, workspace[0 .. 0], Finish.end).ok());
    foreach (turn; 0 .. 1024)
    {
        size_t input = (trial * 17 + turn * 3) % 257 + 1;
        const output = (trial * 73 + turn * 5) % 257 + 1;
        if (input > bytes.length - offset)
            input = bytes.length - offset;
        const finish = offset + input == bytes.length ? Finish.end : Finish.more;
        const step = decoder.process(bytes[offset .. offset + input], workspace[0 .. output], finish);
        if (!step.ok())
        {
            assert(step.error.code == Status.invalidArgument
                    || step.error.code == Status.resourceExhausted || step.error.code == Status.unsupported);
            return;
        }
        assert(step.value.consumed <= input && step.value.produced <= output);
        total += step.value.produced;
        offset += step.value.consumed;
        assert(total <= 2048);
        if (step.value.finished)
            return;
        assert(step.value.consumed || step.value.produced);
    }
    assert(0, "decode fixture failed to terminate");
}

@("corruption_release: a fatal decode error frees the provider state before close")
unittest
{
    ubyte[4096] repetitive;
    ubyte[1024] wire;
    ubyte[8192] output;
    foreach (codec; codecs)
    {
        if (!selected(codec))
            continue;
        const bytes = encode(codec, repetitive[], wire[]);
        foreach (length; [1, bytes / 2, bytes - 1])
        {
            Token token;
            assert(openStream(token, CodecOptions(codec), false).code == Status.ok);
            assert(streamAllocations(token).liveBytes > 0);
            const failed = processStream(token, wire[0 .. length], output[], Finish.end);
            assert(failed.error.code == Status.invalidArgument);
            const released = streamAllocations(token);
            assert(released.calls == 0 && released.liveBytes == 0);
            assert(processStream(token, wire[0 .. bytes], output[], Finish.end).error.code == Status.invalidArgument);
            assert(closeStream(token).code == Status.ok);
            assert(closeStream(token).code == Status.ok);
        }
    }
}

@("decoder_state_calls: decoders refuse work after finish, failure, close and generation reuse")
unittest
{
    ubyte[64] payload;
    random(0x5a17c3e1, payload[]);
    ubyte[512] wire;
    ubyte[128] output;
    foreach (codec; codecs)
    {
        if (!selected(codec))
            continue;
        const bytes = encode(codec, payload[], wire[]);
        Decoder decoder;
        assert(decoder.open(CodecOptions(codec)).code == Status.ok);
        assert(decoder.open(CodecOptions(codec)).code == Status.conflict);
        const done = decoder.process(wire[0 .. bytes], output[], Finish.end);
        assert(done.ok() && done.value.finished && done.value.produced == payload.length);
        assert(output[0 .. payload.length] == payload[]);
        assert(decoder.process(null, output[], Finish.end).error.code == Status.invalidArgument);
        assert(decoder.process(wire[0 .. bytes], output[], Finish.more).error.code == Status.invalidArgument);
        auto stale = decoder;
        assert(decoder.close().code == Status.ok);
        assert(decoder.close().code == Status.ok);
        assert(decoder.process(wire[0 .. bytes], output[], Finish.end).error.code == Status.invalidArgument);
        assert(decoder.open(CodecOptions(codec)).code == Status.ok);
        assert(stale.process(wire[0 .. bytes], output[], Finish.end).error.code == Status.invalidArgument);
        assert(stale.close().code == Status.ok);
        const again = decoder.process(wire[0 .. bytes], output[], Finish.end);
        assert(again.ok() && again.value.finished, "a stale close must not release the reopened stream");
        assert(decoder.close().code == Status.ok);
    }
}

@("zero_input_chunk: empty input steps terminate and leave the stream usable")
unittest
{
    ubyte[300] payload;
    random(0x0badf00d, payload[]);
    ubyte[1024] wire;
    ubyte[512] decoded;
    foreach (codec; codecs)
    {
        if (!selected(codec))
            continue;
        Encoder encoder;
        assert(encoder.open(CodecOptions(codec)).code == Status.ok);
        foreach (_; 0 .. 1000)
        {
            const idle = encoder.process(null, wire[], Finish.more);
            assert(idle.ok() && !idle.value.finished && idle.value.consumed == 0);
            assert(idle.value.produced <= wire.length);
        }
        encoder.close();
        const bytes = encode(codec, payload[], wire[]);
        Decoder decoder;
        assert(decoder.open(CodecOptions(codec)).code == Status.ok);
        scope (exit)
            decoder.close();
        foreach (_; 0 .. 1000)
        {
            const idle = decoder.process(null, decoded[], Finish.more);
            assert(idle.ok() && idle.value == CodecStep.init);
        }
        assert(transform(decoder, wire[0 .. bytes], decoded[], 0 + 31, 17) == payload.length);
        assert(decoded[0 .. payload.length] == payload[]);
    }
}
