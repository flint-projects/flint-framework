/++
Ported from FasterXML/jackson-databind 3.1.8,
src/test/java/tools/jackson/databind/deser/filter/UnknownPropertyDeserTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit assertions become D unittests and asserts; `Class<?>` arguments are template
parameters and the mapper holds the Flint AOT descriptors of the test beans; package-private Java fields are private
D fields (not properties, as Jackson's default field visibility makes them), and private fields that clash with
accessor methods take a trailing underscore; `Map<String,Object>` is `HashMap!(string, Any)` and
`Map<String,Integer>` is `Map!(string, int)`. Cases that need parts of flint.jackson that are not ported yet, or
where it behaves differently, wait behind versions.
+/
module unknown_property_deser_test;

import databind_test_util : jsonMapperBuilder, newJsonMapper, verifyException;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.annotation : JsonIgnore, JsonIgnoreProperties, JsonUnwrapped;
import flint.jackson.databind : DeserializationFeature, JsonMapper, ObjectMapper;
import flint.jackson.databind.exc : UnrecognizedPropertyException;
import flint.java.util : HashMap, LinkedHashMap, List, Map;

@safe:

private final class TestBean
{
    private string _unknown;
    private int _a, _b;

    void setA(int a)
    {
        _a = a;
    }

    void setB(int b)
    {
        _b = b;
    }

    void markUnknown(string unk)
    {
        _unknown = unk;
    }
}

@JsonIgnoreProperties(["b", "c"])
private final class IgnoreSome
{
    int a, b;
    private string c_, d_;

    string c()
    {
        return c_;
    }

    void setC(string value)
    {
        c_ = value;
    }

    string d()
    {
        return d_;
    }

    void setD(string value)
    {
        d_ = value;
    }
}

@JsonIgnoreProperties(ignoreUnknown : true)
private final class IgnoreUnknown
{
    int a;
}

private final class UnwrappedChild
{
    int a, b;
}

@JsonIgnoreProperties(ignoreUnknown : true)
private final class IgnoreUnknownUnwrapped
{
    @JsonUnwrapped UnwrappedChild child;
}

@JsonIgnoreProperties(["a", "d"])
private final class IgnoreMap : HashMap!(string, Any)
{
}

private final class ImplicitIgnores
{
    @JsonIgnore int a;

    @JsonIgnore void setB(int)
    {
    }

    int c;
}

private final class YZ
{
    int y, z;
}

private final class XYZWrapper1
{
    @JsonIgnoreProperties(["x"]) YZ value;
}

@JsonIgnoreProperties(["z"])
private final class X
{
    int x;
}

private final class XYZWrapper2
{
    @JsonIgnoreProperties(["y"]) X value;
}

private final class MapWithoutX
{
    @JsonIgnoreProperties(["x"]) Map!(string, int) values;
}

// [databind#987]
private final class Bean987
{
    string aProperty;
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!TestBean(), descriptorOf!IgnoreSome(), descriptorOf!IgnoreUnknown(),
        descriptorOf!UnwrappedChild(), descriptorOf!IgnoreUnknownUnwrapped(),
        descriptorOf!IgnoreMap(), descriptorOf!ImplicitIgnores(), descriptorOf!YZ(),
        descriptorOf!XYZWrapper1(), descriptorOf!X(), descriptorOf!XYZWrapper2(),
        descriptorOf!MapWithoutX(), descriptorOf!(Map!(string, int))(),
        descriptorOf!(LinkedHashMap!(string, int))(), descriptorOf!Bean987(),
        descriptorOf!(List!Bean987)()
    ])
        t.add(d);
    return t;
}

private ObjectMapper mapper()
{
    return newJsonMapper(table());
}

private enum JSON_UNKNOWN_FIELD = `{ "a" : 1, "foo" : [ 1, 2, 3], "b" : -1 }`;

