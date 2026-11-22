/// Read only the bounded XML fields used by S3 upload responses.
module flint.storage.xml;

import flint.arena : Error, Status;

@safe:

package(flint.storage) enum EnvelopeKind : ubyte
{
    unknown,
    initiated,
    completed,
    serviceError
}

package(flint.storage) struct Span
{
    size_t first;
    size_t last;
}

package(flint.storage) struct Envelope
{
    EnvelopeKind kind;
    Span uploadId;
    Span etag;
}

private struct Tag
{
    Span name;
    size_t text;
    bool nested;
}

private enum TagEnd : ubyte
{
    invalid,
    opened,
    empty
}

package(flint.storage) Error readEnvelope(scope const(char)[] raw, out Envelope result) pure nothrow @nogc
{
    if (raw.length == 0 || raw.length > 1024 * 1024)
        return Error(Status.resourceExhausted, "S3 XML response size is outside its limit");
    size_t cursor;
    skipSpace(raw, cursor);
    if (!declaration(raw, cursor))
        return malformed(cursor);
    skipSpace(raw, cursor);
    if (cursor == raw.length)
        return malformed(cursor);
    return readTree(raw, cursor, result);
}

private bool declaration(scope const(char)[] raw, ref size_t cursor) pure nothrow @nogc
{
    if (!starts(raw, cursor, "<?xml "))
        return true;
    cursor += 6;
    while (cursor < raw.length && raw[cursor] != '<' && !starts(raw, cursor, "?>"))
        ++cursor;
    if (!starts(raw, cursor, "?>"))
        return false;
    cursor += 2;
    return true;
}

private Error readTree(scope const(char)[] raw, size_t cursor, out Envelope result) pure nothrow @nogc
{
    Tag[32] stack;
    size_t depth;
    Envelope verified;
    bool closed;
    while (cursor < raw.length)
    {
        if (raw[cursor] != '<')
        {
            if (!advanceText(raw, cursor, depth != 0))
                return malformed(cursor);
            continue;
        }
        if (closed)
            return malformed(cursor);
        const handled = raw.length - cursor >= 2 && raw[cursor + 1] == '/' ? endTag(raw, cursor, stack[],
                depth, verified) : startTag(raw, cursor, stack[], depth, verified);
        if (handled.code != Status.ok)
            return handled;
        closed = depth == 0;
    }
    if (!closed || verified.kind == EnvelopeKind.unknown)
        return malformed(cursor);
    result = verified;
    return Error.init;
}

private bool advanceText(scope const(char)[] raw, ref size_t cursor, bool inside) pure nothrow @nogc
{
    const character = raw[cursor++];
    if (inside && character == '&')
        return entity(raw, cursor) != 0;
    return space(character) || (inside && character >= ' ' && character != 0x7f);
}

private Error startTag(scope const(char)[] raw, ref size_t cursor, scope Tag[] stack,
        ref size_t depth, ref Envelope envelope) pure nothrow @nogc
{
    if (depth == stack.length)
        return Error(Status.resourceExhausted, "S3 XML maximum depth exceeded", cursor);
    ++cursor;
    Span name;
    if (!readName(raw, cursor, name))
        return malformed(cursor);
    const end = attributes(raw, cursor);
    if (end == TagEnd.invalid)
        return malformed(cursor);
    const opening = raw[name.first .. name.last];
    if (depth == 0)
    {
        final switch (envelope.kind)
        {
        case EnvelopeKind.unknown:
            envelope.kind = rootKind(opening);
            break;
        case EnvelopeKind.initiated, EnvelopeKind.completed, EnvelopeKind.serviceError:
            return malformed(cursor);
        }
        if (envelope.kind == EnvelopeKind.unknown)
            return malformed(name.first);
    }
    else
        stack[depth - 1].nested = true;
    if (end == TagEnd.opened)
        stack[depth++] = Tag(name, cursor, false);
    return Error.init;
}

