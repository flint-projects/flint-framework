/++
Ported from FasterXML/jackson-databind 3.1.8, src/test/java/tools/jackson/databind/deser/jdk/JDKScalarsDeserTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit assertions become D unittests and asserts; `Class<?>` arguments are template
parameters and the mapper holds the Flint AOT descriptors of the test beans; Java's boxed scalars (`Integer`,
`Boolean`, `Character`, ...) are `Nullable!T`, Java's `char` is `wchar`; package-private Java fields are private D
fields; `mapper.createParser` is the mapper's `tokenStreamFactory().createParser`; the PrimitiveCreatorBean
constructor descriptor is built by hand, as Flint AOT emits it; `readerFor(T)` without further configuration is
the mapper's `readValue!T`; `ObjectReader` parts of otherwise portable tests
sit in versioned blocks inside the test. Not ported: testVoidDeser (Java's `Void` and `void.class` have no D
type to bind); testDoubleAsArray carries no `@Test` upstream and does not run. Cases that need parts of
flint.jackson that are not ported yet, or where it behaves differently, wait behind versions.
+/
module jdk_scalars_deser_test;

import databind_test_util : a2q, jsonMapperBuilder, q, verifyException;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : ConstructorDescriptor, Descriptor, DescriptorTable,
    MergedAnnotation, ParameterDescriptor, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.jackson.annotation : JsonCreator, JsonProperty;
import flint.jackson.databind : DeserializationFeature, ObjectMapper;
import flint.jackson.databind.exc : MismatchedInputException;
import std.typecons : Nullable;

@safe:

private enum NAN_STRING = "NaN";

private final class BooleanBean
{
    private bool _v;

    void setV(bool v)
    {
        _v = v;
    }
}

private class IntBean
{
    private int _v;

    void setV(int v)
    {
        _v = v;
    }
}

private final class LongBean
{
    private long _v;

    void setV(long v)
    {
        _v = v;
    }
}

private final class DoubleBean
{
    private double _v;

    void setV(double v)
    {
        _v = v;
    }
}

private final class CharacterBean
{
    private wchar _v;

    void setV(wchar v)
    {
        _v = v;
    }

    wchar getV()
    {
        return _v;
    }
}

private final class CharacterWrapperBean
{
    private Nullable!wchar _v;

    void setV(Nullable!wchar v)
    {
        _v = v;
    }

    Nullable!wchar getV()
    {
        return _v;
    }
}

// Also, let's ensure that it's ok to override methods.
private final class IntBean2 : IntBean
{
    override void setV(int v2)
    {
        super.setV(v2 + 1);
    }
}

private final class PrimitivesBean
{
    bool booleanValue = true;
    byte byteValue = 3;
    wchar charValue = 'a';
    short shortValue = 37;
    int intValue = 1;
    long longValue = 100L;
    float floatValue = 0.25f;
    double doubleValue = -1.0;

    void setIntValue(int v)
    {
        intValue = v;
    }

    void setLongValue(long v)
    {
        longValue = v;
    }

    void setDoubleValue(double v)
    {
        doubleValue = v;
    }
}

private final class WrappersBean
{
    Nullable!bool booleanValue;
    Nullable!byte byteValue;
    Nullable!wchar charValue;
    Nullable!short shortValue;
    Nullable!int intValue;
    Nullable!long longValue;
    Nullable!float floatValue;
    Nullable!double doubleValue;

    void setIntValue(Nullable!int v)
    {
        intValue = v;
    }

    void setDoubleValue(Nullable!double v)
    {
        doubleValue = v;
    }
}

// [databind#2101]
private final class PrimitiveCreatorBean
{
    this(int a, int b)
    {
    }
}

private Any invokePrimitiveCreator(scope Any[] arguments) @safe
{
    return Any.of(new PrimitiveCreatorBean(arguments[0].get!int(), arguments[1].get!int()));
}

private MergedAnnotation[] required(string name)
{
    return [MergedAnnotation(typeNameOf!JsonProperty, Any.of(JsonProperty(name, required: true)))];
}

