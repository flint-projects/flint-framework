/++
Ported from FasterXML/jackson-databind 3.1.8,
src/test/java/tools/jackson/databind/deser/jdk/MapDeserializationTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit assertions become D asserts; `TypeReference<T>` and `Class<T>` arguments are
`readValue!T` template arguments; `Integer` and `Boolean` map values are `Nullable!int`, `int` keys stay `int`;
`Object` is `Any`; `getClass()` checks compare `typeid`; CollectionDeserializationTest.Key is redeclared here.
Not ported: testClassKeyMap (`Class` keys resolve names with Class.forName, Java reflection) and
testcharSequenceKeyMap (D has no `CharSequence` distinct from `string`, whose map keys the other cases cover).
Cases that need JDK types flint.java lacks (TreeMap, AbstractMap, EnumMap, Date, Calendar, UUID, Currency), untyped
`LinkedHashMap`/`ArrayList` binding, delegating creators, ObjectReader, polymorphic type ids, custom deserializers,
Locale keys, Map subclasses or ACCEPT_EMPTY_STRING_AS_NULL_OBJECT wait behind versions.
+/
module map_deserialization_test;

import databind_test_util : jsonMapperBuilder, newJsonMapper, q, verifyException;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.databind : DeserializationFeature, ObjectMapper;
import flint.jackson.databind.exc : InvalidDefinitionException, MismatchedInputException;
import flint.java.util : HashMap, LinkedHashMap, Map;
import std.typecons : Nullable;

@safe:

// CollectionDeserializationTest.Key
private enum Key
{
    KEY1,
    KEY2,
    WHATEVER
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!Key(), descriptorOf!(Nullable!int)(), descriptorOf!(Map!(string, Any))(),
        descriptorOf!(LinkedHashMap!(string, Any))(), descriptorOf!(HashMap!(string, Any))(),
        descriptorOf!(HashMap!(string, Nullable!int))(), descriptorOf!(HashMap!(int, bool))(),
        descriptorOf!(Map!(string, Nullable!int))(),
        descriptorOf!(LinkedHashMap!(string, Nullable!int))(), descriptorOf!(Map!(Key, Key))(),
        descriptorOf!(LinkedHashMap!(Key, Key))(), descriptorOf!(Map!(string, string))(),
        descriptorOf!(LinkedHashMap!(string, string))()
    ])
        t.add(d);
    return t;
}

private ObjectMapper mapper()
{
    return newJsonMapper(table());
}

/*
 * Test methods, untyped (Object valued) maps
 */

// An untyped JSON object or array binds to a JsonNode, where Jackson builds a LinkedHashMap or an ArrayList
// (UntypedObjectDeserializer).
version (FlintJacksonUntypedCollections)
{
    import flint.java.util : Collection;

    @("MapDeserializationTest.testBigUntypedMap")
    unittest
    {
        import std.conv : to;

        auto m = mapper();
        Map!(string, Any) map = new LinkedHashMap!(string, Any)();
        foreach (i; 0 .. 1100)
        {
            if ((i & 1) == 0)
                map.put(i.to!string, Any.of(i));
            else
            {
                Map!(string, Any) map2 = new LinkedHashMap!(string, Any)();
                map2.put("x", Any.of(i));
                map.put(i.to!string, Any.of(map2));
            }
        }
        const json = m.writeValueAsString(map);
        auto bound = m.readValue!Any(json).get!(Map!(string, Any))();

        assert(bound.size() == map.size());
        assert(map.equals(cast(Object) bound));
    }

    @("MapDeserializationTest.testUntypedMap3")
    unittest
    {
        auto m = mapper();
        auto json = `{"a":[{"a":"b"},"value"]}`;
        auto result = m.readValue!(Map!(string, Any))(json);
        assert(result.size() == 1);
        auto ob = result.get("a");
        assert(!ob.isNull());
        auto list = ob.get!(Collection!Any)();
        assert(list.size() == 2);

        json = `{ "var1":"val1", "var2":"val2", ` ~ `"subvars": [`
            ~ ` {  "subvar1" : "subvar2", "x" : "y" }, ` ~ ` { "a":1 } ]` ~ ` }`;
        result = m.readValue!(Map!(string, Any))(json);
        assert(result.size() == 3);
    }
}

