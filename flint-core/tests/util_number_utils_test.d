// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.util.NumberUtilsTests` (v7.1.0): one `unittest` per Java test method,
each starting with a `// <JavaTestName>` comment. Java's `Class<T>` targets are template arguments (R4):
`Byte.class` is `byte`, `Integer.class` is `int`, and so on.

Skipped Java tests (14), with reasons:
- parseNumberUsingNumberFormat, parseNumberRequiringTrimUsingNumberFormat, parseOverflowUsingNumberFormat,
  parseNegativeOverflowUsingNumberFormat: `java.text.NumberFormat` is Locale-based (excluded).
- convertDoubleToBigInteger, convertBigDecimalToBigInteger, convertNonExactBigDecimalToBigInteger,
  parseBigDecimalNumber1, parseBigDecimalNumber2, parseBigDecimalNumber3, convertFloatingPointToBigInteger:
  `BigInteger`/`BigDecimal` targets are not ported in Phase 1 (deferred).
- parseLocalizedBigDecimalNumber1, parseLocalizedBigDecimalNumber2, parseLocalizedBigDecimalNumber3: `NumberFormat`
  and `BigDecimal`.

Adapted: the `BigInteger` rows of parseNumberAsHex, parseNumberAsPositiveHex and parseNumberAsNegativeHex are left
out; in convertToInteger and convertToLong, `BigInteger.valueOf(x)` sources become `long` (and `ulong` beyond
`Long.MAX_VALUE`, standing in for the `BigDecimal` overflow row); `BigInteger.valueOf(Long.MIN_VALUE - 1)` has no
D source type and is left out.
+/
module flint.util.number_utils_test;

import flint.java.lang : IllegalArgumentException, NumberFormatException;
import flint.util : NumberUtils;
import flint.util.test_support : expectThrows;

@safe:

private enum aByte = "127";
private enum aShort = "32767";
private enum anInteger = "2147483647";
private enum aLong = "9223372036854775807";
private enum aFloat = "3.4028235E38";
private enum aDouble = "1.7976931348623157E308";

private void assertToNumberOverflow(T, N)(N number)
{
    auto e = expectThrows!IllegalArgumentException(() {
        NumberUtils.convertNumberToTargetClass!T(number);
    });
    const message = e.getMessage();
    assert(message[$ - "overflow".length .. $] == "overflow", message);
}

// parseNumber
unittest
{
    assert(NumberUtils.parseNumber!byte(aByte) == byte.max, "Byte did not parse");
    assert(NumberUtils.parseNumber!short(aShort) == short.max, "Short did not parse");
    assert(NumberUtils.parseNumber!int(anInteger) == int.max, "Integer did not parse");
    assert(NumberUtils.parseNumber!long(aLong) == long.max, "Long did not parse");
    assert(NumberUtils.parseNumber!float(aFloat) == float.max, "Float did not parse");
    assert(NumberUtils.parseNumber!double(aDouble) == double.max, "Double did not parse");
}

// parseNumberRequiringTrim
unittest
{
    assert(NumberUtils.parseNumber!byte(" " ~ aByte ~ " ") == byte.max, "Byte did not parse");
    assert(NumberUtils.parseNumber!short(" " ~ aShort ~ " ") == short.max, "Short did not parse");
    assert(NumberUtils.parseNumber!int(" " ~ anInteger ~ " ") == int.max, "Integer did not parse");
    assert(NumberUtils.parseNumber!long(" " ~ aLong ~ " ") == long.max, "Long did not parse");
    assert(NumberUtils.parseNumber!float(" " ~ aFloat ~ " ") == float.max, "Float did not parse");
    assert(NumberUtils.parseNumber!double(" " ~ aDouble ~ " ") == double.max, "Double did not parse");
}

// parseNumberAsHex
unittest
{
    assert(NumberUtils.parseNumber!byte("0x7f") == byte.max, "Byte did not parse");
    assert(NumberUtils.parseNumber!short("0x7fff") == short.max, "Short did not parse");
    assert(NumberUtils.parseNumber!int("0x7fffffff") == int.max, "Integer did not parse");
    assert(NumberUtils.parseNumber!long("0x7fffffffffffffff") == long.max, "Long did not parse");
}

// parseNumberAsPositiveHex
unittest
{
    assert(NumberUtils.parseNumber!byte("+0x7f") == 127);
    assert(NumberUtils.parseNumber!short("+0X7fff") == 32_767);
    assert(NumberUtils.parseNumber!int("+#2a") == 42);
    assert(NumberUtils.parseNumber!long("+0x2a") == 42L);
}

