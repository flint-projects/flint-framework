/++
Ported from FasterXML/jackson-databind 3.1.8, src/test/java/tools/jackson/databind/records/RecordBasicsTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: records are D structs (rulebook R11) whose canonical constructor descriptor is built
by hand as Flint AOT emits it, each parameter carrying its record component's annotations as javac propagates them;
`Class<T>` arguments are template parameters; `readValue(json, Object.class)` reads an untyped object, which
flint.jackson's UntypedObjectDeserializer builds as an `ObjectNode` where Jackson builds a `LinkedHashMap`, so the
expected maps are trees; `MAPPER.readerFor(T.class)` without further configuration is the mapper's `readValue!T`.
Cases that need parts of flint.jackson that are not ported yet wait behind versions.
+/
module record_basics_test;

import databind_test_util : newJsonMapper;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : ConstructorDescriptor, Descriptor, DescriptorTable,
    ParameterDescriptor, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.jackson.annotation : JsonProperty;
import flint.jackson.databind : JsonMapper, MapperFeature, ObjectMapper, PropertyNamingStrategies;
import flint.jackson.databind.annotation : JsonNaming;
import flint.jackson.databind.node : JsonNode, ObjectNode;
import flint.java.lang : classOf;

@safe:

private struct EmptyRecord
{
}

private struct SimpleRecord
{
    int id;
    string name;
}

private struct RecordOfRecord
{
    SimpleRecord record;
}

private struct RecordWithRename
{
    int id;
    @JsonProperty("rename") string name;
}

// [databind#2992]
@JsonNaming(classOf!(PropertyNamingStrategies.SnakeCaseStrategy))
private struct SnakeRecord
{
    string myId;
    string myValue;
}

private struct RecordSingleWriteOnly
{
    @JsonProperty(access : JsonProperty.Access.WRITE_ONLY) int id;
}

private struct RecordSomeWriteOnly
{
    @JsonProperty(access : JsonProperty.Access.WRITE_ONLY) int id;
    @JsonProperty(access : JsonProperty.Access.WRITE_ONLY) string name;
    string email;
}

private struct RecordAllWriteOnly
{
    @JsonProperty(access : JsonProperty.Access.WRITE_ONLY) int id;
    @JsonProperty(access : JsonProperty.Access.WRITE_ONLY) string name;
    @JsonProperty(access : JsonProperty.Access.WRITE_ONLY) string email;
}

// The canonical constructor: one argument per component, in declaration order.
private Any invokeRecord(T)(scope Any[] arguments) @safe
{
    T value;
    static foreach (i; 0 .. T.tupleof.length)
        if (!arguments[i].isNull())
            value.tupleof[i] = arguments[i].get!(typeof(T.tupleof[i]))();
    return Any.of(value);
}

// The descriptor Flint AOT emits for a record: its components, and the canonical constructor first.
private Descriptor recordDescriptor(T)()
{
    auto d = descriptorOf!T();
    ParameterDescriptor[] parameters;
    foreach (ref p; d.properties)
        parameters ~= ParameterDescriptor(p.name, p.type, p.annotations.dup);
    d.constructors = ConstructorDescriptor(parameters, null, &invokeRecord!T, true) ~ d.constructors;
    return d;
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        recordDescriptor!EmptyRecord(), recordDescriptor!SimpleRecord(),
        recordDescriptor!RecordOfRecord(), recordDescriptor!RecordWithRename(),
        recordDescriptor!SnakeRecord(), recordDescriptor!RecordSingleWriteOnly(),
        recordDescriptor!RecordSomeWriteOnly(), recordDescriptor!RecordAllWriteOnly()
    ])
        t.add(d);
    return t;
}

private ObjectMapper mapper()
{
    return newJsonMapper(table());
}

// `MAPPER.readValue(json, Object.class)`: the untyped value, here a tree.
private JsonNode readUntyped(ObjectMapper m, string json)
{
    auto value = m.readValue(json, typeNameOf!Any);
    return cast(JsonNode) value.asObject();
}