/**
 * Let's also try another way to express "gimme a Map" deserialization;
 * this time by specifying a Map class, to reduce need to cast
 */
@("MapDeserializationTest.testUntypedMap2")
unittest
{
    // to get "untyped" default map-to-map, pass Object.class
    enum JSON = `{ "a" : "x" }`;

    auto result = mapper().readValue!(HashMap!(string, Any))(JSON);
    assert(result !is null);
    assert(cast(Map!(string, Any)) result !is null);

    assert(result.size() == 1);

    assert(result.get("a").get!string() == "x");
}

// flint.jackson has no delegating creators (@JsonCreator(mode = DELEGATING), or a single-String static factory).
version (FlintJacksonDelegatingCreators)
{
    import flint.jackson.annotation : JsonCreator;
    import flint.java.util : Collections;

    private final class ObjectWrapper
    {
        Any object;

        protected this(Any object)
        {
            this.object = object;
        }

        Any getObject()
        {
            return object;
        }

        @JsonCreator(mode: JsonCreator.Mode.DELEGATING)
        static ObjectWrapper jsonValue(Any object)
        {
            return new ObjectWrapper(object);
        }
    }

    private final class ObjectWrapperMap : HashMap!(string, ObjectWrapper)
    {
    }

    private final class KeyType
    {
        protected string value;

        private this(string v, bool bogus)
        {
            value = v;
        }

        @JsonCreator
        static KeyType create(string v)
        {
            return new KeyType(v, true);
        }
    }

    private enum UNTYPED_MAP_JSON = `{ "double":42.0, "string":"string",`
        ~ `"boolean":true, "list":["list0"],` ~ `"null":null }`;

    private ObjectMapper creatorMapper()
    {
        auto t = table();
        foreach (d; [
            descriptorOf!ObjectWrapper(), descriptorOf!ObjectWrapperMap(),
            descriptorOf!(Map!(string, ObjectWrapper))(),
            descriptorOf!(LinkedHashMap!(string, ObjectWrapper))(), descriptorOf!KeyType(),
            descriptorOf!(Map!(KeyType, Nullable!int))(),
            descriptorOf!(LinkedHashMap!(KeyType, Nullable!int))()
        ])
            t.add(d);
        return newJsonMapper(t);
    }

    private void doTestUntyped(Map!(string, ObjectWrapper) map)
    {
        auto w = map.get("double");
        assert(w !is null);
        assert(w.getObject().get!double() == 42.0);
        assert(map.get("string").getObject().get!string() == "string");
        assert(map.get("boolean").getObject().get!bool() == true);
        assert(Collections.singletonList("list0").equals(map.get("list").getObject().asObject()));
        assert(map.containsKey("null"));
        assert(map.get("null") is null);
        assert(map.size() == 5);
    }

    @("MapDeserializationTest.testSpecialMap")
    unittest
    {
        auto map = creatorMapper().readValue!ObjectWrapperMap(UNTYPED_MAP_JSON);
        assert(map !is null);
        doTestUntyped(map);
    }

    @("MapDeserializationTest.testGenericMap")
    unittest
    {
        auto map = creatorMapper().readValue!(Map!(string, ObjectWrapper))(UNTYPED_MAP_JSON);
        doTestUntyped(map);
    }

    // Test confirming that @JsonCreator may be used with Map Key types
    @("MapDeserializationTest.testKeyWithCreator")
    unittest
    {
        auto m = creatorMapper();
        // first, key should deserialize normally:
        auto key = m.readValue!KeyType(q("abc"));
        assert(key.value == "abc");

        auto map = m.readValue!(Map!(KeyType, Nullable!int))(`{"foo":3}`);
        assert(map.size() == 1);
        key = map.keySet().iterator().next();
        assert(key.value == "foo");
    }
}

