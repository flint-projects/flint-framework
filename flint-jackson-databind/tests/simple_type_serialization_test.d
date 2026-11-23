/++
Ported from FasterXML/jackson-databind 3.1.8, src/test/java/tools/jackson/databind/ser/SimpleTypeSerializationTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit assertions become D asserts; beans are described by `descriptorOf!T`, and the
descriptors Flint AOT emits beyond it (inherited fields, an annotated protected field) are built by hand;
`writeAndMap` reads into a `LinkedHashMap!(string, Any)`, whose nested objects and arrays are tree nodes
(flint.jackson's UntypedObjectDeserializer builds those where Jackson builds a `LinkedHashMap` or `ArrayList`);
`Boolean[]`/`Byte[]` are arrays of `Nullable`; `ObjectMapper.createParser` is the mapper's
`tokenStreamFactory().createParser`, whose end of input is `JsonToken.NOT_AVAILABLE` where Jackson returns null;
the 40000-character string skips the UTF-16 surrogate range, which a D string cannot hold; a Java `transient`
field is a private one (D has no `transient`); `TokenStreamLocation` has no `ContentReference` in Flint.
Cases that need parts of flint.jackson that are not ported yet wait behind versions.
+/
module simple_type_serialization_test;

import databind_test_util : a2q, assertThrows, jsonMapperBuilder, newJsonMapper, q, verifyException;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, DescriptorTable, PropertyDescriptor, descriptorOf, mergedAnnotations;
import flint.engine.aot.name : typeNameOf;
import flint.jackson.annotation : JsonAutoDetect, JsonFormat, JsonIgnore, JsonInclude,
    JsonProperty, JsonPropertyOrder;
import flint.jackson.core : JsonParser, JsonToken, TokenStreamLocation;
import flint.jackson.databind : JsonMapper, ObjectMapper, ObjectWriter, SerializationFeature;
import flint.jackson.databind.exc : InvalidDefinitionException;
import flint.jackson.databind.node : JsonNode;
import flint.java.util : LinkedHashMap, Map;
import std.typecons : Nullable;

@safe:

// Helper classes: field serialization

private class SimpleFieldBean
{
    int x, y;

    // not auto-detectable, not public
    package int z;

    // ignored, not detectable either
    @JsonIgnore int a;
}

private final class TransientBean
{
    int a;
    // transients should not be included
    private int b;
    // or statics
    static int c;
}

private final class OkDupFieldBean : SimpleFieldBean
{
    @JsonProperty("x") protected int myX;

    int y;

    this(int x, int y)
    {
        this.myX = x;
        this.y = y;
    }
}

/// Flint AOT's descriptor of OkDupFieldBean: its own `y` and the annotated protected `myX`, then the inherited `x`
/// and `a` (the base's `y` is hidden).
private Descriptor okDupFieldBeanDescriptor()
{
    auto d = descriptorOf!OkDupFieldBean();
    d.properties ~= PropertyDescriptor("myX", "int", mergedAnnotations!(JsonProperty("x"))(),
            (ref Any self) => Any.of(self.get!OkDupFieldBean().myX), null);
    foreach (ref p; descriptorOf!SimpleFieldBean().properties)
        if (p.name != "y")
            d.properties ~= p;
    return d;
}

/**
 * It is ok to have a method-based and field-based property
 * introspectable: only one should be serialized, and since
 * methods have precedence, it should be the method one.
 */
private final class FieldAndMethodBean
{
    @JsonProperty int z;

    @JsonProperty("z") int getZ()
    {
        return z + 1;
    }
}

private final class DupFieldBean2
{
    int z = 3;

    @JsonProperty("z") int _z = 4;
}

// Helper classes: auto-detect configuration

private class FieldBean
{
    string p1 = "public";
    protected string p2 = "protected";
    private string p3 = "private";
}

private class MethodBean
{
    string getA()
    {
        return "a";
    }

    protected string getB()
    {
        return "b";
    }

    private string getC()
    {
        return "c";
    }
}

private final class FieldBeanWithStatic
{
    int x = 1;

    static int y = 2;

    // not even @JsonProperty should make statics usable...
    @JsonProperty static int z = 3;
}

private final class GetterBeanWithStatic
{
    int getX()
    {
        return 3;
    }

    static int getA()
    {
        return -3;
    }

    // not even @JsonProperty should make statics usable...
    @JsonProperty static int getFoo()
    {
        return 123;
    }
}

// Helper classes: cyclic type handling

private final class CyclicBean
{
    private CyclicBean _next;
    private const string _name;

    this(CyclicBean next, string name)
    {
        _next = next;
        _name = name;
    }

    CyclicBean getNext()
    {
        return _next;
    }

    string getName()
    {
        return _name;
    }

    void assignNext(CyclicBean n)
    {
        _next = n;
    }
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!SimpleFieldBean(), descriptorOf!TransientBean(), okDupFieldBeanDescriptor(),
        descriptorOf!FieldAndMethodBean(), descriptorOf!DupFieldBean2(), descriptorOf!FieldBean(),
        descriptorOf!MethodBean(), descriptorOf!FieldBeanWithStatic(),
        descriptorOf!GetterBeanWithStatic(), descriptorOf!CyclicBean(),
        descriptorOf!(CyclicBean[])(), descriptorOf!TokenStreamLocation(),
        descriptorOf!(bool[])(), descriptorOf!(Nullable!bool)(),
        descriptorOf!(Nullable!bool[])(), descriptorOf!(byte[])(),
        descriptorOf!(Nullable!byte)(), descriptorOf!(Nullable!byte[])(),
        descriptorOf!(int[])(), descriptorOf!(long[])(), descriptorOf!(string[])(),
        descriptorOf!(double[])(), descriptorOf!(float[])(), descriptorOf!(Map!(string, Any))(),
        descriptorOf!(LinkedHashMap!(string, Any))()
    ])
        t.add(d);
    return t;
}

