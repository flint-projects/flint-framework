/// A verified outbound version 13 WebSocket on an owner-confined transport.
module flint.rpc.websocket_client;

import core.lifetime : move;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.http : HttpClient, HttpStream, HttpStreamField, HttpStreamMode, HttpStreamOptions, HttpVersion;
import flint.rpc.ffi.websocket : websocketAccept, websocketKey;
import flint.rpc.metadata : asciiEqual, containsToken, visitFields;
import flint.rpc.websocket_route : PeerState, WebSocketMessage, WebSocketPeer;

@safe:

/// Outbound WebSocket handshake options.
struct WebSocketClientOptions
{
    /// Absolute WSS URL or explicitly enabled numeric loopback WS URL.
    const(char)[] url;
    /// Permit cleartext on numeric Linux loopback addresses.
    bool allowLoopbackCleartext;
    /// Extra request fields. Extensions and subprotocols are unavailable.
    const(HttpStreamField)[] headers;
}

/// Verify the upgrade and return a client peer on the transport owner.
// dfmt off
Result!WebSocketClient connectWebSocket(ref HttpClient client, scope const WebSocketClientOptions options,
        ref scope RequestArena arena, ref Context context) nothrow @nogc
{
    foreach (ref field; options.headers)
    {
        if (reservedField(field.name))
            return failure(Error(Status.invalidArgument, "WebSocket handshake owns sec-websocket fields"));
    }
    const key = websocketKey();
    if (!key.ok())
        return failure(key.error);
    const expected = websocketAccept(key.value[]);
    if (!expected.ok())
        return failure(expected.error);

    scope request = HttpStreamOptions(options.url, HttpStreamMode.upgradedBytes, options.allowLoopbackCleartext,
            options.headers, HttpStreamOptions.init.duplexReceiveBytesPerSecond,
            HttpStreamField("sec-websocket-key", key.value[]));
    auto opened = client.openStream(request, context);
    if (!opened.ok())
        return failure(opened.error);
    auto stream = move(opened.value);
    bool established;
    scope (exit)
    {
        if (!established)
            stream.close();
    }
    const fields = stream.head(arena, context);
    if (!fields.ok())
        return failure(fields.error);
    if (fields.value.status != 101 || fields.value.protocol != HttpVersion.http1
            || !verifiedUpgrade(arena, fields.value.headers, expected.value))
        return failure(Error(Status.invalidArgument, "invalid WebSocket upgrade response"));
    established = true;
    return Result!WebSocketClient(WebSocketClient(move(stream), context));
}
// dfmt on

/// An owned client peer. Close or abort it on the HTTP client's owner before releasing the pool.
struct WebSocketClient
{
    private PeerState state;

    @disable this(this);

    private this(HttpStream stream, Context context) nothrow @nogc
    {
        state = PeerState(move(stream), context);
    }

    /// Write a complete UTF-8 text message from the caller's arena.
    Error text(Buffer message, ref scope RequestArena arena, ref Context context) scope nothrow @nogc
    {
        scope peer = WebSocketPeer(&state);
        return peer.text(message, arena, context);
    }

    /// Write a complete binary message from the caller's arena.
    Error binary(Buffer message, ref scope RequestArena arena, ref Context context) scope nothrow @nogc
    {
        scope peer = WebSocketPeer(&state);
        return peer.binary(message, arena, context);
    }

    /// Read a complete message, answering ping and close frames while waiting.
    Result!WebSocketMessage receive(ref scope RequestArena arena, ref Context context) scope nothrow @nogc
    {
        scope peer = WebSocketPeer(&state);
        return peer.receive(arena, context);
    }

    /// Complete the closing handshake using the earlier of five seconds and the caller deadline.
    // dfmt off
    Error close(ref scope RequestArena arena, ref Context context, ushort code = 1000,
            string reason = "") scope nothrow @nogc
    {
        if (state.identity == 0)
            return Error.init;
        if (!state.sentClose)
        {
            scope peer = WebSocketPeer(&state);
            const sent = peer.close(code, reason);
            if (sent.code != Status.ok)
                return sent;
        }
        Error result;
        while (!state.peerClosed && !state.failed)
        {
            const received = state.receive(arena, context);
            if (!received.ok())
            {
                if (received.error.code != Status.notFound)
                    result = received.error;
                break;
            }
        }
        const released = abort();
        return result.code == Status.ok ? released : result;
    }
    // dfmt on

    /// Cancel the upgraded connection immediately and release its transfer slot.
    Error abort() scope nothrow @nogc
    {
        return state.abort();
    }
}

private bool reservedField(scope const(char)[] name) pure nothrow @nogc
{
    enum prefix = "sec-websocket-";
    return name.length >= prefix.length && asciiEqual(name[0 .. prefix.length], prefix);
}

private Result!WebSocketClient failure(Error reason) nothrow @nogc
{
    return Result!WebSocketClient(WebSocketClient.init, reason);
}

private struct UpgradeFields
{
    uint connections, upgrades, digests;
    bool connection, upgrade, digest, rejected;
    char[28] expected;

    void field(scope const(char)[] name, scope const(char)[] value) nothrow @nogc
    {
        if (asciiEqual(name, "connection"))
        {
            ++connections;
            connection = containsToken(value, "upgrade");
        }
        else if (asciiEqual(name, "upgrade"))
        {
            ++upgrades;
            upgrade = asciiEqual(value, "websocket");
        }
        else if (asciiEqual(name, "sec-websocket-accept"))
        {
            ++digests;
            digest = value == expected[];
        }
        else if (asciiEqual(name, "sec-websocket-extensions") || asciiEqual(name, "sec-websocket-protocol"))
            rejected = true;
    }
}

private bool verifiedUpgrade(ref scope RequestArena arena, Buffer headers, char[28] expected) nothrow @nogc
{
    UpgradeFields fields;
    fields.expected = expected;
    const read = arena.read(headers, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        visitFields(bytes, &fields.field);
    });
    return read == Status.ok && !fields.rejected && fields.connections == 1 && fields.upgrades == 1
        && fields.digests == 1 && fields.connection && fields.upgrade && fields.digest;
}