@("MapDeserializationTest.testFromEmptyString")
unittest
{
    auto m = jsonMapperBuilder(table()).configure(DeserializationFeature.ACCEPT_EMPTY_STRING_AS_NULL_OBJECT,
            true).build();
    const result = m.readValue!(Map!(string, Any))(q(""));
    assert(result is null);
}

/*
 * Test methods, typed maps
 */

@("MapDeserializationTest.testExactStringIntMap")
unittest
{
    // to get typing, must use type reference
    enum JSON = "{ \"foo\" : 13, \"bar\" : -39, \n \"\" : 0 }";
    Map!(string, Nullable!int) result = mapper().readValue!(HashMap!(string, Nullable!int))(JSON);

    assert(result !is null);
    // LIKELY BUG: a HashMap target binds to a LinkedHashMap in Flint; Jackson builds exactly a HashMap.
    version (FlintJacksonConcreteCollectionClass)
        assert(typeid(cast(Object) result) is typeid(HashMap!(string, Nullable!int)));
    assert(result.size() == 3);

    assert(result.get("foo") == 13);
    assert(result.get("bar") == -39);
    assert(result.get("") == 0);
    assert(result.get("foobar").isNull);
    assert(result.get(" ").isNull);
}

/**
 * Let's also check that it is possible to do type conversions
 * to allow use of non-String Map keys.
 */
@("MapDeserializationTest.testIntBooleanMap")
unittest
{
    // to get typing, must use type reference
    enum JSON = `{ "1" : true, "-1" : false }`;
    auto result = mapper().readValue!(HashMap!(int, bool))(JSON);
    assert(result !is null);
    // LIKELY BUG: a HashMap target binds to a LinkedHashMap in Flint; Jackson builds exactly a HashMap.
    version (FlintJacksonConcreteCollectionClass)
        assert(typeid(cast(Object) result) is typeid(HashMap!(int, bool)));
    assert(result.size() == 2);

    assert(result.get(1) == true);
    assert(result.get(-1) == false);
    assert(!result.containsKey(0));
}

