/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/http/converter/StringHttpMessageConverterTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; `String.class` is the
type name `"string"`, bodies go in and out as `Any`; the per-test fields are locals; `String.getBytes(Charset)`
is a private helper; the mocks come from `flint.http.testfixture.mock_http_messages`. Cases that need parts of
the converter or of HttpHeaders flint.http has not ported, or that differ from it, wait behind versions.
+/
module flint.http.converter.string_http_message_converter_tests;

import flint.engine.aot.any : Any;
import flint.http : HttpHeaders, MediaType;
import flint.http.converter : StringHttpMessageConverter;
import flint.http.testfixture.mock_http_messages : MockHttpInputMessage, MockHttpOutputMessage;
import flint.java.nio.charset : Charset, StandardCharsets;

@safe:

private immutable TEXT_PLAIN_UTF_8 = MediaType("text", "plain", StandardCharsets.UTF_8);

/// Java's `String.getBytes(charset)` for the charsets these cases use.
private ubyte[] getBytes(string text, const Charset charset) pure
{
    if (charset == StandardCharsets.UTF_8)
        return cast(ubyte[]) text.dup;
    ubyte[] result;
    foreach (dchar c; text)
        result ~= c < 0x80 || (c < 0x100 && charset == StandardCharsets.ISO_8859_1) ? cast(ubyte) c : '?';
    return result;
}

@("StringHttpMessageConverterTests.canRead")
unittest
{
    auto converter = new StringHttpMessageConverter();
    assert(converter.canRead("string", &MediaType.TEXT_PLAIN));
}

@("StringHttpMessageConverterTests.canWrite")
unittest
{
    auto converter = new StringHttpMessageConverter();
    assert(converter.canWrite("string", &MediaType.TEXT_PLAIN));
    assert(converter.canWrite("string", &MediaType.ALL));
}

@("StringHttpMessageConverterTests.read")
unittest
{
    auto converter = new StringHttpMessageConverter();
    const string body = "Hello World";
    auto inputMessage = new MockHttpInputMessage(body.getBytes(StandardCharsets.UTF_8));
    inputMessage.getHeaders().setContentType(TEXT_PLAIN_UTF_8);
    const result = converter.read("string", inputMessage).get!string;

    assert(result == body, "Invalid result");
}

@("StringHttpMessageConverterTests.readWithContentLengthHeader")
unittest
{
    auto converter = new StringHttpMessageConverter();
    const string body = "Hello World";
    auto inputMessage = new MockHttpInputMessage(body.getBytes(StandardCharsets.UTF_8));
    inputMessage.getHeaders().setContentLength(body.length);
    inputMessage.getHeaders().setContentType(TEXT_PLAIN_UTF_8);
    const result = converter.read("string", inputMessage).get!string;

    assert(result == body, "Invalid result");
}

// gh-24123
@("StringHttpMessageConverterTests.readJson")
unittest
{
    auto converter = new StringHttpMessageConverter();
    const string body = "{\"result\":\"\u0414\u0410\"}";
    auto inputMessage = new MockHttpInputMessage(body.getBytes(StandardCharsets.UTF_8));
    inputMessage.getHeaders().setContentType(MediaType.APPLICATION_JSON);
    const result = converter.read("string", inputMessage).get!string;

    assert(result == body, "Invalid result");
}

// gh-25328
@("StringHttpMessageConverterTests.readJsonApi")
unittest
{
    auto converter = new StringHttpMessageConverter();
    const string body = "{\"result\":\"\u0414\u0410\"}";
    auto inputMessage = new MockHttpInputMessage(body.getBytes(StandardCharsets.UTF_8));
    inputMessage.getHeaders().setContentType(MediaType("application", "vnd.api.v1+json"));
    const result = converter.read("string", inputMessage).get!string;

    assert(result == body, "Invalid result");
}

// flint.http's StringHttpMessageConverter defaults to UTF-8, as Spring Boot configures it (Spring: ISO-8859-1),
// and writes the string's UTF-8 bytes whatever the charset; HttpHeaders also has no getAcceptCharset() yet.
version (FlintStringConverterSpringDefaultCharset)
{
    @("StringHttpMessageConverterTests.writeDefaultCharset")
    unittest
    {
        auto converter = new StringHttpMessageConverter();
        auto outputMessage = new MockHttpOutputMessage();
        const string body = "H\u00e9llo W\u00f6rld";
        converter.write(Any.of(body), null, outputMessage);

        auto headers = outputMessage.getHeaders();
        assert(outputMessage.getBodyAsString(StandardCharsets.ISO_8859_1) == body);
        assert(*headers.getContentType() == MediaType("text", "plain", StandardCharsets.ISO_8859_1));
        assert(headers.getContentLength() == body.getBytes(StandardCharsets.ISO_8859_1).length);
        assert(headers.getAcceptCharset().length == 0);
    }

    // gh-24283
    @("StringHttpMessageConverterTests.writeWithWildCardMediaType")
    unittest
    {
        auto converter = new StringHttpMessageConverter();
        auto outputMessage = new MockHttpOutputMessage();
        const string body = "Hello World";
        converter.write(Any.of(body), &MediaType.ALL, outputMessage);

        auto headers = outputMessage.getHeaders();
        assert(outputMessage.getBodyAsString(StandardCharsets.US_ASCII) == body);
        assert(*headers.getContentType() == MediaType("text", "plain", StandardCharsets.ISO_8859_1));
        assert(headers.getContentLength() == body.length);
        assert(headers.getAcceptCharset().length == 0);
    }
}

