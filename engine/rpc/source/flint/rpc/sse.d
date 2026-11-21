/// Server-sent event fields and bounded incremental parsing.
module flint.rpc.sse;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.rpc.utf8 : Utf8State, utf8Valid;

@safe:

/// Server-sent event handler route.
struct Sse
{
    /// Absolute HTTP GET path.
    string path;
}

/// One event and its optional id, event name and reconnect delay.
struct SseEvent
{
    /// Event name. Empty uses the client's default event.
    string event;
    /// Application resume identifier.
    string id;
    /// Event data in the supplied arena.
    Buffer data;
    /// Reconnection time. Zero omits this field.
    uint retryMillis;
}

package(flint.rpc):

enum maximumSseLine = 4 * 1024;
enum maximumSseData = 16 * 1024;
enum maximumSseField = 1024;

Result!Buffer encodeEvent(scope const ref SseEvent event, ref scope RequestArena arena) nothrow @nogc
{
    if (!fieldValid(event.event, true) || !fieldValid(event.id, false))
        return Result!Buffer(Buffer.init, Error(Status.invalidArgument, "invalid SSE event or id field"));
    if (event.data.length > maximumSseData)
        return Result!Buffer(Buffer.init, Error(Status.resourceExhausted, "SSE data exceeds the byte limit"));
    if (event.data == Buffer.init)
        return renderEvent(event, null, arena);

    Result!Buffer output;
    const result = arena.read(event.data, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        output = utf8Valid(bytes) ? renderEvent(event, bytes, arena) : Result!Buffer(Buffer.init,
            Error(Status.invalidArgument, "invalid UTF-8 in SSE data"));
    });
    return result == Status.ok ? output : Result!Buffer(Buffer.init, Error(result, "invalid SSE data handle"));
}

Result!Buffer encodeHeartbeat(scope const(char)[] comment, ref scope RequestArena arena) nothrow @nogc
{
    if (!fieldValid(comment, true))
        return Result!Buffer(Buffer.init, Error(Status.invalidArgument, "invalid SSE heartbeat comment"));
    const output = arena.allocate(comment.length + 4, 1);
    if (!output.ok())
        return output;
    const status = arena.write(output.value, (scope ubyte[] bytes) @safe nothrow @nogc {
        bytes[0 .. 2] = cast(const(ubyte)[]) ": ";
        bytes[2 .. $ - 2] = cast(const(ubyte)[]) comment;
        bytes[$ - 2 .. $] = cast(const(ubyte)[]) "\n\n";
    });
    return status == Status.ok ? output : Result!Buffer(Buffer.init, Error(status, "SSE heartbeat output changed"));
}

private bool fieldValid(scope const(char)[] value, bool allowNul) pure nothrow @nogc
{
    if (value.length > maximumSseField || !utf8Valid(cast(const(ubyte)[]) value))
        return false;
    foreach (character; value)
    {
        if (character == '\r' || character == '\n' || (!allowNul && character == 0))
            return false;
    }
    return true;
}

// dfmt off
private Result!Buffer renderEvent(scope const ref SseEvent event, scope const(ubyte)[] data,
        ref scope RequestArena arena) nothrow @nogc
{
    auto layout = EventWriter();
    if (!layout.format(event, data))
        return Result!Buffer(Buffer.init, Error(Status.resourceExhausted, "SSE data line exceeds the byte limit"));
    const output = arena.allocate(layout.used, 1);
    if (!output.ok())
        return output;
    const status = arena.write(output.value, (scope ubyte[] bytes) @safe nothrow @nogc {
        auto writer = EventWriter(bytes);
        writer.format(event, data);
    });
    return status == Status.ok ? output : Result!Buffer(Buffer.init, Error(status, "SSE event output changed"));
}
// dfmt on

private struct EventWriter
{
    ubyte[] output;
    size_t used;

    void add(scope const(char)[] value) scope pure nothrow @nogc
    {
        if (output.length != 0)
            output[used .. used + value.length] = cast(const(ubyte)[]) value;
        used += value.length;
    }

    void line(scope const(char)[] key, scope const(char)[] value) scope pure nothrow @nogc
    {
        add(key);
        add(value);
        add("\n");
    }

    bool format(scope const ref SseEvent event, scope const(ubyte)[] bytes) scope pure nothrow @nogc
    {
        if (event.event.length != 0)
            line("event: ", event.event);
        if (event.id.length != 0)
            line("id: ", event.id);
        if (event.retryMillis != 0)
        {
            char[10] digits;
            size_t next = digits.length;
            uint value = event.retryMillis;
            while (value != 0)
            {
                digits[--next] = cast(char)('0' + value % 10);
                value /= 10;
            }
            line("retry: ", digits[next .. $]);
        }

        size_t first;
        auto data = cast(const(char)[]) bytes;
        for (size_t index; index < data.length; ++index)
        {
            if (data[index] == '\r' || data[index] == '\n')
            {
                if (index - first > maximumSseLine - "data: ".length)
                    return false;
                line("data: ", data[first .. index]);
                if (data[index] == '\r' && index + 1 < data.length && data[index + 1] == '\n')
                    ++index;
                first = index + 1;
            }
        }
        if (data.length - first > maximumSseLine - "data: ".length)
            return false;
        line("data: ", data[first .. $]);
        add("\n");
        return true;
    }
}

/// A decoded event-stream notification kind.
public enum SseNotice : ubyte
{
    /// A complete event with its data and the last event id.
    event,
    /// A comment line, including a server heartbeat.
    comment,
    /// A new reconnect delay in milliseconds.
    retry
}

