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
 * spring-core/src/test/java/org/springframework/core/convert/support/GenericConversionServiceTests.java.
 *
 * The service is erased (ADR-030 section 5): `canConvert(String.class, Integer.class)` is `canConvert!(string, int)`
 * and D's `int` stands for both `int` and `Integer`. Spring's package-private StringToNumberConverterFactory and
 * StringToBooleanConverter are not visible to this module: where a test registers one only to give the service a
 * string-to-number or string-to-boolean converter, it registers an equivalent delegate (R9). The default converters
 * themselves are tested in core_convert_default_test.d.
 *
 * Skipped Java tests:
 * - canConvertFromClassSourceTypeToNullTargetType, convertToNullTargetClass,
 *   canConvertIllegalArgumentNullTargetTypeFromClass: a Class token is a template parameter (R4) and cannot be null;
 *   the TypeDescriptor variants are ported.
 * - convertNullSourcePrimitiveTarget, convertNullSourcePrimitiveTargetTypeDescriptor: D has no primitive/wrapper
 *   distinction; a null source converts to null (`T.init`) for every target.
 * - addConverterNoSourceTargetClassInfoAvailable: a raw Converter has no D equivalent (generic types are known).
 * - listToObjectConversion, mapToObjectConversion, stringToObject: D's Object is not a supertype of strings, arrays
 *   or interfaces; Any plays Object's role.
 * - genericConverterDelegatingBackToConversionServiceConverterNotFound, interfaceArrayToStringArray,
 *   objectArrayToStringArray, emptyListToArray, emptyListToObject, stringToArrayCanConvert,
 *   stringToCollectionCanConvert: ObjectToArrayConverter, ArrayToArrayConverter, CollectionToArrayConverter,
 *   CollectionToObjectConverter and the element-converting StringToArray/StringToCollection converters are not
 *   ported (Phase 1).
 * - stringArrayToResourceArray: flint.core.io Resource is out of this module's scope.
 * - wildcardMap, conditionalConverterCachingForDifferentAnnotationAttributes, convertNullAnnotatedStringToString,
 *   multipleCollectionTypesFromSameSourceType, adaptedCollectionTypesFromSameSourceType, genericCollectionAsSource,
 *   rawCollectionAsSource, stringListToListOfSubclassOfUnboundGenericClass,
 *   stringToListOfMapConverterWithFallbackMatch: field reflection (`getClass().getField`) and generics introspection.
 * - conditionalConverterFactory, canConvertToEnumDoesNotThrowForNonEnumTargetType: ConverterFactory has no D
 *   equivalent (its role is played by conditional generic converters), and java.lang.Enum is not a D type.
 * - subclassOfEnumToString, enumWithInterfaceToStringConversion, stringToEnumWithInterfaceConversion,
 *   stringToEnumWithBaseInterfaceConversion: Java enum constant bodies and enums implementing interfaces.
 */
module flint.core.convert_test;

import flint.core.convert : ConversionFailedException, ConverterNotFoundException, TypeDescriptor;
import flint.core.convert.converter : ConditionalConverter, Converter, ConvertiblePair, GenericConverter;
import flint.core.convert.support : DefaultConversionService, GenericConversionService;
import flint.engine.aot.any : Any;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : Boolean, IllegalArgumentException, IllegalStateException, Integer,
    NumberFormatException, Iterable;
import flint.java.util : List;
import flint.util : StringUtils;
import std.exception : collectException;

@safe:

private class Color
{
    static immutable string BLACK_RGB = "000000";
    private string rgb;

    this(string rgb)
    {
        this.rgb = rgb;
    }

    static Color BLACK()
    {
        return new Color(BLACK_RGB);
    }

    override bool opEquals(Object other)
    {
        auto that = cast(Color) other;
        return that !is null && that.rgb == rgb;
    }

    override size_t toHash() nothrow
    {
        return hashOf(rgb);
    }
}

private class SystemColor : Color
{
    this(string rgb)
    {
        super(rgb);
    }
}

private class ColorConverter : Converter!(string, Color)
{
    Color convert(string source)
    {
        return new Color(source[0] == '#' ? source[1 .. $] : source);
    }
}

private class MyConditionalConverter : Converter!(string, Color), ConditionalConverter
{
    private int matchAttempts;

