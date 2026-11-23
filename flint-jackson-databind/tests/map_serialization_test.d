/++
Ported from FasterXML/jackson-databind 3.1.8, src/test/java/tools/jackson/databind/ser/jdk/MapSerializationTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit assertions become D asserts; beans are described by `descriptorOf!T`; maps
are flint.java.util's `HashMap` and `LinkedHashMap` (Flint's `HashMap` iterates in insertion order), `Integer` is
`Nullable!int`, `Object` keys and values are `Object` or `Any`; `byte[]` keys are `immutable(byte)[]` (a hash key
must not change); `Collections.singletonMap` is a one-entry `LinkedHashMap`; annotated package-private fields are public, as `descriptorOf` lists public fields; Java's
instance initializers are constructors; `MapWrapper` is DatabindTestUtil's. Cases that need parts of flint.jackson
or flint.java.util that are not ported yet wait behind versions.
+/
module map_serialization_test;

import databind_test_util : a2q, assertThrows, jsonMapperBuilder, newJsonMapper, verifyException;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.annotation : JsonCreator, JsonKey, JsonPropertyOrder, JsonValue;
import flint.jackson.databind : DatabindException, JsonMapper, ObjectMapper, ObjectWriter, SerializationFeature;
import flint.jackson.databind.exc : InvalidDefinitionException;
import flint.java.util : HashMap, LinkedHashMap, Map;
import std.typecons : Nullable;

@safe:

// [databind#335]
private final class MapOrderingBean
{
    @JsonPropertyOrder(alphabetic : true)
    LinkedHashMap!(string, Nullable!int) map;

    this(string[] keys...)
    {
        map = new LinkedHashMap!(string, Nullable!int)();
        int ix = 1;
        foreach (key; keys)
            map.put(key, Nullable!int(ix++));
    }
}

// [databind#47]
private final class Wat
{
    private const string wat;

    @JsonCreator
    this(string wat)
    {
        this.wat = wat;
    }

    @JsonValue
    string getWat() const
    {
        return wat;
    }

    override string toString() const
    {
        return "(String)[Wat: " ~ wat ~ "]";
    }
}

private final class WatMap : HashMap!(Wat, bool)
{
}

// [databind#2871]
private final class Inner2871
{
    @JsonKey
    string key;

    @JsonValue
    string value;

    this(string key, string value)
    {
        this.key = key;
        this.value = value;
    }

    override string toString() const
    {
        return "Inner2871(" ~ key ~ "," ~ value ~ ")";
    }
}

private final class Outer2871
{
    @JsonKey
    @JsonValue
    Inner2871 inner;

    this(Inner2871 inner)
    {
        this.inner = inner;
    }
}

private final class NoKeyOuter
{
    @JsonValue
    Inner2871 inner;

    this(Inner2871 inner)
    {
        this.inner = inner;
    }
}

// [databind#6240]: same as `Outer2871`, but annotations on getter
private final class OuterWithGetter6240
{
    private Inner2871 inner;

    this(Inner2871 inner)
    {
        this.inner = inner;
    }

    @JsonKey
    @JsonValue
    Inner2871 getInner()
    {
        return inner;
    }
}

// [databind#6240]
private final class KeyOnlyGetter6240
{
    string name = "value";

    @JsonKey
    @JsonValue(false)
    string getId()
    {
        return "a";
    }
}

// [databind#6240]
private final class ValueOnlyGetter6240
{
    @JsonKey(false)
    @JsonValue
    string getId()
    {
        return "a";
    }
}

private final class NotKarlBean
{
    Map!(string, Nullable!int) map;

    this()
    {
        map = new HashMap!(string, Nullable!int)();
        map.put("Not Karl", Nullable!int(1));
    }
}

// DatabindTestUtil.MapWrapper
private final class MapWrapper(K, V)
{
    Map!(K, V) map;

    this(K key, V value)
    {
        map = new LinkedHashMap!(K, V)();
        map.put(key, value);
    }
}

