module flint.actuator.otlp;

import flint.actuator.metrics : Metrics, Snapshot, saturated;
import flint.actuator.spans : SpanRecord, hasBytes;
import flint.actuator.text : TextWriter;
import flint.arena : Buffer, Error, RequestArena, Result, Status, Text;
import flint.serde : DecodeOptions, UnknownFields, decodeInto;

@safe:

private alias Writer = TextWriter;
private alias Record = SpanRecord;

private void stamp(ref TextWriter writer, ref scope RequestArena arena, ulong value) nothrow @nogc
{
    writer.put(arena, "\"");
    writer.integer(arena, value);
    writer.put(arena, "\"");
}

private void attributeHeader(ref TextWriter writer, ref scope RequestArena arena, string service) nothrow @nogc
{
    writer.put(arena, "{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":");
    writer.quoted(arena, service);
    writer.put(arena, "}}]},");
}

private void spanJson(ref Writer outp, ref scope RequestArena dst, scope const ref Record sp, ulong epoch) nothrow @nogc
{
    outp.put(dst, "{\"traceId\":\"");
    outp.hex(dst, sp.context.traceId[]);
    outp.put(dst, "\",\"spanId\":\"");
    outp.hex(dst, sp.context.spanId[]);
    if (hasBytes(sp.parent[]))
    {
        outp.put(dst, "\",\"parentSpanId\":\"");
        outp.hex(dst, sp.parent[]);
    }
    outp.put(dst, "\",\"name\":");
    outp.quoted(dst, sp.name[0 .. sp.bytes]);
    outp.put(dst, ",\"kind\":1,\"startTimeUnixNano\":");
    stamp(outp, dst, saturated(epoch, cast(ulong) sp.start));
    outp.put(dst, ",\"endTimeUnixNano\":");
    stamp(outp, dst, saturated(epoch, cast(ulong) sp.finish));
    outp.put(dst, ",\"flags\":");
    outp.integer(dst, sp.context.flags);
    outp.put(dst, sp.failed ? ",\"status\":{\"code\":2}}" : ",\"status\":{\"code\":1}}");
}

package(flint.actuator) Result!Buffer traces(scope const(SpanRecord)[] records, string service,
        ulong offset, ref scope RequestArena arena) nothrow @nogc
{
    TextWriter writer;
    writer.open(arena);
    writer.put(arena, "{\"resourceSpans\":[");
    attributeHeader(writer, arena, service);
    writer.put(arena, "\"scopeSpans\":[{\"scope\":{\"name\":\"flint.actuator\"},\"spans\":[");
    foreach (index, ref span; records)
    {
        if (index != 0)
            writer.put(arena, ",");
        spanJson(writer, arena, span, offset);
    }
    writer.put(arena, "]}]}]}");
    return Result!Buffer(writer.bytes, writer.error);
}

private void histogram(ref TextWriter writer, ref scope RequestArena arena, scope const ref Snapshot row) nothrow @nogc
{
    ulong total;
    foreach (amount; row.sample.buckets[0 .. row.bounds.length + 1])
        total = saturated(total, amount);
    writer.put(arena, ",\"count\":");
    stamp(writer, arena, total);
    writer.put(arena, ",\"sum\":");
    writer.number(arena, row.sample.sum);
    writer.put(arena, ",\"explicitBounds\":[");
    foreach (index, value; row.bounds)
    {
        if (index != 0)
            writer.put(arena, ",");
        writer.number(arena, value);
    }
    writer.put(arena, "],\"bucketCounts\":[");
    foreach (index, amount; row.sample.buckets[0 .. row.bounds.length + 1])
    {
        if (index != 0)
            writer.put(arena, ",");
        stamp(writer, arena, amount);
    }
    writer.put(arena, "]");
}

private void metricJson(ref TextWriter writer, ref scope RequestArena arena, scope const ref Snapshot row,
        ulong begin, ulong end) nothrow @nogc
{
    writer.put(arena, "{\"name\":");
    writer.quoted(arena, row.name);
    if (row.help.length != 0)
    {
        writer.put(arena, ",\"description\":");
        writer.quoted(arena, row.help);
    }
    if (row.histogram)
        writer.put(arena, ",\"histogram\":{\"aggregationTemporality\":2,\"dataPoints\":[{");
    else
        writer.put(arena, ",\"sum\":{\"aggregationTemporality\":2,\"isMonotonic\":true,\"dataPoints\":[{");
    writer.put(arena, "\"startTimeUnixNano\":");
    stamp(writer, arena, begin);
    writer.put(arena, ",\"timeUnixNano\":");
    stamp(writer, arena, end);
    if (row.histogram)
        histogram(writer, arena, row);
    else
    {
        writer.put(arena, ",\"asInt\":");
        stamp(writer, arena, row.sample.counter < long.max ? row.sample.counter : long.max);
    }
    writer.put(arena, "}]}}");
}

package(flint.actuator) Result!Buffer measurements(Metrics metrics, uint start, uint count,
        string service, ulong from, ulong until, ref scope RequestArena arena) nothrow @nogc
{
    TextWriter writer;
    writer.open(arena);
    writer.put(arena, "{\"resourceMetrics\":[");
    attributeHeader(writer, arena, service);
    writer.put(arena, "\"scopeMetrics\":[{\"scope\":{\"name\":\"flint.actuator\"},\"metrics\":[");
    foreach (index; 0 .. count)
    {
        if (index != 0)
            writer.put(arena, ",");
        const row = metrics.snapshot(start + index);
        metricJson(writer, arena, row, from, until);
    }
    writer.put(arena, "]}]}]}");
    return Result!Buffer(writer.bytes, writer.error);
}

private struct Partial(T)
{
    T rejectedSpans;
    T rejectedDataPoints;
    Text errorMessage;
}

private struct Reply(T)
{
    Partial!T partialSuccess;
}

package(flint.actuator) Result!ulong acknowledged(scope const(ubyte)[] input, bool trace) nothrow @nogc
{
    ubyte[16_384] scratch;
    scope RequestArena arena = RequestArena(scratch[]);
    auto options = DecodeOptions.init;
    options.unknownFields = UnknownFields.ignore;
    Reply!Text strings;
    const parsed = decodeInto(input, strings, arena, options);
    if (parsed.code == Status.ok)
    {
        const result = trace ? strings.partialSuccess.rejectedSpans : strings.partialSuccess.rejectedDataPoints;
        Result!ulong rejected;
        const read = arena.read(result.bytes, (scope const(ubyte)[] data) @safe nothrow @nogc {
            rejected = parseCount(data);
        });
        if (read == Status.invalidArgument && result.bytes.length == 0)
            return Result!ulong(0);
        return read == Status.ok ? rejected : Result!ulong(0, Error(read, "invalid collector count location"));
    }
    arena.reset();
    Reply!long numbers;
    const numeric = decodeInto(input, numbers, arena, options);
    if (numeric.code != Status.ok)
        return Result!ulong(0, Error(Status.ioError, "invalid OTLP coordinator response"));
    const count = trace ? numbers.partialSuccess.rejectedSpans : numbers.partialSuccess.rejectedDataPoints;
    if (count < 0)
        return Result!ulong(0, Error(Status.ioError, "invalid rejected telemetry count"));
    return Result!ulong(cast(ulong) count);
}

private Result!ulong parseCount(scope const(ubyte)[] data) pure nothrow @nogc
{
    if (data.length == 0)
        return Result!ulong(0, Error(Status.ioError, "empty rejected telemetry count"));
    ulong count;
    foreach (character; data)
    {
        if (character < '0' || character > '9' || count > (long.max - (character - '0')) / 10)
            return Result!ulong(0, Error(Status.ioError, "invalid rejected telemetry count"));
        count = count * 10 + character - '0';
    }
    return Result!ulong(count);
}
