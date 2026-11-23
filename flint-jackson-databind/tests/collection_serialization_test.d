/++
Ported from FasterXML/jackson-databind 3.1.8,
src/test/java/tools/jackson/databind/ser/jdk/CollectionSerializationTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit assertions become D asserts; the beans are D classes whose Flint AOT
descriptors the mapper is given; `Collection<Object>` is `Collection!Any`; `MAPPER.createParser` is the mapper's
`tokenStreamFactory().createParser`, and the `StringWriter` and `Reader` variants of testBigCollection write into a
`ByteArrayBuilder` and parse a String; `writeAndMap` reads into a `LinkedHashMap!(string, Any)`. Cases that need JDK
types flint.java lacks (LinkedList, TreeSet, EnumMap), Iterable/Iterator values, custom serializers, default typing
or WRITE_EMPTY_JSON_ARRAYS wait behind versions.
+/
module collection_serialization_test;

import databind_test_util : a2q, jsonMapperBuilder, newJsonMapper;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.core : JsonParser, JsonToken;
import flint.jackson.core.util : ByteArrayBuilder;
import flint.jackson.databind : MapperFeature, ObjectMapper, SerializationFeature;
import flint.java.util : ArrayList, Collection, LinkedHashMap, List;

@safe:

private enum Key
{
    A,
    B,
    C
}

// Field-based simple bean with a single property, "values"
private final class CollectionBean
{
    Collection!Any values;

    this(Collection!Any c)
    {
        values = c;
    }
}

private final class EmptyListBean
{
    List!string empty;

    this()
    {
        empty = new ArrayList!string();
    }
}

private final class EmptyArrayBean
{
    string[] empty = [];
}

private final class StaticListWrapper
{
    protected List!string list;

    this(string[] v...)
    {
        list = new ArrayList!string(v);
    }

    List!string getList()
    {
        return list;
    }

    void setList(List!string l)
    {
        list = l;
    }
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!Key(), descriptorOf!CollectionBean(), descriptorOf!EmptyListBean(),
        descriptorOf!EmptyArrayBean(), descriptorOf!StaticListWrapper(),
        descriptorOf!(int[])(), descriptorOf!(string[])(), descriptorOf!(List!string)(),
        descriptorOf!(ArrayList!string)(), descriptorOf!(ArrayList!int)(),
        descriptorOf!(Collection!Any)(), descriptorOf!(ArrayList!Any)(),
        descriptorOf!(LinkedHashMap!(string, Any))()
    ])
        t.add(d);
    return t;
}

private ObjectMapper mapper()
{
    return newJsonMapper(table());
}

// DatabindTestUtil.writeAndMap.
private LinkedHashMap!(string, Any) writeAndMap(T)(ObjectMapper m, T value)
{
    const str = m.writeValueAsString(value);
    return m.readValue!(LinkedHashMap!(string, Any))(str);
}

// Verify the parser reads `[0, 1, ..., count - 1]`.
private void verifyInts(JsonParser p, int count)
{
    assert(p.nextToken() == JsonToken.START_ARRAY);
    foreach (i; 0 .. count)
    {
        assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
        assert(p.getIntValue() == i);
    }
    assert(p.nextToken() == JsonToken.END_ARRAY);
    p.close();
}

@("CollectionSerializationTest.testCollections")
unittest
{
    auto m = mapper();
    // Let's try different collections, arrays etc
    enum entryLen = 98;

    auto ints = new int[entryLen];
    foreach (i; 0 .. entryLen)
        ints[i] = i;
    verifyInts(m.tokenStreamFactory().createParser(m.writeValueAsString(ints)), entryLen);

    auto c = new ArrayList!int();
    foreach (i; 0 .. entryLen)
        c.add(i);
    verifyInts(m.tokenStreamFactory().createParser(m.writeValueAsString(c)), entryLen);

    // flint.java.util has no LinkedList or TreeSet.
    version (FlintJacksonJdkTypes)
    {
        Collection!int linked = new LinkedList!int();
        Collection!int tree = new TreeSet!int(); // has to be ordered
        foreach (i; 0 .. entryLen)
        {
            linked.add(i);
            tree.add(i);
        }
        verifyInts(m.tokenStreamFactory().createParser(m.writeValueAsString(linked)), entryLen);
        verifyInts(m.tokenStreamFactory().createParser(m.writeValueAsString(tree)), entryLen);
    }
}

