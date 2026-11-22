/// Owner-side JetStream commands, publish receipts and explicit pull acknowledgements.
module flint.mq.jetstream;

import flint.arena : Buffer, Error, RequestArena, Result, Status, Text;
import flint.conc : Context, Deadline, fillSecureRandom;
import flint.mq.ffi.kafka : nativeError;
import flint.mq.ffi.socket : Socket;
import flint.mq.kafka : waitTurn;
import flint.mq.nats : Frame, FrameKind, NatsDecoder, decimal;
import flint.mq.types : AckAction, Message, PublishReceipt, QueueOptions;
import flint.serde : DecodeOptions, UnknownFields, decodeInto;

@safe:
package(flint.mq):

alias NatsHandler = Result!AckAction delegate(ref Message, ref scope RequestArena) @safe nothrow @nogc;

private struct Endpoint
{
    string host;
    ushort port;
    bool tls;
}

private struct ServerInfo
{
    bool tls_required;
    bool auth_required;
    bool headers;
    bool jetstream;
    size_t max_payload;
}

private struct ResponseError
{
    uint code;
}

private struct PubAck
{
    ulong seq;
    bool duplicate;
    ResponseError error;
}

private struct Record
{
    Buffer reply;
    Message message;
}

private struct RequestId
{
    char[64] inbox;
    char[20] sid;
    size_t inboxLength, sidLength;
}

/// One owner serializes socket commands, reply subscriptions, and pulled deliveries.
final class JetStream
{
    private Socket socket;
    private NatsDecoder decoder;
    private ubyte[] deliveryMemory;
    private ubyte[4096] input;
    private size_t inputPosition, inputUsed;
    // One command is staged and sent with a single write. Split small writes of a request would
    // otherwise wait for the peer's delayed acknowledgement before the server can reply.
    private ubyte[16_384] output;
    private size_t outputUsed;
    private char[32] nonce;
    private ulong serial, token;
    private size_t maximumPayload;
    // busy: a command owns the socket. delivering: a handler borrows the delivery workspace.
    private bool live, busy, delivering;
    // Reconnection (ADR-017 decision 12): after a transport error or timeout the socket is dropped and
    // the next operation reconnects, waiting at most for the capped backoff within its own deadline.
    private Endpoint remote;
    private string trustBundle, identity;
    private ubyte[] decoderMemory;
    private bool closed;
    private long retryAt, backoff;

    Error open(QueueOptions options)
    {
        Endpoint address;
        if (!endpoint(options.endpoints, address) || !name(options.clientId) || (!address.tls
                && options.caBundle.length != 0))
            return nativeError(Status.invalidArgument);
        const configured = initialize(options.maxQueuedBytes);
        if (configured.code != Status.ok)
            return configured;
        auto started = socket.open(address.host, address.port);
        if (started.code != Status.ok)
            return started;
        bool ready;
        scope (exit)
        {
            if (!ready)
                socket.close();
        }
        auto context = Context.init.withDeadline(Deadline.afterMillis(connectMillis));
        started = connect(address, options.caBundle, options.clientId, context);
        if (started.code == Status.ok)
        {
            ready = true;
            live = true;
            remote = address;
            trustBundle = options.caBundle;
            identity = options.clientId;
            backoff = firstBackoffNanos;
        }
        return started;
    }

    private Error initialize(size_t bytes)
    {
        if (bytes < 512)
            return nativeError(Status.invalidArgument);
        auto memory = new ubyte[bytes];
        const half = bytes / 2;
        decoderMemory = memory[0 .. half];
        decoder = NatsDecoder(decoderMemory);
        deliveryMemory = memory[half .. $];
        ubyte[16] random;
        const generated = fillSecureRandom(random[]);
        if (generated.code != Status.ok)
            return generated;
        encodeHex(random[], nonce[]);
        return Error.init;
    }

nothrow @nogc:

