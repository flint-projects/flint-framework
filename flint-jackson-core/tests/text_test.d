/// The text jackson-core builds through flint.engine.aot.text rather than Phobos: non-ASCII escaping of well-formed
/// and malformed UTF-8, location and error descriptions, and the trimming of coerced string values.
module flint.jackson.text_test;

import flint.jackson.core : JacksonException, JsonToken, ObjectWriteContext, TokenStreamLocation;
import flint.jackson.core.json : JsonFactory, JsonWriteFeature;
import flint.jackson.core.util : ByteArrayBuilder;

@safe:

private string escaped(string text)
{
    auto output = new ByteArrayBuilder();
    auto factory = JsonFactory.builder().enable(JsonWriteFeature.ESCAPE_NON_ASCII).build();
    auto g = factory.createGenerator(ObjectWriteContext.empty(), output);
    g.writeString(text);
    g.close();
    return output.toUtf8String();
}

@("ESCAPE_NON_ASCII: code points, surrogate pairs and a real U+FFFD")
unittest
{
    assert(escaped("caf\u00e9 \U0001F600 \uFFFD") == `"caf\u00E9 \uD83D\uDE00 \uFFFD"`);
}

@("ESCAPE_NON_ASCII: each malformed byte escapes as U+FFFD and output resumes at the next byte")
unittest
{
    // A bad lead byte, a truncated sequence, a bad continuation byte, an overlong form and a surrogate: Jackson
    // resumes after the first byte, so the bytes after it are read again.
    assert(escaped("a\xFFb") == `"a\uFFFDb"`);
    assert(escaped("\xE2\x82!") == `"\uFFFD\uFFFD!"`);
    assert(escaped("\xE2\x41") == `"\uFFFDA"`);
    assert(escaped("\xC0\xAF") == `"\uFFFD\uFFFD"`);
    assert(escaped("\xED\xA0\x80") == `"\uFFFD\uFFFD\uFFFD"`);
    // Negative: a well-formed U+FFFD is one code point, not three malformed bytes.
    assert(escaped("\xEF\xBF\xBDz") == `"\uFFFDz"`);
}

@("TokenStreamLocation.offsetDescription")
unittest
{
    assert(new TokenStreamLocation(0, -1, 3, 15).offsetDescription() == "line: 3, column: 15");
    assert(new TokenStreamLocation(0, -1, -1, -1).offsetDescription() == "UNKNOWN");
}

/// The message of the error reading `doc`, or null when it reads without one.
private string readError(string doc)
{
    auto p = JsonFactory.builder().build().createParser(doc);
    try
    {
        foreach (_; 0 .. 4)
            p.nextToken();
    }
    catch (JacksonException e)
        return e.getOriginalMessage();
    return null;
}

@("The parser's unexpected-character message carries the character code")
unittest
{
    import std.algorithm.searching : startsWith;

    assert(readError("[1, 'x']").startsWith("Unexpected character (''' (code 39)): "));
    assert(readError("[1, \x01]").startsWith("Unexpected character ((CTRL-CHAR, code 1)): "));
    // Negative: a well-formed document has no error.
    assert(readError("[1, 2]") is null);
}

@("String values coerce to boolean and long after trimming ASCII and Unicode white space")
unittest
{
    auto p = JsonFactory.builder().build().createParser(`[" true\u00A0", "\u2003 42\t", " x "]`);
    assert(p.nextToken() == JsonToken.START_ARRAY);
    assert(p.nextToken() == JsonToken.VALUE_STRING && p.getValueAsBoolean());
    assert(p.nextToken() == JsonToken.VALUE_STRING && p.getValueAsLong() == 42);
    // Negative: text that is not a number or a boolean after trimming takes the default.
    assert(p.nextToken() == JsonToken.VALUE_STRING && p.getValueAsLong(-7) == -7 && !p.getValueAsBoolean());
}
