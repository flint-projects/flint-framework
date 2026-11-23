/++
`org.springframework.web.servlet.mvc.method.annotation`: annotated-controller handling.

Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/main/java/org/springframework/web/servlet/mvc/method/annotation/
(RequestMappingHandlerMapping.java, RequestMappingHandlerAdapter.java, ServletInvocableHandlerMethod.java,
AbstractMessageConverterMethodArgumentResolver.java, AbstractMessageConverterMethodProcessor.java,
RequestResponseBodyMethodProcessor.java, HttpEntityMethodProcessor.java, HttpHeadersReturnValueHandler.java,
ViewNameMethodReturnValueHandler.java, PathVariableMethodArgumentResolver.java,
ServletRequestMethodArgumentResolver.java, ServletResponseMethodArgumentResolver.java,
ExceptionHandlerExceptionResolver.java) and RequestMappingInfoHandlerMapping.HttpOptionsHandler.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: mappings and exception handlers come from Flint AOT's tables (contract 1
section 4.5) and beans from its `BeanFactory`, instead of introspecting classes at startup. Return-value
handlers select on the declared return type name. Message-converter selection is
`AbstractMessageConverterMethodProcessor.writeWithMessageConverters` as written.
+/
module flint.web.servlet.mvc.method.annotation;

import flint.core : MethodParameter, causeOf;
import flint.engine.aot.any : Any;
import flint.engine.aot.bean : BeanFactory;
import flint.engine.aot.descriptor : DescriptorTable, MergedAnnotation;
import flint.engine.aot.mapping : AotHandlerMapping = HandlerMapping, ArgumentKind, ArgumentSpec,
    ExceptionHandlerSpec, HandlerArguments;
import flint.http : HttpEntity, HttpHeaders, HttpMethod, HttpStatus, HttpStatusCode, MediaType,
    ProblemDetail, ResponseEntity;
import flint.http.converter : HttpMessageConverter, HttpMessageNotReadableException, HttpMessageNotWritableException;
import flint.http.server : ServletServerHttpRequest, ServletServerHttpResponse;
import flint.jakarta.servlet : ServletRequest, ServletResponse;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.java.lang : IllegalStateException;
import flint.util : MimeTypeUtils;
import flint.web : ErrorResponse, HttpMediaTypeNotAcceptableException, HttpMediaTypeNotSupportedException;
import flint.web.accept : ContentNegotiationManager;
import flint.web.bind : MissingPathVariableException;
import flint.web.bind.support : DefaultDataBinderFactory, WebDataBinderFactory;
import flint.web.context.request : NativeWebRequest, ServletWebRequest, WebRequest;
import flint.web.method : HandlerMethod;
import flint.web.method.annotation : AbstractNamedValueMethodArgumentResolver, CookieValueMethodArgumentResolver,
    ExceptionHandlerMethodResolver,
    NamedValueInfo, RequestHeaderMethodArgumentResolver, RequestParamMethodArgumentResolver;
import flint.web.method.support : HandlerMethodArgumentResolver, HandlerMethodArgumentResolverComposite,
    HandlerMethodReturnValueHandler,
    HandlerMethodReturnValueHandlerComposite, InvocableHandlerMethod, ModelAndViewContainer;
import flint.web.servlet : HandlerAdapter, HandlerMapping, ModelAndView, View;
import flint.web.servlet.resource : ResourceHttpRequestHandler;
import flint.web.servlet.handler : AbstractHandlerExceptionResolver;
import flint.web.cors : CorsConfiguration;
import flint.web.servlet.mvc.method : RequestMappingInfo, RequestMappingInfoHandlerMapping;
import flint.validation : Validator;

@safe:

// ---------------------------------------------------------------------------------------------------------
// Handler mapping

/// `RequestMappingHandlerMapping`: `@RequestMapping` methods, from Flint AOT's mapping table.
class RequestMappingHandlerMapping : RequestMappingInfoHandlerMapping
{
    /// Registers every row of `mappings`, resolving each controller bean through `beanFactory`.
    this(AotHandlerMapping[] mappings, BeanFactory beanFactory)
    {
        setOrder(0);
        foreach (mapping; mappings)
        {
            Object bean = beanFactory.getBean(mapping.bean);
            // Contract 2's beanType; a row from an older table falls back to the bean's run-time type.
            auto handlerMethod = new HandlerMethod(bean, mapping.beanType.length != 0
                    ? mapping.beanType : typeid(bean).name, mapping);
            registerMapping(new RequestMappingInfo(mapping.paths, mapping.methods, mapping.params,
                    mapping.headers, mapping.consumes, mapping.produces), handlerMethod,
                    initCorsConfiguration(mapping));
        }
    }

    /// Spring's `initCorsConfiguration`: class-level `@CrossOrigin` (contract 2's `typeAnnotations`) updated by the
    /// method's, then permit defaults.
    protected CorsConfiguration initCorsConfiguration(AotHandlerMapping mapping)
    {
        import flint.web.bind.annotation : CrossOrigin;

        if (mapping.method is null)
            return null;
        const(CrossOrigin)[] typeValues, methodValues;
        foreach (ref annotation; mapping.typeAnnotations)
            if (annotation.type == "flint.web.bind.annotation.CrossOrigin" && typeValues.length == 0)
                typeValues ~= annotation.value.get!CrossOrigin;
        foreach (ref annotation; mapping.method.annotations)
            if (annotation.type == "flint.web.bind.annotation.CrossOrigin" && methodValues.length == 0)
                methodValues ~= annotation.value.get!CrossOrigin;
        const(CrossOrigin)* typeAnnotation = typeValues.length != 0 ? &typeValues[0] : null;
        const(CrossOrigin)* methodAnnotation = methodValues.length != 0 ? &methodValues[0] : null;
        if (typeAnnotation is null && methodAnnotation is null)
            return null;
        auto config = new CorsConfiguration;
        updateCorsConfig(config, typeAnnotation);
        updateCorsConfig(config, methodAnnotation);
        if (config.getAllowedMethods().length == 0)
            foreach (m; mapping.methods)
                config.addAllowedMethod(m);
        return config.applyPermitDefaultValues();
    }

