/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/http/converter/json/JacksonJsonHttpMessageConverterTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; `Class<?>` arguments
are Flint type names (`typeNameOf!MyBean`, `Map.class` is `Map!(string, Any)`), bodies go in and out as `Any`; the
`converter` field is a local whose mapper holds the Flint AOT descriptors of the test beans, built by hand as the
AOT registry would (MyBean's descriptor carries MyBase's inherited accessors); bean fields named after D keywords
take a trailing underscore; `String.getBytes(UTF_8)` is a cast; an untyped JSON array reads as a `JsonNode` array,
which flint.jackson's UntypedObjectDeserializer builds where Jackson builds an `ArrayList`; the mocks come from
`flint.http.testfixture.mock_http_messages`. Cases that need parts of the converter or of flint.jackson that are not
ported yet wait behind versions.
+/
module flint.http.converter.jackson_json_http_message_converter_tests;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : ConstructorDescriptor, Descriptor, DescriptorTable,
    ParameterDescriptor, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.http : MediaType;
import flint.http.converter : HttpMessageNotReadableException;
import flint.http.converter.json : JacksonJsonHttpMessageConverter;
import flint.http.testfixture.mock_http_messages : MockHttpInputMessage, MockHttpOutputMessage;
import flint.jackson.databind : JsonMapper;
import flint.jackson.databind.node : JsonNode;
import flint.java.nio.charset : StandardCharsets;
import flint.java.util : HashMap, Map;
import std.algorithm.searching : canFind;
import std.exception : assertThrown;

@safe:

private interface MyInterface
{
    string getString();

    void setString(string value);
}

private class MyBase : MyInterface
{
    private string string_;

    string getString()
    {
        return string_;
    }

    void setString(string value)
    {
        string_ = value;
    }
}

private class MyBean : MyBase
{
    private int number;
    private float fraction;
    private string[] array;
    private bool bool_;
    private byte[] bytes;

    int getNumber()
    {
        return number;
    }

    void setNumber(int number)
    {
        this.number = number;
    }

    float getFraction()
    {
        return fraction;
    }

    void setFraction(float fraction)
    {
        this.fraction = fraction;
    }

    string[] getArray()
    {
        return array;
    }

    void setArray(string[] array)
    {
        this.array = array;
    }

    bool isBool()
    {
        return bool_;
    }

    void setBool(bool value)
    {
        bool_ = value;
    }

    byte[] getBytes()
    {
        return bytes;
    }

    void setBytes(byte[] bytes)
    {
        this.bytes = bytes;
    }
}

/// MyBean's descriptor, with the accessors it inherits from MyBase first, as Jackson lists them.
private Descriptor myBeanDescriptor()
{
    auto d = descriptorOf!MyBean();
    d.properties = descriptorOf!MyBase().properties ~ d.properties;
    return d;
}

/// The descriptors the Flint AOT registry would hold for this module's beans.
private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!MyInterface(), descriptorOf!MyBase(), myBeanDescriptor(),
        descriptorOf!(string[])(), descriptorOf!(byte[])(), descriptorOf!(Map!(string, Any))(),
        descriptorOf!(HashMap!(string, Any))()
    ])
        t.add(d);
    version (FlintJacksonGenericTypes)
        foreach (d; [
            descriptorOf!(List!MyBean)(), descriptorOf!(ArrayList!MyBean)(),
            descriptorOf!(List!MyBase)(), descriptorOf!(List!MyInterface)(),
            descriptorOf!MyParent(), descriptorOf!Impl1(), descriptorOf!Impl2(),
            descriptorOf!(Optional!MyParent)()
    ])
            t.add(d);
    version (FlintJacksonPrettyPrint)
        t.add(descriptorOf!PrettyPrintBean());
    version (FlintJacksonJsonView)
        t.add(descriptorOf!JacksonViewBean());
    version (FlintJacksonFilters)
        t.add(descriptorOf!JacksonFilteredBean());
    t.add(beanWithNoDefaultConstructorDescriptor());
    version (FlintJacksonCustomizers)
        foreach (d; [descriptorOf!MyCustomizedBean(), descriptorOf!MyCustomEnum()])
            t.add(d);
    return t;
}

/// A builder for Jackson's default mapper over this module's descriptors.
private JsonMapper.Builder mapperBuilder()
{
    return JsonMapper.builder().descriptors(table());
}

/// The upstream `converter` field: `new JacksonJsonHttpMessageConverter()`, over this module's descriptors.
private JacksonJsonHttpMessageConverter newConverter()
{
    return new JacksonJsonHttpMessageConverter(mapperBuilder().build());
}

private immutable string myBeanJson = "{" ~ "\"bytes\":\"AQI=\"," ~ "\"array\":[\"Foo\",\"Bar\"],"
    ~ "\"number\":42," ~ "\"string\":\"Foo\"," ~ "\"bool\":true," ~ "\"fraction\":42.0}";