private JsonMapper mapper()
{
    return newJsonMapper(table());
}

// DatabindTestUtil.writeAndMap.
private Map!(string, Any) writeAndMap(T)(ObjectMapper m, T value)
{
    const str = m.writeValueAsString(value);
    return m.readValue!(LinkedHashMap!(string, Any))(str);
}

private int intOf(Any value)
{
    return cast(int) value.get!long();
}

// Test methods, simple types

@("SimpleTypeSerializationTest.testBoolean")
unittest
{
    auto m = mapper();
    assert(m.writeValueAsString(true) == "true");
    assert(m.writeValueAsString(false) == "false");
}

@("SimpleTypeSerializationTest.testBooleanArray")
unittest
{
    auto m = mapper();
    assert(m.writeValueAsString([true, false]) == "[true,false]");
    assert(m.writeValueAsString([Nullable!bool(true), Nullable!bool(false)]) == "[true,false]");
}

@("SimpleTypeSerializationTest.testByteArray")
unittest
{
    auto m = mapper();
    const byte[] data = [1, 17, -3, 127, -128];
    auto data2 = new Nullable!byte[data.length];
    foreach (i, b; data)
        data2[i] = b; // auto-boxing
    // For this we need to deserialize, to get base64 codec
    const str1 = m.writeValueAsString(data.dup);
    const str2 = m.writeValueAsString(data2);
    assert(m.readValue!(byte[])(str1) == data);
    assert(m.readValue!(Nullable!byte[])(str2) == data2);
}