@("CollectionSerializationTest.testBigCollection")
unittest
{
    auto m = mapper();
    enum COUNT = 9999;
    auto value = new ArrayList!int();
    foreach (i; 0 .. COUNT + 1)
        value.add(i);
    // Let's test using 3 main variants...
    foreach (mode; 0 .. 3)
    {
        JsonParser p;
        switch (mode)
        {
        case 0:
            const data = m.writeValueAsBytes(value);
            p = m.tokenStreamFactory().createParser(data);
            break;
        case 1:
            auto sw = new ByteArrayBuilder();
            m.writeValue(sw, Any.of(value));
            p = m.tokenStreamFactory().createParser((cast(const(char)[]) sw.toByteArray()).idup);
            break;
        default:
            const str = m.writeValueAsString(value);
            p = m.tokenStreamFactory().createParser(str);
            break;
        }
        verifyInts(p, COUNT + 1);
    }
}

// flint.java.util has no EnumMap.
version (FlintJacksonJdkTypes)
{
    import flint.java.util : Map;

    private final class EnumMapBean
    {
        EnumMap!(Key, string) _map;

        this(EnumMap!(Key, string) m)
        {
            _map = m;
        }

        EnumMap!(Key, string) getMap()
        {
            return _map;
        }
    }

    @("CollectionSerializationTest.testEnumMap")
    unittest
    {
        auto map = new EnumMap!(Key, string)();
        map.put(Key.B, "xyz");
        map.put(Key.C, "abc");
        // assuming EnumMap uses enum entry order, which I think is true...
        const json = mapper().writeValueAsString(map);
        assert(json == `{"B":"xyz","C":"abc"}`, json);
    }

    @("CollectionSerializationTest.testEmptyBeanEnumMap")
    unittest
    {
        auto map = new EnumMap!(Key, string)();
        auto b = new EnumMapBean(map);
        auto result = writeAndMap(mapper(), b);

        assert(result.size() == 1);
        assert(result.containsKey("map"));
        // we deserialized to untyped, not back to bean, so:
        auto map2 = result.get("map").get!(Map!(Any, Any))();
        assert(map2 !is null);
        assert(map2.size() == 0);
    }

    // Should also be able to serialize null EnumMaps as expected
    @("CollectionSerializationTest.testNullBeanEnumMap")
    unittest
    {
        auto b = new EnumMapBean(null);
        auto result = writeAndMap(mapper(), b);

        assert(result.size() == 1);
        assert(result.containsKey("map"));
        assert(result.get("map").isNull());
    }
}

// An untyped JSON array binds to a JsonNode, where Jackson builds an ArrayList (UntypedObjectDeserializer).
version (FlintJacksonUntypedCollections)
{
    // Test that checks that empty collections are properly serialized
    // when they are Bean properties
    @("CollectionSerializationTest.testEmptyBeanCollection")
    unittest
    {
        Collection!Any x = new ArrayList!Any();
        x.add(Any.of("foobar"));
        auto cb = new CollectionBean(x);
        auto result = writeAndMap(mapper(), cb);
        assert(result.size() == 1);
        assert(result.containsKey("values"));
        auto x2 = result.get("values").get!(Collection!Any)();
        assert(x2 !is null);
        assert(x.equals(cast(Object) x2));
    }
}

@("CollectionSerializationTest.testNullBeanCollection")
unittest
{
    auto cb = new CollectionBean(null);
    auto result = writeAndMap(mapper(), cb);
    assert(result.size() == 1);
    assert(result.containsKey("values"));
    assert(result.get("values").isNull());
}

