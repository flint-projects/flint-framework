// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.util.ObjectUtilsTests` (v7.1.0), including its nested
`NullSafeConciseToStringTests`: one `unittest` per Java test method, each starting with a `// <JavaTestName>`
comment.

Skipped Java tests (42), with reasons:
- toObjectArray, toObjectArrayWithNull, toObjectArrayWithEmptyPrimitiveArray, toObjectArrayWithNonArrayType,
  toObjectArrayWithNonPrimitiveArray: `ObjectUtils.toObjectArray` boxes primitive arrays through
  `java.lang.reflect.Array`; it is excluded (runtime-reflection), since D arrays are already typed.
- isArrayOfPrimitivesWithBooleanArray, isArrayOfPrimitivesWithObjectArray, isArrayOfPrimitivesWithNonArray and the
  17 isPrimitiveOrWrapperWith* tests (BooleanPrimitiveClass, BooleanWrapperClass, BytePrimitiveClass,
  ByteWrapperClass, CharacterClass, CharClass, DoublePrimitiveClass, DoubleWrapperClass, FloatPrimitiveClass,
  FloatWrapperClass, IntClass, IntegerClass, LongPrimitiveClass, LongWrapperClass, NonPrimitiveOrWrapperClass,
  ShortPrimitiveClass, ShortWrapperClass): they test `ClassUtils` on `Class` objects (runtime-reflection).
- NullSafeConciseToStringTests: nullSafeConciseToStringForClass (`Class` objects), ForStringBuilders
  (`StringBuilder`), ForBigNumbers (`BigInteger`/`BigDecimal`), ForDate, ForTemporal, ForUUID, ForFile, ForPath,
  ForURI, ForURL, ForInetAddress, ForCharset, ForCurrency, ForLocale, ForRegExPattern, ForTimeZone, ForZoneId: JDK
  value types that `ClassUtils.isSimpleValueType` recognizes; Flint's simple values are scalars, enums and strings.

Adapted: the `assertEqualHashCodes` half that compares against Java's identity `array.hashCode()` has no D
equivalent (arrays have no identity hash); mixed `Object[]` arrays become typed arrays or objects with
`toString`. D cannot tell a null array from an empty one created with `new T[0]`, so "empty" arrays below are
non-null zero-length slices.
+/
module flint.util.object_utils_test;

import flint.java.io : IOException;
import flint.java.lang : IllegalArgumentException, RuntimeException, UnsupportedOperationException, stringHashCode;
import flint.java.util : Collections, HashMap, HashSet, List, Map, Optional, Set;
import flint.util : ObjectUtils;
import flint.util.test_support : contains, expectThrows;

@safe:

private enum Tropes
{
    FOO,
    BAR,
    baz
}

private class SQLException : Exception
{
    this()
    {
        super("sql");
    }
}

private final class Named
{
    private string name;

    this(string name)
    {
        this.name = name;
    }

    override string toString() const
    {
        return name;
    }
}

/// A non-null, zero-length `T[]`: Java's `new T[0]`.
private T[] emptyArray(T)()
{
    return (new T[1])[0 .. 0];
}

private int javaArrayHash(T)(T[] array, scope int delegate(T) @safe elementHash)
{
    int result = 1;
    foreach (element; array)
        result = 31 * result + elementHash(element);
    return result;
}

private int doubleHash(double value)
{
    union Bits
    {
        double d;
        ulong u;
    }

    Bits bits;
    bits.d = value;
    return cast(int)(bits.u ^ (bits.u >>> 32));
}

private int floatHash(float value)
{
    union Bits
    {
        float f;
        int i;
    }

    Bits bits;
    bits.f = value;
    return bits.i;
}

// isCheckedException
unittest
{
    assert(ObjectUtils.isCheckedException(new Exception("")));
    assert(ObjectUtils.isCheckedException(new SQLException()));
    assert(!ObjectUtils.isCheckedException(new RuntimeException()));
    assert(!ObjectUtils.isCheckedException(new IllegalArgumentException("")));
    // Any Throwable other than RuntimeException and Error has to be considered checked according to the JLS.
    assert(ObjectUtils.isCheckedException(new Throwable("")));
}

