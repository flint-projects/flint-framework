/++
`org.springframework.web.method.annotation`: resolvers for annotated handler parameters, and exception-handler
method lookup.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/method/annotation/ (AbstractNamedValueMethodArgumentResolver.java,
RequestParamMethodArgumentResolver.java, RequestHeaderMethodArgumentResolver.java,
AbstractCookieValueMethodArgumentResolver.java, ExceptionHandlerMethodResolver.java,
MethodArgumentTypeMismatchException.java, MethodArgumentConversionNotSupportedException.java) and
spring-beans' TypeMismatchException.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: annotations are read from Flint AOT's merged annotations on each `ArgumentSpec`
(contract 1 section 4.5); exception types are matched by class name along the thrown object's class chain, as
`ExceptionDepthComparator` measures depth. They skip backtrace capture (ADR-030 section 4).
+/
module flint.web.method.annotation;

import flint.core : MethodParameter, causeOf;
import flint.core.convert : ConversionFailedException;
import flint.web.bind.support : javaTypeName;
import flint.engine.aot.any : Any;
import flint.engine.aot.mapping : ArgumentKind, ExceptionHandlerSpec;
import flint.jakarta.servlet.http : Cookie, HttpServletRequest;
import flint.java.lang : IllegalStateException, RuntimeException;
import flint.web : skipBacktrace;
import flint.web.bind : MissingRequestCookieException, MissingRequestHeaderException,
    MissingServletRequestParameterException, simpleJavaName;
import flint.web.bind.annotation : ValueConstants;
import flint.web.bind.support : WebDataBinderFactory;
import flint.web.context.request : NativeWebRequest;
import flint.web.method.support : HandlerMethodArgumentResolver, ModelAndViewContainer;

@safe:

/// `org.springframework.beans.TypeMismatchException`, reduced to type names (R4).
class TypeMismatchException : RuntimeException
{
    private Any value;
    private string requiredType;
    private string propertyName;

    ///
    this(Any value, string requiredType, Throwable cause)
    {
        super("Failed to convert value of type '" ~ valueTypeName(
                value) ~ "' to required type '" ~ javaTypeName(requiredType) ~ "'" ~ causeText(cause), cause);
        this.value = value;
        this.requiredType = requiredType;
        skipBacktrace(this);
    }

    private static string causeText(Throwable cause)
    {
        if (cause is null)
            return "";
        // ConversionFailedException wraps the parse failure; Spring prints the innermost message.
        auto inner = causeOf(cause) !is null ? causeOf(cause) : cause;
        return "; " ~ inner.msg;
    }

    /// The value that could not be converted.
    Any getValue() pure nothrow @nogc
    {
        return value;
    }

    /// The required type name.
    string getRequiredType() const pure nothrow @nogc
    {
        return requiredType;
    }

    /// The property name, or `null`.
    string getPropertyName() const pure nothrow @nogc
    {
        return propertyName;
    }

    package(flint) void setPropertyName(string name) pure nothrow @nogc
    {
        propertyName = name;
    }
}

private string valueTypeName(Any value) pure nothrow
{
    if (value.isNull())
        return "null";
    if (value.typeName() == "string")
        return "java.lang.String";
    if (value.typeName() == "string[]")
        return "java.lang.String[]";
    return value.typeName();
}

/// `MethodArgumentTypeMismatchException`: a request value could not be converted for a handler parameter (400).
class MethodArgumentTypeMismatchException : TypeMismatchException
{
    private string name;
    private MethodParameter parameter;

    ///
    this(Any value, string requiredType, string name, MethodParameter param, Throwable cause)
    {
        super(value, requiredType, cause);
        this.name = name;
        this.parameter = param;
        setPropertyName(name);
        msg = "Method parameter '" ~ name ~ "': " ~ msg;
    }

    /// The parameter name.
    string getName() const pure nothrow @nogc
    {
        return name;
    }

    /// The method parameter.
    MethodParameter getParameter() pure nothrow @nogc
    {
        return parameter;
    }
}

/// `MethodArgumentConversionNotSupportedException`: no converter for a handler parameter (500).
class MethodArgumentConversionNotSupportedException : RuntimeException
{
    private string name;
    private MethodParameter parameter;
    private string requiredType;

    ///
    this(Any value, string requiredType, string name, MethodParameter param, Throwable cause)
    {
        super("Method parameter '" ~ name ~ "': Failed to convert value of type '" ~ valueTypeName(
                value) ~ "' to required type '" ~ javaTypeName(requiredType) ~ "'", cause);
        this.name = name;
        this.parameter = param;
        this.requiredType = requiredType;
        skipBacktrace(this);
    }

    /// The parameter name.
    string getName() const pure nothrow @nogc
    {
        return name;
    }

    /// The method parameter.
    MethodParameter getParameter() pure nothrow @nogc
    {
        return parameter;
    }
}

/// `AbstractNamedValueMethodArgumentResolver.NamedValueInfo`.
struct NamedValueInfo
{
    string name; ///
    bool required; ///
    string defaultValue; /// `null` when absent

