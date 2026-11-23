/// Exercises SSE delimiter, UTF-8 and field boundaries.
module flint.engine.rpc.sse_behavior;

import flint.arena : Buffer, Error, RequestArena, Status;
import flint.engine.rpc.sse : SseDecoder, SseEvent, SseNotice, encodeEvent, encodeHeartbeat, maximumSseLine;

@safe:

unittest
{
    immutable stream = "\xef\xbb\xbf: keepalive\r\nretry: 1500\r"
        ~ "id: first\nevent: update\r\ndata: a\xf0\x9f\x9a\x80\r" ~ "data: b\r\n\r\n" ~ "id: ignored\0id\ndata:z\n\n";
    foreach (split; 0 .. stream.length + 1)
    {
        size_t events;
        auto sink = (SseNotice notice, scope const(char)[] event, scope const(char)[] id,
                scope const(char)[] value, uint retry) @safe nothrow @nogc {
            switch (events++)
            {
            case 0:
                assert(notice == SseNotice.comment && value == "keepalive");
                break;
            case 1:
                assert(notice == SseNotice.retry && retry == 1_500);
                break;
            case 2:
                assert(notice == SseNotice.event && event == "update" && id == "first" && value == "a🚀\nb");
                break;
            case 3:
                assert(notice == SseNotice.event && event == "message" && id == "first" && value == "z");
                break;
            default:
                assert(0);
            }
        };
        SseDecoder decoder;
        assert(decoder.feed(cast(const(ubyte)[]) stream[0 .. split], sink).code == Status.ok);
        assert(decoder.feed(cast(const(ubyte)[]) stream[split .. $], sink).code == Status.ok);
        assert(events == 4);
    }
}

unittest
{
    ubyte[1024] backing;
    auto arena = RequestArena(backing[]);
    const data = arena.copyIn(cast(const(ubyte)[]) "first\r\nsecond\n");
    const event = SseEvent("update", "13", data.value, 1200);
    const output = encodeEvent(event, arena);
    assert(output.ok());
    assert(arena.read(output.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(cast(const(
            char)[]) bytes == "event: update\nid: 13\nretry: 1200\ndata: first\ndata: second\ndata: \n\n");
        }) == Status.ok);
    const heartbeat = encodeHeartbeat("stay alive", arena);
    assert(heartbeat.ok());
    assert(arena.read(heartbeat.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(cast(const(char)[]) bytes == ": stay alive\n\n");
        }) == Status.ok);
    const badName = SseEvent("x\ny", "", data.value);
    assert(encodeEvent(badName, arena).error.code == Status.invalidArgument);
    const badId = SseEvent("", "x\ry", data.value);
    assert(encodeEvent(badId, arena).error.code == Status.invalidArgument);
    assert(encodeHeartbeat("x\ny", arena).error.code == Status.invalidArgument);
    assert(arena.reset() == Status.ok);
    assert(encodeEvent(event, arena).error.code == Status.invalidArgument);
}

unittest
{
    immutable input = "data: x\xe2\x82y\xffz\n\n";
    SseDecoder decoder;
    size_t seen;
    auto sink = (SseNotice notice, scope const(char)[] event, scope const(char)[] id,
            scope const(char)[] value, uint retry) @safe nothrow @nogc {
        assert(notice == SseNotice.event);
        assert(event == "message" && id.length == 0 && retry == 0);
        assert(value == "x\xef\xbf\xbdy\xef\xbf\xbdz");
        ++seen;
    };
    foreach (byteValue; input)
        assert(decoder.feed([cast(ubyte) byteValue], sink).code == Status.ok);
    assert(seen == 1);
    ubyte[maximumSseLine + 1] tooLong;
    tooLong[] = 'a';
    assert(decoder.feed(tooLong[], sink).code == Status.resourceExhausted);
    assert(decoder.feed([], sink).code == Status.resourceExhausted);
}

/// Records up to eight notices with bounded copies, so the visitor stays nothrow and @nogc.
private struct Recorder
{
    SseNotice[8] notices;
    char[64][8] values;
    size_t[8] lengths;
    char[16][8] ids;
    size_t[8] idLengths;
    char[16][8] events;
    size_t[8] eventLengths;
    uint[8] retries;
    size_t count;

    void record(SseNotice notice, scope const(char)[] event, scope const(char)[] id, scope const(char)[] value,
            uint retry) scope nothrow @nogc
    {
        assert(count < notices.length && value.length <= 64 && id.length <= 16 && event.length <= 16);
        notices[count] = notice;
        values[count][0 .. value.length] = value;
        lengths[count] = value.length;
        ids[count][0 .. id.length] = id;
        idLengths[count] = id.length;
        events[count][0 .. event.length] = event;
        eventLengths[count] = event.length;
        retries[count] = retry;
        ++count;
    }

