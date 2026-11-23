/++
Compile-time construction of Flint AOT's request-mapping and exception-handler rows for one controller or advice
class, until the Flint AOT generator emits them (docs/spring/aot-contract.md section 4.5, section 6).

This is one of the request-mapping internals the rulebook allows to reflect (docs/spring/api-mapping.md,
"API-layer internals allowed to reflect"). It builds exactly the rows the generator writes: combined paths, merged
`@RequestMapping` attributes (through engine-aot's `mergedAnnotations`, so `@AliasFor` and meta-annotations merge
as section 2.1 says), one `ArgumentSpec` per parameter with section 6's kinds, and an invoker that converts each
argument with `Any.get!T`. It is deleted when the generator lands; applications never call it directly.
+/
module flint.web.servlet.mvc.method.aot;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, MergedAnnotation, MethodDescriptor, descriptorOf, findAnnotation,
    mergedAnnotations;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec, ExceptionHandlerSpec, HandlerArguments,
    HandlerMapping;
import flint.engine.aot.name : typeNameOf;
import flint.web.bind.annotation : CookieValue, ExceptionHandler, ModelAttribute, PathVariable, RequestBody,
    RequestHeader, RequestMapping, RequestParam, ResponseStatus, ValueConstants;
import flint.web.util.pattern : PathPatternParser;

@safe:

/// The request-mapping rows of controller `C`, registered under `beanName`.
HandlerMapping[] requestMappingsOf(C)(string beanName)
{
    HandlerMapping[] rows;
    auto typeAnnotations = mergedAnnotations!(__traits(getAttributes, C))();
    string[] typePaths;
    string[] typeMethods, typeParams, typeHeaders, typeConsumes, typeProduces;
    if (auto typeMapping = findAnnotation(typeAnnotations, typeNameOf!RequestMapping))
    {
        const mapping = typeMapping.value.get!RequestMapping;
        typePaths = mapping.path.length != 0 ? mapping.path.dup : mapping.value.dup;
        foreach (m; mapping.method)
            typeMethods ~= m.name();
        typeParams = mapping.params.dup;
        typeHeaders = mapping.headers.dup;
        typeConsumes = mapping.consumes.dup;
        typeProduces = mapping.produces.dup;
    }
    const typeResponseBody = findAnnotation(typeAnnotations, "flint.web.bind.annotation.ResponseBody") !is null;

    static foreach (member; __traits(derivedMembers, C))
    {
        static if (isPublicMethod!(C, member))
        {
            static foreach (overload; __traits(getOverloads, C, member))
            {
                {
                    auto methodAnnotations = mergedAnnotations!(__traits(getAttributes, overload))();
                    if (auto methodMapping = findAnnotation(methodAnnotations, typeNameOf!RequestMapping))
                    {
                        const mapping = methodMapping.value.get!RequestMapping;
                        HandlerMapping row;
                        row.bean = beanName;
                        string[] methodPaths = mapping.path.length != 0 ? mapping.path.dup : mapping.value.dup;
                        row.paths = combinePaths(typePaths, methodPaths);
                        row.methods = typeMethods.dup;
                        foreach (m; mapping.method)
                            row.methods ~= m.name();
                        row.params = typeParams ~ mapping.params;
                        row.headers = typeHeaders ~ mapping.headers;
                        row.consumes = mapping.consumes.length != 0 ? mapping.consumes.dup : typeConsumes;
                        row.produces = mapping.produces.length != 0 ? mapping.produces.dup : typeProduces;
                        row.arguments = argumentsOf!overload();
                        row.returnType = returnTypeName!overload();
                        row.responseBody = typeResponseBody
                            || findAnnotation(methodAnnotations, "flint.web.bind.annotation.ResponseBody") !is null;
                        if (auto status = findAnnotation(methodAnnotations, typeNameOf!ResponseStatus))
                        {
                            const value = status.value.get!ResponseStatus;
                            row.responseStatus = value.code.value();
                            row.reason = value.reason;
                        }
                        auto descriptor = new MethodDescriptor;
                        descriptor.name = member;
                        descriptor.returnType = row.returnType;
                        descriptor.annotations = methodAnnotations;
                        row.method = descriptor;
                        row.invoke = &invokeHandler!(C, overload);
                        row.source = __traits(identifier, C) ~ "." ~ member;
                        rows ~= row;
                    }
                }
            }
        }
    }
    return rows;
}