    bool idle() const
    {
        return !busy && !delivering;
    }

    /// Close for good: no later operation reconnects.
    void close()
    {
        closed = true;
        drop();
    }

    // dfmt off
    Result!PublishReceipt publish(scope const(char)[] subject, scope const(ubyte)[] key,
            scope const(ubyte)[] payload, scope const(char)[] dedup, ref scope const Context context)
    {
        if (closed || busy)
            return publishFailure(nativeError(Status.conflict));
        busy = true;
        scope (exit)
            busy = false;
        const connected = ensureLive(context);
        if (connected.code != Status.ok)
            return publishFailure(connected);
        return publishRecord(subject, key, payload, dedup, context);
    }

    Error poll(string stream, string consumer, string deadLetter, bool confirmed,
            ref scope const Context context, scope NatsHandler handler)
    {
        if (closed || busy || delivering)
            return nativeError(Status.conflict);
        delivering = true;
        scope (exit)
            delivering = false;
        auto arena = RequestArena(deliveryMemory);
        auto record = pullLive(stream, consumer, context, arena);
        if (!record.ok())
            return record.error;
        // The pulled frame is retired and copied, so the handler may publish on this client.
        auto message = record.value.message;
        const requested = handler(message, arena);
        if (!requested.ok())
            return requested.error;
        return settle(record.value.reply, message, arena, requested.value, deadLetter, confirmed, context);
    }

    private Result!Record pullLive(string stream, string consumer, ref scope const Context context,
            ref scope RequestArena arena)
    {
        busy = true;
        scope (exit)
            busy = false;
        const connected = ensureLive(context);
        if (connected.code != Status.ok)
            return Result!Record(Record.init, connected);
        return pull(stream, consumer, context, arena);
    }

    private Error settle(Buffer reply, ref Message message, ref scope RequestArena arena, AckAction action,
            string deadLetter, bool confirmed, ref scope const Context context)
    {
        while (busy && live)
        {
            const waited = waitTurn(context);
            if (waited.code != Status.ok)
                return waited;
        }
        // The broker redelivers an unacknowledged message after its ack wait.
        if (!live)
            return closed ? nativeError(Status.conflict) : Error(Status.unavailable,
                    "JetStream connection lost before acknowledgement; the broker will redeliver");
        busy = true;
        scope (exit)
            busy = false;
        if (action == AckAction.reject)
        {
            const delivered = deadLetterRecord(deadLetter, message, arena, context);
            if (delivered.code != Status.ok)
                return delivered;
        }
        return acknowledge(reply, arena, action, confirmed, context);
    }

    /// Release the transport and every partial frame; a later operation may reconnect unless closed.
    private void drop()
    {
        socket.close();
        live = false;
        outputUsed = 0;
        inputPosition = inputUsed = 0;
        decoder = NatsDecoder(decoderMemory);
    }

    /// Reconnect after a dropped transport, waiting for the capped backoff only within the caller's deadline.
    private Error ensureLive(ref scope const Context context)
    {
        while (!live)
        {
            // A client that never connected has no endpoint to return to.
            if (closed || remote.port == 0)
                return nativeError(Status.conflict);
            const now = Deadline.afterMillis(0).monotonicNanoseconds;
            if (now < retryAt)
            {
                if (context.deadline().monotonicNanoseconds <= retryAt)
                    return reconnectPending;
                const waited = waitTurn(context);
                if (waited.code == Status.timedOut)
                    return reconnectPending;
                if (waited.code != Status.ok)
                    return waited;
                continue;
            }
            const attempt = reconnect(context);
            if (attempt.code == Status.cancelled)
                return attempt;
            if (attempt.code != Status.ok)
            {
                retryAt = Deadline.afterMillis(0).monotonicNanoseconds + backoff;
                backoff = backoff >= maximumBackoffNanos / 2 ? maximumBackoffNanos : backoff * 2;
            }
        }
        return Error.init;
    }

