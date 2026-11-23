/++
Ported from FasterXML/jackson-databind 3.1.8,
src/test/java/tools/jackson/databind/deser/jdk/CollectionDeserializationTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D asserts; `TypeReference<T>` and `Class<T>`
arguments are `readValue!T` template arguments; the beans are D classes whose Flint AOT descriptors the mapper is
given (XBean's int constructor is not a creator, as in Jackson, since the default one exists); `Object` is `Any`;
`getClass()` checks compare `typeid`; Java's `AbstractSet` field is a `Set!string` (flint.java.util has no
AbstractSet). Cases that need JDK types flint.java lacks (EnumSet, ArrayBlockingQueue, TreeSet, Deque,
NavigableSet), untyped `ArrayList` binding, custom deserializers, ObjectReader, Iterable properties, default typing,
`@JsonFormat(with)` or ACCEPT_SINGLE_VALUE_AS_ARRAY wait behind versions.
+/
module collection_deserialization_test;

import databind_test_util : jsonMapperBuilder, newJsonMapper, q, verifyException;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.annotation : JsonProperty;
import flint.jackson.databind : DeserializationFeature, ObjectMapper;
import flint.jackson.databind.exc : MismatchedInputException;
import flint.java.util : AbstractList, ArrayList, Collection, Collections, HashSet, LinkedHashMap, List, Map, Set;

@safe:

private enum Key
{
    KEY1,
    KEY2,
    WHATEVER
}

private final class XBean
{
    int x;

    this()
    {
    }

    this(int x)
    {
        this.x = x;
    }
}

// [databind#2251]
private final class ListAsAbstract
{
    AbstractList!string values;
}

private final class SetAsAbstract
{
    Set!string values;
}

private final class KeyListBean
{
    List!Key keys;
}

// [databind#3068]: Exception wrapping (or not)
private final class MyContainerModel
{
    @JsonProperty("processor-id") string id = "123";
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!Key(), descriptorOf!XBean(), descriptorOf!ListAsAbstract(),
        descriptorOf!SetAsAbstract(), descriptorOf!KeyListBean(),
        descriptorOf!MyContainerModel(), descriptorOf!(Key[])(), descriptorOf!(string[])(),
        descriptorOf!(int[])(), descriptorOf!(XBean[])(), descriptorOf!(List!Key)(),
        descriptorOf!(ArrayList!Key)(), descriptorOf!(List!string)(),
        descriptorOf!(ArrayList!string)(), descriptorOf!(AbstractList!string)(),
        descriptorOf!(Set!string)(), descriptorOf!(HashSet!string)(),
        descriptorOf!(List!XBean)(), descriptorOf!(ArrayList!XBean)(),
        descriptorOf!(Set!XBean)(), descriptorOf!(List!Any)(), descriptorOf!(ArrayList!Any)(),
        descriptorOf!(Map!(string, MyContainerModel))(),
        descriptorOf!(LinkedHashMap!(string, MyContainerModel))()
    ])
        t.add(d);
    return t;
}

private ObjectMapper mapper()
{
    return newJsonMapper(table());
}

// An untyped JSON array binds to a JsonNode, where Jackson builds an ArrayList (UntypedObjectDeserializer).
version (FlintJacksonUntypedCollections)
{
    @("CollectionDeserializationTest.testUntypedList")
    unittest
    {
        // to get "untyped" default List, pass Object.class
        enum JSON = `[ "text!", true, null, 23 ]`;

        // Not a guaranteed cast theoretically, but will work:
        // (since we know that Jackson will construct an ArrayList here...)
        auto value = mapper().readValue!Any(JSON);
        assert(!value.isNull());
        auto result = value.get!(ArrayList!Any)();

        assert(result.size() == 4);

        assert(result.get(0).get!string() == "text!");
        assert(result.get(1).get!bool() == true);
        assert(result.get(2).isNull());
        assert(result.get(3).get!int() == 23);
    }
}

@("CollectionDeserializationTest.testExactStringCollection")
unittest
{
    // to get typing, must use type reference
    enum JSON = `[ "a", "b" ]`;
    List!string result = mapper().readValue!(ArrayList!string)(JSON);

    assert(result !is null);
    assert(typeid(cast(Object) result) is typeid(ArrayList!string));
    assert(result.size() == 2);

    assert(result.get(0) == "a");
    assert(result.get(1) == "b");
}

