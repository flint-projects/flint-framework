/// Bounded HTTP/1 response headers and fixed public status translation.
module flint.engine.web.wire;

import core.stdc.time : time;
import flint.arena : Status;
import flint.engine.web.stream : StreamField, validStreamFields;

@safe:

package(flint.engine.web) ushort responseCode(Status code) pure nothrow @nogc
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

package(flint.engine.web) bool validMediaType(scope const(char)[] contentType) pure nothrow @nogc
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

/// Length of an RFC 9110 section 5.6.7 IMF-fixdate such as `Sun, 06 Nov 1994 08:49:37 GMT`.
package(flint.engine.web) enum httpDateBytes = 29;
/// Capacity of the longest Allow value, `GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS`.
package(flint.engine.web) enum allowBytes = 48;

// Module variables are thread-local, so each owner loop keeps its own copy. A response reads the
// coarse wall clock once and reformats only when the second has changed.
private char[httpDateBytes] cachedDate = "Thu, 01 Jan 1970 00:00:00 GMT";
private long cachedSecond;

/// The current Date field value for this worker thread, refreshed at most once per second.
package(flint.engine.web) const(char)[] httpDate() nothrow @nogc
{
    const now = cast(long) time(null);
    if (now != cachedSecond)
    {
        formatHttpDate(now, cachedDate);
        cachedSecond = now;
    }
    return cachedDate[];
}

/// Format Unix seconds as an IMF-fixdate in UTC, using the proleptic Gregorian civil calendar.
package(flint.engine.web) void formatHttpDate(long seconds, ref char[httpDateBytes] output) pure nothrow @nogc
{
    static immutable string weekdays = "SunMonTueWedThuFriSat";
    static immutable string months = "JanFebMarAprMayJunJulAugSepOctNovDec";
    long days = seconds / 86_400;
    long clock = seconds % 86_400;
    if (clock < 0)
    {
        clock += 86_400;
        --days;
    }
    // 1970-01-01 was a Thursday.
    const weekday = cast(size_t)(((days % 7) + 11) % 7);
    // Days to civil date (H. Hinnant), with eras of 146,097 days starting on 0000-03-01.
    const shifted = days + 719_468;
    const era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097;
    const dayOfEra = shifted - era * 146_097;
    const yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365;
    const dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
    const monthIndex = (5 * dayOfYear + 2) / 153;
    const day = dayOfYear - (153 * monthIndex + 2) / 5 + 1;
    const month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9;
    long year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0);
    year = year < 0 ? 0 : (year > 9999 ? 9999 : year);

    output[0 .. 3] = weekdays[weekday * 3 .. weekday * 3 + 3];
    output[3 .. 5] = ", ";
    twoDigits(output[5 .. 7], day);
    output[7] = ' ';
    output[8 .. 11] = months[cast(size_t)(month - 1) * 3 .. cast(size_t)(month - 1) * 3 + 3];
    output[11] = ' ';
    twoDigits(output[12 .. 14], year / 100);
    twoDigits(output[14 .. 16], year % 100);
    output[16] = ' ';
    twoDigits(output[17 .. 19], clock / 3600);
    output[19] = ':';
    twoDigits(output[20 .. 22], clock / 60 % 60);
    output[22] = ':';
    twoDigits(output[23 .. 25], clock % 60);
    output[25 .. 29] = " GMT";
}

private void twoDigits(scope char[] output, long value) pure nothrow @nogc
{
    output[0] = cast(char)('0' + value / 10);
    output[1] = cast(char)('0' + value % 10);
}

/// Write the Allow value for a method bit set indexed by `Method`, in a fixed order. HEAD is listed
/// only when its bit is set; the router sets it for a GET handler that serves HEAD.
package(flint.engine.web) size_t formatAllow(ubyte methods, ref char[allowBytes] output) pure nothrow @nogc
{
    // Method order: get, post, put, patch, delete_, head, options.
    static immutable string[7] names = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"];
    static immutable ubyte[7] order = [0, 5, 1, 2, 3, 4, 6];
    size_t length;
    foreach (method; order)
    {
        if ((methods & (1 << method)) == 0)
            continue;
        if (length != 0)
        {
            output[length .. length + 2] = ", ";
            length += 2;
        }
        const name = names[method];
        output[length .. length + name.length] = name;
        length += name.length;
    }
    return length;
}

package(flint.engine.web) size_t writeHeader(scope ubyte[] output, ushort status, string contentType,
        size_t length, bool persistent, ubyte versionMinor, ubyte allow = 0) nothrow @nogc
{
    scope writer = HeaderWriter(output);
    writer.write(versionMinor == 0 ? "HTTP/1.0 " : "HTTP/1.1 ");
    writer.decimal(status);
    writer.write(" ");
    writer.write(reason(status));
    writer.write("\r\nDate: ");
    writer.write(httpDate());
    // RFC 9110 sections 8.6 and 15.4.5: 204 never carries Content-Length, and a 304 has no body to frame.
    if (status != 204 && status != 304)
    {
        writer.write("\r\nContent-Length: ");
        writer.decimal(length);
    }
    if (contentType.length != 0)
    {
        writer.write("\r\nContent-Type: ");
        writer.write(contentType);
    }
    // RFC 9110 section 15.5.6: a 405 lists the methods the target resource supports.
    if (status == 405 && allow != 0)
        writeAllow(writer, allow);
    writer.write("\r\nConnection: ");
    writer.write(persistent ? "keep-alive" : "close");
    writer.write("\r\n\r\n");
    return writer.full ? 0 : writer.offset;
}