    private Error reconnect(ref scope const Context context)
    {
        auto limit = context.withDeadline(Deadline.afterMillis(connectMillis));
        auto started = socket.open(remote.host, remote.port);
        if (started.code == Status.ok)
            started = connect(remote, trustBundle, identity, limit);
        if (started.code != Status.ok)
        {
            drop();
            return started;
        }
        live = true;
        backoff = firstBackoffNanos;
        return Error.init;
    }

    private Error connect(Endpoint address, string bundle, string clientId, ref scope const Context context)
    {
        auto status = await(() => socket.connected(), context);
        if (status.code != Status.ok)
            return status;
        const frame = next(context);
        if (frame.code != Status.ok)
            return frame;
        ServerInfo info;
        status = readInfo(info);
        if (status.code != Status.ok)
            return status;
        status = supported(info, address.tls);
        if (status.code != Status.ok)
            return status;
        maximumPayload = info.max_payload;
        if (address.tls)
        {
            status = upgradeTls(address, bundle, context);
            if (status.code != Status.ok)
                return status;
        }
        return sendConnect(clientId, address.tls, context);
    }

    private Error upgradeTls(Endpoint address, string bundle, ref scope const Context context)
    {
        if (inputPosition != inputUsed)
            return nativeError(Status.invalidArgument);
        const started = socket.startTls(address.host, bundle);
        return started.code == Status.ok ? await(() => socket.handshake(), context) : started;
    }

    private Error readInfo(out ServerInfo info)
    {
        Error parsed = nativeError(Status.invalidArgument);
        decoder.visit((scope const ref Frame frame) @safe nothrow @nogc {
            if (frame.kind == FrameKind.info)
                parsed = json(cast(const(ubyte)[]) frame.argument, info);
        });
        decoder.retire();
        return parsed;
    }

    private Error sendConnect(string clientId, bool tls, ref scope const Context context)
    {
        char[512] command;
        size_t used;
        appendKnown(command[], used, `CONNECT {"verbose":false,"pedantic":true,"protocol":1,`);
        appendKnown(command[], used, `"headers":true,"no_responders":true,"name":"`);
        if (!put(command[], used, clientId) || !put(command[], used, tls ? `","tls_required":true}` : `"}`)
                || !put(command[], used, "\r\nPING\r\n"))
            return nativeError(Status.invalidArgument);
        auto sent = write(cast(const(ubyte)[]) command[0 .. used], context);
        if (sent.code != Status.ok)
            return sent;
        sent = relevant(context);
        if (sent.code != Status.ok)
            return sent;
        FrameKind kind;
        decoder.visit((scope const ref Frame frame) { kind = frame.kind; });
        decoder.retire();
        return kind == FrameKind.pong ? Error.init : nativeError(Status.invalidArgument);
    }

    private Error next(ref scope const Context context)
    {
        for (;;)
        {
            const active = context.check();
            if (active.code != Status.ok)
                return active;
            if (inputPosition < inputUsed)
            {
                const decoded = decoder.feed(input[inputPosition .. inputUsed]);
                inputPosition += decoded.consumed;
                if (decoded.error.code != Status.ok || decoded.complete)
                    return decoded.error;
            }
            const read = socket.read(input[]);
            if (read.error.code == Status.unavailable)
            {
                const waited = waitTurn(context);
                if (waited.code != Status.ok)
                    return waited;
            }
            else if (!read.ok() || read.value == 0)
                return read.ok() ? nativeError(Status.ioError) : read.error;
            else
            {
                inputPosition = 0;
                inputUsed = read.value;
            }
        }
    }