    private static void updateCorsConfig(CorsConfiguration config,
            const(imported!"flint.web.bind.annotation".CrossOrigin)* annotation)
    {
        if (annotation is null)
            return;
        foreach (origin; annotation.origins.length != 0 ? annotation.origins : annotation.value)
            config.addAllowedOrigin(origin);
        foreach (pattern; annotation.originPatterns)
            config.addAllowedOriginPattern(pattern);
        foreach (method; annotation.methods)
            config.addAllowedMethod(method.name());
        foreach (header; annotation.allowedHeaders)
            config.addAllowedHeader(header);
        foreach (header; annotation.exposedHeaders)
            config.addExposedHeader(header);
        if (annotation.allowCredentials == "true")
            config.setAllowCredentials(true);
        else if (annotation.allowCredentials == "false")
            config.setAllowCredentials(false);
        else if (annotation.allowCredentials.length != 0)
            throw new IllegalStateException("@CrossOrigin's allowCredentials value must be \"true\", \"false\", "
                    ~ "or an empty string (\"\"): current value is [" ~ annotation.allowCredentials ~ "]");
        if (annotation.allowPrivateNetwork == "true")
            config.setAllowPrivateNetwork(true);
        else if (annotation.allowPrivateNetwork == "false")
            config.setAllowPrivateNetwork(false);
        if (annotation.maxAge >= 0)
            config.setMaxAge(annotation.maxAge);
    }

    protected override HandlerMethod createOptionsHandler(string[] declaredMethods,
            MediaType[] acceptPatch, MediaType[] acceptQuery)
    {
        auto handler = new HttpOptionsHandler(declaredMethods, acceptPatch, acceptQuery);
        AotHandlerMapping row;
        row.bean = "httpOptionsHandler";
        row.returnType = "flint.http.HttpHeaders";
        row.invoke = &HttpOptionsHandler.invoke;
        return new HandlerMethod(handler, typeid(handler).name, row);
    }
}

/// `RequestMappingInfoHandlerMapping.HttpOptionsHandler`: the `Allow`, `Accept-Patch` and `Accept-Query` answer.
final class HttpOptionsHandler
{
    private HttpHeaders headers;

    ///
    this(string[] declaredMethods, MediaType[] acceptPatch, MediaType[] acceptQuery)
    {
        headers = HttpHeaders.create();
        HttpMethod[] allowed;
        void add(HttpMethod m)
        {
            foreach (a; allowed)
                if (a == m)
                    return;
            allowed ~= m;
        }

        if (declaredMethods.length == 0)
        {
            foreach (m; HttpMethod.values())
                if (m != HttpMethod.TRACE)
                    add(m);
        }
        else
        {
            foreach (name; declaredMethods)
            {
                auto m = HttpMethod.valueOf(name);
                add(m);
                if (m == HttpMethod.GET || m == HttpMethod.QUERY)
                    add(HttpMethod.HEAD);
            }
            add(HttpMethod.OPTIONS);
        }
        headers.setAllow(allowed);
        headers.set(HttpHeaders.ACCEPT_PATCH, MediaType.toString(acceptPatch));
        headers.set("Accept-Query", MediaType.toString(acceptQuery));
    }

    /// The headers.
    HttpHeaders handle() pure nothrow @nogc
    {
        return headers;
    }

    private static void invoke(Object bean, HandlerArguments, ref Any result) @safe
    {
        result = Any.of((cast(HttpOptionsHandler) bean).handle());
    }
}

// ---------------------------------------------------------------------------------------------------------
// Argument resolvers

/// `PathVariableMethodArgumentResolver`: `@PathVariable`.
class PathVariableMethodArgumentResolver : AbstractNamedValueMethodArgumentResolver
{
    bool supportsParameter(MethodParameter parameter)
    {
        return parameter.getArgumentSpec().kind == ArgumentKind.pathVariable;
    }

    protected override Any resolveName(string name, MethodParameter parameter, NativeWebRequest request)
    {
        auto variables = request.getAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE,
                WebRequest.SCOPE_REQUEST);
        if (variables.isNull())
            return Any.init;
        foreach (pair; variables.get!(string[2][]))
            if (pair[0] == name)
                return Any.of(pair[1]);
        return Any.init;
    }

    protected override void handleMissingValue(string name, MethodParameter parameter)
    {
        throw new MissingPathVariableException(name, parameter, false);
    }

    protected override void handleMissingValueAfterConversion(string name, MethodParameter parameter,
            NativeWebRequest request)
    {
        throw new MissingPathVariableException(name, parameter, true);
    }

    /// Records the value under `View.PATH_VARIABLES`, for views and redirects.
    protected override void handleResolvedValue(Any arg, string name, MethodParameter parameter,
            ModelAndViewContainer mavContainer, NativeWebRequest request)
    {
        auto existing = request.getAttribute(View.PATH_VARIABLES, WebRequest.SCOPE_REQUEST);
        Any[string] pathVars = existing.isNull() ? null : existing.get!(Any[string]);
        pathVars[name] = arg;
        request.setAttribute(View.PATH_VARIABLES, Any.of(pathVars), WebRequest.SCOPE_REQUEST);
    }
}

/// `ServletRequestMethodArgumentResolver`: the request, `WebRequest` and `HttpMethod` parameters.
class ServletRequestMethodArgumentResolver : HandlerMethodArgumentResolver
{
    private static immutable string[] types = [
        "flint.jakarta.servlet.http.HttpServletRequest", "flint.jakarta.servlet.ServletRequest",
        "flint.web.context.request.WebRequest", "flint.web.context.request.NativeWebRequest",
        "flint.web.context.request.ServletWebRequest", "flint.http.HttpMethod"
    ];

    bool supportsParameter(MethodParameter parameter)
    {
        foreach (t; types)
            if (parameter.getParameterType() == t)
                return true;
        return false;
    }