// @JsonCreator PrimitiveCreatorBean(@JsonProperty(value="a",required=true) int a, @JsonProperty(...) int b).
private Descriptor primitiveCreatorDescriptor()
{
    auto d = descriptorOf!PrimitiveCreatorBean();
    d.constructors = ConstructorDescriptor([
        ParameterDescriptor("a", "int", required("a")), ParameterDescriptor("b", "int", required("b"))
    ], [MergedAnnotation(typeNameOf!JsonCreator, Any.of(JsonCreator()))], &invokePrimitiveCreator) ~ d.constructors;
    return d;
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!BooleanBean(), descriptorOf!IntBean(), descriptorOf!LongBean(),
        descriptorOf!DoubleBean(), descriptorOf!CharacterBean(), descriptorOf!CharacterWrapperBean(),
        descriptorOf!IntBean2(), descriptorOf!PrimitivesBean(), descriptorOf!WrappersBean(),
        primitiveCreatorDescriptor(), descriptorOf!(Nullable!bool)(),
        descriptorOf!(Nullable!byte)(), descriptorOf!(Nullable!wchar)(),
        descriptorOf!(Nullable!short)(), descriptorOf!(Nullable!int)(),
        descriptorOf!(Nullable!long)(), descriptorOf!(Nullable!float)(),
        descriptorOf!(Nullable!double)(), descriptorOf!(bool[])(), descriptorOf!(byte[])(),
        descriptorOf!(wchar[])(), descriptorOf!(short[])(), descriptorOf!(int[])(),
        descriptorOf!(long[])(), descriptorOf!(float[])(), descriptorOf!(double[])()
    ])
        t.add(d);
    return t;
}

// [databind#4858] Changes defaults for 3.0 so ensure configs work for 2.x and 3.x
private ObjectMapper mapper()
{
    return jsonMapperBuilder(table()).disable(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES).build();
}

// Java's Float.equals/Double.equals: NaN equals NaN.
private bool sameFloating(F)(F expected, F actual)
{
    import std.math : isNaN;

    return expected.isNaN ? actual.isNaN : expected == actual;
}

/*
 * Scalar tests for boolean
 */

@("JDKScalarsDeserTest.testBooleanPrimitive")
unittest
{
    auto m = mapper();
    // first, simple case:
    auto result = m.readValue!BooleanBean(`{"v":true}`);
    assert(result._v);
    result = m.readValue!BooleanBean(`{"v":null}`);
    assert(result !is null);
    assert(!result._v);
    result = m.readValue!BooleanBean(`{"v":1}`);
    assert(result !is null);
    assert(result._v);

    // should work with arrays too..
    const array = m.readValue!(bool[])("[ null, false ]");
    assert(array !is null);
    assert(array.length == 2);
    assert(!array[0]);
    assert(!array[1]);
}

// Simple unit test to verify that we can map boolean values to java.lang.Boolean.
@("JDKScalarsDeserTest.testBooleanWrapper")
unittest
{
    auto result = mapper().readValue!(Nullable!bool)("true");
    assert(result == Nullable!bool(true));
    result = mapper().readValue!(Nullable!bool)("false");
    assert(result == Nullable!bool(false));
}

/*
 * Scalar tests for integral types
 */

@("JDKScalarsDeserTest.testByteWrapper")
unittest
{
    auto result = mapper().readValue!(Nullable!byte)("   -42\t");
    assert(result == Nullable!byte(-42));

    // Also: should be able to coerce floats, strings:
    result = mapper().readValue!(Nullable!byte)(` "-12"`);
    assert(result == Nullable!byte(-12));

    result = mapper().readValue!(Nullable!byte)(" 39.07");
    assert(result == Nullable!byte(39));
}

