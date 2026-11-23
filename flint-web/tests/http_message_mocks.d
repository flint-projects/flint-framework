/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/testFixtures/java/org/springframework/web/testfixture/http/MockHttpInputMessage.java and
MockHttpOutputMessage.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: flint.http's HttpInputMessage hands out the body bytes and HttpOutputMessage
appends to them, so the `InputStream` body and its constructor become a `const(ubyte)[]` and the
`ByteArrayOutputStream` a `ubyte[]`; the headers are created writable up front so copies share them;
`getBodyAsString(Charset)` decodes UTF-8, US-ASCII and ISO-8859-1 (the charsets the ported tests use).
+/
module flint.http.testfixture.mock_http_messages;

import flint.http : HttpHeaders, HttpInputMessage, HttpOutputMessage;
import flint.java.nio.charset : Charset, StandardCharsets, UnsupportedCharsetException;

@safe:

/// `MockHttpInputMessage`: mock implementation of `HttpInputMessage`.
class MockHttpInputMessage : HttpInputMessage
{
    private HttpHeaders headers;
    private const(ubyte)[] content;

    /// Create a `MockHttpInputMessage` with the supplied body.
    this(const(ubyte)[] body) pure nothrow
    {
        headers = HttpHeaders.create();
        this.content = body;
    }

    HttpHeaders getHeaders()
    {
        return headers;
    }

    const(ubyte)[] getBody()
    {
        return content;
    }
}

/// `MockHttpOutputMessage`: mock implementation of `HttpOutputMessage`.
class MockHttpOutputMessage : HttpOutputMessage
{
    private HttpHeaders headers;
    private ubyte[] content;

    ///
    this() pure nothrow
    {
        headers = HttpHeaders.create();
    }

    HttpHeaders getHeaders()
    {
        return headers;
    }

    /// Appends `bytes` to the body.
    void writeBody(scope const(ubyte)[] bytes)
    {
        content ~= bytes;
    }

    /// Return the body content as a byte array.
    ubyte[] getBodyAsBytes() const pure nothrow
    {
        return content.dup;
    }

    /// Return the body content interpreted as a UTF-8 string.
    string getBodyAsString() const pure
    {
        return getBodyAsString(StandardCharsets.UTF_8);
    }

    /// Return the body content interpreted as a string using the supplied character set.
    string getBodyAsString(const Charset charset) const pure
    {
        import std.utf : encode;

        if (charset == StandardCharsets.UTF_8)
            return cast(string) content.idup;
        if (charset != StandardCharsets.ISO_8859_1 && charset != StandardCharsets.US_ASCII)
            throw new UnsupportedCharsetException(charset.name());
        char[] result;
        foreach (b; content)
            encode(result, b < 0x80 || charset == StandardCharsets.ISO_8859_1 ? dchar(b) : dchar(0xFFFD));
        return result.idup;
    }
}