    Any resolveArgument(MethodParameter parameter, ModelAndViewContainer mavContainer,
            NativeWebRequest webRequest, WebDataBinderFactory binderFactory)
    {
        switch (parameter.getParameterType())
        {
        case "flint.http.HttpMethod":
            return Any.of(HttpMethod.valueOf(webRequest.getNativeRequest().getMethod()));
        case "flint.web.context.request.WebRequest", "flint.web.context.request.NativeWebRequest",
                "flint.web.context.request.ServletWebRequest":
                return Any.of(cast(Object) webRequest);
        default:
            return Any.of(cast(Object) webRequest.getNativeRequest());
        }
    }
}

/// `ServletResponseMethodArgumentResolver`: the response parameter.
class ServletResponseMethodArgumentResolver : HandlerMethodArgumentResolver
{
    bool supportsParameter(MethodParameter parameter)
    {
        const type = parameter.getParameterType();
        return type == "flint.jakarta.servlet.http.HttpServletResponse"
            || type == "flint.jakarta.servlet.ServletResponse";
    }

    Any resolveArgument(MethodParameter parameter, ModelAndViewContainer mavContainer,
            NativeWebRequest webRequest, WebDataBinderFactory binderFactory)
    {
        if (mavContainer !is null)
            mavContainer.setRequestHandled(true);
        return Any.of(cast(Object) webRequest.getNativeResponse());
    }
}

// ---------------------------------------------------------------------------------------------------------
// Message conversion

/// `AbstractMessageConverterMethodProcessor`: reading bodies, and writing them with content negotiation.
abstract class AbstractMessageConverterMethodProcessor : HandlerMethodArgumentResolver, HandlerMethodReturnValueHandler
{
    protected HttpMessageConverter[] messageConverters;
    protected ContentNegotiationManager contentNegotiationManager;

    private static immutable MediaType[] problemMediaTypes = [MediaType.APPLICATION_PROBLEM_JSON];

    ///
    protected this(HttpMessageConverter[] converters, ContentNegotiationManager manager)
    {
        messageConverters = converters;
        contentNegotiationManager = manager !is null ? manager : new ContentNegotiationManager;
    }

    /// Reads `typeName` from the request body. Throws `HttpMediaTypeNotSupportedException` or
    /// `HttpMessageNotReadableException`.
    protected Any readWithMessageConverters(NativeWebRequest webRequest, MethodParameter parameter, string typeName)
    {
        auto inputMessage = new ServletServerHttpRequest(webRequest.getNativeRequest());
        auto contentType = inputMessage.getHeaders().getContentType();
        MediaType effective = contentType !is null ? *contentType : MediaType.APPLICATION_OCTET_STREAM;
        const 
        body = inputMessage.getBody();
        foreach (converter; messageConverters)
        {
            if (converter.canRead(typeName, &effective))
            {
                if (body.length == 0)
                    return Any.init;
                return converter.read(typeName, inputMessage);
            }
        }
        if (body.length == 0)
            return Any.init;
        MediaType[] supported;
        foreach (converter; messageConverters)
            supported ~= converter.getSupportedMediaTypes(typeName);
        import std.typecons : nullable;

        throw new HttpMediaTypeNotSupportedException(nullable(effective), supported,
                nullable(HttpMethod.valueOf(webRequest.getNativeRequest().getMethod())));
    }

    /// Spring's `writeWithMessageConverters`.
    protected void writeWithMessageConverters(Any value, MethodParameter returnType,
            NativeWebRequest webRequest, ServletServerHttpResponse outputMessage)
    {
        auto request = webRequest.getNativeRequest();
        string valueType = value.isNull() ? returnType.getParameterType() : value.typeName();
        auto contentType = outputMessage.getHeaders().getContentType();
        const isContentTypePreset = contentType !is null && contentType.isConcrete();
        MediaType selectedMediaType;
        bool selected;
        if (isContentTypePreset)
        {
            selectedMediaType = *contentType;
            selected = true;
        }
        else
        {
            MediaType[] acceptableTypes;
            try
                acceptableTypes = contentNegotiationManager.resolveMediaTypes(webRequest);
            catch (HttpMediaTypeNotAcceptableException ex)
            {
                const series = outputMessage.getServletResponse().getStatus() / 100;
                if (value.isNull() || series == 4 || series == 5)
                    return;
                throw ex;
            }
            auto producibleTypes = getProducibleMediaTypes(request, valueType);
            if (!value.isNull() && producibleTypes.length == 0)
                throw new HttpMessageNotWritableException("No converter found for return value of type: " ~ valueType);
            MediaType[] compatibleMediaTypes;
            determineCompatibleMediaTypes(acceptableTypes, producibleTypes, compatibleMediaTypes);
            if (compatibleMediaTypes.length == 0 && valueType == "flint.http.ProblemDetail")
                determineCompatibleMediaTypes(cast(MediaType[]) problemMediaTypes.dup,
                        producibleTypes, compatibleMediaTypes);
            if (compatibleMediaTypes.length == 0)
            {
                if (!value.isNull())
                    throw new HttpMediaTypeNotAcceptableException(producibleTypes);
                return;
            }
            MimeTypeUtils.sortBySpecificity(compatibleMediaTypes);
            foreach (mediaType; compatibleMediaTypes)
            {
                if (mediaType.isConcrete())
                {
                    selectedMediaType = mediaType;
                    selected = true;
                    break;
                }
                else if (mediaType.equalsTypeAndSubtype(MediaType.ALL)
                        || mediaType.equalsTypeAndSubtype(MediaType("application")))
                {
                    selectedMediaType = MediaType.APPLICATION_OCTET_STREAM;
                    selected = true;
                    break;
                }
            }
        }
        if (selected)
        {
            selectedMediaType = selectedMediaType.removeQualityValue();
            foreach (converter; messageConverters)
            {
                if (converter.canWrite(valueType, &selectedMediaType))
                {
                    if (!value.isNull())
                        converter.write(value, &selectedMediaType, outputMessage);
                    return;
                }
            }
        }
        if (!value.isNull())
        {
            auto producible = request.getAttribute(HandlerMapping.PRODUCIBLE_MEDIA_TYPES_ATTRIBUTE);
            if (isContentTypePreset || !producible.isNull())
                throw new HttpMessageNotWritableException(
                        "No converter for [" ~ valueType ~ "] with preset Content-Type '" ~ (contentType is null
                        ? "null" : contentType.toString()) ~ "'");
            MediaType[] supported;
            foreach (converter; messageConverters)
                supported ~= converter.getSupportedMediaTypes(valueType);
            throw new HttpMediaTypeNotAcceptableException(supported);
        }
    }