private final class ObjectContainer4773
{
    Map!(Any, string) exampleMap;

    this()
    {
        exampleMap = new HashMap!(Any, string)();
    }
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!MapOrderingBean(), descriptorOf!Wat(), descriptorOf!Inner2871(),
        descriptorOf!Outer2871(), descriptorOf!NoKeyOuter(), descriptorOf!OuterWithGetter6240(),
        descriptorOf!KeyOnlyGetter6240(), descriptorOf!ValueOnlyGetter6240(),
        descriptorOf!NotKarlBean(), descriptorOf!(MapWrapper!(immutable(byte)[], string))(),
        descriptorOf!ObjectContainer4773(), descriptorOf!(Nullable!int)(),
        descriptorOf!(byte[])(), descriptorOf!(Map!(string, Nullable!int))(),
        descriptorOf!(LinkedHashMap!(string, Nullable!int))(),
        descriptorOf!(Map!(immutable(byte)[], string))(), descriptorOf!(Map!(Any, string))()
    ])
        t.add(d);
    return t;
}

private JsonMapper mapper()
{
    return newJsonMapper(table());
}

private JsonMapper sortingMapper()
{
    return jsonMapperBuilder(table()).configure(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS, true).build();
}

// // // Tests from MapSerializationTest

// flint.jackson's ObjectMapper has no writerFor, nor ObjectWriter with/without(feature).
version (FlintJacksonObjectWriterConfig)
{
    @("MapSerializationTest.testUsingObjectWriter")
    unittest
    {
        import flint.engine.aot.name : typeNameOf;

        ObjectWriter w = mapper().writerFor(typeNameOf!Object);
        auto map = new LinkedHashMap!(string, Any)();
        map.put("a", Any.of(1));
        const json = w.writeValueAsString(map);
        assert(json == a2q("{'a':1}"), json);
    }
}

// flint.jackson has no @JsonSerialize(using) nor ValueSerializer.
version (FlintJacksonCustomSerializers)
{
    @JsonSerialize(using : classOf!PseudoMapSerializer)
    private final class PseudoMap : LinkedHashMap!(string, string)
    {
        this(string[] values...)
        {
            for (size_t i = 0; i < values.length; i += 2)
                put(values[i], values[i + 1]);
        }
    }

    private final class PseudoMapSerializer : ValueSerializer!(Map!(string, string))
    {
        override void serialize(Map!(string, string) value, JsonGenerator g, SerializationContext ctxt)
        {
            // just use standard Map.toString(), output as JSON String
            g.writeString(value.toString());
        }
    }

    @("MapSerializationTest.testMapSerializer")
    unittest
    {
        assert(mapper().writeValueAsString(new PseudoMap("a", "b", "c", "d")) == `"{a=b, c=d}"`);
    }
}

// problems with map entries, values
@("MapSerializationTest.testMapKeySetValuesSerialization")
unittest
{
    auto m = mapper();
    Map!(string, string) map = new HashMap!(string, string)();
    map.put("a", "b");
    assert(m.writeValueAsString(map.keySet()) == `["a"]`);
    assert(m.writeValueAsString(map.values()) == `["b"]`);

    // flint.java.util has no TreeMap nor ConcurrentHashMap.
    version (FlintJacksonJdkTypes)
    {
        import flint.java.util : TreeMap;
        import flint.java.util.concurrent : ConcurrentHashMap;

        // TreeMap has similar inner class(es):
        map = new TreeMap!(string, string)();
        map.put("c", "d");
        assert(m.writeValueAsString(map.keySet()) == `["c"]`);
        assert(m.writeValueAsString(map.values()) == `["d"]`);

        // and for [JACKSON-533], same for concurrent maps
        map = new ConcurrentHashMap!(string, string)();
        map.put("e", "f");
        assert(m.writeValueAsString(map.keySet()) == `["e"]`);
        assert(m.writeValueAsString(map.values()) == `["f"]`);
    }
}