// flint.jackson reports a float out of a byte's range with databind's InvalidFormatException, where Jackson throws
// jackson-core's InputCoercionException.
// LIKELY BUG: readValue!(Nullable!byte)("300.5") throws InvalidFormatException "Numeric value (300) out of range of
// `byte`" (expected InputCoercionException, whose message names the value 300.5).
version (FlintJacksonInputCoercionException)
{
    // [databind#5240]: float-to-Byte overflow must not silently wrap-around
    @("JDKScalarsDeserTest.testByteFromFloatOverflow")
    unittest
    {
        import flint.jackson.core.exc : InputCoercionException;

        auto m = mapper();
        // Values outside [-128, 255] (the supported byte/unsigned-byte range)
        // should fail rather than be silently truncated to a byte.
        // Wrapper Byte:
        foreach (json; ["300.5", "-200.5"])
        {
            try
            {
                const b = m.readValue!(Nullable!byte)(json);
                assert(false, "Should have failed for value out of `byte` range; got " ~ b.toString());
            }
            catch (InputCoercionException e)
                verifyException(e, "out of range of `byte`");
        }
        // Primitive byte (via property):
        foreach (json; [`{"byteValue":300.5}`, `{"byteValue":-200.5}`])
        {
            try
            {
                import std.conv : to;

                const bean = m.readValue!PrimitivesBean(json);
                assert(false, "Should have failed for value out of `byte` range; got " ~ bean.byteValue.to!string);
            }
            catch (InputCoercionException e)
                verifyException(e, "out of range of `byte`");
        }
    }
}

@("JDKScalarsDeserTest.testShortWrapper")
unittest
{
    auto result = mapper().readValue!(Nullable!short)("37");
    assert(result == Nullable!short(37));

    // Also: should be able to coerce floats, strings:
    result = mapper().readValue!(Nullable!short)(` "-1009"`);
    assert(result == Nullable!short(-1009));

    result = mapper().readValue!(Nullable!short)("-12.9");
    assert(result == Nullable!short(-12));
}

@("JDKScalarsDeserTest.testCharacterWrapper")
unittest
{
    import std.conv : to;

    auto m = mapper();
    // First: canonical value is 1-char string
    assert(m.readValue!(Nullable!wchar)(q("a")) == Nullable!wchar('a'));

    // flint.jackson reads a char from a 1-character String only, not from an integer character code.
    // LIKELY BUG: readValue!(Nullable!wchar)(" 88") throws InvalidFormatException "Cannot deserialize value of
    // type `char` from String "88"" (expected 'X').
    version (FlintJacksonCharFromIntCode)
    {
        // But can also pass in ascii code
        const result = m.readValue!(Nullable!wchar)(" " ~ (cast(int) 'X').to!string);
        assert(result == Nullable!wchar('X'));
    }

    // 22-Jun-2020, tatu: one special case turns out to be white space;
    //    need to avoid considering it "blank" value
    assert(m.readValue!(Nullable!wchar)(q(" ")) == Nullable!wchar(' '));

    auto wrapper = m.readValue!CharacterWrapperBean(`{"v":null}`);
    assert(wrapper !is null);
    assert(wrapper.getV().isNull);

    // flint.jackson has no ObjectReader (readerFor/with/without).
    version (FlintJacksonObjectReader)
    {
        try
        {
            m.readerFor!CharacterBean().with_(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES)
                .readValue(`{"v":null}`);
            assert(false, "Attempting to deserialize a 'null' JSON reference into a 'char' property did not"
                    ~ " throw an exception");
        }
        catch (MismatchedInputException e)
            verifyException(e, "cannot map `null`");
        CharacterBean charBean = m.readerFor!CharacterBean()
            .without(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES).readValue(`{"v":null}`);
        assert(wrapper !is null);
        assert(charBean.getV() == '\u0000');
    }
}

@("JDKScalarsDeserTest.testIntWrapper")
unittest
{
    auto result = mapper().readValue!(Nullable!int)("   -42\t");
    assert(result == Nullable!int(-42));

    // Also: should be able to coerce floats, strings:
    result = mapper().readValue!(Nullable!int)(` "-1200"`);
    assert(result == Nullable!int(-1200));

    result = mapper().readValue!(Nullable!int)(" 39.07");
    assert(result == Nullable!int(39));
}