    /// The producible types: the mapping's `produces`, else the types of the converters that can write
    /// `valueType`, else `*/*`.
    protected MediaType[] getProducibleMediaTypes(HttpServletRequest request, string valueType)
    {
        auto attribute = request.getAttribute(HandlerMapping.PRODUCIBLE_MEDIA_TYPES_ATTRIBUTE);
        if (!attribute.isNull() && attribute.get!(MediaType[]).length != 0)
            return attribute.get!(MediaType[]);
        // Usually one converter can write the value: its list is the result as it is (Spring's LinkedHashSet
        // copy only matters when lists are merged or repeat a type).
        MediaType[] result;
        bool merged;
        foreach (converter; messageConverters)
        {
            if (!converter.canWrite(valueType, null))
                continue;
            auto supported = converter.getSupportedMediaTypes(valueType);
            if (result.length == 0 && !merged && distinct(supported))
            {
                result = supported;
                continue;
            }
            if (!merged)
            {
                MediaType[] copy;
                foreach (mediaType; result)
                    if (!contains(copy, mediaType))
                        copy ~= mediaType;
                result = copy;
                merged = true;
            }
            foreach (mediaType; supported)
                if (!contains(result, mediaType))
                    result ~= mediaType;
        }
        if (result.length == 0)
            result ~= MediaType.ALL;
        return result;
    }

    private static bool distinct(const MediaType[] types)
    {
        foreach (index, ref type; types)
            if (contains(types[0 .. index], type))
                return false;
        return true;
    }

    private static bool contains(const MediaType[] types, const MediaType mediaType)
    {
        foreach (ref type; types)
            if (type == mediaType)
                return true;
        return false;
    }

    private static void determineCompatibleMediaTypes(MediaType[] acceptableTypes,
            MediaType[] producibleTypes, ref MediaType[] mediaTypesToUse)
    {
        // At most one result per pair: one allocation, filled in place, instead of growing by appends.
        MediaType[] found;
        size_t count;
        foreach (requestedType; acceptableTypes)
            foreach (producibleType; producibleTypes)
                if (requestedType.isCompatibleWith(producibleType))
                {
                    auto mediaType = getMostSpecificMediaType(requestedType, producibleType);
                    if (contains(mediaTypesToUse, mediaType) || contains(found[0 .. count], mediaType))
                        continue;
                    if (found is null)
                        found = new MediaType[acceptableTypes.length * producibleTypes.length];
                    found[count++] = mediaType;
                }
        if (count != 0)
            mediaTypesToUse = mediaTypesToUse.length == 0 ? found[0 .. count] : mediaTypesToUse ~ found[0 .. count];
    }

    private static MediaType getMostSpecificMediaType(MediaType acceptType, MediaType produceType)
    {
        auto produceTypeToUse = produceType.copyQualityValue(acceptType);
        return acceptType.isLessSpecific(produceTypeToUse) ? produceTypeToUse : acceptType;
    }

    protected static ServletServerHttpResponse createOutputMessage(NativeWebRequest webRequest)
    {
        return new ServletServerHttpResponse(webRequest.getNativeResponse());
    }
}

/// `RequestResponseBodyMethodProcessor`: `@RequestBody` arguments and `@ResponseBody` return values.
class RequestResponseBodyMethodProcessor : AbstractMessageConverterMethodProcessor
{
    private Validator validator;
    private DescriptorTable descriptors;

    ///
    this(HttpMessageConverter[] converters, ContentNegotiationManager manager = null)
    {
        super(converters, manager);
    }

    /// The validator for `@Valid` and `@Validated` arguments, with the descriptors its binding results read
    /// properties through (Spring keeps it in the web binding initializer).
    package(flint) void setValidator(Validator validator, DescriptorTable descriptors) pure nothrow @nogc
    {
        this.validator = validator;
        this.descriptors = descriptors;
    }

    bool supportsParameter(MethodParameter parameter)
    {
        return parameter.getArgumentSpec().kind == ArgumentKind.requestBody;
    }

    bool supportsReturnType(MethodParameter returnType)
    {
        // Selected per handler: the adapter only routes @ResponseBody methods here.
        return true;
    }

    Any resolveArgument(MethodParameter parameter, ModelAndViewContainer mavContainer,
            NativeWebRequest webRequest, WebDataBinderFactory binderFactory)
    {
        auto arg = readWithMessageConverters(webRequest, parameter, parameter.getNestedParameterType());
        if (arg.isNull() && parameter.getArgumentSpec().required && !parameter.isOptional())
            throw new HttpMessageNotReadableException("Required request body is missing: " ~ parameter.getExecutable(),
                    null, new ServletServerHttpRequest(webRequest.getNativeRequest()));
        if (!arg.isNull())
            validateIfApplicable(arg, parameter);
        return arg;
    }

    /// Spring's `validateIfApplicable` and `isBindExceptionRequired`: a `@Valid` or `@Validated` argument is
    /// validated into a `BeanPropertyBindingResult` named as `Conventions` names the parameter, and errors throw
    /// `MethodArgumentNotValidException`.
    protected void validateIfApplicable(Any arg, MethodParameter parameter)
    {
        import flint.validation : BeanPropertyBindingResult;
        import flint.web.bind : MethodArgumentNotValidException;

        if (validator is null || !parameter.getArgumentSpec().validate)
            return;
        auto result = new BeanPropertyBindingResult(arg,
                variableNameOf(parameter.getNestedParameterType()), descriptors);
        validator.validate(arg, result);
        if (result.hasErrors())
            throw new MethodArgumentNotValidException(parameter, result);
    }