// sort Map entries by key
@("MapSerializationTest.testOrderByKey")
unittest
{
    ObjectMapper m = newJsonMapper(table());
    assert(!m.isEnabled(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS));
    auto map = new LinkedHashMap!(string, Nullable!int)();
    map.put("b", Nullable!int(3));
    map.put("a", Nullable!int(6));
    // by default, no (re)ordering:
    assert(m.writeValueAsString(map) == `{"b":3,"a":6}`);
    // flint.jackson's ObjectMapper has no writer(SerializationFeature).
    version (FlintJacksonObjectWriterConfig)
    {
        // but can be changed
        ObjectWriter sortingW = m.writer(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS);
        assert(sortingW.writeValueAsString(map) == `{"a":6,"b":3}`);
    }
}

// flint.jackson's ObjectMapper has no writer(SerializationFeature), nor ObjectWriter with/without(feature).
version (FlintJacksonObjectWriterConfig)
{
    // related to [databind#1411]
    @("MapSerializationTest.testOrderByWithNulls")
    unittest
    {
        ObjectWriter sortingW = mapper().writer(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS)
            .without(SerializationFeature.FAIL_ON_ORDER_MAP_BY_INCOMPARABLE_KEY);
        // 16-Oct-2016, tatu: but mind the null key, if any
        auto mapWithNullKey = new LinkedHashMap!(string, Nullable!int)();
        mapWithNullKey.put(null, Nullable!int(1));
        mapWithNullKey.put("b", Nullable!int(2));
        // 16-Oct-2016, tatu: By default, null keys are not accepted...
        try
            sortingW.writeValueAsString(mapWithNullKey);
        catch (DatabindException e)
            verifyException(e, "Null key for a Map not allowed");
    }
}

// LIKELY BUG: @JsonPropertyOrder(alphabetic = true) on a Map property is not honoured: Jackson writes
// {"map":{"a":3,"b":2,"c":1}}; flint.jackson keeps insertion order: {"map":{"c":1,"b":2,"a":3}}.
version (FlintJacksonMapPropertyOrder)
{
    // [Databind#335]
    @("MapSerializationTest.testOrderByKeyViaProperty")
    unittest
    {
        auto input = new MapOrderingBean("c", "b", "a");
        const json = mapper().writeValueAsString(input);
        assert(json == a2q("{'map':{'a':3,'b':2,'c':1}}"), json);
    }
}

// flint.jackson has no @JsonTypeInfo/@JsonTypeName (nor mix-ins).
version (FlintJacksonGenericTypes)
{
    import flint.jackson.annotation : JsonTypeInfo, JsonTypeName;

    // for [databind#691]
    @JsonTypeInfo(use : JsonTypeInfo.Id.NAME)
    @JsonTypeName("mymap")
    private final class MapWithTypedValues : LinkedHashMap!(string, string)
    {
    }

    @JsonTypeInfo(use : JsonTypeInfo.Id.CLASS)
    private final class Mixin691
    {
    }

    // [databind#691]
    @("MapSerializationTest.testNullJsonMapping691")
    unittest
    {
        auto input = new MapWithTypedValues();
        input.put("id", "Test");
        input.put("NULL", null);

        const json = mapper().writeValueAsString(input);

        assert(json == a2q("{'@type':'mymap','id':'Test','NULL':null}"), json);
    }

    // [databind#691]
    @("MapSerializationTest.testNullJsonInTypedMap691")
    unittest
    {
        auto map = new HashMap!(string, string)();
        map.put("NULL", null);

        ObjectMapper m = jsonMapperBuilder(table()).addMixIn(classOf!Object, classOf!Mixin691).build();
        const json = m.writeValueAsString(map);
        assert(json == `{"@class":"java.util.HashMap","NULL":null}`, json);
    }
}

