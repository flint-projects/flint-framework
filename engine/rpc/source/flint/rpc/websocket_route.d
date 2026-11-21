/// WebSocket upgrade, owner-fiber messages and the closing handshake.
module flint.rpc.websocket_route;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.rpc.ffi.websocket : websocketAccept;
import flint.rpc.utf8 : utf8Valid;
import flint.rpc.websocket : WebSocket, WsDecoder, WsOpcode, maximumControlBytes, serverHeader, validCloseCode;
import flint.web : Method, Request, RequestContext, Server, StreamField, StreamMode, StreamRoute, StreamToken;

@safe:

/// A complete WebSocket message in the receiving arena.
struct WebSocketMessage
{
    /// Message bytes.
    Buffer payload;
    /// True for validated UTF-8 text, false for binary.
    bool text;
}

/// A borrowed peer bound to the active owner fiber.
struct WebSocketPeer
{
    private ulong slot;
    private ulong generation;
    private PeerState* state;

    private this(return scope PeerState* state) nothrow @nogc
    {
        this.state = state;
        slot = state.identity;
        generation = state.identity;
    }

    /// Write a complete text message from this arena.
    Error text(Buffer text, ref scope RequestArena arena, ref Context context) scope nothrow @nogc
    {
        return send(WsOpcode.text, text, arena, context);
    }

    /// Write a complete binary message from this arena.
    Error binary(Buffer payload, ref scope RequestArena arena, ref Context context) scope nothrow @nogc
    {
        return send(WsOpcode.binary, payload, arena, context);
    }

    /// Receive a complete message. Ping and close frames are processed by the peer.
    Result!WebSocketMessage receive(ref scope RequestArena arena, ref Context context) scope nothrow @nogc
    {
        if (!live())
            return Result!WebSocketMessage(WebSocketMessage.init, expired());
        return state.receive(arena, context);
    }

    /// Send a single close frame and start the bounded closing handshake.
    Error close(ushort code = 1000, string reason = "") scope nothrow @nogc
    {
        if (!live())
            return expired();
        if (!validCloseCode(code) || reason.length > maximumControlBytes - 2 || !utf8Valid(cast(const(ubyte)[]) reason))
            return Error(Status.invalidArgument, "invalid WebSocket close code or reason");
        ubyte[maximumControlBytes] payload;
        payload[0] = cast(ubyte)(code >> 8);
        payload[1] = cast(ubyte) code;
        payload[2 .. 2 + reason.length] = cast(const(ubyte)[]) reason;
        return state.sendClose(payload[0 .. 2 + reason.length]);
    }

    private bool live() const scope nothrow @nogc
    {
        return state !is null && slot != 0 && slot == generation && state.identity == generation;
    }

    // dfmt off
    private Error send(WsOpcode code, Buffer payload, ref scope RequestArena arena,
            ref Context context) scope nothrow @nogc
    {
        if (!live())
            return expired();
        if (state.sentClose || state.peerClosed)
            return Error(Status.conflict, "WebSocket is closing");
        if (payload == Buffer.init)
            return state.frame(code, null, context);
        Error sent;
        const checked = arena.read(payload, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            if (code == WsOpcode.text && !utf8Valid(bytes))
                sent = Error(Status.invalidArgument, "invalid UTF-8 WebSocket message");
            else
                sent = state.frame(code, bytes, context);
        });
        return checked == Status.ok ? sent : Error(checked, "WebSocket send buffer is unavailable");
    }
    // dfmt on

    private static Error expired() pure nothrow @nogc
    {
        return Error(Status.unavailable, "WebSocket peer is no longer active");
    }
}

/// A handler whose request, peer and arena are borrowed until it returns.
// dfmt off
alias WebSocketHandler = Error delegate(ref scope Request, ref scope WebSocketPeer,
        ref scope RequestContext) @safe nothrow @nogc;
// dfmt on