// ObjectMapper.writer(Base64Variant) and the Base64 variants are not ported.
version (FlintJacksonObjectWriterConfig)
{
    // as per [Issue#42], allow Base64 variant use as well
    @("SimpleTypeSerializationTest.testBase64Variants")
    unittest
    {
        import flint.jackson.core : Base64Variants;

        auto m = mapper();
        const input = cast(byte[]) "abcdefghijklmnopqrstuvwxyz1234567890abcdefghijklmnopqrstuvwxyz1234567890X".dup;

        // default encoding is "MIME, no linefeeds", so:
        enum noLinefeeds = "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkwYWJjZGVmZ2hpamtsbW5vcHFyc3R1"
            ~ "dnd4eXoxMjM0NTY3ODkwWA==";
        assert(m.writeValueAsString(input) == q(noLinefeeds));
        assert(m.writer(Base64Variants.MIME_NO_LINEFEEDS).writeValueAsString(input) == q(noLinefeeds));

        // but others should be slightly different
        assert(m.writer(Base64Variants.MIME).writeValueAsString(input) == q(
                "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkwYWJjZGVmZ2hpamtsbW5vcHFyc3R1"
                ~ "\\ndnd4eXoxMjM0NTY3ODkwWA=="));
        assert(m.writer(Base64Variants.MODIFIED_FOR_URL).writeValueAsString(input) == q(
                "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkwYWJjZGVmZ2hpamtsbW5vcHFyc3R1"
                ~ "dnd4eXoxMjM0NTY3ODkwWA")); // no padding or LF
        // PEM mandates 64 char lines:
        assert(m.writer(Base64Variants.PEM)
                .writeValueAsString(input) == q("YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkwYWJjZGVmZ2hpamts"
                ~ "\\nbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkwWA=="));
    }
}

// flint.jackson has no serializer for `Class` values (ClassRef).
version (FlintJacksonClassValues)
{
    @("SimpleTypeSerializationTest.testClass")
    unittest
    {
        import flint.java.lang : classOf;
        import flint.java.util : List;

        const result = mapper().writeValueAsString(classOf!(List!string));
        assert(result == "\"java.util.List\"", result);
    }
}

// Test methods, array types

@("SimpleTypeSerializationTest.testLongStringArray")
unittest
{
    enum SIZE = 40_000;

    auto m = mapper();
    dchar[] sb;
    sb.reserve(SIZE);
    foreach (i; 0 .. SIZE)
        if (i < 0xD800 || i > 0xDFFF)
            sb ~= cast(dchar) i;
    import std.conv : to;

    const str = sb.to!string;
    const data = m.writeValueAsBytes!(string[])(["abc", str, null, str]);
    auto p = m.tokenStreamFactory().createParser(data);
    assert(p.nextToken() == JsonToken.START_ARRAY);
    assert(p.nextToken() == JsonToken.VALUE_STRING);
    assert(p.getString() == "abc");
    assert(p.nextToken() == JsonToken.VALUE_STRING);
    const actual = p.getString();
    assert(str.length == actual.length);
    assert(str == actual);
    assert(p.nextToken() == JsonToken.VALUE_NULL);
    assert(p.nextToken() == JsonToken.VALUE_STRING);
    assert(p.getString() == str);
    assert(p.nextToken() == JsonToken.END_ARRAY);
    assert(p.nextToken() == JsonToken.NOT_AVAILABLE);
    p.close();
}

@("SimpleTypeSerializationTest.testIntArray")
unittest
{
    const json = mapper().writeValueAsString([1, 2, 3, -7]);
    assert(json == "[1,2,3,-7]", json);
}

@("SimpleTypeSerializationTest.testBigIntArray")
unittest
{
    enum SIZE = 99_999;
    auto m = mapper();
    auto ints = new int[SIZE];
    foreach (i, ref v; ints)
        v = cast(int) i;

    // Let's try couple of times, to ensure that state is handled
    // correctly by ObjectMapper (wrt buffer recycling used
    // with 'writeAsBytes()')
    foreach (round; 0 .. 3)
    {
        const data = m.writeValueAsBytes(ints);
        auto p = m.tokenStreamFactory().createParser(data);
        assert(p.nextToken() == JsonToken.START_ARRAY);
        foreach (i; 0 .. SIZE)
        {
            assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
            assert(p.getIntValue() == i);
        }
        assert(p.nextToken() == JsonToken.END_ARRAY);
        p.close();
    }
}