// flint.jackson's ObjectMapper has no writer(SerializationFeature); flint.java.util has no concurrent maps.
version (FlintJacksonObjectWriterConfig)
{
    // [databind#1513]
    @("MapSerializationTest.testConcurrentMaps")
    unittest
    {
        import flint.java.util : Hashtable;
        import flint.java.util.concurrent : ConcurrentHashMap, ConcurrentSkipListMap;

        ObjectWriter w = mapper().writer(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS);

        Map!(string, string) input = new ConcurrentSkipListMap!(string, string)();
        input.put("x", "y");
        input.put("a", "b");
        auto json = w.writeValueAsString(input);
        assert(json == a2q("{'a':'b','x':'y'}"), json);

        input = new ConcurrentHashMap!(string, string)();
        input.put("x", "y");
        input.put("a", "b");
        json = w.writeValueAsString(input);
        assert(json == a2q("{'a':'b','x':'y'}"), json);

        // One more: while not technically concurrent map at all, exhibits same issue
        input = new Hashtable!(string, string)();
        input.put("x", "y");
        input.put("a", "b");
        json = w.writeValueAsString(input);
        assert(json == a2q("{'a':'b','x':'y'}"), json);
    }
}

// // // Tests from MapKeyAnnotationsTest

// LIKELY BUG: a Map key's @JsonValue is not used: Jackson writes {"3":true}; flint.jackson writes the key's
// toString(), {"(String)[Wat: 3]":true}.
version (FlintJacksonJsonValueMapKeys)
{
    // [databind#47]
    @("MapSerializationTest.testMapJsonValueKey47")
    unittest
    {
        auto input = new WatMap();
        input.put(new Wat("3"), true);

        const json = mapper().writeValueAsString(input);
        assert(json == a2q("{'3':true}"), json);
    }

    private final class UCString
    {
        private string value;

        this(string v)
        {
            import std.uni : toUpper;

            value = v.toUpper();
        }

        @JsonValue
        string asString()
        {
            return value;
        }
    }

    private enum AbcLC
    {
        A,
        B,
        C,
    }

    // Java's @JsonValue method of AbcLC (D enums have no methods).
    @JsonValue
    private string toLC(AbcLC value)
    {
        import std.conv : to;
        import std.uni : toLower;

        return value.to!string.toLower();
    }

    // [databind#943]
    @("MapSerializationTest.testDynamicMapKeys")
    unittest
    {
        auto stuff = new LinkedHashMap!(Any, Nullable!int)();
        stuff.put(Any.of(AbcLC.B), Nullable!int(3));
        stuff.put(Any.of(new UCString("foo")), Nullable!int(4));
        const json = mapper().writeValueAsString(stuff);
        assert(json == a2q("{'b':3,'FOO':4}"), json);
    }

    // [databind#2306]
    private final class JsonValue2306Key
    {
        @JsonValue
        private string id;

        this(string id)
        {
            this.id = id;
        }
    }

    // [databind#2306]
    @("MapSerializationTest.testMapKeyWithJsonValue")
    unittest
    {
        auto map = new LinkedHashMap!(JsonValue2306Key, string)();
        map.put(new JsonValue2306Key("myId"), "value");
        assert(mapper().writeValueAsString(map) == a2q("{'myId':'value'}"));
    }
}

// LIKELY BUG: @JsonKey is not used for Map keys: Jackson writes {"innerKey":"value"}; flint.jackson writes the
// key's toString().
version (FlintJacksonJsonKey)
{
    // [databind#2871]
    @("MapSerializationTest.testClassAsKey")
    unittest
    {
        auto outer = new Outer2871(new Inner2871("innerKey", "innerValue"));
        auto map = new LinkedHashMap!(Outer2871, string)();
        map.put(outer, "value");
        const actual = mapper().writeValueAsString(map);
        assert(actual == `{"innerKey":"value"}`, actual);
    }
}

// [databind#2871]
@("MapSerializationTest.testClassAsValue")
unittest
{
    auto mapA = new LinkedHashMap!(string, Outer2871)();
    mapA.put("key", new Outer2871(new Inner2871("innerKey", "innerValue")));
    const actual = mapper().writeValueAsString(mapA);
    assert(actual == `{"key":"innerValue"}`, actual);
}