private Error endTag(scope const(char)[] raw, ref size_t cursor, scope Tag[] stack, ref size_t depth,
        ref Envelope envelope) pure nothrow @nogc
{
    const closing = cursor;
    cursor += 2;
    Span name;
    if (depth == 0 || !readName(raw, cursor, name))
        return malformed(cursor);
    const open = stack[--depth];
    const element = raw[name.first .. name.last];
    if (element != raw[open.name.first .. open.name.last])
        return malformed(name.first);
    skipSpace(raw, cursor);
    if (cursor == raw.length || raw[cursor++] != '>')
        return malformed(cursor);
    if (depth != 1)
        return Error.init;
    if (envelope.kind == EnvelopeKind.initiated && element == "UploadId")
        return value(open, closing, envelope.uploadId);
    if (envelope.kind == EnvelopeKind.completed && element == "ETag")
        return value(open, closing, envelope.etag);
    return Error.init;
}

private Error value(Tag tag, size_t end, ref Span destination) pure nothrow @nogc
{
    if (tag.nested || tag.text == end || destination.last != 0)
        return malformed(tag.text);
    destination = Span(tag.text, end);
    return Error.init;
}

private TagEnd attributes(scope const(char)[] raw, ref size_t cursor) pure nothrow @nogc
{
    while (cursor < raw.length)
    {
        const separated = space(raw[cursor]);
        skipSpace(raw, cursor);
        if (cursor == raw.length)
            return TagEnd.invalid;
        if (raw[cursor] == '>')
        {
            ++cursor;
            return TagEnd.opened;
        }
        if (starts(raw, cursor, "/>"))
        {
            cursor += 2;
            return TagEnd.empty;
        }
        if (!separated || !attribute(raw, cursor))
            return TagEnd.invalid;
    }
    return TagEnd.invalid;
}

private bool attribute(scope const(char)[] raw, ref size_t cursor) pure nothrow @nogc
{
    Span ignored;
    if (!readName(raw, cursor, ignored))
        return false;
    skipSpace(raw, cursor);
    if (cursor == raw.length || raw[cursor++] != '=')
        return false;
    skipSpace(raw, cursor);
    if (cursor == raw.length || (raw[cursor] != '"' && raw[cursor] != '\''))
        return false;
    const delimiter = raw[cursor++];
    while (cursor < raw.length && raw[cursor] != delimiter)
    {
        if (raw[cursor] < ' ' || raw[cursor] == '<' || raw[cursor] == '&')
            return false;
        ++cursor;
    }
    if (cursor == raw.length)
        return false;
    ++cursor;
    return true;
}

private bool readName(scope const(char)[] raw, ref size_t cursor, out Span name) pure nothrow @nogc
{
    const first = cursor;
    while (cursor < raw.length && nameChar(raw[cursor], cursor != first))
        ++cursor;
    name = Span(first, cursor);
    return cursor > first && cursor - first <= 128;
}

private bool nameChar(char value, bool continuation) pure nothrow @nogc
{
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || value == '_'
        || (continuation && ((value >= '0' && value <= '9') || value == ':' || value == '-' || value == '.'));
}

private EnvelopeKind rootKind(scope const(char)[] name) pure nothrow @nogc
{
    switch (name)
    {
    case "InitiateMultipartUploadResult":
        return EnvelopeKind.initiated;
    case "CompleteMultipartUploadResult":
        return EnvelopeKind.completed;
    case "Error":
        return EnvelopeKind.serviceError;
    default:
        return EnvelopeKind.unknown;
    }
}

// UTF-8 code units of a scalar, as std.utf.encode!(Yes.useReplacementDchar) writes them: surrogates and values
// beyond U+10FFFF become U+FFFD.
private size_t encodeReplacing(ref char[4] buffer, dchar scalar) pure nothrow @nogc
{
    if (scalar <= 0x7F)
    {
        buffer[0] = cast(char) scalar;
        return 1;
    }
    if (scalar <= 0x7FF)
    {
        buffer[0] = cast(char)(0xC0 | (scalar >> 6));
        buffer[1] = cast(char)(0x80 | (scalar & 0x3F));
        return 2;
    }
    if (scalar <= 0xFFFF || scalar > 0x10FFFF)
    {
        if ((scalar >= 0xD800 && scalar <= 0xDFFF) || scalar > 0x10FFFF)
            scalar = 0xFFFD;
        buffer[0] = cast(char)(0xE0 | (scalar >> 12));
        buffer[1] = cast(char)(0x80 | ((scalar >> 6) & 0x3F));
        buffer[2] = cast(char)(0x80 | (scalar & 0x3F));
        return 3;
    }
    buffer[0] = cast(char)(0xF0 | (scalar >> 18));
    buffer[1] = cast(char)(0x80 | ((scalar >> 12) & 0x3F));
    buffer[2] = cast(char)(0x80 | ((scalar >> 6) & 0x3F));
    buffer[3] = cast(char)(0x80 | (scalar & 0x3F));
    return 4;
}