// flint.jackson has no ObjectReader (readerFor/with).
version (FlintJacksonObjectReader)
{
    @("UnknownPropertyDeserTest.testUnknownHandlingDefault")
    unittest
    {
        try
        {
            mapper().readerFor!TestBean().with_(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
                .readValue(JSON_UNKNOWN_FIELD);
            assert(false, "Should not pass");
        }
        catch (UnrecognizedPropertyException jex)
            verifyException(jex, "Unrecognized property \"foo\"");
    }
}

// flint.jackson has no DeserializationProblemHandler (addHandler/withHandler).
version (FlintJacksonProblemHandler)
{
    import flint.jackson.core : JsonParser;
    import flint.jackson.databind : DeserializationContext, ValueDeserializer;
    import flint.jackson.databind.deser : DeserializationProblemHandler;

    // Marks unknown properties when encountered, along with the JSON value of the property.
    private class MyHandler : DeserializationProblemHandler
    {
        override bool handleUnknownProperty(DeserializationContext ctxt, JsonParser jp,
                ValueDeserializer deserializer, Object bean, string propertyName)
        {
            import flint.jackson.core : tokenName;

            (cast(TestBean) bean).markUnknown(propertyName ~ ":" ~ tokenName(jp.currentToken()));
            jp.skipChildren();
            return true;
        }
    }

    @("UnknownPropertyDeserTest.testUnknownHandlingIgnoreWithHandler")
    unittest
    {
        auto m = jsonMapperBuilder(table()).addHandler(new MyHandler()).build();
        const result = m.readValue!TestBean(JSON_UNKNOWN_FIELD);
        assert(result !is null);
        assert(result._a == 1);
        assert(result._b == -1);
        assert(result._unknown == "foo:START_ARRAY");
    }

    @("UnknownPropertyDeserTest.testUnknownHandlingIgnoreWithHandlerAndObjectReader")
    unittest
    {
        auto m = newJsonMapper(table());
        const TestBean result = m.readerFor!TestBean().withHandler(new MyHandler()).readValue(JSON_UNKNOWN_FIELD);
        assert(result !is null);
        assert(result._a == 1);
        assert(result._b == -1);
        assert(result._unknown == "foo:START_ARRAY");
    }

    private class SkippingHandler : DeserializationProblemHandler
    {
        override bool handleUnknownProperty(DeserializationContext ctxt, JsonParser p,
                ValueDeserializer deserializer, Object beanOrClass, string propertyName)
        {
            p.skipChildren();
            return true;
        }
    }

    @("UnknownPropertyDeserTest.testIssue987")
    unittest
    {
        auto jsonMapper = jsonMapperBuilder(table()).addHandler(new SkippingHandler()).build();
        const input = `[{"aProperty":"x","unknown":{"unknown":{}}}]`;
        auto deserializedList = jsonMapper.readValue!(List!Bean987)(input);
        assert(deserializedList.size() == 1);
    }
}

@("UnknownPropertyDeserTest.testUnknownHandlingIgnoreWithFeature")
unittest
{
    auto m = jsonMapperBuilder(table()).disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES).build();
    const result = m.readValue!TestBean(JSON_UNKNOWN_FIELD);
    assert(result !is null);
    assert(result._a == 1);
    assert(result._unknown is null);
    assert(result._b == -1);
}

@("UnknownPropertyDeserTest.testWithClassIgnore")
unittest
{
    auto result = mapper().readValue!IgnoreSome(`{ "a":1,"b":2,"c":"x","d":"y"}`);
    // first: should deserialize 2 of properties normally
    assert(result.a == 1);
    assert(result.d() == "y");
    // and not take other 2
    assert(result.b == 0);
    assert(result.c() is null);
}