// isCompatibleWithThrowsClause
unittest
{
    assert(ObjectUtils.isCompatibleWithThrowsClause(new RuntimeException()));
    assert(ObjectUtils.isCompatibleWithThrowsClause!()(new RuntimeException()));
    assert(ObjectUtils.isCompatibleWithThrowsClause!(Exception)(new RuntimeException()));
    assert(ObjectUtils.isCompatibleWithThrowsClause!(SQLException, IOException)(new RuntimeException()));
    assert(ObjectUtils.isCompatibleWithThrowsClause!(Throwable)(new RuntimeException()));

    assert(!ObjectUtils.isCompatibleWithThrowsClause(new Exception("")));
    assert(!ObjectUtils.isCompatibleWithThrowsClause!()(new Exception("")));
    assert(ObjectUtils.isCompatibleWithThrowsClause!(Exception)(new Exception("")));
    assert(!ObjectUtils.isCompatibleWithThrowsClause!(SQLException, IOException)(new Exception("")));
    assert(ObjectUtils.isCompatibleWithThrowsClause!(Throwable)(new Exception("")));

    assert(!ObjectUtils.isCompatibleWithThrowsClause(new SQLException()));
    assert(!ObjectUtils.isCompatibleWithThrowsClause!()(new SQLException()));
    assert(ObjectUtils.isCompatibleWithThrowsClause!(Exception)(new SQLException()));
    assert(ObjectUtils.isCompatibleWithThrowsClause!(SQLException, IOException)(new SQLException()));
    assert(ObjectUtils.isCompatibleWithThrowsClause!(Throwable)(new SQLException()));

    assert(!ObjectUtils.isCompatibleWithThrowsClause(new Throwable("")));
    assert(!ObjectUtils.isCompatibleWithThrowsClause!()(new Throwable("")));
    assert(!ObjectUtils.isCompatibleWithThrowsClause!(Exception)(new Throwable("")));
    assert(!ObjectUtils.isCompatibleWithThrowsClause!(SQLException, IOException)(new Throwable("")));
    assert(ObjectUtils.isCompatibleWithThrowsClause!(Throwable)(new Throwable("")));
}

// isEmptyNull
unittest
{
    assert(ObjectUtils.isEmpty(null));
}

// isEmptyArray
unittest
{
    assert(ObjectUtils.isEmpty(emptyArray!char()));
    assert(ObjectUtils.isEmpty(emptyArray!Object()));
    assert(ObjectUtils.isEmpty(emptyArray!int()));
    assert(!ObjectUtils.isEmpty([42]));
}

// isEmptyCollection
unittest
{
    assert(ObjectUtils.isEmpty(Collections.emptyList!string()));
    assert(ObjectUtils.isEmpty(Collections.emptySet!string()));
    auto set = new HashSet!string();
    set.add("foo");
    assert(!ObjectUtils.isEmpty(set));
    assert(!ObjectUtils.isEmpty(Collections.singletonList("foo")));
}

// isEmptyMap
unittest
{
    assert(ObjectUtils.isEmpty(Collections.emptyMap!(string, long)()));
    auto map = new HashMap!(string, long)();
    map.put("foo", 42L);
    assert(!ObjectUtils.isEmpty(map));
}

// isEmptyCharSequence
unittest
{
    char[] builder;
    assert(ObjectUtils.isEmpty(builder));
    assert(ObjectUtils.isEmpty(""));
    assert(!ObjectUtils.isEmpty("foo".dup));
    assert(!ObjectUtils.isEmpty("   "));
    assert(!ObjectUtils.isEmpty("\t"));
    assert(!ObjectUtils.isEmpty("foo"));
}

// isEmptyUnsupportedObjectType
unittest
{
    assert(!ObjectUtils.isEmpty(42L));
    assert(!ObjectUtils.isEmpty(new Object));
}

// addObjectToArraySunnyDay
unittest
{
    string[] array = ["foo", "bar"];
    const newArray = ObjectUtils.addObjectToArray(array, "baz");
    assert(newArray.length == 3);
    assert(newArray[2] == "baz");
}