    ///
    this(string name, bool required, string defaultValue) pure nothrow @nogc
    {
        this.name = name;
        this.required = required;
        this.defaultValue = defaultValue;
    }
}

/// `AbstractNamedValueMethodArgumentResolver`: Spring's named-value resolution, defaults and conversion.
abstract class AbstractNamedValueMethodArgumentResolver : HandlerMethodArgumentResolver
{
    /// The name, required flag and default of `parameter`'s binding annotation.
    protected NamedValueInfo createNamedValueInfo(MethodParameter parameter)
    {
        auto spec = parameter.getArgumentSpec();
        return NamedValueInfo(spec.name, spec.required, spec.defaultValue);
    }

    private NamedValueInfo getNamedValueInfo(MethodParameter parameter)
    {
        auto info = createNamedValueInfo(parameter);
        if (info.name.length == 0)
            info.name = parameter.getParameterName();
        const defaultValue = info.defaultValue == ValueConstants.DEFAULT_NONE ? null : info.defaultValue;
        return NamedValueInfo(info.name, info.required, defaultValue);
    }

    Any resolveArgument(MethodParameter parameter, ModelAndViewContainer mavContainer,
            NativeWebRequest webRequest, WebDataBinderFactory binderFactory)
    {
        auto namedValueInfo = getNamedValueInfo(parameter);
        Any arg = resolveName(namedValueInfo.name, parameter, webRequest);
        if (arg.isNull())
        {
            if (namedValueInfo.defaultValue !is null)
                arg = Any.of(namedValueInfo.defaultValue);
            else if (namedValueInfo.required && !parameter.isOptional())
                handleMissingValue(namedValueInfo.name, parameter, webRequest);
            // Optional!int stands for Optional<Integer>: its element is a wrapper, never a primitive.
            if (!parameter.isOptional())
                arg = handleNullValue(namedValueInfo.name, arg, parameter.getNestedParameterType());
        }
        else if (arg.holds!string && arg.get!string.length == 0 && namedValueInfo.defaultValue !is null)
            arg = Any.of(namedValueInfo.defaultValue);
        if (binderFactory !is null)
        {
            const targetType = parameter.getParameterType();
            Any value = arg;
            try
            {
                arg = binderFactory.convertIfNecessary(value, targetType, parameter);
                // Check for a null value after conversion of the incoming value (gh-29550, gh-31336).
                if (arg.isNull())
                {
                    if (namedValueInfo.defaultValue !is null)
                    {
                        value = Any.of(namedValueInfo.defaultValue);
                        arg = binderFactory.convertIfNecessary(value, targetType, parameter);
                    }
                    else if (namedValueInfo.required && !parameter.isOptional())
                        handleMissingValueAfterConversion(namedValueInfo.name, parameter, webRequest);
                }
            }
            catch (ConversionFailedException ex)
                throw new MethodArgumentTypeMismatchException(value,
                        parameter.getNestedParameterType(), namedValueInfo.name, parameter, ex);
        }
        handleResolvedValue(arg, namedValueInfo.name, parameter, mavContainer, webRequest);
        return arg;
    }

    /// The raw value for `name`, or a null `Any`.
    protected abstract Any resolveName(string name, MethodParameter parameter, NativeWebRequest request);

    /// Throws for a required value that is missing.
    protected void handleMissingValue(string name, MethodParameter parameter, NativeWebRequest request)
    {
        handleMissingValue(name, parameter);
    }

    /// ditto
    protected void handleMissingValue(string name, MethodParameter parameter)
    {
        // dfmt off
        throw new IllegalStateException("Missing argument '" ~ name ~ "' for method parameter of type "
                ~ simpleJavaName(
        // dfmt on
        parameter.getNestedParameterType()));
    }

    /// Throws for a value that became null after conversion.
    protected void handleMissingValueAfterConversion(string name, MethodParameter parameter, NativeWebRequest request)
    {
        handleMissingValue(name, parameter, request);
    }

    private Any handleNullValue(string name, Any value, string paramType)
    {
        if (value.isNull())
        {
            if (paramType == "bool")
                return Any.of(false);
            switch (paramType)
            {
            case "byte", "ubyte", "short", "ushort", "int", "uint", "long", "ulong", "float", "double",
                    "char":
                    throw new IllegalStateException("Optional " ~ paramType ~ " parameter '" ~ name
                            ~ "' is present but cannot be translated into a null value due to being declared as a "
                            ~ "primitive type. Consider declaring it as object wrapper for the corresponding "
                            ~ "primitive type.");
            default:
                break;
            }
        }
        return value;
    }

    /// Called with the converted value.
    protected void handleResolvedValue(Any arg, string name, MethodParameter parameter,
            ModelAndViewContainer mavContainer, NativeWebRequest webRequest)
    {
    }
}

/// `RequestParamMethodArgumentResolver`: `@RequestParam` and, by default, simple-type parameters.
class RequestParamMethodArgumentResolver : AbstractNamedValueMethodArgumentResolver
{
    private bool useDefaultResolution;