/// Register a version 13 upgrade at an explicit HTTP/1 GET path.
Error registerWebSocket(ref Server server, WebSocket annotation, WebSocketHandler action)
{
    if (action is null)
        return Error(Status.invalidArgument, "WebSocket route requires an action");
    auto runner = new WebSocketRoute(action);
    return server.routeStream(StreamRoute(Method.get, annotation.path, StreamMode.upgrade, &runner.run));
}

private final class WebSocketRoute
{
    private WebSocketHandler action;

    this(WebSocketHandler action)
    {
        this.action = action;
    }

    Error run(ref scope Request request, ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        const opened = handshake(request, context, token);
        if (opened.code != Status.ok)
            return opened;
        scope state = PeerState(token, context.cancellation, context.requestId);
        scope peer = WebSocketPeer(&state);
        const handled = action(request, peer, context);
        if (context.cancellation.cancelled())
            return context.cancellation.check();
        if (!state.sentClose)
        {
            const closed = peer.close(handled.code == Status.ok ? 1000 : 1011);
            if (closed.code != Status.ok)
                return closed;
        }
        while (!state.peerClosed && !state.failed)
        {
            const reply = state.receive(context.arena, context.cancellation);
            if (!reply.ok())
                break;
        }
        return token.finish(null, context.cancellation);
    }

    // dfmt off
    private static Error handshake(ref scope Request request,
            ref scope RequestContext context, scope StreamToken token) nothrow @nogc
    {
        if (!matchHeader(request, context.arena, "connection", "upgrade") || !matchHeader(request,
                context.arena, "upgrade", "websocket") || request.body().value.length != 0
                || request.headerCount("sec-websocket-key") != 1)
            return reject(token, context.cancellation, 400, null);
        if (!matchHeader(request, context.arena, "sec-websocket-version", "13", false))
            return reject(token, context.cancellation, 426, [
            StreamField("sec-websocket-version", "13")
        ]);

        const key = request.header("sec-websocket-key");
        if (!key.ok())
            return reject(token, context.cancellation, 400, null);
        Result!(char[28]) accept;
        const read = context.arena.read(key.value, (scope const(ubyte)[] source) @safe nothrow @nogc {
            accept = websocketAccept(trim(cast(const(char)[]) source));
        });
        if (read != Status.ok || !accept.ok())
            return reject(token, context.cancellation, accept.error.code == Status.invalidArgument ? 400 : 503, null);
        const opened = token.begin(101, [
            StreamField("upgrade", "websocket"), StreamField("connection", "Upgrade"),
            StreamField("sec-websocket-accept", accept.value[])
        ], context.cancellation);
        return opened;
    }
    // dfmt on
}

private struct PeerState
{
    StreamToken token;
    Context transport;
    ulong identity;
    Deadline closeDeadline;
    bool sentClose;
    bool peerClosed;
    bool failed;
    WsDecoder decoder;
    ubyte[4096] input;
    size_t position;
    size_t available;

    this(return scope StreamToken token, Context transport, ulong identity) nothrow @nogc
    {
        this.token = token;
        this.transport = transport;
        this.identity = identity;
    }

    Error frame(WsOpcode opcode, scope const(ubyte)[] payload, ref scope const Context context) scope nothrow @nogc
    {
        const header = serverHeader(opcode, payload.length);
        if (!header.ok())
            return header.error;
        const started = token.send(header.value.bytes[0 .. header.value.length], context);
        if (started.code != Status.ok || payload.length == 0)
            return started;
        const sent = token.send(payload, context);
        if (sent.code != Status.ok)
        {
            failed = true;
            token.cancel();
        }
        return sent;
    }

    Error sendClose(scope const(ubyte)[] payload) scope nothrow @nogc
    {
        if (sentClose)
            return Error(Status.conflict, "WebSocket close was already sent");
        sentClose = true;
        closeDeadline = Deadline.afterMillis(5_000);
        const closing = transport.withDeadline(closeDeadline);
        return frame(WsOpcode.close, payload, closing);
    }

