// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/*
 * Copyright 2002-present the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by the Flint authors: ported from spring-framework v7.1.0,
 * spring-core/src/test/java/org/springframework/core/convert/converter/DefaultConversionServiceTests.java (the cases
 * that apply to Flint's erased DefaultConversionService), followed by Flint tests of Spring's documented default
 * converters (StringToBooleanConverter, StringToCharacterConverter, StringToNumberConverterFactory,
 * StringToEnumConverterFactory, NumberToNumberConverterFactory and NumberUtils.convertNumberToTargetClass).
 *
 * D's `int` stands for `int` and `Integer`; a conversion whose Java result is null is checked through the erased
 * `convert(Any, TypeDescriptor, TypeDescriptor)`, since the typed façade returns `T.init` for null.
 *
 * Skipped Java tests (by reason):
 * - BigInteger, BigDecimal, Number, DataSize, CustomNumber (no D types; Number is abstract):
 *   stringToBigInteger, bigIntegerToString, stringToBigDecimal, bigDecimalToString, stringToNumber,
 *   stringToNumberEmptyString, stringToDataSizeWithInvalidString, stringToDataSizeWithEmptyString, stringToDataSize,
 *   numberToDataSizeConversionRejectsNumberWithFractionalPart, numberToDataSize, numberToNumberNotSupportedNumber.
 * - Locale, Charset, Currency, UUID, Pattern, TimeZone, java.time, java.util.Date/java.sql, Properties, streams and
 *   Optional are not registered (Phase 1): stringToLocale, stringToLocaleWithCountry, stringToLocaleWithLanguageTag,
 *   stringToCharset, charsetToString, stringToCurrency, currencyToString, uuidToStringAndStringToUuid,
 *   stringToPatternEmptyString, stringToPattern, patternToString, convertStringToTimezone,
 *   convertObjectToStringWithJavaTimeOfMethodPresent, convertObjectToObjectWithJavaTimeOfMethod,
 *   convertArrayToStream, convertPropertiesToString, convertStringToProperties,
 *   convertStringToPropertiesWithLeadingSpaces, convertDateToInstant, convertSqlDateToInstant,
 *   convertSqlTimeToInstant, convertSqlTimestampToInstant, convertInstantToDate, convertInstantToSqlTimestamp, and
 *   the nested OptionalConversionTests class: canConvertRawOptionalRemainsPermissive,
 *   canConvertOptionalWithUnboundedWildcardRemainsPermissive,
 *   canConvertOptionalWithUnresolvedTypeVariableRemainsPermissive,
 *   canConvertOptionalWithBoundedWildcardReflectsUpperBound, canConvertOptionalToObjectReflectsContainedElementType,
 *   convertObjectToOptional, convertNullToOptional, convertNullOptionalToNull, convertEmptyOptionalToNull,
 *   convertEmptyOptionalToOptional, convertOptionalToOptionalWithoutConversionOfContainedObject,
 *   convertOptionalToOptionalWithConversionOfContainedObject,
 *   convertOptionalToObjectWithoutConversionOfContainedObject,
 *   convertOptionalToObjectWithConversionOfContainedObject, convertNestedOptionalsToObject,
 *   convertOptionalToObjectViaTypeDescriptorForMethodParameter.
 * - Java enum subclasses and integer-to-enum by ordinal (IntegerToEnumConverterFactory, EnumToIntegerConverter are
 *   not registered): stringToEnumWithSubclass, integerToEnum, integerToEnumWithSubclass, enumToInteger.
 * - Number to and from Character (not registered): numberToCharacter, characterToNumber.
 * - Field reflection and generics introspection (`getClass().getField`, TypeDescriptor.collection/map, EnumSet,
 *   raw collections): stringToEnumSet, convertArrayToCollectionGenericTypeConversion, spr7766,
 *   convertCollectionToStringWithElementConversion, convertStringToCollectionWithElementConversion,
 *   convertCollectionToObjectAssignableTarget, convertObjectToCollectionWithElementConversion,
 *   convertCollectionToCollection, convertCollectionToCollectionNull, convertCollectionToCollectionNotGeneric,
 *   convertCollectionToCollectionSpecialCaseSourceImpl, collection, convertMapToMap, map, convertHashMapValuesToList,
 *   convertListOfNonStringifiable, convertListOfListToString, convertCannotOptimizeArray.
 * - Element-converting array/collection converters (ArrayToArray, ArrayToCollection, CollectionToArray,
 *   ArrayToObject, ObjectToArray, CollectionToObject, ObjectToCollection) are not ported:
 *   convertArrayToCollectionInterface, convertArrayToSetInterface, convertArrayToListInterface,
 *   convertArrayToCollectionImpl, convertArrayToAbstractCollection, convertArrayToStringWithElementConversion,
 *   convertStringToArrayWithElementConversion (Integer[]), convertArrayToObject, convertArrayToObjectWithElementConversion,
 *   convertArrayToObjectAssignableTargetType, convertObjectToArray, convertObjectToArrayWithElementConversion,
 *   convertCollectionToArray, convertCollectionToArrayWithElementConversion, convertCollectionToObject,
 *   convertCollectionToObjectWithElementConversion, convertCollectionToObjectWithCustomConverter,
 *   convertObjectToCollection, convertStringArrayToIntegerArray, convertStringArrayToIntArray,
 *   convertIntArrayToStringArray, convertIntegerArrayToIntegerArray, convertIntegerArrayToIntArray,
 *   convertIntArrayToIntegerArray, convertObjectArrayToIntegerArray, convertObjectArrayToIntArray,
 *   convertIntArrayToObjectArray, convertIntArrayToFloatArray, convertIntArrayToPrimitiveFloatArray,
 *   convertPrimitiveByteArrayToByteWrapperArray, convertPrimitiveByteArrayToPrimitiveByteArray,
 *   convertCharArrayToString, convertStringToCharArray, convertStringToCustomCharArray,
 *   multidimensionalArrayToListConversionShouldConvertEntriesCorrectly.
 * - ObjectToObjectConverter (reflective valueOf/of/from/constructor/finder lookup, never ported):
 *   convertObjectToStringWithValueOfMethodPresentUsingToString, convertObjectToObjectUsingValueOfMethod,
 *   convertObjectToStringUsingToString, convertObjectToObjectUsingObjectConstructor,
 *   convertObjectToStringNotSupported, convertObjectToObjectNoValueOfMethodOrConstructor,
 *   convertObjectToObjectFinderMethod, convertObjectToObjectFinderMethodWithNull,
 *   convertObjectToObjectFinderMethodWithIdConversion.
 */
module flint.core.convert_default_test;

import flint.core.convert : ConversionFailedException, TypeDescriptor;
import flint.core.convert.support : DefaultConversionService;
import flint.engine.aot.any : Any;
import flint.java.lang : IllegalArgumentException, NumberFormatException;
import flint.java.util : Collection, List;
import std.exception : collectException;
import std.format : format;

@safe:

private enum Foo
{
    BAR,
    BAZ,
}

private DefaultConversionService service()
{
    return new DefaultConversionService;
}

/// The erased conversion of the string `source` to `T`, for results that may be null.
private Any convertString(T)(string source)
{
    return service().convert(Any.of(source), TypeDescriptor.valueOf!string, TypeDescriptor.valueOf!T);
}

/// The message of the cause of the `ConversionFailedException` converting `source` to `T`.
private string failureCause(T, S)(S source)
{
    auto e = collectException!ConversionFailedException(service().convert!T(source));
    assert(e !is null, "expected a ConversionFailedException");
    assert(cast(IllegalArgumentException) e.getCause() !is null, e.getCause().msg);
    return e.getCause().msg;
}

unittest
{
    // stringToCharacter
    assert(service().convert!char("1") == '1');
}

unittest
{
    // stringToCharacterEmptyString
    assert(convertString!char("").isNull);
}

unittest
{
    // stringToCharacterInvalidString
    assert(collectException!ConversionFailedException(service().convert!char("invalid")) !is null);
}

unittest
{
    // characterToString
    assert(service().convert!string('3') == "3");
}

unittest
{
    // stringToBooleanTrue
    foreach (value; ["true", "on", "yes", "1", "TRUE", "ON", "YES"])
        assert(service().convert!bool(value), value);
}

unittest
{
    // stringToBooleanFalse
    foreach (value; ["false", "off", "no", "0", "FALSE", "OFF", "NO"])
        assert(!service().convert!bool(value), value);
}

unittest
{
    // stringToBooleanEmptyString
    assert(convertString!bool("").isNull);
}

unittest
{
    // stringToBooleanInvalidString
    assert(collectException!ConversionFailedException(service().convert!bool("invalid")) !is null);
}

unittest
{
    // booleanToString
    assert(service().convert!string(true) == "true");
}

unittest
{
    // stringToByte
    assert(service().convert!byte("1") == 1);
}

unittest
{
    // byteToString
    assert(service().convert!string(cast(byte) 'A') == "65");
}

unittest
{
    // stringToShort
    assert(service().convert!short("1") == 1);
}

unittest
{
    // shortToString
    const short three = 3;
    assert(service().convert!string(three) == "3");
}

unittest
{
    // stringToInteger
    assert(service().convert!int("1") == 1);
}

unittest
{
    // integerToString
    assert(service().convert!string(3) == "3");
}

unittest
{
    // stringToLong
    assert(service().convert!long("1") == 1L);
}

unittest
{
    // longToString
    assert(service().convert!string(3L) == "3");
}

unittest
{
    // stringToFloat
    assert(service().convert!float("1.0") == 1.0f);
}

unittest
{
    // floatToString
    assert(service().convert!string(1.0f) == "1.0");
}

unittest
{
    // stringToDouble
    assert(service().convert!double("1.0") == 1.0);
}

unittest
{
    // doubleToString
    assert(service().convert!string(1.0) == "1.0");
}

unittest
{
    // stringToEnum
    assert(service().convert!Foo("BAR") == Foo.BAR);
}

unittest
{
    // stringToEnumEmptyString
    assert(convertString!Foo("").isNull);
}

unittest
{
    // enumToString
    assert(service().convert!string(Foo.BAR) == "BAR");
}

unittest
{
    // integerToEnumNull
    assert(service().convert(Any.init, null, TypeDescriptor.valueOf!Foo).isNull);
}

unittest
{
    // stringToString
    const str = "test";
    assert(service().convert!string(str) is str);
}

unittest
{
    // numberToNumber
    assert(service().convert!long(1) == 1L);
}

unittest
{
    // convertArrayToString
    assert(service().convert!string(["1", "2", "3"]) == "1,2,3");
}

unittest
{
    // convertEmptyArrayToString
    // Spring returns ""; an empty D array is a null array, which converts to null (an empty string either way).
    string[] empty;
    assert(service().convert!string(empty).length == 0);
}

unittest
{
    // convertStringToArray
    assert(service().convert!(string[])("1,2,3") == ["1", "2", "3"]);
}

unittest
{
    // convertStringToPrimitiveArrayWithElementConversion
    assert(service().convert!(int[])("1,2,3") == [1, 2, 3]);
}

unittest
{
    // convertEmptyStringToArray
    assert(service().convert!(string[])("").length == 0);
}

unittest
{
    // convertCollectionToString
    auto list = List!string.of("foo", "bar");
    assert(service().convert!string(list) == "foo,bar");
}

unittest
{
    // convertStringToCollection
    auto result = service().convert!(List!string)("1,2,3");
    assert(result.toArray() == ["1", "2", "3"]);
}

unittest
{
    // convertEmptyStringToCollection
    auto result = service().convert!(Collection!string)("");
    assert(result !is null && result.isEmpty());
}

unittest
{
    // convertListOfStringToString
    auto list = List!string.of("Foo", "Bar");
    assert(service().canConvert!(List!string, string)());
    assert(service().convert!string(list) == "Foo,Bar");
}

unittest
{
    // convertIntArrayToIntArray
    int[] intArray = [1, 2, 3];
    const result = service().convert!(int[])(intArray);
    assert(result is intArray);
    assert(result == [1, 2, 3]);
}

// Flint tests of Spring's documented default conversions

unittest
{
    // StringToBooleanConverter: values are trimmed and case-insensitive; the message quotes the original value
    assert(service().convert!bool(" Yes "));
    assert(!service().convert!bool("\tOff\n"));
    assert(convertString!bool("   ").isNull);
    assert(failureCause!bool("maybe") == "Invalid boolean value 'maybe'");
}

unittest
{
    // StringToCharacterConverter: only a string of length 1 converts, and the message gives the length
    assert(failureCause!char("invalid") == "Can only convert a [String] with length of 1 to a [Character]; "
            ~ "string value 'invalid' has length of 7");
    assert(service().convert!dchar("é") == 'é');
}

unittest
{
    // StringToNumberConverterFactory: whitespace is trimmed, the full range of each type converts
    assert(service().convert!int(" 42 ") == 42);
    assert(service().convert!byte("-128") == byte.min);
    assert(service().convert!long("9223372036854775807") == long.max);
    assert(service().convert!short("-32768") == short.min);
}

unittest
{
    // StringToNumberConverterFactory: a value out of the target's range fails
    assert(collectException!ConversionFailedException(service().convert!byte("128")) !is null);
    assert(collectException!ConversionFailedException(service().convert!int("2147483648")) !is null);
    assert(collectException!ConversionFailedException(service().convert!int("12abc")) !is null);
}

unittest
{
    // NEEDS-UTIL: NumberUtils.parseNumber's Byte.decode/Integer.decode NumberFormatException
    // StringToNumberConverterFactory: overflow and garbage fail with a NumberFormatException cause
    version (none)
    {
        auto e = collectException!ConversionFailedException(service().convert!byte("128"));
        assert(e !is null && cast(NumberFormatException) e.getCause() !is null);
        e = collectException!ConversionFailedException(service().convert!int("12abc"));
        assert(e !is null && cast(NumberFormatException) e.getCause() !is null);
    }
}

unittest
{
    // NEEDS-UTIL: NumberUtils.parseNumber decodes hex ("0x", "0X", "#") and octal-free radix prefixes
    // StringToNumberConverterFactory: hex values
    version (none)
    {
        assert(service().convert!int("0x10") == 16);
        assert(service().convert!int("0X1F") == 31);
        assert(service().convert!long("#FF") == 255);
        assert(service().convert!int("-0x10") == -16);
        assert(service().convert!short("0x7FFF") == short.max);
        assert(collectException!ConversionFailedException(service().convert!byte("0x80")) !is null);
    }
}

unittest
{
    // StringToEnumConverterFactory: the constant name is trimmed; an unknown name fails like Enum.valueOf
    import std.string : indexOf;

    assert(service().convert!Foo(" BAZ ") == Foo.BAZ);
    const message = failureCause!Foo("QUX");
    assert(message.indexOf("No enum constant ") == 0 && message.indexOf("Foo.QUX") > 0, message);
}

unittest
{
    // NumberToNumberConverterFactory: widening and narrowing within range convert
    assert(service().convert!long(int.max) == int.max);
    assert(service().convert!byte(127) == 127);
    assert(service().convert!short(cast(long) short.min) == short.min);
    assert(service().convert!double(3) == 3.0);
    assert(service().convert!int(3.0) == 3);
}

unittest
{
    // NumberUtils.convertNumberToTargetClass: overflow fails with Spring's message
    enum overflow = "Could not convert number [%s] of type [%s] to target class [%s]: overflow";
    assert(failureCause!byte(300) == format(overflow, 300, "int", "byte"));
    assert(failureCause!int(long.max) == format(overflow, long.max, "long", "int"));
    assert(failureCause!ubyte(-1) == format(overflow, -1, "int", "ubyte"));
}

unittest
{
    // ConversionFailedException carries the source and target types and the value
    auto e = collectException!ConversionFailedException(service().convert!int("BOGUS"));
    assert(e !is null);
    assert(e.msg == "Failed to convert from type [string] to type [int] for value [BOGUS]", e.msg);
    assert(e.getSourceType().getName() == "string");
    assert(e.getTargetType().getName() == "int");
    assert(e.getValue().get!string == "BOGUS");
}

unittest
{
    // getSharedInstance returns a working DefaultConversionService
    assert(DefaultConversionService.getSharedInstance().convert!int("7") == 7);
}