// SPR-7905
@("JacksonJsonHttpMessageConverterTests.canReadAndWriteMicroformats")
unittest
{
    auto converter = newConverter();
    const microType = MediaType("application", "vnd.test-micro-type+json");
    assert(converter.canRead(typeNameOf!MyBean, &microType));
    assert(converter.canWrite(typeNameOf!MyBean, &microType));
}

@("JacksonJsonHttpMessageConverterTests.write")
unittest
{
    auto converter = newConverter();
    auto outputMessage = new MockHttpOutputMessage();
    auto bean = new MyBean();
    bean.setString("Foo");
    bean.setNumber(42);
    bean.setFraction(42F);
    bean.setArray(["Foo", "Bar"]);
    bean.setBool(true);
    bean.setBytes([0x1, 0x2]);
    converter.write(Any.of(bean), null, outputMessage);
    const result = outputMessage.getBodyAsString(StandardCharsets.UTF_8);
    assert(result.canFind("\"string\":\"Foo\""));
    assert(result.canFind("\"number\":42"));
    assert(result.canFind("fraction\":42.0"));
    assert(result.canFind("\"array\":[\"Foo\",\"Bar\"]"));
    assert(result.canFind("\"bool\":true"));
    assert(result.canFind("\"bytes\":\"AQI=\""));
    assert(*outputMessage.getHeaders().getContentType() == MediaType.APPLICATION_JSON, "Invalid content-type");
}

@("JacksonJsonHttpMessageConverterTests.readInvalidJson")
unittest
{
    auto converter = newConverter();
    auto inputMessage = new MockHttpInputMessage(cast(const(ubyte)[]) "FooBar");
    inputMessage.getHeaders().setContentType(MediaType("application", "json"));
    assertThrown!HttpMessageNotReadableException(converter.read(typeNameOf!MyBean, inputMessage));
}

@("JacksonJsonHttpMessageConverterTests.writeAscii")
unittest
{
    auto converter = newConverter();
    auto outputMessage = new MockHttpOutputMessage();
    Map!(string, Any) map = new HashMap!(string, Any)();
    map.put("foo", Any.of("bar"));
    const charset = StandardCharsets.US_ASCII;
    const contentType = MediaType("application", "json", charset);
    converter.write(Any.of(map), &contentType, outputMessage);

    const result = outputMessage.getBodyAsString(charset);
    assert(result == "{\"foo\":\"bar\"}");
    assert(*outputMessage.getHeaders().getContentType() == contentType, "Invalid content-type");
}

@("JacksonJsonHttpMessageConverterTests.repeatableWrites")
unittest
{
    auto converter = newConverter();
    auto outputMessage1 = new MockHttpOutputMessage();
    auto bean = new MyBean();
    bean.setString("Foo");
    converter.write(Any.of(bean), null, outputMessage1);
    string result = outputMessage1.getBodyAsString(StandardCharsets.UTF_8);
    assert(result.canFind("\"string\":\"Foo\""));

    auto outputMessage2 = new MockHttpOutputMessage();
    converter.write(Any.of(bean), null, outputMessage2);
    result = outputMessage2.getBodyAsString(StandardCharsets.UTF_8);
    assert(result.canFind("\"string\":\"Foo\""));
}

