/*
 * Ported from Jackson (jackson-core) 3.1.8, https://github.com/FasterXML/jackson-core,
 * tag jackson-core-3.1.8: src/main/java/tools/jackson/core/io/{NumberInput,NumberOutput,CharTypes}.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D (rulebook v2); doubles and floats
 * render through flint.serde.java_number, which matches the JDK's Double.toString. NumberInput.parseDouble
 * reports invalid text by returning false, because flint:jackson-core does not depend on flint:java's
 * NumberFormatException; it accepts Java's decimal syntax and converts through flint.serde's correctly
 * rounded parser.
 */

/// Low-level number and character output helpers of the streaming layer.
module flint.jackson.core.io;

@safe:

/// Helper class for parsing numbers from text (Jackson's `NumberInput`).
struct NumberInput
{
    /// Java's `Double.parseDouble`, which Jackson's `parseDouble(String, boolean)` calls: surrounding ASCII
    /// whitespace and control characters are trimmed; then an optional sign, decimal digits with an optional
    /// fraction (either part may be empty, not both) and an optional exponent, and an optional `f`, `F`, `d` or `D`
    /// suffix; or `NaN` and `Infinity`. A magnitude beyond the double range is an infinity, as in Java. Returns
    /// false where Java throws `NumberFormatException`, for any other text. Hexadecimal floating-point literals
    /// are not supported.
    static bool parseDouble(scope const(char)[] text, out double value) nothrow
    {
        import flint.serde.json_read : parseJsonDecimal;

        static bool digit(char c) pure nothrow @nogc
        {
            return c >= '0' && c <= '9';
        }

        size_t start, end = text.length;
        while (start < end && text[start] <= ' ')
            start++;
        while (end > start && text[end - 1] <= ' ')
            end--;
        auto t = text[start .. end];
        bool negative;
        if (t.length && (t[0] == '+' || t[0] == '-'))
        {
            negative = t[0] == '-';
            t = t[1 .. $];
        }
        if (t == "NaN")
        {
            value = double.nan;
            return true;
        }
        if (t == "Infinity")
        {
            value = negative ? -double.infinity : double.infinity;
            return true;
        }
        if (t.length > 1 && ((t[$ - 1] | 0x20) == 'f' || (t[$ - 1] | 0x20) == 'd'))
            t = t[0 .. $ - 1];
        size_t at;
        while (at < t.length && digit(t[at]))
            at++;
        auto whole = t[0 .. at];
        const(char)[] fraction;
        if (at < t.length && t[at] == '.')
        {
            const from = ++at;
            while (at < t.length && digit(t[at]))
                at++;
            fraction = t[from .. at];
        }
        if (whole.length + fraction.length == 0)
            return false;
        const(char)[] exponent;
        if (at < t.length && (t[at] | 0x20) == 'e')
        {
            const from = ++at;
            if (at < t.length && (t[at] == '+' || t[at] == '-'))
                at++;
            const digits = at;
            while (at < t.length && digit(t[at]))
                at++;
            if (at == digits)
                return false;
            exponent = t[from .. at];
        }
        if (at != t.length)
            return false;
        while (whole.length > 1 && whole[0] == '0')
            whole = whole[1 .. $];
        // Rewritten in JSON's number grammar, which flint.serde's parser takes.
        char[] json;
        json.reserve(whole.length + fraction.length + exponent.length + 4);
        if (negative)
            json ~= '-';
        json ~= whole.length ? whole : "0";
        if (fraction.length)
        {
            json ~= '.';
            json ~= fraction;
        }
        if (exponent.length)
        {
            json ~= 'e';
            json ~= exponent;
        }
        double[1] parsed;
        value = parseJsonDecimal(cast(const(ubyte)[]) json, parsed[0]) ? parsed[0] : negative
            ? -double.infinity : double.infinity;
        return true;
    }
}