    const(char)[] value(size_t index) const return nothrow @nogc
    {
        return values[index][0 .. lengths[index]];
    }

    const(char)[] id(size_t index) const return nothrow @nogc
    {
        return ids[index][0 .. idLengths[index]];
    }

    const(char)[] event(size_t index) const return nothrow @nogc
    {
        return events[index][0 .. eventLengths[index]];
    }
}

@("sse_boundaries: field grammar, retry validation, empty data and the last event id follow the HTML parser")
unittest
{
    immutable stream = "retry: 12a\nretry: 99999999999\nretry\nretry: 250\n" ~ "data\n\n"
        ~ "id: keep\nunknown: ignored\nevent: first\n\n"
        ~ "data:no-space\ndata:  two-spaces\n\n" ~ "event: named\ndata: \n\n" ~ "id\ndata: cleared\n\n"
        ~ "data: pending";
    foreach (split; 0 .. stream.length + 1)
    {
        Recorder seen;
        auto decoder = new SseDecoder;
        assert(decoder.feed(cast(const(ubyte)[]) stream[0 .. split], &seen.record).code == Status.ok);
        assert(decoder.feed(cast(const(ubyte)[]) stream[split .. $], &seen.record).code == Status.ok);
        // Only the all-digit retry is reported; overflow and non-digits are ignored.
        assert(seen.count == 5);
        assert(seen.notices[0] == SseNotice.retry && seen.retries[0] == 250);
        // A bare "data" field dispatches an event with empty data.
        assert(seen.notices[1] == SseNotice.event && seen.event(1) == "message" && seen.value(1) == "");
        // An event field without data does not dispatch, and its name does not leak into the next event.
        assert(seen.event(2) == "message" && seen.id(2) == "keep");
        assert(seen.value(2) == "no-space\n two-spaces");
        assert(seen.event(3) == "named" && seen.value(3) == "" && seen.id(3) == "keep");
        // An empty id field resets the last event id.
        assert(seen.value(4) == "cleared" && seen.id(4) == "");
        // An event that is still pending at the end of input is not dispatched.
    }
}

@("sse_boundaries: a bounded event buffer and encoder reject oversized data instead of truncating it")
unittest
{
    ubyte[40 * 1024] backing;
    auto arena = RequestArena(backing[]);
    ubyte[16 * 1024 + 1] large;
    large[] = 'a';
    const tooLarge = arena.copyIn(large[]);
    const oversized = SseEvent("", "", tooLarge.value);
    assert(encodeEvent(oversized, arena).error.code == Status.resourceExhausted);
    ubyte[4096] line;
    line[] = 'b';
    const longLine = arena.copyIn(line[]);
    const overlong = SseEvent("", "", longLine.value);
    assert(encodeEvent(overlong, arena).error.code == Status.resourceExhausted);
    immutable ubyte[2] invalid = [0xc3, 0x28];
    const badData = arena.copyIn(invalid[]);
    const malformed = SseEvent("", "", badData.value);
    assert(encodeEvent(malformed, arena).error.code == Status.invalidArgument);
    char[1025] field;
    field[] = 'c';
    const wideName = SseEvent(field[].idup, "", Buffer.init);
    assert(encodeEvent(wideName, arena).error.code == Status.invalidArgument);
    const retryOnly = SseEvent("", "", Buffer.init, 4_294_967_295);
    const empty = encodeEvent(retryOnly, arena);
    assert(empty.ok());
    assert(arena.read(empty.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(cast(const(char)[]) bytes == "retry: 4294967295\ndata: \n\n");
        }) == Status.ok);

    // Four 4000-byte data lines exceed the 16 KiB event buffer; the decoder fails closed.
    char[4000] chunk;
    chunk[] = 'd';
    Recorder seen;
    auto decoder = new SseDecoder;
    Error failure;
    foreach (_; 0 .. 5)
    {
        failure = decoder.feed(cast(const(ubyte)[]) "data: ", &seen.record);
        if (failure.code == Status.ok)
            failure = decoder.feed(cast(const(ubyte)[]) chunk[], &seen.record);
        if (failure.code == Status.ok)
            failure = decoder.feed(cast(const(ubyte)[]) "\n", &seen.record);
        if (failure.code != Status.ok)
            break;
    }
    assert(failure.code == Status.resourceExhausted && seen.count == 0);
    assert(decoder.feed(cast(const(ubyte)[]) "\n", &seen.record).code == Status.resourceExhausted);
    assert(decoder.feed(cast(const(ubyte)[]) "data: x\n\n", null).code == Status.invalidArgument);
}