// Kept out of line: inlined, this buffer cost every ordinary response head about 90 ns (LDC -O3).
pragma(inline, false) private void writeAllow(ref scope HeaderWriter writer, ubyte allow) nothrow @nogc
{
    char[allowBytes] methods = void;
    writer.write("\r\nAllow: ");
    writer.write(methods[0 .. formatAllow(allow, methods)]);
}

package(flint.engine.web) size_t writeStreamHeader(scope ubyte[] output, ushort status,
        scope const(StreamField)[] fields, ubyte minor, bool upgrade) nothrow @nogc
{
    if (!validStreamFields(fields, upgrade))
        return 0;
    scope writer = HeaderWriter(output);
    writer.write(minor == 0 ? "HTTP/1.0 " : "HTTP/1.1 ");
    writer.decimal(status);
    writer.write(" ");
    writer.write(status == 101 ? "Switching Protocols" : reason(status));
    writer.write("\r\n");
    if (!upgrade && !hasField(fields, "date"))
    {
        writer.write("Date: ");
        writer.write(httpDate());
        writer.write("\r\n");
    }
    foreach (ref field; fields)
    {
        writer.write(field.name);
        writer.write(": ");
        writer.write(field.value);
        writer.write("\r\n");
    }
    if (!upgrade)
    {
        if (minor == 1)
            writer.write("Transfer-Encoding: chunked\r\n");
        writer.write("Connection: close\r\n");
    }
    writer.write("\r\n");
    return writer.full ? 0 : writer.offset;
}

/// How a fiber route's body is delimited on the wire.
package(flint.engine.web) enum FiberFraming : ubyte
{
    /// `Content-Length` with the exact body length.
    length,
    /// `Transfer-Encoding: chunked` (HTTP/1.1).
    chunked,
    /// No body and no framing field: 1xx, 204 and 304.
    none,
    /// Delimited by closing the connection (HTTP/1.0 with an unknown length).
    close
}

/// The connection fields a fiber route's head ends with, as Tomcat's `Http11Processor.prepareResponse` writes them.
package(flint.engine.web) struct FiberPersistence
{
    /// The connection serves another request after this response.
    bool keep;
    /// The request named `keep-alive` in its `Connection` field.
    bool requested;
    /// Seconds announced in `Keep-Alive: timeout=N`.
    long timeoutSeconds;
}

/// Write a fiber route's head: `HTTP/1.x <status> ` with no reason phrase, the application fields in order,
/// the framing field, `Date` unless the application sent one, then the connection fields. Returns 0 when the
/// fields are invalid or the head does not fit.
// dfmt off
package(flint.engine.web) size_t writeFiberHeader(scope ubyte[] output, ushort status,
        scope const(StreamField)[] fields, FiberFraming framing, ulong length, ubyte minor,
        FiberPersistence persistence) nothrow @nogc
{
    import flint.engine.web.fiber : validFiberFields;

    if (status < 100 || status > 999 || !validFiberFields(fields))
        return 0;
    scope writer = HeaderWriter(output);
    writer.write(minor == 0 ? "HTTP/1.0 " : "HTTP/1.1 ");
    writer.decimal(status);
    writer.write(" \r\n");
    foreach (ref field; fields)
    {
        writer.write(field.name);
        writer.write(": ");
        writer.write(field.value);
        writer.write("\r\n");
    }
    final switch (framing)
    {
    case FiberFraming.length:
        writer.write("Content-Length: ");
        writer.decimal(length);
        writer.write("\r\n");
        break;
    case FiberFraming.chunked:
        writer.write("Transfer-Encoding: chunked\r\n");
        break;
    case FiberFraming.none, FiberFraming.close:
        break;
    }
    if (!hasField(fields, "date"))
    {
        writer.write("Date: ");
        writer.write(httpDate());
        writer.write("\r\n");
    }
    if (!persistence.keep)
        writer.write("Connection: close\r\n");
    else if (persistence.requested && persistence.timeoutSeconds > 0)
    {
        if (minor == 0)
            writer.write("Connection: keep-alive\r\n");
        writer.write("Keep-Alive: timeout=");
        writer.decimal(persistence.timeoutSeconds);
        writer.write("\r\n");
        if (minor != 0)
            writer.write("Connection: keep-alive\r\n");
    }
    writer.write("\r\n");
    return writer.full ? 0 : writer.offset;
}
// dfmt on

