/++
`org.springframework.web.bind.support`: the data-binder factory handed to argument resolvers.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/bind/support/WebDataBinderFactory.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: `WebDataBinder` comes with spring-context's `DataBinder` (framework-core); until then
the factory converts single request values, which is what the named-value resolvers ask of it, with
`DefaultConversionService`'s string rules and Spring's message wording (`SimpleConversion`, package-private).
+/
module flint.web.bind.support;

import flint.core : MethodParameter;
import flint.core.convert : ConversionFailedException, TypeDescriptor;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable;
import flint.web.context.request : NativeWebRequest;

@safe:

/// `WebDataBinderFactory`, reduced to the conversion the named-value resolvers use.
interface WebDataBinderFactory
{
    /// Converts a request value (`string` or `string[]`) to `parameter`'s type. Throws `ConversionFailedException`.
    Any convertIfNecessary(Any value, string targetType, MethodParameter parameter);
}

/// The default factory: Spring's `DefaultFormattingConversionService` rules for request values. `Optional!T` targets
/// wrap through the type's descriptor (`ObjectToOptionalConverter`), so the table must describe them.
class DefaultDataBinderFactory : WebDataBinderFactory
{
    private DescriptorTable descriptors;

    /// With the descriptors of the `Optional!T`, array and collection parameter types (may be `null`).
    this(DescriptorTable descriptors = null) pure nothrow @nogc
    {
        this.descriptors = descriptors;
    }

    Any convertIfNecessary(Any value, string targetType, MethodParameter parameter)
    {
        if (isOptionalType(targetType))
            return toOptional(value, targetType, parameter);
        if (value.isNull())
            return value;
        if (value.typeName() == targetType)
            return value;
        if (value.holds!(string[]))
            return fromArray(value.get!(string[]), targetType);
        if (value.holds!string)
            return SimpleConversion.convert(value.get!string, targetType);
        return value;
    }

    // ObjectToOptionalConverter: null becomes `Optional.empty()`, anything else is converted to the element type
    // and wrapped. Without a descriptor for the optional type, the element value is returned unwrapped.
    private Any toOptional(Any value, string targetType, MethodParameter parameter)
    {
        if (value.typeName() == targetType)
            return value;
        auto descriptor = descriptors is null ? null : descriptors.find(targetType);
        string elementType = descriptor !is null ? descriptor.elementType : null;
        if (elementType.length == 0)
            elementType = parameter !is null && parameter.getParameterType() == targetType
                ? parameter.getNestedParameterType() : optionalElement(targetType);
        auto element = convertIfNecessary(value, elementType, parameter);
        if (descriptor is null || descriptor.wrap is null)
            return element;
        return descriptor.wrap(element);
    }

    private Any fromArray(string[] values, string targetType)
    {
        if (targetType == "string")
        {
            // ArrayToStringConverter: join with ','.
            string joined;
            foreach (i, v; values)
                joined ~= (i == 0 ? "" : ",") ~ v;
            return Any.of(joined);
        }
        if (targetType == "string[]")
            return Any.of(values);
        if (SimpleConversion.isArray(targetType))
            return SimpleConversion.convertEach(values, targetType);
        // ArrayToArrayConverter and ArrayToCollectionConverter through the target type's descriptor.
        auto descriptor = descriptors is null ? null : descriptors.find(targetType);
        if (descriptor !is null && descriptor.fromElements !is null && descriptor.elementType.length)
        {
            Any[] elements;
            foreach (v; values)
                elements ~= SimpleConversion.convert(v, descriptor.elementType);
            return descriptor.fromElements(elements);
        }
        // ArrayToObjectConverter: the first element.
        return values.length == 0 ? Any.init : SimpleConversion.convert(values[0], targetType);
    }

    private static bool isOptionalType(string type) pure nothrow @nogc
    {
        enum prefix = "flint.java.util.Optional!";
        return type.length > prefix.length && type[0 .. prefix.length] == prefix;
    }

    private static string optionalElement(string type) pure nothrow @nogc
    {
        enum prefix = "flint.java.util.Optional!";
        auto rest = type[prefix.length .. $];
        return rest.length > 1 && rest[0] == '(' && rest[$ - 1] == ')' ? rest[1 .. $ - 1] : rest;
    }
}