// addObjectToArraysAtPosition
unittest
{
    string[] array = ["foo", "bar", "baz"];
    assert(ObjectUtils.addObjectToArray(array, "bat", 3) == ["foo", "bar", "baz", "bat"]);
    assert(ObjectUtils.addObjectToArray(array, "bat", 2) == ["foo", "bar", "bat", "baz"]);
    assert(ObjectUtils.addObjectToArray(array, "bat", 1) == ["foo", "bat", "bar", "baz"]);
    assert(ObjectUtils.addObjectToArray(array, "bat", 0) == ["bat", "foo", "bar", "baz"]);
}

// addObjectToArrayWhenEmpty
unittest
{
    const newArray = ObjectUtils.addObjectToArray(emptyArray!string(), "foo");
    assert(newArray.length == 1);
    assert(newArray[0] == "foo");
}

// addObjectToSingleNonNullElementArray
unittest
{
    string[] array = ["foo"];
    const newArray = ObjectUtils.addObjectToArray(array, "bar");
    assert(newArray.length == 2);
    assert(newArray[0] == "foo");
    assert(newArray[1] == "bar");
}

// addObjectToSingleNullElementArray
unittest
{
    string[] array = [null];
    const newArray = ObjectUtils.addObjectToArray(array, "bar");
    assert(newArray.length == 2);
    assert(newArray[0] is null);
    assert(newArray[1] == "bar");
}

// addObjectToNullArray
unittest
{
    const newArray = ObjectUtils.addObjectToArray(cast(string[]) null, "foo");
    assert(newArray.length == 1);
    assert(newArray[0] == "foo");
}

// addNullObjectToNullArray
unittest
{
    auto newArray = ObjectUtils.addObjectToArray(cast(Object[]) null, cast(Object) null);
    assert(newArray.length == 1);
    assert(newArray[0] is null);
}

// nullSafeEqualsWithArrays
unittest
{
    assert(ObjectUtils.nullSafeEquals(["a", "b", "c"], ["a", "b", "c"]));
    assert(ObjectUtils.nullSafeEquals([1, 2, 3], [1, 2, 3]));
    assert(ObjectUtils.nullSafeEquals([1L, 2, 3], [1L, 2, 3]));
    assert(ObjectUtils.nullSafeEquals([cast(short) 1, 2, 3], [cast(short) 1, 2, 3]));
    assert(ObjectUtils.nullSafeEquals([cast(byte) 1, 2, 3], [cast(byte) 1, 2, 3]));
    assert(ObjectUtils.nullSafeEquals([1.0f, 2, 3], [1.0f, 2, 3]));
    assert(ObjectUtils.nullSafeEquals([1.0, 2, 3], [1.0, 2, 3]));
    assert(ObjectUtils.nullSafeEquals("\x01\x02\x03".dup, "\x01\x02\x03".dup));
    assert(ObjectUtils.nullSafeEquals([true, false, true], [true, false, true]));
}

// identityToString
unittest
{
    auto obj = new Object;
    const expected = typeid(obj).name ~ "@" ~ ObjectUtils.getIdentityHexString(obj);
    assert(ObjectUtils.identityToString(obj) == expected);
}

// identityToStringWithNullObject
unittest
{
    assert(ObjectUtils.identityToString(null) == "");
}

// nullSafeHashWithNull
unittest
{
    assert(ObjectUtils.nullSafeHash(cast(Object[]) null) == 0);
}

// nullSafeHashWithIntermediateNullElements
unittest
{
    assert(ObjectUtils.nullSafeHash(3, null, 5) == 31 * (31 * (31 * 1 + 3) + 0) + 5);
}

// nullSafeHashCodeWithNullBooleanArray
unittest
{
    bool[] array = null;
    assert(ObjectUtils.nullSafeHashCode(array) == 0);
}

// nullSafeHashCodeWithBooleanArray
unittest
{
    bool[] array = [true, false];
    assert(ObjectUtils.nullSafeHashCode(array) == 31 * (31 * 1 + 1231) + 1237);
}

// nullSafeHashCodeWithObjectBeingBooleanArray
unittest
{
    bool[] array = [true, false];
    assert(ObjectUtils.nullSafeHashCode(array) == javaArrayHash(array, (bool b) => b ? 1231 : 1237));
}

// nullSafeHashCodeWithNullByteArray
unittest
{
    byte[] array = null;
    assert(ObjectUtils.nullSafeHashCode(array) == 0);
}