// The helper `map(key1, value1, key2, value2)`, as a tree.
private ObjectNode map(ObjectMapper m, string key1, int value1, string key2, string value2)
{
    auto result = m.createObjectNode();
    result.put(key1, value1);
    result.put(key2, value2);
    return result;
}

// flint.jackson has no JavaType (constructType, isRecordType).
version (FlintJacksonGenericTypes)
{
    @("RecordBasicsTest.testRecordJavaType")
    unittest
    {
        auto m = mapper();
        assert(!m.constructType!RecordBasicsTest().isRecordType());
        assert(m.constructType!SimpleRecord().isRecordType());
        assert(m.constructType!RecordOfRecord().isRecordType());
        assert(m.constructType!RecordWithRename().isRecordType());
    }
}

@("RecordBasicsTest.testSerializeSimpleRecord")
unittest
{
    auto m = mapper();
    const json = m.writeValueAsString(SimpleRecord(123, "Bob"));
    auto expected = map(m, "id", 123, "name", "Bob");
    assert(expected.equals(readUntyped(m, json)), json);
}

@("RecordBasicsTest.testDeserializeSimpleRecord")
unittest
{
    assert(SimpleRecord(123, "Bob") == mapper().readValue!SimpleRecord(`{"id":123,"name":"Bob"}`));
}

@("RecordBasicsTest.testSerializeEmptyRecord")
unittest
{
    assert(mapper().writeValueAsString(EmptyRecord()) == "{}");
}

@("RecordBasicsTest.testDeserializeEmptyRecord")
unittest
{
    assert(EmptyRecord() == mapper().readValue!EmptyRecord("{}"));
}

@("RecordBasicsTest.testSerializeRecordOfRecord")
unittest
{
    auto m = mapper();
    const record = RecordOfRecord(SimpleRecord(123, "Bob"));
    const json = m.writeValueAsString(record);
    auto expected = m.createObjectNode();
    expected.set("record", map(m, "id", 123, "name", "Bob"));
    assert(expected.equals(readUntyped(m, json)), json);
}

@("RecordBasicsTest.testDeserializeRecordOfRecord")
unittest
{
    assert(RecordOfRecord(SimpleRecord(123, "Bob")) == mapper()
            .readValue!RecordOfRecord(`{"record":{"id":123,"name":"Bob"}}`));
}

@("RecordBasicsTest.testSerializeSimpleRecord_DisableAnnotationIntrospector")
unittest
{
    const record = SimpleRecord(123, "Bob");
    auto m = JsonMapper.builder().descriptors(table()).configure(MapperFeature.USE_ANNOTATIONS, false).build();
    const json = m.writeValueAsString(record);
    assert(json == `{"id":123,"name":"Bob"}`, json);
}

@("RecordBasicsTest.testDeserializeSimpleRecord_DisableAnnotationIntrospector")
unittest
{
    auto m = JsonMapper.builder().descriptors(table()).configure(MapperFeature.USE_ANNOTATIONS, false).build();
    const value = m.readValue!SimpleRecord(`{"id":123,"name":"Bob"}`);
    assert(SimpleRecord(123, "Bob") == value);
}

@("RecordBasicsTest.testSerializeJsonRename")
unittest
{
    auto m = mapper();
    const json = m.writeValueAsString(RecordWithRename(123, "Bob"));
    auto expected = map(m, "id", 123, "rename", "Bob");
    assert(expected.equals(readUntyped(m, json)), json);
}

@("RecordBasicsTest.testDeserializeJsonRename")
unittest
{
    const value = mapper().readValue!RecordWithRename(`{"id":123,"rename":"Bob"}`);
    assert(RecordWithRename(123, "Bob") == value);
}

