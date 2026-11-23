/++
Ported from FasterXML/jackson-databind 3.1.8, src/test/java/tools/jackson/databind/ser/enums/EnumSerializationTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit assertions become D asserts; `EnumSet` is a `HashSet` and `EnumMap` a
`LinkedHashMap` (both hold one entry here); D enums have no methods or constructors, so a Java enum's `toString()` is
a comment, its `@JsonValue`/`@JsonKey` methods are free functions over the enum, and a constant's constructor
argument is its value (`OK : string`); DatabindTestUtil's EnumWithSubClass has no constant-specific bodies in D.
+/
module enum_serialization_test;

import databind_test_util : a2q, jsonMapperBuilder, q;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.annotation : JsonKey, JsonProperty, JsonValue;
import flint.jackson.databind : EnumFeature, JsonMapper;
import flint.java.util : HashMap, HashSet, LinkedHashMap, Map, Set;

@safe:

/// Test enumeration for verifying Enum serialization functionality; Java's `toString()` lower-cases the name.
private enum TestEnum
{
    A,
    B,
    C,
}

/// Alternative version that forces use of "toString-serializer" (`@JsonSerialize(using=ToStringSerializer.class)`).
private enum AnnotatedTestEnum
{
    A2,
    B2,
    C2,
}

private enum EnumWithJsonValue : string
{
    A = "foo",
    B = "bar",
}

// EnumWithJsonValue's `@JsonValue public String external()`.
@JsonValue private string external(EnumWithJsonValue e)
{
    return "value:" ~ e;
}

// The constant-specific bodies of DatabindTestUtil.EnumWithSubClass are Java only.
private enum EnumWithSubClass
{
    A,
    B,
}

private enum SerializableEnum
{
    A,
    B,
    C,
}

// Java's `toString()` lower-cases the name.
private enum LowerCaseEnum
{
    A,
    B,
    C,
}

private enum NOT_OK : string
{
    V1 = "v1",
}

private enum OK : string
{
    V1 = "v1",
}

// [JACKSON-757], non-inner enum
private enum NOT_OK2 : string
{
    V2 = "v2",
}

// Java's `toString()` lower-cases the name.
private enum LC749Enum
{
    A,
    B,
    C,
}

// for [databind#1322]
private enum EnumWithJsonProperty
{
    @JsonProperty("aleph") A,
}

// [databind#2871]: add `@JsonKey`
private enum EnumWithJsonKey : string
{
    A = "a",
    B = "b",
}

@JsonKey private string externalKey(EnumWithJsonKey e)
{
    return "key:" ~ e;
}

@JsonValue private string externalValue(EnumWithJsonKey e)
{
    return "value:" ~ e;
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!TestEnum(), descriptorOf!AnnotatedTestEnum(), descriptorOf!EnumWithJsonValue(),
        descriptorOf!EnumWithSubClass(), descriptorOf!SerializableEnum(),
        descriptorOf!LowerCaseEnum(), descriptorOf!NOT_OK(), descriptorOf!OK(),
        descriptorOf!NOT_OK2(), descriptorOf!LC749Enum(), descriptorOf!EnumWithJsonProperty(),
        descriptorOf!EnumWithJsonKey(), descriptorOf!(HashSet!TestEnum)(),
        descriptorOf!(HashSet!EnumWithJsonProperty)(),
        descriptorOf!(LinkedHashMap!(EnumWithJsonValue, string))(),
        descriptorOf!(LinkedHashMap!(LowerCaseEnum, string))(),
        descriptorOf!(LinkedHashMap!(LC749Enum, string))(),
        descriptorOf!(LinkedHashMap!(EnumWithJsonProperty, string))(),
        descriptorOf!(HashMap!(EnumWithJsonProperty, int))(),
        descriptorOf!(LinkedHashMap!(EnumWithJsonKey, EnumWithJsonKey))()
    ])
        t.add(d);
    return t;
}

private JsonMapper mapper()
{
    return jsonMapperBuilder(table()).disable(EnumFeature.WRITE_ENUMS_USING_TO_STRING).build();
}

@("EnumSerializationTest.testSimple")
unittest
{
    assert(mapper().writeValueAsString(TestEnum.B) == `"B"`);
}

@("EnumSerializationTest.testEnumSet")
unittest
{
    Set!TestEnum value = new HashSet!TestEnum();
    value.add(TestEnum.B);
    assert(mapper().writeValueAsString(value) == `["B"]`);
}

// flint.jackson's enum serializer writes the constant's name: it calls no toString(), @JsonValue or @JsonKey method,
// and has no @JsonSerialize(using=ToStringSerializer.class) (D enums have no methods to declare them on).
version (FlintJacksonEnumMethods)
{
    /**
     * Whereas regular Enum serializer uses enum names, some users
     * prefer calling toString() instead. So let's verify that
     * this can be done using annotation for enum class.
     */
    @("EnumSerializationTest.testEnumUsingToString")
    unittest
    {
        assert(mapper().writeValueAsString(AnnotatedTestEnum.C2) == `"c2"`);
    }
}