@("SimpleTypeSerializationTest.testLongArray")
unittest
{
    const json = mapper().writeValueAsString([long.min, 0, long.max]);
    assert(json == "[-9223372036854775808,0,9223372036854775807]", json);
}

@("SimpleTypeSerializationTest.testStringArray")
unittest
{
    auto m = mapper();
    assert(m.writeValueAsString(["a", "\"foo\"", null]) == `["a","\"foo\"",null]`);
    assert(m.writeValueAsString(cast(string[])[]) == "[]");
}

@("SimpleTypeSerializationTest.testDoubleArray")
unittest
{
    const json = mapper().writeValueAsString([
        1.01, 2.0, -7, double.nan, -double.infinity, double.infinity
    ]);
    assert(json == `[1.01,2.0,-7.0,"NaN","-Infinity","Infinity"]`, json);
}

@("SimpleTypeSerializationTest.testFloatArray")
unittest
{
    const json = mapper().writeValueAsString([
        1.01f, 2.0f, -7f, float.nan, -float.infinity, float.infinity
    ]);
    assert(json == `[1.01,2.0,-7.0,"NaN","-Infinity","Infinity"]`, json);
}

// Test methods, Jackson types

@("SimpleTypeSerializationTest.testLocation")
unittest
{
    auto m = mapper();
    auto loc = new TokenStreamLocation(-1, -1, 100, 13);
    auto result = writeAndMap(m, loc);
    assert(intOf(result.get("charOffset")) == -1);
    assert(intOf(result.get("byteOffset")) == -1);
    assert(intOf(result.get("lineNr")) == 100);
    assert(intOf(result.get("columnNr")) == 13);
    assert(result.size() == 4);
}

// flint.jackson has no TokenBuffer.
version (FlintJacksonTokenBuffer)
{
    // DatabindTestUtil.SAMPLE_DOC_JSON_SPEC and verifyJsonSpecSampleDoc, as far as this test reads them.
    private enum SAMPLE_DOC_JSON_SPEC = `{
  "Image" : {
    "Width" : 800,
    "Height" : 600,
    "Title" : "View from 15th Floor",
    "Thumbnail" : {
      "Url" : "http://www.example.com/image/481989943",
      "Height" : 125,
      "Width" : "100"
    },
    "IDs" : [116, 943, 234, 38793]
  }
}`;

    private void verifyJsonSpecSampleDoc(JsonParser p)
    {
        assert(p.nextToken() == JsonToken.START_OBJECT);
        assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.getString() == "Image");
        assert(p.nextToken() == JsonToken.START_OBJECT);
        assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.getString() == "Width");
        assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT && p.getIntValue() == 800);
        assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.getString() == "Height");
        assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT && p.getIntValue() == 600);
        assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.getString() == "Title");
        assert(p.nextToken() == JsonToken.VALUE_STRING && p.getString() == "View from 15th Floor");
        assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.getString() == "Thumbnail");
        assert(p.nextToken() == JsonToken.START_OBJECT);
        assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.getString() == "Url");
        assert(p.nextToken() == JsonToken.VALUE_STRING && p.getString() == "http://www.example.com/image/481989943");
        assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.getString() == "Height");
        assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT && p.getIntValue() == 125);
        assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.getString() == "Width");
        assert(p.nextToken() == JsonToken.VALUE_STRING && p.getString() == "100");
        assert(p.nextToken() == JsonToken.END_OBJECT);
        assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.getString() == "IDs");
        assert(p.nextToken() == JsonToken.START_ARRAY);
        foreach (id; [116, 943, 234, 38_793])
            assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT && p.getIntValue() == id);
        assert(p.nextToken() == JsonToken.END_ARRAY);
        assert(p.nextToken() == JsonToken.END_OBJECT);
        assert(p.nextToken() == JsonToken.END_OBJECT);
        assert(p.nextToken() == JsonToken.NOT_AVAILABLE);
    }

    /**
     * Verify that {@link TokenBuffer} can be properly serialized
     * automatically, using the "standard" JSON sample document
     */
    @("SimpleTypeSerializationTest.testTokenBuffer")
    unittest
    {
        import flint.jackson.databind.util : TokenBuffer;

        auto m = mapper();
        // First, copy events from known good source (StringReader)
        auto p = m.tokenStreamFactory().createParser(SAMPLE_DOC_JSON_SPEC);
        auto tb = TokenBuffer.forGeneration();
        while (p.nextToken() != JsonToken.NOT_AVAILABLE)
            tb.copyCurrentEvent(p);
        p.close();
        // Then serialize as String
        const str = m.writeValueAsString(tb);
        tb.close();
        // and verify it looks ok
        verifyJsonSpecSampleDoc(m.tokenStreamFactory().createParser(str));
    }
}

