/// Bounded HTTP/1 response headers and fixed public status translation.
module flint.web.wire;

import flint.arena : Status;

@safe:

package(flint.web) ushort responseCode(Status code) pure nothrow @nogc
{
    switch (code)
    {
    case Status.invalidArgument:
        return 400;
    case Status.permissionDenied:
        return 403;
    case Status.notFound:
        return 404;
    case Status.conflict:
        return 409;
    case Status.timedOut:
        return 504;
    case Status.resourceExhausted, Status.unavailable:
        return 503;
    default:
        return 500;
    }
}

package(flint.web) bool validMediaType(scope const(char)[] contentType) pure nothrow @nogc
{
    if (contentType.length > 256)
        return false;
    foreach (character; contentType)
    {
        if (character < ' ' || character > '~')
            return false;
    }
    return true;
}

package(flint.web) size_t writeHeader(scope ubyte[] output, ushort status, string contentType,
        size_t length, bool persistent, ubyte versionMinor) nothrow @nogc
{
    scope writer = HeaderWriter(output);
    writer.write(versionMinor == 0 ? "HTTP/1.0 " : "HTTP/1.1 ");
    writer.decimal(status);
    writer.write(" ");
    writer.write(reason(status));
    writer.write("\r\nContent-Length: ");
    writer.decimal(length);
    if (contentType.length != 0)
    {
        writer.write("\r\nContent-Type: ");
        writer.write(contentType);
    }
    writer.write("\r\nConnection: ");
    writer.write(persistent ? "keep-alive" : "close");
    writer.write("\r\n\r\n");
    return writer.full ? 0 : writer.offset;
}

private struct HeaderWriter
{
    ubyte[] destination;
    size_t offset;
    bool full;

    void write(scope const(char)[] bytes) scope nothrow @nogc
    {
        if (bytes.length > destination.length - offset)
        {
            full = true;
            return;
        }
        foreach (character; bytes)
            destination[offset++] = cast(ubyte) character;
    }

    void decimal(ulong number) scope nothrow @nogc
    {
        char[20] digits;
        size_t first = digits.length;
        do
        {
            digits[--first] = cast(char)('0' + number % 10);
            number /= 10;
        }
        while (number != 0);
        write(digits[first .. $]);
    }
}

private struct Reason
{
    ushort code;
    string text;
}

private immutable Reason[] reasons = [
    Reason(200, "OK"), Reason(201, "Created"), Reason(204, "No Content"), Reason(400,
            "Bad Request"), Reason(401, "Unauthorized"), Reason(403, "Forbidden"),
    Reason(404, "Not Found"), Reason(408, "Request Timeout"), Reason(409, "Conflict"),
    Reason(413, "Payload Too Large"), Reason(429, "Too Many Requests"),
    Reason(431, "Request Header Fields Too Large"), Reason(500, "Internal Server Error"),
    Reason(501, "Not Implemented"), Reason(503, "Service Unavailable"), Reason(504,
            "Gateway Timeout"), Reason(505, "HTTP Version Not Supported")
];

private string reason(ushort status) pure nothrow @nogc
{
    foreach (ref description; reasons)
        if (description.code == status)
            return description.text;
    return "";
}
