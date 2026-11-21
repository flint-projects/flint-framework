/// Bounded request assembly over the pinned HTTP/1 parser.
module flint.web.http1;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.web.ffi.shim : Http1Info, Http1Parser, HttpEvent, HttpProgress;
import flint.web.types : HeaderRecord, Method, RequestMetadata, lower, maximumFields, sameName;

@safe:

/// One request boundary observed by the connection owner.
package(flint.web) enum ReadOutcome
{
    more,
    request,
    rejected
}

/// Optional limit selector after the request headers determine the route.
// dfmt off
package(flint.web) alias BodyLimit = size_t delegate(Method, Buffer,
        ref scope RequestArena) @safe nothrow @nogc;
// dfmt on

/// The parser instance and request scratch remain on their owning connection.
package(flint.web) struct Http1Reader
{
    RequestMetadata metadata;
    ushort responseStatus;
    bool keepAlive;
    bool upgradeRequested;
    ubyte versionMinor;

    private Http1Parser parser;
    private size_t headerLimit;
    private size_t bodyLimit;
    private size_t defaultBodyLimit;
    private size_t wireHeaderBytes;
    private size_t trailerBytes;
    private size_t nameBytes;
    private uint nameStart;
    private uint trailerCount;
    private Buffer value;
    private bool readingHeaders;
    private bool readingQuery;
    private bool sawHost;
    private bool sawLength;
    private bool sawTransfer;

    Error open(ulong token, ubyte[] names, size_t maxHeaderBytes, size_t maxBodyBytes) nothrow @nogc
    {
        if (maxHeaderBytes == 0 || maxHeaderBytes > uint.max || names.length < maxHeaderBytes
                || metadata.headers.length != maximumFields)
            return Error(Status.invalidArgument, "invalid HTTP header scratch capacity");
        const result = parser.open(token);
        if (result.code == Status.ok)
            prepare(names, maxHeaderBytes, maxBodyBytes);
        return result;
    }

    void prepare(ubyte[] names, size_t maxHeaderBytes, size_t maxBodyBytes) nothrow @nogc
    {
        metadata.names = names;
        headerLimit = maxHeaderBytes;
        defaultBodyLimit = maxBodyBytes;
    }

    void setBodyLimit(size_t cap) nothrow @nogc
    {
        bodyLimit = cap;
    }

    Status receiveH2Header(scope const(ubyte)[] name, scope const(ubyte)[] bytes, bool trailer,
            ref scope RequestArena arena) nothrow @nogc
    {
        if (!accountHeader(name.length, bytes.length))
            return Status.resourceExhausted;
        if (name.length == 0)
            return Status.invalidArgument;
        if (name[0] == ':')
        {
            if (trailer)
                return Status.invalidArgument;
            if (name == cast(const(ubyte)[]) ":path")
                return target(bytes, arena);
            return name == cast(const(ubyte)[]) ":method" ? setMethod(bytes) : Status.ok;
        }
        if (metadata.fieldCount + trailerCount >= maximumFields)
            return Status.resourceExhausted;
        if (trailer)
        {
            ++trailerCount;
            return Status.ok;
        }
        const started = fieldName(name);
        if (started != Status.ok)
            return started;
        const stored = extend(arena, value, bytes);
        return stored == Status.ok ? finishField(arena) : stored;
    }

    private bool accountHeader(size_t name, size_t value) nothrow @nogc
    {
        const remaining = headerLimit - wireHeaderBytes;
        if (name > remaining || value > remaining - name || remaining - name - value < 4)
            return false;
        wireHeaderBytes += name + value + 4;
        return true;
    }

    private Status setMethod(scope const(ubyte)[] value) nothrow @nogc
    {
        static immutable string[] methods = [
            "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"
        ];
        foreach (index, method; methods)
        {
            if (value == cast(const(ubyte)[]) method)
            {
                metadata.method = cast(Method) index;
                return Status.ok;
            }
        }
        return Status.unsupported;
    }

    Status receiveH2Body(scope const(ubyte)[] bytes, ref scope RequestArena arena) nothrow @nogc
    {
        return receive(HttpEvent.body, bytes, arena);
    }

    bool finishH2(ref scope RequestArena arena) nothrow @nogc
    {
        metadata.valid = complete(arena);
        return metadata.valid;
    }

    bool begin() nothrow @nogc
    {
        metadata.reset();
        bodyLimit = defaultBodyLimit;
        if (metadata.generation == ulong.max || metadata.headers.length != maximumFields)
            return false;
        ++metadata.generation;
        responseStatus = 400;
        keepAlive = false;
        upgradeRequested = false;
        versionMinor = 1;
        wireHeaderBytes = 0;
        trailerBytes = 0;
        nameBytes = 0;
        nameStart = 0;
        trailerCount = 0;
        value = Buffer.init;
        readingHeaders = true;
        readingQuery = false;
        sawHost = false;
        sawLength = false;
        sawTransfer = false;
        return true;
    }

    bool awaitingHeaders() const nothrow @nogc
    {
        return readingHeaders;
    }

    void close() nothrow @nogc
    {
        metadata.reset();
        metadata.names = null;
        parser.close();
    }

    // dfmt off
    ReadOutcome feed(scope const(ubyte)[] input, ref scope RequestArena arena, out size_t position,
            scope BodyLimit selectLimit = null) nothrow @nogc
    {
        do
        {
            Status rejected;
            const progress = advance(input, arena, position, rejected);
            final switch (progress)
            {
            case HttpProgress.more:
                return readingHeaders && wireHeaderBytes == headerLimit ? reject(431) : ReadOutcome.more;
            case HttpProgress.failed:
                if (rejected == Status.outOfMemory)
                    return reject(503);
                return reject(responseStatus);
            case HttpProgress.headers:
                const status = acceptHeaders(arena, selectLimit);
                if (status != 0)
                    return reject(status);
                if (!upgradeRequested)
                    break;
                return finishRequest(arena);
            case HttpProgress.complete:
                return finishRequest(arena);
            }
        }
        while (true);
    }
    // dfmt on

    private ReadOutcome finishRequest(ref scope RequestArena arena) nothrow @nogc
    {
        if (!complete(arena))
            return reject(503);
        metadata.valid = true;
        return ReadOutcome.request;
    }

    private HttpProgress advance(scope const(ubyte)[] input, ref scope RequestArena arena,
            ref size_t position, out Status rejected) nothrow @nogc
    {
        const remaining = input.length - position;
        const allowance = headerLimit - wireHeaderBytes;
        if (readingHeaders && allowance == 0)
        {
            rejected = limited(431);
            return HttpProgress.failed;
        }
        const length = readingHeaders && allowance < remaining ? allowance : remaining;
        const parsed = parser.feed(input[position .. position + length], (HttpEvent event,
                scope const(ubyte)[] bytes) @safe nothrow @nogc {
            return receive(event, bytes, arena);
        });
        position += parsed.consumed;
        if (readingHeaders)
            wireHeaderBytes += parsed.consumed;
        rejected = parsed.rejected;
        return parsed.progress;
    }

    private ReadOutcome reject(ushort status) nothrow @nogc
    {
        responseStatus = status;
        keepAlive = false;
        metadata.valid = false;
        return ReadOutcome.rejected;
    }

    private ushort acceptHeaders(ref scope RequestArena arena, scope BodyLimit selectLimit) nothrow @nogc
    {
        Http1Info info;
        if (!parser.headers(info) || info.major != 1 || info.minor > 1)
            return 505;
        versionMinor = info.minor;
        if (!validFraming(info))
            return 400;
        if (info.method > Method.options)
            return 501;
        metadata.method = cast(Method) info.method;
        if (selectLimit !is null)
            bodyLimit = selectLimit(metadata.method, metadata.path, arena);
        if (info.contentLength > bodyLimit)
            return 413;
        upgradeRequested = info.upgrade != 0;
        if (upgradeRequested && !validUpgrade(info))
            return 400;
        keepAlive = info.keepAlive != 0 && !upgradeRequested;
        readingHeaders = false;
        return 0;
    }

    private bool validFraming(scope const ref Http1Info info) const pure nothrow @nogc
    {
        return (versionMinor != 1 || sawHost) && (!sawTransfer || (!sawLength && info.chunked != 0));
    }

    private static bool validUpgrade(scope const ref Http1Info info) pure nothrow @nogc
    {
        return info.minor == 1 && info.chunked == 0 && info.contentLength == 0;
    }

    private Status receive(HttpEvent event, scope const(ubyte)[] bytes, ref scope RequestArena arena) nothrow @nogc
    {
        switch (event)
        {
        case HttpEvent.begin, HttpEvent.headers, HttpEvent.complete:
            return Status.ok;
        case HttpEvent.target:
            return target(bytes, arena);
        case HttpEvent.body:
            if (bytes.length > bodyLimit - metadata.body.length())
                return limited(413);
            return extend(arena, metadata.body, bytes);
        default:
            return receiveField(event, bytes, arena);
        }
    }

    private Status receiveField(HttpEvent event, scope const(ubyte)[] bytes, ref scope RequestArena arena) nothrow @nogc
    {
        switch (event)
        {
        case HttpEvent.field:
            return fieldName(bytes);
        case HttpEvent.fieldEnd:
            if (metadata.fieldCount + trailerCount >= maximumFields)
                return limited(431);
            return nameBytes > nameStart ? Status.ok : Status.invalidArgument;
        case HttpEvent.value:
            if (!readingHeaders && !accountTrailer(bytes.length))
                return limited(431);
            return extend(arena, value, bytes);
        case HttpEvent.valueEnd:
            return finishField(arena);
        default:
            return Status.invalidArgument;
        }
    }

    private Status limited(ushort status) nothrow @nogc
    {
        responseStatus = status;
        return Status.resourceExhausted;
    }

    private Status target(scope const(ubyte)[] bytes, ref scope RequestArena arena) nothrow @nogc
    {
        if (readingQuery)
            return extend(arena, metadata.query, bytes);

        size_t position;
        while (position < bytes.length && bytes[position] != '?')
            ++position;
        const result = extend(arena, metadata.path, bytes[0 .. position]);
        if (result != Status.ok || position == bytes.length)
            return result;
        readingQuery = true;
        return extend(arena, metadata.query, bytes[position + 1 .. $]);
    }

    private Status fieldName(scope const(ubyte)[] bytes) nothrow @nogc
    {
        if (bytes.length > metadata.names.length - nameBytes || (!readingHeaders && !accountTrailer(bytes.length)))
            return limited(431);
        foreach (byteValue; bytes)
            metadata.names[nameBytes++] = lower(byteValue);
        return Status.ok;
    }

    private bool accountTrailer(size_t length) nothrow @nogc
    {
        if (length > headerLimit - wireHeaderBytes - trailerBytes)
            return false;
        trailerBytes += length;
        return true;
    }

    private Status finishField(ref scope RequestArena arena) nothrow @nogc
    {
        auto name = metadata.names[nameStart .. nameBytes];
        if (!readingHeaders)
            return finishTrailer(name);
        const filled = extend(arena, value, null);
        if (filled != Status.ok)
            return filled;
        const framing = checkFraming(name, arena);
        if (framing != Status.ok)
            return framing;

        metadata.headers[metadata.fieldCount] = HeaderRecord(nameStart, cast(uint) nameBytes, value);
        ++metadata.fieldCount;
        nameStart = cast(uint) nameBytes;
        value = Buffer.init;
        return Status.ok;
    }

    private Status finishTrailer(scope const(ubyte)[] name) nothrow @nogc
    {
        if (sameName(name, "content-length") || sameName(name, "transfer-encoding") || sameName(name,
                "host") || sameName(name, "connection"))
            return Status.invalidArgument;
        if (!accountTrailer(4))
            return limited(431);
        ++trailerCount;
        nameBytes = nameStart;
        value = Buffer.init;
        return Status.ok;
    }

    private Status checkFraming(scope const(ubyte)[] name, ref scope RequestArena arena) nothrow @nogc
    {
        if (sameName(name, "host"))
        {
            if (sawHost || !headerContainsValue(arena, value))
                return Status.invalidArgument;
            sawHost = true;
        }
        else if (sameName(name, "content-length"))
        {
            if (sawLength || sawTransfer)
                return Status.invalidArgument;
            sawLength = true;
        }
        else if (sameName(name, "transfer-encoding"))
        {
            if (sawTransfer || sawLength || !isChunked(arena, value))
                return Status.invalidArgument;
            sawTransfer = true;
        }
        return Status.ok;
    }

    private bool complete(ref scope RequestArena arena) nothrow @nogc
    {
        return metadata.path.length() != 0 && extend(arena, metadata.query, null) == Status.ok
            && extend(arena, metadata.body, null) == Status.ok;
    }
}

private Status extend(ref scope RequestArena arena, ref Buffer destination, scope const(ubyte)[] fragment) nothrow @nogc
{
    if (fragment.length == 0 && destination != Buffer.init)
        return Status.ok;
    if (destination == Buffer.init)
    {
        auto stored = arena.copyIn(fragment);
        if (stored.ok())
            destination = stored.value;
        return stored.error.code;
    }
    return arena.append(destination, fragment);
}

private bool headerContainsValue(ref scope RequestArena arena, Buffer buffer) nothrow @nogc
{
    bool found;
    const result = arena.read(buffer, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        foreach (value; bytes)
        {
            if (value != ' ' && value != '\t')
            {
                found = true;
                break;
            }
        }
    });
    return result == Status.ok && found;
}

private bool isChunked(ref scope RequestArena arena, Buffer buffer) nothrow @nogc
{
    bool supported;
    const result = arena.read(buffer, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        size_t first;
        size_t last = bytes.length;
        while (first < last && (bytes[first] == ' ' || bytes[first] == '\t'))
            ++first;
        while (last > first && (bytes[last - 1] == ' ' || bytes[last - 1] == '\t'))
            --last;
        supported = sameName(bytes[first .. last], "chunked");
    });
    return result == Status.ok && supported;
}