@("NumberInput.parseDouble takes Java's decimal syntax and rejects anything else")
unittest
{
    double value;
    foreach (text, expected; [
        "1": 1.0,
        " 2.5 ": 2.5,
        "+3": 3.0,
        "-0.5": -0.5,
        ".5": 0.5,
        "5.": 5.0,
        "1e3": 1000.0,
        "1E-2": 0.01,
        "007.25": 7.25,
        "2f": 2.0,
        "4.5D": 4.5,
        "1e400": double.infinity,
        "-1e400": -double.infinity
    ])
    {
        assert(NumberInput.parseDouble(text, value), text);
        assert(value == expected, text);
    }
    assert(NumberInput.parseDouble("NaN", value) && value != value);
    assert(NumberInput.parseDouble("-Infinity", value) && value == -double.infinity);
    foreach (text; [
        "", " ", "foobar", "1x", "abc", "1e", "1e+", ".", "-", "+-1", "1.2.3", "f", "0x10", "1 2"
    ])
        assert(!NumberInput.parseDouble(text, value), text);
}

/// Helper class for efficient writing of numeric values. Java's `toString(double)` and `toString(float)`
/// are `flint.serde.java_number.javaDoubleString` and `javaFloatString`.
struct NumberOutput
{
    /// Whether `Double.toString(v)` would not be a finite number: NaN or an infinity.
    static bool notFinite(double value) pure nothrow @nogc
    {
        return value != value || value == double.infinity || value == -double.infinity;
    }

    /// ditto, for floats.
    static bool notFinite(float value) pure nothrow @nogc
    {
        return value != value || value == float.infinity || value == -float.infinity;
    }

    /// Write the decimal digits of `v` right-aligned into a 20-byte buffer start and return the length, left-aligned.
    static size_t writeLong(long v, ref char[20] output) pure nothrow @nogc
    {
        char[20] digits;
        size_t first = digits.length;
        ulong magnitude = v < 0 ? cast(ulong)(-(v + 1)) + 1 : cast(ulong) v;
        do
        {
            digits[--first] = cast(char)('0' + magnitude % 10);
            magnitude /= 10;
        }
        while (magnitude != 0);
        size_t length;
        if (v < 0)
            output[length++] = '-';
        const significant = digits[first .. $];
        output[length .. length + significant.length] = significant;
        return length + significant.length;
    }
}

/// Uppercase hexadecimal digits Jackson writes in `\uXXXX` escapes (`JsonWriteFeature.WRITE_HEX_UPPER_CASE`).
enum string upperHexDigits = "0123456789ABCDEF";

/// Lowercase hexadecimal digits, used when `WRITE_HEX_UPPER_CASE` is disabled.
enum string lowerHexDigits = "0123456789abcdef";

/**
 * The escape Jackson writes for an ASCII byte (`CharTypes.get7BitOutputEscapes()`):
 * 0 for none, a letter for a two-character escape (`\n`), or -1 for `\u00XX`.
 */
int outputEscape(ubyte c, bool escapeForwardSlash = false) pure nothrow @nogc
{
    switch (c)
    {
    case '"':
        return '"';
    case '\\':
        return '\\';
    case '\b':
        return 'b';
    case '\t':
        return 't';
    case '\n':
        return 'n';
    case '\f':
        return 'f';
    case '\r':
        return 'r';
    case '/':
        return escapeForwardSlash ? '/' : 0;
    default:
        return c < 0x20 ? -1 : 0;
    }
}

@("NumberOutput prints Java's integer and floating-point text")
unittest
{
    char[20] digits;
    assert(digits[0 .. NumberOutput.writeLong(long.min, digits)] == "-9223372036854775808");
    assert(digits[0 .. NumberOutput.writeLong(0, digits)] == "0");
    assert(NumberOutput.notFinite(double.nan) && NumberOutput.notFinite(-float.infinity)
            && !NumberOutput.notFinite(1.0));
    assert(outputEscape('\n') == 'n' && outputEscape(0x0B) == -1 && outputEscape(0x7F) == 0 && outputEscape('/') == 0);
}
