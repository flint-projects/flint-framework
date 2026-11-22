/// Allocation-free HTML output and URL admission.
module flint.templates.output;

import flint.arena : Buffer, Error, RequestArena, Status, Text;
import flint.templates.utf8 : decodeScalar;
import flint.templates.context : EscapeKind, lower;
import flint.templates.types : TrustedHtml;
import std.traits : isIntegral, isSigned;

@safe:
package(flint.templates):

private enum maximumOutput = 16_777_216;
private enum maximumIterations = 100_000;

struct Writer
{
    private ubyte[] destination;
    private bool filling;

    size_t length;
    uint iterations;
    Error failure;

    this(return scope ubyte[] destination) nothrow @nogc
    {
        this.destination = destination;
        filling = true;
    }

    void append(scope const(char)[] text) scope nothrow @nogc
    {
        if (failure.code != Status.ok)
            return;
        if (text.length > maximumOutput - length)
        {
            failure = Error(Status.resourceExhausted, "template output exceeds 16 MiB");
            return;
        }
        if (filling)
        {
            if (text.length > destination.length - length)
            {
                failure = Error(Status.conflict, "template render count changed");
                return;
            }
            destination[length .. length + text.length] = cast(const(ubyte)[]) text;
        }
        length += text.length;
    }

    bool iteration() scope nothrow @nogc
    {
        if (iterations == maximumIterations)
        {
            failure = Error(Status.resourceExhausted, "template loop exceeds 100000 iterations");
            return false;
        }
        ++iterations;
        return true;
    }

    void escaped(scope const(char)[] text, EscapeKind mode = EscapeKind.text) scope nothrow @nogc
    {
        if (failure.code != Status.ok)
            return;
        if (text.length > maximumOutput - length)
        {
            failure = Error(Status.resourceExhausted, "template output exceeds 16 MiB");
            return;
        }
        if (mode == EscapeKind.url)
        {
            failure = urlPolicy(text);
            if (failure.code != Status.ok)
                return;
        }
        size_t first;
        size_t cursor;
        while (cursor < text.length)
        {
            // Skip the common run of ASCII bytes that need neither escaping nor UTF-8 decoding.
            while (cursor < text.length && plainByte[cast(ubyte) text[cursor]])
                ++cursor;
            if (cursor == text.length)
                break;
            const start = cursor;
            const byte_ = cast(ubyte) text[cursor];
            if (byte_ >= 0x80)
            {
                if (!decodeScalar(text, cursor).valid)
                {
                    failure = Error(Status.invalidArgument, "invalid UTF-8 in template field", start);
                    return;
                }
                continue;
            }
            ++cursor;
            const mapped = entity(text[start]);
            if (mapped !is null)
            {
                append(text[first .. start]);
                append(mapped);
                if (failure.code != Status.ok)
                    return;
                first = cursor;
            }
        }
        append(text[first .. $]);
    }

    void field(scope const(char)[] text, EscapeKind mode, ref scope RequestArena) scope nothrow @nogc
    {
        escaped(text, mode);
    }

    void field(scope const(ubyte)[] text, EscapeKind mode, ref scope RequestArena) scope nothrow @nogc
    {
        escaped(cast(const(char)[]) text, mode);
    }

    void field(Buffer buffer, EscapeKind mode, ref scope RequestArena arena) scope nothrow @nogc
    {
        const status = arena.read(buffer, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            escaped(cast(const(char)[]) bytes, mode);
        });
        if (status != Status.ok)
            failure = Error(status, "template input buffer is unavailable");
    }

    void field(Text text, EscapeKind mode, ref scope RequestArena arena) scope nothrow @nogc
    {
        field(text.bytes, mode, arena);
    }

    void field(TrustedHtml raw, EscapeKind mode, ref scope RequestArena arena) scope nothrow @nogc
    {
        if (mode != EscapeKind.text)
        {
            failure = Error(Status.invalidArgument, "trusted HTML requires a text context");
            return;
        }
        const status = arena.read(raw.handle(), (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            append(cast(const(char)[]) bytes);
        });
        if (status != Status.ok)
            failure = Error(status, "trusted HTML buffer is unavailable");
    }

    void field(bool value, EscapeKind, ref scope RequestArena) scope nothrow @nogc
    {
        append(value ? "true" : "false");
    }

    void field(T)(T value, EscapeKind, ref scope RequestArena) scope nothrow @nogc if (isIntegral!T)
    {
        static if (isSigned!T)
        {
            if (value < 0)
            {
                append("-");
                decimal(cast(ulong)(-(cast(long) value + 1)) + 1);
                return;
            }
        }
        decimal(cast(ulong) value);
    }

    private void decimal(ulong number) scope nothrow @nogc
    {
        char[20] digits;
        size_t cursor = digits.length;
        do
        {
            digits[--cursor] = cast(char)('0' + number % 10);
            number /= 10;
        }
        while (number);
        append(digits[cursor .. $]);
    }
}