    /// `Conventions.getVariableNameForParameter` for a single value: the simple type name, uncapitalized unless
    /// it starts with two capitals (`OwnerDto` → `ownerDto`, `URLData` → `URLData`).
    package(flint) static string variableNameOf(string typeName) pure nothrow
    {
        size_t start;
        foreach (index, c; typeName)
            if (c == '.')
                start = index + 1;
        const simple = typeName[start .. $];
        if (simple.length == 0 || simple[0] < 'A' || simple[0] > 'Z')
            return simple;
        if (simple.length > 1 && simple[1] >= 'A' && simple[1] <= 'Z')
            return simple;
        return cast(char)(simple[0] + 32) ~ simple[1 .. $];
    }

    void handleReturnValue(Any returnValue, MethodParameter returnType,
            ModelAndViewContainer mavContainer, NativeWebRequest webRequest)
    {
        mavContainer.setRequestHandled(true);
        auto outputMessage = createOutputMessage(webRequest);
        // A returned ProblemDetail sets the response status (error response interceptors and error views are
        // not ported).
        if (!returnValue.isNull() && returnValue.holds!ProblemDetail)
            outputMessage.setStatusCode(HttpStatusCode.valueOf(returnValue.get!ProblemDetail.getStatus()));
        writeWithMessageConverters(returnValue, returnType, webRequest, outputMessage);
        // Spring 7: no flush here, so the container sets Content-Length when the response completes.
        outputMessage.close();
    }
}

/// `HttpEntityMethodProcessor`: `HttpEntity`/`RequestEntity` arguments and `ResponseEntity`, `HttpEntity`,
/// `ErrorResponse` and `ProblemDetail` return values.
class HttpEntityMethodProcessor : AbstractMessageConverterMethodProcessor
{
    ///
    this(HttpMessageConverter[] converters, ContentNegotiationManager manager = null)
    {
        super(converters, manager);
    }

    bool supportsParameter(MethodParameter parameter)
    {
        const type = parameter.getParameterType();
        return type == "flint.http.HttpEntity" || type == "flint.http.RequestEntity";
    }

    bool supportsReturnType(MethodParameter returnType)
    {
        const type = returnType.getParameterType();
        return type == "flint.http.ResponseEntity" || type == "flint.http.HttpEntity"
            || type == "flint.http.ProblemDetail"
            || type == "flint.web.ErrorResponse"
            || type == "flint.web.ErrorResponseException" || type == "flint.web.server.ResponseStatusException";
    }

    Any resolveArgument(MethodParameter parameter, ModelAndViewContainer mavContainer,
            NativeWebRequest webRequest, WebDataBinderFactory binderFactory)
    {
        auto inputMessage = new ServletServerHttpRequest(webRequest.getNativeRequest());
        // Contract 2's elementType is the T of HttpEntity!T or RequestEntity!T; an untyped entity reads text.
        const elementType = parameter.getArgumentSpec().elementType;
        auto body = readWithMessageConverters(webRequest, parameter, elementType.length != 0 ? elementType : "string");
        return Any.of(HttpEntity.of(body, inputMessage.getHeaders()));
    }

    void handleReturnValue(Any returnValue, MethodParameter returnType,
            ModelAndViewContainer mavContainer, NativeWebRequest webRequest)
    {
        mavContainer.setRequestHandled(true);
        if (returnValue.isNull())
            return;
        // ResponseEntity is a struct, so a handler's `null` arrives as ResponseEntity.init, the one entity
        // without a status: Spring leaves the response alone for it.
        if (returnValue.holds!ResponseEntity && returnValue.get!ResponseEntity.getStatusCode().value() == 0)
            return;
        auto outputMessage = createOutputMessage(webRequest);
        HttpEntity httpEntity;
        bool hasStatus;
        HttpStatusCode status;
        if (auto errorResponse = cast(ErrorResponse) returnValue.asObject())
        {
            status = errorResponse.getStatusCode();
            hasStatus = true;
            httpEntity = HttpEntity.of(errorResponse.getBody(), errorResponse.getHeaders());
        }
        else if (returnValue.holds!ProblemDetail)
        {
            auto detail = returnValue.get!ProblemDetail;
            status = HttpStatusCode.valueOf(detail.getStatus());
            hasStatus = true;
            httpEntity = HttpEntity.of(detail);
        }
        else if (returnValue.holds!ResponseEntity)
        {
            auto entity = returnValue.get!ResponseEntity;
            status = entity.getStatusCode();
            hasStatus = true;
            httpEntity = entity.entity;
        }
        else
            httpEntity = returnValue.get!HttpEntity;

        auto outputHeaders = outputMessage.getHeaders();
        foreach (name, values; httpEntity.getHeaders())
            outputHeaders.put(name, values.dup);
        if (hasStatus)
            outputMessage.getServletResponse().setStatus(status.value());
        writeWithMessageConverters(httpEntity.getBody(), returnType, webRequest, outputMessage);
        outputMessage.flush();
    }
}

/// `HttpHeadersReturnValueHandler`: an `HttpHeaders` return value is the response headers.
class HttpHeadersReturnValueHandler : HandlerMethodReturnValueHandler
{
    bool supportsReturnType(MethodParameter returnType)
    {
        return returnType.getParameterType() == "flint.http.HttpHeaders";
    }

    void handleReturnValue(Any returnValue, MethodParameter returnType,
            ModelAndViewContainer mavContainer, NativeWebRequest webRequest)
    {
        mavContainer.setRequestHandled(true);
        if (returnValue.isNull())
            return;
        auto headers = returnValue.get!HttpHeaders;
        auto outputMessage = new ServletServerHttpResponse(webRequest.getNativeResponse());
        foreach (name, values; headers)
            outputMessage.getHeaders().put(name, values.dup);
        outputMessage.flush();
    }
}

