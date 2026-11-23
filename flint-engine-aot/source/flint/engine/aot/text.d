/++
Number and character text without Phobos templates, for the framework modules' erased core (ADR-030 section 5).

One `std.conv.to!string(double)` instantiates about 4,900 templates and one `to!string(dchar)` about 4,500
(`std.format`, `std.uni`, `std.traits`); `to!long` and `to!double` cost over 1,000 each. These functions are not
templates and give the same results as those `std.conv` calls, which the unittests check case by case.
+/
module flint.engine.aot.text;

import flint.engine.aot.sys.text : formatE, formatG, readDouble, readFloat;

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

/// ditto, as `to!string(int)`; an exact match, so an `int` needs no cast to choose between `long` and `ulong`.
string decimal(int value) pure nothrow
{
    return decimal(cast(long) value);
}

/// ditto, as `to!string(uint)`.
string decimal(uint value) pure nothrow
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

/// `tryParseLong` limited to `int`, as `to!int` reads text: false also for a value outside `int`.
ParsedLong tryParseInt(scope const(char)[] text) pure nothrow @nogc
{
    auto result = tryParseLong(text);
    result.ok = result.ok && result.value >= int.min && result.value <= int.max;
    return result;
}

/// `text` without leading and trailing white space, as `std.string.strip` does: the characters `std.uni.isWhite`
/// accepts, ASCII and Unicode.
inout(char)[] stripWhite(inout(char)[] text) pure nothrow @nogc
{
    size_t start, end = text.length;
    size_t width;
    while (start < end && (width = whiteAt(text, start)) != 0)
        start += width;
    while (end > start)
    {
        size_t at = end - 1;
        while (at > start && (text[at] & 0xC0) == 0x80)
            --at;
        if (whiteAt(text, at) != end - at)
            break;
        end = at;
    }
    return text[start .. end];
}

// The byte width of the white-space character starting at `i` (std.uni.isWhite), or 0.
private size_t whiteAt(scope const(char)[] text, size_t i) pure nothrow @nogc
{
    static immutable dchar[] white = [
        ' ', '\t', '\n', '\v', '\f', '\r', 0x85, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003,
        0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000
    ];
    const lead = text[i];
    size_t width;
    dchar c;
    if (lead < 0x80)
    {
        width = 1;
        c = lead;
    }
    else if ((lead & 0xE0) == 0xC0 && i + 1 < text.length)
    {
        width = 2;
        c = ((lead & 0x1F) << 6) | (text[i + 1] & 0x3F);
    }
    else if ((lead & 0xF0) == 0xE0 && i + 2 < text.length)
    {
        width = 3;
        c = ((lead & 0x0F) << 12) | ((text[i + 1] & 0x3F) << 6) | (text[i + 2] & 0x3F);
    }
    foreach (w; white)
        if (width && c == w)
            return width;
    return 0;
}

/// A parse result for `ulong`.
struct ParsedULong
{
    /// The text was a valid number.
    bool ok;
    /// The number, when ok.
    ulong value;
}

/// Reads a whole decimal number as `to!ulong` does: digits only, no sign; not ok for malformed text or overflow.
ParsedULong tryParseULong(scope const(char)[] text) pure nothrow @nogc
{
    ParsedULong result;
    if (text.length == 0)
        return result;
    ulong value;
    foreach (c; text)
    {
        if (!isDigit(c))
            return result;
        const digit = c - '0';
        if (value > (ulong.max - digit) / 10)
            return result;
        value = value * 10 + digit;
    }
    result.ok = true;
    result.value = value;
    return result;
}

