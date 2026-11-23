/++
Ported from FasterXML/jackson-databind 3.1.8, src/test/java/tools/jackson/databind/deser/NullHandlingDeserTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit assertions become D unittests and asserts; `Class<?>` and `TypeReference`
arguments are template parameters and the mapper holds the Flint AOT descriptors of the test beans; `Object` is
`Any`; DatabindTestUtil's `StringWrapper` is declared here. Cases that need parts of flint.jackson that are not
ported yet wait behind versions.
+/
module null_handling_deser_test;

import databind_test_util : a2q, jsonMapperBuilder, newJsonMapper, verifyException;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.databind : JsonMapper, ObjectMapper;
import flint.java.util : HashMap, List, Map, Set;

@safe:

// DatabindTestUtil.StringWrapper.
private final class StringWrapper
{
    string str;
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    t.add(descriptorOf!StringWrapper());
    return t;
}

@("NullHandlingDeserTest.testNull")
unittest
{
    auto mapper = newJsonMapper(table());
    // null doesn't really have a type, fake by assuming Object
    const result = mapper.readValue!Any("   null");
    assert(result.isNull());

    // although nominal type CAN matter
    const str = mapper.readValue!string("null");
    assert(str is null);

    const w = mapper.readValue!StringWrapper(a2q("{'str': null}"));
    assert(w !is null);
    assert(w.str is null);
}

// flint.jackson has no custom ValueDeserializer registration (SimpleModule.addDeserializer, getNullValue).
version (FlintJacksonCustomSerializers)
{
    import flint.jackson.annotation : JsonAnySetter;
    import flint.jackson.core : JsonParser, Version;
    import flint.jackson.databind : DeserializationContext, ObjectReader, ValueDeserializer;
    import flint.jackson.databind.mod : SimpleModule;

    private final class FunnyNullDeserializer : ValueDeserializer!string
    {
        override string deserialize(JsonParser jp, DeserializationContext ctxt)
        {
            return "text";
        }

        override string getNullValue(DeserializationContext ctxt)
        {
            return "funny";
        }
    }

    private final class AnySetter
    {
        private Map!(string, string) any;

        this()
        {
            any = new HashMap!(string, string)();
        }

        @JsonAnySetter
        void setAny(string name, string value)
        {
            any.put(name, value);
        }

        Map!(string, string) getAny()
        {
            return any;
        }
    }

    private ObjectMapper funnyMapper()
    {
        auto mod = new SimpleModule("test", Version.unknownVersion());
        mod.addDeserializer!string(new FunnyNullDeserializer());
        auto t = table();
        t.add(descriptorOf!AnySetter());
        t.add(descriptorOf!(List!string)());
        t.add(descriptorOf!(Map!(string, string))());
        return jsonMapperBuilder(t).addModule(mod).build();
    }

    @("NullHandlingDeserTest.testAnySetterNulls")
    unittest
    {
        auto mapper = funnyMapper();
        const fieldName = "fieldName";
        const nullValue = "{\"" ~ fieldName ~ "\":null}";

        // should get non-default null directly:
        auto result = mapper.readValue!AnySetter(nullValue);

        assert(result.getAny().size() == 1);
        assert(result.getAny().get(fieldName) !is null);
        assert(result.getAny().get(fieldName) == "funny");

        // as well as via ObjectReader
        ObjectReader reader = mapper.readerFor!AnySetter();
        result = reader.readValue!AnySetter(nullValue);

        assert(result.getAny().size() == 1);
        assert(result.getAny().get(fieldName) !is null);
        assert(result.getAny().get(fieldName) == "funny");
    }

    @("NullHandlingDeserTest.testCustomRootNulls")
    unittest
    {
        auto mapper = funnyMapper();

        // should get non-default null directly:
        string str = mapper.readValue!string("null");
        assert(str !is null);
        assert(str == "funny");

        // as well as via ObjectReader
        ObjectReader reader = mapper.readerFor!string();
        str = reader.readValue!string("null");
        assert(str !is null);
        assert(str == "funny");
    }

    // [databind#407]
    @("NullHandlingDeserTest.testListOfNulls")
    unittest
    {
        auto mapper = funnyMapper();
        const list = ["funny"];

        // should get non-default null directly:
        auto deser = mapper.readValue!(List!string)("[null]");
        assert(deser !is null);
        assert(deser.size() == 1);
        assert(deser.get(0) == list[0]);

        // as well as via ObjectReader
        ObjectReader reader = mapper.readerFor!(List!string)();
        deser = reader.readValue!(List!string)("[null]");
        assert(deser !is null);
        assert(deser.size() == 1);
        assert(deser.get(0) == list[0]);
    }

    // Test for [#407]
    @("NullHandlingDeserTest.testMapOfNulls")
    unittest
    {
        auto mapper = funnyMapper();
        // should get non-default null directly:
        auto deser = mapper.readValue!(Map!(string, string))(`{"key":null}`);
        assert(deser !is null);
        assert(deser.size() == 1);
        assert(deser.get("key") == "funny");

        // as well as via ObjectReader
        ObjectReader reader = mapper.readerFor!(Map!(string, string))();
        deser = reader.readValue!(Map!(string, string))(`{"key":null}`);
        assert(deser !is null);
        assert(deser.size() == 1);
        assert(deser.get("key") == "funny");
    }
}