/// `ModelAndViewMethodReturnValueHandler`: a returned `ModelAndView` gives the view (or view name) and its model;
/// `null` means the handler wrote the response.
class ModelAndViewMethodReturnValueHandler : HandlerMethodReturnValueHandler
{
    bool supportsReturnType(MethodParameter returnType)
    {
        return returnType.getParameterType() == "flint.web.servlet.ModelAndView";
    }

    void handleReturnValue(Any returnValue, MethodParameter returnType,
            ModelAndViewContainer mavContainer, NativeWebRequest webRequest)
    {
        auto modelAndView = returnValue.isNull() ? null : cast(ModelAndView) returnValue.get!Object;
        if (modelAndView is null)
        {
            mavContainer.setRequestHandled(true);
            return;
        }
        if (modelAndView.isReference())
            mavContainer.setViewName(modelAndView.getViewName());
        else
            mavContainer.setView(cast(Object) modelAndView.getView());
        auto model = modelAndView.getModel();
        foreach (name; model.keySet().toArray())
            mavContainer.addAttribute(name, model.get(name));
    }
}

/// `ViewNameMethodReturnValueHandler`: a `string` (without `@ResponseBody`) names a view; `void` too.
class ViewNameMethodReturnValueHandler : HandlerMethodReturnValueHandler
{
    bool supportsReturnType(MethodParameter returnType)
    {
        const type = returnType.getParameterType();
        return type == "void" || type == "string";
    }

    void handleReturnValue(Any returnValue, MethodParameter returnType,
            ModelAndViewContainer mavContainer, NativeWebRequest webRequest)
    {
        if (returnValue.holds!string)
            mavContainer.setViewName(returnValue.get!string);
    }
}

// ---------------------------------------------------------------------------------------------------------
// Invocation

/// `ServletInvocableHandlerMethod`: invocation plus `@ResponseStatus` and return-value handling.
class ServletInvocableHandlerMethod : InvocableHandlerMethod
{
    private HandlerMethodReturnValueHandlerComposite returnValueHandlers;
    private HandlerMethodReturnValueHandler responseBodyHandler;

    ///
    this(HandlerMethod handlerMethod)
    {
        super(handlerMethod);
    }

    /// Sets the return value handlers, and the `@ResponseBody` handler used for `@ResponseBody` methods.
    void setHandlerMethodReturnValueHandlers(HandlerMethodReturnValueHandlerComposite handlers,
            HandlerMethodReturnValueHandler responseBody)
    {
        returnValueHandlers = handlers;
        responseBodyHandler = responseBody;
    }

    /// Invokes the method and handles its return value.
    void invokeAndHandle(ServletWebRequest webRequest, ModelAndViewContainer mavContainer, Any[] providedArgs = null)
    {
        auto returnValue = invokeForRequest(webRequest, mavContainer, providedArgs);
        setResponseStatus(webRequest);
        if (returnValue.isNull() && (isVoid() || !getReturnType().getParameterType().length))
        {
            if (getResponseStatus() != 0 || mavContainer.isRequestHandled())
            {
                mavContainer.setRequestHandled(true);
                return;
            }
        }
        else if (getResponseStatusReason() !is null)
        {
            mavContainer.setRequestHandled(true);
            return;
        }
        mavContainer.setRequestHandled(false);
        auto returnType = getReturnType();
        // Spring orders ResponseEntity/HttpHeaders handlers before @ResponseBody, and view names after it.
        // supportsReturnType first: it is cheap, and the interface-to-class casts run only when it holds.
        foreach (handler; returnValueHandlers.getHandlers())
        {
            if (handler.supportsReturnType(returnType) && (cast(HttpEntityMethodProcessor) handler
                    || cast(HttpHeadersReturnValueHandler) handler))
            {
                handler.handleReturnValue(returnValue, returnType, mavContainer, webRequest);
                return;
            }
        }
        if (isResponseBody() && responseBodyHandler !is null)
        {
            responseBodyHandler.handleReturnValue(returnValue, returnType, mavContainer, webRequest);
            return;
        }
        returnValueHandlers.handleReturnValue(returnValue, returnType, mavContainer, webRequest);
    }

    private void setResponseStatus(ServletWebRequest webRequest)
    {
        const status = getResponseStatus();
        if (status == 0)
            return;
        auto response = webRequest.getResponse();
        const reason = getResponseStatusReason();
        if (reason !is null)
            response.sendError(status, reason);
        else
            response.setStatus(status);
        webRequest.getRequest().setAttribute("org.springframework.web.servlet.View.responseStatus",
                Any.of(HttpStatusCode.valueOf(status)));
    }
}

// ---------------------------------------------------------------------------------------------------------
// Handler adapter

/// The default argument resolvers, return value handlers and converters, in Spring's order.
private struct DefaultHandlers
{
    HandlerMethodArgumentResolverComposite argumentResolvers;
    HandlerMethodReturnValueHandlerComposite returnValueHandlers;
    RequestResponseBodyMethodProcessor responseBody;

    static DefaultHandlers create(HttpMessageConverter[] converters, ContentNegotiationManager manager,
            HandlerMethodArgumentResolver[] customResolvers, HandlerMethodReturnValueHandler[] customHandlers)
    {
        DefaultHandlers result;
        result.responseBody = new RequestResponseBodyMethodProcessor(converters, manager);
        auto entity = new HttpEntityMethodProcessor(converters, manager);
        result.argumentResolvers = new HandlerMethodArgumentResolverComposite;
        result.argumentResolvers.addResolvers(new RequestParamMethodArgumentResolver(false),
                new PathVariableMethodArgumentResolver, new RequestHeaderMethodArgumentResolver,
                new CookieValueMethodArgumentResolver, result.responseBody,
                new ServletRequestMethodArgumentResolver, new ServletResponseMethodArgumentResolver, entity);
        result.argumentResolvers.addResolvers(customResolvers);
        result.argumentResolvers.addResolvers(new RequestParamMethodArgumentResolver(true));
        result.returnValueHandlers = new HandlerMethodReturnValueHandlerComposite;
        result.returnValueHandlers.addHandlers(new ModelAndViewMethodReturnValueHandler, entity,
                new HttpHeadersReturnValueHandler);
        result.returnValueHandlers.addHandlers(customHandlers);
        result.returnValueHandlers.addHandlers(new ViewNameMethodReturnValueHandler);
        return result;
    }
}