// flint.http has no ResolvableType read/write overloads or getJavaType hook; flint.jackson no @JsonTypeInfo.
version (FlintJacksonGenericTypes)
{
    import flint.core : ParameterizedTypeReference, ResolvableType;
    import flint.http : ResponseEntity;
    import flint.jackson.annotation : JsonSubTypes, JsonTypeInfo;
    import flint.jackson.databind : JavaType, ObjectMapper;
    import flint.java.lang : classOf;
    import flint.java.util : ArrayList, List, Optional;

    private ResolvableType unresolvableType()
    {
        return ResolvableType.forClass(typeNameOf!ResponseEntity).getNested(2);
    }

    /// JSONAssert.assertEquals(expected, actual, true): the same JSON trees.
    private void assertJsonEquals(string expected, string actual)
    {
        auto mapper = new ObjectMapper();
        assert(mapper.readTree(expected).equals(mapper.readTree(actual)), actual);
    }

    @JsonTypeInfo(JsonTypeInfo.Id.NAME)
    @JsonSubTypes([JsonSubTypes.Type(classOf!Impl1), JsonSubTypes.Type(classOf!Impl2)])
    private interface MyParent
    {
    }

    private class Impl1 : MyParent
    {
    }

    private class Impl2 : MyParent
    {
    }

    @("JacksonJsonHttpMessageConverterTests.canRead")
    unittest
    {
        auto converter = newConverter();
        assert(converter.canRead(typeNameOf!MyBean, &MediaType.APPLICATION_JSON));
        assert(converter.canRead(typeNameOf!(Map!(string, Any)), &MediaType.APPLICATION_JSON));
        const utf8 = MediaType("application", "json", StandardCharsets.UTF_8);
        assert(converter.canRead(typeNameOf!MyBean, &utf8));
        const ascii = MediaType("application", "json", StandardCharsets.US_ASCII);
        assert(converter.canRead(typeNameOf!MyBean, &ascii));
        const latin1 = MediaType("application", "json", StandardCharsets.ISO_8859_1);
        assert(converter.canRead(typeNameOf!MyBean, &latin1));
        assert(converter.canRead(unresolvableType(), &MediaType.APPLICATION_JSON));
    }

    @("JacksonJsonHttpMessageConverterTests.readUnresolable")
    unittest
    {
        auto converter = newConverter();
        auto inputMessage = new MockHttpInputMessage(cast(const(ubyte)[]) myBeanJson);
        inputMessage.getHeaders().setContentType(MediaType("application", "json"));
        auto result = converter.read(unresolvableType(), inputMessage, null).get!(HashMap!(string, Any));
        assert(result.get("string").get!string == "Foo");
        assert(result.get("number").get!int == 42);
        assert(result.get("fraction").get!double == 42.0);
        auto array = result.get("array").get!(List!Any);
        assert(array.size() == 2 && array.get(0).get!string == "Foo" && array.get(1).get!string == "Bar");
        assert(result.get("bool").get!bool == true);
        assert(result.get("bytes").get!string == "AQI=");
    }

    @("JacksonJsonHttpMessageConverterTests.writeWithBaseType")
    unittest
    {
        auto converter = newConverter();
        auto outputMessage = new MockHttpOutputMessage();
        auto bean = new MyBean();
        bean.setString("Foo");
        bean.setNumber(42);
        bean.setFraction(42F);
        bean.setArray(["Foo", "Bar"]);
        bean.setBool(true);
        bean.setBytes([0x1, 0x2]);
        converter.write(Any.of(bean), ResolvableType.forClass(typeNameOf!MyBase), null, outputMessage, null);
        const result = outputMessage.getBodyAsString(StandardCharsets.UTF_8);
        assert(result.canFind("\"string\":\"Foo\""));
        assert(result.canFind("\"number\":42"));
        assert(result.canFind("fraction\":42.0"));
        assert(result.canFind("\"array\":[\"Foo\",\"Bar\"]"));
        assert(result.canFind("\"bool\":true"));
        assert(result.canFind("\"bytes\":\"AQI=\""));
        assert(*outputMessage.getHeaders().getContentType() == MediaType.APPLICATION_JSON, "Invalid content-type");
    }

    @("JacksonJsonHttpMessageConverterTests.readAndWriteGenerics")
    unittest
    {
        auto customizedConverter = new class JacksonJsonHttpMessageConverter
        {
            this()
            {
                super(mapperBuilder().build());
            }

            protected override JavaType getJavaType(string type, string contextClass)
            {
                if (type == typeNameOf!(List!Any))
                    return new ObjectMapper().getTypeFactory()
                        .constructCollectionType(typeNameOf!(ArrayList!MyBean), typeNameOf!MyBean);
                else
                    return super.getJavaType(type, contextClass);
            }
        };
        const json = "[" ~ myBeanJson ~ "]";
        auto inputMessage = new MockHttpInputMessage(cast(const(ubyte)[]) json);
        inputMessage.getHeaders().setContentType(MediaType("application", "json"));

        auto results = customizedConverter.read(typeNameOf!(List!Any), inputMessage).get!(List!MyBean);
        assert(results.size() == 1);
        auto result = results.get(0);
        assert(result.getString() == "Foo");
        assert(result.getNumber() == 42);
        assert(result.getFraction() == 42F);
        assert(result.getArray() == ["Foo", "Bar"]);
        assert(result.isBool());
        assert(result.getBytes() == [0x1, 0x2]);

        auto outputMessage = new MockHttpOutputMessage();
        customizedConverter.write(Any.of(results), &MediaType.APPLICATION_JSON, outputMessage);
        assertJsonEquals(json, outputMessage.getBodyAsString(StandardCharsets.UTF_8));
    }

    @("JacksonJsonHttpMessageConverterTests.readAndWriteParameterizedType")
    unittest
    {
        auto converter = newConverter();
        const beansList = ParameterizedTypeReference!(List!MyBean)();

        const json = "[" ~ myBeanJson ~ "]";
        auto inputMessage = new MockHttpInputMessage(cast(const(ubyte)[]) json);
        inputMessage.getHeaders().setContentType(MediaType.APPLICATION_JSON);

        auto results = converter.read(ResolvableType.forType(beansList), inputMessage, null).get!(List!MyBean);
        assert(results.size() == 1);
        auto result = results.get(0);
        assert(result.getString() == "Foo");
        assert(result.getNumber() == 42);
        assert(result.getFraction() == 42F);
        assert(result.getArray() == ["Foo", "Bar"]);
        assert(result.isBool());
        assert(result.getBytes() == [0x1, 0x2]);

        auto outputMessage = new MockHttpOutputMessage();
        converter.write(Any.of(results), ResolvableType.forType(beansList),
                &MediaType.APPLICATION_JSON, outputMessage, null);
        assertJsonEquals(json, outputMessage.getBodyAsString(StandardCharsets.UTF_8));
    }

    @("JacksonJsonHttpMessageConverterTests.writeParameterizedBaseType")
    unittest
    {
        auto converter = newConverter();
        const beansList = ParameterizedTypeReference!(List!MyBean)();
        const baseList = ParameterizedTypeReference!(List!MyBase)();

        const json = "[" ~ myBeanJson ~ "]";
        auto inputMessage = new MockHttpInputMessage(cast(const(ubyte)[]) json);
        inputMessage.getHeaders().setContentType(MediaType.APPLICATION_JSON);

        auto results = converter.read(ResolvableType.forType(beansList), inputMessage, null).get!(List!MyBean);
        assert(results.size() == 1);
        auto result = results.get(0);
        assert(result.getString() == "Foo");
        assert(result.getNumber() == 42);
        assert(result.getFraction() == 42F);
        assert(result.getArray() == ["Foo", "Bar"]);
        assert(result.isBool());
        assert(result.getBytes() == [0x1, 0x2]);

        auto outputMessage = new MockHttpOutputMessage();
        converter.write(Any.of(results), ResolvableType.forType(baseList),
                &MediaType.APPLICATION_JSON, outputMessage, null);
        assertJsonEquals(json, outputMessage.getBodyAsString(StandardCharsets.UTF_8));
    }

    // gh-24498
    @("JacksonJsonHttpMessageConverterTests.writeOptional")
    unittest
    {
        auto converter = newConverter();
        const optionalParent = ParameterizedTypeReference!(Optional!MyParent)();
        auto result = Optional!MyParent.of(new Impl1());
        auto outputMessage = new MockHttpOutputMessage();
        converter.write(Any.of(result), ResolvableType.forType(optionalParent.getType()),
                &MediaType.APPLICATION_JSON, outputMessage, null);

        assert(outputMessage.getBodyAsString(StandardCharsets.UTF_8).canFind("@type"));
    }

    // SPR-13318
    @("JacksonJsonHttpMessageConverterTests.writeSubType")
    unittest
    {
        auto converter = newConverter();
        auto outputMessage = new MockHttpOutputMessage();
        auto bean = new MyBean();
        bean.setString("Foo");
        bean.setNumber(42);

        converter.write(Any.of(bean), ResolvableType.forType(typeNameOf!MyInterface),
                &MediaType.APPLICATION_JSON, outputMessage, null);

        const result = outputMessage.getBodyAsString(StandardCharsets.UTF_8);
        assert(result.canFind("\"string\":\"Foo\""));
        assert(result.canFind("\"number\":42"));
    }

    // SPR-13318
    @("JacksonJsonHttpMessageConverterTests.writeSubTypeList")
    unittest
    {
        auto converter = newConverter();
        auto outputMessage = new MockHttpOutputMessage();
        List!MyBean beans = new ArrayList!MyBean();
        auto foo = new MyBean();
        foo.setString("Foo");
        foo.setNumber(42);
        beans.add(foo);
        auto bar = new MyBean();
        bar.setString("Bar");
        bar.setNumber(123);
        beans.add(bar);
        const typeReference = ParameterizedTypeReference!(List!MyInterface)();

        converter.write(Any.of(beans), ResolvableType.forType(typeReference),
                &MediaType.APPLICATION_JSON, outputMessage, null);

        const result = outputMessage.getBodyAsString(StandardCharsets.UTF_8);
        assert(result.canFind("\"string\":\"Foo\""));
        assert(result.canFind("\"number\":42"));
        assert(result.canFind("\"string\":\"Bar\""));
        assert(result.canFind("\"number\":123"));
    }
}