// Spring's StringHttpMessageConverter leaves the charset off JSON content types (gh-24123, gh-25328); flint.http
// adds the default charset to them. HttpHeaders also has no getAcceptCharset() yet.
version (FlintStringConverterJsonCharset)
{
    // gh-24123
    @("StringHttpMessageConverterTests.writeJson")
    unittest
    {
        auto converter = new StringHttpMessageConverter();
        auto outputMessage = new MockHttpOutputMessage();
        const string body = "{\"føø\":\"bår\"}";
        converter.write(Any.of(body), &MediaType.APPLICATION_JSON, outputMessage);

        auto headers = outputMessage.getHeaders();
        assert(outputMessage.getBodyAsString(StandardCharsets.UTF_8) == body);
        assert(*headers.getContentType() == MediaType.APPLICATION_JSON);
        assert(headers.getContentLength() == body.getBytes(StandardCharsets.UTF_8).length);
        assert(headers.getAcceptCharset().length == 0);
    }

    // gh-25328
    @("StringHttpMessageConverterTests.writeJsonApi")
    unittest
    {
        auto converter = new StringHttpMessageConverter();
        auto outputMessage = new MockHttpOutputMessage();
        const string body = "{\"føø\":\"bår\"}";
        const contentType = MediaType("application", "vnd.api.v1+json");
        converter.write(Any.of(body), &contentType, outputMessage);

        auto headers = outputMessage.getHeaders();
        assert(outputMessage.getBodyAsString(StandardCharsets.UTF_8) == body);
        assert(*headers.getContentType() == contentType);
        assert(headers.getContentLength() == body.getBytes(StandardCharsets.UTF_8).length);
        assert(headers.getAcceptCharset().length == 0);
    }
}

// flint.http's HttpHeaders has no getAcceptCharset() yet.
version (FlintHttpHeadersAcceptCharset)
{
    @("StringHttpMessageConverterTests.writeUTF8")
    unittest
    {
        auto converter = new StringHttpMessageConverter();
        auto outputMessage = new MockHttpOutputMessage();
        const string body = "H\u00e9llo W\u00f6rld";
        converter.write(Any.of(body), &TEXT_PLAIN_UTF_8, outputMessage);

        auto headers = outputMessage.getHeaders();
        assert(outputMessage.getBodyAsString(StandardCharsets.UTF_8) == body);
        assert(*headers.getContentType() == TEXT_PLAIN_UTF_8);
        assert(headers.getContentLength() == body.getBytes(StandardCharsets.UTF_8).length);
        assert(headers.getAcceptCharset().length == 0);
    }

    // SPR-8867
    @("StringHttpMessageConverterTests.writeOverrideRequestedContentType")
    unittest
    {
        auto converter = new StringHttpMessageConverter();
        auto outputMessage = new MockHttpOutputMessage();
        const string body = "H\u00e9llo W\u00f6rld";
        const requestedContentType = MediaType("text", "html");

        auto headers = outputMessage.getHeaders();
        headers.setContentType(TEXT_PLAIN_UTF_8);
        converter.write(Any.of(body), &requestedContentType, outputMessage);

        assert(outputMessage.getBodyAsString(StandardCharsets.UTF_8) == body);
        assert(*headers.getContentType() == TEXT_PLAIN_UTF_8);
        assert(headers.getContentLength() == body.getBytes(StandardCharsets.UTF_8).length);
        assert(headers.getAcceptCharset().length == 0);
    }
}

// flint.http's converters have no supportsRepeatableWrites(T) yet.
version (FlintRepeatableWrites)
{
    @("StringHttpMessageConverterTests.repeatableWrites")
    unittest
    {
        auto converter = new StringHttpMessageConverter();
        auto outputMessage1 = new MockHttpOutputMessage();
        const string body = "Hello World";
        assert(converter.supportsRepeatableWrites(Any.of(body)));

        converter.write(Any.of(body), &TEXT_PLAIN_UTF_8, outputMessage1);
        assert(outputMessage1.getBodyAsString() == body);

        auto outputMessage2 = new MockHttpOutputMessage();
        converter.write(Any.of(body), &TEXT_PLAIN_UTF_8, outputMessage2);
        assert(outputMessage2.getBodyAsString() == body);
    }
}