    private Error relevant(ref scope const Context context)
    {
        for (;;)
        {
            const arrived = next(context);
            if (arrived.code != Status.ok)
                return arrived;
            FrameKind kind;
            decoder.visit((scope const ref Frame frame) { kind = frame.kind; });
            if (kind == FrameKind.message || kind == FrameKind.headers || kind == FrameKind.pong)
                return Error.init;
            decoder.retire();
            if (kind == FrameKind.failure)
                return nativeError(Status.permissionDenied);
            if (kind == FrameKind.ping)
            {
                const answered = write(cast(const(ubyte)[]) "PONG\r\n", context);
                if (answered.code != Status.ok)
                    return answered;
            }
        }
    }

    private Error write(scope const(ubyte)[] bytes, ref scope const Context context)
    {
        size_t written;
        while (written < bytes.length)
        {
            const active = context.check();
            if (active.code != Status.ok)
                return active;
            const progressed = socket.write(bytes[written .. $]);
            if (progressed.error.code == Status.unavailable)
            {
                const waited = waitTurn(context);
                if (waited.code != Status.ok)
                    return waited;
            }
            else if (!progressed.ok())
                return progressed.error;
            else
                written += progressed.value;
        }
        return Error.init;
    }

    private Error prepare(ref RequestId id, ref scope const Context context)
    {
        if (serial == ulong.max)
            return nativeError(Status.resourceExhausted);
        id.sidLength = digits(++serial, id.sid[]);
        appendKnown(id.inbox[], id.inboxLength, "_INBOX.");
        appendKnown(id.inbox[], id.inboxLength, nonce[]);
        appendKnown(id.inbox[], id.inboxLength, ".");
        appendKnown(id.inbox[], id.inboxLength, id.sid[0 .. id.sidLength]);
        char[128] command;
        size_t used;
        appendKnown(command[], used, "SUB ");
        appendKnown(command[], used, id.inbox[0 .. id.inboxLength]);
        appendKnown(command[], used, " ");
        appendKnown(command[], used, id.sid[0 .. id.sidLength]);
        appendKnown(command[], used, "\r\nUNSUB ");
        appendKnown(command[], used, id.sid[0 .. id.sidLength]);
        appendKnown(command[], used, " 1\r\n");
        return stage(cast(const(ubyte)[]) command[0 .. used], context);
    }

    private Error transmit(scope const(char)[] subject, scope const(char)[] inbox, scope const(ubyte)[] headers,
            scope const(ubyte)[] payload, ref scope const Context context)
    {
        char[768] line;
        size_t used;
        if (!addressSubject(subject) || payload.length > maximumPayload
                || headers.length > maximumPayload - payload.length)
            return nativeError(Status.invalidArgument);
        appendKnown(line[], used, headers.length ? "HPUB " : "PUB ");
        appendKnown(line[], used, subject);
        appendKnown(line[], used, " ");
        if (inbox.length != 0)
        {
            appendKnown(line[], used, inbox);
            appendKnown(line[], used, " ");
        }
        if (headers.length != 0)
        {
            putNumber(line[], used, headers.length);
            appendKnown(line[], used, " ");
        }
        putNumber(line[], used, headers.length + payload.length);
        appendKnown(line[], used, "\r\n");
        auto sent = stage(cast(const(ubyte)[]) line[0 .. used], context);
        if (sent.code == Status.ok)
            sent = stage(headers, context);
        if (sent.code == Status.ok)
            sent = stage(payload, context);
        if (sent.code == Status.ok)
            sent = stage(cast(const(ubyte)[]) "\r\n", context);
        return sent.code == Status.ok ? flush(context) : sent;
    }

    private Error stage(scope const(ubyte)[] bytes, ref scope const Context context)
    {
        if (bytes.length > output.length - outputUsed)
        {
            const flushed = flush(context);
            if (flushed.code != Status.ok)
                return flushed;
            if (bytes.length > output.length)
                return write(bytes, context);
        }
        output[outputUsed .. outputUsed + bytes.length] = bytes[];
        outputUsed += bytes.length;
        return Error.init;
    }

    private Error flush(ref scope const Context context)
    {
        if (outputUsed == 0)
            return Error.init;
        const pending = outputUsed;
        outputUsed = 0;
        return write(output[0 .. pending], context);
    }