// flint.http's JacksonJsonHttpMessageConverter has no registerMappersForType.
version (FlintJacksonMapperRegistrations)
{
    import flint.jackson.databind : ObjectMapper;

    @("JacksonJsonHttpMessageConverterTests.canReadWithObjectMapperRegistrationForType")
    unittest
    {
        auto converter = newConverter();
        const halJsonMediaType = MediaType.parseMediaType("application/hal+json");
        const halFormsJsonMediaType = MediaType.parseMediaType("application/prs.hal-forms+json");

        assert(converter.canRead(typeNameOf!MyBean, &halJsonMediaType));
        assert(converter.canRead(typeNameOf!MyBean, &MediaType.APPLICATION_JSON));
        assert(converter.canRead(typeNameOf!MyBean, &halFormsJsonMediaType));
        assert(converter.canRead(typeNameOf!(Map!(string, Any)), &MediaType.APPLICATION_JSON));

        converter.registerMappersForType(typeNameOf!MyBean, (Map!(MediaType, ObjectMapper) map) {
            map.put(halJsonMediaType, new JsonMapper());
            map.put(MediaType.APPLICATION_JSON, new JsonMapper());
        });

        assert(converter.canRead(typeNameOf!MyBean, &halJsonMediaType));
        assert(converter.canRead(typeNameOf!MyBean, &MediaType.APPLICATION_JSON));
        assert(converter.canRead(typeNameOf!(Map!(string, Any)), &MediaType.APPLICATION_JSON));
    }

    @("JacksonJsonHttpMessageConverterTests.getSupportedMediaTypes")
    unittest
    {
        auto converter = newConverter();
        const MediaType[] defaultMediaTypes = [
            MediaType.APPLICATION_JSON, MediaType.parseMediaType("application/*+json")
        ];
        assert(converter.getSupportedMediaTypes() == defaultMediaTypes);
        assert(converter.getSupportedMediaTypes(typeNameOf!MyBean) == defaultMediaTypes);

        const halJson = MediaType.parseMediaType("application/hal+json");
        converter.registerMappersForType(typeNameOf!MyBean, (Map!(MediaType, ObjectMapper) map) {
            map.put(halJson, new JsonMapper());
            map.put(MediaType.APPLICATION_JSON, new JsonMapper());
        });

        assert(converter.getSupportedMediaTypes(typeNameOf!MyBean) == [
            halJson, MediaType.APPLICATION_JSON
        ]);
        assert(converter.getSupportedMediaTypes(typeNameOf!(Map!(string, Any))) == defaultMediaTypes);
    }
}

