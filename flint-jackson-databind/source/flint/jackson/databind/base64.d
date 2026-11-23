/*
 * Ported from Jackson (jackson-core) 3.1.8, https://github.com/FasterXML/jackson-core,
 * tag jackson-core-3.1.8: src/main/java/tools/jackson/core/Base64Variant.java (behaviour of
 * Base64Variants.MIME_NO_LINEFEEDS)
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: the default variant's encoding and decoding as two functions,
 * replacing std.base64 (no per-call template instances).
 */

/// Base64 as `Base64Variants.MIME_NO_LINEFEEDS` writes and reads it: the standard alphabet, padded, no line feeds.
module flint.jackson.databind.base64;

@safe:

private static immutable char[64] alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// `Base64Variant.encode(input)`.
package(flint.jackson) string encodeBase64(scope const(ubyte)[] input) pure nothrow
{
    auto output = new char[(input.length + 2) / 3 * 4];
    size_t o;
    size_t i;
    for (; i + 3 <= input.length; i += 3)
    {
        const bits = (input[i] << 16) | (input[i + 1] << 8) | input[i + 2];
        output[o .. o + 4] = [
            alphabet[bits >> 18], alphabet[(bits >> 12) & 63], alphabet[(bits >> 6) & 63],
            alphabet[bits & 63]
        ];
        o += 4;
    }
    if (i < input.length)
    {
        const two = i + 1 < input.length;
        const bits = (input[i] << 16) | (two ? input[i + 1] << 8 : 0);
        output[o .. o + 4] = [
            alphabet[bits >> 18], alphabet[(bits >> 12) & 63], two ? alphabet[(bits >> 6) & 63] : '=',
            '='
        ];
    }
    return output.idup;
}

/// `Base64Variant.decode(input)`: whitespace between quartets is skipped and padding is required. Returns null
/// and sets `error` to Jackson's description when the text is not Base64.
package(flint.jackson) ubyte[] decodeBase64(scope const(char)[] input, out string error) pure nothrow
{
    ubyte[] output;
    size_t i;
    for (;;)
    {
        while (i < input.length && input[i] <= ' ')
            ++i;
        if (i >= input.length)
            return output;
        int[4] sextets;
        const count = readUnit(input, i, sextets, error);
        if (error !is null)
            return null;
        const bits = (sextets[0] << 18) | (sextets[1] << 12) | (sextets[2] << 6) | sextets[3];
        output ~= cast(ubyte)(bits >> 16);
        if (count >= 3)
            output ~= cast(ubyte)(bits >> 8);
        if (count == 4)
            output ~= cast(ubyte) bits;
    }
}

// One 4-character unit at `i`: the number of data characters (2 or 3 before padding, else 4), or an error.
private size_t readUnit(scope const(char)[] input, ref size_t i, ref int[4] sextets, out string error) pure nothrow
{
    foreach (count; 0 .. 4)
    {
        if (i >= input.length)
        {
            error = missingPadding;
            return 0;
        }
        const c = input[i++];
        if (c == '=' && count >= 2)
        {
            // One '=' after three characters, two after two.
            if (count == 2 && (i >= input.length || input[i++] != '='))
                error = missingPadding;
            return count;
        }
        sextets[count] = valueOf(c);
        if (sextets[count] < 0)
        {
            error = illegal(c, count);
            return 0;
        }
    }
    return 4;
}

private enum missingPadding = "Unexpected end of base64-encoded String: base64 variant 'MIME-NO-LINEFEEDS' expects "
    ~ "padding (one or more '=' characters) at the end. This Base64Variant might have been incorrectly configured";

private int valueOf(char c) pure nothrow @nogc
{
    if (c >= 'A' && c <= 'Z')
        return c - 'A';
    if (c >= 'a' && c <= 'z')
        return c - 'a' + 26;
    if (c >= '0' && c <= '9')
        return c - '0' + 52;
    return c == '+' ? 62 : c == '/' ? 63 : -1;
}

// Base64Variant._reportInvalidBase64Char.
private string illegal(char c, size_t index) pure nothrow
{
    import flint.engine.aot.text : decimal;

    static immutable hex = "0123456789abcdef";
    const code = "0x" ~ (c >= 16 ? [hex[c >> 4]] : "") ~ hex[c & 15];
    if (c <= ' ')
        return "Illegal white space character (code " ~ code ~ ") as character #" ~ decimal(
                cast(long) index + 1) ~ " of 4-char base64 unit: can only used between units";
    if (c == '=')
        return "Unexpected padding character ('=') as character #" ~ decimal(
                cast(long) index + 1) ~ " of 4-char base64 unit: padding only legal as 3rd or 4th character";
    return "Illegal character '" ~ c ~ "' (code " ~ code ~ ") in base64 content";
}

@("Base64 round trips and the standard vectors")
unittest
{
    static immutable string[7] encoded = [
        "", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"
    ];
    foreach (n, expected; encoded)
    {
        const bytes = cast(const(ubyte)[]) "foobar"[0 .. n];
        assert(encodeBase64(bytes) == expected, expected);
        string error;
        assert(decodeBase64(expected, error) == bytes && error is null, expected);
    }
    string error;
    assert(decodeBase64(" Zm9v Zg== ", error) == cast(const(ubyte)[]) "foof" && error is null);
    assert(decodeBase64("Zm9", error) is null && error == missingPadding);
    assert(decodeBase64("Zm!v", error) is null && error == "Illegal character '!' (code 0x21) in base64 content");
}
