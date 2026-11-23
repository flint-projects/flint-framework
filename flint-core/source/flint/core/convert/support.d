// Ported from spring-framework v7.1.0: spring-core/src/main/java/org/springframework/core/convert/support
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
 * spring-core/src/main/java/org/springframework/core/convert/support/{ConfigurableConversionService,
 * GenericConversionService,DefaultConversionService,StringToBooleanConverter,StringToCharacterConverter,
 * StringToNumberConverterFactory,NumberToNumberConverterFactory,ObjectToStringConverter,
 * StringToEnumConverterFactory,EnumToStringConverter,StringToArrayConverter,StringToCollectionConverter,
 * ArrayToStringConverter,CollectionToStringConverter}.java. The converters are erased over canonical type names.
 */

/++
`org.springframework.core.convert.support`: the `ConversionService` implementations.

`DefaultConversionService` registers Spring's scalar converters: `string` to and from every D scalar (Java's
primitives and wrappers) with Spring's parsing rules, number to number with overflow checks, `string` to and from
integral enums (through `Descriptor.enumValues`), and comma-delimited `string` to and from `string[]`, `int[]`,
`long[]`, `List!string` and `Set!string`. Date and time, `ByteBuffer`, `Locale`, `Charset`, `UUID`, `Currency`,
`Pattern` and the reflective `ObjectToObjectConverter` are not registered (Phase 1; the reflective one never).

`getSharedInstance` returns a new instance on each call: Flint keeps no mutable module-level state (ADR-030
section 4), and a `DefaultConversionService` is cheap to build.
+/
module flint.core.convert.support;

import flint.core.convert : ConversionFailedException, ConversionService,
    ConverterNotFoundException, TypeDescriptor, scalarName;
import flint.core.convert.converter : ConditionalConverter, ConditionalGenericConverter,
    ConvertiblePair, ConverterRegistry, GenericConverter;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, DescriptorTable, TypeKind;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : Boolean, IllegalArgumentException, IllegalStateException, valueOf;
import flint.java.util : ArrayList, Collection, LinkedHashSet, List, RawCollection, Set;
import flint.util : NumberUtils, StringUtils;

@safe:

/// A `ConversionService` that is also a `ConverterRegistry`.
interface ConfigurableConversionService : ConversionService, ConverterRegistry
{
}

