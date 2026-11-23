/++
Ported from FasterXML/jackson-databind 3.1.8, src/test/java/tools/jackson/databind/ser/SerializationOrderTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit assertions become D asserts; each bean's Flint AOT descriptor comes from
`descriptorOf!T`, with the constructor descriptors Flint AOT emits for parameterized constructors (and their
`@JsonCreator`/`@JsonProperty` annotations) built by hand, a subclass's descriptor carrying its superclass's
properties, and BeanFor268's `@JsonProperty`-annotated non-getter methods added as read-only properties.
Mix-ins wait behind a version.
+/
module serialization_order_test;

import databind_test_util : a2q, jsonMapperBuilder, newJsonMapper;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : ConstructorDescriptor, Descriptor, DescriptorTable,
    MergedAnnotation, ParameterDescriptor, PropertyDescriptor, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.jackson.annotation : JsonCreator, JsonProperty, JsonPropertyOrder;
import flint.jackson.databind : JsonMapper, MapperFeature;

@safe:

private final class BeanWithCreator
{
    int a;
    int b;
    int c;

    @JsonCreator
    this(@JsonProperty("c") int c, @JsonProperty("a") int a)
    {
        this.a = a;
        this.c = c;
    }
}

@JsonPropertyOrder(["c", "a", "b"])
private class BeanWithOrder
{
    int d, b, a, c;

    this(int a, int b, int c, int d)
    {
        this.a = a;
        this.b = b;
        this.c = c;
        this.d = d;
    }
}

@JsonPropertyOrder(value: ["d"], alphabetic: true)
private final class SubBeanWithOrder : BeanWithOrder
{
    this(int a, int b, int c, int d)
    {
        super(a, b, c, d);
    }
}

@JsonPropertyOrder([
    "b", "a",
    // note: including non-existant properties is fine (has no effect, but not an error)
    "foobar", "c"
])
private final class OrderMixIn
{
}

@JsonPropertyOrder(["a", "b", "x", "z"])
private final class BeanFor268
{
    @JsonProperty("a")
    string xA = "a";
    @JsonProperty("z")
    string aZ = "z";

    @JsonProperty("b")
    string xB()
    {
        return "b";
    }

    @JsonProperty("x")
    string aX()
    {
        return "x";
    }
}

private final class BeanFor459
{
    int d = 4;
    int c = 3;
    int b = 2;
    int a = 1;
}

// For [databind#311]
@JsonPropertyOrder(alphabetic: true)
private final class BeanForGH311
{
    private const int a;
    private const int b;

    @JsonCreator
    this(@JsonProperty("b") int b, @JsonProperty("a") int a)
    { //b and a are out of order, although alphabetic = true
        this.a = a;
        this.b = b;
    }

    int getA() const
    {
        return a;
    }

    int getB() const
    {
        return b;
    }
}

// We'll expect ordering of "FUBAR"
@JsonPropertyOrder(["f"])
private final class OrderingByIndexBean
{
    int r;
    int a;

    @JsonProperty(index: 1)
    int b;

    @JsonProperty(index: 0)
    int u;

    int f;
}

// For [databind#2879]
@JsonPropertyOrder(["a", "c"])
private final class BeanFor2879
{
    int c;
    int b;
    int a;

    @JsonCreator
    this(@JsonProperty("a") int a, @JsonProperty("b") int b, @JsonProperty("c") int c)
    {
        this.a = a;
        this.b = b;
        this.c = c;
    }
}

// For [databind#2879]
private final class BeanForStrictOrdering
{
    private const int a;
    private int b;
    private const int c;

    @JsonCreator
    this(@JsonProperty("c") int c, @JsonProperty("a") int a)
    { //b and a are out of order, although alphabetic = true
        this.a = a;
        this.c = c;
    }

    int getA() const
    {
        return a;
    }

    int getB() const
    {
        return b;
    }

    int getC() const
    {
        return c;
    }
}

// For [databind#5918]
private final class BeanForGH5918
{
    private string notes;
    private string firstName;
    private string lastName;

    @JsonCreator
    this(@JsonProperty("lastName") string lastName, @JsonProperty("firstName") string firstName)
    {
        this.firstName = firstName;
        this.lastName = lastName;
    }

    string getNotes()
    {
        return notes;
    }

    void setNotes(string notes)
    {
        this.notes = notes;
    }

    string getFirstName()
    {
        return firstName;
    }

    string getLastName()
    {
        return lastName;
    }
}