// [databind#2871]
@("MapSerializationTest.testNoKeyOuter")
unittest
{
    auto mapA = new LinkedHashMap!(string, NoKeyOuter)();
    mapA.put("key", new NoKeyOuter(new Inner2871("innerKey", "innerValue")));
    const actual = mapper().writeValueAsString(mapA);
    assert(actual == `{"key":"innerValue"}`, actual);
}

// LIKELY BUG: @JsonKey is not used for Map keys: Jackson writes {"innerKey":"value"}; flint.jackson writes the
// key's toString().
version (FlintJacksonJsonKey)
{
    // [databind#6240]
    @("MapSerializationTest.testClassAsKeyWithGetter")
    unittest
    {
        auto outer = new OuterWithGetter6240(new Inner2871("innerKey", "innerValue"));
        auto map = new LinkedHashMap!(OuterWithGetter6240, string)();
        map.put(outer, "value");
        const json = mapper().writeValueAsString(map);
        assert(json == `{"innerKey":"value"}`, json);
    }
}

// [databind#6240]
@("MapSerializationTest.testClassAsValueWithGetter")
unittest
{
    auto m = mapper();
    auto outer = new OuterWithGetter6240(new Inner2871("innerKey", "innerValue"));
    assert(m.writeValueAsString(outer) == `"innerValue"`);
    auto map = new LinkedHashMap!(string, OuterWithGetter6240)();
    map.put("key", outer);
    assert(m.writeValueAsString(map) == `{"key":"innerValue"}`);
}

// LIKELY BUG: a @JsonKey getter is not kept out of the properties, nor used for Map keys: Jackson writes
// {"name":"value"} and {"a":1}; flint.jackson writes {"id":"a","name":"value"} and the key's toString().
version (FlintJacksonJsonKey)
{
    // [databind#6240]: disabled `@JsonValue` must not expose key getter as property
    @("MapSerializationTest.testKeyOnlyGetter")
    unittest
    {
        auto m = mapper();
        const json = m.writeValueAsString(new KeyOnlyGetter6240());
        assert(json == `{"name":"value"}`, json);
        auto map = new LinkedHashMap!(KeyOnlyGetter6240, Nullable!int)();
        map.put(new KeyOnlyGetter6240(), Nullable!int(1));
        assert(m.writeValueAsString(map) == `{"a":1}`);
    }
}

// [databind#6240]: disabled `@JsonKey` must not disable `@JsonValue`
@("MapSerializationTest.testValueOnlyGetter")
unittest
{
    const json = mapper().writeValueAsString(new ValueOnlyGetter6240());
    assert(json == `"a"`, json);
}

// // // Tests from MapKeySerializationTest

@("MapSerializationTest.testNotKarl")
unittest
{
    const serialized = mapper().writeValueAsString(new NotKarlBean());
    assert(serialized == `{"map":{"Not Karl":1}}`, serialized);
}