/// The `@ExceptionHandler` rows of `C`, registered under `beanName`; `advice` marks a `@ControllerAdvice`.
ExceptionHandlerSpec[] exceptionHandlersOf(C)(string beanName)
{
    ExceptionHandlerSpec[] rows;
    auto typeAnnotations = mergedAnnotations!(__traits(getAttributes, C))();
    const advice = findAnnotation(typeAnnotations, "flint.web.bind.annotation.ControllerAdvice") !is null;
    const typeResponseBody = findAnnotation(typeAnnotations, "flint.web.bind.annotation.ResponseBody") !is null;
    string[] basePackages;
    if (auto adviceAnnotation = findAnnotation(typeAnnotations, "flint.web.bind.annotation.ControllerAdvice"))
    {
        import flint.web.bind.annotation : ControllerAdvice;

        const value = adviceAnnotation.value.get!ControllerAdvice;
        basePackages = value.basePackages.length != 0 ? value.basePackages.dup : value.value.dup;
    }
    static foreach (member; __traits(derivedMembers, C))
    {
        static if (isPublicMethod!(C, member))
        {
            static foreach (overload; __traits(getOverloads, C, member))
            {
                {
                    auto methodAnnotations = mergedAnnotations!(__traits(getAttributes, overload))();
                    if (auto handler = findAnnotation(methodAnnotations, typeNameOf!ExceptionHandler))
                    {
                        const value = handler.value.get!ExceptionHandler;
                        ExceptionHandlerSpec row;
                        row.bean = beanName;
                        foreach (ref type; value.value.length != 0 ? value.value : value.exception)
                            row.exceptionTypes ~= type.name;
                        if (row.exceptionTypes.length == 0)
                            row.exceptionTypes = exceptionParameterTypes!overload();
                        row.advice = advice;
                        row.adviceBasePackages = basePackages;
                        row.arguments = argumentsOf!overload();
                        row.returnType = returnTypeName!overload();
                        row.responseBody = typeResponseBody
                            || findAnnotation(methodAnnotations, "flint.web.bind.annotation.ResponseBody") !is null;
                        if (auto status = findAnnotation(methodAnnotations, typeNameOf!ResponseStatus))
                            row.responseStatus = status.value.get!ResponseStatus.code.value();
                        row.invoke = &invokeExceptionHandler!(C, overload);
                        row.source = __traits(identifier, C) ~ "." ~ member;
                        rows ~= row;
                    }
                }
            }
        }
    }
    return rows;
}

/// The descriptors of `C`'s handler return types and `@RequestBody` types (what message conversion needs).
Descriptor[] handlerDescriptorsOf(C)()
{
    Descriptor[] result;
    static foreach (member; __traits(derivedMembers, C))
    {
        static if (isPublicMethod!(C, member))
        {
            static foreach (overload; __traits(getOverloads, C, member))
            {
                static if (is(typeof(overload) R == return) && isUserData!R)
                    result ~= descriptorOf!R();
            }
        }
    }
    return result;
}

private enum isUserData(T) = (is(T == struct) || is(T == class)) && !isFrameworkType!T;

private template isFrameworkType(T)
{
    enum name = typeNameOf!T;
    enum isFrameworkType = name.length > 6 && name[0 .. 6] == "flint.";
}

private template isPublicMethod(C, string member)
{
    static if (__traits(compiles, __traits(getMember, C, member)) && member != "this" && member != "__ctor"
            && member != "__dtor" && member.length >= 2 && member[0 .. 2] != "__")
    {
        enum isPublicMethod = __traits(getVisibility, __traits(getMember, C, member)) == "public"
            && is(typeof(__traits(getMember, C, member)) == function);
    }
    else
        enum isPublicMethod = false;
}

private string returnTypeName(alias method)()
{
    static if (is(typeof(method) R == return))
    {
        static if (is(R == void))
            return "void";
        else
            return typeNameOf!R;
    }
    else
        return "void";
}

private string[] exceptionParameterTypes(alias method)()
{
    string[] result;
    static if (is(typeof(method) Params == __parameters))
    {
        static foreach (i; 0 .. Params.length)
        {
            static if (is(Params[i] : Throwable))
                result ~= typeNameOf!(Params[i]);
        }
    }
    return result;
}