/// ASCII bytes copied unchanged: everything below 0x80 except the bytes `entity` rewrites.
private static immutable bool[256] plainByte = () {
    bool[256] table;
    foreach (index; 0 .. 0x80)
        table[index] = entity(cast(char) index) is null;
    return table;
}();

private string entity(char value) pure nothrow @nogc
{
    switch (value)
    {
    case '&':
        return "&amp;";
    case '<':
        return "&lt;";
    case '>':
        return "&gt;";
    case '"':
        return "&quot;";
    case '\'':
        return "&#39;";
    case '\0':
        return "&#xfffd;";
    default:
        return null;
    }
}

private bool equalFold(scope const(char)[] input, string wanted) pure nothrow @nogc
{
    if (input.length != wanted.length)
        return false;
    foreach (index, ch; input)
    {
        if (lower(ch) != wanted[index])
            return false;
    }
    return true;
}

private int hex(char ch) pure nothrow @nogc
{
    if (ch >= '0' && ch <= '9')
        return ch - '0';
    const normalized = lower(ch);
    return normalized >= 'a' && normalized <= 'f' ? normalized - 'a' + 10 : -1;
}

private bool badByte(uint value) pure nothrow @nogc
{
    return value <= 0x20 || value == 0x7f || value == '\\';
}

private bool badEscape(int value) pure nothrow @nogc
{
    return value != ' ' && badByte(value);
}

private Error safeCharacters(scope const(char)[] text) nothrow @nogc
{
    size_t index;
    while (index < text.length)
    {
        const first = index;
        const decoded = decodeScalar(text, index);
        const scalar = decoded.value;
        if (!decoded.valid || badByte(scalar) || (scalar >= 0x80 && scalar <= 0x9f))
            return Error(Status.invalidArgument, "invalid character in template URL", first);
        if (scalar != '%')
            continue;
        if (text.length - index < 2)
            return Error(Status.invalidArgument, "truncated template URL escape", first);
        const top = hex(text[index]);
        const low = hex(text[index + 1]);
        if (top < 0 || low < 0 || badEscape(top * 16 + low))
            return Error(Status.invalidArgument, "invalid template URL escape", first);
        index += 2;
    }
    return Error.init;
}

Error urlPolicy(scope const(char)[] text) nothrow @nogc
{
    const characters = safeCharacters(text);
    if (characters.code != Status.ok)
        return characters;
    if (text.length >= 2 && text[0 .. 2] == "//")
        return Error(Status.invalidArgument, "scheme-relative template URL is forbidden");
    foreach (index, ch; text)
    {
        if (ch == '/' || ch == '?' || ch == '#')
            break;
        if (ch == ':')
            return schemePolicy(text[0 .. index], text[index + 1 .. $]);
    }
    return Error.init;
}

private Error schemePolicy(scope const(char)[] scheme, scope const(char)[] tail) pure nothrow @nogc
{
    if (equalFold(scheme, "mailto") && tail.length != 0)
        return Error.init;
    if ((equalFold(scheme, "http") || equalFold(scheme, "https")) && tail.length >= 3
            && tail[0 .. 2] == "//" && tail[2] != '/' && tail[2] != '?' && tail[2] != '#')
        return Error.init;
    return Error(Status.invalidArgument, "template URL scheme is forbidden or incomplete");
}
