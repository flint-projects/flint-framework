/++
Ported from FasterXML/jackson-databind 3.1.8, src/test/java/tools/jackson/databind/ser/filter/JsonIncludeTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit assertions become D asserts; `Integer`/`Boolean` are `Nullable!int` and
`Nullable!bool`; `writeAndMap` reads into a `Map!(string, Any)`; `changeDefaultPropertyInclusion` takes the value
inclusion instead of an operator over `JsonInclude.Value` (deviation D-JACKSON-3); each bean's descriptor comes from
`descriptorOf!T`, a subclass's carrying its superclass's properties and class annotations, with the constructor
descriptor Flint AOT emits for Issue1351NonBean's `@JsonCreator` built by hand; DatabindTestUtil's IntWrapper and
StringWrapper are declared here.
Not ported: testInclusionOfDate and testInclusionOfCalendar (java.util.Date and java.util.Calendar have no Flint
counterpart; Flint has java.time only).
+/
module json_include_test;

import databind_test_util : a2q, jsonMapperBuilder, newJsonMapper;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : ConstructorDescriptor, Descriptor, DescriptorTable,
    MergedAnnotation, ParameterDescriptor, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.jackson.annotation : JsonCreator, JsonInclude, JsonProperty, JsonPropertyOrder;
import flint.jackson.databind : JsonMapper, MapperFeature, ObjectMapper;
import flint.java.util : ArrayList, LinkedHashMap, List, Map;
import std.typecons : Nullable;

@safe:

private final class SimpleBean
{
    string getA()
    {
        return "a";
    }

    string getB()
    {
        return null;
    }
}

@JsonInclude(JsonInclude.Include.ALWAYS)  // just to ensure default
private final class NoNullsBean
{
    @JsonInclude(JsonInclude.Include.NON_NULL) string getA()
    {
        return null;
    }

    string getB()
    {
        return null;
    }
}

@JsonInclude(JsonInclude.Include.NON_DEFAULT)
private final class NonDefaultBean
{
    private string _a = "a", _b = "b";

    string getA()
    {
        return _a;
    }

    string getB()
    {
        return _b;
    }
}

// [databind#998]: Do not require no-arg constructor; but if not, defaults check
//    has weaker interpretation
@JsonPropertyOrder(["x", "y", "z"])
@JsonInclude(JsonInclude.Include.NON_DEFAULT)
private final class NonDefaultBeanXYZ
{
    int x;
    int y = 3;
    int z = 7;

    this(int x, int y, int z)
    {
        this.x = x;
        this.y = y;
        this.z = z;
    }
}

@JsonInclude(JsonInclude.Include.NON_DEFAULT)
private final class MixedBean
{
    private string _a = "a", _b = "b";

    string getA()
    {
        return _a;
    }

    @JsonInclude(JsonInclude.Include.NON_NULL) string getB()
    {
        return _b;
    }
}

// to ensure that default values work for collections as well
@JsonInclude(JsonInclude.Include.NON_DEFAULT)
private final class ListBean
{
    List!string strings;

    this()
    {
        strings = new ArrayList!string();
    }
}

@JsonInclude(JsonInclude.Include.NON_DEFAULT)
private final class ArrayBean
{
    int[] ints = [1, 2];
}

// Test to ensure that default exclusion works for fields too
@JsonPropertyOrder(["i1", "i2"])
private final class DefaultIntBean
{
    @JsonInclude(JsonInclude.Include.NON_DEFAULT) int i1;

    @JsonInclude(JsonInclude.Include.NON_DEFAULT) Nullable!int i2;

    this(int i1, Nullable!int i2)
    {
        this.i1 = i1;
        this.i2 = i2;
    }
}

// [databind#5570]: Test for Boolean wrapper default behavior
@JsonPropertyOrder(["b1", "b2"])
private final class DefaultBooleanBean
{
    @JsonInclude(JsonInclude.Include.NON_DEFAULT) bool b1; // primitive