/// `RequestMappingHandlerAdapter`: invokes `HandlerMethod`s.
class RequestMappingHandlerAdapter : HandlerAdapter
{
    private HttpMessageConverter[] messageConverters;
    private ContentNegotiationManager contentNegotiationManager;
    private HandlerMethodArgumentResolver[] customArgumentResolvers;
    private HandlerMethodReturnValueHandler[] customReturnValueHandlers;
    private DefaultHandlers handlers;
    private WebDataBinderFactory binderFactory;

    /// With the message converters (Spring Boot's `HttpMessageConverters`).
    this(HttpMessageConverter[] messageConverters, ContentNegotiationManager manager = null,
            HandlerMethodArgumentResolver[] customArgumentResolvers = null,
            HandlerMethodReturnValueHandler[] customReturnValueHandlers = null)
    {
        this.messageConverters = messageConverters;
        contentNegotiationManager = manager !is null ? manager : new ContentNegotiationManager;
        this.customArgumentResolvers = customArgumentResolvers;
        this.customReturnValueHandlers = customReturnValueHandlers;
        handlers = DefaultHandlers.create(messageConverters, contentNegotiationManager,
                customArgumentResolvers, customReturnValueHandlers);
        binderFactory = new DefaultDataBinderFactory;
    }

    /// The message converters.
    HttpMessageConverter[] getMessageConverters() pure nothrow @nogc
    {
        return messageConverters;
    }

    /// The argument resolvers.
    HandlerMethodArgumentResolverComposite getArgumentResolvers() pure nothrow @nogc
    {
        return handlers.argumentResolvers;
    }

    /// The return value handlers.
    HandlerMethodReturnValueHandlerComposite getReturnValueHandlers() pure nothrow @nogc
    {
        return handlers.returnValueHandlers;
    }

    package(flint) RequestResponseBodyMethodProcessor getResponseBodyHandler() pure nothrow @nogc
    {
        return handlers.responseBody;
    }

    /// The validator for `@Valid` arguments (Spring's `ConfigurableWebBindingInitializer.setValidator`), with
    /// the descriptor table its binding results read properties through.
    void setValidator(Validator validator, DescriptorTable descriptors = null)
    {
        handlers.responseBody.setValidator(validator, descriptors);
    }

    package(flint) WebDataBinderFactory getBinderFactory() pure nothrow @nogc
    {
        return binderFactory;
    }

    /// The descriptors request values convert through (`Optional!T` and array parameters); Spring's conversion
    /// service in the `WebBindingInitializer`.
    package(flint) void setDescriptors(DescriptorTable descriptors)
    {
        binderFactory = new DefaultDataBinderFactory(descriptors);
    }

    bool supports(Object handler)
    {
        return cast(HandlerMethod) handler !is null;
    }

    ModelAndView handle(HttpServletRequest request, HttpServletResponse response, Object handler)
    {
        auto handlerMethod = cast(HandlerMethod) handler;
        auto webRequest = new ServletWebRequest(request, response);
        auto invocable = new ServletInvocableHandlerMethod(handlerMethod);
        invocable.setHandlerMethodArgumentResolvers(handlers.argumentResolvers);
        invocable.setHandlerMethodReturnValueHandlers(handlers.returnValueHandlers, handlers.responseBody);
        invocable.setDataBinderFactory(binderFactory);
        auto mavContainer = new ModelAndViewContainer;
        invocable.invokeAndHandle(webRequest, mavContainer);
        return getModelAndView(mavContainer);
    }

    private static ModelAndView getModelAndView(ModelAndViewContainer mavContainer)
    {
        if (mavContainer.isRequestHandled())
            return null;
        auto mav = new ModelAndView(mavContainer.getViewName(), mavContainer.getModel());
        if (!mavContainer.isViewReference())
            mav.setView(cast(imported!"flint.web.servlet".View) mavContainer.getView());
        if (auto status = mavContainer.getStatus())
            mav.setStatus(*status);
        return mav;
    }
}

// ---------------------------------------------------------------------------------------------------------
// @ExceptionHandler

/// One `@ControllerAdvice` bean and its exception handlers, as Spring's `ControllerAdviceBean`.
struct ControllerAdviceBean
{
    string beanName; ///
    int order = int.max; ///
    string[] basePackages; ///
    string[] assignableTypes; ///
    string[] annotations; ///
    ExceptionHandlerSpec[] handlers; ///

    /// Whether the advice applies to a controller of `beanType` carrying `typeAnnotations` (Spring's
    /// `HandlerTypePredicate`: a name prefix of a base package, an assignable type, or a class annotation).
    /// `supertypes` are the controller's superclasses and interfaces, for assignability; a null `beanType` (no
    /// handler) matches only an advice without selectors.
    // dfmt off
    bool isApplicableToBeanType(string beanType, scope const(MergedAnnotation)[] typeAnnotations = null,
            scope const(string)[] supertypes = null) const pure nothrow @nogc
    {
        if (basePackages.length == 0 && assignableTypes.length == 0 && annotations.length == 0)
            return true;
        if (beanType is null)
            return false;
        foreach (p; basePackages)
            if (beanType.length >= p.length && beanType[0 .. p.length] == p)
                return true;
        foreach (t; assignableTypes)
        {
            if (t == beanType)
                return true;
            foreach (supertype; supertypes)
                if (t == supertype)
                    return true;
        }
        foreach (a; annotations)
            foreach (ref annotation; typeAnnotations)
                if (annotation.type == a)
                    return true;
        return false;
    }
    // dfmt on
}