    Result!WebSocketMessage receive(ref scope RequestArena arena, ref scope const Context context) scope nothrow @nogc
    {
        if (peerClosed)
            return ended();
        const current = context.withDeadline(closeDeadline);
        for (;;)
        {
            if (position == available)
            {
                const bytes = token.receive(input[], current);
                if (!bytes.ok())
                    return Result!WebSocketMessage(WebSocketMessage.init, bytes.error);
                if (bytes.value == 0)
                    return Result!WebSocketMessage(WebSocketMessage.init, Error(Status.unavailable,
                            "WebSocket transport closed without a handshake"));
                available = bytes.value;
                position = 0;
            }
            const frameResult = decoder.feed(input[position .. available], arena);
            position += frameResult.consumed;
            if (frameResult.error.code != Status.ok)
            {
                failFrame(frameResult.closeCode);
                return Result!WebSocketMessage(WebSocketMessage.init, frameResult.error);
            }
            if (!frameResult.complete)
                continue;

            if (frameResult.opcode == WsOpcode.text || frameResult.opcode == WsOpcode.binary)
                return Result!WebSocketMessage(WebSocketMessage(frameResult.payload,
                        frameResult.opcode == WsOpcode.text));
            const control = frameResult.control[0 .. frameResult.controlLength];
            const handled = handleControl(frameResult.opcode, control, current);
            if (handled.code != Status.ok)
                return Result!WebSocketMessage(WebSocketMessage.init, handled);
            if (peerClosed)
                return ended();

        }
    }

    private void failFrame(ushort code) scope nothrow @nogc
    {
        failed = true;
        if (!sentClose)
        {
            const ubyte[2] errorCode = [cast(ubyte)(code >> 8), cast(ubyte) code];
            sendClose(errorCode[]);
        }
    }

    // dfmt off
    private Error handleControl(WsOpcode opcode, scope const(ubyte)[] control,
            ref scope const Context context) scope nothrow @nogc
    {
        if (opcode == WsOpcode.close)
        {
            peerClosed = true;
            return sentClose ? Error.init : sendClose(control);
        }
        return opcode == WsOpcode.ping ? frame(WsOpcode.pong, control, context) : Error.init;
    }
    // dfmt on

}

private Result!WebSocketMessage ended() pure nothrow @nogc
{
    return Result!WebSocketMessage(WebSocketMessage.init, Error(Status.notFound, "WebSocket peer closed"));
}

private Error reject(scope StreamToken token, ref scope const Context context, ushort status,
        scope const(StreamField)[] fields) nothrow @nogc
{
    const sent = token.begin(status, fields, context);
    if (sent.code != Status.ok)
        return sent;
    const completed = token.finish(null, context);
    return completed.code == Status.ok ? Error(Status.invalidArgument, "WebSocket handshake rejected") : completed;
}

private bool matchHeader(ref scope Request request, ref scope RequestArena arena, string name,
        string token, bool list = true) nothrow @nogc
{
    if (request.headerCount(name) != 1)
        return false;
    const header = request.header(name);
    bool found;
    return header.ok() && arena.read(header.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        found = list ? containsToken(cast(const(char)[]) bytes, token) : asciiEqual(trim(cast(const(char)[]) bytes),
            token);
    }) == Status.ok && found;
}

private const(char)[] trim(return scope const(char)[] value) pure nothrow @nogc
{
    while (value.length != 0 && (value[0] == '\t' || value[0] == ' '))
        value = value[1 .. $];
    while (value.length != 0 && (value[$ - 1] == '\t' || value[$ - 1] == ' '))
        value = value[0 .. $ - 1];
    return value;
}

private bool containsToken(scope const(char)[] list, string wanted) pure nothrow @nogc
{
    size_t first;
    foreach (index, value; list)
    {
        if (value == ',')
        {
            if (asciiEqual(trim(list[first .. index]), wanted))
                return true;
            first = index + 1;
        }
    }
    return asciiEqual(trim(list[first .. $]), wanted);
}

private bool asciiEqual(scope const(char)[] raw, string lowercase) pure nothrow @nogc
{
    if (raw.length != lowercase.length)
        return false;
    foreach (index, value; raw)
    {
        const decoded = value >= 'A' && value <= 'Z' ? value + 'a' - 'A' : value;
        if (decoded != lowercase[index])
            return false;
    }
    return true;
}