/++
Base `ConversionService` implementation suitable for use in most environments: converters are looked up by exact
source and target type names, then by the source's supertypes, then among conditional converters. Converters for one
pair are tried most recently added first; conditional converters registered for no pair, in registration order (as
Spring's `ConvertersForPair` and global converter set are).
+/
class GenericConversionService : ConfigurableConversionService
{
    private GenericConverter[][string] byPair;
    private GenericConverter[] conditional;
    private DescriptorTable descriptors;

    /// Descriptors used to resolve enum and supertype information for types known only by name.
    void setDescriptorTable(DescriptorTable table) pure nothrow @nogc
    {
        descriptors = table;
    }

    /// Add a generic converter: by its pairs, or as a conditional converter when it declares none.
    void addConverterErased(GenericConverter converter)
    {
        auto pairs = converter.getConvertibleTypes();
        if (pairs.length == 0)
        {
            if (cast(ConditionalConverter) converter is null)
                throw new IllegalStateException("Only conditional converters may return null convertible types");
            conditional ~= converter;
            return;
        }
        foreach (pair; pairs)
        {
            const key = pairKey(pair.sourceType, pair.targetType);
            byPair[key] = converter ~ byPair.get(key, null);
        }
    }

    /// Remove every converter for the pair.
    void removeConvertibleErased(string sourceType, string targetType)
    {
        byPair.remove(pairKey(sourceType, targetType));
    }

    /// Whether a converter exists for the pair (a null source type: anything converts null).
    bool canConvertErased(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        if (targetType is null)
            throw new IllegalArgumentException("Target type to convert to cannot be null");
        return sourceType is null || getConverter(sourceType, targetType) !is null;
    }

    /// Whether conversion between the types can be skipped because the source is already a target.
    bool canBypassConvert(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        if (targetType is null)
            throw new IllegalArgumentException("Target type to convert to cannot be null");
        return sourceType is null || resolve(sourceType).isAssignableTo(targetType);
    }

    /// Convert `source` from `sourceType` to `targetType`.
    Any convertErased(Any source, const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        if (targetType is null)
            throw new IllegalArgumentException("Target type to convert to cannot be null");
        if (sourceType is null)
        {
            if (!source.isNull)
                throw new IllegalArgumentException("Source must be [null] if source type == [null]");
            return convertNullSource(sourceType, targetType);
        }
        if (source.isNull)
            return convertNullSource(sourceType, targetType);
        checkSourceType(source, sourceType);
        auto converter = getConverter(sourceType, targetType);
        if (converter is null)
            throw new ConverterNotFoundException(sourceType, targetType);
        try
            return converter.convert(source, resolve(sourceType), resolve(targetType));
        catch (ConversionFailedException e)
            throw e;
        catch (Exception e)
            throw new ConversionFailedException(sourceType, targetType, source, e);
    }

    // Spring's `sourceType.getObjectType().isInstance(source)` check, for values held by type name: a reference is
    // checked by its converters (its static type may be a subtype of `sourceType`).
    private static void checkSourceType(Any source, const TypeDescriptor sourceType)
    {
        if (source.asObject() !is null || source.typeName == sourceType.getName())
            return;
        throw new IllegalArgumentException("Source to convert from must be an instance of [" ~ sourceType.getName()
                ~ "]; instead it was a [" ~ source.typeName ~ "]");
    }

    /// The value a null source converts to: `Any.init` (null), or an empty `Optional` (not yet: `Any.init`).
    protected Any convertNullSource(const TypeDescriptor, const TypeDescriptor)
    {
        return Any.init;
    }

    /++
    The converter for the pair, or null. As in Spring, each source type candidate (the type, then its supertypes)
    is checked against the converters registered for that exact pair, the most recent first and skipping
    conditional ones that do not match, and then against the conditional converters registered for no pair.
    +/
    protected GenericConverter getConverter(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        auto source = resolve(sourceType), target = resolve(targetType);
        foreach (candidateSource; [source.getName()] ~ supertypes(source))
        {
            if (auto found = pairKey(candidateSource, target.getName()) in byPair)
                foreach (converter; *found)
                    if (matches(converter, source, target))
                        return converter;
            foreach (converter; conditional)
                if ((cast(ConditionalConverter) converter).matches(source, target))
                    return converter;
        }
        return getDefaultConverter(source, target);
    }

    private static bool matches(GenericConverter converter, const TypeDescriptor source, const TypeDescriptor target)
    {
        auto candidate = cast(ConditionalConverter) converter;
        return candidate is null || candidate.matches(source, target);
    }

    /// The converter used when no other matches: a no-op when the source is assignable to the target.
    protected GenericConverter getDefaultConverter(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        return sourceType.isAssignableTo(targetType) ? new NoOpConverter : null;
    }

    /// `type`, completed with its descriptor from the descriptor table when it carries none.
    protected const(TypeDescriptor) resolve(const TypeDescriptor type)
    {
        if (type.getDescriptor() !is null || descriptors is null)
            return type;
        auto descriptor = descriptors.find(type.getName());
        return descriptor is null ? type : new TypeDescriptor(type.getName(), descriptor, type.getAnnotations());
    }

    private static string[] supertypes(const TypeDescriptor type)
    {
        string[] result = type.supertypeNames().dup;
        if (auto descriptor = type.getDescriptor())
            foreach (name; descriptor.supertypes)
                if (!contains(result, name))
                    result ~= name;
        return result;
    }

    private static bool contains(string[] names, string name) pure nothrow @nogc
    {
        foreach (candidate; names)
            if (candidate == name)
                return true;
        return false;
    }

    private static string pairKey(string sourceType, string targetType) pure
    {
        return sourceType ~ "\x1f" ~ targetType;
    }

    /// The registered converters, one per line.
    override string toString() const
    {
        string result = "ConversionService converters =\n";
        foreach (key, converters; byPair)
            foreach (converter; converters)
                result ~= "\t" ~ typeid(cast(const Object) converter).name ~ "\n";
        return result;
    }
}

private final class NoOpConverter : GenericConverter
{
    ConvertiblePair[] getConvertibleTypes()
    {
        return null;
    }

    Any convert(Any source, const TypeDescriptor, const TypeDescriptor)
    {
        return source;
    }
}

/++
A `GenericConversionService` configured with the converters appropriate for most environments.
+/
class DefaultConversionService : GenericConversionService
{
    /// A service with the default converters.
    this()
    {
        addDefaultConverters(this);
    }

    /// A new `DefaultConversionService` (see the module documentation on why it is not shared).
    static ConversionService getSharedInstance()
    {
        return new DefaultConversionService;
    }

    /// Add the default converters to `converterRegistry`.
    static void addDefaultConverters(ConverterRegistry converterRegistry)
    {
        addScalarConverters(converterRegistry);
        addCollectionConverters(converterRegistry);
    }

    /// Add the comma-delimited `string` to and from array and collection converters.
    static void addCollectionConverters(ConverterRegistry converterRegistry)
    {
        converterRegistry.addConverter(new StringToListConverter);
        converterRegistry.addConverter(new ListToStringConverter);
    }

    private static void addScalarConverters(ConverterRegistry converterRegistry)
    {
        converterRegistry.addConverter(new NumberToNumberConverter);
        converterRegistry.addConverter(new StringToScalarConverter);
        converterRegistry.addConverter(new ScalarToStringConverter);
        converterRegistry.addConverter(new StringToEnumConverter);
        converterRegistry.addConverter(new EnumToStringConverter);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Scalar converters

private bool integralName(string name) pure nothrow @nogc
{
    switch (name)
    {
    case "byte", "ubyte", "short", "ushort", "int", "uint", "long", "ulong":
        return true;
    default:
        return false;
    }
}

private bool floatingName(string name) pure nothrow @nogc
{
    return name == "float" || name == "double" || name == "real";
}

/// `string` to `bool`, `char` and the numbers, with Spring's rules: trimmed, empty is null.
private final class StringToScalarConverter : ConditionalGenericConverter
{
    ConvertiblePair[] getConvertibleTypes()
    {
        return null;
    }

    bool matches(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        return sourceType.getName() == "string" && scalarName(targetType.getName());
    }

    Any convert(Any source, const TypeDescriptor, const TypeDescriptor targetType)
    {
        const text = source.get!string;
        switch (targetType.getName())
        {
        case "bool":
            return toBoolean(text);
        case "char", "wchar", "dchar":
            return toCharacter(text, targetType.getName());
        default:
            // Spring's StringToNumberConverterFactory: only an empty string is null; NumberUtils trims the rest.
            if (text.length == 0)
                return Any.init;
            return parseNumber(StringUtils.trimAllWhitespace(text), targetType.getName());
        }
    }

    private static Any toBoolean(string source)
    {
        import flint.engine.aot.text : stripWhite;

        // ASCII lower case is enough: no other character lowers to a letter of these words, as String.toLowerCase.
        char[] lowered = stripWhite(source).dup;
        foreach (ref c; lowered)
            if (c >= 'A' && c <= 'Z')
                c += 'a' - 'A';
        const value = lowered;
        if (value.length == 0)
            return Any.init;
        switch (value)
        {
        case "true", "on", "yes", "1":
            return Any.of(true);
        case "false", "off", "no", "0":
            return Any.of(false);
        default:
            throw new IllegalArgumentException("Invalid boolean value '" ~ source ~ "'");
        }
    }

    private static Any toCharacter(string source, string target)
    {
        import flint.engine.aot.text : codePointCount, decodeUtf8, isValidUtf8;

        if (source.length == 0)
            return Any.init;
        if (!isValidUtf8(source))
            throw new IllegalArgumentException("Invalid UTF-8 sequence in '" ~ source ~ "'");
        const length = codePointCount(source);
        if (length > 1)
            throw new IllegalArgumentException("Can only convert a [String] with length of 1 to a [Character]; "
                    ~ "string value '" ~ source ~ "' has length of " ~ valueOf(length));
        size_t index;
        const c = decodeUtf8(source, index);
        if (target == "char")
        {
            if (c > 0x7F)
                throw new IllegalArgumentException("Character '" ~ source ~ "' does not fit a D char");
            return Any.of(cast(char) c);
        }
        return target == "wchar" ? Any.of(cast(wchar) c) : Any.of(c);
    }
}

/// Parse `text` as the scalar named `target` with `NumberUtils.parseNumber`.
private Any parseNumber(string text, string target)
{
    switch (target)
    {
    case "byte":
        return Any.of(NumberUtils.parseNumber!byte(text));
    case "ubyte":
        return Any.of(parseUnsigned!ubyte(text));
    case "short":
        return Any.of(NumberUtils.parseNumber!short(text));
    case "ushort":
        return Any.of(parseUnsigned!ushort(text));
    case "int":
        return Any.of(NumberUtils.parseNumber!int(text));
    case "uint":
        return Any.of(parseUnsigned!uint(text));
    case "long":
        return Any.of(NumberUtils.parseNumber!long(text));
    case "ulong":
        return Any.of(parseUnsigned!ulong(text));
    case "float":
        return Any.of(NumberUtils.parseNumber!float(text));
    default:
        return Any.of(NumberUtils.parseNumber!double(text));
    }
}

/// Parse an unsigned D integer (Java has none): `NumberUtils.parseNumber!long`, range-checked.
private T parseUnsigned(T)(string text)
{
    import flint.engine.aot.text : tryParseULong;

    static if (is(T == ulong))
    {
        const parsed = tryParseULong(text);
        if (parsed.ok)
            return parsed.value;
    }
    const value = NumberUtils.parseNumber!long(text);
    if (value < 0 || cast(ulong) value > T.max)
        throw new IllegalArgumentException("Could not convert number [" ~ text
                ~ "] of type [java.lang.Long] to target class [" ~ T.stringof ~ "]: overflow");
    return cast(T) value;
}

/// Scalars to `string` (Spring's `ObjectToStringConverter` for numbers, characters and booleans).
private final class ScalarToStringConverter : ConditionalGenericConverter
{
    ConvertiblePair[] getConvertibleTypes()
    {
        return null;
    }

    bool matches(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        return scalarName(sourceType.getName()) && targetType.getName() == "string";
    }

    Any convert(Any source, const TypeDescriptor sourceType, const TypeDescriptor)
    {
        if (floatingName(sourceType.getName()))
            return Any.of(valueOf(source.get!double));
        return Any.of(source.toString());
    }
}

/// Number to number, checking the range as `NumberUtils.convertNumberToTargetClass` does.
private final class NumberToNumberConverter : ConditionalGenericConverter
{
    ConvertiblePair[] getConvertibleTypes()
    {
        return null;
    }

    bool matches(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        const source = sourceType.getName(), target = targetType.getName();
        return source != target && (integralName(source) || floatingName(source))
            && (integralName(target) || floatingName(target));
    }

    Any convert(Any source, const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        const target = targetType.getName();
        if (floatingName(target))
            return target == "float" ? Any.of(source.get!float) : Any.of(source.get!double);
        if (floatingName(sourceType.getName()))
            return parseNumber(valueOf(cast(long) source.get!double), target);
        if (!fits(source, target))
            throw new IllegalArgumentException("Could not convert number [" ~ source.toString()
                    ~ "] of type [" ~ sourceType.getName() ~ "] to target class [" ~ target ~ "]: overflow");
        return parseNumber(source.toString(), target);
    }

    private static bool fits(Any source, string target)
    {
        switch (target)
        {
        case "byte":
            return source.holds!byte;
        case "ubyte":
            return source.holds!ubyte;
        case "short":
            return source.holds!short;
        case "ushort":
            return source.holds!ushort;
        case "int":
            return source.holds!int;
        case "uint":
            return source.holds!uint;
        case "long":
            return source.holds!long;
        default:
            return source.holds!ulong;
        }
    }
}

/// `string` to an integral enum, by constant name (Java's `Enum.valueOf`); empty is null.
private final class StringToEnumConverter : ConditionalGenericConverter
{
    ConvertiblePair[] getConvertibleTypes()
    {
        return null;
    }

    bool matches(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        return sourceType.getName() == "string" && targetType.isEnum();
    }

    Any convert(Any source, const TypeDescriptor, const TypeDescriptor targetType)
    {
        import flint.engine.aot.text : stripWhite;

        const text = source.get!string;
        if (text.length == 0)
            return Any.init;
        const name = stripWhite(text);
        auto descriptor = targetType.getDescriptor();
        foreach (i, constant; descriptor.enumConstants)
            if (constant == name && i < descriptor.enumValues.length)
                return Any.ofEnum(descriptor.name, descriptor.enumValues[i]);
        throw new IllegalArgumentException("No enum constant " ~ descriptor.name ~ "." ~ name);
    }
}

/// An integral enum to its constant name.
private final class EnumToStringConverter : ConditionalGenericConverter
{
    ConvertiblePair[] getConvertibleTypes()
    {
        return null;
    }

    bool matches(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        return sourceType.isEnum() && targetType.getName() == "string";
    }

    Any convert(Any source, const TypeDescriptor sourceType, const TypeDescriptor)
    {
        auto descriptor = sourceType.getDescriptor();
        foreach (i, value; descriptor.enumValues)
            if (value == source.enumBits)
                return Any.of(descriptor.enumConstants[i]);
        return Any.of(source.toString());
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Comma-delimited lists

private static immutable listTargets = [
    typeNameOf!(string[]), typeNameOf!(int[]), typeNameOf!(long[]), typeNameOf!(List!string),
    typeNameOf!(Set!string), typeNameOf!(Collection!string)
];

/// A comma-delimited `string` to `string[]`, `int[]`, `long[]`, `List!string`, `Set!string`, `Collection!string`.
private final class StringToListConverter : ConditionalGenericConverter
{
    ConvertiblePair[] getConvertibleTypes()
    {
        return null;
    }

    bool matches(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        if (sourceType.getName() != "string")
            return false;
        foreach (target; listTargets)
            if (target == targetType.getName())
                return true;
        return false;
    }

    Any convert(Any source, const TypeDescriptor, const TypeDescriptor targetType)
    {
        auto fields = StringUtils.commaDelimitedListToStringArray(source.get!string);
        foreach (ref field; fields)
            field = StringUtils.trimWhitespace(field);
        switch (targetType.getName())
        {
        case "string[]":
            return Any.of(fields);
        case "int[]":
            return Any.of(parseAll!int(fields));
        case "long[]":
            return Any.of(parseAll!long(fields));
        case typeNameOf!(Set!string):
            Set!string set = new LinkedHashSet!string(fields);
            return Any.of(set);
        default:
            List!string list = new ArrayList!string(fields);
            return Any.of(list);
        }
    }

    private static T[] parseAll(T)(string[] fields)
    {
        T[] result;
        foreach (field; fields)
            result ~= NumberUtils.parseNumber!T(field);
        return result;
    }
}

/// `string[]` and collections to a comma-delimited `string`.
private final class ListToStringConverter : ConditionalGenericConverter
{
    ConvertiblePair[] getConvertibleTypes()
    {
        return null;
    }

    bool matches(const TypeDescriptor sourceType, const TypeDescriptor targetType)
    {
        return targetType.getName() == "string" && (sourceType.getName() == "string[]" || sourceType.isCollection());
    }

    Any convert(Any source, const TypeDescriptor sourceType, const TypeDescriptor)
    {
        if (sourceType.getName() == "string[]")
            return Any.of(joinComma(source.get!(string[])));
        auto collection = cast(RawCollection) source.asObject();
        if (collection is null)
            return Any.of(source.toString());
        string[] parts;
        foreach (element; collection.toAnyArray())
            parts ~= element.isNull ? "null" : element.toString();
        return Any.of(joinComma(parts));
    }

    private static string joinComma(string[] parts)
    {
        string result;
        foreach (i, part; parts)
            result ~= (i ? "," : "") ~ part;
        return result;
    }
}