// The converter ignores charsets (accepts ISO-8859-1, always writes UTF-8) and has no MappingJacksonValue.
version (FlintJacksonEncodings)
{
    import flint.http.converter.json : MappingJacksonValue;
    import flint.java.lang : UnsupportedOperationException;

    @("JacksonJsonHttpMessageConverterTests.canWrite")
    unittest
    {
        auto converter = newConverter();
        assert(converter.canWrite(typeNameOf!MyBean, &MediaType.APPLICATION_JSON));
        assert(converter.canWrite(typeNameOf!(Map!(string, Any)), &MediaType.APPLICATION_JSON));
        const utf8 = MediaType("application", "json", StandardCharsets.UTF_8);
        assert(converter.canWrite(typeNameOf!MyBean, &utf8));
        const ascii = MediaType("application", "json", StandardCharsets.US_ASCII);
        assert(converter.canWrite(typeNameOf!MyBean, &ascii));
        const latin1 = MediaType("application", "json", StandardCharsets.ISO_8859_1);
        assert(!converter.canWrite(typeNameOf!MyBean, &latin1));
        assertThrown!UnsupportedOperationException(converter.canWrite(typeNameOf!MappingJacksonValue,
                &MediaType.APPLICATION_JSON));
    }

    @("JacksonJsonHttpMessageConverterTests.writeUTF16")
    unittest
    {
        auto converter = newConverter();
        const contentType = MediaType("application", "json", StandardCharsets.UTF_16BE);
        auto outputMessage = new MockHttpOutputMessage();
        const string text = "Héllo Wörld";
        converter.write(Any.of(text), &contentType, outputMessage);
        assert(outputMessage.getBodyAsString(StandardCharsets.UTF_16BE) == "\"" ~ text ~ "\"", "Invalid result");
        assert(*outputMessage.getHeaders().getContentType() == contentType, "Invalid content-type");
    }
}

@("JacksonJsonHttpMessageConverterTests.readTyped")
unittest
{
    auto converter = newConverter();
    auto inputMessage = new MockHttpInputMessage(cast(const(ubyte)[]) myBeanJson);
    inputMessage.getHeaders().setContentType(MediaType("application", "json"));
    auto result = converter.read(typeNameOf!MyBean, inputMessage).get!MyBean;
    assert(result.getString() == "Foo");
    assert(result.getNumber() == 42);
    assert(result.getFraction() == 42F);
    assert(result.getArray() == ["Foo", "Bar"]);
    assert(result.isBool());
    assert(result.getBytes() == [0x1, 0x2]);
}

@("JacksonJsonHttpMessageConverterTests.readUntyped")
unittest
{
    auto converter = newConverter();
    auto inputMessage = new MockHttpInputMessage(cast(const(ubyte)[]) myBeanJson);
    inputMessage.getHeaders().setContentType(MediaType("application", "json"));
    auto result = converter.read(typeNameOf!(HashMap!(string, Any)), inputMessage).get!(HashMap!(string, Any));
    assert(result.get("string").get!string == "Foo");
    assert(result.get("number").get!int == 42);
    assert(result.get("fraction").get!double == 42.0);
    auto array = result.get("array").get!JsonNode;
    assert(array.isArray() && array.size() == 2);
    assert(array.get(0).stringValue() == "Foo" && array.get(1).stringValue() == "Bar");
    assert(result.get("bool").get!bool == true);
    assert(result.get("bytes").get!string == "AQI=");
}