    private Error request(scope const(char)[] subject, scope const(ubyte)[] headers,
            scope const(ubyte)[] payload, ref scope const Context context, out RequestId id)
    {
        auto asked = prepare(id, context);
        if (asked.code == Status.ok)
            asked = transmit(subject, id.inbox[0 .. id.inboxLength], headers, payload, context);
        if (asked.code == Status.ok)
            asked = relevant(context);
        if (asked.code != Status.ok)
        {
            // A late reply would desynchronize this stream, so any failure retires the transport.
            drop();
            return transportFailure(asked);
        }
        return asked;
    }

    private Result!PublishReceipt publishRecord(scope const(char)[] subject, scope const(ubyte)[] key,
            scope const(ubyte)[] payload, scope const(char)[] dedup, ref scope const Context context)
    {
        if (!addressSubject(subject) || key.length > 256 || (dedup.length != 0 && !name(dedup))
                || payload.length > deliveryMemory.length || payload.length > maximumPayload)
            return publishFailure(nativeError(Status.invalidArgument));
        char[768] header;
        const length = publishHeaders(key, dedup, header[]);
        RequestId id;
        const sent = request(subject, cast(const(ubyte)[]) header[0 .. length], payload, context, id);
        if (sent.code != Status.ok)
            return publishFailure(sent);
        PubAck receipt;
        Error parsed = nativeError(Status.invalidArgument);
        decoder.visit((scope const ref Frame frame) {
            if (matching(frame, id) && serverStatus(frame.header) == 0)
                parsed = json(frame.payload, receipt);
        });
        decoder.retire();
        if (parsed.code != Status.ok || receipt.error.code != 0 || receipt.seq == 0)
            return publishFailure(parsed.code != Status.ok ? parsed : nativeError(Status.unavailable));
        return Result!PublishReceipt(PublishReceipt(-1, -1, receipt.seq));
    }

    private Result!Record pull(string stream, string consumer, ref scope const Context context,
            ref scope RequestArena arena)
    {
        char[256] subject;
        size_t used;
        appendKnown(subject[], used, "$JS.API.CONSUMER.MSG.NEXT.");
        if (!put(subject[], used, stream) || !put(subject[], used, ".") || !put(subject[], used, consumer))
            return Result!Record(Record.init, nativeError(Status.invalidArgument));
        RequestId id;
        const sent = request(subject[0 .. used], null, cast(const(ubyte)[]) `{"batch":1,"no_wait":true}`, context, id);
        if (sent.code != Status.ok)
            return Result!Record(Record.init, sent);
        Result!Record result;
        decoder.visit((scope const ref Frame frame) {
            const status = serverStatus(frame.header);
            if (!deliveryMatches(frame, id))
                result.error = nativeError(Status.invalidArgument);
            else if (status != 0)
                result.error = nativeError(status == 404 || status == 408 || status == 409
                        ? Status.unavailable : Status.ioError);
            else
                result = storeDelivery(frame, arena);
        });
        decoder.retire();
        return result;
    }

    private Result!Record storeDelivery(scope const ref Frame frame, ref scope RequestArena arena)
    {
        if (!addressSubject(frame.subject) || !ackSubject(frame.reply) || token == ulong.max)
            return Result!Record(Record.init, nativeError(Status.invalidArgument));
        const encoded = headerValue(frame.header, "Flint-Key");
        ubyte[256] key;
        const keyBytes = decodeHex(encoded, key[]);
        if (keyBytes == size_t.max)
            return Result!Record(Record.init, nativeError(Status.invalidArgument));
        const reply = arena.copyIn(cast(const(ubyte)[]) frame.reply);
        const topic = arena.copyIn(cast(const(ubyte)[]) frame.subject);
        const copiedKey = arena.copyIn(key[0 .. keyBytes]);
        const payload = arena.copyIn(frame.payload);
        if (!reply.ok() || !topic.ok() || !copiedKey.ok() || !payload.ok())
            return Result!Record(Record.init, nativeError(Status.resourceExhausted));
        const sequence = streamSequence(frame.reply);
        return Result!Record(Record(reply.value, Message(Text(topic.value), copiedKey.value, payload.value,
                sequence > long.max ? -1 : cast(long) sequence, -1, ++token)));
    }

