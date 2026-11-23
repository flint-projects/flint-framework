/++
`org.springframework.http.converter.json`: the Jackson JSON converter.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/http/converter/AbstractJacksonHttpMessageConverter.java,
spring-web/src/main/java/org/springframework/http/converter/json/JacksonJsonHttpMessageConverter.java and
ProblemDetailJacksonMixin.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. The converter writes through
`flint.jackson.databind.ObjectMapper` with the value's descriptor (ADR-030 section 5). It registers Spring's
`ProblemDetailJacksonMixin` behaviour: `@JsonInclude(NON_EMPTY)` and the `properties` map as `@JsonAnyGetter`, after
the other properties, which Jackson 3 sorts by name (detail, instance, status, title, type).
+/
module flint.http.converter.json;

import flint.engine.aot.any : Any;
import flint.http : HttpInputMessage, HttpOutputMessage, MediaType, ProblemDetail;
import flint.http.converter : AbstractHttpMessageConverter, HttpMessageConversionException,
    HttpMessageNotReadableException, HttpMessageNotWritableException;
import flint.jackson.core : JacksonException;
import flint.jackson.databind : JsonMapper, ObjectMapper;
import flint.jackson.databind.exc : InvalidDefinitionException;

@safe:

/// `JacksonJsonHttpMessageConverter`: `application/json` and `application/*+json` through Jackson.
class JacksonJsonHttpMessageConverter : AbstractHttpMessageConverter
{
    private ObjectMapper mapper;

    /// With a default mapper.
    this()
    {
        this(new JsonMapper);
    }

    /// With `mapper` (Spring Boot passes its auto-configured `JsonMapper`).
    this(ObjectMapper mapper)
    {
        super(MediaType.APPLICATION_JSON, MediaType("application", "*+json"));
        this.mapper = mapper;
    }

    /// The mapper.
    ObjectMapper getMapper() pure nothrow @nogc
    {
        return mapper;
    }

    protected override bool supports(string typeName)
    {
        return typeName == "flint.engine.aot.any.Any" || typeName == "flint.http.ProblemDetail"
            || mapper.descriptors().find(typeName) !is null;
    }

    /// `AbstractJacksonHttpMessageConverter.readJavaType`: the body through the mapper's descriptor of `typeName`.
    /// A type the mapper cannot handle is a conversion error (500); any other Jackson failure is unreadable input
    /// (400), with Jackson's original message.
    protected override Any readInternal(string typeName, HttpInputMessage inputMessage)
    {
        try
            return mapper.readValue(inputMessage.getBody(), typeName);
        catch (InvalidDefinitionException ex)
            throw new HttpMessageConversionException("Type definition error: " ~ ex.getType(), ex);
        catch (JacksonException ex)
            throw new HttpMessageNotReadableException("JSON parse error: " ~ ex.getOriginalMessage(), ex, inputMessage);
    }

    protected override void writeInternal(Any value, HttpOutputMessage outputMessage)
    {
        string json;
        try
            json = value.holds!ProblemDetail
                ? problemDetailJson(value.get!ProblemDetail) : mapper.writeValueAsString(value);
        catch (Exception e)
            throw new HttpMessageNotWritableException("Could not write JSON: " ~ e.msg, e);
        outputMessage.writeBody(cast(const(ubyte)[]) json);
    }

    /// `ProblemDetailJacksonMixin`: `@JsonInclude(NON_EMPTY)`, Jackson 3's name order for the bean properties
    /// (detail, instance, status, title, type), then the `properties` map as `@JsonAnyGetter`. Each value is
    /// written by the mapper, so escaping and numbers are Jackson's.
    private string problemDetailJson(ProblemDetail detail)
    {
        string json = "{";
        void member(string name, string encoded)
        {
            json ~= (json.length > 1 ? "," : "") ~ mapper.writeValueAsString(Any.of(name)) ~ ":" ~ encoded;
        }

        if (detail.getDetail().length != 0)
            member("detail", mapper.writeValueAsString(Any.of(detail.getDetail())));
        if (auto instance = detail.getInstance())
            if (instance.toString().length != 0)
                member("instance", mapper.writeValueAsString(Any.of(instance.toString())));
        member("status", mapper.writeValueAsString(Any.of(cast(long) detail.getStatus())));
        if (detail.getTitle().length != 0)
            member("title", mapper.writeValueAsString(Any.of(detail.getTitle())));
        if (auto type = detail.getType())
            if (type.toString().length != 0)
                member("type", mapper.writeValueAsString(Any.of(type.toString())));
        foreach (name; detail.getPropertyNames())
            member(name, mapper.writeValueAsString(detail.getProperty(name)));
        return json ~ "}";
    }
}