// flint.jackson has no @JsonSerialize(keyUsing), ValueSerializer, SimpleModule nor mix-ins.
version (FlintJacksonCustomSerializers)
{
    import flint.jackson.databind.annotation : JsonSerialize;
    import flint.jackson.databind.module_ : SimpleModule;
    import flint.java.lang : classOf;

    private final class KarlSerializer : ValueSerializer!string
    {
        override void serialize(string value, JsonGenerator g, SerializationContext ctxt)
        {
            g.writeName("Karl");
        }
    }

    private final class KarlBean
    {
        @JsonSerialize(keyUsing : classOf!KarlSerializer)
        Map!(string, Nullable!int) map;

        this()
        {
            map = new HashMap!(string, Nullable!int)();
            map.put("Not Karl", Nullable!int(1));
        }
    }

    private enum OuterEnum
    {
        inner,
    }

    private enum ABCKey
    {
        A,
        B,
        C,
    }

    private final class ABCMapWrapper
    {
        Map!(ABCKey, string) stuff;

        this()
        {
            stuff = new HashMap!(ABCKey, string)();
            stuff.put(ABCKey.B, "bar");
        }
    }

    @JsonSerialize(keyUsing : classOf!ABCKeySerializer)
    private enum ABCMixin
    {
        none,
    }

    private final class BAR(T)
    {
        T value;

        this(T value)
        {
            this.value = value;
        }

        @JsonValue
        T getValue()
        {
            return value;
        }

        override string toString() const
        {
            import std.conv : to;

            return typeof(this).stringof ~ ", value:" ~ value.to!string;
        }
    }

    private final class ABCKeySerializer : ValueSerializer!ABCKey
    {
        override void serialize(ABCKey value, JsonGenerator g, SerializationContext ctxt)
        {
            import std.conv : to;

            g.writeName("xxx" ~ value.to!string);
        }
    }

    private final class NullKeySerializer : ValueSerializer!Any
    {
        private string _null;

        this(string s)
        {
            _null = s;
        }

        override void serialize(Any value, JsonGenerator g, SerializationContext ctxt)
        {
            g.writeName(_null);
        }
    }

    private final class NullValueSerializer : ValueSerializer!Any
    {
        private string _null;

        this(string s)
        {
            _null = s;
        }

        override void serialize(Any value, JsonGenerator g, SerializationContext ctxt)
        {
            g.writeString(_null);
        }
    }

    @("MapSerializationTest.testKarl")
    unittest
    {
        const serialized = mapper().writeValueAsString(new KarlBean());
        assert(serialized == `{"map":{"Karl":1}}`, serialized);
    }

    // [databind#75]: caching of KeySerializers
    @("MapSerializationTest.testBoth")
    unittest
    {
        // Let's NOT use shared one, to ensure caching starts from clean slate
        auto m = newJsonMapper(table());
        const value1 = m.writeValueAsString(new NotKarlBean());
        assert(value1 == `{"map":{"Not Karl":1}}`);
        const value2 = m.writeValueAsString(new KarlBean());
        assert(value2 == `{"map":{"Karl":1}}`);
    }

    // Test custom key serializer for enum
    @("MapSerializationTest.testCustomForEnum")
    unittest
    {
        // cannot use shared mapper as we are registering a module
        auto mod = new SimpleModule("test");
        mod.addKeySerializer(classOf!ABCKey, new ABCKeySerializer());
        ObjectMapper m = jsonMapperBuilder(table()).addModule(mod).build();

        const json = m.writeValueAsString(new ABCMapWrapper());
        assert(json == `{"stuff":{"xxxB":"bar"}}`, json);
    }

    @("MapSerializationTest.testCustomNullSerializers")
    unittest
    {
        auto mod = new SimpleModule().setDefaultNullKeySerializer(new NullKeySerializer("NULL-KEY"))
            .setDefaultNullValueSerializer(new NullValueSerializer("NULL"));
        ObjectMapper m = jsonMapperBuilder(table()).addModule(mod).build();
        auto input = new HashMap!(string, Nullable!int)();
        input.put(null, Nullable!int(3));
        auto json = m.writeValueAsString(input);
        assert(json == `{"NULL-KEY":3}`, json);
        json = m.writeValueAsString([Any.of(1), Any.init, Any.of(true)]);
        assert(json == `[1,"NULL",true]`, json);
    }

    @("MapSerializationTest.testCustomEnumInnerMapKey")
    unittest
    {
        import flint.java.util : EnumMap;
        import flint.jackson.databind.node : JsonNode;

        auto outerMap = new HashMap!(OuterEnum, Any)();
        Map!(ABCKey, Map!(string, string)) map = new EnumMap!(ABCKey, Map!(string, string))(classOf!ABCKey);
        auto innerMap = new HashMap!(string, string)();
        innerMap.put("one", "1");
        map.put(ABCKey.A, innerMap);
        outerMap.put(OuterEnum.inner, Any.of(map));
        auto mod = new SimpleModule("test").setMixInAnnotation(classOf!ABCKey, classOf!ABCMixin)
            .addKeySerializer(classOf!ABCKey, new ABCKeySerializer());
        ObjectMapper m = jsonMapperBuilder(table()).addModule(mod).build();

        JsonNode tree = m.convertValue!JsonNode(outerMap);

        JsonNode innerNode = tree.get("inner");
        const key = innerNode.propertyNames()[0];
        assert(key == "xxxA", key);
    }

    // [databind#838]
    @("MapSerializationTest.testUnWrappedMapWithKeySerializer")
    unittest
    {
        import flint.jackson.annotation : JsonInclude;
        import flint.jackson.databind : DateTimeFeature, DeserializationFeature, TypeReference;

        auto mod = new SimpleModule("test");
        mod.addKeySerializer(classOf!ABCKey, new ABCKeySerializer());
        ObjectMapper m = jsonMapperBuilder(table()).changeDefaultPropertyInclusion(JsonInclude.Include.NON_EMPTY)
            .enable(DeserializationFeature.ACCEPT_EMPTY_STRING_AS_NULL_OBJECT)
            .disable(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS).addModule(mod).build();
        auto stuff = new HashMap!(ABCKey, Object)();
        stuff.put(ABCKey.B, new BAR!string("bar"));
        const json = m.writerFor(new TypeReference!(Map!(ABCKey, Object))()).writeValueAsString(stuff);
        assert(json == `{"xxxB":"bar"}`, json);
    }

    // [databind#838]
    @("MapSerializationTest.testUnWrappedMapWithDefaultType")
    unittest
    {
        import flint.jackson.annotation : JsonTypeInfo;
        import flint.jackson.databind : DefaultTyping, TypeReference;
        import flint.jackson.databind.jsontype : DefaultTypeResolverBuilder, NoCheckSubTypeValidator;

        auto mod = new SimpleModule("test");
        mod.addKeySerializer(classOf!ABCKey, new ABCKeySerializer());
        auto typer = new DefaultTypeResolverBuilder(NoCheckSubTypeValidator.instance,
                DefaultTyping.NON_FINAL, JsonTypeInfo.As.PROPERTY, JsonTypeInfo.Id.NAME, null).typeIdVisibility(true);
        ObjectMapper m = jsonMapperBuilder(table()).addModule(mod).setDefaultTyping(typer).build();

        auto stuff = new HashMap!(ABCKey, string)();
        stuff.put(ABCKey.B, "bar");
        const json = m.writerFor(new TypeReference!(Map!(ABCKey, string))()).writeValueAsString(stuff);
        assert(json == `{"@type":"HashMap","xxxB":"bar"}`, json);
    }
}

