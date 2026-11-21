/// Bounded byte construction for SigV4 and S3 envelopes.
module flint.storage.encoding;

import flint.arena : Error, Result, Status;

@safe:

package(flint.storage) struct Writer
{
    private char[] target;
    size_t length;
    bool valid = true;

    this(return scope char[] bytes) pure nothrow @nogc
    {
        target = bytes;
    }

    void put(char item) scope pure nothrow @nogc
    {
        if (length == target.length)
        {
            valid = false;
            return;
        }
        target[length++] = item;
    }

    void append(scope const(char)[] source) scope pure nothrow @nogc
    {
        if (source.length > target.length - length)
        {
            valid = false;
            return;
        }
        target[length .. length + source.length] = source[];
        length += source.length;
    }

    void percent(scope const(char)[] source, bool retainSlash = false) scope pure nothrow @nogc
    {
        foreach (item; source)
        {
            if (unreserved(item) || (item == '/' && retainSlash))
            {
                put(item);
                continue;
            }
            const byteValue = cast(ubyte) item;
            put('%');
            put("0123456789ABCDEF"[byteValue >> 4]);
            put("0123456789ABCDEF"[byteValue & 15]);
        }
    }

    void decimal(ulong number) scope pure nothrow @nogc
    {
        char[20] digits;
        size_t start = digits.length;
        do
        {
            digits[--start] = cast(char)('0' + number % 10);
            number /= 10;
        }
        while (number);
        append(digits[start .. $]);
    }

    const(char)[] bytes() return scope const pure nothrow @nogc
    {
        return target[0 .. length];
    }
}

package(flint.storage) bool asciiAlpha(char value) pure nothrow @nogc
{
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z');
}

package(flint.storage) bool asciiDigit(char value) pure nothrow @nogc
{
    return value >= '0' && value <= '9';
}

package(flint.storage) char lowerAscii(char value) pure nothrow @nogc
{
    return value >= 'A' && value <= 'Z' ? cast(char)(value + ('a' - 'A')) : value;
}

private bool unreserved(char value) pure nothrow @nogc
{
    return asciiAlpha(value) || asciiDigit(value) || value == '-' || value == '.' || value == '_' || value == '~';
}

package(flint.storage) bool sameAscii(scope const(char)[] left, scope const(char)[] right) pure nothrow @nogc
{
    if (left.length != right.length)
        return false;
    foreach (index, item; left)
        if (lowerAscii(item) != lowerAscii(right[index]))
            return false;
    return true;
}

package(flint.storage) bool safeField(scope const(char)[] value, size_t capacity) pure nothrow @nogc
{
    if (value.length > capacity)
        return false;
    foreach (item; value)
        if ((item < ' ' && item != '\t') || item == 0x7f)
            return false;
    return true;
}

package(flint.storage) Result!ulong parseDecimal(scope const(char)[] text) pure nothrow @nogc
{
    if (!text.length)
        return Result!ulong(0, Error(Status.invalidArgument, "decimal field is empty"));
    ulong number;
    foreach (item; text)
    {
        if (!asciiDigit(item))
            return Result!ulong(0, Error(Status.invalidArgument, "decimal field has a nonnumeric byte"));
        const digit = cast(ulong)(item - '0');
        if (number > (ulong.max - digit) / 10)
            return Result!ulong(0, Error(Status.resourceExhausted, "decimal field exceeds its range"));
        number = number * 10 + digit;
    }
    return Result!ulong(number);
}