// Test methods, field serialization

@("SimpleTypeSerializationTest.testSimpleAutoDetect")
unittest
{
    auto bean = new SimpleFieldBean();
    // let's set x, leave y as is
    bean.x = 13;
    auto result = writeAndMap(mapper(), bean);
    assert(result.size() == 2);
    assert(intOf(result.get("x")) == 13);
    assert(intOf(result.get("y")) == 0);
}

// flint.jackson has no @JsonSerialize/@JsonDeserialize.
version (FlintJacksonCustomSerializers)
{
    private final class SimpleFieldBean2
    {
        @JsonSerialize private string[] values;

        // note: this annotation should not matter for serialization:
        @JsonDeserialize private int dummy;
    }

    @("SimpleTypeSerializationTest.testSimpleAnnotation")
    unittest
    {
        auto bean = new SimpleFieldBean2();
        bean.values = ["a", "b"];
        auto result = writeAndMap(mapper(), bean);
        assert(result.size() == 1);
        auto values = result.get("values").get!JsonNode();
        assert(values.size() == 2);
        assert(values.get(0).stringValue() == "a");
        assert(values.get(1).stringValue() == "b");
    }
}

@("SimpleTypeSerializationTest.testTransientAndStatic")
unittest
{
    auto bean = new TransientBean();
    auto result = writeAndMap(mapper(), bean);
    assert(result.size() == 1);
    assert(intOf(result.get("a")) == 0);
}

// flint.jackson ignores @JsonAutoDetect and the default visibility settings.
version (FlintJacksonAutoDetect)
{
    @JsonAutoDetect(setterVisibility : JsonAutoDetect.Visibility.PUBLIC_ONLY, fieldVisibility:
            JsonAutoDetect.Visibility.NONE)
    private final class NoAutoDetectBean
    {
        // not auto-detectable any more
        int x;

        @JsonProperty("z") int _z;
    }

    @("SimpleTypeSerializationTest.testNoAutoDetect")
    unittest
    {
        auto t = table();
        t.add(descriptorOf!NoAutoDetectBean());
        auto bean = new NoAutoDetectBean();
        bean._z = -4;
        auto result = writeAndMap(newJsonMapper(t), bean);
        assert(result.size() == 1);
        assert(intOf(result.get("z")) == -4);
    }
}

/**
 * Unit test that verifies that if both a field and a getter
 * method exist for a logical property (which is allowed),
 * getter has precedence over field.
 */
@("SimpleTypeSerializationTest.testMethodPrecedence")
unittest
{
    auto bean = new FieldAndMethodBean();
    bean.z = 9;
    assert(bean.getZ() == 10);
    const json = mapper().writeValueAsString(bean);
    assert(json == `{"z":10}`, json);
}

/**
 * Testing [JACKSON-226]: it is ok to have "field override",
 * as long as there are no intra-class conflicts.
 */
@("SimpleTypeSerializationTest.testOkDupFields")
unittest
{
    auto bean = new OkDupFieldBean(1, 2);
    auto json = writeAndMap(mapper(), bean);
    assert(json.size() == 2);
    assert(intOf(json.get("x")) == 1);
    assert(intOf(json.get("y")) == 2);
}