    bool matches(const TypeDescriptor, const TypeDescriptor)
    {
        matchAttempts++;
        return false;
    }

    Color convert(string)
    {
        return null;
    }

    int getMatchAttempts() const
    {
        return matchAttempts;
    }
}

private class NonConditionalGenericConverter : GenericConverter
{
    ConvertiblePair[] getConvertibleTypes()
    {
        return null;
    }

    Any convert(Any, const TypeDescriptor, const TypeDescriptor)
    {
        return Any.init;
    }
}

private class MyConditionalGenericConverter : GenericConverter, ConditionalConverter
{
    private const(TypeDescriptor)[] sourceTypes;

    ConvertiblePair[] getConvertibleTypes()
    {
        return null;
    }

    bool matches(const TypeDescriptor sourceType, const TypeDescriptor)
    {
        sourceTypes ~= sourceType;
        return false;
    }

    Any convert(Any, const TypeDescriptor, const TypeDescriptor)
    {
        return Any.init;
    }

    const(TypeDescriptor)[] getSourceTypes()
    {
        return sourceTypes;
    }
}

private interface MyBaseInterface
{
}

private interface MyInterface : MyBaseInterface
{
}

private class MyInterfaceImplementor : MyInterface
{
}

private class MyBaseInterfaceToStringConverter : Converter!(MyBaseInterface, string)
{
    string convert(MyBaseInterface)
    {
        return "RESULT";
    }
}

private class MyStringArrayToIntegerArrayConverter : Converter!(string[], int[])
{
    int[] convert(string[] source)
    {
        int[] result;
        foreach (s; source)
            result ~= Integer.parseInt(s[1 .. $]);
        return result;
    }
}

private class MyStringToIntegerArrayConverter : Converter!(string, int[])
{
    int[] convert(string source)
    {
        int[] result;
        foreach (s; StringUtils.commaDelimitedListToStringArray(source))
            result ~= Integer.parseInt(s[1 .. $]);
        return result;
    }
}

private class WithCopyConstructor
{
    this()
    {
    }

    this(WithCopyConstructor)
    {
    }
}

private enum MyEnum
{
    A,
    B,
    C,
}

/// The StringToNumberConverterFactory role for `int`: Spring's `Integer.valueOf`.
private void addStringToInt(GenericConversionService conversionService)
{
    conversionService.addConverter!(string, int)((string source) => Integer.parseInt(source));
}

unittest
{
    // canConvert
    auto conversionService = new GenericConversionService;
    assert(!conversionService.canConvert!(string, int)());
    addStringToInt(conversionService);
    assert(conversionService.canConvert!(string, int)());
}

unittest
{
    // canConvertAssignable
    auto conversionService = new GenericConversionService;
    assert(conversionService.canConvert!(string, string)());
    assert(conversionService.canConvert!(SystemColor, Color)()); // Java: Integer to Number
    assert(conversionService.canConvert!(bool, bool)());
}

unittest
{
    // canConvertFromTypeDescriptorSourceTypeToNullTargetType
    auto conversionService = new GenericConversionService;
    const e = collectException!IllegalArgumentException(
            conversionService.canConvert(TypeDescriptor.valueOf!string, null));
    assert(e !is null && e.msg == "Target type to convert to cannot be null");
}

unittest
{
    // canConvertNullSourceType
    auto conversionService = new GenericConversionService;
    assert(conversionService.canConvert(null, TypeDescriptor.valueOf!int));
}

unittest
{
    // convert
    auto conversionService = new GenericConversionService;
    addStringToInt(conversionService);
    assert(conversionService.convert!int("3") == 3);
}

unittest
{
    // convertNullSource
    auto conversionService = new GenericConversionService;
    assert(conversionService.convert(Any.init, null, TypeDescriptor.valueOf!int).isNull);
}

unittest
{
    // convertNotNullSourceNullSourceTypeDescriptor
    auto conversionService = new GenericConversionService;
    const e = collectException!IllegalArgumentException(conversionService.convert(Any.of("3"),
            null, TypeDescriptor.valueOf!int));
    assert(e !is null && e.msg == "Source must be [null] if source type == [null]");
}

unittest
{
    // convertAssignableSource
    auto conversionService = new GenericConversionService;
    assert(!conversionService.convert!bool(false));
}