// dfmt off
package(flint.storage) Error copyXmlText(scope const(char)[] raw, Span span,
        scope char[] target, out size_t used) pure nothrow @nogc
{
    if (span.first >= span.last || span.last > raw.length)
        return malformed(span.first);
    for (size_t cursor = span.first; cursor < span.last;)
    {
        if (used == target.length)
            return Error(Status.resourceExhausted, "S3 XML field exceeds its limit", cursor);
        const character = raw[cursor++];
        if (character == '&')
        {
            const scalar = entity(raw[0 .. span.last], cursor);
            if (!scalar)
                return malformed(cursor);
            char[4] encoded;
            const count = encodeReplacing(encoded, scalar);
            if (count > target.length - used)
                return Error(Status.resourceExhausted, "S3 XML field exceeds its limit", cursor);
            target[used .. used + count] = encoded[0 .. count];
            used += count;
        }
        else
            target[used++] = character;
    }
    return Error.init;
}
// dfmt on

private dchar entity(scope const(char)[] raw, ref size_t cursor) pure nothrow @nogc
{
    if (starts(raw, cursor, "#"))
    {
        ++cursor;
        return characterReference(raw, cursor);
    }
    static immutable string[5] entities = ["amp;", "lt;", "gt;", "quot;", "apos;"];
    static immutable string decoded = "&<>\"'";
    foreach (index, name; entities)
        if (starts(raw, cursor, name))
        {
            cursor += name.length;
            return decoded[index];
        }
    return 0;
}

private dchar characterReference(scope const(char)[] raw, ref size_t cursor) pure nothrow @nogc
{
    const hexadecimal = starts(raw, cursor, "x");
    const base = hexadecimal ? 16u : 10u;
    cursor += hexadecimal;
    const first = cursor;
    uint number;
    while (cursor < raw.length && raw[cursor] != ';')
    {
        const digit = hexDigit(raw[cursor++]);
        if (digit >= base || number > (0x10_ffffu - digit) / base)
            return 0;
        number = number * base + digit;
    }
    if (cursor == first || cursor == raw.length || !xmlScalar(number))
        return 0;
    ++cursor;
    return cast(dchar) number;
}

private uint hexDigit(char item) pure nothrow @nogc
{
    if (item >= '0' && item <= '9')
        return item - '0';
    const lower = cast(char)(item | 0x20);
    return lower >= 'a' && lower <= 'f' ? lower - 'a' + 10 : uint.max;
}

private bool xmlScalar(uint value) pure nothrow @nogc
{
    return value == 9 || value == 10 || value == 13 || (value >= 0x20 && value <= 0xd7ff)
        || (value >= 0xe000 && value <= 0xfffd) || (value >= 0x1_0000 && value <= 0x10_ffff);
}

private bool starts(scope const(char)[] raw, size_t cursor, string marker) pure nothrow @nogc
{
    return marker.length <= raw.length - cursor && raw[cursor .. cursor + marker.length] == marker;
}

private bool space(char value) pure nothrow @nogc
{
    return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

private void skipSpace(scope const(char)[] raw, ref size_t cursor) pure nothrow @nogc
{
    while (cursor < raw.length && space(raw[cursor]))
        ++cursor;
}

private Error malformed(size_t offset) pure nothrow @nogc
{
    return Error(Status.invalidArgument, "invalid or unsupported S3 XML response", offset);
}