    private Error deadLetterRecord(string subject, ref Message message, ref scope RequestArena arena,
            ref scope const Context context)
    {
        if (subject.length == 0)
            return nativeError(Status.conflict);
        Error status;
        const first = arena.read(message.key, (scope const(ubyte)[] key) {
            const second = arena.read(message.payload, (scope const(ubyte)[] payload) {
                status = publishRecord(subject, key, payload, null, context).error;
            });
            if (second != Status.ok)
                status = nativeError(second);
        });
        return first == Status.ok ? status : nativeError(first);
    }

    private Error acknowledge(Buffer reply, ref scope RequestArena arena, AckAction action, bool confirmed,
            ref scope const Context context)
    {
        Error result;
        const read = arena.read(reply, (scope const(ubyte)[] address) {
            const subject = cast(const(char)[]) address;
            if (action == AckAction.retry)
                result = transmit(subject, null, null, cast(const(ubyte)[]) `-NAK {"delay":100000000}`, context);
            else if (confirmed)
                result = doubleAck(subject, context);
            else
                result = transmit(subject, null, null, cast(const(ubyte)[]) "+ACK", context);
        });
        if (result.code != Status.ok)
        {
            drop();
            result = transportFailure(result);
        }
        return read == Status.ok ? result : nativeError(read);
    }

    private Error doubleAck(scope const(char)[] subject, ref scope const Context context)
    {
        RequestId id;
        const confirmed = request(subject, null, cast(const(ubyte)[]) "+ACK", context, id);
        if (confirmed.code != Status.ok)
            return confirmed;
        bool ok;
        decoder.visit((scope const ref Frame frame) {
            ok = matching(frame, id) && serverStatus(frame.header) == 0;
        });
        decoder.retire();
        return ok ? Error.init : nativeError(Status.ioError);
    }
    // dfmt on
}

private enum connectMillis = 5000;
private enum firstBackoffNanos = 25_000_000L;
private enum maximumBackoffNanos = 2_000_000_000L;
private enum connectionLost = Error(Status.unavailable,
            "JetStream connection lost; the request outcome may be ambiguous and the client will reconnect");
private enum reconnectPending = Error(Status.unavailable, "JetStream connection is down; reconnect pending");

/// Keep deadline, cancellation, validation and broker refusals; report anything else as a lost connection.
private Error transportFailure(Error failure) pure nothrow @nogc
{
    const code = failure.code;
    const kept = code == Status.timedOut || code == Status.cancelled || code == Status.invalidArgument
        || code == Status.permissionDenied || code == Status.resourceExhausted;
    return kept ? failure : connectionLost;
}

private Error supported(ServerInfo info, bool secure) pure nothrow @nogc
{
    if (info.auth_required || (info.tls_required && !secure))
        return nativeError(Status.permissionDenied);
    return info.jetstream && info.headers && info.max_payload != 0 ? Error.init : nativeError(Status.unsupported);
}

private alias SocketStep = Error delegate() @safe nothrow @nogc;

private Error await(scope SocketStep progress, ref scope const Context context) nothrow @nogc
{
    for (;;)
    {
        const status = progress();
        if (status.code != Status.unavailable)
            return status;
        const waited = waitTurn(context);
        if (waited.code != Status.ok)
            return waited;
    }
}

