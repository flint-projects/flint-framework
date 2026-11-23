/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
ServletInvocableHandlerMethodTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` returns. `new ServletInvocableHandlerMethod(controller, method)` wraps a
`HandlerMethod` over the `HandlerMapping` row Flint AOT writes for the method (as
flint.web.servlet.mvc.method.aot builds it, without requiring `@RequestMapping`): the parameters' `ArgumentSpec`s,
the return type, `@ResponseStatus` and `@ResponseBody` from the merged annotations, and an invoker that converts
each argument with `Any.get!T`. The composites' `addResolver` and `addHandler` are the variadic `addResolvers` and
`addHandlers`; `setHandlerMethodReturnValueHandlers` also takes the `@ResponseBody` handler, `null` here as
Spring's test registers none. Java's `return null` from a `ResponseEntity` method is `ResponseEntity.init`. The
test lives with flint.mock.web in flint:framework-test. Cases that need unported features or behave differently
are gated by version.
+/
module flint.web.servlet_invocable_handler_method_tests;

// flint.web first: importing flint.web.method.support before it trips a forward-reference error on
// LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.core : MethodParameter;
import flint.core.annotation : AliasFor;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : MethodDescriptor, findAnnotation, mergedAnnotations;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec, HandlerArguments, HandlerMapping;
import flint.engine.aot.name : typeNameOf;
import flint.http : HttpStatus, ResponseEntity;
import flint.http.converter : HttpMessageConverter, HttpMessageNotWritableException, StringHttpMessageConverter;
import flint.jakarta.servlet.http : HttpServletResponse;
import flint.java.lang : classOf;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.bind.annotation : ResponseBody, ResponseStatus, ValueConstants;
import flint.web.context.request : NativeWebRequest, ServletWebRequest;
import flint.web.method : HandlerMethod;
import flint.web.method.support : HandlerMethodArgumentResolverComposite,
    HandlerMethodReturnValueHandler, HandlerMethodReturnValueHandlerComposite, ModelAndViewContainer;
import flint.web.servlet.mvc.method.annotation : HttpEntityMethodProcessor,
    ServletInvocableHandlerMethod, ServletResponseMethodArgumentResolver;
import std.traits : ParameterIdentifierTuple, Parameters, ReturnType;

@safe:

private struct Fixture
{
    HttpMessageConverter[] converters;
    HandlerMethodArgumentResolverComposite argumentResolvers;
    HandlerMethodReturnValueHandlerComposite returnValueHandlers;
    ModelAndViewContainer mavContainer;
    MockHttpServletRequest request;
    MockHttpServletResponse response;
    ServletWebRequest webRequest;
}

private Fixture setup()
{
    Fixture f;
    f.converters = [new StringHttpMessageConverter()];
    f.argumentResolvers = new HandlerMethodArgumentResolverComposite();
    f.returnValueHandlers = new HandlerMethodReturnValueHandlerComposite();
    f.mavContainer = new ModelAndViewContainer();
    f.request = new MockHttpServletRequest("GET", "/");
    f.response = new MockHttpServletResponse();
    f.webRequest = new ServletWebRequest(f.request, f.response);
    return f;
}

@("ServletInvocableHandlerMethodTests.invokeAndHandle_VoidWithResponseStatus")
unittest
{
    auto f = setup();
    auto handlerMethod = getHandlerMethod!(Handler, "responseStatus")(f, new Handler());
    handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);

    assert(f.response.getStatus() == HttpStatus.BAD_REQUEST.value());
    assert(f.mavContainer.isRequestHandled(), "Null return value + @ResponseStatus should result in 'request handled'");
}

@("ServletInvocableHandlerMethodTests.invokeAndHandle_VoidWithComposedResponseStatus")
unittest
{
    auto f = setup();
    auto handlerMethod = getHandlerMethod!(Handler, "composedResponseStatus")(f, new Handler());
    handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);

    assert(f.response.getStatus() == HttpStatus.BAD_REQUEST.value());
    assert(f.mavContainer.isRequestHandled(),
            "Null return value + @ComposedResponseStatus should result in 'request handled'");
}

@("ServletInvocableHandlerMethodTests.invokeAndHandle_VoidWithTypeLevelResponseStatus")
unittest
{
    auto f = setup();
    auto handlerMethod = getHandlerMethod!(ResponseStatusHandler, "handle")(f, new ResponseStatusHandler());
    handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);

    assert(f.mavContainer.isRequestHandled());
    assert(f.response.getStatus() == HttpStatus.BAD_REQUEST.value());
}

@("ServletInvocableHandlerMethodTests.invokeAndHandle_VoidWithHttpServletResponseArgument")
unittest
{
    auto f = setup();
    f.argumentResolvers.addResolvers(new ServletResponseMethodArgumentResolver());

    auto handlerMethod = getHandlerMethod!(Handler, "httpServletResponse")(f, new Handler());
    handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);

    assert(f.mavContainer.isRequestHandled(),
            "Null return value + HttpServletResponse arg should result in 'request handled'");
}

// ServletWebRequest has no checkNotModified.
version (FlintWebRequestNotModified)
{
    @("ServletInvocableHandlerMethodTests.invokeAndHandle_VoidRequestNotModified")
    unittest
    {
        auto f = setup();
        f.request.addHeader("If-Modified-Since", "10000000");
        const lastModifiedTimestamp = 1000 * 1000;
        f.webRequest.checkNotModified(lastModifiedTimestamp);

        auto handlerMethod = getHandlerMethod!(Handler, "notModified")(f, new Handler());
        handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);

        assert(f.mavContainer.isRequestHandled(),
                "Null return value + 'not modified' request should result in 'request handled'");
    }
}

// ShallowEtagHeaderFilter (and ServletWebRequest.checkNotModified) are not ported.
version (FlintShallowEtagHeaderFilter)
{
    import flint.http : HttpHeaders;
    import flint.jakarta.servlet : FilterChain, ServletRequest, ServletResponse;
    import flint.java.lang : IllegalStateException;
    import flint.web.filter : ShallowEtagHeaderFilter;

    /// Spring's lambda `FilterChain`.
    private final class LambdaFilterChain : FilterChain
    {
        private void delegate() @safe body_;

        this(void delegate() @safe body_)
        {
            this.body_ = body_;
        }

        void doFilter(ServletRequest, ServletResponse)
        {
            body_();
        }
    }

    @("ServletInvocableHandlerMethodTests.invokeAndHandle_VoidNotModifiedWithEtag")
    unittest
    {
        auto f = setup();
        const eTagValue = "\"deadb33f8badf00d\"";

        auto chain = new LambdaFilterChain(() {
            f.request.addHeader(HttpHeaders.IF_NONE_MATCH, eTagValue);
            f.webRequest.checkNotModified(eTagValue);

            try
            {
                auto handlerMethod = getHandlerMethod!(Handler, "notModified")(f, new Handler());
                handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);
            }
            catch (Exception ex)
                throw new IllegalStateException(ex.msg, ex);
        });

        new ShallowEtagHeaderFilter().doFilter(f.request, f.response, chain);

        assert(f.response.getStatus() == 304);
        assert(f.response.getHeader(HttpHeaders.ETAG) == eTagValue);
        assert(f.response.getContentAsString().length == 0);
    }

    // gh-23775, gh-24635
    @("ServletInvocableHandlerMethodTests.invokeAndHandle_ETagFilterHasNoImpactWhenETagPresent")
    unittest
    {
        auto f = setup();
        const eTagValue = "\"deadb33f8badf00d\"";

        auto chain = new LambdaFilterChain(() {
            f.request.addHeader(HttpHeaders.IF_NONE_MATCH, eTagValue);
            f.webRequest.checkNotModified(eTagValue);

            try
            {
                auto handlerMethod = getHandlerMethod!(Handler, "notModified")(f, new Handler());
                handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);
            }
            catch (Exception ex)
                throw new IllegalStateException(ex.msg, ex);
        });

        new ShallowEtagHeaderFilter().doFilter(f.request, f.response, chain);

        assert(f.response.getStatus() == 304);
        assert(f.response.getHeader(HttpHeaders.ETAG) == eTagValue);
        assert(f.response.getContentAsString().length == 0);
    }
}

// SPR-9159
@("ServletInvocableHandlerMethodTests.invokeAndHandle_NotVoidWithResponseStatusAndReason")
unittest
{
    auto f = setup();
    auto handlerMethod = getHandlerMethod!(Handler, "responseStatusWithReason")(f, new Handler());
    handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);

    assert(f.response.getStatus() == HttpStatus.BAD_REQUEST.value());
    assert(f.response.getErrorMessage() == "400 Bad Request");
    assert(f.mavContainer.isRequestHandled(), "When a status reason w/ used, the request is handled");
}

// HandlerMethod has no bean-name and MessageSource constructor, so @ResponseStatus reason codes are not resolved.
version (FlintHandlerMethodMessageSource)
{
    import flint.context.i18n : LocaleContextHolder;
    import flint.context.support : StaticApplicationContext;
    import flint.java.util : Locale;

    @("ServletInvocableHandlerMethodTests.invokeAndHandle_responseStatusAndReasonCode")
    unittest
    {
        auto f = setup();
        const locale = Locale.ENGLISH;

        const beanName = "handler";
        auto context = new StaticApplicationContext();
        context.registerBean!Handler(beanName);
        context.addMessage("BadRequest.error", locale, "Bad request message");
        context.refresh();

        auto beanFactory = context.getBeanFactory();

        LocaleContextHolder.setLocale(locale);
        scope (exit)
            LocaleContextHolder.resetLocaleContext();

        auto handlerMethod = new HandlerMethod(beanName, beanFactory, context,
                handlerRow!(Handler, Handler.responseStatusWithReasonCode)());
        handlerMethod = handlerMethod.createWithResolvedBean();

        new ServletInvocableHandlerMethod(handlerMethod).invokeAndHandle(f.webRequest, f.mavContainer);

        assert(f.response.getStatus() == HttpStatus.BAD_REQUEST.value());
        assert(f.response.getErrorMessage() == "Bad request message");
    }
}

@("ServletInvocableHandlerMethodTests.invokeAndHandle_Exception")
unittest
{
    auto f = setup();
    f.returnValueHandlers.addHandlers(new ExceptionRaisingReturnValueHandler());

    auto handlerMethod = getHandlerMethod!(Handler, "handle")(f, new Handler());
    assert(thrown!HttpMessageNotWritableException(() {
            handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);
        }) !is null);
}

// RedirectView and ViewMethodReturnValueHandler are not ported (and return value handlers are selected by the
// declared return type, not the returned value's type).
version (FlintWebRedirectView)
{
    import flint.web.method.annotation : RequestParamMethodArgumentResolver;
    import flint.web.servlet.mvc.method.annotation : ViewMethodReturnValueHandler, ViewNameMethodReturnValueHandler;
    import flint.web.servlet.view : RedirectView;

    @("ServletInvocableHandlerMethodTests.invokeAndHandle_DynamicReturnValue")
    unittest
    {
        auto f = setup();
        f.argumentResolvers.addResolvers(new RequestParamMethodArgumentResolver(false));
        f.returnValueHandlers.addHandlers(new ViewMethodReturnValueHandler());
        f.returnValueHandlers.addHandlers(new ViewNameMethodReturnValueHandler());

        // Invoke without a request parameter (String return value)
        auto hm = getHandlerMethod!(Handler, "dynamicReturnValue")(f, new Handler());
        hm.invokeAndHandle(f.webRequest, f.mavContainer);

        assert(f.mavContainer.getView() !is null);
        assert(typeid(f.mavContainer.getView()) is typeid(RedirectView));

        // Invoke with a request parameter (RedirectView return value)
        f.request.setParameter("param", "value");
        hm.invokeAndHandle(f.webRequest, f.mavContainer);

        assert(f.mavContainer.getViewName() == "view");
    }
}

// Async request processing (wrapConcurrentResult, DeferredResult, ResponseBodyEmitter, StreamingResponseBody,
// ReactiveTypeHandler) is not ported.
version (FlintAsyncWebRequest)
{
    import flint.http.converter.json : JacksonJsonHttpMessageConverter;
    import flint.java.util : List;
    import flint.web.accept : ContentNegotiationManager;
    import flint.web.servlet.mvc.method.annotation : ModelAndViewMethodReturnValueHandler, ReactiveTypeHandler,
        RequestResponseBodyMethodProcessor,
        ResponseBodyEmitterReturnValueHandler, StreamingResponseBodyReturnValueHandler;

    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_MethodLevelResponseBody")
    unittest
    {
        auto f = setup();
        wrapConcurrentResultResponseBody!(MethodLevelResponseBodyHandler)(f, Any.of("bar"), typeNameOf!string);
    }

    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_MethodLevelResponseBodyEmpty")
    unittest
    {
        auto f = setup();
        wrapConcurrentResultResponseBody!(MethodLevelResponseBodyHandler)(f, Any.init, typeNameOf!string);
    }

    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_TypeLevelResponseBody")
    unittest
    {
        auto f = setup();
        wrapConcurrentResultResponseBody!(TypeLevelResponseBodyHandler)(f, Any.of("bar"), typeNameOf!string);
    }

    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_TypeLevelResponseBodyEmpty")
    unittest
    {
        auto f = setup();
        wrapConcurrentResultResponseBody!(TypeLevelResponseBodyHandler)(f, Any.init, typeNameOf!string);
    }

    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_DeferredResultSubclass")
    unittest
    {
        auto f = setup();
        wrapConcurrentResultResponseBody!(DeferredResultSubclassHandler)(f, Any.of("bar"), typeNameOf!string);
    }

    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_DeferredResultSubclassEmpty")
    unittest
    {
        auto f = setup();
        wrapConcurrentResultResponseBody!(DeferredResultSubclassHandler)(f, Any.init,
                typeNameOf!CustomDeferredResult);
    }

    private void wrapConcurrentResultResponseBody(C)(ref Fixture f, Any result, string expectedReturnType)
    {
        f.returnValueHandlers.addHandlers(new ModelAndViewMethodReturnValueHandler());
        f.returnValueHandlers.addHandlers(new RequestResponseBodyMethodProcessor(f.converters));
        auto handlerMethod = getHandlerMethod!(C, "handle")(f, new C());

        handlerMethod = handlerMethod.wrapConcurrentResult(result);
        handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);
        const expected = !result.isNull() ? result.get!string : "";
        assert(f.response.getContentAsString() == expected);
        assert(handlerMethod.getReturnValueType(result).getParameterType() == expectedReturnType);
    }

    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_ResponseEntity")
    unittest
    {
        auto f = setup();
        f.returnValueHandlers.addHandlers(new HttpEntityMethodProcessor(f.converters));
        auto handlerMethod = getHandlerMethod!(ResponseEntityHandler, "handleDeferred")(f, new ResponseEntityHandler());
        handlerMethod = handlerMethod.wrapConcurrentResult(Any.of(ResponseEntity.of("bar", HttpStatus.OK)));
        handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);

        assert(f.response.getContentAsString() == "bar");
    }

    // SPR-12287
    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_ResponseEntityNullBody")
    unittest
    {
        auto f = setup();
        f.returnValueHandlers.addHandlers(new HttpEntityMethodProcessor(f.converters));
        auto handlerMethod = getHandlerMethod!(ResponseEntityHandler, "handleDeferred")(f, new ResponseEntityHandler());
        handlerMethod = handlerMethod.wrapConcurrentResult(Any.of(ResponseEntity(HttpStatus.OK)));
        handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);

        assert(f.response.getStatus() == 200);
        assert(f.response.getContentAsString().length == 0);
    }

    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_ResponseEntityNullReturnValue")
    unittest
    {
        auto f = setup();
        f.returnValueHandlers.addHandlers(new HttpEntityMethodProcessor(f.converters));
        auto handlerMethod = getHandlerMethod!(ResponseEntityHandler, "handleDeferred")(f, new ResponseEntityHandler());
        handlerMethod = handlerMethod.wrapConcurrentResult(Any.init);
        handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);

        assert(f.response.getStatus() == 200);
        assert(f.response.getContentAsString().length == 0);
    }

    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_ResponseBodyEmitter")
    unittest
    {
        auto f = setup();
        f.returnValueHandlers.addHandlers(new ResponseBodyEmitterReturnValueHandler(f.converters));

        auto handlerMethod = getHandlerMethod!(StreamingHandler, "handleEmitter")(f, new StreamingHandler());
        handlerMethod = handlerMethod.wrapConcurrentResult(Any.init);
        handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);

        assert(f.response.getStatus() == 200);
        assert(f.response.getContentAsString().length == 0);
    }

    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_StreamingResponseBody")
    unittest
    {
        auto f = setup();
        f.returnValueHandlers.addHandlers(new StreamingResponseBodyReturnValueHandler());
        auto handlerMethod = getHandlerMethod!(StreamingHandler, "handleStreamBody")(f, new StreamingHandler());
        handlerMethod = handlerMethod.wrapConcurrentResult(Any.init);
        handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);

        assert(f.response.getStatus() == 200);
        assert(f.response.getContentAsString().length == 0);
    }

    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_CollectedValuesList")
    unittest
    {
        auto f = setup();
        HttpMessageConverter[] converters = [new JacksonJsonHttpMessageConverter()];
        auto result = new ReactiveTypeHandler.CollectedValuesList(typeNameOf!(List!string));
        result.add(Any.of(List!string.of("foo1", "bar1")));
        result.add(Any.of(List!string.of("foo2", "bar2")));

        auto manager = new ContentNegotiationManager();
        f.returnValueHandlers.addHandlers(new RequestResponseBodyMethodProcessor(converters, manager));
        auto hm = getHandlerMethod!(MethodLevelResponseBodyHandler, "handleFluxOfLists")(f,
                new MethodLevelResponseBodyHandler());
        hm = hm.wrapConcurrentResult(Any.of(result));
        hm.invokeAndHandle(f.webRequest, f.mavContainer);

        assert(f.response.getStatus() == 200);
        assert(f.response.getContentAsString() == `[["foo1","bar1"],["foo2","bar2"]]`);
    }

    // SPR-15478
    @("ServletInvocableHandlerMethodTests.wrapConcurrentResult_CollectedValuesListWithResponseEntity")
    unittest
    {
        auto f = setup();
        HttpMessageConverter[] converters = [new JacksonJsonHttpMessageConverter()];
        auto result = new ReactiveTypeHandler.CollectedValuesList(typeNameOf!Bar);
        result.add(Any.of(new Bar("foo")));
        result.add(Any.of(new Bar("bar")));

        auto manager = new ContentNegotiationManager();
        f.returnValueHandlers.addHandlers(new RequestResponseBodyMethodProcessor(converters, manager));
        auto hm = getHandlerMethod!(ResponseEntityHandler, "handleFlux")(f, new ResponseEntityHandler());
        hm = hm.wrapConcurrentResult(Any.of(result));
        hm.invokeAndHandle(f.webRequest, f.mavContainer);

        assert(f.response.getStatus() == 200);
        assert(f.response.getContentAsString() == `[{"value":"foo"},{"value":"bar"}]`);
    }
}

// ResponseEntity is a struct: the handler's null is ResponseEntity.init, which has no status.
// SPR-12287 (16/Oct/14 comments)
@("ServletInvocableHandlerMethodTests.responseEntityRawTypeWithNullBody")
unittest
{
    auto f = setup();
    f.returnValueHandlers.addHandlers(new HttpEntityMethodProcessor(f.converters));
    auto handlerMethod = getHandlerMethod!(ResponseEntityHandler, "handleRawType")(f, new ResponseEntityHandler());
    handlerMethod.invokeAndHandle(f.webRequest, f.mavContainer);

    assert(f.response.getStatus() == 200);
    assert(f.response.getContentAsString().length == 0);
}

/// `controller.getClass().getDeclaredMethod(methodName)`, wrapped as Spring's `getHandlerMethod` does.
private ServletInvocableHandlerMethod getHandlerMethod(C, string methodName)(ref Fixture f, C controller)
{
    auto handlerMethod = new ServletInvocableHandlerMethod(new HandlerMethod(controller,
            typeNameOf!C, handlerRow!(C, __traits(getMember, C, methodName))()));
    handlerMethod.setHandlerMethodArgumentResolvers(f.argumentResolvers);
    handlerMethod.setHandlerMethodReturnValueHandlers(f.returnValueHandlers, null);
    return handlerMethod;
}

/// The `HandlerMapping` row Flint AOT writes for `method` of `C`, as flint.web.servlet.mvc.method.aot builds it:
/// parameters by name and type, the return type, `@ResponseStatus` from the method's merged annotations,
/// `@ResponseBody` from the method's or the class's, and the invoker.
private HandlerMapping handlerRow(C, alias method)()
{
    alias names = ParameterIdentifierTuple!method;
    HandlerMapping row;
    row.bean = "handler";
    row.beanType = typeNameOf!C;
    row.typeAnnotations = mergedAnnotations!(__traits(getAttributes, C))();
    auto methodAnnotations = mergedAnnotations!(__traits(getAttributes, method))();
    static foreach (i, P; Parameters!method)
    {
        {
            ArgumentSpec spec;
            spec.name = names[i];
            spec.type = typeNameOf!P;
            spec.defaultValue = ValueConstants.DEFAULT_NONE;
            spec.kind = ArgumentKind.byType;
            spec.required = true;
            row.arguments ~= spec;
        }
    }
    static if (is(ReturnType!method == void))
        row.returnType = "void";
    else
        row.returnType = typeNameOf!(ReturnType!method);
    row.responseBody = findAnnotation(row.typeAnnotations, typeNameOf!ResponseBody) !is null
        || findAnnotation(methodAnnotations, typeNameOf!ResponseBody) !is null;
    if (auto status = findAnnotation(methodAnnotations, typeNameOf!ResponseStatus))
    {
        const value = status.value.get!ResponseStatus;
        row.responseStatus = value.code.value();
        row.reason = value.reason;
    }
    auto descriptor = new MethodDescriptor;
    descriptor.name = __traits(identifier, method);
    descriptor.returnType = row.returnType;
    descriptor.annotations = methodAnnotations;
    row.method = descriptor;
    row.invoke = &invokeHandler!(C, method);
    return row;
}

/// Flint AOT's generated invoker: each argument converted with `Any.get!T` (`T.init` when null).
private void invokeHandler(C, alias method)(Object bean, HandlerArguments arguments, ref Any result)
{
    auto controller = cast(C) bean;
    Parameters!method args;
    static foreach (i, P; Parameters!method)
    {
        {
            auto value = arguments.get(i);
            if (!value.isNull())
            {
                static if (is(P == class) || is(P == interface))
                    args[i] = cast(P) value.asObject();
                else
                    args[i] = value.get!P;
            }
        }
    }
    static if (is(ReturnType!method == void))
        __traits(child, controller, method)(args);
    else
        result = Any.of(__traits(child, controller, method)(args));
}

/// The exception `action` throws, or `null`.
private E thrown(E : Exception)(scope void delegate() @safe action)
{
    try
        action();
    catch (E ex)
        return ex;
    return null;
}

@ResponseStatus private struct ComposedResponseStatus
{
    @AliasFor(annotation : classOf!ResponseStatus, attribute:
            "code")
    HttpStatus responseStatus = HttpStatus.INTERNAL_SERVER_ERROR;
}

private class Handler
{
    string handle()
    {
        return "view";
    }

    @ResponseStatus(HttpStatus.BAD_REQUEST)
    void responseStatus()
    {
    }

    @ResponseStatus(code : HttpStatus.BAD_REQUEST, reason:
            "400 Bad Request")
    string responseStatusWithReason()
    {
        return "foo";
    }

    @ResponseStatus(code : HttpStatus.BAD_REQUEST, reason:
            "BadRequest.error")
    string responseStatusWithReasonCode()
    {
        return "foo";
    }

    @ComposedResponseStatus(responseStatus : HttpStatus.BAD_REQUEST)
    void composedResponseStatus()
    {
    }

    void httpServletResponse(HttpServletResponse)
    {
    }

    void notModified()
    {
    }

    version (FlintWebRedirectView)
    {
        import flint.web.bind.annotation : RequestParam;

        Any dynamicReturnValue(@RequestParam(required : false) string param)
        {
            return param !is null ? Any.of("view") : Any.of(new RedirectView("redirectView"));
        }
    }
}

@ResponseStatus(HttpStatus.BAD_REQUEST)
private class ResponseStatusHandler
{
    void handle()
    {
    }
}

version (FlintAsyncWebRequest)
{
    import flint.web.context.request.async : DeferredResult;
    import flint.web.servlet.mvc.method.annotation : ResponseBodyEmitter, StreamingResponseBody;
    import reactor.core.publisher : Flux;

    private class MethodLevelResponseBodyHandler
    {
        @ResponseBody DeferredResult!string handle()
        {
            return null;
        }

        // Unusual but legal return type
        // Properly test generic type handling of Flux values collected to a List

        @ResponseBody Flux!(List!string) handleFluxOfLists()
        {
            return null;
        }
    }

    @ResponseBody private class TypeLevelResponseBodyHandler
    {
        DeferredResult!string handle()
        {
            return null;
        }
    }

    private class DeferredResultSubclassHandler
    {
        @ResponseBody CustomDeferredResult handle()
        {
            return null;
        }
    }

    private class CustomDeferredResult : DeferredResult!string
    {
    }

    private class StreamingHandler
    {
        ResponseBodyEmitter handleEmitter()
        {
            return null;
        }

        StreamingResponseBody handleStreamBody()
        {
            return null;
        }
    }

    private class Bar
    {
        private string value;

        this(string value)
        {
            this.value = value;
        }

        string getValue()
        {
            return value;
        }
    }
}

private class ResponseEntityHandler
{
    version (FlintAsyncWebRequest)
    {
        DeferredResult!ResponseEntity handleDeferred()
        {
            return null;
        }

        ResponseEntity handleFlux()
        {
            return ResponseEntity.init;
        }
    }

    ResponseEntity handleRawType()
    {
        return ResponseEntity.init;
    }
}

private final class ExceptionRaisingReturnValueHandler : HandlerMethodReturnValueHandler
{
    bool supportsReturnType(MethodParameter)
    {
        return true;
    }

    void handleReturnValue(Any, MethodParameter, ModelAndViewContainer, NativeWebRequest)
    {
        throw new HttpMessageNotWritableException("oops, can't write");
    }
}