@("JDKScalarsDeserTest.testIntPrimitive")
unittest
{
    auto m = mapper();
    // first, simple case:
    auto result = m.readValue!IntBean(`{"v":3}`);
    assert(result._v == 3);

    result = m.readValue!IntBean(`{"v":null}`);
    assert(result !is null);
    assert(result._v == 0);

    // should work with arrays too..
    auto array = m.readValue!(int[])("[ null ]");
    assert(array !is null);
    assert(array.length == 1);
    assert(array[0] == 0);

    // flint.jackson has no ObjectReader (readerFor/with/without).
    version (FlintJacksonObjectReader)
    {
        // [databind#381]
        try
        {
            m.readerFor!IntBean().without(DeserializationFeature.UNWRAP_SINGLE_VALUE_ARRAYS).readValue(`{"v":[3]}`);
            assert(false, "Did not throw exception when reading a value from a single value array with the"
                    ~ " UNWRAP_SINGLE_VALUE_ARRAYS feature disabled");
        }
        catch (MismatchedInputException exp)
        {
            //Correctly threw exception
        }

        auto unwrappingR = m.readerFor!IntBean().with_(DeserializationFeature.UNWRAP_SINGLE_VALUE_ARRAYS);

        result = unwrappingR.readValue!IntBean(`{"v":[3]}`);
        assert(result._v == 3);

        result = unwrappingR.readValue!IntBean(`[{"v":[3]}]`);
        assert(result._v == 3);

        try
        {
            unwrappingR.readValue!IntBean(`[{"v":[3,3]}]`);
            assert(false, "Did not throw exception while reading a value from a multi value array with"
                    ~ " UNWRAP_SINGLE_VALUE_ARRAY feature enabled");
        }
        catch (MismatchedInputException exp)
        {
            //threw exception as required
        }

        result = unwrappingR.readValue!IntBean(`{"v":[null]}`);
        assert(result !is null);
        assert(result._v == 0);

        array = m.readerFor!(int[])().with_(DeserializationFeature.UNWRAP_SINGLE_VALUE_ARRAYS)
            .readValue!(int[])("[ [ null ] ]");
        assert(array !is null);
        assert(array.length == 1);
        assert(array[0] == 0);
    }
}

@("JDKScalarsDeserTest.testLongWrapper")
unittest
{
    auto result = mapper().readValue!(Nullable!long)("12345678901");
    assert(result == Nullable!long(12_345_678_901L));

    // Also: should be able to coerce floats, strings:
    result = mapper().readValue!(Nullable!long)(` "-9876"`);
    assert(result == Nullable!long(-9876));

    result = mapper().readValue!(Nullable!long)("1918.3");
    assert(result == Nullable!long(1918));
}

@("JDKScalarsDeserTest.testLongPrimitive")
unittest
{
    auto m = mapper();
    // first, simple case:
    auto result = m.readValue!LongBean(`{"v":3}`);
    assert(result._v == 3);
    result = m.readValue!LongBean(`{"v":null}`);
    assert(result !is null);
    assert(result._v == 0);

    // should work with arrays too..
    auto array = m.readValue!(long[])("[ null ]");
    assert(array !is null);
    assert(array.length == 1);
    assert(array[0] == 0);

    // flint.jackson has no ObjectReader (readerFor/with/without).
    version (FlintJacksonObjectReader)
    {
        // [databind#381]
        try
        {
            m.readerFor!LongBean().without(DeserializationFeature.UNWRAP_SINGLE_VALUE_ARRAYS).readValue(`{"v":[3]}`);
            assert(false, "Did not throw exception when reading a value from a single value array with the"
                    ~ " UNWRAP_SINGLE_VALUE_ARRAYS feature disabled");
        }
        catch (MismatchedInputException exp)
        {
            //Correctly threw exception
        }

        auto unwrappingR = m.readerFor!LongBean().with_(DeserializationFeature.UNWRAP_SINGLE_VALUE_ARRAYS);

        result = unwrappingR.readValue!LongBean(`{"v":[3]}`);
        assert(result._v == 3);

        result = unwrappingR.readValue!LongBean(`[{"v":[3]}]`);
        assert(result._v == 3);

        try
        {
            unwrappingR.readValue!LongBean(`[{"v":[3,3]}]`);
            assert(false, "Did not throw exception while reading a value from a multi value array with"
                    ~ " UNWRAP_SINGLE_VALUE_ARRAY feature enabled");
        }
        catch (MismatchedInputException exp)
        {
            //threw exception as required
        }

        result = unwrappingR.readValue!LongBean(`{"v":[null]}`);
        assert(result !is null);
        assert(result._v == 0);

        array = m.readerFor!(long[])().with_(DeserializationFeature.UNWRAP_SINGLE_VALUE_ARRAYS)
            .readValue!(long[])("[ [ null ] ]");
        assert(array !is null);
        assert(array.length == 1);
        assert(array[0] == 0);
    }
}

