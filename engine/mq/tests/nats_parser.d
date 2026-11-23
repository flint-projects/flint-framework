/// Split-point and limit tests for NATS framing.
module flint.engine.mq.nats_parser;

import flint.arena : Status;
import flint.engine.mq.nats : Frame, FrameKind, NatsDecoder, maxControlLine;

@safe:

unittest
{
    enum frames = "INFO {\"headers\":true}\r\nPiNg\r\nMSG orders 7 $ACK.x 5\r\nA\r\nBC\r\n"
        ~ "HMSG inbox 7 12 15\r\nNATS/1.0\r\n\r\nxyz\r\n+OK\r\n";
    foreach (split; 0 .. frames.length + 1)
    {
        ubyte[16] backing;
        auto parser = NatsDecoder(backing[]);
        size_t framesSeen;
        foreach (chunk; [frames[0 .. split], frames[split .. $]])
        {
            auto remaining = cast(const(ubyte)[]) chunk;
            while (remaining.length != 0)
            {
                const parsed = parser.feed(remaining);
                assert(parsed.error.code == Status.ok && parsed.consumed != 0);
                remaining = remaining[parsed.consumed .. $];
                if (!parsed.complete)
                    continue;
                readFixture(parser, framesSeen);
                parser.retire();
            }
        }
        assert(framesSeen == 5 && parser.end().code == Status.ok);
    }
}

private void readFixture(ref scope NatsDecoder parser, ref size_t framesSeen) nothrow @nogc
{
    assert(parser.visit((scope const ref Frame frame) @safe nothrow @nogc {
            switch (framesSeen++)
            {
            case 0:
                assert(frame.kind == FrameKind.info && frame.argument == `{"headers":true}`);
                break;
            case 1:
                assert(frame.kind == FrameKind.ping);
                break;
            case 2:
                assert(frame.kind == FrameKind.message && frame.subject == "orders");
                assert(frame.sid == "7" && frame.reply == "$ACK.x");
                assert(frame.payload == cast(const(ubyte)[]) "A\r\nBC");
                break;
            case 3:
                assert(frame.kind == FrameKind.headers && frame.reply.length == 0);
                assert(frame.header == cast(const(ubyte)[]) "NATS/1.0\r\n\r\n");
                assert(frame.payload == cast(const(ubyte)[]) "xyz");
                break;
            case 4:
                assert(frame.kind == FrameKind.ok);
                break;
            default:
                assert(0);
            }
        }).code == Status.ok);
}

unittest
{
    foreach (bad; [
        "MSG subject 1 -1\r\n", "MSG subject 1 9999999999999999999999999\r\n",
        "HMSG subject 1 2 1\r\n", "MSG subject 1 1\r\na\rx", "PING\n", "PONG extra\r\n"
    ])
    {
        ubyte[4] memory;
        auto parser = NatsDecoder(memory[]);
        assert(parser.feed(cast(const(ubyte)[]) bad).error.code == Status.invalidArgument);
    }
    ubyte[4] memory;
    auto parser = NatsDecoder(memory[]);
    assert(parser.feed(cast(const(ubyte)[]) "MSG subject 1 5\r\n").error.code == Status.resourceExhausted);
    parser = NatsDecoder(memory[]);
    assert(parser.feed(cast(const(ubyte)[]) "MSG subject 1 4\r\naa\r").error.code == Status.ok);
    assert(parser.end().code == Status.invalidArgument);
    parser = NatsDecoder(memory[]);
    assert(parser.feed(cast(const(ubyte)[]) "MSG subject 1 4\r\n\0\r\nX\r\n").complete);
    parser = NatsDecoder(memory[]);
    ubyte[maxControlLine + 1] oversized;
    oversized[] = cast(ubyte) 'a';
    assert(parser.feed(oversized[]).error.code == Status.resourceExhausted);
}