// The annotations Flint AOT merges onto a constructor and its parameters.
private MergedAnnotation[] creatorAnnotation()
{
    return [MergedAnnotation(typeNameOf!JsonCreator, Any.of(JsonCreator()), 0)];
}

private ParameterDescriptor named(string name, string type)
{
    return ParameterDescriptor(name, type, [
        MergedAnnotation(typeNameOf!JsonProperty, Any.of(JsonProperty(name)), 0)
    ]);
}

private ParameterDescriptor plain(string name, string type)
{
    return ParameterDescriptor(name, type);
}

private ParameterDescriptor[] fourInts()
{
    return [plain("a", "int"), plain("b", "int"), plain("c", "int"), plain("d", "int")];
}

private Descriptor withCreator(Descriptor d, ConstructorDescriptor creator)
{
    d.constructors = creator ~ d.constructors;
    return d;
}

private Any newBeanFor2879(scope Any[] v)
{
    return Any.of(new BeanFor2879(v[0].get!int(), v[1].get!int(), v[2].get!int()));
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    t.add(withCreator(descriptorOf!BeanWithCreator(), ConstructorDescriptor([
        named("c", "int"), named("a", "int")
    ], creatorAnnotation(), (scope Any[] v) => Any.of(new BeanWithCreator(v[0].get!int(), v[1].get!int())))));
    t.add(withCreator(descriptorOf!BeanWithOrder(), ConstructorDescriptor(fourInts(), null,
            (scope Any[] v) => Any.of(new BeanWithOrder(v[0].get!int(), v[1].get!int(),
            v[2].get!int(), v[3].get!int())))));
    auto sub = withCreator(descriptorOf!SubBeanWithOrder(), ConstructorDescriptor(fourInts(),
            null, (scope Any[] v) => Any.of(new SubBeanWithOrder(v[0].get!int(), v[1].get!int(),
            v[2].get!int(), v[3].get!int()))));
    sub.properties = descriptorOf!BeanWithOrder().properties ~ sub.properties;
    t.add(sub);
    t.add(beanFor268Descriptor());
    t.add(descriptorOf!BeanFor459());
    t.add(withCreator(descriptorOf!BeanForGH311(), ConstructorDescriptor([
        named("b", "int"), named("a", "int")
    ], creatorAnnotation(), (scope Any[] v) => Any.of(new BeanForGH311(v[0].get!int(), v[1].get!int())))));
    t.add(descriptorOf!OrderingByIndexBean());
    t.add(withCreator(descriptorOf!BeanFor2879(), ConstructorDescriptor([
        named("a", "int"), named("b", "int"), named("c", "int")
    ], creatorAnnotation(), &newBeanFor2879)));
    t.add(withCreator(descriptorOf!BeanForStrictOrdering(), ConstructorDescriptor([
        named("c", "int"), named("a", "int")
    ], creatorAnnotation(), (scope Any[] v) => Any.of(new BeanForStrictOrdering(v[0].get!int(), v[1].get!int())))));
    t.add(withCreator(descriptorOf!BeanForGH5918(), ConstructorDescriptor([
        named("lastName", "string"), named("firstName", "string")
    ], creatorAnnotation(), (scope Any[] v) => Any.of(new BeanForGH5918(v[0].get!string(), v[1].get!string())))));
    return t;
}

// BeanFor268's annotated methods are properties named after the methods, renamed by their @JsonProperty.
private Descriptor beanFor268Descriptor()
{
    auto d = descriptorOf!BeanFor268();
    d.properties ~= PropertyDescriptor("xB", "string", [
        MergedAnnotation(typeNameOf!JsonProperty, Any.of(JsonProperty("b")), 0)
    ], (ref Any self) => Any.of(self.get!BeanFor268().xB()), null);
    d.properties ~= PropertyDescriptor("aX", "string", [
        MergedAnnotation(typeNameOf!JsonProperty, Any.of(JsonProperty("x")), 0)
    ], (ref Any self) => Any.of(self.get!BeanFor268().aX()), null);
    return d;
}

private JsonMapper mapper()
{
    return newJsonMapper(table());
}

private JsonMapper alphaMapper()
{
    return jsonMapperBuilder(table()).enable(MapperFeature.SORT_PROPERTIES_ALPHABETICALLY).build();
}

@("SerializationOrderTest.testImplicitOrderByCreator")
unittest
{
    assert(mapper().writeValueAsString(new BeanWithCreator(1, 2)) == `{"c":1,"a":2,"b":0}`);
}

@("SerializationOrderTest.testExplicitOrder")
unittest
{
    assert(mapper().writeValueAsString(new BeanWithOrder(1, 2, 3, 4)) == `{"c":3,"a":1,"b":2,"d":4}`);
}