/// The superclasses (up to, not including, `Object`) and interfaces of `bean`'s class, by fully qualified name.
private string[] supertypesOf(Object bean) pure nothrow
{
    string[] names;
    void addInterfaces(TypeInfo_Class type)
    {
        foreach (ref implemented; type.interfaces)
        {
            names ~= implemented.classinfo.name;
            addInterfaces(implemented.classinfo);
        }
    }

    if (bean is null)
        return null;
    for (TypeInfo_Class type = typeid(bean); type !is null && type !is typeid(Object); type = type.base)
    {
        if (type !is typeid(bean))
            names ~= type.name;
        addInterfaces(type);
    }
    return names;
}

/// `ExceptionHandlerExceptionResolver`: invokes `@ExceptionHandler` methods of the controller, then of advice.
class ExceptionHandlerExceptionResolver : AbstractHandlerExceptionResolver
{
    private ExceptionHandlerSpec[] handlerSpecs;
    private ControllerAdviceBean[] adviceBeans;
    private BeanFactory beanFactory;
    private RequestMappingHandlerAdapter adapter;

    /// Over Flint AOT's exception-handler table, sharing the adapter's resolvers and handlers.
    this(ExceptionHandlerSpec[] handlerSpecs, BeanFactory beanFactory,
            RequestMappingHandlerAdapter adapter, int[string] adviceOrder = null)
    {
        this.handlerSpecs = handlerSpecs;
        this.beanFactory = beanFactory;
        this.adapter = adapter;
        foreach (spec; handlerSpecs)
        {
            if (!spec.advice)
                continue;
            bool found;
            foreach (ref advice; adviceBeans)
                if (advice.beanName == spec.bean)
                {
                    advice.handlers ~= spec;
                    found = true;
                }
            if (!found)
            {
                ControllerAdviceBean advice;
                advice.beanName = spec.bean;
                advice.basePackages = spec.adviceBasePackages;
                advice.assignableTypes = spec.adviceAssignableTypes;
                advice.annotations = spec.adviceAnnotations;
                if (auto order = spec.bean in adviceOrder)
                    advice.order = *order;
                advice.handlers = [spec];
                adviceBeans ~= advice;
            }
        }
        // OrderComparator: lower order first; equal orders keep definition order.
        for (size_t i = 1; i < adviceBeans.length; i++)
        {
            auto a = adviceBeans[i];
            size_t j = i;
            while (j > 0 && adviceBeans[j - 1].order > a.order)
            {
                adviceBeans[j] = adviceBeans[j - 1];
                j--;
            }
            adviceBeans[j] = a;
        }
    }

    protected override bool shouldApplyTo(HttpServletRequest request, Object handler)
    {
        // AbstractHandlerMethodExceptionResolver, plus Spring 6.1's default for ResourceHttpRequestHandler: global
        // (@ControllerAdvice) handlers apply to it, so NoResourceFoundException reaches the application's advice.
        return handler is null || cast(HandlerMethod) handler !is null
            || (cast(ResourceHttpRequestHandler) handler !is null && adviceBeans.length != 0);
    }

    protected override ModelAndView doResolveException(HttpServletRequest request,
            HttpServletResponse response, Object handler, Exception exception)
    {
        auto handlerMethod = cast(HandlerMethod) handler;
        Object bean;
        ExceptionHandlerSpec* spec = findHandler(handlerMethod, exception, bean);
        if (spec is null)
            return null;
        auto exceptionHandlerMethod = new ServletInvocableHandlerMethod(new HandlerMethod(bean,
                spec.beanType.length != 0 ? spec.beanType : typeid(bean).name, *spec));
        exceptionHandlerMethod.setHandlerMethodArgumentResolvers(adapter.getArgumentResolvers());
        exceptionHandlerMethod.setHandlerMethodReturnValueHandlers(adapter.getReturnValueHandlers(),
                adapter.getResponseBodyHandler());
        exceptionHandlerMethod.setDataBinderFactory(adapter.getBinderFactory());
        auto webRequest = new ServletWebRequest(request, response);
        auto mavContainer = new ModelAndViewContainer;
        Any[] provided = [Any.of(cast(Object) exception)];
        for (Throwable cause = causeOf(exception); cause !is null; cause = causeOf(cause))
            provided ~= Any.of(cast(Object) cause);
        if (handlerMethod !is null)
            provided ~= Any.of(cast(Object) handlerMethod);
        try
            exceptionHandlerMethod.invokeAndHandle(webRequest, mavContainer, provided);
        catch (Exception invocationEx)
        {
            // Spring logs and lets the original exception continue, unless the handler rethrew it.
            if (invocationEx !is exception)
                return null;
            return null;
        }
        if (mavContainer.isRequestHandled())
            return new ModelAndView();
        auto mav = new ModelAndView(mavContainer.getViewName(), mavContainer.getModel());
        if (!mavContainer.isViewReference())
            mav.setView(cast(imported!"flint.web.servlet".View) mavContainer.getView());
        if (auto status = mavContainer.getStatus())
            mav.setStatus(*status);
        return mav;
    }

    private ExceptionHandlerSpec* findHandler(HandlerMethod handlerMethod, Exception exception, out Object bean)
    {
        if (handlerMethod !is null)
        {
            ExceptionHandlerSpec[] local;
            foreach (spec; handlerSpecs)
                if (!spec.advice && spec.bean == handlerMethod.getBeanName())
                    local ~= spec;
            if (auto found = new ExceptionHandlerMethodResolver(local).resolveMethod(exception))
            {
                bean = handlerMethod.getBean();
                return found;
            }
        }
        const supertypes = handlerMethod is null ? null : supertypesOf(handlerMethod.getBean());
        foreach (ref advice; adviceBeans)
        {
            if (handlerMethod is null ? !advice.isApplicableToBeanType(null) : !advice.isApplicableToBeanType(
                    handlerMethod.getBeanType(), handlerMethod.getBeanTypeAnnotations(), supertypes))
                continue;
            if (auto found = new ExceptionHandlerMethodResolver(advice.handlers).resolveMethod(exception))
            {
                bean = beanFactory.getBean(advice.beanName);
                return found;
            }
        }
        return null;
    }
}