// flint.jackson has no @JsonSerialize/@JsonDeserialize.
version (FlintJacksonCustomSerializers)
{
    @JsonInclude(JsonInclude.Include.NON_EMPTY)
    private final class Item240
    {
        @JsonProperty private string id;
        // only include annotation to ensure it won't override settings
        @JsonSerialize(typing : JsonSerialize.Typing.STATIC) private string state;

        this(string id, string state)
        {
            this.id = id;
            this.state = state;
        }
    }

    @("SimpleTypeSerializationTest.testIssue240")
    unittest
    {
        auto bean = new Item240("a12", null);
        assert(mapper().writeValueAsString(bean) == `{"id":"a12"}`);
    }

    /**
     * Let's test invalid bean too: can't have 2 logical properties
     * with same name.
     */
    private final class DupFieldBean
    {
        @JsonProperty("foo") int _z = 1;

        @JsonSerialize private int foo = 2;
    }

    @("SimpleTypeSerializationTest.testFailureDueToDupField1")
    unittest
    {
        auto e = assertThrows!InvalidDefinitionException(() {
            const json = mapper().writeValueAsString(new DupFieldBean());
            assert(false, "Should not pass, got: " ~ json);
        });
        verifyException(e, "Multiple fields representing");
    }
}

@("SimpleTypeSerializationTest.testResolvedDuplicate")
unittest
{
    const json = mapper().writeValueAsString(new DupFieldBean2());
    assert(json == a2q("{'z':4}"), json);
}

// Test methods, auto-detect configuration

@("SimpleTypeSerializationTest.testDefaults")
unittest
{
    auto m = mapper();
    // by default, only public fields and getters are detected
    assert(m.writeValueAsString(new FieldBean()) == `{"p1":"public"}`);
    assert(m.writeValueAsString(new MethodBean()) == `{"a":"a"}`);
}

// flint.jackson ignores @JsonAutoDetect and the default visibility settings.
version (FlintJacksonAutoDetect)
{
    @JsonAutoDetect(fieldVisibility : JsonAutoDetect.Visibility.PROTECTED_AND_PUBLIC)
    private final class ProtFieldBean : FieldBean
    {
    }

    @JsonAutoDetect(getterVisibility : JsonAutoDetect.Visibility.PROTECTED_AND_PUBLIC)
    private final class ProtMethodBean : MethodBean
    {
    }

    @("SimpleTypeSerializationTest.testProtectedViaAnnotations")
    unittest
    {
        auto t = table();
        t.add(descriptorOf!ProtFieldBean());
        t.add(descriptorOf!ProtMethodBean());
        auto m = newJsonMapper(t);
        auto result = writeAndMap(m, new ProtFieldBean());
        assert(result.size() == 2);
        assert(result.get("p1").get!string() == "public");
        assert(result.get("p2").get!string() == "protected");
        assert(result.get("p3").isNull());

        result = writeAndMap(m, new ProtMethodBean());
        assert(result.size() == 2);
        assert(result.get("a").get!string() == "a");
        assert(result.get("b").get!string() == "b");
        assert(result.get("c").isNull());
    }
}

@("SimpleTypeSerializationTest.testStaticFields")
unittest
{
    auto result = writeAndMap(mapper(), new FieldBeanWithStatic());
    assert(result.size() == 1);
    assert(intOf(result.get("x")) == 1);
}

@("SimpleTypeSerializationTest.testStaticMethods")
unittest
{
    auto result = writeAndMap(mapper(), new GetterBeanWithStatic());
    assert(result.size() == 1);
    assert(intOf(result.get("x")) == 3);
}