// Contract section 6: parameter kinds, names, required flags and defaults.
private ArgumentSpec[] argumentsOf(alias method)()
{
    import std.traits : ParameterIdentifierTuple;

    ArgumentSpec[] result;
    static if (is(typeof(method) Params == __parameters))
    {
        alias names = ParameterIdentifierTuple!method;
        static foreach (i; 0 .. Params.length)
        {
            {
                ArgumentSpec spec;
                spec.type = typeNameOf!(Params[i]);
                spec.name = names[i];
                spec.annotations = mergedAnnotations!(__traits(getAttributes, Params[i .. i + 1]))();
                spec.defaultValue = ValueConstants.DEFAULT_NONE;
                spec.required = true;
                if (auto a = findAnnotation(spec.annotations, typeNameOf!PathVariable))
                {
                    const v = a.value.get!PathVariable;
                    spec.kind = ArgumentKind.pathVariable;
                    setName(spec, v.name, v.value);
                    spec.required = v.required;
                }
                else if (auto a = findAnnotation(spec.annotations, typeNameOf!RequestParam))
                {
                    const v = a.value.get!RequestParam;
                    spec.kind = ArgumentKind.requestParam;
                    setName(spec, v.name, v.value);
                    spec.required = v.required;
                    spec.defaultValue = v.defaultValue;
                }
                else if (auto a = findAnnotation(spec.annotations, typeNameOf!RequestHeader))
                {
                    const v = a.value.get!RequestHeader;
                    spec.kind = ArgumentKind.requestHeader;
                    setName(spec, v.name, v.value);
                    spec.required = v.required;
                    spec.defaultValue = v.defaultValue;
                }
                else if (auto a = findAnnotation(spec.annotations, typeNameOf!CookieValue))
                {
                    const v = a.value.get!CookieValue;
                    spec.kind = ArgumentKind.cookieValue;
                    setName(spec, v.name, v.value);
                    spec.required = v.required;
                    spec.defaultValue = v.defaultValue;
                }
                else if (auto a = findAnnotation(spec.annotations, typeNameOf!RequestBody))
                {
                    spec.kind = ArgumentKind.requestBody;
                    spec.required = a.value.get!RequestBody.required;
                }
                else if (auto a = findAnnotation(spec.annotations, typeNameOf!ModelAttribute))
                    spec.kind = ArgumentKind.modelAttribute;
                else static if (isSimpleType!(Params[i]))
                {
                    spec.kind = ArgumentKind.requestParam;
                    spec.required = false;
                }
                else static if (is(Params[i] == class) || is(Params[i] == interface) || isFrameworkType!(Params[i]))
                    spec.kind = ArgumentKind.byType;
                else
                    spec.kind = ArgumentKind.modelAttribute;
                spec.validate = findAnnotation(spec.annotations, "flint.jakarta.validation.Valid") !is null
                    || findAnnotation(spec.annotations, "flint.validation.annotation.Validated") !is null;
                result ~= spec;
            }
        }
    }
    return result;
}

private void setName(ref ArgumentSpec spec, string name, string value) pure nothrow @nogc
{
    if (name.length != 0)
        spec.name = name;
    else if (value.length != 0)
        spec.name = value;
}

private template isSimpleType(T)
{
    static if (is(T == E[], E) && !is(T : const(char)[]))
        enum isSimpleType = isSimpleType!E;
    else
        enum isSimpleType = __traits(isScalar, T) || is(T : const(char)[]) || is(T == enum);
}

private void invokeHandler(C, alias method)(Object bean, HandlerArguments arguments, ref Any result) @safe
{
    auto controller = cast(C) bean;
    static if (is(typeof(method) Params == __parameters))
    {
        Params args;
        static foreach (i; 0 .. Params.length)
            args[i] = argument!(Params[i])(arguments, i);
        static if (is(typeof(method) R == return) && !is(R == void))
            result = Any.of(__traits(child, controller, method)(args));
        else
            __traits(child, controller, method)(args);
    }
}

private void invokeExceptionHandler(C, alias method)(Object bean, Exception exception, HandlerArguments arguments,
        ref Any result) @safe
{
    invokeHandler!(C, method)(bean, arguments, result);
}

private T argument(T)(HandlerArguments arguments, size_t index)
{
    auto value = arguments.get(index);
    if (value.isNull())
        return T.init;
    static if (is(T == class) || is(T == interface))
        return cast(T) value.asObject();
    else
        return value.get!T;
}

/// Class paths × method paths, combined as Spring's `PathPatternsRequestCondition.combine` does.
private string[] combinePaths(string[] typePaths, string[] methodPaths)
{
    if (typePaths.length == 0 && methodPaths.length == 0)
        return [""];
    if (typePaths.length == 0)
        return normalize(methodPaths);
    if (methodPaths.length == 0)
        return normalize(typePaths);
    auto parser = new PathPatternParser;
    string[] result;
    foreach (typePath; normalize(typePaths))
        foreach (methodPath; normalize(methodPaths))
            result ~= parser.parse(typePath).combine(parser.parse(methodPath)).getPatternString();
    return result;
}

private string[] normalize(string[] paths) pure nothrow
{
    string[] result;
    foreach (path; paths)
        result ~= path.length != 0 && path[0] != '/' ? "/" ~ path : path;
    return result;
}
