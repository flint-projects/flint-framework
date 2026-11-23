/++
Number and character text without Phobos templates, for the framework modules' erased core (ADR-030 section 5).

One `std.conv.to!string(double)` instantiates about 4,900 templates and one `to!string(dchar)` about 4,500
(`std.format`, `std.uni`, `std.traits`); `to!long` and `to!double` cost over 1,000 each. These functions are not
templates and give the same results as those `std.conv` calls, which the unittests check case by case.
+/
module flint.engine.aot.text;

import flint.engine.aot.sys.text : formatG, readDouble;

@safe:

/// `value` in decimal, as `to!string(long)`.
string decimal(long value) pure nothrow
{
    if (value < 0)
        return "-" ~ digits(value == long.min ? cast(ulong) long.max + 1 : cast(ulong)-value);
    return digits(cast(ulong) value);
}

/// ditto, as `to!string(ulong)`.
string decimal(ulong value) pure nothrow
{
    return digits(value);
}

private string digits(ulong value) pure nothrow
{
    char[20] buffer;
    size_t start = buffer.length;
    do
    {
        buffer[--start] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value != 0);
    return buffer[start .. $].idup;
}

/// The UTF-8 encoding of `c`, as `to!string(dchar)`; null for a surrogate or a value above U+10FFFF, where
/// `to!string` throws.
string utf8(dchar c) pure nothrow
{
    if (c < 0x80)
        return [cast(char) c].idup;
    if (c < 0x800)
        return [cast(char)(0xC0 | (c >> 6)), cast(char)(0x80 | (c & 0x3F))].idup;
    if (c >= 0xD800 && c <= 0xDFFF)
        return null;
    if (c < 0x10000)
        return [
        cast(char)(0xE0 | (c >> 12)), cast(char)(0x80 | ((c >> 6) & 0x3F)),
        cast(char)(0x80 | (c & 0x3F))
    ].idup;
    if (c <= 0x10FFFF)
        return [
        cast(char)(0xF0 | (c >> 18)), cast(char)(0x80 | ((c >> 12) & 0x3F)),
        cast(char)(0x80 | ((c >> 6) & 0x3F)), cast(char)(0x80 | (c & 0x3F))
    ].idup;
    return null;
}

/// Reads a whole decimal integer as `to!long` does: an optional sign and digits only. False where `to!long`
/// throws, for malformed text or a value out of range.
bool parseLong(scope const(char)[] text, out long value) pure nothrow @nogc
{
    size_t i;
    bool negative;
    if (i < text.length && (text[i] == '-' || text[i] == '+'))
        negative = text[i++] == '-';
    if (i == text.length)
        return false;
    ulong magnitude;
    const limit = negative ? cast(ulong) long.max + 1 : cast(ulong) long.max;
    for (; i < text.length; ++i)
    {
        const c = text[i];
        if (!isDigit(c))
            return false;
        const digit = c - '0';
        if (magnitude > (limit - digit) / 10)
            return false;
        magnitude = magnitude * 10 + digit;
    }
    value = negative ? -cast(long) magnitude : cast(long) magnitude;
    return true;
}

/// A parse result: whether the text was accepted, and the value.
struct ParsedLong
{
    /// The text was a valid number.
    bool ok;
    /// The number, when ok.
    long value;
}

/// ditto
struct ParsedDouble
{
    /// The text was a valid number.
    bool ok;
    /// The number, when ok.
    double value;
}

/// `parseLong` as a value, for call sites that would otherwise declare an `out` variable.
ParsedLong tryParseLong(scope const(char)[] text) pure nothrow @nogc
{
    ParsedLong result;
    result.ok = parseLong(text, result.value);
    return result;
}

/// `parseDouble` as a value, for call sites that would otherwise declare an `out` variable.
ParsedDouble tryParseDouble(scope const(char)[] text) pure nothrow
{
    ParsedDouble result;
    result.ok = parseDouble(text, result.value);
    return result;
}