// nullSafeHashCodeWithByteArray
unittest
{
    byte[] array = [8, 10];
    assert(ObjectUtils.nullSafeHashCode(array) == 31 * (31 * 1 + 8) + 10);
}

// nullSafeHashCodeWithObjectBeingByteArray
unittest
{
    byte[] array = [6, 39];
    assert(ObjectUtils.nullSafeHashCode(array) == javaArrayHash(array, (byte b) => cast(int) b));
}

// nullSafeHashCodeWithNullCharArray
unittest
{
    char[] array = null;
    assert(ObjectUtils.nullSafeHashCode(array) == 0);
}

// nullSafeHashCodeWithCharArray
unittest
{
    char[] array = ['a', 'E'];
    assert(ObjectUtils.nullSafeHashCode(array) == 31 * (31 * 1 + 'a') + 'E');
}

// nullSafeHashCodeWithObjectBeingCharArray
unittest
{
    char[] array = ['l', 'M'];
    assert(ObjectUtils.nullSafeHashCode(array) == javaArrayHash(array, (char c) => cast(int) c));
    // Java's char[] holds UTF-16 units: a supplementary character counts twice (R14).
    assert(ObjectUtils.nullSafeHashCode("\U0001F600".dup) == 31 * (31 * 1 + 0xD83D) + 0xDE00);
}

// nullSafeHashCodeWithNullDoubleArray
unittest
{
    double[] array = null;
    assert(ObjectUtils.nullSafeHashCode(array) == 0);
}

// nullSafeHashCodeWithDoubleArray
unittest
{
    double[] array = [8449.65, 9944.923];
    assert(ObjectUtils.nullSafeHashCode(array) == javaArrayHash(array, (double d) => doubleHash(d)));
}

// nullSafeHashCodeWithObjectBeingDoubleArray
unittest
{
    double[] array = [68_930.993, 9022.009];
    assert(ObjectUtils.nullSafeHashCode(array) == javaArrayHash(array, (double d) => doubleHash(d)));
}

// nullSafeHashCodeWithNullFloatArray
unittest
{
    float[] array = null;
    assert(ObjectUtils.nullSafeHashCode(array) == 0);
}

// nullSafeHashCodeWithFloatArray
unittest
{
    float[] array = [9.6f, 7.4f];
    assert(ObjectUtils.nullSafeHashCode(array) == javaArrayHash(array, (float f) => floatHash(f)));
}

// nullSafeHashCodeWithObjectBeingFloatArray
unittest
{
    float[] array = [9.9f, 9.54f];
    assert(ObjectUtils.nullSafeHashCode(array) == javaArrayHash(array, (float f) => floatHash(f)));
}

// nullSafeHashCodeWithNullIntArray
unittest
{
    int[] array = null;
    assert(ObjectUtils.nullSafeHashCode(array) == 0);
}

// nullSafeHashCodeWithIntArray
unittest
{
    int[] array = [884, 340];
    assert(ObjectUtils.nullSafeHashCode(array) == 31 * (31 * 1 + 884) + 340);
}

// nullSafeHashCodeWithObjectBeingIntArray
unittest
{
    int[] array = [89, 32];
    assert(ObjectUtils.nullSafeHashCode(array) == javaArrayHash(array, (int i) => i));
}

// nullSafeHashCodeWithNullLongArray
unittest
{
    long[] array = null;
    assert(ObjectUtils.nullSafeHashCode(array) == 0);
}

// nullSafeHashCodeWithLongArray
unittest
{
    long[] array = [7993L, 84_320L];
    assert(ObjectUtils.nullSafeHashCode(array) == 31 * (31 * 1 + 7993) + 84_320);
}

// nullSafeHashCodeWithObjectBeingLongArray
unittest
{
    long[] array = [4389, 320, -1];
    assert(ObjectUtils.nullSafeHashCode(array) == javaArrayHash(array, (long l) => cast(int)(l ^ (l >>> 32))));
}

// nullSafeHashCodeWithNullShortArray
unittest
{
    short[] array = null;
    assert(ObjectUtils.nullSafeHashCode(array) == 0);
}

// nullSafeHashCodeWithShortArray
unittest
{
    short[] array = [4, 25];
    assert(ObjectUtils.nullSafeHashCode(array) == 31 * (31 * 1 + 4) + 25);
}