    @JsonInclude(JsonInclude.Include.NON_DEFAULT) Nullable!bool b2; // wrapper

    this(bool b1, Nullable!bool b2)
    {
        this.b1 = b1;
        this.b2 = b2;
    }
}

// [databind#5570]: Bean for reproducing the exact issue scenario
private final class Issue5570Bean
{
    private Nullable!bool value;

    Nullable!bool getValue()
    {
        return value;
    }

    void setValue(Nullable!bool value)
    {
        this.value = value;
    }
}

// [databind#4741]
@JsonInclude(JsonInclude.Include.NON_DEFAULT)
private final class NonDefaultBean4741
{
    string value = null;
}

private final class NonEmptyString
{
    @JsonInclude(JsonInclude.Include.NON_EMPTY) string value;

    this(string v)
    {
        value = v;
    }
}

private final class NonEmptyInt
{
    @JsonInclude(JsonInclude.Include.NON_EMPTY) int value;

    this(int v)
    {
        value = v;
    }
}

private final class NonEmptyDouble
{
    @JsonInclude(JsonInclude.Include.NON_EMPTY) double value;

    this(double v)
    {
        value = v;
    }
}

// DatabindTestUtil.IntWrapper.
private final class IntWrapper
{
    int i;

    this()
    {
    }

    this(int value)
    {
        i = value;
    }
}

// DatabindTestUtil.StringWrapper.
private final class StringWrapper
{
    string str;

    this()
    {
    }

    this(string value)
    {
        str = value;
    }
}

// [databind#1327]
@JsonInclude(JsonInclude.Include.NON_EMPTY)
private final class Issue1327BeanEmpty
{
    List!string myList;

    this()
    {
        myList = new ArrayList!string();
    }
}

// [databind#1327]
private final class Issue1327BeanAlways
{
    @JsonInclude(JsonInclude.Include.ALWAYS) List!string myList;

    this()
    {
        myList = new ArrayList!string();
    }
}

// [databind#1351]
private final class Issue1351Bean
{
    const string first;
    const double second;

    this(string first, double second)
    {
        this.first = first;
        this.second = second;
    }
}

@JsonInclude(JsonInclude.Include.NON_DEFAULT)
private abstract class Issue1351NonBeanParent
{
    protected const int num;

    protected this(int num)
    {
        this.num = num;
    }

    @JsonProperty("num") int getNum() const
    {
        return num;
    }
}

private final class Issue1351NonBean : Issue1351NonBeanParent
{
    private string str;

    @JsonCreator this(@JsonProperty("num") int num)
    {
        super(num);
    }

    string getStr()
    {
        return str;
    }

    void setStr(string str)
    {
        this.str = str;
    }
}

// Issue1351NonBean as Flint AOT describes it: the inherited getter and class annotation, and the creator.
private Descriptor issue1351NonBeanDescriptor()
{
    auto d = descriptorOf!Issue1351NonBean();
    d.properties = descriptorOf!Issue1351NonBeanParent().properties ~ d.properties;
    d.annotations = descriptorOf!Issue1351NonBeanParent().annotations ~ d.annotations;
    d.constructors = ConstructorDescriptor([
        ParameterDescriptor("num", "int", [
            MergedAnnotation(typeNameOf!JsonProperty, Any.of(JsonProperty("num")), 0)
        ])
    ], [MergedAnnotation(typeNameOf!JsonCreator, Any.of(JsonCreator()), 0)],
        (scope Any[] v) => Any.of(new Issue1351NonBean(v[0].get!int()))) ~ d.constructors;
    return d;
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!SimpleBean(), descriptorOf!NoNullsBean(), descriptorOf!NonDefaultBean(),
        descriptorOf!NonDefaultBeanXYZ(), descriptorOf!MixedBean(), descriptorOf!ListBean(),
        descriptorOf!ArrayBean(), descriptorOf!DefaultIntBean(), descriptorOf!DefaultBooleanBean(),
        descriptorOf!Issue5570Bean(), descriptorOf!NonDefaultBean4741(),
        descriptorOf!NonEmptyString(), descriptorOf!NonEmptyInt(), descriptorOf!NonEmptyDouble(),
        descriptorOf!IntWrapper(), descriptorOf!StringWrapper(), descriptorOf!Issue1327BeanEmpty(),
        descriptorOf!Issue1327BeanAlways(), descriptorOf!Issue1351Bean(),
        issue1351NonBeanDescriptor(), descriptorOf!(int[])(), descriptorOf!(Nullable!int)(),
        descriptorOf!(Nullable!bool)(), descriptorOf!(List!string)(),
        descriptorOf!(ArrayList!string)(), descriptorOf!(Map!(string, Any))(),
        descriptorOf!(LinkedHashMap!(string, Any))()
    ])
        t.add(d);
    return t;
}