/// Reads a whole floating-point number as `to!double` does: decimal with optional fraction, exponent and single
/// underscores after digits, hexadecimal with a binary exponent, and `inf` and `nan` in any case. False where
/// `to!double` throws, for malformed text or a finite number out of range.
bool parseDouble(scope const(char)[] text, out double value) pure nothrow
{
    size_t i;
    bool negative, plus;
    if (i < text.length && (text[i] == '-' || text[i] == '+'))
    {
        negative = text[i] == '-';
        plus = !negative;
        ++i;
    }
    const rest = text[i .. $];
    final switch (special(rest, negative, plus, value))
    {
    case Special.none:
        break;
    case Special.accepted:
        return true;
    case Special.refused:
        return false;
    }
    char[] cleaned;
    cleaned.reserve(text.length + 1);
    if (negative)
        cleaned ~= '-';
    if (!mantissaAndExponent(rest, cleaned))
        return false;
    cleaned ~= '\0';
    size_t consumed;
    const parsed = readDouble(cleaned, consumed);
    if (consumed + 1 != cleaned.length || parsed == double.infinity || parsed == -double.infinity)
        return false;
    value = parsed;
    return true;
}

private enum Special
{
    none,
    accepted,
    refused
}

// `inf` (without a plus sign, as to!double) and `nan` in any case; Special.none for any other text.
private Special special(scope const(char)[] text, bool negative, bool plus, out double value) pure nothrow @nogc
{
    if (equalsIgnoreCase(text, "inf"))
    {
        value = negative ? -double.infinity : double.infinity;
        return plus ? Special.refused : Special.accepted;
    }
    if (equalsIgnoreCase(text, "nan"))
    {
        value = double.nan;
        return Special.accepted;
    }
    return Special.none;
}