/// Interim stand-in for spring-core's `ConversionService`, for the string-to-type conversion of request
/// values: scalars, `string`, `bool`, `java.time` values, and arrays of them by comma splitting. As Spring's
/// `StringToBooleanConverter`, number, character and formatter-based converters do, a blank value converts to
/// null. Throws `ConversionFailedException`.
package(flint) struct SimpleConversion
{
    import flint.engine.aot.any : Any;

    /// Whether `targetType` is one this converter handles.
    static bool canConvert(string targetType) pure nothrow @nogc
    {
        switch (targetType)
        {
        case "string", "bool", "byte", "ubyte", "short", "ushort", "int", "uint", "long", "ulong",
                "float", "double", "char", "string[]", "int[]", "long[]", localDate, localTime,
                localDateTime, instant, offsetDateTime, zonedDateTime:
                return true;
        default:
            return false;
        }
    }

    private enum localDate = "flint.java.time.LocalDate";
    private enum localTime = "flint.java.time.LocalTime";
    private enum localDateTime = "flint.java.time.LocalDateTime";
    private enum instant = "flint.java.time.Instant";
    private enum offsetDateTime = "flint.java.time.OffsetDateTime";
    private enum zonedDateTime = "flint.java.time.ZonedDateTime";

    /// Whether `targetType` is an array type `convertEach` builds.
    static bool isArray(string targetType) pure nothrow @nogc
    {
        return targetType == "string[]" || targetType == "int[]" || targetType == "long[]";
    }

    /// Each of `values` converted to the element type of `targetType` (`ArrayToArrayConverter`).
    static Any convertEach(string[] values, string targetType)
    {
        switch (targetType)
        {
        case "int[]":
            return Any.of(convertAll!int(values, "int"));
        case "long[]":
            return Any.of(convertAll!long(values, "long"));
        default:
            return Any.of(values);
        }
    }

    private static T[] convertAll(T)(string[] values, string elementType)
    {
        T[] result;
        foreach (v; values)
        {
            auto element = convert(v, elementType);
            if (element.isNull())
                throw conversionFailed(elementType ~ "[]", v, null);
            result ~= element.get!T;
        }
        return result;
    }

    /// `value` converted to `targetType`; null for a blank value and a non-string target.
    static Any convert(string value, string targetType)
    {
        import flint.java.time : DateTimeException;
        import std.conv : ConvException, to;
        import std.string : strip;

        if (targetType != "string" && !isArray(targetType) && (targetType == "char"
                ? value.length == 0 : value.strip.length == 0))
            return Any.init;
        try
        {
            switch (targetType)
            {
            case "string":
                return Any.of(value);
            case localDate, localTime, localDateTime, instant, offsetDateTime, zonedDateTime:
                return parseTemporal(value.strip, targetType);
            case "bool":
                return Any.of(parseBoolean(value));
            case "byte":
                return Any.of(value.strip.to!byte);
            case "ubyte":
                return Any.of(value.strip.to!ubyte);
            case "short":
                return Any.of(value.strip.to!short);
            case "ushort":
                return Any.of(value.strip.to!ushort);
            case "int":
                return Any.of(value.strip.to!int);
            case "uint":
                return Any.of(value.strip.to!uint);
            case "long":
                return Any.of(value.strip.to!long);
            case "ulong":
                return Any.of(value.strip.to!ulong);
            case "float":
                return Any.of(value.strip.to!float);
            case "double":
                return Any.of(value.strip.to!double);
            case "char":
                if (value.length != 1)
                    throw new ConvException("not a single character");
                return Any.of(value[0]);
            case "string[]":
                return Any.of(splitComma(value));
            case "int[]":
                {
                    int[] result;
                    foreach (part; splitComma(value))
                        result ~= part.strip.to!int;
                    return Any.of(result);
                }
            case "long[]":
                {
                    long[] result;
                    foreach (part; splitComma(value))
                        result ~= part.strip.to!long;
                    return Any.of(result);
                }
            default:
                throw conversionFailed(targetType, value, null);
            }
        }
        catch (ConvException e)
            throw conversionFailed(targetType, value,
                    new imported!"flint.java.lang".NumberFormatException(forInput(value)));
        catch (DateTimeException e)
            throw conversionFailed(targetType, value, e);
    }

    // TemporalAccessorParser's ISO fallback (`LocalDate.parse(text)` and the like); the localized SHORT style is
    // not ported.
    private static Any parseTemporal(string text, string targetType)
    {
        import flint.java.time : Instant, LocalDate, LocalDateTime, LocalTime, OffsetDateTime, ZonedDateTime;

        switch (targetType)
        {
        case localDate:
            return Any.of(LocalDate.parse(text));
        case localTime:
            return Any.of(LocalTime.parse(text));
        case localDateTime:
            return Any.of(LocalDateTime.parse(text));
        case instant:
            return Any.of(Instant.parse(text));
        case offsetDateTime:
            return Any.of(OffsetDateTime.parse(text));
        default:
            return Any.of(ZonedDateTime.parse(text));
        }
    }

    /// The real `ConversionFailedException`, with Java's type names as Spring's message prints them.
    private static ConversionFailedException conversionFailed(string targetType, string value, Throwable cause)
    {
        return new ConversionFailedException(new TypeDescriptor("java.lang.String"),
                new TypeDescriptor(javaTypeName(targetType)), Any.of(value), cause);
    }

    private static string forInput(string value) pure nothrow
    {
        return "For input string: \"" ~ value ~ "\"";
    }

    private static bool parseBoolean(string value)
    {
        import std.conv : ConvException;
        import std.uni : toLower;

        switch (value.toLower)
        {
        case "true", "on", "yes", "1":
            return true;
        case "false", "off", "no", "0":
            return false;
        default:
            throw new ConvException("Invalid boolean value '" ~ value ~ "'");
        }
    }

    private static string[] splitComma(string value) pure nothrow
    {
        string[] result;
        size_t start;
        foreach (i, c; value)
            if (c == ',')
            {
                result ~= value[start .. i];
                start = i + 1;
            }
        result ~= value[start .. $];
        return result;
    }
}

/// Java's name for a D scalar type, as Spring's messages print it (`long` → `long`, `string` → `java.lang.String`).
package(flint) string javaTypeName(string type) pure nothrow
{
    switch (type)
    {
    case "string":
        return "java.lang.String";
    case "bool":
        return "boolean";
    case "ubyte":
        return "byte";
    case "ushort":
        return "short";
    case "uint":
        return "int";
    case "ulong":
        return "long";
    case "string[]":
        return "java.lang.String[]";
    default:
        enum prefix = "flint.java.";
        return type.length > prefix.length && type[0 .. prefix.length] == prefix ? type["flint.".length .. $] : type;
    }
}