@("JacksonJsonHttpMessageConverterTests.readValidJsonWithUnknownProperty")
unittest
{
    auto converter = newConverter();
    const json = "{\"string\":\"string\",\"unknownProperty\":\"value\"}";
    auto inputMessage = new MockHttpInputMessage(cast(const(ubyte)[]) json);
    inputMessage.getHeaders().setContentType(MediaType("application", "json"));
    converter.read(typeNameOf!MyBean, inputMessage);
    // Assert no HttpMessageNotReadableException is thrown
}

private class BeanWithNoDefaultConstructor
{
    private const string property1;
    private const string property2;

    this(string property1, string property2)
    {
        this.property1 = property1;
        this.property2 = property2;
    }

    string getProperty1() const
    {
        return property1;
    }

    string getProperty2() const
    {
        return property2;
    }
}

private Any invokeBeanWithNoDefaultConstructor(scope Any[] arguments) @safe
{
    return Any.of(new BeanWithNoDefaultConstructor(arguments[0].get!string(), arguments[1].get!string()));
}

/// The single public constructor, with its parameter names, as Flint AOT records it.
private Descriptor beanWithNoDefaultConstructorDescriptor()
{
    auto d = descriptorOf!BeanWithNoDefaultConstructor();
    d.constructors = ConstructorDescriptor([
        ParameterDescriptor("property1", "string"), ParameterDescriptor("property2", "string")
    ], null, &invokeBeanWithNoDefaultConstructor) ~ d.constructors;
    return d;
}

// gh-27511
@("JacksonJsonHttpMessageConverterTests.readWithNoDefaultConstructor")
unittest
{
    auto converter = newConverter();
    const json = "{\"property1\":\"foo\",\"property2\":\"bar\"}";
    auto inputMessage = new MockHttpInputMessage(cast(const(ubyte)[]) json);
    inputMessage.getHeaders().setContentType(MediaType.APPLICATION_JSON);
    const bean = converter.read(typeNameOf!BeanWithNoDefaultConstructor, inputMessage)
        .get!BeanWithNoDefaultConstructor;
    assert(bean.property1 == "foo");
    assert(bean.property2 == "bar");
}

// flint.http reads a JSON body as UTF-8 bytes; it does not decode a non-Unicode charset as Spring's Reader does.
version (FlintJacksonNonUnicodeRead)
{
    @("JacksonJsonHttpMessageConverterTests.readNonUnicode")
    unittest
    {
        auto converter = newConverter();
        const ubyte[] json = ['{', '"', 0xF8, 0xF8, '"', ':', '"', 'b', 0xE5, 'r', '"', '}']; // {"føø":"bår"}
        const charset = StandardCharsets.ISO_8859_1;
        auto inputMessage = new MockHttpInputMessage(json);
        inputMessage.getHeaders().setContentType(MediaType("application", "json", charset));
        auto result = converter.read(typeNameOf!(HashMap!(string, Any)), inputMessage).get!(HashMap!(string, Any));

        assert(result.size() == 1);
        assert(result.get("føø").get!string == "bår");
    }
}

@("JacksonJsonHttpMessageConverterTests.readAscii")
unittest
{
    auto converter = newConverter();
    const json = "{\"foo\":\"bar\"}";
    const charset = StandardCharsets.US_ASCII;
    auto inputMessage = new MockHttpInputMessage(cast(const(ubyte)[]) json);
    inputMessage.getHeaders().setContentType(MediaType("application", "json", charset));
    auto result = converter.read(typeNameOf!(HashMap!(string, Any)), inputMessage).get!(HashMap!(string, Any));

    assert(result.size() == 1);
    assert(result.get("foo").get!string == "bar");
}

@("JacksonJsonHttpMessageConverterTests.readEmptyAsNull")
unittest
{
    auto converter = newConverter();
    auto inputMessage = new MockHttpInputMessage(cast(const(ubyte)[]) "null");
    inputMessage.getHeaders().setContentType(MediaType("application", "json"));
    assert(converter.read(typeNameOf!(Map!(string, Any)), inputMessage).isNull());
}

// flint.http has no ResolvableType write overload for INDENT_OUTPUT beans, nor the SSE `data:` line prefix.
version (FlintJacksonPrettyPrint)
{
    import flint.core : ResolvableType;
    import flint.jackson.databind : SerializationFeature;

    private class PrettyPrintBean
    {
        private string name;

        string getName()
        {
            return name;
        }

        void setName(string name)
        {
            this.name = name;
        }
    }

    @("JacksonJsonHttpMessageConverterTests.prettyPrint")
    unittest
    {
        import std.array : replace;

        auto outputMessage = new MockHttpOutputMessage();
        auto bean = new PrettyPrintBean();
        bean.setName("Jason");

        auto mapper = mapperBuilder().enable(SerializationFeature.INDENT_OUTPUT).build();
        auto converter = new JacksonJsonHttpMessageConverter(mapper);
        converter.write(Any.of(bean), ResolvableType.forType(typeNameOf!PrettyPrintBean),
                &MediaType.APPLICATION_JSON, outputMessage, null);
        const result = outputMessage.getBodyAsString(StandardCharsets.UTF_8);

        assert(result.replace("\r\n", "\n") == "{\n  \"name\" : \"Jason\"\n}");
    }

    @("JacksonJsonHttpMessageConverterTests.prettyPrintWithSse")
    unittest
    {
        auto outputMessage = new MockHttpOutputMessage();
        outputMessage.getHeaders().setContentType(MediaType.TEXT_EVENT_STREAM);
        auto bean = new PrettyPrintBean();
        bean.setName("Jason");

        auto mapper = mapperBuilder().enable(SerializationFeature.INDENT_OUTPUT).build();
        auto converter = new JacksonJsonHttpMessageConverter(mapper);
        converter.write(Any.of(bean), ResolvableType.forType(typeNameOf!PrettyPrintBean),
                &MediaType.APPLICATION_JSON, outputMessage, null);
        const result = outputMessage.getBodyAsString(StandardCharsets.UTF_8);

        assert(result == "{\ndata:   \"name\" : \"Jason\"\ndata: }");
    }
}