// Beyond simple case, let's also ensure that method overriding works as expected.
@("JDKScalarsDeserTest.testIntWithOverride")
unittest
{
    const result = mapper().readValue!IntBean2(`{"v":8}`);
    assert(result._v == 9);
}

/*
 * Scalar tests for floating point types
 */

@("JDKScalarsDeserTest.testDoublePrimitive")
unittest
{
    auto m = mapper();
    // first, simple case:
    // bit tricky with binary fps but...
    const value = 0.016;
    auto result = m.readValue!DoubleBean(`{"v":0.016}`);
    assert(result._v == value);
    // then [JACKSON-79]:
    result = m.readValue!DoubleBean(`{"v":null}`);
    assert(result !is null);
    assert(result._v == 0.0);

    // should work with arrays too..
    const array = m.readValue!(double[])("[ null ]");
    assert(array !is null);
    assert(array.length == 1);
    assert(array[0] == 0.0);
}

/* Note: dealing with floating-point values is tricky; not sure if
 * we can really use equality tests here... JDK does have decent
 * conversions though, to retain accuracy and round-trippability.
 * But still...
 */
@("JDKScalarsDeserTest.testFloatWrapper")
unittest
{
    // Also: should be able to coerce floats, strings:
    static immutable STRS = ["1.0", "0.0", "-0.3", "0.7", "42.012", "-999.0", NAN_STRING];

    // Float.valueOf/Double.valueOf of each, as D literals (std.conv's parsing is not correctly rounded).
    static immutable float[] EXPS = [1.0f, 0.0f, -0.3f, 0.7f, 42.012f, -999.0f, float.nan];

    foreach (i, str; STRS)
    {
        const exp = EXPS[i];
        Nullable!float result;

        if (NAN_STRING != str)
        {
            // First, as regular floating point value
            result = mapper().readValue!(Nullable!float)(str);
            assert(sameFloating(exp, result.get), str);
        }

        // and then as coerced String:
        result = mapper().readValue!(Nullable!float)(` "` ~ str ~ `"`);
        assert(sameFloating(exp, result.get), str);
    }
}

@("JDKScalarsDeserTest.testDoubleWrapper")
unittest
{
    // Also: should be able to coerce doubles, strings:
    static immutable STRS = ["1.0", "0.0", "-0.3", "0.7", "42.012", "-999.0", NAN_STRING];

    // Float.valueOf/Double.valueOf of each, as D literals (std.conv's parsing is not correctly rounded).
    static immutable double[] EXPS = [1.0, 0.0, -0.3, 0.7, 42.012, -999.0, double.nan];

    foreach (i, str; STRS)
    {
        const exp = EXPS[i];
        Nullable!double result;

        // First, as regular double value
        if (NAN_STRING != str)
        {
            result = mapper().readValue!(Nullable!double)(str);
            assert(sameFloating(exp, result.get), str);
        }
        // and then as coerced String:
        result = mapper().readValue!(Nullable!double)(` "` ~ str ~ `"`);
        assert(sameFloating(exp, result.get), str);
    }
}

/*
 * Scalar tests, other
 */

