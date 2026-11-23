/*
 * Ported from Jackson (jackson-core) 3.1.8, https://github.com/FasterXML/jackson-core,
 * tag jackson-core-3.1.8: src/main/java/tools/jackson/core/io/{NumberOutput,CharTypes}.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D (rulebook v2); doubles and floats
 * render through flint.serde.java_number, which matches the JDK's Double.toString.
 */

/// Low-level number and character output helpers of the streaming layer.
module flint.jackson.core.io;

@safe:

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