private bool endpoint(string text, out Endpoint address) pure nothrow @nogc
{
    if (prefix(text, "nats://"))
        text = text[7 .. $];
    else if (prefix(text, "tls://"))
    {
        address.tls = true;
        text = text[6 .. $];
    }
    else
        return false;
    if (text.length == 0 || text.length > 260)
        return false;
    const bracketed = text[0] == '[';
    const first = bracketed ? 1 : 0;
    size_t end = hostEnd(text, first, bracketed);
    if (end == first || end == size_t.max || (bracketed && end == text.length))
        return false;
    address.host = text[first .. end];
    end += bracketed;
    address.port = parsePort(text[end .. $]);
    return address.port != 0;
}

private ushort parsePort(scope const(char)[] suffix) pure nothrow @nogc
{
    if (suffix.length == 0)
        return 4222;
    size_t port;
    if (suffix[0] != ':' || !decimal(suffix[1 .. $], port) || port > ushort.max)
        return 0;
    return cast(ushort) port;
}

private size_t hostEnd(scope const(char)[] text, size_t first, bool bracketed) pure nothrow @nogc
{
    size_t position = first;
    while (position < text.length && text[position] != (bracketed ? ']' : ':'))
    {
        if (!nameByte(text[position]) && text[position] != '.' && !(bracketed && text[position] == ':'))
            return size_t.max;
        ++position;
    }
    return position;
}

bool name(scope const(char)[] value) pure nothrow @nogc
{
    if (value.length == 0 || value.length > 96)
        return false;
    foreach (byteValue; value)
        if (!nameByte(byteValue))
            return false;
    return true;
}

private bool nameByte(char byteValue) pure nothrow @nogc
{
    return (byteValue >= '0' && byteValue <= '9') || (byteValue >= 'a' && byteValue <= 'z')
        || (byteValue >= 'A' && byteValue <= 'Z') || byteValue == '_' || byteValue == '-';
}

private bool addressSubject(scope const(char)[] value) pure nothrow @nogc
{
    if (value.length == 0 || value.length > 255)
        return false;
    bool lastDot = true;
    foreach (byteValue; value)
    {
        if ((!nameByte(byteValue) && byteValue != '$' && byteValue != '.') || (lastDot && byteValue == '.'))
            return false;
        lastDot = byteValue == '.';
    }
    return !lastDot;
}

private bool ackSubject(scope const(char)[] value) pure nothrow @nogc
{
    return prefix(value, "$JS.ACK.") && addressSubject(value);
}

private bool prefix(scope const(char)[] text, string expected) pure nothrow @nogc
{
    return text.length >= expected.length && text[0 .. expected.length] == expected;
}

private bool put(scope char[] output, ref size_t used, scope const(char)[] bytes) pure nothrow @nogc
{
    if (bytes.length > output.length - used)
        return false;
    output[used .. used + bytes.length] = bytes[];
    used += bytes.length;
    return true;
}

private void appendKnown(scope char[] output, ref size_t used, scope const(char)[] bytes) pure nothrow @nogc
{
    const fits = put(output, used, bytes);
    assert(fits);
}

private size_t digits(ulong value, scope char[] output) pure nothrow @nogc
{
    char[20] reverse;
    size_t used;
    do
    {
        reverse[used++] = cast(char)('0' + (value % 10));
        value /= 10;
    }
    while (value != 0);
    if (used > output.length)
        return 0;
    foreach (index; 0 .. used)
        output[index] = reverse[used - index - 1];
    return used;
}

private void putNumber(scope char[] output, ref size_t used, size_t byteCount) pure nothrow @nogc
{
    used += digits(byteCount, output[used .. $]);
}

private void encodeHex(scope const(ubyte)[] input, scope char[] output) pure nothrow @nogc
{
    static immutable alphabet = "0123456789abcdef";
    foreach (index, byteValue; input)
    {
        output[index * 2] = alphabet[byteValue >> 4];
        output[index * 2 + 1] = alphabet[byteValue & 15];
    }
}