@("JDKScalarsDeserTest.testBase64Variants")
unittest
{
    const INPUT = cast(const(byte)[]) "abcdefghijklmnopqrstuvwxyz1234567890abcdefghijklmnopqrstuvwxyz1234567890X";

    // default encoding is "MIME, no linefeeds", so:
    assert(INPUT == mapper().readValue!(byte[])(
            q("YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkwYWJjZGVmZ2hpamts"
            ~ "bW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkwWA==")));

    // flint.jackson has no ObjectReader (readerFor/with(Base64Variant)).
    version (FlintJacksonObjectReader)
    {
        import flint.jackson.core : Base64Variants;

        enum ABC = "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkwYWJjZGVmZ2hpamts";
        auto reader = mapper().readerFor!(byte[])();
        assert(INPUT == reader.with_(Base64Variants.MIME_NO_LINEFEEDS)
                .readValue!(byte[])(q(ABC ~ "bW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkwWA==")));

        // but others should be slightly different
        assert(INPUT == reader.with_(Base64Variants.MIME)
                .readValue!(byte[])(q(ABC ~ "bW5vcHFyc3R1\\ndnd4eXoxMjM0NTY3ODkwWA==")));
        assert(INPUT == reader.with_(Base64Variants.MODIFIED_FOR_URL)
                .readValue!(byte[])(q(ABC ~ "bW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkwWA")));
        // PEM mandates 64 char lines:
        assert(INPUT == reader.with_(Base64Variants.PEM)
                .readValue!(byte[])(q(ABC ~ "\\nbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkwWA==")));
    }
}

/*
 * Sequence tests
 */

// flint.jackson's readValue(JsonParser) leaves the parser on the value's last token; Jackson clears it, so the
// next call reads the next value.
// LIKELY BUG: over " 0 1 2 ...", the second readValue!(Nullable!int)(p) returns 0 again (expected 1).
version (FlintJacksonReadValueSequence)
{
    // Then a unit test to verify that we can conveniently bind sequence of space-separated simple values
    @("JDKScalarsDeserTest.testSequenceOfInts")
    unittest
    {
        import std.conv : to;

        enum NR_OF_INTS = 100;

        string sb;
        foreach (i; 0 .. NR_OF_INTS)
            sb ~= " " ~ i.to!string;
        auto m = jsonMapperBuilder(table()).disable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS).build();
        auto p = m.tokenStreamFactory().createParser(sb);
        scope (exit)
            p.close();
        foreach (i; 0 .. NR_OF_INTS)
        {
            const result = m.readValue!(Nullable!int)(p);
            assert(result == Nullable!int(i), i.to!string);
        }
    }
}

/*
 * Empty String coercion, handling
 */

@("JDKScalarsDeserTest.testEmptyStringForIntegerWrappers")
unittest
{
    auto m = mapper();
    auto bean = m.readValue!WrappersBean(`{"byteValue":""}`);
    assert(bean.byteValue.isNull);

    // char/Character is different... not sure if this should work or not:
    bean = m.readValue!WrappersBean(`{"charValue":""}`);
    assert(bean.charValue.isNull);

    bean = m.readValue!WrappersBean(`{"shortValue":""}`);
    assert(bean.shortValue.isNull);
    bean = m.readValue!WrappersBean(`{"intValue":""}`);
    assert(bean.intValue.isNull);
    bean = m.readValue!WrappersBean(`{"longValue":""}`);
    assert(bean.longValue.isNull);
}

@("JDKScalarsDeserTest.testEmptyStringForFloatWrappers")
unittest
{
    auto m = mapper();
    auto bean = m.readValue!WrappersBean(`{"floatValue":""}`);
    assert(bean.floatValue.isNull);
    bean = m.readValue!WrappersBean(`{"doubleValue":""}`);
    assert(bean.doubleValue.isNull);
}

@("JDKScalarsDeserTest.testEmptyStringForBooleanPrimitive")
unittest
{
    const bean = mapper().readValue!PrimitivesBean(`{"booleanValue":""}`);
    assert(!bean.booleanValue);
}