/// Whether an application field list already names `name` (ASCII case-insensitive).
package(flint.engine.web) bool hasField(scope const(StreamField)[] fields, scope const(char)[] name) pure nothrow @nogc
{
    foreach (ref field; fields)
    {
        if (field.name.length != name.length)
            continue;
        bool same = true;
        foreach (index, character; field.name)
        {
            const lower = character >= 'A' && character <= 'Z' ? cast(char)(character + 32) : character;
            if (lower != name[index])
            {
                same = false;
                break;
            }
        }
        if (same)
            return true;
    }
    return false;
}

package(flint.engine.web) size_t writeChunk(scope ubyte[] output, scope const(ubyte)[] body) nothrow @nogc
{
    scope writer = HeaderWriter(output);
    char[2 * size_t.sizeof] digits;
    size_t start = digits.length;
    size_t left = body.length;
    do
    {
        digits[--start] = "0123456789abcdef"[left % 16];
        left /= 16;
    }
    while (left != 0);
    writer.write(digits[start .. $]);
    writer.write("\r\n");
    writer.write(cast(const(char)[])
            body);
    writer.write("\r\n");
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
    Reason(404, "Not Found"), Reason(405, "Method Not Allowed"), Reason(408, "Request Timeout"),
    Reason(409, "Conflict"), Reason(413, "Payload Too Large"), Reason(429, "Too Many Requests"),
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

@("IMF-fixdate formatting covers the RFC example, epoch, leap days and century boundaries")
unittest
{
    char[httpDateBytes] text;
    formatHttpDate(784_111_777, text);
    assert(text[] == "Sun, 06 Nov 1994 08:49:37 GMT");
    formatHttpDate(0, text);
    assert(text[] == "Thu, 01 Jan 1970 00:00:00 GMT");
    formatHttpDate(951_782_399, text);
    assert(text[] == "Mon, 28 Feb 2000 23:59:59 GMT");
    formatHttpDate(951_782_400, text);
    assert(text[] == "Tue, 29 Feb 2000 00:00:00 GMT");
    formatHttpDate(4_107_542_400, text);
    assert(text[] == "Mon, 01 Mar 2100 00:00:00 GMT");
    formatHttpDate(-1, text);
    assert(text[] == "Wed, 31 Dec 1969 23:59:59 GMT");
}

@("the per-thread Date cache returns the current second without reformatting within it")
unittest
{
    const first = httpDate();
    assert(first.length == httpDateBytes && first[$ - 4 .. $] == " GMT");
    const second = httpDate();
    assert(first is second, "the cache must return its thread-local storage");
}

version (unittest) private bool endsWith(scope const(char)[] text, scope const(char)[] suffix) pure nothrow @nogc
{
    return text.length >= suffix.length && text[$ - suffix.length .. $] == suffix;
}

@("fiber heads have no reason phrase and put framing after the application's fields, as Tomcat does")
unittest
{
    ubyte[512] output;
    const StreamField[2] fields = [
        StreamField("Allow", "GET"), StreamField("Content-Type", "application/json")
    ];
    auto text = cast(const(char)[]) output[0 .. writeFiberHeader(output[], 405, fields[],
                FiberFraming.chunked, 0, 1, FiberPersistence(true, false, 60))];
    enum head405 = "HTTP/1.1 405 \r\nAllow: GET\r\nContent-Type: application/json\r\n"
        ~ "Transfer-Encoding: chunked\r\nDate: ";
    assert(text.length == head405.length + httpDateBytes + 4 && text[0 .. head405.length] == head405);
    assert(text[$ - 4 .. $] == "\r\n\r\n");

    text = cast(const(char)[]) output[0 .. writeFiberHeader(output[], 200, null,
                FiberFraming.length, 34, 1, FiberPersistence(false, false, 60))];
    enum head200 = "HTTP/1.1 200 \r\nContent-Length: 34\r\n";
    assert(text[0 .. head200.length] == head200 && endsWith(text, "\r\nConnection: close\r\n\r\n"));

    text = cast(const(char)[]) output[0 .. writeFiberHeader(output[], 200, null,
                FiberFraming.length, 0, 1, FiberPersistence(true, true, 60))];
    assert(endsWith(text, "GMT\r\nKeep-Alive: timeout=60\r\nConnection: keep-alive\r\n\r\n"));

    text = cast(const(char)[]) output[0 .. writeFiberHeader(output[], 204, [
        StreamField("Date", "x")
    ], FiberFraming.none, 0, 1, FiberPersistence(true, false, 60))];
    assert(text == "HTTP/1.1 204 \r\nDate: x\r\n\r\n");

    assert(writeFiberHeader(output[], 200, [StreamField("Content-Length", "1")],
            FiberFraming.length, 1, 1, FiberPersistence.init) == 0);
    assert(writeFiberHeader(output[0 .. 20], 200, null, FiberFraming.length, 1, 1, FiberPersistence.init) == 0);
}

@("Allow lists registered methods in a fixed order")
unittest
{
    char[allowBytes] text;
    assert(text[0 .. formatAllow(0b0100001, text)] == "GET, HEAD");
    assert(text[0 .. formatAllow(0b1111111, text)] == "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS");
    assert(formatAllow(0, text) == 0);
}