// parseNumberAsNegativeHex
unittest
{
    assert(NumberUtils.parseNumber!byte("-0x80") == byte.min, "Byte did not parse");
    assert(NumberUtils.parseNumber!short("-0x8000") == short.min, "Short did not parse");
    assert(NumberUtils.parseNumber!int("-0x80000000") == int.min, "Integer did not parse");
    assert(NumberUtils.parseNumber!long("-0x8000000000000000") == long.min, "Long did not parse");
}

// parseOverflow
unittest
{
    expectThrows!IllegalArgumentException(() { NumberUtils.parseNumber!byte(aLong); });
    expectThrows!IllegalArgumentException(() { NumberUtils.parseNumber!short(aLong); });
    expectThrows!IllegalArgumentException(() { NumberUtils.parseNumber!int(aLong); });
    assert(NumberUtils.parseNumber!long(aLong) == long.max);
    assert(NumberUtils.parseNumber!double(aDouble) == double.max);
}

// parseNegativeOverflow
unittest
{
    const minLong = "-9223372036854775808";
    const minDouble = "4.9E-324";
    expectThrows!IllegalArgumentException(() { NumberUtils.parseNumber!byte(minLong); });
    expectThrows!IllegalArgumentException(() { NumberUtils.parseNumber!short(minLong); });
    expectThrows!IllegalArgumentException(() { NumberUtils.parseNumber!int(minLong); });
    assert(NumberUtils.parseNumber!long(minLong) == long.min);
    assert(NumberUtils.parseNumber!double(minDouble) == double.min_normal * double.epsilon);
}

private int toInt(N)(N number)
{
    return NumberUtils.convertNumberToTargetClass!int(number);
}

private long toLong(N)(N number)
{
    return NumberUtils.convertNumberToTargetClass!long(number);
}

// convertToInteger
unittest
{
    alias convert = toInt;
    assert(convert(-1L) == -1);
    assert(convert(0L) == 0);
    assert(convert(1L) == 1);
    assert(convert(cast(long) int.max) == int.max);
    assert(convert(cast(long)(int.max + 1)) == int.min);
    assert(convert(cast(long) int.min) == int.min);
    assert(convert(cast(long)(int.min - 1)) == int.max);
    assert(convert(-1) == -1);
    assert(convert(0) == 0);
    assert(convert(1) == 1);
    assert(convert(int.max) == int.max);
    assert(convert(int.max + 1) == int.min);
    assert(convert(int.min) == int.min);
    assert(convert(int.min - 1) == int.max);
    assert(convert(cast(short)-1) == -1);
    assert(convert(cast(short) 0) == 0);
    assert(convert(cast(short) 1) == 1);
    assert(convert(short.max) == short.max);
    assert(convert(cast(short)(short.max + 1)) == short.min);
    assert(convert(short.min) == short.min);
    assert(convert(cast(short)(short.min - 1)) == short.max);
    assert(convert(cast(byte)-1) == -1);
    assert(convert(cast(byte) 0) == 0);
    assert(convert(cast(byte) 1) == 1);
    assert(convert(byte.max) == byte.max);
    assert(convert(cast(byte)(byte.max + 1)) == byte.min);
    assert(convert(byte.min) == byte.min);
    assert(convert(cast(byte)(byte.min - 1)) == byte.max);
    assertToNumberOverflow!int(long.max + 1);
    assertToNumberOverflow!int(long.min - 1);
    assertToNumberOverflow!int(cast(long) int.max + 1);
    assertToNumberOverflow!int(cast(long) int.min - 1);
    assertToNumberOverflow!int(18_446_744_073_709_551_611UL);
}

// convertToLong
unittest
{
    alias convert = toLong;
    assert(convert(-1L) == -1);
    assert(convert(0L) == 0);
    assert(convert(1L) == 1);
    assert(convert(long.max) == long.max);
    assert(convert(long.max + 1) == long.min);
    assert(convert(long.min) == long.min);
    assert(convert(long.min - 1) == long.max);
    assert(convert(-1) == -1);
    assert(convert(0) == 0);
    assert(convert(1) == 1);
    assert(convert(int.max) == int.max);
    assert(convert(int.max + 1) == int.min);
    assert(convert(int.min) == int.min);
    assert(convert(int.min - 1) == int.max);
    assert(convert(cast(short)-1) == -1);
    assert(convert(cast(short) 0) == 0);
    assert(convert(cast(short) 1) == 1);
    assert(convert(short.max) == short.max);
    assert(convert(cast(short)(short.max + 1)) == short.min);
    assert(convert(short.min) == short.min);
    assert(convert(cast(short)(short.min - 1)) == short.max);
    assert(convert(cast(byte)-1) == -1);
    assert(convert(cast(byte) 0) == 0);
    assert(convert(cast(byte) 1) == 1);
    assert(convert(byte.max) == byte.max);
    assert(convert(cast(byte)(byte.max + 1)) == byte.min);
    assert(convert(byte.min) == byte.min);
    assert(convert(cast(byte)(byte.min - 1)) == byte.max);
    assertToNumberOverflow!long(cast(ulong) long.max + 1);
    assertToNumberOverflow!long(18_446_744_073_709_551_611UL);
}