// flint.jackson has no @JacksonInject binding, InjectableValues nor ObjectReader.
version (FlintJacksonInjectableValues)
{
    private struct RecordWithHeaderInject
    {
        int id;
        @JacksonInject string name;
    }

    private struct RecordWithConstructorInject
    {
        int id;
        string name;
    }

    // Confirmation of fix of [databind#4218]
    @("RecordBasicsTest.testDeserializeHeaderInjectRecord4218")
    unittest
    {
        auto reader = mapper().readerFor!RecordWithHeaderInject().with_(new InjectableValues.Std()
                .addValue!string("Bob"));
        assert(!reader.readValue(`{"id":123}`).isNull());
    }

    @("RecordBasicsTest.testDeserializeConstructorInjectRecord4218")
    unittest
    {
        auto reader = mapper().readerFor!RecordWithConstructorInject()
            .with_(new InjectableValues.Std().addValue!string("Bob"));
        const value = reader.readValue!RecordWithConstructorInject(`{"id":123}`);
        assert(RecordWithConstructorInject(123, "Bob") == value);
    }
}

// [databind#2992]
@("RecordBasicsTest.testNamingStrategy")
unittest
{
    auto m = mapper();
    const input = SnakeRecord("123", "value");
    const json = m.writeValueAsString(input);
    assert(json == `{"my_id":"123","my_value":"value"}`, json);
    const output = m.readValue!SnakeRecord(json);
    assert(input == output);
}

// flint.jackson has no @JsonDeserialize(converter) nor Converter.
version (FlintJacksonCustomSerializers)
{
    private struct RecordWithJsonDeserialize
    {
        int id;
        @JsonDeserialize(converter : classOf!StringTrimmer) string name;
    }

    private final class StringTrimmer : Converter!(string, string)
    {
        string convert(string value)
        {
            import std.string : strip;

            return value.strip();
        }
    }

    @("RecordBasicsTest.testDeserializeJsonDeserializeRecord")
    unittest
    {
        const value = mapper().readValue!RecordWithJsonDeserialize(`{"id":123,"name":"   Bob   "}`);
        assert(RecordWithJsonDeserialize(123, "Bob") == value);
    }
}

@("RecordBasicsTest.testSerialize_SingleWriteOnlyParameter")
unittest
{
    assert(mapper().writeValueAsString(RecordSingleWriteOnly(123)) == "{}");
}

// [databind#3897]
@("RecordBasicsTest.testDeserialize_SingleWriteOnlyParameter")
unittest
{
    assert(RecordSingleWriteOnly(123) == mapper().readValue!RecordSingleWriteOnly(`{"id":123}`));
}

@("RecordBasicsTest.testSerialize_SomeWriteOnlyParameter")
unittest
{
    const json = mapper().writeValueAsString(RecordSomeWriteOnly(123, "Bob", "bob@example.com"));
    assert(json == `{"email":"bob@example.com"}`, json);
}

@("RecordBasicsTest.testDeserialize_SomeWriteOnlyParameter")
unittest
{
    const value = mapper().readValue!RecordSomeWriteOnly(`{"id":123,"name":"Bob","email":"bob@example.com"}`);
    assert(RecordSomeWriteOnly(123, "Bob", "bob@example.com") == value);
}

@("RecordBasicsTest.testSerialize_AllWriteOnlyParameter")
unittest
{
    assert(mapper().writeValueAsString(RecordAllWriteOnly(123, "Bob", "bob@example.com")) == "{}");
}

@("RecordBasicsTest.testDeserialize_AllWriteOnlyParameter")
unittest
{
    const value = mapper().readValue!RecordAllWriteOnly(`{"id":123,"name":"Bob","email":"bob@example.com"}`);
    assert(RecordAllWriteOnly(123, "Bob", "bob@example.com") == value);
}

// [databind#4678]
@("RecordBasicsTest.testSerializeWithSettersForGetters")
unittest
{
    auto withSetters = JsonMapper.builder().descriptors(table())
        .configure(MapperFeature.REQUIRE_SETTERS_FOR_GETTERS, true).build();
    const input = SimpleRecord(123, "Bob");
    assert(mapper().writeValueAsString(input) == withSetters.writeValueAsString(input));
}