private int nibble(char digit) pure nothrow @nogc
{
    if (digit >= '0' && digit <= '9')
        return digit - '0';
    if (digit >= 'a' && digit <= 'f')
        return digit - 'a' + 10;
    return -1;
}

private size_t decodeHex(scope const(char)[] input, scope ubyte[] data) pure nothrow @nogc
{
    const size = input.length / 2;
    if (input.length % 2 || size > data.length)
        return size_t.max;
    foreach (index; 0 .. size)
    {
        const high = nibble(input[index * 2]);
        const low = nibble(input[index * 2 + 1]);
        if (high < 0 || low < 0)
            return size_t.max;
        data[index] = cast(ubyte)((high << 4) | low);
    }
    return size;
}

// dfmt off
private size_t publishHeaders(scope const(ubyte)[] key, scope const(char)[] dedup,
        scope char[] output) pure nothrow @nogc
{
    if (key.length == 0 && dedup.length == 0)
        return 0;
    size_t used;
    appendKnown(output, used, "NATS/1.0\r\n");
    if (key.length)
    {
        appendKnown(output, used, "Flint-Key: ");
        const length = key.length * 2;
        encodeHex(key, output[used .. used + length]);
        used += length;
        appendKnown(output, used, "\r\n");
    }
    if (dedup.length)
    {
        appendKnown(output, used, "Nats-Msg-Id: ");
        appendKnown(output, used, dedup);
        appendKnown(output, used, "\r\n");
    }
    appendKnown(output, used, "\r\n");
    return used;
}
// dfmt on

private size_t serverStatus(scope const(ubyte)[] header) pure nothrow @nogc
{
    if (header.length == 0)
        return 0;
    const text = cast(const(char)[]) header;
    if (prefix(text, "NATS/1.0\r\n"))
        return 0;
    if (!prefix(text, "NATS/1.0 ") || text.length < 14)
        return size_t.max;
    size_t code;
    return decimal(text[9 .. 12], code) ? code : size_t.max;
}

private const(char)[] headerValue(return scope const(ubyte)[] headers, string key) pure nothrow @nogc
{
    const text = cast(const(char)[]) headers;
    size_t line;
    foreach (end, byteValue; text)
    {
        if (byteValue == '\n')
        {
            if (end > line && text[end - 1] == '\r' && end - line > key.length + 2
                    && prefix(text[line .. end], key) && text[line + key.length .. line + key.length + 2] == ": ")
                return text[line + key.length + 2 .. end - 1];
            line = end + 1;
        }
    }
    return null;
}

private size_t streamSequence(scope const(char)[] reply) pure nothrow @nogc
{
    size_t end = reply.length;
    uint fields;
    for (size_t start = reply.length; start > 0; --start)
    {
        if (reply[start - 1] == '.')
        {
            if (++fields == 4)
            {
                size_t sequence;
                return decimal(reply[start .. end], sequence) ? sequence : size_t.max;
            }
            end = start - 1;
        }
    }
    return size_t.max;
}

private bool deliveryMatches(scope const ref Frame frame, scope const ref RequestId id) pure nothrow @nogc
{
    return (frame.kind == FrameKind.message || frame.kind == FrameKind.headers) && frame.sid == id
        .sid[0 .. id.sidLength];
}

private bool matching(scope const ref Frame frame, scope const ref RequestId id) pure nothrow @nogc
{
    return deliveryMatches(frame, id) && frame.subject == id.inbox[0 .. id.inboxLength];
}

private Error json(T)(scope const(ubyte)[] input, ref T result) nothrow @nogc
{
    ubyte[8192] scratch;
    auto arena = RequestArena(scratch[]);
    DecodeOptions options;
    options.unknownFields = UnknownFields.ignore;
    return decodeInto(input, result, arena, options);
}

private Result!PublishReceipt publishFailure(Error error) pure nothrow @nogc
{
    return Result!PublishReceipt(PublishReceipt.init, error);
}