@("JDKScalarsDeserTest.testEmptyStringForIntegerPrimitives")
unittest
{
    auto m = mapper();
    auto bean = m.readValue!PrimitivesBean(`{"byteValue":""}`);
    assert(bean.byteValue == 0);
    bean = m.readValue!PrimitivesBean(`{"charValue":""}`);
    assert(bean.charValue == 0);
    bean = m.readValue!PrimitivesBean(`{"shortValue":""}`);
    assert(bean.shortValue == 0);
    bean = m.readValue!PrimitivesBean(`{"intValue":""}`);
    assert(bean.intValue == 0);
    bean = m.readValue!PrimitivesBean(`{"longValue":""}`);
    assert(bean.longValue == 0L);
}

@("JDKScalarsDeserTest.testEmptyStringForFloatPrimitives")
unittest
{
    auto m = mapper();
    auto bean = m.readValue!PrimitivesBean(`{"floatValue":""}`);
    assert(bean.floatValue == 0.0f);
    bean = m.readValue!PrimitivesBean(`{"doubleValue":""}`);
    assert(bean.doubleValue == 0.0);
}

/*
 * Null handling for scalars in POJO
 */

@("JDKScalarsDeserTest.testNullForPrimitivesDefault")
unittest
{
    auto m = mapper();
    // by default, ok to rely on defaults
    auto bean = m.readValue!PrimitivesBean(`{"intValue":null, "booleanValue":null, "doubleValue":null}`);
    assert(bean !is null);
    assert(bean.intValue == 0);
    assert(!bean.booleanValue);
    assert(bean.doubleValue == 0.0);

    bean = m.readValue!PrimitivesBean(`{"byteValue":null, "longValue":null, "floatValue":null}`);
    assert(bean !is null);
    assert(bean.byteValue == 0);
    assert(bean.longValue == 0L);
    assert(bean.floatValue == 0.0f);
}

private void verifyPath(MismatchedInputException e, string propName)
{
    assert(e.getPath().length == 1);
    assert(e.getPath()[0].propertyName == propName);
}

// flint.jackson has no ObjectReader (readerFor/with/forType).
version (FlintJacksonObjectReader)
{
    private void expectNullFailure(R)(R reader, string json, string message, string path)
    {
        try
        {
            reader.readValue(json);
            assert(false, "Expected failure for " ~ path ~ " + null");
        }
        catch (MismatchedInputException e)
        {
            verifyException(e, message);
            verifyPath(e, path);
        }
    }

    @("JDKScalarsDeserTest.testNullForPrimitivesNotAllowedInts")
    unittest
    {
        const reader = mapper().readerFor!PrimitivesBean().with_(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES);
        expectNullFailure(reader, `{"byteValue":null}`, "Cannot map `null` into type `byte`", "byteValue");
        expectNullFailure(reader, `{"shortValue":null}`, "Cannot map `null` into type `short`", "shortValue");
        expectNullFailure(reader, `{"intValue":null}`, "Cannot map `null` into type `int`", "intValue");
        expectNullFailure(reader, `{"longValue":null}`, "Cannot map `null` into type `long`", "longValue");
    }

    @("JDKScalarsDeserTest.testNullForPrimitivesNotAllowedFP")
    unittest
    {
        const reader = mapper().readerFor!PrimitivesBean().with_(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES);
        // float/double
        expectNullFailure(reader, `{"floatValue":null}`, "Cannot map `null` into type `float`", "floatValue");
        expectNullFailure(reader, `{"doubleValue":null}`, "Cannot map `null` into type `double`", "doubleValue");
    }

    @("JDKScalarsDeserTest.testNullForPrimitivesNotAllowedMisc")
    unittest
    {
        const reader = mapper().readerFor!PrimitivesBean().with_(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES);
        // boolean
        expectNullFailure(reader, `{"booleanValue":null}`, "Cannot map `null` into type `boolean`", "booleanValue");
        expectNullFailure(reader, `{"charValue":null}`, "Cannot map `null` into type `char`", "charValue");
    }

    // [databind#2101]
    @("JDKScalarsDeserTest.testNullForPrimitivesViaCreator")
    unittest
    {
        try
        {
            mapper().readerFor!PrimitiveCreatorBean()
                .with_(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES).readValue(a2q("{'a': null}"));
            assert(false, "Expected failure for `int` and `null`");
        }
        catch (MismatchedInputException e)
        {
            verifyException(e, "Cannot map `null` into type `int`");
            verifyPath(e, "a");
        }
    }

    private void nullForPrimitiveArrays(T : E[], E)(E defValue, bool testEmptyString = true)
    {
        enum EMPTY_STRING_JSON = `[ "" ]`;
        enum JSON_WITH_NULL = "[ null ]";
        const SIMPLE_NAME = "`" ~ E.stringof ~ "[]`";
        auto readerCoerceOk = mapper().readerFor!T();
        auto readerNoNulls = readerCoerceOk.with_(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES);

        auto ob = readerCoerceOk.forType!T().readValue!T(JSON_WITH_NULL);
        assert(ob.length == 1);
        assert(ob[0] == defValue);
        try
        {
            readerNoNulls.readValue!T(JSON_WITH_NULL);
            assert(false, "Should not pass");
        }
        catch (MismatchedInputException e)
        {
            verifyException(e, "Cannot coerce `null`");
            verifyException(e, "to element of " ~ SIMPLE_NAME);
        }

        if (testEmptyString)
        {
            ob = readerCoerceOk.forType!T().readValue!T(EMPTY_STRING_JSON);
            assert(ob.length == 1);
            assert(ob[0] == defValue);
        }
    }

    @("JDKScalarsDeserTest.testNullForPrimitiveArrays")
    unittest
    {
        nullForPrimitiveArrays!(bool[])(false);
        nullForPrimitiveArrays!(byte[])(0);
        nullForPrimitiveArrays!(wchar[])(0, false);
        nullForPrimitiveArrays!(short[])(0);
        nullForPrimitiveArrays!(int[])(0);
        nullForPrimitiveArrays!(long[])(0L);
        nullForPrimitiveArrays!(float[])(0f);
        nullForPrimitiveArrays!(double[])(0.0);
    }

}