@("EnumSerializationTest.testSubclassedEnums")
unittest
{
    assert(mapper().writeValueAsString(EnumWithSubClass.B) == `"B"`);
}

version (FlintJacksonEnumMethods)
{
    @("EnumSerializationTest.testEnumsWithJsonValue")
    unittest
    {
        assert(mapper().writeValueAsString(EnumWithJsonValue.B) == `"value:bar"`);
    }
}

// flint.jackson has no mix-in annotations (MapperBuilder.addMixIn).
version (FlintJacksonMixIns)
{
    private interface ToStringMixin
    {
        @JsonValue string toString() const;
    }

    @("EnumSerializationTest.testEnumsWithJsonValueUsingMixin")
    unittest
    {
        // can't share, as new mix-ins are added
        auto mapper = jsonMapperBuilder(table()).addMixIn!(TestEnum, ToStringMixin)().build();
        assert(mapper.writeValueAsString(TestEnum.B) == `"b"`);
    }
}

version (FlintJacksonEnumMethods)
{
    // [databind#601]
    @("EnumSerializationTest.testEnumsWithJsonValueInMap")
    unittest
    {
        auto input = new LinkedHashMap!(EnumWithJsonValue, string)();
        input.put(EnumWithJsonValue.B, "x");
        // 24-Sep-2015, tatu: SHOULD actually use annotated method, as per:
        assert(mapper().writeValueAsString(input) == `{"value:bar":"x"}`);
    }
}

// flint.jackson has no JacksonSerializable, custom serializers or SimpleModule.
version (FlintJacksonCustomSerializers)
{
    /**
     * Test for ensuring that @JsonSerializable is used with Enum types as well
     * as with any other types.
     */
    @("EnumSerializationTest.testSerializableEnum")
    unittest
    {
        assert(mapper().writeValueAsString(SerializableEnum.A) == `"foo"`);
    }
}

// flint.jackson's ObjectWriter has no with/without/forType (per-call features).
version (FlintJacksonObjectWriterConfig)
{
    @("EnumSerializationTest.testToStringEnum")
    unittest
    {
        auto m = jsonMapperBuilder(table()).configure(EnumFeature.WRITE_ENUMS_USING_TO_STRING, true).build();
        assert(m.writeValueAsString(LowerCaseEnum.B) == `"b"`);

        // [databind#749] but should also be able to dynamically disable
        auto w = m.writer().without(EnumFeature.WRITE_ENUMS_USING_TO_STRING);
        assert(w.writeValueAsString(LowerCaseEnum.B) == `"B"`);
    }
}

version (FlintJacksonEnumMethods)
{
    @("EnumSerializationTest.testToStringEnumWithEnumMap")
    unittest
    {
        auto m = jsonMapperBuilder(table()).enable(EnumFeature.WRITE_ENUMS_USING_TO_STRING).build();
        auto enums = new LinkedHashMap!(LowerCaseEnum, string)();
        enums.put(LowerCaseEnum.C, "value");
        assert(m.writeValueAsString(enums) == `{"c":"value"}`);
    }
}

@("EnumSerializationTest.testAsIndex")
unittest
{
    // By default, serialize using name
    auto m = jsonMapperBuilder(table()).disable(EnumFeature.WRITE_ENUMS_USING_TO_STRING).build();
    assert(!m.isEnabled(EnumFeature.WRITE_ENUMS_USING_INDEX));
    assert(m.writeValueAsString(TestEnum.B) == q("B"));

    // but we can change (dynamically, too!) it to be number-based
    m = jsonMapperBuilder(table()).enable(EnumFeature.WRITE_ENUMS_USING_INDEX).build();
    assert(m.writeValueAsString(TestEnum.B) == "1");
}

// flint.jackson cannot serialize an enum whose base type is not integral (Java's enum with a constructor argument).
// LIKELY BUG: OK.V1 (`enum OK : string`) throws AnyTypeException "Any holds enum_serialization_test.OK, not long",
// expected "V1".
version (FlintJacksonNonIntegralEnums)
{
    @("EnumSerializationTest.testAnnotationsOnEnumCtor")
    unittest
    {
        assert(mapper().writeValueAsString(OK.V1) == q("V1"));
        assert(mapper().writeValueAsString(NOT_OK.V1) == q("V1"));
        assert(mapper().writeValueAsString(NOT_OK2.V2) == q("V2"));
    }
}

version (FlintJacksonCustomSerializers)
{
    // [databind#227]
    @("EnumSerializationTest.testGenericEnumSerializer")
    unittest
    {
        // By default, serialize using name
        auto module_ = new SimpleModule("foobar");
        module_.addSerializer!Enum(new LowerCasingEnumSerializer());
        auto mapper = jsonMapperBuilder(table()).addModule(module_).build();
        assert(mapper.writeValueAsString(TestEnum.B) == q("b"));
    }
}

// [databind#749]

@("EnumSerializationTest.testEnumMapSerDefault")
unittest
{
    auto mapper = jsonMapperBuilder(table()).disable(EnumFeature.WRITE_ENUMS_USING_TO_STRING).build();
    auto m = new LinkedHashMap!(LC749Enum, string)();
    m.put(LC749Enum.A, "value");
    assert(mapper.writeValueAsString(m) == `{"A":"value"}`);
}

