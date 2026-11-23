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
import flint.http.converter : AbstractHttpMessageConverter, HttpMessageNotReadableException,
    HttpMessageNotWritableException;
import flint.jackson.databind : JsonGenerator, ObjectMapper;

@safe:

/// `JacksonJsonHttpMessageConverter`: `application/json` and `application/*+json` through Jackson.
class JacksonJsonHttpMessageConverter : AbstractHttpMessageConverter
{
    private ObjectMapper mapper;

    /// With a default mapper.
    this()
    {
        this(new ObjectMapper);
    }

    /// With `mapper` (Spring Boot passes its auto-configured `JsonMapper`).
    this(ObjectMapper mapper)
    {
        super(MediaType.APPLICATION_JSON, MediaType("application", "*+json"));
        this.mapper = mapper;
        mapper.addCustomWriter("flint.http.ProblemDetail", &writeProblemDetail);
    }

    /// The mapper.
    ObjectMapper getMapper() pure nothrow @nogc
    {
        return mapper;
    }

    protected override bool supports(string typeName)
    {
        return mapper.canSerialize(typeName) || typeName == "flint.engine.aot.any.Any";
    }

    protected override Any readInternal(string typeName, HttpInputMessage inputMessage)
    {
        throw new HttpMessageNotReadableException("JSON parse error: reading " ~ typeName
                ~ " waits for flint.jackson.databind", null, inputMessage);
    }

    protected override void writeInternal(Any value, HttpOutputMessage outputMessage)
    {
        string json;
        try
            json = mapper.writeValueAsString(value);
        catch (Exception e)
            throw new HttpMessageNotWritableException("Could not write JSON: " ~ e.msg, e);
        outputMessage.writeBody(cast(const(ubyte)[]) json);
    }

    private void writeProblemDetail(ref Any value, JsonGenerator generator)
    {
        auto detail = value.get!ProblemDetail;
        generator.writeStartObject();
        if (detail.getDetail().length != 0)
        {
            generator.writeName("detail");
            generator.writeString(detail.getDetail());
        }
        if (auto instance = detail.getInstance())
            if (instance.toString().length != 0)
            {
                generator.writeName("instance");
                generator.writeString(instance.toString());
            }
        generator.writeName("status");
        generator.writeNumber(cast(long) detail.getStatus());
        if (detail.getTitle().length != 0)
        {
            generator.writeName("title");
            generator.writeString(detail.getTitle());
        }
        if (auto type = detail.getType())
            if (type.toString().length != 0)
            {
                generator.writeName("type");
                generator.writeString(type.toString());
            }
        foreach (name; detail.getPropertyNames())
        {
            generator.writeName(name);
            generator.writePOJO(detail.getProperty(name));
        }
        generator.writeEndObject();
    }
}