// flint.jackson has no @JsonTypeInfo/@JsonSubTypes polymorphic type ids.
version (FlintJacksonGenericTypes)
{
    import flint.jackson.annotation : JsonSubTypes, JsonTypeInfo;
    import flint.java.lang : classOf;

    private interface Proxy
    {
    }

    private final class TypeA : Proxy
    {
        string aValue;
    }

    private final class TypeB : Proxy
    {
        string bValue;
    }

    // [databind#1601]
    private final class RootData
    {
        string name;
        string type;
        @JsonTypeInfo(use: JsonTypeInfo.Id.NAME, include: JsonTypeInfo.As.EXTERNAL_PROPERTY, property: "type")
        @JsonSubTypes([
            JsonSubTypes.Type(classOf!TypeA, "TypeA"), JsonSubTypes.Type(classOf!TypeB, "TypeB")
        ])
        Proxy proxy;
    }

    // [databind#1601]
    @("NullHandlingDeserTest.testPolymorphicDataNull")
    unittest
    {
        auto t = table();
        foreach (d; [
            descriptorOf!RootData(), descriptorOf!Proxy(), descriptorOf!TypeA(), descriptorOf!TypeB()
        ])
            t.add(d);
        auto mapper = newJsonMapper(t);
        const typeA = `{"name":"TypeAData", "type":"TypeA", "proxy":{"aValue":"This works!"}}`;
        const typeAData = mapper.readValue!RootData(typeA);
        assert((cast(const TypeA) typeAData.proxy).aValue == "This works!", "No value for aValue!?");
        const typeB = `{"name":"TypeBData", "type":"TypeB", "proxy":{"bValue":"This works too!"}}`;
        const typeBData = mapper.readValue!RootData(typeB);
        assert((cast(const TypeB) typeBData.proxy).bValue == "This works too!", "No value for bValue!?");
        const typeBNull = `{"name":"TypeBData", "type":"TypeB", "proxy": null}`;
        const typeBNullData = mapper.readValue!RootData(typeBNull);
        assert(typeBNullData.proxy is null, "Proxy should be null!");
    }
}

// flint.jackson has no changeDefaultNullHandling (Nulls.FAIL for contents) nor InvalidNullException.
version (FlintJacksonConfigOverrides)
{
    import flint.jackson.annotation : JsonSetter, Nulls;
    import flint.jackson.databind.exc : InvalidNullException;

    // [databind #3227]
    private enum EnumMapTestEnum
    {
        A,
        B,
        C,
    }

    private ObjectMapper contentNullFailMapper()
    {
        auto t = table();
        foreach (d; [
            descriptorOf!(Map!(string, Any))(), descriptorOf!(Map!(EnumMapTestEnum, int))(),
            descriptorOf!EnumMapTestEnum(), descriptorOf!(List!Any)(),
            descriptorOf!(Set!Any)(), descriptorOf!(List!string)(),
            descriptorOf!(Set!string)(), descriptorOf!(Any[])(), descriptorOf!(string[])()
        ])
            t.add(d);
        return JsonMapper.builder().descriptors(t)
            .changeDefaultNullHandling((JsonSetter.Value n) => n.withContentNulls(Nulls.FAIL)).build();
    }

    private void expectInvalidNull(scope void delegate() @safe action)
    {
        try
        {
            action();
            assert(false, "InvalidNullException expected");
        }
        catch (InvalidNullException e)
            verifyException(e, "Invalid `null` value encountered");
    }

    // Test for [databind#3227]
    @("NullHandlingDeserTest.testContentsNullFailForMaps")
    unittest
    {
        auto mapper = contentNullFailMapper();
        expectInvalidNull(() {
            mapper.readValue!(Map!(string, Any))(`{ "field": null, "property": 1 }`);
        });
        expectInvalidNull(() {
            mapper.readValue!(Map!(EnumMapTestEnum, int))(`{ "A": 1, "B": null }`);
        });
    }

    // Test for [databind#3227]
    @("NullHandlingDeserTest.testContentsNullFailForCollections")
    unittest
    {
        auto mapper = contentNullFailMapper();
        expectInvalidNull(() { mapper.readValue!(List!Any)(`[null, {"field": 1}]`); });
        expectInvalidNull(() { mapper.readValue!(Set!Any)(`[{"field": 1}, null]`); });
        expectInvalidNull(() { mapper.readValue!(List!string)(`["foo", null]`); });
        expectInvalidNull(() { mapper.readValue!(Set!string)(`["foo", null]`); });
    }

    // Test for [databind#3227]
    @("NullHandlingDeserTest.testContentsNullFailForArrays")
    unittest
    {
        auto mapper = contentNullFailMapper();
        expectInvalidNull(() { mapper.readValue!(Any[])(`[null, {"field": 1}]`); });
        expectInvalidNull(() { mapper.readValue!(string[])(`[null, "foo"]`); });
    }
}