// flint.jackson ignores @JsonAutoDetect and the default visibility settings.
version (FlintJacksonAutoDetect)
{
    @("SimpleTypeSerializationTest.testPrivateUsingGlobals")
    unittest
    {
        ObjectMapper m = jsonMapperBuilder(table()).changeDefaultVisibility(
                vc => vc.withFieldVisibility(JsonAutoDetect.Visibility.ANY)).build();

        auto result = writeAndMap(m, new FieldBean());
        assert(result.size() == 3);
        assert(result.get("p1").get!string() == "public");
        assert(result.get("p2").get!string() == "protected");
        assert(result.get("p3").get!string() == "private");

        m = jsonMapperBuilder(table()).changeDefaultVisibility(
                vc => vc.withGetterVisibility(JsonAutoDetect.Visibility.ANY)).build();
        result = writeAndMap(m, new MethodBean());
        assert(result.size() == 3);
        assert(result.get("a").get!string() == "a");
        assert(result.get("b").get!string() == "b");
        assert(result.get("c").get!string() == "c");
    }

    @("SimpleTypeSerializationTest.testBasicSetup")
    unittest
    {
        ObjectMapper m = jsonMapperBuilder(table()).changeDefaultVisibility(
                vc => vc.with_(JsonAutoDetect.Visibility.ANY)).build();
        auto result = writeAndMap(m, new FieldBean());
        assert(result.size() == 3);
        assert(result.get("p1").get!string() == "public");
        assert(result.get("p2").get!string() == "protected");
        assert(result.get("p3").get!string() == "private");
    }

    @("SimpleTypeSerializationTest.testMapperShortcutMethods")
    unittest
    {
        import flint.jackson.annotation : PropertyAccessor;

        ObjectMapper m = jsonMapperBuilder(table()).changeDefaultVisibility(
                vc => vc.withVisibility(PropertyAccessor.FIELD, JsonAutoDetect.Visibility.ANY)).build();

        auto result = writeAndMap(m, new FieldBean());
        assert(result.size() == 3);
        assert(result.get("p1").get!string() == "public");
        assert(result.get("p2").get!string() == "protected");
        assert(result.get("p3").get!string() == "private");
    }
}

// Test methods, cyclic types

@("SimpleTypeSerializationTest.testLinkedButNotCyclic")
unittest
{
    auto last = new CyclicBean(null, "last");
    auto first = new CyclicBean(last, "first");
    auto map = writeAndMap(mapper(), first);

    assert(map.size() == 2);
    assert(map.get("name").get!string() == "first");

    auto map2 = map.get("next").get!JsonNode();
    assert(map2 !is null);
    assert(map2.size() == 2);
    assert(map2.get("name").stringValue() == "last");
    assert(map2.get("next").isNull());
}

@("SimpleTypeSerializationTest.testSimpleDirectSelfReference")
unittest
{
    auto selfRef = new CyclicBean(null, "self-refs");
    auto first = new CyclicBean(selfRef, "first");
    selfRef.assignNext(selfRef);
    auto wrapper = [first];
    try
        writeAndMap(mapper(), wrapper);
    catch (InvalidDefinitionException e)
        verifyException(e, "Direct self-reference leading to cycle");
}

// ObjectWriter has no with/without(SerializationFeature) (nor WRITE_SELF_REFERENCES_AS_NULL, Shape.ARRAY beans).
version (FlintJacksonObjectWriterConfig)
{
    @JsonPropertyOrder(["id", "parent"])
    private class Selfie2501
    {
        int id;

        Selfie2501 parent;

        this(int id)
        {
            this.id = id;
        }
    }

    @JsonFormat(shape : JsonFormat.Shape.ARRAY)
    private final class Selfie2501AsArray : Selfie2501
    {
        this(int id)
        {
            super(id);
        }
    }

    // [databind#2501]: Should be possible to replace null cyclic ref
    @("SimpleTypeSerializationTest.testReplacedCycle")
    unittest
    {
        auto t = table();
        t.add(descriptorOf!Selfie2501());
        t.add(descriptorOf!Selfie2501AsArray());
        auto self1 = new Selfie2501(1);
        self1.parent = self1;
        ObjectWriter w = newJsonMapper(t).writer().without(SerializationFeature.FAIL_ON_SELF_REFERENCES)
            .with_(SerializationFeature.WRITE_SELF_REFERENCES_AS_NULL);
        assert(w.writeValueAsString(self1) == a2q("{'id':1,'parent':null}"));

        // Also consider a variant of cyclic POJO in container
        auto self2 = new Selfie2501AsArray(2);
        self2.parent = self2;
        assert(w.writeValueAsString(self2) == a2q("[2,null]"));
    }
}