private void invalidStringCoercionFail(T)(string targetTypeName)
{
    enum JSON = `[ "foobar" ]`;

    try
    {
        mapper().readValue!T(JSON);
        assert(false, "Should not pass");
    }
    catch (MismatchedInputException e)
        verifyException(e, "Cannot deserialize value of type `" ~ targetTypeName ~ "` from String \"foobar\"");
}

@("JDKScalarsDeserTest.testInvalidStringCoercionFail")
unittest
{
    invalidStringCoercionFail!(bool[])("boolean");
    // A String element of byte[] fails with "from non-integer token: overflow" instead of Jackson's message.
    version (FlintJacksonByteArrayStringElement)
        invalidStringCoercionFail!(byte[])("byte[]");

    // char[] is special, cannot use generalized test here
    invalidStringCoercionFail!(short[])("short");
    invalidStringCoercionFail!(int[])("int");
    invalidStringCoercionFail!(long[])("long");
    invalidStringCoercionFail!(float[])("float");
    invalidStringCoercionFail!(double[])("double");
}

/*
 * Tests for mismatch: JSON Object for scalars (not supported for JSON)
 */

private void failForNumberFromObject(T)(string classDescription)
{
    try
    {
        mapper().readValue!T(a2q("{'value':12}"));
        assert(false, "Should not pass");
    }
    catch (MismatchedInputException e)
    {
        verifyException(e, "from Object value");
        verifyException(e, classDescription);
    }
}

@("JDKScalarsDeserTest.testFailForScalarFromObject")
unittest
{
    failForNumberFromObject!byte("`byte`");
    failForNumberFromObject!short("`short`");
    failForNumberFromObject!long("`long`");
    failForNumberFromObject!float("`float`");
    failForNumberFromObject!double("`double`");
    // flint.java has no BigInteger/BigDecimal.
    version (FlintJacksonBigNumbers)
    {
        import flint.java.math : BigDecimal, BigInteger;

        failForNumberFromObject!BigInteger("`java.math.BigInteger`");
        failForNumberFromObject!BigDecimal("`java.math.BigDecimal`");
    }
}