// flint.jackson has no key serializer for `Class` values (ClassRef).
version (FlintJacksonClassValues)
{
    // [databind#682]
    @("MapSerializationTest.testClassKey")
    unittest
    {
        import flint.java.lang : ClassRef, classOf;

        auto map = new LinkedHashMap!(ClassRef, Nullable!int)();
        map.put(classOf!string, Nullable!int(2));
        const json = mapper().writeValueAsString(map);
        assert(json == a2q("{'java.lang.String':2}"), json);
    }
}

// LIKELY BUG: binary Map keys are not Base64-encoded: Jackson writes {"map":{"AQIDBAU=":"stuff"}}; flint.jackson
// writes {"map":{"immutable(byte)[]":"stuff"}}.
version (FlintJacksonBinaryMapKeys)
{
    // [databind#1552]
    @("MapSerializationTest.testMapsWithBinaryKeys")
    unittest
    {
        import std.base64 : Base64;

        auto m = mapper();
        immutable(byte)[] binary = [1, 2, 3, 4, 5];

        // First, using wrapper
        auto input = new MapWrapper!(immutable(byte)[], string)(binary, "stuff");
        const expBase64 = Base64.encode(cast(const(ubyte)[]) binary).idup;

        auto json = m.writeValueAsString(input);
        assert(json == a2q("{'map':{'" ~ expBase64 ~ "':'stuff'}}"), json);

        // and then dynamically..
        auto map = new LinkedHashMap!(immutable(byte)[], string)();
        map.put(binary, "xyz");
        json = m.writeValueAsString(map);
        assert(json == a2q("{'" ~ expBase64 ~ "':'xyz'}"), json);
    }
}