// A hexadecimal or decimal number, appended to `cleaned` without underscores; false where to!double refuses it.
private bool mantissaAndExponent(scope const(char)[] text, ref char[] cleaned) pure nothrow
{
    if (text.length >= 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X'))
    {
        cleaned ~= text;
        return hexadecimal(text[2 .. $]);
    }
    size_t i;
    size_t mantissaDigits;
    if (!digitRun(text, i, cleaned, mantissaDigits))
        return false;
    if (i < text.length && text[i] == '.')
    {
        cleaned ~= '.';
        ++i;
        if (!digitRun(text, i, cleaned, mantissaDigits))
            return false;
    }
    return mantissaDigits > 0 && exponent(text, i, cleaned) && i == text.length;
}

// Digits from `i`, each `_` only directly after a digit, as to!double allows; the digits go to `cleaned`.
private bool digitRun(scope const(char)[] text, ref size_t i, ref char[] cleaned, ref size_t count) pure nothrow
{
    bool afterDigit;
    for (; i < text.length && (isDigit(text[i]) || text[i] == '_'); ++i)
    {
        if (text[i] == '_')
        {
            if (!afterDigit)
                return false;
            afterDigit = false;
            continue;
        }
        cleaned ~= text[i];
        ++count;
        afterDigit = true;
    }
    return true;
}

// An optional decimal exponent at `i`: `e` or `E`, an optional sign and at least one digit.
private bool exponent(scope const(char)[] text, ref size_t i, ref char[] cleaned) pure nothrow
{
    if (i == text.length || (text[i] != 'e' && text[i] != 'E'))
        return true;
    cleaned ~= 'e';
    ++i;
    if (i < text.length && (text[i] == '+' || text[i] == '-'))
        cleaned ~= text[i++];
    const start = i;
    for (; i < text.length && isDigit(text[i]); ++i)
        cleaned ~= text[i];
    return i > start;
}

// Hexadecimal digits with an optional point, then an optional binary exponent `p`.
private bool hexadecimal(scope const(char)[] text) pure nothrow @nogc
{
    size_t i, mantissaDigits;
    for (; i < text.length && (isHexDigit(text[i]) || text[i] == '.'); ++i)
        mantissaDigits += isHexDigit(text[i]);
    if (mantissaDigits == 0)
        return false;
    if (i < text.length && (text[i] == 'p' || text[i] == 'P'))
    {
        ++i;
        if (i < text.length && (text[i] == '+' || text[i] == '-'))
            ++i;
        const start = i;
        while (i < text.length && isDigit(text[i]))
            ++i;
        if (i == start)
            return false;
    }
    return i == text.length;
}

/// `value` as `to!string(double)` prints it: C's `%g`, six significant digits.
string doubleText(double value) pure nothrow
{
    char[32] buffer;
    const length = formatG(value, buffer[]);
    return buffer[0 .. length].idup;
}

private bool isDigit(char c) pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

private bool isHexDigit(char c) pure nothrow @nogc
{
    return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

private bool equalsIgnoreCase(scope const(char)[] a, string b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i, c; a)
    {
        const lower = c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
        if (lower != b[i])
            return false;
    }
    return true;
}

unittest
{
    import std.conv : to;

    foreach (value; [0L, 1, -1, 42, -42, 1_234_567_890, long.max, long.min])
        assert(decimal(value) == value.to!string);
    foreach (value; [0UL, 1, 10, ulong.max])
        assert(decimal(value) == value.to!string);
}

unittest
{
    import std.conv : to;

    static immutable dchar[] valid = [
        'a', 0x7F, 0x80, 0xE9, 0x7FF, 0x800, 0x20AC, 0xFFFF, 0x10000, 0x1F600, 0x10FFFF
    ];
    foreach (c; valid)
        assert(utf8(c) == c.to!string);
    assert(utf8(cast(dchar) 0xD800) is null && utf8(cast(dchar) 0xDFFF) is null);
    assert(utf8(cast(dchar) 0x110000) is null);
}

unittest
{
    import std.conv : to;

    static struct Parsed
    {
        bool ok;
        long value;
    }

    static Parsed parsed(string text)
    {
        Parsed result;
        result.ok = parseLong(text, result.value);
        return result;
    }

    static immutable texts = [
        "12", "-12", "+12", "", "-", "+", " 1", "1 ", "9223372036854775807", "9223372036854775808",
        "-9223372036854775808", "-9223372036854775809", "0x10", "1_0", "007", "18446744073709551616"
    ];
    foreach (text; texts)
    {
        bool expected = true;
        long reference;
        try
            reference = text.to!long;
        catch (Exception)
            expected = false;
        const result = parsed(text);
        assert(result.ok == expected, text);
        if (expected)
            assert(result.value == reference, text);
    }
}

unittest
{
    import std.conv : to;
    import std.math : isNaN;

    static struct Parsed
    {
        bool ok;
        double value;
    }

    static Parsed parsed(string text)
    {
        Parsed result;
        result.ok = parseDouble(text, result.value);
        return result;
    }

    static immutable texts = [
        "1.5", "-2", "1e5", "1E5", ".5", "5.", "inf", "-inf", "nan", "infinity", "Infinity", "NaN",
        "INF", "Inf", "-INF", "+inf", "nAn", "-nan", "+nan", "0x1p3", "0X1P3", "0x1.8p1",
        "-0x1p-2", "0x", " 1", "1 ", "", "1,5", "+3", "1e400", "-1e400", "1e-400", "-0", "1_000",
        "_1", "1__0", "1_", "1._5", "1e_5", "0012", "1.5e", "e5", ".", "1.5E+3", "1.5e-3",
        "4.9e-324", "123456789012345678901234567890", "2.2250738585072014e-308"
    ];
    foreach (text; texts)
    {
        bool expected = true;
        double reference;
        try
            reference = text.to!double;
        catch (Exception)
            expected = false;
        const result = parsed(text);
        assert(result.ok == expected, text);
        if (expected)
            assert(reference.isNaN ? result.value.isNaN : result.value is reference, text);
    }
}

unittest
{
    import std.conv : to;

    static immutable values = [
        0.0, -0.0, 1.0, 1.5, 0.1, 0.2 + 0.1, 1e20, 1e21, 1e-5, 1e-4, 123_456_789.0,
        3.141_592_653_589_793, double.nan, -double.nan, double.infinity, -double.infinity,
        2.5e-308, double.min_normal / 4, double.max, 100.0, 1e15, 1e16, 0.000_123, -42.75,
        999_999.5, double.min_normal * double.epsilon
    ];
    foreach (value; values)
        assert(doubleText(value) == value.to!string, value.to!string);
}
