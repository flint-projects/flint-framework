/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/http/converter/HttpMessageConverterTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the erased
`HttpMessageConverter` drops `<T>`, `MyType.class` is `MyType`'s fully qualified name, and Java's
`AssertionError("Not expected")` is `assert(false, "Not expected")`.
+/
module flint.http.converter.http_message_converter_tests;

import flint.engine.aot.any : Any;
import flint.http : HttpInputMessage, HttpOutputMessage, MediaType;
import flint.http.converter : AbstractHttpMessageConverter, HttpMessageConverter;
import std.traits : fullyQualifiedName;

@safe:

private enum string myType = fullyQualifiedName!MyType;

@("HttpMessageConverterTests.canRead")
unittest
{
    const mediaType = MediaType("foo", "bar");
    HttpMessageConverter converter = new MyHttpMessageConverter(mediaType);

    const fooWildcard = MediaType("foo", "*");
    assert(converter.canRead(myType, &mediaType));
    assert(!converter.canRead(myType, &fooWildcard));
    assert(!converter.canRead(myType, &MediaType.ALL));
}

@("HttpMessageConverterTests.canReadWithWildcardSubtype")
unittest
{
    const mediaType = MediaType("foo");
    HttpMessageConverter converter = new MyHttpMessageConverter(mediaType);

    const fooBar = MediaType("foo", "bar");
    const fooWildcard = MediaType("foo", "*");
    assert(converter.canRead(myType, &fooBar));
    assert(converter.canRead(myType, &fooWildcard));
    assert(!converter.canRead(myType, &MediaType.ALL));
}

@("HttpMessageConverterTests.canWrite")
unittest
{
    const mediaType = MediaType("foo", "bar");
    HttpMessageConverter converter = new MyHttpMessageConverter(mediaType);

    const fooWildcard = MediaType("foo", "*");
    assert(converter.canWrite(myType, &mediaType));
    assert(converter.canWrite(myType, &fooWildcard));
    assert(converter.canWrite(myType, &MediaType.ALL));
}

@("HttpMessageConverterTests.canWriteWithWildcardInSupportedSubtype")
unittest
{
    const mediaType = MediaType("foo");
    HttpMessageConverter converter = new MyHttpMessageConverter(mediaType);

    const fooBar = MediaType("foo", "bar");
    const fooWildcard = MediaType("foo", "*");
    assert(converter.canWrite(myType, &fooBar));
    assert(converter.canWrite(myType, &fooWildcard));
    assert(converter.canWrite(myType, &MediaType.ALL));
}

private class MyHttpMessageConverter : AbstractHttpMessageConverter
{
    this(MediaType supportedMediaType)
    {
        super(supportedMediaType);
    }

    protected override bool supports(string typeName)
    {
        return typeName == myType;
    }

    protected override Any readInternal(string typeName, HttpInputMessage inputMessage)
    {
        assert(false, "Not expected");
    }

    protected override void writeInternal(Any value, HttpOutputMessage outputMessage)
    {
        assert(false, "Not expected");
    }
}

private class MyType
{
}