// [databind#1679]
@("MapSerializationTest.testMapKeyRecursion1679")
unittest
{
    auto objectMap = new HashMap!(Object, Any)();
    objectMap.put(new Object(), Any.of("foo"));
    const json = mapper().writeValueAsString(objectMap);
    assert(json !is null);
}

// // // Tests from MapSerializationSorted4773Test

// flint.jackson's ObjectWriter has no with(SerializationFeature); flint.java.util has no Currency.
version (FlintJacksonObjectWriterConfig)
{
    private final class IncomparableContainer4773
    {
        Map!(Currency, string) exampleMap;

        this()
        {
            exampleMap = new HashMap!(Currency, string)();
        }
    }

    // [databind#4773]
    @("MapSerializationTest.testSerializationFailureWhenEnabledWithIncomparableKeys")
    unittest
    {
        import flint.java.util : Currency;

        auto t = table();
        t.add(descriptorOf!IncomparableContainer4773());
        auto entity = new IncomparableContainer4773();
        entity.exampleMap.put(Currency.getInstance("GBP"), "GBP_TEXT");
        entity.exampleMap.put(Currency.getInstance("AUD"), "AUD_TEXT");

        auto e = assertThrows!InvalidDefinitionException(() {
            jsonMapperBuilder(t).configure(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS, true).build().writer()
                .with_(SerializationFeature.FAIL_ON_ORDER_MAP_BY_INCOMPARABLE_KEY).writeValueAsString(entity);
        });
        verifyException(e, "Cannot order Map entries by key of incomparable type");
    }
}

// LIKELY BUG: ORDER_MAP_ENTRIES_BY_KEYS is not honoured: Jackson writes the keys sorted ('1' to '5'); flint.jackson
// writes them in iteration order ('5','1','3','4','2').
version (FlintJacksonOrderMapEntriesByKeys)
{
    // [databind#4773]
    @("MapSerializationTest.testSerializationWithGenericObjectKeys")
    unittest
    {
        auto entity = new ObjectContainer4773();
        entity.exampleMap.put(Any.of(5), "N_TEXT");
        entity.exampleMap.put(Any.of(1), "GBP_TEXT");
        entity.exampleMap.put(Any.of(3), "T_TEXT");
        entity.exampleMap.put(Any.of(4), "AUD_TEXT");
        entity.exampleMap.put(Any.of(2), "KRW_TEXT");

        const jsonResult = sortingMapper().writeValueAsString(entity);

        assert(jsonResult == a2q("{'exampleMap':{" ~ "'1':'GBP_TEXT'," ~ "'2':'KRW_TEXT',"
                ~ "'3':'T_TEXT'," ~ "'4':'AUD_TEXT'," ~ "'5':'N_TEXT'}}"), jsonResult);
    }
}

// flint.jackson's ObjectWriter has no with(SerializationFeature).
version (FlintJacksonObjectWriterConfig)
{
    // [databind#4773]
    @("MapSerializationTest.testSerWithNullType")
    unittest
    {
        auto entity = new ObjectContainer4773();
        entity.exampleMap.put(Any.init, "AUD_TEXT");

        auto e = assertThrows!InvalidDefinitionException(() {
            sortingMapper().writer().with_(SerializationFeature.FAIL_ON_ORDER_MAP_BY_INCOMPARABLE_KEY)
                .writeValueAsString(entity);
        });
        verifyException(e, "Cannot order Map entries by key of incomparable type [null]");
    }
}
