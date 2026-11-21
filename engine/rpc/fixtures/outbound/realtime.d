/// Outbound SSE and WebSocket fixture for independent local peers.
module realtime_fixture;

import core.lifetime : move;
import flint.arena : Buffer, Error, RequestArena, Status;
import flint.conc : Context, Deadline;
import flint.http : ClientOptions, HttpClient;
import flint.rpc : SseClientOptions, SseNotice, WebSocketClientOptions, connectWebSocket, subscribeSse;
import std.stdio : writeln;

@safe:

int main(string[] arguments)
{
    if (arguments.length != 3 && arguments.length != 4)
        return 2;
    HttpClient http;
    ClientOptions config;
    config.maxConnections = config.maxConnectionsPerOrigin = 1;
    if (arguments.length == 4)
        config.caBundle = arguments[3];
    check(http.open(config));
    auto caller = Context.init.withDeadline(Deadline.afterMillis(12_000));
    auto memory = new ubyte[4 * 1024 * 1024 + 65_536];
    auto arena = RequestArena(memory);
    const mode = arguments[1];
    const root = arguments[2];
    const clear = arguments.length == 3;
    if (mode == "sse")
        receiveSse(http, arena, caller, root, clear);
    else if (mode == "sse-reject")
        assert(subscribeSse(http, SseClientOptions(root, clear), arena, caller, (SseNotice,
                scope const(char)[], scope const(char)[], scope const(char)[], uint) @safe nothrow @nogc {
                assert(0, "malformed SSE head entered visitor");
            }).code == Status.invalidArgument);
    else if (mode == "ws")
        websocket(http, arena, caller, root, clear);
    else if (mode == "ws-reject")
        assert(!connectWebSocket(http, WebSocketClientOptions(root, clear), arena, caller).ok());
    else if (mode == "ws-suite")
        suite(http, arena, caller, root);
    else
        return 3;
    check(http.close());
    return 0;
}

private void receiveSse(ref HttpClient http, ref scope RequestArena arena, ref Context caller, string url, bool clear)
{
    const options = SseClientOptions(url, clear, "resume-6");
    uint received;
    // dfmt off
    const result = subscribeSse(http, options, arena, caller, (SseNotice notice,
            scope const(char)[] event, scope const(char)[] id, scope const(char)[] value,
            uint retry) @safe nothrow @nogc {
        switch (received++)
        {
        case 0:
            assert(notice == SseNotice.comment && value == "heartbeat");
            break;
        case 1:
            assert(notice == SseNotice.retry && retry == 1500);
            break;
        case 2:
            assert(notice == SseNotice.event && event == "created" && id == "resume-7");
            assert(value == "he⌛llo\nworld");
            break;
        case 3:
            assert(notice == SseNotice.event && event == "message" && id == "resume-7" && value == "next");
            break;
        default:
            assert(0, "unexpected SSE notice");
        }
    });
    // dfmt on
    check(result);
    assert(received == 4);
    writeln("SSE fragmented fields, UTF-8, heartbeat, retry and resume passed");
}

private void websocket(ref HttpClient http, ref scope RequestArena arena, ref Context caller, string url, bool clear)
{
    auto opened = connectWebSocket(http, WebSocketClientOptions(url, clear), arena, caller);
    check(opened.error);
    auto peer = move(opened.value);
    scope (exit)
        check(peer.abort());
    const reply = peer.receive(arena, caller);
    check(reply.error);
    assert(reply.value.text);
    assert(arena.read(reply.value.payload, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(bytes == cast(const(ubyte)[]) "hi⌛");
        }) == Status.ok);
    check(peer.text(reply.value.payload, arena, caller));
    ubyte[126] payload;
    foreach (index, ref value; payload)
        value = cast(ubyte) index;
    const binary = arena.copyIn(payload[]);
    check(binary.error);
    check(peer.binary(binary.value, arena, caller));
    check(peer.close(arena, caller, 1000, "finished"));
    writeln("WebSocket digest, coalesced frame, fragmented UTF-8, pong, masked echo and close passed");
}

private void suite(ref HttpClient http, ref scope RequestArena arena, ref Context caller, string url)
{
    auto opened = connectWebSocket(http, WebSocketClientOptions(url, true), arena, caller);
    check(opened.error);
    auto peer = move(opened.value);
    scope (exit)
        check(peer.abort());
    for (;;)
    {
        auto received = peer.receive(arena, caller);
        if (!received.ok())
        {
            switch (received.error.code)
            {
            case Status.notFound:
            case Status.unavailable:
            case Status.invalidArgument:
            case Status.resourceExhausted:
            case Status.timedOut:
            case Status.ioError:
                return;
            default:
                check(received.error);
            }
        }
        const sent = received.value.text ? peer.text(received.value.payload, arena,
                caller) : peer.binary(received.value.payload, arena, caller);
        if (sent.code == Status.cancelled || sent.code == Status.timedOut || sent.code == Status.ioError)
            return;
        check(sent);
        assert(arena.reset() == Status.ok);
    }
}

private void check(Error status)
{
    if (status.code != Status.ok)
    {
        writeln(status.code, " ", status.message);
        assert(0);
    }
}