version (FlintJacksonObjectWriterConfig)
{
    @("EnumSerializationTest.testEnumMapSerDisableToString")
    unittest
    {
        auto mapper = jsonMapperBuilder(table()).build();
        auto w = mapper.writer().without(EnumFeature.WRITE_ENUMS_USING_TO_STRING);
        auto m = new LinkedHashMap!(LC749Enum, string)();
        m.put(LC749Enum.A, "value");
        assert(w.writeValueAsString(m) == `{"A":"value"}`);
    }

    @("EnumSerializationTest.testEnumMapSerEnableToString")
    unittest
    {
        auto mapper = jsonMapperBuilder(table()).build();
        auto w = mapper.writer().with_(EnumFeature.WRITE_ENUMS_USING_TO_STRING);
        auto m = new LinkedHashMap!(LC749Enum, string)();
        m.put(LC749Enum.A, "value");
        assert(w.writeValueAsString(m) == `{"a":"value"}`);
    }
}

// flint.jackson's enum serializer ignores @JsonProperty on enum constants.
// LIKELY BUG: EnumWithJsonProperty.A writes "A", expected "aleph" (as a value, in a Set and as a Map key).
version (FlintJacksonEnumConstantRename)
{
    // [databind#1322]
    @("EnumSerializationTest.testEnumsWithJsonProperty")
    unittest
    {
        assert(mapper().writeValueAsString(EnumWithJsonProperty.A) == q("aleph"));
    }
}

version (FlintJacksonObjectWriterConfig)
{
    @("EnumSerializationTest.testEnumsWithJsonPropertyEnableToString")
    unittest
    {
        const result = mapper().writerFor!EnumWithJsonProperty()
            .with_(EnumFeature.WRITE_ENUMS_USING_TO_STRING).writeValueAsString(EnumWithJsonProperty.A);
        assert(result == q("aleph"));
    }
}

version (FlintJacksonEnumConstantRename)
{
    // [databind#1535]
    @("EnumSerializationTest.testEnumKeysWithJsonProperty")
    unittest
    {
        Map!(EnumWithJsonProperty, int) input = new HashMap!(EnumWithJsonProperty, int)();
        input.put(EnumWithJsonProperty.A, 13);
        assert(mapper().writeValueAsString(input) == a2q("{'aleph':13}"));
    }

    // [databind#1322]
    @("EnumSerializationTest.testEnumsWithJsonPropertyInSet")
    unittest
    {
        Set!EnumWithJsonProperty input = new HashSet!EnumWithJsonProperty();
        input.add(EnumWithJsonProperty.A);
        assert(mapper().writeValueAsString(input) == `["aleph"]`);
    }

    // [databind#1322]
    @("EnumSerializationTest.testEnumsWithJsonPropertyAsKey")
    unittest
    {
        auto input = new LinkedHashMap!(EnumWithJsonProperty, string)();
        input.put(EnumWithJsonProperty.A, "b");
        assert(mapper().writeValueAsString(input) == `{"aleph":"b"}`);
    }
}

version (FlintJacksonEnumMethods)
{
    // [databind#2871]
    @("EnumSerializationTest.testEnumWithJsonKey")
    unittest
    {
        // First with EnumMap
        auto input1 = new LinkedHashMap!(EnumWithJsonKey, EnumWithJsonKey)();
        input1.put(EnumWithJsonKey.A, EnumWithJsonKey.B);
        assert(mapper().writeValueAsString(input1) == a2q("{'key:a':'value:b'}"));

        // Then regular Map with Enums
        Map!(EnumWithJsonKey, EnumWithJsonKey) input2 = new LinkedHashMap!(EnumWithJsonKey, EnumWithJsonKey)();
        input2.put(EnumWithJsonKey.A, EnumWithJsonKey.B);
        assert(mapper().writeValueAsString(input2) == a2q("{'key:a':'value:b'}"));
    }
}

// flint.jackson has no ObjectReader (ObjectMapper.reader()).
version (FlintJacksonObjectReader)
{
    // [databind#3053]
    @("EnumSerializationTest.testEnumFeature_WRITE_ENUMS_TO_LOWERCASE_isDisabledByDefault")
    unittest
    {
        auto reader = mapper().reader();
        assert(!reader.isEnabled(EnumFeature.WRITE_ENUMS_TO_LOWERCASE));
        assert(!reader.without(EnumFeature.WRITE_ENUMS_TO_LOWERCASE).isEnabled(EnumFeature.WRITE_ENUMS_TO_LOWERCASE));
    }
}

@("EnumSerializationTest.testEnumFeature_WRITE_ENUMS_TO_LOWERCASE")
unittest
{
    auto m = jsonMapperBuilder(table()).configure(EnumFeature.WRITE_ENUMS_TO_LOWERCASE, true).build();
    assert(m.writeValueAsString(TestEnum.B) == q("b"));
    // NOTE: cannot be dynamically changed
}