unittest
{
    // converterNotFound
    auto conversionService = new GenericConversionService;
    auto e = collectException!ConverterNotFoundException(conversionService.convert!int("3"));
    assert(e !is null);
    assert(e.msg == "No converter found capable of converting from type [string] to type [int]", e.msg);
    assert(e.getSourceType().getName() == "string" && e.getTargetType().getName() == "int");
}

unittest
{
    // sourceTypeIsVoid
    auto conversionService = new GenericConversionService;
    assert(!conversionService.canConvert!(void, string)());
}

unittest
{
    // targetTypeIsVoid
    auto conversionService = new GenericConversionService;
    assert(!conversionService.canConvert!(string, void)());
}

unittest
{
    // convertNull
    auto conversionService = new GenericConversionService;
    assert(conversionService.convert!(Color, Any)(Any.init) is null);
}

unittest
{
    // convertToNullTargetTypeDescriptor
    auto conversionService = new GenericConversionService;
    const e = collectException!IllegalArgumentException(conversionService.convert(Any.of("3"),
            TypeDescriptor.valueOf!string, null));
    assert(e !is null && e.msg == "Target type to convert to cannot be null");
}

unittest
{
    // convertWrongSourceTypeDescriptor
    auto conversionService = new GenericConversionService;
    const e = collectException!IllegalArgumentException(conversionService.convert(Any.of("3"),
            TypeDescriptor.valueOf!int, TypeDescriptor.valueOf!long));
    assert(e !is null && e.msg == "Source to convert from must be an instance of [int]; instead it was a [string]",
            e.msg);
}

unittest
{
    // convertWrongTypeArgument
    auto conversionService = new GenericConversionService;
    addStringToInt(conversionService);
    auto e = collectException!ConversionFailedException(conversionService.convert!int("BOGUS"));
    assert(e !is null);
    assert(e.msg == "Failed to convert from type [string] to type [int] for value [BOGUS]", e.msg);
    assert(cast(NumberFormatException) e.getCause() !is null);
    assert(e.getValue().get!string == "BOGUS");
}

unittest
{
    // convertSuperSourceType
    auto conversionService = new GenericConversionService;
    // Java registers CharSequence -> Integer and converts a String; here the source is a MyBaseInterface.
    conversionService.addConverter!(MyBaseInterface, int)((MyBaseInterface) => 3);
    const result = conversionService.convert!int(new MyInterfaceImplementor);
    assert(result == 3);
}

unittest
{
    // convertSuperTarget
    auto conversionService = new GenericConversionService;
    conversionService.addConverter(new ColorConverter);
    assert(collectException!ConverterNotFoundException(conversionService.convert!SystemColor("#000000")) !is null);
}

unittest
{
    // convertObjectToPrimitive
    auto conversionService = new GenericConversionService;
    assert(!conversionService.canConvert!(string, bool)());
    conversionService.addConverter!(string, bool)((string source) => Boolean.parseBoolean(source));
    assert(conversionService.canConvert!(string, bool)());
    assert(conversionService.convert!bool("true"));
    assert(conversionService.canConvert(TypeDescriptor.valueOf!string, TypeDescriptor.valueOf!bool));
    assert(conversionService.convert(Any.of("true"), TypeDescriptor.valueOf!string,
            TypeDescriptor.valueOf!bool).get!bool);
}

unittest
{
    // convertObjectToPrimitiveViaConverterFactory
    auto conversionService = new GenericConversionService;
    assert(!conversionService.canConvert!(string, int)());
    addStringToInt(conversionService);
    assert(conversionService.canConvert!(string, int)());
    assert(conversionService.convert!int("3") == 3);
}

unittest
{
    // listToIterableConversion
    auto conversionService = new GenericConversionService;
    auto raw = List!string.of("one", "two");
    const converted = conversionService.convert!(Iterable!string)(raw);
    assert(cast(const Object) converted is cast(const Object) raw);
}

unittest
{
    // interfaceToString
    auto conversionService = new GenericConversionService;
    conversionService.addConverter(new MyBaseInterfaceToStringConverter);
    assert(conversionService.convert!string(new MyInterfaceImplementor) == "RESULT");
}