// flint.jackson has no @JsonAppend virtual properties, nor ObjectWriter.withAttribute.
version (FlintJacksonJsonAppend)
{
    import flint.jackson.databind.annotation : JsonAppend;

    @JsonAppend(attrs : [
        JsonAppend.Attr("id"), JsonAppend.Attr(value: "internal", propName: "extra", required: true)
    ])
    private final class VPropSimpleBean
    {
        int value = 13;
    }

    @JsonAppend(prepend : true, attrs:
            [JsonAppend.Attr("id"), JsonAppend.Attr(value: "internal", propName: "extra")])
    private final class VPropSimpleBeanPrepend
    {
        int value = 13;
    }

    private enum VPropABC
    {
        A,
        B,
        C,
    }

    @JsonAppend(attrs : [JsonAppend.Attr(value: "desc", include: JsonInclude.Include.NON_EMPTY)])
    private final class OptionalsBean
    {
        int value = 28;
    }

    private final class CustomVProperty : VirtualBeanPropertyWriter
    {
        override Any value(Any bean, JsonGenerator jgen, SerializationContext prov)
        {
            if (_name.toString() == "id")
                return Any.of("abc123");
            if (_name.toString() == "extra")
                return Any.of([42]);
            return Any.of("???");
        }
    }

    @JsonAppend(prepend : true, props:
            [
        JsonAppend.Prop(value: classOf!CustomVProperty, name: "id"),
        JsonAppend.Prop(value: classOf!CustomVProperty, name: "extra")
    ])
    private final class CustomVBean
    {
        int value = 72;
    }

    private DescriptorTable appendTable()
    {
        auto t = table();
        foreach (d; [
            descriptorOf!VPropSimpleBean(), descriptorOf!VPropSimpleBeanPrepend(),
            descriptorOf!VPropABC(), descriptorOf!OptionalsBean(), descriptorOf!CustomVBean()
        ])
            t.add(d);
        return t;
    }

    @("SimpleTypeSerializationTest.testAttributeProperties")
    unittest
    {
        auto writer = newJsonMapper(appendTable()).writer();
        auto stuff = new LinkedHashMap!(string, Any)();
        stuff.put("x", Any.of(3));
        stuff.put("y", Any.of(VPropABC.B));

        auto json = writer.withAttribute("id", "abc123").withAttribute("internal", stuff)
            .writeValueAsString(new VPropSimpleBean());
        assert(json == a2q("{'value':13,'id':'abc123','extra':{'x':3,'y':'B'}}"));

        json = writer.withAttribute("id", "abc123").withAttribute("internal", stuff)
            .writeValueAsString(new VPropSimpleBeanPrepend());
        assert(json == a2q("{'id':'abc123','extra':{'x':3,'y':'B'},'value':13}"));
    }

    @("SimpleTypeSerializationTest.testAttributePropInclusion")
    unittest
    {
        auto writer = newJsonMapper(appendTable()).writer();
        // first, with desc
        auto json = writer.withAttribute("desc", "nice").writeValueAsString(new OptionalsBean());
        assert(json == a2q("{'value':28,'desc':'nice'}"));

        // then with null (not defined)
        json = writer.writeValueAsString(new OptionalsBean());
        assert(json == a2q("{'value':28}"));

        // and finally "empty"
        json = writer.withAttribute("desc", "").writeValueAsString(new OptionalsBean());
        assert(json == a2q("{'value':28}"));
    }

    @("SimpleTypeSerializationTest.testCustomProperties")
    unittest
    {
        const json = newJsonMapper(appendTable()).writer().withAttribute("desc", "nice")
            .writeValueAsString(new CustomVBean());
        assert(json == a2q("{'id':'abc123','extra':[42],'value':72}"));
    }
}
