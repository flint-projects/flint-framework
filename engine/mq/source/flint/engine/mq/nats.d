/// Bounded framing for the NATS client protocol.
module flint.engine.mq.nats;

import flint.arena : Error, Status;

@safe:
package(flint.engine.mq):

/// Maximum bytes in a command line before its CRLF terminator.
enum maxControlLine = 4096;

/// Server command kinds accepted by the client.
enum FrameKind : ubyte
{
    none,
    info,
    ping,
    pong,
    ok,
    failure,
    message,
    headers
}

/// Byte ranges borrowed while the parser's current frame remains ready.
struct Frame
{
    FrameKind kind;
    const(char)[] argument;
    const(char)[] subject;
    const(char)[] sid;
    const(char)[] reply;
    const(ubyte)[] header;
    const(ubyte)[] payload;
}

alias FrameVisitor = void delegate(scope const ref Frame frame) @safe nothrow @nogc;

/// Progress through the input. A complete frame must be retired before more input can be offered.
struct ReadProgress
{
    size_t consumed;
    bool complete;
    Error error;
}

private struct Span
{
    size_t start;
    size_t end;

    const(char)[] view(return scope const(char)[] line) const pure nothrow @nogc
    {
        return line[start .. end];
    }
}

/// Incremental parser using a separately owned, preallocated body buffer.
struct NatsDecoder
{
    private char[maxControlLine] control;
    private ubyte[] body;
    private FrameKind kind;
    private Span subject;
    private Span sid;
    private Span reply;
    private Span argument;
    private size_t lineBytes, bodyBytes, headerBytes, bodyUsed, tail;
    private bool lineCR, ready, failed;

    this(return scope ubyte[] storage) nothrow @nogc
    {
        body = storage;
    }

    ReadProgress feed(scope const(ubyte)[] wire) scope nothrow @nogc
    {
        if (failed)
            return ReadProgress(0, false, Error(Status.conflict, "NATS framing already failed"));
        if (ready)
            return ReadProgress(0, true);

        size_t position;
        while (position < wire.length)
        {
            if (kind == FrameKind.none)
            {
                const parsed = readLine(wire[position++]);
                if (parsed.code != Status.ok)
                    return fail(position, parsed);
            }
            else
            {
                const parsed = readBody(wire, position);
                if (parsed.code != Status.ok)
                    return fail(position, parsed);
            }
            if (ready)
                return ReadProgress(position, true);
        }
        return ReadProgress(position);
    }

    Error visit(scope FrameVisitor visitor) const scope nothrow @nogc
    {
        if (!ready || visitor is null)
            return Error(Status.conflict, "NATS frame is unavailable");
        const line = control[0 .. lineBytes];
        scope frame = Frame(kind, argument.view(line), subject.view(line), sid.view(line),
                reply.view(line), body[0 .. headerBytes], body[headerBytes .. bodyBytes]);
        visitor(frame);
        return Error.init;
    }

    void retire() scope nothrow @nogc
    {
        if (ready)
        {
            kind = FrameKind.none;
            subject = sid = reply = argument = Span.init;
            lineBytes = bodyBytes = headerBytes = bodyUsed = tail = 0;
            lineCR = ready = false;
        }
    }

    Error end() const scope pure nothrow @nogc
    {
        if (failed || lineBytes != 0 || lineCR || (!ready && kind != FrameKind.none))
            return Error(Status.invalidArgument, "truncated NATS frame");
        return Error.init;
    }

    private ReadProgress fail(size_t used, Error error) scope nothrow @nogc
    {
        failed = true;
        return ReadProgress(used, false, error);
    }

    private Error readLine(ubyte byteValue) scope nothrow @nogc
    {
        if (lineCR)
            return byteValue == '\n' ? parseLine() : invalidLine();
        if (byteValue == '\r')
            lineCR = true;
        else
        {
            if (byteValue < ' ' || byteValue == 127)
                return invalidLine();
            if (lineBytes == control.length)
                return Error(Status.resourceExhausted, "NATS command line exceeds the byte limit");
            control[lineBytes++] = cast(char) byteValue;
        }
        return Error.init;
    }