// DatabindTestUtil.writeAndMap.
private Map!(string, Any) writeAndMap(ObjectMapper m, Any value)
{
    const str = m.writeValueAsString(value);
    return m.readValue!(Map!(string, Any))(str);
}

private JsonMapper mapper()
{
    return newJsonMapper(table());
}

@("JsonIncludeTest.testGlobal")
unittest
{
    auto result = writeAndMap(mapper(), Any.of(new SimpleBean()));
    assert(result.size() == 2);
    assert(result.get("a").get!string() == "a");
    assert(result.get("b").isNull());
    assert(result.containsKey("b"));
}

@("JsonIncludeTest.testNonNullByClass")
unittest
{
    auto result = writeAndMap(mapper(), Any.of(new NoNullsBean()));
    assert(result.size() == 1);
    assert(!result.containsKey("a"));
    assert(result.get("a").isNull());
    assert(result.containsKey("b"));
    assert(result.get("b").isNull());
}

// flint.jackson's class-level NON_DEFAULT does not compare with the default instance's values.
// LIKELY BUG: NonDefaultBean{_a:"notA"} writes {"a":"notA","b":"b"}, expected {"a":"notA"}; MixedBean writes "a":"a";
// ArrayBean writes {"ints":[1,2]}, expected {}; NonDefaultBean4741{value:""} writes {}, expected {"value":""}.
version (FlintJacksonNonDefaultByClass)
{
    @("JsonIncludeTest.testNonDefaultByClass")
    unittest
    {
        auto bean = new NonDefaultBean();
        // need to change one of defaults
        bean._a = "notA";
        auto result = writeAndMap(mapper(), Any.of(bean));
        assert(result.size() == 1);
        assert(result.containsKey("a"));
        assert(result.get("a").get!string() == "notA");
        assert(!result.containsKey("b"));
        assert(result.get("b").isNull());
    }
}

// [databind#998]
@("JsonIncludeTest.testNonDefaultByClassNoCtor")
unittest
{
    auto bean = new NonDefaultBeanXYZ(1, 2, 0);
    const json = mapper().writeValueAsString(bean);
    assert(json == a2q("{'x':1,'y':2}"), json);
}

version (FlintJacksonNonDefaultByClass)
{
    @("JsonIncludeTest.testMixedMethod")
    unittest
    {
        auto bean = new MixedBean();
        bean._a = "xyz";
        bean._b = null;
        auto result = writeAndMap(mapper(), Any.of(bean));
        assert(result.size() == 1);
        assert(result.get("a").get!string() == "xyz");
        assert(!result.containsKey("b"));

        bean._a = "a";
        bean._b = "b";
        result = writeAndMap(mapper(), Any.of(bean));
        assert(result.size() == 1);
        assert(result.get("b").get!string() == "b");
        assert(!result.containsKey("a"));
    }
}

@("JsonIncludeTest.testDefaultForEmptyList")
unittest
{
    assert(mapper().writeValueAsString(new ListBean()) == "{}");
}

// NON_DEFAULT should work for arrays too
version (FlintJacksonNonDefaultByClass)
{
    @("JsonIncludeTest.testNonEmptyDefaultArray")
    unittest
    {
        assert(mapper().writeValueAsString(new ArrayBean()) == "{}");
    }
}

