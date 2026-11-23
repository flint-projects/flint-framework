/// Thread-local stream ownership, exact progress and cumulative output limits.
module flint.engine.codec.runtime;

import core.atomic : atomicLoad, cas;
import flint.arena : Error, Result, Status;
import flint.engine.codec.types : Codec, CodecOptions, CodecStep, Finish;
import flint.engine.codec.ffi.shim : Allocations, NativeCodec, NativeStatus, NativeStep, disjoint, nativeError;

@safe:
nothrow @nogc:

package(flint.engine.codec) struct Token
{
    size_t index;
    ulong generation;
}

private shared ulong lastGeneration;

package(flint.engine.codec) ulong nextGeneration()
{
    for (;;)
    {
        const observed = atomicLoad(lastGeneration);
        if (observed == ulong.max)
            return 0;
        if (cas(&lastGeneration, observed, observed + 1))
            return observed + 1;
    }
}

private enum Phase : ubyte
{
    open,
    ending,
    finished,
    failed
}

private struct Slot
{
nothrow @nogc:

    ulong generation;
    NativeCodec codec;
    CodecOptions options;
    ulong input;
    ulong output;
    bool encode;
    Phase phase;

    ulong remaining(ulong actualInput) const
    {
        ulong limit = options.maxOutputBytes;
        if (!encode)
        {
            const denominator = actualInput < 1024 ? 1024 : actualInput;
            if (denominator <= ulong.max / options.maxExpansionRatio)
            {
                const ratioLimit = denominator * options.maxExpansionRatio;
                if (ratioLimit < limit)
                    limit = ratioLimit;
            }
        }
        return limit - output;
    }

    Result!CodecStep fail(Error error)
    {
        phase = Phase.failed;
        codec.close();
        return Result!CodecStep(CodecStep.init, error);
    }

    Result!CodecStep advance(scope const(ubyte)[] inputBytes, scope ubyte[] outputBytes, Finish finish)
    {
        const capacity = remaining(input);
        if (capacity == 0)
            return inspectTrailer(inputBytes, outputBytes, finish);

        const wanted = capacity < outputBytes.length ? cast(size_t) capacity : outputBytes.length;
        return settle(codec.step(inputBytes, outputBytes[0 .. wanted], finish), inputBytes.length, finish);
    }

    private Result!CodecStep inspectTrailer(scope const(ubyte)[] inputBytes, scope ubyte[] outputBytes, Finish finish)
    {
        ubyte[1] probe;
        const progress = codec.step(inputBytes, probe[], finish);
        if (progress.status >= NativeStatus.ok && progress.produced
                && (progress.consumed > ulong.max - input || progress.produced > remaining(input + progress.consumed)))
            return fail(limitError);

        const outcome = settle(progress, inputBytes.length, finish);
        if (outcome.ok() && progress.produced)
            outputBytes[0] = probe[0];
        return outcome;
    }

    private Result!CodecStep settle(NativeStep progress, size_t supplied, Finish finish)
    {
        if (progress.status < NativeStatus.ok)
            return fail(nativeError(progress.status));
        if (progress.consumed > ulong.max - input)
            return fail(limitError);
        input += progress.consumed;
        if (progress.produced > remaining(input))
            return fail(limitError);
        output += progress.produced;

        const finished = progress.status == NativeStatus.finished;
        if (finished && progress.consumed != supplied)
            return fail(Error(Status.invalidArgument, "trailing bytes or concatenated codec frame"));
        if (finish == Finish.end && progress.status == NativeStatus.needInput)
            return fail(Error(Status.invalidArgument, "truncated codec stream"));
        if (finished)
            phase = Phase.finished;
        return Result!CodecStep(CodecStep(progress.consumed, progress.produced, finished));
    }
}

private enum limitError = Error(Status.resourceExhausted, "codec output or expansion budget exceeded");
private enum wrongState = Error(Status.invalidArgument, "codec is closed, finished or owned by another thread");

private Slot[128] streams;

package(flint.engine.codec) Error openStream(ref Token owner, CodecOptions options, bool encode)
{
    if (live(owner))
        return Error(Status.conflict, "codec stream is already open");
    if (options.codec > Codec.max || options.maxOutputBytes == 0 || options.maxExpansionRatio == 0)
        return Error(Status.invalidArgument, "invalid codec options");
    foreach (index, ref slot; streams)
    {
        if (slot.generation != 0)
            continue;
        const generation = nextGeneration();
        if (generation == 0)
            break;

        const failure = slot.codec.open(options.codec, encode, options.level);
        if (failure.code != Status.ok)
            return failure;
        slot.generation = generation;
        slot.options = options;
        slot.encode = encode;
        owner = Token(index, generation);
        return Error.init;
    }
    return Error(Status.resourceExhausted, "codec stream slots exhausted");
}

package(flint.engine.codec) Result!CodecStep processStream(Token owner, scope const(ubyte)[] input,
        scope ubyte[] output, Finish finish)
{
    if (!live(owner))
        return Result!CodecStep(CodecStep.init, wrongState);
    ref Slot slot = streams[owner.index];
    if (slot.phase >= Phase.finished || finish > Finish.max)
        return Result!CodecStep(CodecStep.init, wrongState);
    if (slot.phase == Phase.ending && finish != Finish.end)
        return Result!CodecStep(CodecStep.init, Error(Status.invalidArgument, "codec frame is already ending"));
    if (!disjoint(input, output))
        return Result!CodecStep(CodecStep.init, Error(Status.invalidArgument, "codec input and output overlap"));
    if (!output.length)
        return Result!CodecStep.init;
    if (finish == Finish.end)
        slot.phase = Phase.ending;
    return slot.advance(input, output, finish);
}

package(flint.engine.codec) Allocations streamAllocations(Token owner)
{
    return live(owner) ? streams[owner.index].codec.allocations() : Allocations.init;
}

package(flint.engine.codec) Error closeStream(ref Token owner)
{
    if (live(owner))
    {
        streams[owner.index].codec.close();
        streams[owner.index] = Slot.init;
    }
    owner = Token.init;
    return Error.init;
}

private bool live(Token owner)
{
    return owner.generation != 0 && owner.index < streams.length && streams[owner.index].generation == owner.generation;
}

static ~this()
{
    foreach (ref slot; streams)
        slot.codec.close();
}