// flint.java.util has no EnumSet, ArrayBlockingQueue, TreeSet, Deque or NavigableSet.
version (FlintJacksonJdkTypes)
{
    @("CollectionDeserializationTest.testHashSet")
    unittest
    {
        enum JSON = `[ "KEY1", "KEY2" ]`;

        auto result = mapper().readValue!(EnumSet!Key)(JSON);
        assert(result !is null);
        assert(cast(EnumSet!Key) result !is null);
        assert(result.size() == 2);

        assert(result.contains(Key.KEY1));
        assert(result.contains(Key.KEY2));
        assert(!result.contains(Key.WHATEVER));
    }

    // [databind#161]
    @("CollectionDeserializationTest.testArrayBlockingQueue")
    unittest
    {
        // ok to skip polymorphic type to get Object
        auto q = mapper().readValue!(ArrayBlockingQueue!Any)("[1, 2, 3]");
        assert(q !is null);
        assert(q.size() == 3);
        assert(q.take().get!int() == 1);
        assert(q.take().get!int() == 2);
        assert(q.take().get!int() == 3);
    }

    // [databind#4262]: Handle problem of `null`s for `TreeSet`
    @("CollectionDeserializationTest.testNullsWithTreeSet")
    unittest
    {
        try
        {
            mapper().readValue!(TreeSet!Any)(`[ "acb", null, 123 ]`);
            assert(false, "Should not pass");
        }
        catch (MismatchedInputException e)
        {
            verifyException(e, "`java.util.Collection` of type ");
            verifyException(e, " does not accept `null` values");
        }
    }

    // for [databind#216]
    @("CollectionDeserializationTest.testJava6Types")
    unittest
    {
        auto dq = mapper().readValue!(Deque!Any)("[1]");
        assert(dq !is null);
        assert(dq.size() == 1);

        auto ns = mapper().readValue!(NavigableSet!Any)("[ true ]");
        assert(ns.size() == 1);
    }
}