// Null `Nullable!T` wrappers count as values for NON_DEFAULT, and MapperFeature.WRAPPERS_DEFAULT_TO_NULL is ignored.
// LIKELY BUG: DefaultIntBean(0, null) writes {"i2":null}, expected {}; with WRAPPERS_DEFAULT_TO_NULL disabled,
// DefaultIntBean(0, 0) writes {"i2":0}, expected {}; Issue5570Bean{value:null} writes {"value":null}, expected {}.
version (FlintJacksonWrapperInclusion)
{
    @("JsonIncludeTest.testDefaultForIntegers")
    unittest
    {
        auto mapper = jsonMapperBuilder(table()).enable(MapperFeature.WRAPPERS_DEFAULT_TO_NULL).build();
        // [databind#5570]: Integer wrapper default is null, not 0, so Integer.valueOf(0) should be included
        assert(mapper.writeValueAsString(new DefaultIntBean(0, Nullable!int(0))) == `{"i2":0}`);
        assert(mapper.writeValueAsString(new DefaultIntBean(0, Nullable!int(1))) == `{"i2":1}`);
        assert(mapper.writeValueAsString(new DefaultIntBean(0, Nullable!int.init)) == "{}");
        assert(mapper.writeValueAsString(new DefaultIntBean(3, Nullable!int(0))) == `{"i1":3,"i2":0}`);
        assert(mapper.writeValueAsString(new DefaultIntBean(3, Nullable!int.init)) == `{"i1":3}`);

        // but with different settings
        mapper = jsonMapperBuilder(table()).disable(MapperFeature.WRAPPERS_DEFAULT_TO_NULL).build();

        assert(mapper.writeValueAsString(new DefaultIntBean(0, Nullable!int(0))) == "{}");
        assert(mapper.writeValueAsString(new DefaultIntBean(0, Nullable!int(1))) == `{"i2":1}`);
        assert(mapper.writeValueAsString(new DefaultIntBean(0, Nullable!int.init)) == "{}");
        assert(mapper.writeValueAsString(new DefaultIntBean(3, Nullable!int(0))) == `{"i1":3}`);
        assert(mapper.writeValueAsString(new DefaultIntBean(3, Nullable!int.init)) == `{"i1":3}`);
    }
}

version (FlintJacksonWrapperInclusion)
{
    // [databind#5570]: Test for Boolean wrapper with NON_DEFAULT
    @("JsonIncludeTest.testDefaultForBooleans")
    unittest
    {
        auto mapper = jsonMapperBuilder(table()).enable(MapperFeature.WRAPPERS_DEFAULT_TO_NULL).build();

        // Both false: primitive suppressed (false is default for boolean),
        // wrapper included (Boolean default is null, not false)
        assert(mapper.writeValueAsString(new DefaultBooleanBean(false, Nullable!bool(false))) == `{"b2":false}`);

        // Both true: both included (neither matches their defaults)
        assert(mapper.writeValueAsString(new DefaultBooleanBean(true, Nullable!bool(true))) == `{"b1":true,"b2":true}`);

        // Wrapper null: both suppressed (primitive=false matches default, wrapper=null matches default)
        assert(mapper.writeValueAsString(new DefaultBooleanBean(false, Nullable!bool.init)) == "{}");

        // Primitive true, wrapper false: both included (neither matches defaults)
        const json = mapper.writeValueAsString(new DefaultBooleanBean(true, Nullable!bool(false)));
        assert(json == `{"b1":true,"b2":false}`);
    }
}