// flint.java.util has no TreeMap, AbstractMap or EnumMap; flint.java no Date, Calendar, UUID or Currency.
version (FlintJacksonJdkTypes)
{
    private final class AbstractMapWrapper
    {
        AbstractMap!(string, Nullable!int) values;
    }

    @("MapDeserializationTest.testExactStringStringMap")
    unittest
    {
        // to get typing, must use type reference
        enum JSON = `{ "a" : "b" }`;
        Map!(string, string) result = mapper().readValue!(TreeMap!(string, string))(JSON);

        assert(result !is null);
        assert(typeid(cast(Object) result) is typeid(TreeMap!(string, string)));
        assert(result.size() == 1);

        assert(result.get("a") == "b");
        assert(result.get("b") is null);
    }

    @("MapDeserializationTest.testAbstractMapDefault")
    unittest
    {
        const result = mapper().readValue!AbstractMapWrapper(`{"values":{"foo":42}}`);
        assert(result !is null);
        assert(typeid(cast(const Object) result.values) is typeid(LinkedHashMap!(string, Nullable!int)));
    }

    @("MapDeserializationTest.testEnumMap")
    unittest
    {
        enum JSON = `{ "KEY1" : "", "WHATEVER" : null }`;

        // to get typing, must use type reference
        auto result = mapper().readValue!(EnumMap!(Key, string))(JSON);

        assert(result !is null);
        assert(typeid(result) is typeid(EnumMap!(Key, string)));
        assert(result.size() == 2);

        assert(result.get(Key.KEY1) == "");
        // null should be ok too...
        assert(result.containsKey(Key.WHATEVER));
        assert(result.get(Key.WHATEVER) is null);

        // plus we have nothing for this key
        assert(!result.containsKey(Key.KEY2));
        assert(result.get(Key.KEY2) is null);
    }

    @("MapDeserializationTest.testDateMap")
    unittest
    {
        auto date1 = new Date(123_456_000L);
        auto fmt = new SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US);

        const JSON = "{ \"" ~ fmt.format(date1) ~ "\" : \"\", \"" ~ new Date(0).getTime().to!string ~ "\" : null }";
        auto result = mapper().readValue!(HashMap!(Date, string))(JSON);

        assert(result !is null);
        assert(typeid(result) is typeid(HashMap!(Date, string)));
        assert(result.size() == 2);

        assert(result.containsKey(date1));
        assert(result.get(new Date(123_456_000L)) == "");

        assert(result.containsKey(new Date(0)));
        assert(result.get(new Date(0)) is null);
    }

    @("MapDeserializationTest.testCalendarMap")
    unittest
    {
        auto m = mapper();
        // 18-Jun-2015, tatu: Should be safest to use default timezone that mapper would use
        auto tz = m.serializationConfig().getTimeZone();
        auto c = Calendar.getInstance(tz);

        c.setTimeInMillis(123_456_000L);
        auto fmt = new SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US);
        const JSON = "{ \"" ~ fmt.format(c.getTime()) ~ "\" : \"\", \"" ~ new Date(0).getTime()
            .to!string ~ "\" : null }";
        auto result = m.readValue!(HashMap!(Calendar, string))(JSON);

        assert(result !is null);
        assert(typeid(result) is typeid(HashMap!(Calendar, string)));
        assert(result.size() == 2);

        assert(result.containsKey(c));
        assert(result.get(c) == "");
        c.setTimeInMillis(0);
        assert(result.containsKey(c));
        assert(result.get(c) is null);
    }

    @("MapDeserializationTest.testUUIDKeyMap")
    unittest
    {
        auto key = UUID.nameUUIDFromBytes(cast(const(ubyte)[]) "foobar");
        const JSON = "{ \"" ~ key.toString() ~ "\":4}";
        auto result = mapper().readValue!(Map!(UUID, Any))(JSON);
        assert(result !is null);
        assert(result.size() == 1);
        const ob = result.keySet().iterator().next();
        assert(ob == key);
    }

    @("MapDeserializationTest.testCurrencyKeyMap")
    unittest
    {
        auto key = Currency.getInstance("USD");
        const JSON = "{ \"" ~ key.toString() ~ "\":4}";
        auto result = mapper().readValue!(Map!(Currency, Any))(JSON);
        assert(result !is null);
        assert(result.size() == 1);
        const ob = result.keySet().iterator().next();
        assert(ob == key);
    }
}

@("MapDeserializationTest.testGenericStringIntMap")
unittest
{
    // to get typing, must use type reference; but with abstract type
    enum JSON = `{ "a" : 1, "b" : 2, "c" : -99 }`;
    auto result = mapper().readValue!(Map!(string, Nullable!int))(JSON);
    assert(result !is null);
    assert(result.size() == 3);

    assert(result.get("c") == -99);
    assert(result.get("b") == 2);
    assert(result.get("a") == 1);

    assert(result.get("").isNull);
}

/*
 * Test methods, updating
 */

// flint.jackson has no ObjectReader (readerFor(), withValueToUpdate()).
version (FlintJacksonObjectReader)
{
    import flint.java.util : Collections;

    @("MapDeserializationTest.testMapUpdate")
    unittest
    {
        Map!(string, Any) map = new HashMap!(string, Any)();
        auto result = mapper().readerFor!(Map!(string, Any))().withValueToUpdate(map).readValue("{ }");
        assert(result is map);
        assert(map.size() == 0);

        result = mapper().readerFor!(Map!(string, Any))().withValueToUpdate(map).readValue(`{"key": null }`);
        assert(result is map);
        assert(map.size() == 1);
        assert(Collections.singletonMap("key", Any.init).equals(cast(Object) map));

        result = mapper().readerFor!(Map!(string, Any))().withValueToUpdate(map).readValue(`{"key": false }`);
        assert(result is map);
        assert(map.size() == 1);
        assert(Collections.singletonMap("key", Any.of(false)).equals(cast(Object) map));
    }
}