    /// With `useDefaultResolution` true, a simple-type parameter without an annotation is a request parameter.
    this(bool useDefaultResolution = false) pure nothrow @nogc
    {
        this.useDefaultResolution = useDefaultResolution;
    }

    bool supportsParameter(MethodParameter parameter)
    {
        if (parameter.getArgumentSpec().kind != ArgumentKind.requestParam)
            return false;
        if (parameter.getParameterAnnotation("flint.web.bind.annotation.RequestParam") !is null)
            return true;
        return useDefaultResolution;
    }

    protected override Any resolveName(string name, MethodParameter parameter, NativeWebRequest request)
    {
        auto values = request.getParameterValues(name);
        if (values is null)
            return Any.init;
        return values.length == 1 ? Any.of(values[0]) : Any.of(values);
    }

    protected override void handleMissingValue(string name, MethodParameter parameter, NativeWebRequest request)
    {
        throw new MissingServletRequestParameterException(name, parameter.getNestedParameterType(), parameter, false);
    }

    protected override void handleMissingValueAfterConversion(string name, MethodParameter parameter,
            NativeWebRequest request)
    {
        throw new MissingServletRequestParameterException(name, parameter.getNestedParameterType(), parameter, true);
    }
}

/// `RequestHeaderMethodArgumentResolver`: `@RequestHeader` values.
class RequestHeaderMethodArgumentResolver : AbstractNamedValueMethodArgumentResolver
{
    bool supportsParameter(MethodParameter parameter)
    {
        return parameter.getArgumentSpec().kind == ArgumentKind.requestHeader;
    }

    protected override Any resolveName(string name, MethodParameter parameter, NativeWebRequest request)
    {
        auto values = request.getHeaderValues(name);
        if (values is null)
            return Any.init;
        return values.length == 1 ? Any.of(values[0]) : Any.of(values);
    }

    protected override void handleMissingValue(string name, MethodParameter parameter, NativeWebRequest request)
    {
        throw new MissingRequestHeaderException(name, parameter, false);
    }

    protected override void handleMissingValueAfterConversion(string name, MethodParameter parameter,
            NativeWebRequest request)
    {
        throw new MissingRequestHeaderException(name, parameter, true);
    }
}

/// `ServletCookieValueMethodArgumentResolver`: `@CookieValue` (lives in webmvc in Spring; the cookie lookup is here).
class CookieValueMethodArgumentResolver : AbstractNamedValueMethodArgumentResolver
{
    bool supportsParameter(MethodParameter parameter)
    {
        return parameter.getArgumentSpec().kind == ArgumentKind.cookieValue;
    }

    protected override Any resolveName(string name, MethodParameter parameter, NativeWebRequest request)
    {
        foreach (cookie; request.getNativeRequest().getCookies())
            if (cookie.getName() == name)
                return parameter.getNestedParameterType() == "flint.jakarta.servlet.http.Cookie"
                    ? Any.of(cookie) : Any.of(cookie.getValue());
        return Any.init;
    }

    protected override void handleMissingValue(string name, MethodParameter parameter, NativeWebRequest request)
    {
        throw new MissingRequestCookieException(name, parameter, false);
    }
}

/// `ExceptionHandlerMethodResolver`: finds the `@ExceptionHandler` method for an exception, by nearest type.
class ExceptionHandlerMethodResolver
{
    private ExceptionHandlerSpec[] handlers;

    /// Over the handlers declared by one bean (a controller or an advice).
    this(ExceptionHandlerSpec[] handlers) pure nothrow @nogc
    {
        this.handlers = handlers;
    }

    /// Whether any handler is declared.
    bool hasExceptionMappings() const pure nothrow @nogc
    {
        return handlers.length != 0;
    }

    /// The handler for `exception` (or, failing that, for its causes), or `null`.
    ExceptionHandlerSpec* resolveMethod(Throwable exception)
    {
        for (Throwable current = exception; current !is null; current = causeOf(current))
            if (auto found = resolveMethodByExceptionType(current))
                return found;
        return null;
    }

    /// The handler whose declared type is nearest to `exception`'s class, or `null`.
    ExceptionHandlerSpec* resolveMethodByExceptionType(Throwable exception)
    {
        ExceptionHandlerSpec* best;
        size_t bestDepth = size_t.max;
        foreach (ref handler; handlers)
        {
            foreach (type; handler.exceptionTypes)
            {
                const depth = exceptionDepth(exception, type);
                if (depth < bestDepth)
                {
                    best = &handler;
                    bestDepth = depth;
                }
            }
        }
        return best;
    }

    /// `ExceptionDepthComparator`: 0 for the exact class, 1 for its parent, ...; `size_t.max` when unrelated.
    static size_t exceptionDepth(Throwable exception, string typeName)
    {
        size_t depth;
        for (auto info = typeid(exception); info !is null; info = info.base, depth++)
        {
            if (info.name == typeName)
                return depth;
            foreach (i; info.interfaces)
                if (i.classinfo.name == typeName)
                    return depth;
        }
        return size_t.max;
    }
}