// convertFloatingPointToLong
unittest
{
    import std.math : nextDown;

    alias convert = toLong;
    assert(convert(-1.5) == -1);
    assert(convert(1.5f) == 1);
    assert(convert(cast(double) long.min) == long.min);
    assert(convert(nextDown(0x1p63)) == 0x7FFF_FFFF_FFFF_FC00L);
    assertToNumberOverflow!long(0x1p63);
    assertToNumberOverflow!long(1e20);
    assertToNumberOverflow!long(-1e20);
    assertToNumberOverflow!long(1e20f);
    assertToNumberOverflow!long(double.infinity);
    assertToNumberOverflow!long(-double.infinity);
    assertToNumberOverflow!long(float.infinity);
    assertToNumberOverflow!long(-float.infinity);
    assertToNumberOverflow!long(double.nan);
    assertToNumberOverflow!long(float.nan);
    assertToNumberOverflow!int(double.nan);
    assertToNumberOverflow!short(double.nan);
    assertToNumberOverflow!byte(double.nan);
}

// Flint: Spring's and Java's messages, non-ASCII whitespace (R14), and floating-point syntax.
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        NumberUtils.convertNumberToTargetClass!long(1e20);
    });
    assert(e.getMessage() == "Could not convert number [1.0E20] of type [java.lang.Double] to target class "
            ~ "[java.lang.Long]: overflow");
    e = expectThrows!IllegalArgumentException(() {
        NumberUtils.convertNumberToTargetClass!byte(300);
    });
    assert(e.getMessage() == "Could not convert number [300] of type [java.lang.Integer] to target class "
            ~ "[java.lang.Byte]: overflow");
    auto nfe = expectThrows!NumberFormatException(() { NumberUtils.parseNumber!byte("128"); });
    assert(nfe.getMessage() == "Value out of range. Value:\"128\" Radix:10");
    nfe = expectThrows!NumberFormatException(() { NumberUtils.parseNumber!byte("0x80"); });
    assert(nfe.getMessage() == "Value 128 out of range from input 0x80");
    nfe = expectThrows!NumberFormatException(() { NumberUtils.parseNumber!int("abc"); });
    assert(nfe.getMessage() == "For input string: \"abc\"");
    nfe = expectThrows!NumberFormatException(() { NumberUtils.parseNumber!int("0xZZ"); });
    assert(nfe.getMessage() == "For input string: \"ZZ\" under radix 16");
    nfe = expectThrows!NumberFormatException(() { NumberUtils.parseNumber!long("0x-1"); });
    assert(nfe.getMessage() == "Sign character in wrong position");
    nfe = expectThrows!NumberFormatException(() { NumberUtils.parseNumber!double("1.2.3"); });
    assert(nfe.getMessage() == "For input string: \"1.2.3\"");
    nfe = expectThrows!NumberFormatException(() { NumberUtils.parseNumber!double(" "); });
    assert(nfe.getMessage() == "empty String");
    expectThrows!IllegalArgumentException(() { NumberUtils.parseNumber!int(null); });
    assert(NumberUtils.parseNumber!int("　 4  2 ") == 42);
    assert(NumberUtils.parseNumber!long("-#ff") == -255);
    assert(NumberUtils.parseNumber!double("1e3") == 1000);
    assert(NumberUtils.parseNumber!double("-.5d") == -0.5);
    assert(NumberUtils.parseNumber!float("2.5f") == 2.5f);
    assert(NumberUtils.parseNumber!double("0x1.8p1") == 3);
    assert(NumberUtils.parseNumber!double("-Infinity") == -double.infinity);
    const nan = NumberUtils.parseNumber!double("NaN");
    assert(nan != nan);
    assert(NumberUtils.convertNumberToTargetClass!double(3) == 3.0);
    assert(NumberUtils.convertNumberToTargetClass!float(0.5) == 0.5f);
}