// flint.http's JacksonJsonHttpMessageConverter has no setPrefixJson/setJsonPrefix.
version (FlintJacksonJsonPrefix)
{
    import flint.core : ResolvableType;

    @("JacksonJsonHttpMessageConverterTests.prefixJson")
    unittest
    {
        auto converter = newConverter();
        auto outputMessage = new MockHttpOutputMessage();
        converter.setPrefixJson(true);
        converter.write(Any.of("foo"), ResolvableType.forType(typeNameOf!string),
                &MediaType.APPLICATION_JSON, outputMessage, null);

        assert(outputMessage.getBodyAsString(StandardCharsets.UTF_8) == ")]}', \"foo\"");
    }

    @("JacksonJsonHttpMessageConverterTests.prefixJsonCustom")
    unittest
    {
        auto converter = newConverter();
        auto outputMessage = new MockHttpOutputMessage();
        converter.setJsonPrefix(")))");
        converter.write(Any.of("foo"), ResolvableType.forType(typeNameOf!string),
                &MediaType.APPLICATION_JSON, outputMessage, null);

        assert(outputMessage.getBodyAsString(StandardCharsets.UTF_8) == ")))\"foo\"");
    }
}

// flint.jackson has no @JsonView, and flint.http's converters take no serialization hints.
version (FlintJacksonJsonView)
{
    import flint.core : ResolvableType;
    import flint.jackson.annotation : JsonView;
    import flint.java.lang : classOf;

    private interface MyJacksonView1
    {
    }

    private interface MyJacksonView2
    {
    }

    private interface MyJacksonView3
    {
    }

    @JsonView([classOf!MyJacksonView3])
    private class JacksonViewBean
    {
        @JsonView([classOf!MyJacksonView1]) private string withView1;
        @JsonView([classOf!MyJacksonView2]) private string withView2;
        private string withoutView;

        string getWithView1()
        {
            return withView1;
        }

        void setWithView1(string withView1)
        {
            this.withView1 = withView1;
        }

        string getWithView2()
        {
            return withView2;
        }

        void setWithView2(string withView2)
        {
            this.withView2 = withView2;
        }

        string getWithoutView()
        {
            return withoutView;
        }

        void setWithoutView(string withoutView)
        {
            this.withoutView = withoutView;
        }
    }

    @("JacksonJsonHttpMessageConverterTests.fieldLevelJsonView")
    unittest
    {
        auto converter = newConverter();
        auto outputMessage = new MockHttpOutputMessage();
        auto bean = new JacksonViewBean();
        bean.setWithView1("with");
        bean.setWithView2("with");
        bean.setWithoutView("without");

        const Any[string] hints = [typeNameOf!JsonView: Any.of(typeNameOf!MyJacksonView1)];
        converter.write(Any.of(bean), ResolvableType.forType(typeNameOf!JacksonViewBean),
                &MediaType.APPLICATION_JSON, outputMessage, hints);

        const result = outputMessage.getBodyAsString(StandardCharsets.UTF_8);
        assert(result.canFind("\"withView1\":\"with\""));
        assert(!result.canFind("\"withView2\":\"with\""));
        assert(!result.canFind("\"withoutView\":\"without\""));
    }

    @("JacksonJsonHttpMessageConverterTests.classLevelJsonView")
    unittest
    {
        auto converter = newConverter();
        auto outputMessage = new MockHttpOutputMessage();
        auto bean = new JacksonViewBean();
        bean.setWithView1("with");
        bean.setWithView2("with");
        bean.setWithoutView("without");

        const Any[string] hints = [typeNameOf!JsonView: Any.of(typeNameOf!MyJacksonView3)];
        converter.write(Any.of(bean), ResolvableType.forType(typeNameOf!JacksonViewBean),
                &MediaType.APPLICATION_JSON, outputMessage, hints);

        const result = outputMessage.getBodyAsString(StandardCharsets.UTF_8);
        assert(!result.canFind("\"withView1\":\"with\""));
        assert(!result.canFind("\"withView2\":\"with\""));
        assert(result.canFind("\"withoutView\":\"without\""));
    }
}