/// The name of `value`'s constant, as `to!string` prints an enum, including `cast(E)n` for a value that names no
/// constant. A small template per enum type, where `to!string` instantiates `std.format` for it.
string enumName(E)(E value) pure nothrow if (is(E Base == enum) && __traits(isIntegral, Base))
{
    foreach (member; __traits(allMembers, E))
        if (value == __traits(getMember, E, member))
            return member;
    return "cast(" ~ E.stringof ~ ")" ~ decimal(cast(long) value);
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
    const read = special(rest, negative, plus);
    final switch (read.kind)
    {
    case Special.none:
        break;
    case Special.accepted:
        value = read.value;
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

// `inf` (without a plus sign, as to!double) and `nan` in any case, with its value; Special.none for other text.
private struct SpecialRead
{
    Special kind;
    double value;
}

/// ditto
private SpecialRead special(scope const(char)[] text, bool negative, bool plus) pure nothrow @nogc
{
    if (equalsIgnoreCase(text, "inf"))
        return SpecialRead(plus ? Special.refused : Special.accepted, negative ? -double.infinity : double.infinity);
    if (equalsIgnoreCase(text, "nan"))
        return SpecialRead(Special.accepted, double.nan);
    return SpecialRead(Special.none, 0);
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

/// `value` as `format("%.*e", precision, value)` prints it: C's `%e` with `precision` digits after the point,
/// for `precision` in [0, 40]; null outside it.
string scientific(double value, int precision) pure nothrow
{
    char[64] buffer;
    const length = formatE(value, precision, buffer[]);
    return length ? buffer[0 .. length].idup : null;
}

/// A float parse result.
struct ParsedFloat
{
    /// The text was a valid number.
    bool ok;
    /// The number, when ok.
    float value;
}

/// Reads a whole floating-point number as `to!float` does: the syntax `parseDouble` accepts, rounded once to float.
ParsedFloat tryParseFloat(scope const(char)[] text) pure nothrow
{
    ParsedFloat result;
    size_t i;
    bool negative, plus;
    if (i < text.length && (text[i] == '-' || text[i] == '+'))
    {
        negative = text[i] == '-';
        plus = !negative;
        ++i;
    }
    const rest = text[i .. $];
    const read = special(rest, negative, plus);
    final switch (read.kind)
    {
    case Special.none:
        break;
    case Special.accepted:
        result.ok = true;
        result.value = cast(float) read.value;
        return result;
    case Special.refused:
        return result;
    }
    char[] cleaned;
    cleaned.reserve(text.length + 1);
    if (negative)
        cleaned ~= '-';
    if (!mantissaAndExponent(rest, cleaned))
        return result;
    cleaned ~= '\0';
    size_t consumed;
    const parsed = readFloat(cleaned, consumed);
    if (consumed + 1 != cleaned.length || parsed == float.infinity || parsed == -float.infinity)
        return result;
    result.ok = true;
    result.value = parsed;
    return result;
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
    foreach (value; [0, 7, -7, int.max, int.min])
        assert(decimal(value) == value.to!string);
    foreach (value; [0U, 9, uint.max])
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
    import std.math : isNaN, nextDown, nextUp;

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
    // Phobos is the oracle only where `real` is wider than `double` (x86's 80 bits). Where `real` is `double`
    // (AArch64), `to!double` range-errors on an underflow and can be one ulp off, so values are compared within an
    // ulp there, and the underflow is pinned below.
    enum wideReal = real.mant_dig > double.mant_dig;
    foreach (text; texts)
    {
        if (text == "1e-400")
            continue;
        bool expected = true;
        double reference;
        try
            reference = text.to!double;
        catch (Exception)
            expected = false;
        const result = parsed(text);
        assert(result.ok == expected, text);
        if (!expected)
            continue;
        if (reference.isNaN)
            assert(result.value.isNaN, text);
        else if (wideReal)
            assert(result.value is reference, text);
        else
            assert(result.value is reference || result.value is nextUp(reference)
                    || result.value is nextDown(reference), text);
    }
    // An underflow rounds to zero, as Java's Double.parseDouble and x86's Phobos do.
    const underflow = parsed("1e-400");
    assert(underflow.ok && underflow.value == 0.0);
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

unittest
{
    import std.conv : to;

    foreach (text; [
        "0", "-2147483648", "2147483647", "2147483648", "-2147483649", "+7", "", "x", " 1"
    ])
    {
        bool expected = true;
        int reference;
        try
            reference = text.to!int;
        catch (Exception)
            expected = false;
        const result = tryParseInt(text);
        assert(result.ok == expected, text);
        if (expected)
            assert(result.value == reference, text);
    }
}

unittest
{
    import std.string : strip;

    static immutable texts = [
        "", " ", "1.5", "  1.5\t\n", "\u00A01.5\u3000", "\u20281\u2029", "x\u0085", "\u00A0",
        "1\u200B", "\u2000\u200A2\u202F\u205F", "é é", "\u1680-3\u1680", "\v\fz\r"
    ];
    foreach (text; texts)
        assert(stripWhite(text) == text.strip(), text);
}

unittest
{
    import std.format : format;

    static immutable values = [
        0.0, -0.0, 1.0, 1.5, 0.1, 0.2 + 0.1, 1e20, 1e-5, 123_456_789.0, 3.141_592_653_589_793,
        double.max, double.min_normal, double.min_normal / 4, -42.75, 999_999.5, 1e308, 5e-5,
        0.000_123
    ];
    foreach (value; values)
        foreach (precision; 0 .. 17)
            assert(scientific(value, precision) == format("%.*e", precision, value), format("%.*e", precision, value));
    assert(scientific(1.0, -1) is null && scientific(1.0, 41) is null);
}

unittest
{
    import std.conv : to;
    import std.math : isNaN;

    static immutable texts = [
        "0.1", "1.5", "-2", "1e5", "3.4028235e38", "3.4028236e38", "1e39", "1.17549435e-38",
        "1e-46", "0x1p3", "nan", "inf", "-inf", "+inf", "1_000", "", " 1", "16777217",
        "0.30000001192092896", "1.00000005960464477539"
    ];
    foreach (text; texts)
    {
        bool expected = true;
        float reference;
        try
            reference = text.to!float;
        catch (Exception)
            expected = false;
        const result = tryParseFloat(text);
        assert(result.ok == expected, text);
        if (expected)
            assert(reference.isNaN ? result.value.isNaN : result.value is reference, text);
    }
}

unittest
{
    import std.conv : to;

    foreach (text; [
        "5", "+5", "-0", "-1", "18446744073709551615", "18446744073709551616", "", "+", "007", "1_0"
    ])
    {
        bool expected = true;
        ulong reference;
        try
            reference = text.to!ulong;
        catch (Exception)
            expected = false;
        const result = tryParseULong(text);
        assert(result.ok == expected, text);
        if (expected)
            assert(result.value == reference, text);
    }
}

unittest
{
    import std.conv : to;

    enum Color
    {
        red,
        GREEN,
        blueSky
    }

    foreach (value; [Color.red, Color.GREEN, Color.blueSky, cast(Color) 7])
        assert(enumName(value) == value.to!string);
}
