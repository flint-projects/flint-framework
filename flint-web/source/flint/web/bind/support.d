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
import flint.web.context.request : NativeWebRequest;

@safe:

/// `WebDataBinderFactory`, reduced to the conversion the named-value resolvers use.
interface WebDataBinderFactory
{
    /// Converts a request value (`string` or `string[]`) to `parameter`'s type. Throws `ConversionFailedException`.
    Any convertIfNecessary(Any value, string targetType, MethodParameter parameter);
}

/// The default factory: Spring's `DefaultConversionService` rules for request values.
class DefaultDataBinderFactory : WebDataBinderFactory
{
    Any convertIfNecessary(Any value, string targetType, MethodParameter parameter)
    {
        if (value.isNull())
            return value;
        if (value.typeName() == targetType)
            return value;
        if (value.holds!(string[]))
        {
            auto values = value.get!(string[]);
            if (targetType == "string")
            {
                // ArrayToStringConverter: join with ','.
                string joined;
                foreach (i, v; values)
                    joined ~= (i == 0 ? "" : ",") ~ v;
                return Any.of(joined);
            }
            if (targetType == "string[]")
                return value;
            // ArrayToObjectConverter: the first element.
            return values.length == 0 ? Any.init : SimpleConversion.convert(values[0], targetType);
        }
        if (value.holds!string)
            return SimpleConversion.convert(value.get!string, targetType);
        return value;
    }
}

/// Interim stand-in for spring-core's `ConversionService`, for the string-to-type conversion of request
/// values: scalars, `string`, `bool`, and arrays of them by comma splitting. Throws `ConversionFailedException`.
package(flint) struct SimpleConversion
{
    import flint.engine.aot.any : Any;

    /// Whether `targetType` is one this converter handles.
    static bool canConvert(string targetType) pure nothrow @nogc
    {
        switch (targetType)
        {
        case "string", "bool", "byte", "ubyte", "short", "ushort", "int", "uint", "long", "ulong",
                "float", "double", "char", "string[]", "int[]", "long[]":
                return true;
        default:
            return false;
        }
    }

    /// `value` converted to `targetType`.
    static Any convert(string value, string targetType)
    {
        import std.conv : ConvException, to;
        import std.string : strip;

        try
        {
            switch (targetType)
            {
            case "string":
                return Any.of(value);
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
        return type;
    }
}