// flint.jackson has no @JsonDeserialize(using), custom deserializers or SimpleModule.
version (FlintJacksonCustomSerializers)
{
    @JsonDeserialize(using : classOf!ListDeserializer)
    private final class CustomList : LinkedList!string
    {
    }

    private final class ListDeserializer : StdDeserializer!CustomList
    {
        override CustomList deserialize(JsonParser jp, DeserializationContext ctxt)
        {
            auto result = new CustomList();
            result.add(jp.getString());
            return result;
        }
    }

    private final class MyJobModel
    {
        Map!(string, MyContainerModel) containers;
        int maxChangeLogStreamPartitions = 13;

        this()
        {
            containers = Collections.singletonMap("key", new MyContainerModel());
        }
    }

    private final class CustomException : RuntimeException
    {
        this(string s)
        {
            super(s);
        }
    }

    /// Test to verify that @JsonDeserialize.using works as expected
    @("CollectionDeserializationTest.testCustomDeserializer")
    unittest
    {
        auto result = mapper().readValue!CustomList(q("abc"));
        assert(result.size() == 1);
        assert(result.get(0) == "abc");
    }

    // for [databind#3068]
    @("CollectionDeserializationTest.testWrapExceptions3068")
    unittest
    {
        auto module_ = new SimpleModule("SimpleModule", Version.unknownVersion()).addDeserializer!MyContainerModel(
                new class ValueDeserializer!MyContainerModel
            {
            override MyContainerModel deserialize(JsonParser p, DeserializationContext ctxt)
            {
                throw new CustomException("Custom message");}
            }
);
            auto m = jsonMapperBuilder(table()).addModule(module_).build();
            const json = m.writeValueAsString(new MyJobModel());

            // First, verify NO wrapping:
            try
            {
                m.readerFor!MyJobModel().without(DeserializationFeature.WRAP_EXCEPTIONS).readValue(json);
                assert(false, "Should not pass");
            }
            catch (CustomException e)
                verifyException(e, "Custom message");

            // and then wrapping
            try
            {
                m.readerFor!MyJobModel().with_(DeserializationFeature.WRAP_EXCEPTIONS).readValue(json);
                assert(false, "Should not pass");
            }
            catch (JacksonException e)
            {
                verifyException(e, "Custom message");
                const rootC = e.getCause();
                assert(rootC !is null);
                assert(cast(const CustomException) rootC !is null);
            }
        }
    }

    // Testing "implicit JSON array" for single-element arrays,
    // mostly produced by Jettison, Badgerfish conversions (from XML)
    @("CollectionDeserializationTest.testImplicitArrays")
    unittest
    {
        // can't share mapper, custom configs (could create ObjectWriter tho)
        auto m = jsonMapperBuilder(table()).enable(DeserializationFeature.ACCEPT_SINGLE_VALUE_AS_ARRAY).build();

        // first with simple scalar types (numbers), with collections
        auto ints = m.readValue!(List!Any)("4");
        assert(ints.size() == 1);
        assert(ints.get(0).get!int() == 4);
        auto strings = m.readValue!(ArrayList!string)(q("abc"));
        assert(strings.size() == 1);
        assert(strings.get(0) == "abc");
        // and arrays:
        const intArray = m.readValue!(int[])("-7");
        assert(intArray.length == 1);
        assert(intArray[0] == -7);
        const stringArray = m.readValue!(string[])(q("xyz"));
        assert(stringArray.length == 1);
        assert(stringArray[0] == "xyz");

        // and then with Beans:
        auto xbeanList = m.readValue!(List!XBean)(`{"x":4}`);
        assert(xbeanList.size() == 1);
        assert(typeid(xbeanList.get(0)) is typeid(XBean));

        const xbeanArray = m.readValue!(XBean[])(`{"x":29}`);
        assert(xbeanArray.length == 1);
        assert(typeid(xbeanArray[0]) is typeid(XBean));
    }

    // flint.jackson has no ObjectReader (reader(), readerFor(), with/without).
    version (FlintJacksonObjectReader)
    {
        // [databind#828]
        @JsonDeserialize(using : classOf!SomeObjectDeserializer)
        private final class SomeObject
        {
        }

        private final class SomeObjectDeserializer : StdDeserializer!SomeObject
        {
            override SomeObject deserialize(JsonParser p, DeserializationContext ctxt)
            {
                throw new RuntimeException("I want to catch this exception");
            }
        }

        // [JACKSON-620]: allow "" to mean 'null' for Maps
        @("CollectionDeserializationTest.testFromEmptyString")
        unittest
        {
            auto r = mapper().reader(DeserializationFeature.ACCEPT_EMPTY_STRING_AS_NULL_OBJECT);
            auto result = r.forType!(List!Any)().readValue(q(""));
            assert(result.isNull());
        }

        // for [databind#828]
        @("CollectionDeserializationTest.testWrapExceptions")
        unittest
        {
            auto wrappingReader = mapper().readerFor!(List!SomeObject)()
                .with_(DeserializationFeature.WRAP_EXCEPTIONS);

            try
                wrappingReader.readValue("[{}]");
            catch (JacksonException exc)
                assert(exc.getOriginalMessage() == "I want to catch this exception");

            auto noWrapReader = mapper().readerFor!(List!SomeObject)()
                .without(DeserializationFeature.WRAP_EXCEPTIONS);

            try
                noWrapReader.readValue("[{}]");
            catch (DatabindException exc)
                assert(false, "It should not have wrapped the RuntimeException.");
            catch (RuntimeException exc)
                assert(exc.getMessage() == "I want to catch this exception");
        }
    }

    // flint.jackson binds neither Iterable nor Iterator properties.
    version (FlintJacksonIterableTypes)
    {
        import flint.java.lang : Iterable;

        // [databind#199]
        private final class ListAsIterable
        {
            Iterable!string values;
        }

        private final class ListAsIterableX
        {
            Iterable!XBean nums;
        }

        private ObjectMapper iterableMapper()
        {
            auto t = table();
            foreach (d; [
                descriptorOf!ListAsIterable(), descriptorOf!ListAsIterableX(),
                descriptorOf!(Iterable!string)(), descriptorOf!(Iterable!XBean)()
            ])
                t.add(d);
            return newJsonMapper(t);
        }

        // [databind#199]
        @("CollectionDeserializationTest.testIterableWithStrings")
        unittest
        {
            enum JSON = `{ "values":["a","b"]}`;
            auto w = iterableMapper().readValue!ListAsIterable(JSON);
            assert(w !is null);
            assert(w.values !is null);
            auto it = w.values.iterator();
            assert(it.hasNext());
            assert(it.next() == "a");
            assert(it.next() == "b");
            assert(!it.hasNext());
        }

        @("CollectionDeserializationTest.testIterableWithBeans")
        unittest
        {
            enum JSON = `{ "nums":[{"x":1},{"x":2}]}`;
            auto w = iterableMapper().readValue!ListAsIterableX(JSON);
            assert(w !is null);
            assert(w.nums !is null);
            auto it = w.nums.iterator();
            assert(it.hasNext());
            auto xb = it.next();
            assert(xb !is null);
            assert(xb.x == 1);
            xb = it.next();
            assert(xb.x == 2);
            assert(!it.hasNext());
        }
    }

    // for [databind#506]
    @("CollectionDeserializationTest.testArrayIndexForExceptions1")
    unittest
    {
        try
        {
            mapper().readValue!(Key[])(`[ "KEY2", false ]`);
            assert(false, "Should not pass");
        }
        catch (MismatchedInputException e)
        {
            verifyException(e, "Cannot deserialize value of type");
            verifyException(e, "from Boolean value");
            assert(e.getPath().length == 1);
            assert(e.getPath()[0].index == 1);
        }
    }

    @("CollectionDeserializationTest.testArrayIndexForExceptions2")
    unittest
    {
        try
        {
            mapper().readValue!(string[])(`[ "xyz", { } ]`);
            assert(false, "Should not pass");
        }
        catch (MismatchedInputException e)
        {
            verifyException(e, "Cannot deserialize value of type");
            verifyException(e, "from Object value");
            assert(e.getPath().length == 1);
            assert(e.getPath()[0].index == 1);
        }
    }

    @("CollectionDeserializationTest.testArrayIndexForExceptions3")
    unittest
    {
        try
        {
            mapper().readValue!KeyListBean(`{"keys":[ "KEY2", false ]}`);
            assert(false, "Should not pass");
        }
        catch (MismatchedInputException e)
        {
            verifyException(e, "Cannot deserialize value of type");
            verifyException(e, "from Boolean value");
            assert(e.getPath().length == 2);
            // Bean has no index, but has name:
            assert(e.getPath()[0].index == -1);
            assert(e.getPath()[0].propertyName == "keys");

            // and for List, reverse:
            assert(e.getPath()[1].index == 1);
            assert(e.getPath()[1].propertyName is null);
        }
    }

    // [databind#2251]
    @("CollectionDeserializationTest.testAbstractListAndSet")
    unittest
    {
        enum JSON = `{"values":["foo", "bar"]}`;

        auto list = mapper().readValue!ListAsAbstract(JSON);
        assert(list.values.size() == 2);
        assert(typeid(cast(Object) list.values) is typeid(ArrayList!string));

        auto set = mapper().readValue!SetAsAbstract(JSON);
        assert(set.values.size() == 2);
        // LIKELY BUG: an abstract Set binds to a LinkedHashSet in Flint; Jackson builds a HashSet.
        version (FlintJacksonConcreteCollectionClass)
            assert(typeid(cast(Object) set.values) is typeid(HashSet!string), typeid(cast(Object) set.values).name);
    }

    // Round-trip test for singleton collections
    @("CollectionDeserializationTest.testSingletonCollections")
    unittest
    {
        auto m = mapper();
        auto json = m.writeValueAsString(Collections.singleton(new XBean(3)));
        Collection!XBean result = m.readValue!(List!XBean)(json);
        assert(result !is null);
        assert(result.size() == 1);
        assert(result.iterator().next().x == 3);

        json = m.writeValueAsString(Collections.singletonList(new XBean(28)));
        result = m.readValue!(List!XBean)(json);
        assert(result !is null);
        assert(result.size() == 1);
        assert(result.iterator().next().x == 28);
    }

    // flint.jackson has no default typing (activateDefaultTyping, type ids).
    version (FlintJacksonGenericTypes)
    {
        // [databind#1868]: Verify class name serialized as is
        @("CollectionDeserializationTest.testUnmodifiableSet")
        unittest
        {
            auto m = jsonMapperBuilder(table()).activateDefaultTyping(NoCheckSubTypeValidator.instance,
                    DefaultTyping.NON_FINAL, JsonTypeInfo.As.PROPERTY).build();
            auto theSet = Collections.unmodifiableSet(Collections.singleton("a"));
            const json = m.writeValueAsString(theSet);

            assert(json == `["java.util.Collections$UnmodifiableSet",["a"]]`, json);

            auto result = m.readValue!(Set!Any)(json);
            assert(result !is null);
            assert(result.size() == 1);
        }
    }

    // flint.jackson does not read @JsonFormat(with = ACCEPT_SINGLE_VALUE_AS_ARRAY): Jackson reads a single value into a
    // one-element collection, Flint throws MismatchedInputException.
    version (FlintJacksonJsonFormatFeatures)
    {
        import flint.jackson.annotation : JsonFormat;

        // [databind#5522]
        @JsonFormat(with_ : [JsonFormat.Feature.ACCEPT_SINGLE_VALUE_AS_ARRAY])
        private final class CustomNumberList5522 : ArrayList!Any
        {
        }

        @JsonFormat(with_ : [JsonFormat.Feature.ACCEPT_SINGLE_VALUE_AS_ARRAY])
        private final class CustomStringList5522 : ArrayList!string
        {
        }

        private final class CustomClassForNumber5522
        {
            private CustomNumberList5522 value;

            CustomNumberList5522 getValue()
            {
                return value;
            }

            void setValue(CustomNumberList5522 value)
            {
                this.value = value;
            }
        }

        private final class CustomClassForString5522
        {
            private CustomStringList5522 value;

            CustomStringList5522 getValue()
            {
                return value;
            }

            void setValue(CustomStringList5522 value)
            {
                this.value = value;
            }
        }

        private final class CustomClassForListField5522
        {
            @JsonFormat(with_ : [JsonFormat.Feature.ACCEPT_SINGLE_VALUE_AS_ARRAY])
            private List!string value;

            List!string getValue()
            {
                return value;
            }

            void setValue(List!string value)
            {
                this.value = value;
            }
        }

        private DescriptorTable table5522()
        {
            auto t = table();
            foreach (d; [
                descriptorOf!CustomNumberList5522(), descriptorOf!CustomStringList5522(),
                descriptorOf!CustomClassForNumber5522(), descriptorOf!CustomClassForString5522(),
                descriptorOf!CustomClassForListField5522()
            ])
                t.add(d);
            return t;
        }

        private ObjectMapper mapper5522()
        {
            return jsonMapperBuilder(table5522()).disable(DeserializationFeature.ACCEPT_SINGLE_VALUE_AS_ARRAY).build();
        }

        // [databind#5522]
        @("CollectionDeserializationTest.testCustomNumberCollectionDeserialize5522")
        unittest
        {
            enum jsonValue = `{
    "value": 1
}
`;
            auto result = mapper5522().readValue!CustomClassForNumber5522(jsonValue);
            assert(result.value.size() == 1);
            assert(result.value.get(0).get!int() == 1);
        }

        // [databind#5522]
        @("CollectionDeserializationTest.testCustomStringCollectionDeserialize5522")
        unittest
        {
            enum jsonValue = `{
    "value": "test"
}
`;
            auto result = mapper5522().readValue!CustomClassForString5522(jsonValue);
            assert(result.value.size() == 1);
            assert(result.value.get(0) == "test");
        }

        // [databind#5522]
        @("CollectionDeserializationTest.testStringCollectionDeserializeInField5522")
        unittest
        {
            enum jsonValue = `{
    "value": "test"
}
`;
            auto result = mapper5522().readValue!CustomClassForListField5522(jsonValue);
            assert(result.value.size() == 1);
            assert(result.value.get(0) == "test");
        }
    }
