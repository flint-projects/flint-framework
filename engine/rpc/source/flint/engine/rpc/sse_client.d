/// Consume a server-sent event stream over the pinned outbound HTTP transport.
module flint.engine.rpc.sse_client;

import core.lifetime : move;
import flint.arena : Buffer, Error, RequestArena, Status;
import flint.conc : Context;
import flint.engine.http : HttpClient, HttpStreamField, HttpStreamOptions;
import flint.engine.rpc.metadata : asciiEqual, mediaValue, visitFields;
import flint.engine.rpc.sse : SseDecoder, SseVisitor, maximumSseField;
import flint.engine.rpc.utf8 : utf8Valid;

@safe:

/// Resume an event stream only when the caller supplies its last acknowledged event id.
struct SseClientOptions
{
    /// Absolute HTTPS URL, or an explicitly allowed numeric loopback URL.
    const(char)[] url;
    /// Permit cleartext on numeric Linux loopback addresses.
    bool allowLoopbackCleartext;
    /// Optional Last-Event-ID request field value.
    const(char)[] lastEventId;
}

/// Deliver event, retry and comment notifications until the response ends or the context stops.
// dfmt off
Error subscribeSse(ref HttpClient client, scope const SseClientOptions options, ref scope RequestArena arena,
        ref scope const Context context, scope SseVisitor visitor) nothrow @nogc
{
    if (visitor is null || options.lastEventId.length > maximumSseField
            || !utf8Valid(cast(const(ubyte)[]) options.lastEventId))
        return Error(Status.invalidArgument, "invalid SSE client options");
    static immutable HttpStreamField[1] headers = [HttpStreamField("accept", "text/event-stream")];
    scope request = HttpStreamOptions(options.url, HttpStreamOptions.init.mode, options.allowLoopbackCleartext,
            headers[], HttpStreamOptions.init.duplexReceiveBytesPerSecond,
            options.lastEventId.length ? HttpStreamField("last-event-id", options.lastEventId) : HttpStreamField.init);
    auto opened = client.openStream(request, context);
    if (!opened.ok())
        return opened.error;
    auto stream = move(opened.value);
    scope (exit)
        stream.close();

    const head = stream.head(arena, context);
    if (!head.ok())
        return head.error;
    const accepted = head.value.status == 200 && eventStream(arena, head.value.headers);
    if (!accepted)
        return Error(Status.invalidArgument, "SSE response must carry HTTP 200 and text/event-stream");

    SseDecoder decoder;
    ubyte[4096] input;
    for (;;)
    {
        const bytes = stream.receive(input[], context);
        if (!bytes.ok() || bytes.value == 0)
            return bytes.error;
        const next = decoder.feed(input[0 .. bytes.value], visitor);
        if (next.code != Status.ok)
            return next;
    }
}
// dfmt on

private bool eventStream(ref scope RequestArena arena, Buffer headers) nothrow @nogc
{
    uint count;
    bool valid;
    const parsed = arena.read(headers, (scope const(ubyte)[] block) @safe nothrow @nogc {
        visitFields(block, (scope const(char)[] name, scope const(char)[] value) @safe nothrow @nogc {
            if (asciiEqual(name, "content-type"))
            {
                ++count;
                valid = asciiEqual(mediaValue(value), "text/event-stream");
            }
        });
    });
    return parsed == Status.ok && count == 1 && valid;
}