// nullSafeHashCodeWithObjectBeingShortArray
unittest
{
    short[] array = [5, 3];
    assert(ObjectUtils.nullSafeHashCode(array) == javaArrayHash(array, (short s) => cast(int) s));
}

// nullSafeHashCodeWithObject
unittest
{
    const str = "Luke";
    assert(ObjectUtils.nullSafeHashCode(str) == stringHashCode(str));
}

// nullSafeHashCodeWithObjectArray
unittest
{
    string[] array = ["Leia", "Han"];
    assert(ObjectUtils.nullSafeHashCode(array) == 31 * (31 * 1 + stringHashCode("Leia")) + stringHashCode("Han"));
}

// nullSafeHashCodeWithObjectArrayEqualToNull
unittest
{
    assert(ObjectUtils.nullSafeHashCode(cast(Object[]) null) == 0);
}

// nullSafeHashCodeWithObjectBeingObjectArray
unittest
{
    string[] array = ["Luke", "Anakin"];
    assert(ObjectUtils.nullSafeHashCode(array) == javaArrayHash(array, (string s) => stringHashCode(s)));
}

// nullSafeHashCodeWithObjectEqualToNull
unittest
{
    Object[] array = null;
    assert(ObjectUtils.nullSafeHashCode(array) == 0);
}

// nullSafeToStringWithBooleanArray
unittest
{
    assert(ObjectUtils.nullSafeToString([true, false]) == "{true, false}");
}

// nullSafeToStringWithBooleanArrayBeingEmpty
unittest
{
    assert(ObjectUtils.nullSafeToString(emptyArray!bool()) == "{}");
}

// nullSafeToStringWithBooleanArrayEqualToNull
unittest
{
    assert(ObjectUtils.nullSafeToString(cast(bool[]) null) == "null");
}

// nullSafeToStringWithByteArray
unittest
{
    byte[] array = [5, 38];
    assert(ObjectUtils.nullSafeToString(array) == "{0526}");
}

// nullSafeToStringWithByteArrayBeingEmpty
unittest
{
    assert(ObjectUtils.nullSafeToString(emptyArray!byte()) == "{}");
}

// nullSafeToStringWithByteArrayEqualToNull
unittest
{
    assert(ObjectUtils.nullSafeToString(cast(byte[]) null) == "null");
}

// nullSafeToStringWithCharArray
unittest
{
    char[] array = ['A', 'B'];
    assert(ObjectUtils.nullSafeToString(array) == "{'A', 'B'}");
    assert(ObjectUtils.nullSafeToString("é日".dup) == "{'é', '日'}");
}

// nullSafeToStringWithCharArrayBeingEmpty
unittest
{
    assert(ObjectUtils.nullSafeToString(emptyArray!char()) == "{}");
}

// nullSafeToStringWithCharArrayEqualToNull
unittest
{
    assert(ObjectUtils.nullSafeToString(cast(char[]) null) == "null");
}

// nullSafeToStringWithDoubleArray
unittest
{
    assert(ObjectUtils.nullSafeToString([8594.93, 8_594_023.95]) == "{8594.93, 8594023.95}");
}

// nullSafeToStringWithDoubleArrayBeingEmpty
unittest
{
    assert(ObjectUtils.nullSafeToString(emptyArray!double()) == "{}");
}

// nullSafeToStringWithDoubleArrayEqualToNull
unittest
{
    assert(ObjectUtils.nullSafeToString(cast(double[]) null) == "null");
}

// nullSafeToStringWithFloatArray
unittest
{
    assert(ObjectUtils.nullSafeToString([8.6f, 43.8f]) == "{8.6, 43.8}");
}

// nullSafeToStringWithFloatArrayBeingEmpty
unittest
{
    assert(ObjectUtils.nullSafeToString(emptyArray!float()) == "{}");
}

// nullSafeToStringWithFloatArrayEqualToNull
unittest
{
    assert(ObjectUtils.nullSafeToString(cast(float[]) null) == "null");
}

// nullSafeToStringWithIntArray
unittest
{
    assert(ObjectUtils.nullSafeToString([9, 64]) == "{9, 64}");
}