// flint.jackson has no FilterProvider/SimpleBeanPropertyFilter, and flint.http's converters take no hints.
version (FlintJacksonFilters)
{
    import flint.core : ResolvableType;
    import flint.jackson.annotation : JsonFilter;
    import flint.jackson.databind.ser : FilterProvider, SimpleBeanPropertyFilter, SimpleFilterProvider;

    @JsonFilter("myJacksonFilter")
    private class JacksonFilteredBean
    {
        private string property1;
        private string property2;

        string getProperty1()
        {
            return property1;
        }

        void setProperty1(string property1)
        {
            this.property1 = property1;
        }

        string getProperty2()
        {
            return property2;
        }

        void setProperty2(string property2)
        {
            this.property2 = property2;
        }
    }

    @("JacksonJsonHttpMessageConverterTests.filters")
    unittest
    {
        auto converter = newConverter();
        auto outputMessage = new MockHttpOutputMessage();
        auto bean = new JacksonFilteredBean();
        bean.setProperty1("value");
        bean.setProperty2("value");

        FilterProvider filters = new SimpleFilterProvider().addFilter("myJacksonFilter",
                SimpleBeanPropertyFilter.serializeAllExcept("property2"));
        const Any[string] hints = [typeNameOf!FilterProvider: Any.of(filters)];
        converter.write(Any.of(bean), ResolvableType.forType(typeNameOf!JacksonFilteredBean),
                &MediaType.APPLICATION_JSON, outputMessage, hints);

        const result = outputMessage.getBodyAsString(StandardCharsets.UTF_8);
        assert(result.canFind("\"property1\":\"value\""));
        assert(!result.canFind("\"property2\":\"value\""));
    }
}

// The converter has no customizeReader/customizeWriter hooks, flint.jackson no ObjectReader.
version (FlintJacksonCustomizers)
{
    import flint.jackson.databind : EnumFeature, ObjectReader, ObjectWriter;

    private class MyCustomizedBean
    {
        private MyCustomEnum property;

        MyCustomEnum getProperty()
        {
            return property;
        }

        void setProperty(MyCustomEnum property)
        {
            this.property = property;
        }
    }

    private enum MyCustomEnum
    {
        VAL1, // Java overrides toString(): "Value1"; a D enum has no toString of its own
        VAL2, // toString(): "Value2"
    }

    private class JacksonJsonHttpMessageConverterWithCustomization : JacksonJsonHttpMessageConverter
    {
        this()
        {
            super(mapperBuilder().build());
        }

        protected override ObjectReader customizeReader(ObjectReader reader, string javaType)
        {
            return reader.without(EnumFeature.READ_ENUMS_USING_TO_STRING);
        }

        protected override ObjectWriter customizeWriter(ObjectWriter writer, string javaType,
                scope const(MediaType)* contentType)
        {
            return writer.without(EnumFeature.WRITE_ENUMS_USING_TO_STRING);
        }
    }

    @("JacksonJsonHttpMessageConverterTests.readWithCustomized")
    unittest
    {
        auto converter = newConverter();
        auto customizedConverter = new JacksonJsonHttpMessageConverterWithCustomization();
        const json = "{\"property\":\"Value1\"}";
        auto inputMessage1 = new MockHttpInputMessage(cast(const(ubyte)[]) json);
        auto inputMessage2 = new MockHttpInputMessage(cast(const(ubyte)[]) json);
        inputMessage1.getHeaders().setContentType(MediaType("application", "json"));
        inputMessage2.getHeaders().setContentType(MediaType("application", "json"));

        assertThrown!HttpMessageNotReadableException(customizedConverter.read(typeNameOf!MyCustomizedBean,
                inputMessage1));

        auto customizedResult = converter.read(typeNameOf!MyCustomizedBean, inputMessage2).get!MyCustomizedBean;
        assert(customizedResult.getProperty() == MyCustomEnum.VAL1);
    }

    @("JacksonJsonHttpMessageConverterTests.writeWithCustomized")
    unittest
    {
        auto converter = newConverter();
        auto customizedConverter = new JacksonJsonHttpMessageConverterWithCustomization();
        auto outputMessage1 = new MockHttpOutputMessage();
        auto outputMessage2 = new MockHttpOutputMessage();
        auto bean = new MyCustomizedBean();
        bean.setProperty(MyCustomEnum.VAL2);
        converter.write(Any.of(bean), null, outputMessage1);
        customizedConverter.write(Any.of(bean), null, outputMessage2);
        const result1 = outputMessage1.getBodyAsString(StandardCharsets.UTF_8);
        assert(result1.canFind("\"property\":\"Value2\""));
        const result2 = outputMessage2.getBodyAsString(StandardCharsets.UTF_8);
        assert(result2.canFind("\"property\":\"VAL2\""));
    }
}