// flint.jackson has no @JsonSerialize(using) nor custom StdSerializer subclasses.
version (FlintJacksonCustomSerializers)
{
    import databind_test_util : q;
    import flint.jackson.core : JsonGenerator;
    import flint.java.lang : Iterable, classOf;
    import flint.java.util : Arrays;

    @JsonSerialize(using : classOf!ListSerializer)
    private final class PseudoList : ArrayList!string
    {
        this(string[] values...)
        {
            super(values);
        }
    }

    private final class ListSerializer : StdSerializer!(List!string)
    {
        override void serialize(List!string value, JsonGenerator gen, SerializationContext provider)
        {
            // just use standard List.toString(), output as JSON String
            gen.writeString(value.toString());
        }
    }

    private final class IterA
    {
        string unexpected = "Bye.";
    }

    private final class IterB
    {
        @JsonSerialize(as : classOf!(Iterable!IterA), contentUsing:
                classOf!IterASerializer)
        List!IterA list;

        this()
        {
            list = Arrays.asList(new IterA());
        }
    }

    private final class IterASerializer : ValueSerializer!IterA
    {
        override void serialize(IterA a, JsonGenerator g, SerializationContext provider)
        {
            g.writeStartArray();
            g.writeString("Hello world.");
            g.writeEndArray();
        }
    }

    @("CollectionSerializationTest.testListSerializer")
    unittest
    {
        auto m = mapper();
        assert(m.writeValueAsString(new PseudoList("ab", "cd", "ef")) == q("[ab, cd, ef]"));
        assert(m.writeValueAsString(new PseudoList()) == q("[]"));
    }

    // [databind#358]
    @("CollectionSerializationTest.testIterable358")
    unittest
    {
        const json = mapper().writeValueAsString(new IterB());
        assert(json == `{"list":[["Hello world."]]}`, json);
    }
}

@("CollectionSerializationTest.testEmptyListOrArray")
unittest
{
    auto m = mapper();
    // by default, empty lists serialized normally
    auto list = new EmptyListBean();
    auto array = new EmptyArrayBean();
    assert(m.isEnabled(SerializationFeature.WRITE_EMPTY_JSON_ARRAYS));
    assert(m.writeValueAsString(list) == `{"empty":[]}`);
    assert(m.writeValueAsString(array) == `{"empty":[]}`);

    // LIKELY BUG: with WRITE_EMPTY_JSON_ARRAYS disabled Jackson writes {} for both; Flint writes {"empty":[]}.
    version (FlintJacksonWriteEmptyJsonArrays)
    {
        // note: value of setting may be cached when constructing serializer, need a new instance
        auto m2 = jsonMapperBuilder(table()).configure(SerializationFeature.WRITE_EMPTY_JSON_ARRAYS, false).build();
        assert(m2.writeValueAsString(list) == "{}", m2.writeValueAsString(list));
        assert(m2.writeValueAsString(array) == "{}", m2.writeValueAsString(array));
    }
}

@("CollectionSerializationTest.testStaticList")
unittest
{
    // First: au naturel
    auto w = new StaticListWrapper("a", "b", "c");
    const json = mapper().writeValueAsString(w);
    assert(json == a2q("{'list':['a','b','c']}"), json);

    // flint.jackson has no default typing (activateDefaultTyping, type ids).
    version (FlintJacksonGenericTypes)
    {
        import std.format : format;

        // but then with default typing
        auto typed = jsonMapperBuilder(table()).activateDefaultTyping(NoCheckSubTypeValidator.instance,
                DefaultTyping.NON_FINAL).build();
        const typedJson = typed.writeValueAsString(w);
        assert(typedJson == a2q(format("['%s',{'list':['%s',['a','b','c']]}]", typeid(w).name,
                typeid(cast(Object) w.list).name)));
    }
}