unittest
{
    // stringArrayToIntegerArray
    auto conversionService = new GenericConversionService;
    conversionService.addConverter(new MyStringArrayToIntegerArrayConverter);
    assert(conversionService.convert!(int[])(["x1", "z3"]) == [1, 3]);
}

unittest
{
    // stringToIntegerArray
    auto conversionService = new GenericConversionService;
    conversionService.addConverter(new MyStringToIntegerArrayConverter);
    assert(conversionService.convert!(int[])("x1,z3") == [1, 3]);
}

unittest
{
    // stringToString
    auto conversionService = new GenericConversionService;
    const value = "myValue";
    const result = conversionService.convert!string(value);
    assert(result is value);
}

unittest
{
    // ignoreCopyConstructor
    auto conversionService = new GenericConversionService;
    auto value = new WithCopyConstructor;
    assert(conversionService.convert!WithCopyConstructor(value) is value);
}

unittest
{
    // convertiblePairsInSet
    bool[ConvertiblePair] set;
    set[ConvertiblePair(typeNameOf!int, typeNameOf!string)] = true;
    assert((ConvertiblePair(typeNameOf!int, typeNameOf!string) in set) !is null);
}

unittest
{
    // convertiblePairEqualsAndHash
    const pair = ConvertiblePair(typeNameOf!int, typeNameOf!string);
    const pairEqual = ConvertiblePair(typeNameOf!int, typeNameOf!string);
    assert(pairEqual == pair);
    assert(hashOf(pairEqual) == hashOf(pair));
}

unittest
{
    // convertiblePairDifferentEqualsAndHash
    const pair = ConvertiblePair(typeNameOf!int, typeNameOf!string);
    const pairOpposite = ConvertiblePair(typeNameOf!string, typeNameOf!int);
    assert(pair != pairOpposite);
    assert(hashOf(pair) != hashOf(pairOpposite));
}

unittest
{
    // canConvertIllegalArgumentNullTargetTypeFromTypeDescriptor
    auto conversionService = new GenericConversionService;
    assert(collectException!IllegalArgumentException(
            conversionService.canConvert(TypeDescriptor.valueOf!string, null)) !is null);
}

unittest
{
    // removeConvertible
    auto conversionService = new GenericConversionService;
    conversionService.addConverter(new ColorConverter);
    assert(conversionService.canConvert!(string, Color)());
    conversionService.removeConvertible!(string, Color)();
    assert(!conversionService.canConvert!(string, Color)());
}

unittest
{
    // conditionalConverter
    import flint.engine.aot.objects : objectEquals;

    auto conversionService = new GenericConversionService;
    auto converter = new MyConditionalConverter;
    conversionService.addConverter(new ColorConverter);
    conversionService.addConverter(converter);
    assert(objectEquals(conversionService.convert!Color("#000000"), Color.BLACK));
    assert(converter.getMatchAttempts() > 0);
}

unittest
{
    // shouldNotSupportNullConvertibleTypesFromNonConditionalGenericConverter
    auto conversionService = new GenericConversionService;
    GenericConverter converter = new NonConditionalGenericConverter;
    const e = collectException!IllegalStateException(conversionService.addConverter(converter));
    assert(e !is null && e.msg == "Only conditional converters may return null convertible types");
}

unittest
{
    // conditionalConversionForAllTypes
    auto conversionService = new GenericConversionService;
    auto converter = new MyConditionalGenericConverter;
    conversionService.addConverter(converter);
    assert(conversionService.convert!int(3) == 3);
    // Java walks Integer's class hierarchy (more than two candidates); a D int has no supertypes.
    assert(converter.getSourceTypes().length >= 1);
    foreach (td; converter.getSourceTypes())
        assert(td.getType() == "int");
}

unittest
{
    // convertOptimizeArray
    auto conversionService = new GenericConversionService;
    byte[] byteArray = [1, 2, 3];
    const converted = conversionService.convert!(byte[])(byteArray);
    assert(converted is byteArray);
    assert(converted == [1, 2, 3]);
}

unittest
{
    // enumToStringConversion
    // Java adds EnumToStringConverter, which is package-private; DefaultConversionService registers it.
    auto conversionService = new DefaultConversionService;
    assert(conversionService.convert!string(MyEnum.A) == "A");
}