// nullSafeToStringWithIntArrayBeingEmpty
unittest
{
    assert(ObjectUtils.nullSafeToString(emptyArray!int()) == "{}");
}

// nullSafeToStringWithIntArrayEqualToNull
unittest
{
    assert(ObjectUtils.nullSafeToString(cast(int[]) null) == "null");
}

// nullSafeToStringWithLongArray
unittest
{
    assert(ObjectUtils.nullSafeToString([434L, 23_423L]) == "{434, 23423}");
}

// nullSafeToStringWithLongArrayBeingEmpty
unittest
{
    assert(ObjectUtils.nullSafeToString(emptyArray!long()) == "{}");
}

// nullSafeToStringWithLongArrayEqualToNull
unittest
{
    assert(ObjectUtils.nullSafeToString(cast(long[]) null) == "null");
}

// nullSafeToStringWithPlainOldString
unittest
{
    assert(ObjectUtils.nullSafeToString("I shoh love tha taste of mangoes") == "I shoh love tha taste of mangoes");
}

// nullSafeToStringWithObjectArray
unittest
{
    Object[] array = [new Named("Han"), new Named("43")];
    assert(ObjectUtils.nullSafeToString(array) == "{Han, 43}");
}

// nullSafeToStringWithObjectArrayBeingEmpty
unittest
{
    assert(ObjectUtils.nullSafeToString(emptyArray!Object()) == "{}");
}

// nullSafeToStringWithObjectArrayEqualToNull
unittest
{
    assert(ObjectUtils.nullSafeToString(cast(Object[]) null) == "null");
}

// nullSafeToStringWithShortArray
unittest
{
    short[] array = [7, 9];
    assert(ObjectUtils.nullSafeToString(array) == "{7, 9}");
}

// nullSafeToStringWithShortArrayBeingEmpty
unittest
{
    assert(ObjectUtils.nullSafeToString(emptyArray!short()) == "{}");
}

// nullSafeToStringWithShortArrayEqualToNull
unittest
{
    assert(ObjectUtils.nullSafeToString(cast(short[]) null) == "null");
}

// nullSafeToStringWithStringArray
unittest
{
    assert(ObjectUtils.nullSafeToString(["Luke", "Anakin"]) == "{Luke, Anakin}");
}

// nullSafeToStringWithStringArrayBeingEmpty
unittest
{
    assert(ObjectUtils.nullSafeToString(emptyArray!string()) == "{}");
}

// nullSafeToStringWithStringArrayEqualToNull
unittest
{
    assert(ObjectUtils.nullSafeToString(cast(string[]) null) == "null");
}

// containsConstant
unittest
{
    auto values = [Tropes.FOO, Tropes.BAR, Tropes.baz];
    assert(ObjectUtils.containsConstant(values, "FOO"));
    assert(ObjectUtils.containsConstant(values, "foo"));
    assert(ObjectUtils.containsConstant(values, "BaR"));
    assert(ObjectUtils.containsConstant(values, "bar"));
    assert(ObjectUtils.containsConstant(values, "BAZ"));
    assert(ObjectUtils.containsConstant(values, "baz"));
    assert(!ObjectUtils.containsConstant(values, "BOGUS"));
    assert(ObjectUtils.containsConstant(values, "FOO", true));
    assert(!ObjectUtils.containsConstant(values, "foo", true));
}

// containsElement
unittest
{
    string[] array = ["foo", "bar"];
    assert(!ObjectUtils.containsElement(cast(string[]) null, "foo"));
    assert(!ObjectUtils.containsElement(array, null));
    assert(!ObjectUtils.containsElement(array, "bogus"));
    assert(ObjectUtils.containsElement(array, "foo"));
    assert(ObjectUtils.containsElement(array, "bar"));
    assert(ObjectUtils.containsElement([7, 42], 42));
    assert(ObjectUtils.containsElement([["baz", "quux"], ["x"]], ["baz", "quux"]));
}