/*
 * Test methods, maps with enums
 */

@("MapDeserializationTest.testMapWithEnums")
unittest
{
    enum JSON = `{ "KEY2" : "WHATEVER" }`;

    // to get typing, must use type reference
    auto result = mapper().readValue!(Map!(Key, Key))(JSON);

    assert(result !is null);
    assert(result.size() == 1);

    assert(result.get(Key.KEY2) == Key.WHATEVER);
    assert(!result.containsKey(Key.WHATEVER));
    assert(!result.containsKey(Key.KEY1));
}

// flint.jackson has no @JsonTypeInfo polymorphic type ids.
version (FlintJacksonGenericTypes)
{
    import flint.java.util : ArrayList, List;

    private final class EnumMapContainer
    {
        @JsonTypeInfo(use: JsonTypeInfo.Id.CLASS, include: JsonTypeInfo.As.PROPERTY, property: "@class")
        EnumMap!(KeyEnum, ITestType) testTypes;
    }

    private final class ListContainer
    {
        List!ITestType testTypes;
    }

    @JsonTypeInfo(use: JsonTypeInfo.Id.CLASS, include: JsonTypeInfo.As.PROPERTY, property: "@class")
    private interface ITestType
    {
    }

    private enum KeyEnum
    {
        A,
        B
    }

    // Java's enum implementing an interface: a class with constants.
    private final class ConcreteType : ITestType
    {
        static immutable ONE = new ConcreteType();
        static immutable TWO = new ConcreteType();
    }

    @("MapDeserializationTest.testEnumPolymorphicSerializationTest")
    unittest
    {
        auto m = new ObjectMapper();
        List!ITestType testTypesList = new ArrayList!ITestType();
        testTypesList.add(ConcreteType.ONE);
        testTypesList.add(ConcreteType.TWO);
        auto listContainer = new ListContainer();
        listContainer.testTypes = testTypesList;
        auto json = m.writeValueAsString(listContainer);
        listContainer = m.readValue!ListContainer(json);
        auto enumMapContainer = new EnumMapContainer();
        auto testTypesMap = new EnumMap!(KeyEnum, ITestType)();
        testTypesMap.put(KeyEnum.A, ConcreteType.ONE);
        testTypesMap.put(KeyEnum.B, ConcreteType.TWO);
        enumMapContainer.testTypes = testTypesMap;

        json = m.writeValueAsString(enumMapContainer);
        enumMapContainer = m.readValue!EnumMapContainer(json);
    }
}

/*
 * Test methods, maps with various alternative key types
 */

// flint.jackson's key deserializers cover String, integral, boolean and enum keys only, not Locale.
version (FlintJacksonMapKeyDeserializers)
{
    import flint.java.util : Locale;

    @("MapDeserializationTest.testLocaleKeyMap")
    unittest
    {
        const key = Locale("zh", "CN"); // Locale.CHINA
        const JSON = "{ \"" ~ key.toString() ~ "\":4}";
        auto t = table();
        t.add(descriptorOf!(Map!(Locale, Any))());
        t.add(descriptorOf!(LinkedHashMap!(Locale, Any))());
        auto result = newJsonMapper(t).readValue!(Map!(Locale, Any))(JSON);
        assert(result !is null);
        assert(result.size() == 1);
        const ob = result.keySet().iterator().next();
        assert(ob == key);
    }
}

/*
 * Test methods, annotated Maps
 */