/// Called synchronously with temporary spans for event, last id, data or a comment.
public alias SseVisitor = void delegate(SseNotice, scope const(char)[] event, scope const(char)[] id,
        scope const(char)[] value, uint retryMillis) @safe nothrow @nogc;

/// A byte-fed parser with independent line and event budgets.
struct SseDecoder
{
    private char[maximumSseLine] lineBytes;
    private char[maximumSseData + 1] dataBytes;
    private char[maximumSseField] eventBytes;
    private char[maximumSseField] idBytes;
    private size_t lineUsed;
    private size_t dataUsed;
    private size_t eventUsed;
    private size_t idUsed;
    private bool firstLine = true;
    private bool skipLF;
    private bool failed;

    Error feed(scope const(ubyte)[] input, scope SseVisitor visitor) scope nothrow @nogc
    {
        if (visitor is null)
            return Error(Status.invalidArgument, "SSE visitor required");
        if (failed)
            return Error(Status.resourceExhausted, "SSE decoder exceeded its bounds");
        foreach (value; input)
        {
            if (skipLF)
            {
                skipLF = false;
                if (value == '\n')
                    continue;
            }
            if (value == '\r' || value == '\n')
            {
                skipLF = value == '\r';
                if (!deliverLine(visitor))
                    return limit();
                lineUsed = 0;
            }
            else
            {
                if (lineUsed == lineBytes.length)
                    return limit();
                lineBytes[lineUsed++] = cast(char) value;
            }
        }
        return Error.init;
    }

    private Error limit() scope pure nothrow @nogc
    {
        failed = true;
        return Error(Status.resourceExhausted, "SSE line or field exceeds the byte limit");
    }

    private bool deliverLine(scope SseVisitor visitor) scope nothrow @nogc
    {
        scope line = lineBytes[0 .. lineUsed];
        if (firstLine)
        {
            firstLine = false;
            if (line.length >= 3 && line[0 .. 3] == "\xef\xbb\xbf")
                line = line[3 .. $];
        }
        if (utf8Valid(cast(const(ubyte)[]) line))
            return processLine(line, visitor);
        char[maximumSseLine] replacement;
        const count = repairUtf8(line, replacement[]);
        return count != size_t.max && processLine(replacement[0 .. count], visitor);
    }

    private bool processLine(scope const(char)[] line, scope SseVisitor visitor) scope nothrow @nogc
    {
        if (line.length == 0)
        {
            dispatchEvent(visitor);
            return true;
        }
        size_t separator;
        while (separator < line.length && line[separator] != ':')
            ++separator;
        size_t start = separator < line.length ? separator + 1 : separator;
        if (start < line.length && line[start] == ' ')
            ++start;
        scope value = line[start .. $];
        switch (line[0 .. separator])
        {
        case "":
            visitor(SseNotice.comment, null, null, value, 0);
            return true;
        case "event":
            return store(eventBytes[], eventUsed, value);
        case "data":
            return appendData(value);
        case "id":
            return storeId(value);
        case "retry":
            const delay = parseDelay(value);
            if (delay >= 0)
                visitor(SseNotice.retry, null, null, null, cast(uint) delay);
            return true;
        default:
            return true;
        }
    }

    private void dispatchEvent(scope SseVisitor visitor) scope nothrow @nogc
    {
        if (dataUsed != 0)
        {
            visitor(SseNotice.event, eventUsed == 0 ? "message" : eventBytes[0 .. eventUsed],
                    idBytes[0 .. idUsed], dataBytes[0 .. dataUsed - 1], 0);
            dataUsed = 0;
        }
        eventUsed = 0;
    }

    private bool appendData(scope const(char)[] value) scope nothrow @nogc
    {
        if (value.length >= dataBytes.length - dataUsed)
            return false;
        dataBytes[dataUsed .. dataUsed + value.length] = value;
        dataUsed += value.length;
        dataBytes[dataUsed++] = '\n';
        return true;
    }

    private bool storeId(scope const(char)[] value) scope nothrow @nogc
    {
        foreach (character; value)
        {
            if (character == 0)
                return true;
        }
        return store(idBytes[], idUsed, value);
    }

    private static bool store(scope char[] buffer, out size_t used, scope const(char)[] input) pure nothrow @nogc
    {
        if (input.length > buffer.length)
            return false;
        used = input.length;
        buffer[0 .. used] = input;
        return true;
    }

    private static long parseDelay(scope const(char)[] value) pure nothrow @nogc
    {
        if (value.length == 0)
            return -1;
        ulong number;
        foreach (character; value)
        {
            if (character < '0' || character > '9')
                return -1;
            number = number * 10 + character - '0';
            if (number > uint.max)
                return -1;
        }
        return cast(long) number;
    }

}

private size_t repairUtf8(scope const(char)[] source, scope char[] output) pure nothrow @nogc
{
    size_t read;
    size_t written;
    while (read < source.length)
    {
        Utf8State scalar;
        const first = read;
        bool valid;
        do
        {
            valid = scalar.accept(cast(ubyte) source[read]);
            if (valid)
                ++read;
        }
        while (valid && read < source.length && !scalar.complete());

        if (valid && scalar.complete())
        {
            const length = read - first;
            if (length > output.length - written)
                return size_t.max;
            output[written .. written + length] = source[first .. read];
            written += length;
        }
        else
        {
            if (output.length - written < 3)
                return size_t.max;
            output[written .. written + 3] = "\xef\xbf\xbd";
            written += 3;
            if (read == first)
                ++read;
        }
    }
    return written;
}