// caseInsensitiveValueOf
unittest
{
    auto values = [Tropes.FOO, Tropes.BAR, Tropes.baz];
    assert(ObjectUtils.caseInsensitiveValueOf(values, "foo") == Tropes.FOO);
    assert(ObjectUtils.caseInsensitiveValueOf(values, "BAR") == Tropes.BAR);
    auto e = expectThrows!IllegalArgumentException(() {
        ObjectUtils.caseInsensitiveValueOf(values, "bogus");
    });
    assert(e.getMessage() == "Constant [bogus] does not exist in enum type flint.util.object_utils_test.Tropes");
}

private enum truncated = " (truncated)...";
private enum truncatedLength = 100 + truncated.length;

private string repeat(string text, size_t times)
{
    string result;
    foreach (_; 0 .. times)
        result ~= text;
    return result;
}

// nullSafeConciseToStringForNull
unittest
{
    assert(ObjectUtils.nullSafeConciseToString(null) == "null");
}

// nullSafeConciseToStringForEmptyOptional
unittest
{
    assert(ObjectUtils.nullSafeConciseToString(Optional!string.empty()) == "Optional.empty");
}

// nullSafeConciseToStringForNonEmptyOptionals
unittest
{
    assert(ObjectUtils.nullSafeConciseToString(Optional!Tropes.of(Tropes.BAR)) == "Optional[BAR]");
    const repeat100 = repeat("X", 100);
    const repeat101 = repeat("X", 101);
    assert(ObjectUtils.nullSafeConciseToString(Optional!string.of(repeat100)) == "Optional[" ~ repeat100 ~ "]");
    assert(ObjectUtils.nullSafeConciseToString(Optional!string.of(repeat101)) == "Optional[" ~ repeat100
            ~ truncated ~ "]");
}

// nullSafeConciseToStringForNonEmptyOptionalCustomType
unittest
{
    static class CustomType
    {
    }

    auto customType = new CustomType;
    const expected = "Optional[" ~ ObjectUtils.nullSafeConciseToString(customType) ~ "]";
    assert(ObjectUtils.nullSafeConciseToString(Optional!CustomType.of(customType)) == expected);
}

// nullSafeConciseToStringForStrings
unittest
{
    const repeat100 = repeat("X", 100);
    const repeat101 = repeat("X", 101);
    assert(ObjectUtils.nullSafeConciseToString("") == "");
    assert(ObjectUtils.nullSafeConciseToString("foo") == "foo");
    assert(ObjectUtils.nullSafeConciseToString(repeat100) == repeat100);
    const concise = ObjectUtils.nullSafeConciseToString(repeat101);
    assert(concise.length == truncatedLength && concise[$ - truncated.length .. $] == truncated);
}

// nullSafeConciseToStringForEnum
unittest
{
    assert(ObjectUtils.nullSafeConciseToString(Tropes.FOO) == "FOO");
}

// nullSafeConciseToStringForPrimitivesAndWrappers
unittest
{
    assert(ObjectUtils.nullSafeConciseToString(true) == "true");
    assert(ObjectUtils.nullSafeConciseToString('X') == "X");
    assert(ObjectUtils.nullSafeConciseToString(42L) == "42");
    assert(ObjectUtils.nullSafeConciseToString(99.1234) == "99.1234");
}

// nullSafeConciseToStringForEmptyArrays
unittest
{
    assert(ObjectUtils.nullSafeConciseToString(emptyArray!char()) == "{}");
    assert(ObjectUtils.nullSafeConciseToString(emptyArray!(int[])()) == "{}");
    assert(ObjectUtils.nullSafeConciseToString(emptyArray!string()) == "{}");
    assert(ObjectUtils.nullSafeConciseToString(emptyArray!(long[])()) == "{}");
}

// nullSafeConciseToStringForNonEmptyArrays
unittest
{
    assert(ObjectUtils.nullSafeConciseToString(['a']) == "{...}");
    assert(ObjectUtils.nullSafeConciseToString([[1], [2]]) == "{...}");
    assert(ObjectUtils.nullSafeConciseToString(["enigma"]) == "{...}");
    assert(ObjectUtils.nullSafeConciseToString([[1L], [2L]]) == "{...}");
}

// nullSafeConciseToStringForEmptyCollections
unittest
{
    List!string list = List!string.of();
    Set!int set = Set!int.of();
    assert(ObjectUtils.nullSafeConciseToString(list) == "[...]");
    assert(ObjectUtils.nullSafeConciseToString(set) == "[...]");
}