@("SerializationOrderTest.testAlphabeticOrder")
unittest
{
    assert(mapper().writeValueAsString(new SubBeanWithOrder(1, 2, 3, 4)) == `{"d":4,"a":1,"b":2,"c":3}`);
}

// flint.jackson has no mix-in annotations (MapperBuilder.addMixIn).
version (FlintJacksonMixIns)
{
    @("SerializationOrderTest.testOrderWithMixins")
    unittest
    {
        auto mapper = jsonMapperBuilder(table()).addMixIn!(BeanWithOrder, OrderMixIn)().build();
        assert(mapper.writeValueAsString(new BeanWithOrder(1, 2, 3, 4)) == `{"b":2,"a":1,"c":3,"d":4}`);
    }
}

@("SerializationOrderTest.testOrderWrt268")
unittest
{
    assert(mapper().writeValueAsString(new BeanFor268()) == `{"a":"a","b":"b","x":"x","z":"z"}`);
}

@("SerializationOrderTest.testOrderWithFeature")
unittest
{
    assert(alphaMapper().writeValueAsString(new BeanFor459()) == `{"a":1,"b":2,"c":3,"d":4}`);
}

// [databind#2879]: verify that Creator properties never override explicit
//   order
@("SerializationOrderTest.testCreatorVsExplicitOrdering")
unittest
{
    assert(mapper().writeValueAsString(new BeanFor2879(1, 2, 3)) == a2q("{'a':1,'c':3,'b':2}"));
    assert(alphaMapper().writeValueAsString(new BeanFor2879(1, 2, 3)) == a2q("{'a':1,'c':3,'b':2}"));
}

// [databind#311]
@("SerializationOrderTest.testAlphaAndCreatorOrdering")
unittest
{
    assert(alphaMapper().writeValueAsString(new BeanForGH311(2, 1)) == a2q("{'b':2,'a':1}"));
    auto mapper = jsonMapperBuilder(table()).disable(MapperFeature.SORT_CREATOR_PROPERTIES_FIRST).build();
    assert(mapper.writeValueAsString(new BeanForGH311(2, 1)) == a2q("{'a':1,'b':2}"));
}

// [databind#2555]
@("SerializationOrderTest.testOrderByIndexEtc")
unittest
{
    // since "default" order can actually vary with later JDKs, only verify
    // case of alphabetic-as-default
    assert(alphaMapper().writeValueAsString(new OrderingByIndexBean()) == a2q("{'f':0,'u':0,'b':0,'a':0,'r':0}"));
}

// [databind#2879]: allow preventing Creator properties from overriding
//    alphabetic ordering
@("SerializationOrderTest.testStrictAlphaAndCreatorOrdering")
unittest
{
    auto alpha = alphaMapper();
    // without changing defaults, creators are sorted before other properties
    // BUT are sorted within their own category
    assert(alpha.isEnabled(MapperFeature.SORT_PROPERTIES_ALPHABETICALLY));
    assert(alpha.isEnabled(MapperFeature.SORT_CREATOR_PROPERTIES_FIRST));
    assert(alpha.writeValueAsString(new BeanForStrictOrdering(2, 3)) == a2q("{'c':2,'a':3,'b':0}"));

    // but can change that
    auto strictAlpha = jsonMapperBuilder(table()).enable(MapperFeature.SORT_PROPERTIES_ALPHABETICALLY)
        .disable(MapperFeature.SORT_CREATOR_PROPERTIES_FIRST).build();

    assert(strictAlpha.writeValueAsString(new BeanForStrictOrdering(1, 2)) == a2q("{'a':2,'b':0,'c':1}"));
}

// [databind#5918]: disabling SORT_CREATOR_PROPERTIES_FIRST should work
//   even when SORT_PROPERTIES_ALPHABETICALLY is also disabled
@("SerializationOrderTest.testCreatorPropsNotFirstWhenBothSortingDisabled")
unittest
{
    auto mapper = jsonMapperBuilder(table()).disable(MapperFeature.SORT_PROPERTIES_ALPHABETICALLY)
        .disable(MapperFeature.SORT_CREATOR_PROPERTIES_FIRST).build();
    auto person = new BeanForGH5918("last", "first");
    person.setNotes("notes");
    const json = mapper.writeValueAsString(person);
    // Creator properties (lastName, firstName) should NOT be forced first
    assert(json == a2q("{'notes':'notes','firstName':'first','lastName':'last'}"), json);
}