    private Error parseLine() scope nothrow @nogc
    {
        const line = control[0 .. lineBytes];
        size_t position;
        const command = word(line, position).view(line);
        kind = readKind(command);
        if (kind == FrameKind.none)
            return invalidLine();
        if (kind == FrameKind.message || kind == FrameKind.headers)
            return parseDelivery(line, position);
        if (kind == FrameKind.info || kind == FrameKind.failure)
            argument = Span(position, line.length);
        else if (position < line.length)
            return invalidLine();
        ready = true;
        return Error.init;
    }

    private Error parseDelivery(scope const(char)[] line, size_t position) scope nothrow @nogc
    {
        subject = word(line, position);
        sid = word(line, position);
        Span[3] remaining;
        size_t count;
        while (position < line.length && count < remaining.length)
            remaining[count++] = word(line, position);
        const lengths = kind == FrameKind.headers ? 2 : 1;
        if (subject.start == subject.end || sid.start == sid.end || position < line.length
                || count < lengths || count > lengths + 1)
            return invalidLine();
        if (count > lengths)
            reply = remaining[0];
        return readLengths(line, remaining[count - lengths .. count]);
    }

    private Error readLengths(scope const(char)[] line, scope const(Span)[] ranges) scope nothrow @nogc
    {
        if (!decimal(ranges[$ - 1].view(line), bodyBytes))
            return invalidLine();
        if (ranges.length == 2 && (!decimal(ranges[0].view(line), headerBytes) || headerBytes == 0
                || headerBytes > bodyBytes))
            return invalidLine();
        if (bodyBytes > body.length)
            return Error(Status.resourceExhausted, "NATS payload exceeds the byte limit");
        return Error.init;
    }

    private Error readBody(scope const(ubyte)[] wire, ref size_t position) scope nothrow @nogc
    {
        const missing = bodyBytes - bodyUsed;
        const available = wire.length - position;
        const count = missing < available ? missing : available;
        if (count != 0)
        {
            body[bodyUsed .. bodyUsed + count] = wire[position .. position + count];
            bodyUsed += count;
            position += count;
        }
        while (position < wire.length && tail < 2)
        {
            if (wire[position++] != (tail == 0 ? '\r' : '\n'))
                return Error(Status.invalidArgument, "invalid NATS payload terminator");
            ++tail;
        }
        ready = tail == 2;
        return Error.init;
    }
}

private Error invalidLine() pure nothrow @nogc
{
    return Error(Status.invalidArgument, "invalid NATS command line");
}

private Span word(scope const(char)[] text, ref size_t position) pure nothrow @nogc
{
    const first = position;
    while (position < text.length && text[position] != ' ')
        ++position;
    const result = Span(first, position);
    while (position < text.length && text[position] == ' ')
        ++position;
    return result;
}

private FrameKind readKind(scope const(char)[] command) pure nothrow @nogc
{
    if (command.length > 4)
        return FrameKind.none;
    char[4] upper;
    foreach (i, value; command)
        upper[i] = value >= 'a' && value <= 'z' ? cast(char)(value - 'a' + 'A') : value;
    static immutable string[] names = ["INFO", "PING", "PONG", "+OK", "-ERR", "MSG", "HMSG"];
    foreach (index, expected; names)
        if (upper[0 .. command.length] == expected)
            return cast(FrameKind)(index + 1);
    return FrameKind.none;
}

bool decimal(scope const(char)[] input, out size_t value) pure nothrow @nogc
{
    if (input.length == 0)
        return false;
    foreach (digit; input)
    {
        if (digit < '0' || digit > '9' || value > (size_t.max - (digit - '0')) / 10)
            return false;
        value = value * 10 + (digit - '0');
    }
    return true;
}