// nullSafeConciseToStringForNonEmptyCollections
unittest
{
    List!string list = List!string.of("a", "b");
    Set!int set = Set!int.of(1);
    assert(ObjectUtils.nullSafeConciseToString(list) == "[...]");
    assert(ObjectUtils.nullSafeConciseToString(set) == "[...]");
}

// nullSafeConciseToStringForEmptyMaps
unittest
{
    assert(ObjectUtils.nullSafeConciseToString(Map!(string, string).of()) == "{...}");
}

// nullSafeConciseToStringForNonEmptyMaps
unittest
{
    assert(ObjectUtils.nullSafeConciseToString(Map!(string, int).of("a", 1, "b", 2, "c", 3)) == "{...}");
}

// nullSafeConciseToStringForCustomTypes
unittest
{
    static class ExplosiveType
    {
        override string toString() const @safe
        {
            throw new UnsupportedOperationException("no-go");
        }
    }

    auto explosiveType = new ExplosiveType;
    expectThrows!UnsupportedOperationException(() { explosiveType.toString(); });
    const concise = ObjectUtils.nullSafeConciseToString(explosiveType);
    const explosivePrefix = typeid(explosiveType).name ~ "@";
    assert(concise[0 .. explosivePrefix.length] == explosivePrefix);

    static class WordyType
    {
        override string toString() const @safe
        {
            return repeat("blah blah", 20);
        }
    }

    auto wordyType = new WordyType;
    assert(wordyType.toString().length >= 180);
    const wordyPrefix = typeid(wordyType).name ~ "@";
    assert(ObjectUtils.nullSafeConciseToString(wordyType)[0 .. wordyPrefix.length] == wordyPrefix);
}

// unwrapOptional
unittest
{
    assert(ObjectUtils.unwrapOptional(null) is null);
    assert(ObjectUtils.unwrapOptional("some value") == "some value");
    assert(ObjectUtils.unwrapOptional(Optional!string.empty()) is null);
    assert(ObjectUtils.unwrapOptional(Optional!string.of("some value")) == "some value");
    // The nested-Optional half cannot be written yet: flint:java's Optional!(Optional!T) does not instantiate
    // (its stream() uses Optional as an associative-array key, which needs a const opEquals).
}

// Flint: the remaining helpers, and R14 for strings.
unittest
{
    assert(ObjectUtils.isArray([1]));
    assert(!ObjectUtils.isArray("text"));
    assert(!ObjectUtils.isArray(cast(int[]) null));
    assert(!ObjectUtils.isArray(new Object));
    assert(ObjectUtils.getDisplayString(cast(Object) null) == "");
    assert(ObjectUtils.getDisplayString("日本") == "日本");
    assert(ObjectUtils.getDisplayString(new Named("x")) == "x");
    assert(ObjectUtils.nullSafeClassName(null) == "null");
    assert(ObjectUtils.nullSafeClassName(42) == "java.lang.Integer");
    assert(ObjectUtils.nullSafeClassName(new Named("x")) == "flint.util.object_utils_test.Named");
    assert(ObjectUtils.nullSafeEquals(cast(string) null, null));
    assert(!ObjectUtils.nullSafeEquals("a", null));
    assert(!ObjectUtils.nullSafeEquals("1", 1));
    assert(!ObjectUtils.nullSafeEquals(1, 1L), "Java's Integer and Long are never equal");
    assert(ObjectUtils.nullSafeEquals(new Named("x"), new Named("x")) == false);
    assert(ObjectUtils.nullSafeHashCode("日本") == stringHashCode("日本"));
    assert(ObjectUtils.nullSafeHashCode(null) == 0);
    const concise = ObjectUtils.nullSafeConciseToString(repeat("日", 101));
    assert(concise == repeat("日", 100) ~ truncated);
    assert(ObjectUtils.nullSafeToString([1e20, 0.001, 1e-4, -0.0, double.nan]) == "{1.0E20, 0.001, 1.0E-4, -0.0, NaN}");
    expectThrows!Exception(() { ObjectUtils.addObjectToArray(["a"], "b", 2); });
    assert(ObjectUtils.isEmpty(["k": 1]) == false);
    assert(ObjectUtils.isEmpty(contains("a", "b")) == false);
}
