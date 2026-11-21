/// Exercises SSE delimiter, UTF-8 and field boundaries.
module flint.rpc.sse_behavior;

import flint.arena : RequestArena, Status;
import flint.rpc.sse : SseDecoder, SseEvent, SseNotice, encodeEvent, encodeHeartbeat, maximumSseLine;

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