version (FlintJacksonWrapperInclusion)
{
    // [databind#5570]: Reproduce exact scenario from issue report
    @("JsonIncludeTest.testIssue5570BooleanWrapper")
    unittest
    {
        // Test case from issue #5570 - global NON_DEFAULT configuration
        auto mapper = jsonMapperBuilder(table()).enable(MapperFeature.WRAPPERS_DEFAULT_TO_NULL)
            .changeDefaultPropertyInclusion(JsonInclude.Include.NON_DEFAULT).build();

        auto pojo = new Issue5570Bean();
        pojo.setValue(Nullable!bool(false));

        // Should include "value":false because Boolean default is null, not false
        assert(mapper.writeValueAsString(pojo) == `{"value":false}`);

        // null should be excluded (matches default for Boolean wrapper)
        pojo.setValue(Nullable!bool.init);
        assert(mapper.writeValueAsString(pojo) == "{}");

        // true should be included (doesn't match null default)
        pojo.setValue(Nullable!bool(true));
        assert(mapper.writeValueAsString(pojo) == `{"value":true}`);
    }
}

@("JsonIncludeTest.testEmptyInclusionScalars")
unittest
{
    auto defMapper = mapper();
    auto inclMapper = jsonMapperBuilder(table()).changeDefaultPropertyInclusion(JsonInclude.Include.NON_EMPTY).build();

    // First, Strings
    auto str = new StringWrapper("");
    assert(defMapper.writeValueAsString(str) == `{"str":""}`);
    assert(inclMapper.writeValueAsString(str) == "{}");
    assert(inclMapper.writeValueAsString(new StringWrapper()) == "{}");

    assert(defMapper.writeValueAsString(new NonEmptyString("x")) == `{"value":"x"}`);
    assert(defMapper.writeValueAsString(new NonEmptyString("")) == "{}");

    // Then numbers
    // 11-Nov-2015, tatu: As of Jackson 2.7, scalars should NOT be considered empty,
    //   except for wrappers if they are `null`
    assert(defMapper.writeValueAsString(new NonEmptyInt(12)) == `{"value":12}`);
    assert(defMapper.writeValueAsString(new NonEmptyInt(0)) == `{"value":0}`);

    assert(defMapper.writeValueAsString(new NonEmptyDouble(1.25)) == `{"value":1.25}`);
    assert(defMapper.writeValueAsString(new NonEmptyDouble(0.0)) == `{"value":0.0}`);

    auto zero = new IntWrapper(0);
    assert(defMapper.writeValueAsString(zero) == `{"i":0}`);
    assert(inclMapper.writeValueAsString(zero) == `{"i":0}`);
}

// for [databind#1327]
@("JsonIncludeTest.test1327ClassDefaultsForEmpty")
unittest
{
    import std.string : indexOf;

    auto mapper = jsonMapperBuilder(table()).changeDefaultPropertyInclusion(JsonInclude.Include.NON_NULL).build();

    const jsonString = mapper.writeValueAsString(new Issue1327BeanEmpty());

    assert(jsonString.indexOf("myList") < 0, "Should not contain `myList`: " ~ jsonString);
}

@("JsonIncludeTest.test1327ClassDefaultsForAlways")
unittest
{
    import std.string : indexOf;

    auto mapper = jsonMapperBuilder(table()).changeDefaultPropertyInclusion(JsonInclude.Include.NON_EMPTY).build();

    const jsonString = mapper.writeValueAsString(new Issue1327BeanAlways());

    assert(jsonString.indexOf("myList") >= 0, "Should contain `myList` with Include.ALWAYS: " ~ jsonString);
}

// [databind#1351], [databind#1417]
@("JsonIncludeTest.testIssue1351")
unittest
{
    auto mapper = jsonMapperBuilder(table()).changeDefaultPropertyInclusion(JsonInclude.Include.NON_DEFAULT).build();
    assert(mapper.writeValueAsString(new Issue1351Bean(null, cast(double) 0)) == a2q("{}"));
    // [databind#1417]
    assert(mapper.writeValueAsString(new Issue1351NonBean(0)) == a2q("{}"));
}

// [databind#4741]
version (FlintJacksonNonDefaultByClass)
{
    @("JsonIncludeTest.testSerialization4741")
    unittest
    {
        auto bean = new NonDefaultBean4741();
        bean.value = "";
        assert(mapper().writeValueAsString(bean) == a2q("{'value':''}"));
    }
}
