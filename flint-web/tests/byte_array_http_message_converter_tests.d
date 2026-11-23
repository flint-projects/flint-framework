/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/http/converter/ByteArrayHttpMessageConverterTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; `byte[].class` is the
type name `"ubyte[]"`, bodies go in and out as `Any`; the `@BeforeEach` field is a local; the mocks come from
`flint.http.testfixture.mock_http_messages`. Cases that need parts of the converter flint.http has not ported wait
behind versions.
+/
module flint.http.converter.byte_array_http_message_converter_tests;

import flint.engine.aot.any : Any;
import flint.http : MediaType;
import flint.http.converter : ByteArrayHttpMessageConverter;
import flint.http.testfixture.mock_http_messages : MockHttpInputMessage, MockHttpOutputMessage;

@safe:

@("ByteArrayHttpMessageConverterTests.canRead")
unittest
{
    auto converter = new ByteArrayHttpMessageConverter();
    const mediaType = MediaType("application", "octet-stream");
    assert(converter.canRead("ubyte[]", &mediaType));
}

@("ByteArrayHttpMessageConverterTests.canWrite")
unittest
{
    auto converter = new ByteArrayHttpMessageConverter();
    const mediaType = MediaType("application", "octet-stream");
    assert(converter.canWrite("ubyte[]", &mediaType));
    assert(converter.canWrite("ubyte[]", &MediaType.ALL));
}

@("ByteArrayHttpMessageConverterTests.read")
unittest
{
    auto converter = new ByteArrayHttpMessageConverter();
    const ubyte[] body = [0x1, 0x2];
    auto inputMessage = new MockHttpInputMessage(body);
    inputMessage.getHeaders().setContentType(MediaType("application", "octet-stream"));
    const result = converter.read("ubyte[]", inputMessage).get!(ubyte[]);
    assert(result == body, "Invalid result");
}

@("ByteArrayHttpMessageConverterTests.readWithContentLengthHeaderSet")
unittest
{
    auto converter = new ByteArrayHttpMessageConverter();
    const ubyte[] body = [0x1, 0x2, 0x3, 0x4, 0x5];
    auto inputMessage = new MockHttpInputMessage(body);
    inputMessage.getHeaders().setContentType(MediaType("application", "octet-stream"));
    inputMessage.getHeaders().setContentLength(body.length);
    const result = converter.read("ubyte[]", inputMessage).get!(ubyte[]);
    assert(result == body, "Invalid result");
}

@("ByteArrayHttpMessageConverterTests.write")
unittest
{
    auto converter = new ByteArrayHttpMessageConverter();
    auto outputMessage = new MockHttpOutputMessage();
    ubyte[] body = [0x1, 0x2]; // mutable: Any.of records the exact `ubyte[]` the converter reads back
    converter.write(Any.of(body), null, outputMessage);
    assert(outputMessage.getBodyAsBytes() == body, "Invalid result");
    assert(*outputMessage.getHeaders().getContentType() == MediaType.APPLICATION_OCTET_STREAM);
    assert(outputMessage.getHeaders().getContentLength() == 2);
}

// flint.http's converters have no supportsRepeatableWrites(T) yet.
version (FlintRepeatableWrites)
{
    @("ByteArrayHttpMessageConverterTests.repeatableWrites")
    unittest
    {
        auto converter = new ByteArrayHttpMessageConverter();
        auto outputMessage1 = new MockHttpOutputMessage();
        ubyte[] body = [0x1, 0x2]; // mutable: Any.of records the exact `ubyte[]` the converter reads back
        assert(converter.supportsRepeatableWrites(Any.of(body)));

        converter.write(Any.of(body), null, outputMessage1);
        assert(outputMessage1.getBodyAsBytes() == body);

        auto outputMessage2 = new MockHttpOutputMessage();
        converter.write(Any.of(body), null, outputMessage2);
        assert(outputMessage2.getBodyAsBytes() == body);
    }
}