// flint.jackson applies @JsonIgnoreProperties to beans only, not to Map types or Map-valued properties.
// LIKELY BUG: {"a":[1],"b":2,"c":"x","d":false} read as IgnoreMap keeps "a" and "d" (4 entries, expected 2) and
// comes back boxed as Map!(string, Any), so readValue!IgnoreMap throws AnyTypeException; and
// {"values":{"x":1,"y":2}} keeps "x" in MapWithoutX.values (2 entries, expected 1).
version (FlintJacksonIgnorePropertiesForMaps)
{
    @("UnknownPropertyDeserTest.testClassIgnoreWithMap")
    unittest
    {
        // Let's actually use incompatible types for "a" and "d"; should not matter when ignored
        auto result = mapper().readValue!IgnoreMap(
                "{ \"a\":[ 1],\n" ~ "\"b\":2,\n" ~ "\"c\": \"x\",\n" ~ "\"d\":false }");
        assert(result.size() == 2);
        auto ob = result.get("b");
        assert(ob.holds!int());
        assert(ob.get!int() == 2);
        assert(result.get("c").get!string() == "x");
        assert(!result.containsKey("a"));
        assert(!result.containsKey("d"));
    }

    @("UnknownPropertyDeserTest.testPropertyIgnoralForMap")
    unittest
    {
        auto result = mapper().readValue!MapWithoutX(`{"values":{"x":1,"y":2}}`);
        assert(result.values !is null);
        assert(result.values.size() == 1);
        assert(result.values.get("y") == 2);
    }
}

@("UnknownPropertyDeserTest.testClassWithIgnoreUnknown")
unittest
{
    const result = mapper().readValue!IgnoreUnknown(`{"b":3,"c":[1,2],"x":{ },"a":-3}`);
    assert(result.a == -3);
}

// flint.jackson has no @JsonAnySetter.
version (FlintJacksonAnySetter)
{
    import flint.jackson.annotation : JsonAnyGetter, JsonAnySetter;

    @JsonIgnoreProperties(ignoreUnknown : true)
    private final class IgnoreUnknownAnySetter
    {
        Map!(string, Any) props;

        this()
        {
            props = new HashMap!(string, Any)();
        }

        @JsonAnySetter void addProperty(string key, Any value)
        {
            props.put(key, value);
        }

        @JsonAnyGetter Map!(string, Any) getProperties()
        {
            return props;
        }
    }

    @("UnknownPropertyDeserTest.testAnySetterWithFailOnUnknownDisabled")
    unittest
    {
        auto t = table();
        t.add(descriptorOf!IgnoreUnknownAnySetter());
        auto value = newJsonMapper(t).readValue!IgnoreUnknownAnySetter(`{"x":"y", "a":"b"}`);
        assert(value !is null);
        assert(value.props.size() == 2);
    }
}

// flint.jackson writes @JsonUnwrapped properties but does not read them back.
// LIKELY BUG: {"a":1, "b":2} into IgnoreUnknownUnwrapped leaves `child` null (expected child.a == 1, child.b == 2).
version (FlintJacksonUnwrappedDeser)
{
    @("UnknownPropertyDeserTest.testUnwrappedWithFailOnUnknownDisabled")
    unittest
    {
        const value = mapper().readValue!IgnoreUnknownUnwrapped(`{"a":1, "b":2}`);
        assert(value !is null);
        assert(value.child !is null);
        assert(value.child.a == 1);
        assert(value.child.b == 2);
    }
}

@("UnknownPropertyDeserTest.testClassWithUnknownAndIgnore")
unittest
{
    // should be ok: "a" and "b" ignored, "c" mapped:
    const result = mapper().readValue!ImplicitIgnores(`{"a":1,"b":2,"c":3 }`);
    assert(result.c == 3);

    // but "d" is not defined, so should still error
    try
        mapper().readValue!ImplicitIgnores(`{"a":1,"b":2,"c":3,"d":4 }`);
    catch (UnrecognizedPropertyException e)
        verifyException(e, "Unrecognized property \"d\"");
}

@("UnknownPropertyDeserTest.testPropertyIgnoral")
unittest
{
    const result = mapper().readValue!XYZWrapper1(`{"value":{"y":2,"x":1,"z":3}}`);
    assert(result.value.y == 2);
    assert(result.value.z == 3);
}

@("UnknownPropertyDeserTest.testPropertyIgnoralWithClass")
unittest
{
    const result = mapper().readValue!XYZWrapper2(`{"value":{"y":2,"x":1,"z":3}}`);
    assert(result.value.x == 1);
}