// flint.jackson has no @JsonDeserialize(using) nor custom StdDeserializer subclasses.
version (FlintJacksonCustomSerializers)
{
    @JsonDeserialize(using: classOf!CustomMapDeserializer)
    private final class CustomMap : LinkedHashMap!(string, string)
    {
    }

    private final class CustomMapDeserializer : StdDeserializer!CustomMap
    {
        override CustomMap deserialize(JsonParser p, DeserializationContext ctxt)
        {
            auto result = new CustomMap();
            result.put("x", p.getString());
            return result;
        }
    }

    /**
     * Simple test to ensure that @JsonDeserialize.using is
     * recognized
     */
    @("MapDeserializationTest.testMapWithDeserializer")
    unittest
    {
        auto result = mapper().readValue!CustomMap(q("xyz"));
        assert(result.size() == 1);
        assert(result.get("x") == "xyz");
    }
}

/*
 * Error tests
 */

@("MapDeserializationTest.testMapError")
unittest
{
    auto m = mapper();
    try
    {
        auto result = m.readValue!(Map!(string, string))("[ 1, 2 ]");
        assert(false, "Expected an exception, but got result value: " ~ result.toString());
    }
    catch (MismatchedInputException jex)
        verifyException(jex, "JsonToken.START_ARRAY");

    try
    {
        auto result = m.readValue!(Map!(string, string))("true");
        assert(false, "Expected an exception, but got result value: " ~ result.toString());
    }
    catch (MismatchedInputException jex)
        verifyException(jex, "from Boolean value (token `JsonToken.VALUE_TRUE`)");

    // flint.jackson has no ObjectReader (readerFor(), withValueToUpdate()).
    version (FlintJacksonObjectReader)
    {
        Map!(string, string) map = new HashMap!(string, string)();
        try
        {
            auto result = m.readerFor!(Map!(string, string))().withValueToUpdate(map).readValue("true");
            assert(false, "Expected an exception, but got result value: " ~ result.toString());
        }
        catch (MismatchedInputException jex)
            verifyException(jex, "from Boolean value (token `JsonToken.VALUE_TRUE`)");
    }
}

// LIKELY BUG: a Map subclass (BrokenMap, MyMap2757) binds as the LinkedHashMap its Map descriptor builds, so reading
// it throws AnyTypeException "Any holds flint.java.util.Map!(...), not <subclass>"; Jackson binds the subclass, or
// throws InvalidDefinitionException "no default constructor found" when it has none.
version (FlintJacksonMapSubclasses)
{
    private final class BrokenMap : HashMap!(string, Any)
    {
        // No default ctor, nor @JsonCreators
        this(Any dummy)
        {
            super();
        }
    }

    // [databind#2757]
    private final class MyMap2757 : LinkedHashMap!(string, string)
    {
        this()
        {
        }

        void setValue(string)
        {
        }

        void setValue(int)
        {
        }

        long getValue()
        {
            return 0L;
        }
    }

    private ObjectMapper subclassMapper()
    {
        auto t = table();
        t.add(descriptorOf!BrokenMap());
        t.add(descriptorOf!MyMap2757());
        return newJsonMapper(t);
    }

    @("MapDeserializationTest.testNoCtorMap")
    unittest
    {
        try
        {
            subclassMapper().readValue!BrokenMap(`{ "a" : 3 }`);
            assert(false, "Should not pass");
        }
        catch (InvalidDefinitionException e)
        {
            // instead, should get this exception:
            verifyException(e, "no default constructor found");
        }
    }

    // [databind#2757]: should allow deserialization as Map despite conflicting setters
    @("MapDeserializationTest.testCanDeserializeMap2757")
    unittest
    {
        auto m = subclassMapper();
        auto input = new MyMap2757();
        input.put("a", "b");
        const json = m.writeValueAsString(input);
        auto x = m.readValue!MyMap2757(json);
        assert(x.size() == 1);
        assert(input.get("a") == "b");
    }
}