// flint.jackson serializes neither Iterator nor Iterable values that are not collections.
version (FlintJacksonIterableTypes)
{
    import flint.jackson.annotation : JsonFilter;
    import flint.java.lang : Iterable;
    import flint.java.util : Iterator;
    import std.typecons : Nullable;

    // Java's default Iterable.forEach, and D's foreach, over iterator().
    private mixin template IterableDefaults(T)
    {
        void forEach(void delegate(T) @safe action)
        {
            for (auto it = iterator(); it.hasNext();)
                action(it.next());
        }

        int opApply(scope int delegate(T) @safe dg)
        {
            for (auto it = iterator(); it.hasNext();)
                if (const result = dg(it.next()))
                    return result;
            return 0;
        }
    }

    private final class IterableWrapper : Iterable!(Nullable!int)
    {
        List!(Nullable!int) _ints;

        this(int[] values)
        {
            _ints = new ArrayList!(Nullable!int)();
            foreach (i; values)
                _ints.add(Nullable!int(i));
        }

        Iterator!(Nullable!int) iterator()
        {
            return _ints.iterator();
        }

        mixin IterableDefaults!(Nullable!int);
    }

    @JsonSerialize(typing : JsonSerialize.Typing.STATIC)
    private final class BeanWithIterable
    {
        private ArrayList!string values;

        this()
        {
            values = new ArrayList!string();
            values.add("value");
        }

        Iterable!string getValues()
        {
            return values;
        }
    }

    private final class BeanWithIterator
    {
        private ArrayList!string values;

        this()
        {
            values = new ArrayList!string();
            values.add("itValue");
        }

        Iterator!string getValues()
        {
            return values.iterator();
        }
    }

    private class IntIterable : Iterable!(Nullable!int)
    {
        Iterator!(Nullable!int) iterator()
        {
            return new IntIterator(1, 3);
        }

        mixin IterableDefaults!(Nullable!int);
    }

    private final class IntIterator : Iterator!(Nullable!int)
    {
        int i;
        const int last;

        this(int first, int last)
        {
            i = first;
            this.last = last;
        }

        bool hasNext()
        {
            return i <= last;
        }

        Nullable!int next()
        {
            return Nullable!int(i++);
        }

        void remove()
        {
        }

        int getX()
        {
            return 13;
        }
    }

    // [databind#2390]
    @JsonFilter("default")
    private final class IntIterable2390 : IntIterable
    {
    }

    private ObjectMapper staticMapper()
    {
        return jsonMapperBuilder(table()).enable(MapperFeature.USE_STATIC_TYPING).build();
    }

    @("CollectionSerializationTest.testIterator")
    unittest
    {
        auto m = mapper();
        auto l = new ArrayList!(Nullable!int)();
        l.add(Nullable!int(1));
        l.add(Nullable!int.init);
        l.add(Nullable!int(-9));
        l.add(Nullable!int(0));

        assert(m.writeValueAsString(l.iterator()) == "[1,null,-9,0]");
        l.clear();
        assert(m.writeValueAsString(l.iterator()) == "[]");
    }

    @("CollectionSerializationTest.testIterable")
    unittest
    {
        assert(mapper().writeValueAsString(new IterableWrapper([1, 2, 3])) == "[1,2,3]");
    }

    @("CollectionSerializationTest.testWithIterable")
    unittest
    {
        auto staticTyped = staticMapper();
        assert(staticTyped.writeValueAsString(new BeanWithIterable()) == `{"values":["value"]}`);
        assert(staticTyped.writeValueAsString(new IntIterable()) == "[1,2,3]");

        auto m = mapper();
        assert(m.writeValueAsString(new BeanWithIterable()) == `{"values":["value"]}`);
        assert(m.writeValueAsString(new IntIterable()) == "[1,2,3]");

        // 17-Apr-2018, tatu: Turns out we may need "fresh" mapper for some failures?
        auto freshMapper = new ObjectMapper();
        assert(freshMapper.writeValueAsString(new BeanWithIterable()) == `{"values":["value"]}`);
        assert(freshMapper.writeValueAsString(new IntIterable()) == "[1,2,3]");
    }

    @("CollectionSerializationTest.testWithIterator")
    unittest
    {
        assert(staticMapper().writeValueAsString(new BeanWithIterator()) == `{"values":["itValue"]}`);

        // [databind#1977]
        auto numbersList = new ArrayList!Any();
        numbersList.add(Any.of(1));
        numbersList.add(Any.of(0.25));
        const json = mapper().writeValueAsString(numbersList.iterator());
        assert(json == "[1,0.25]", json);
    }

    // [databind#2390]
    @("CollectionSerializationTest.testIterableWithAnnotation")
    unittest
    {
        assert(staticMapper().writeValueAsString(new IntIterable2390()) == "[1,2,3]");
    }
}
