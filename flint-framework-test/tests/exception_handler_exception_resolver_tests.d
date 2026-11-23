/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
ExceptionHandlerExceptionResolverTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` returns, and the resolver has no warn log category to set. The resolver is built
over Flint AOT's exception-handler table (`exceptionHandlersOf` for the test's controllers and the loaded advice)
with a `RequestMappingHandlerAdapter` over Spring's byte-array and string converters: `afterPropertiesSet` builds
it, and `loadConfiguration` registers a configuration's advice beans (a `@Configuration` with `@Bean` methods
becomes the list of advice classes it declares) in a `StaticBeanFactory`, with their `@Order`.
`new HandlerMethod(bean, "handle")` is the `HandlerMapping` row Flint AOT writes for the method. Java's
`IllegalAccessException`, `ArrayIndexOutOfBoundsException` and `SocketTimeoutException` are private exception
classes with Java's hierarchy, and `WebApplicationObjectSupport` a private base class; Java's
`new Exception(cause)` is D's `new Exception(cause.toString(), cause)`, whose cause is `next`. `AssertionError` is
an `Exception` in Flint (R8), so the handler that declares Java's `Error` declares `AssertionError`.
`Throwable.toString()` is `javaToString`, `ClassUtils.getShortName` is `simpleTypeName`, and
`new ModelAndView(viewName, modelName, modelObject)` is `new ModelAndView(viewName).addObject(...)`. The test lives
with flint.mock.web in flint:framework-test. Cases that need unported classes or behave differently are gated by
version.
+/
module flint.web.exception_handler_exception_resolver_tests;

import flint.core.annotation : Order;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : MethodDescriptor, findAnnotation, mergedAnnotations;
import flint.engine.aot.mapping : AotHandlerMapping = HandlerMapping, ExceptionHandlerSpec;
import flint.engine.aot.name : simpleTypeName, typeNameOf;
import flint.http : HttpStatus;
import flint.http.converter : ByteArrayHttpMessageConverter, HttpMessageConverter, StringHttpMessageConverter;
import flint.java.io : IOException, Writer;
import flint.java.lang : AssertionError, IllegalArgumentException, IllegalStateException,
    IndexOutOfBoundsException, NullPointerException, classOf, javaToString;
import flint.jakarta.servlet : ServletException;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.stereotype : Controller;
import flint.test.web.servlet.setup : StaticBeanFactory, beanNameOf;
import flint.web.bind.annotation : ExceptionHandler, ResponseBody, ResponseStatus, RestControllerAdvice;
import flint.web.method : HandlerMethod;
import flint.web.servlet : ModelAndView;
import flint.web.servlet.mvc.method.annotation : ExceptionHandlerExceptionResolver, RequestMappingHandlerAdapter;
import flint.web.servlet.mvc.method.aot : exceptionHandlersOf;

@safe:

private struct Fixture
{
    ExceptionHandlerExceptionResolver resolver;
    MockHttpServletRequest request;
    MockHttpServletResponse response;
    /// The application context's advice beans, their exception-handler rows and their `@Order`.
    StaticBeanFactory beanFactory;
    ExceptionHandlerSpec[] adviceHandlers;
    int[string] adviceOrder;
}

private Fixture setup()
{
    Fixture f;
    f.beanFactory = new StaticBeanFactory();
    f.request = new MockHttpServletRequest("GET", "/");
    version (FlintWebFlashAttributes)
    {
        import flint.web.servlet : DispatcherServlet, FlashMap;

        f.request.setAttribute(DispatcherServlet.OUTPUT_FLASH_MAP_ATTRIBUTE, Any.of(new FlashMap()));
    }
    f.response = new MockHttpServletResponse();
    return f;
}

@("ExceptionHandlerExceptionResolverTests.nullHandler")
unittest
{
    auto f = setup();
    Object handler = null;
    afterPropertiesSet(f);
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handler, null);
    assert(mav is null, "Exception can be resolved only if there is a HandlerMethod");
}

// The resolver has no argument resolvers, return value handlers or ResponseBodyAdvice of its own (no
// setCustomArgumentResolvers, setArgumentResolvers, setCustomReturnValueHandlers, setReturnValueHandlers,
// setResponseBodyAdvice or their getters): it shares the RequestMappingHandlerAdapter's.
version (FlintExceptionHandlerResolverConfiguration)
{
    import flint.web.method.support : HandlerMethodArgumentResolver, HandlerMethodReturnValueHandler;
    import flint.web.servlet.mvc.method.annotation : ServletRequestMethodArgumentResolver,
        ViewNameMethodReturnValueHandler;

    @("ExceptionHandlerExceptionResolverTests.setCustomArgumentResolvers")
    unittest
    {
        import std.algorithm.searching : canFind;

        auto f = setup();
        HandlerMethodArgumentResolver argumentResolver = new ServletRequestMethodArgumentResolver();
        f.resolver.setCustomArgumentResolvers([argumentResolver]);
        afterPropertiesSet(f);

        assert(f.resolver.getArgumentResolvers().getResolvers().canFind(argumentResolver));
        assertMethodProcessorCount(f, defaultResolverCount() + 1, defaultHandlerCount());
    }

    @("ExceptionHandlerExceptionResolverTests.setArgumentResolvers")
    unittest
    {
        auto f = setup();
        HandlerMethodArgumentResolver argumentResolver = new ServletRequestMethodArgumentResolver();
        f.resolver.setArgumentResolvers([argumentResolver]);
        afterPropertiesSet(f);

        assertMethodProcessorCount(f, 1, defaultHandlerCount());
    }

    @("ExceptionHandlerExceptionResolverTests.setCustomReturnValueHandlers")
    unittest
    {
        import std.algorithm.searching : canFind;

        auto f = setup();
        HandlerMethodReturnValueHandler handler = new ViewNameMethodReturnValueHandler();
        f.resolver.setCustomReturnValueHandlers([handler]);
        afterPropertiesSet(f);

        assert(f.resolver.getReturnValueHandlers().getHandlers().canFind(handler));
        assertMethodProcessorCount(f, defaultResolverCount(), defaultHandlerCount() + 1);
    }

    @("ExceptionHandlerExceptionResolverTests.setResponseBodyAdvice")
    unittest
    {
        import flint.web.servlet.mvc.method.annotation : JsonViewResponseBodyAdvice;

        auto f = setup();
        f.resolver.setResponseBodyAdvice([new JsonViewResponseBodyAdvice()]);
        assert(f.resolver.getResponseBodyAdvice().length == 1);
        f.resolver.setResponseBodyAdvice([new CustomResponseBodyAdvice()]);
        assert(f.resolver.getResponseBodyAdvice().length == 2);
    }

    @("ExceptionHandlerExceptionResolverTests.setReturnValueHandlers")
    unittest
    {
        import flint.web.method.annotation : ModelMethodProcessor;

        auto f = setup();
        HandlerMethodReturnValueHandler handler = new ModelMethodProcessor();
        f.resolver.setReturnValueHandlers([handler]);
        afterPropertiesSet(f);

        assertMethodProcessorCount(f, defaultResolverCount(), 1);
    }

    /// `@BeforeAll setupOnce`: the default resolver's argument resolver count.
    private size_t defaultResolverCount()
    {
        auto f = setup();
        afterPropertiesSet(f);
        return f.resolver.getArgumentResolvers().getResolvers().length;
    }

    /// `@BeforeAll setupOnce`: the default resolver's return value handler count.
    private size_t defaultHandlerCount()
    {
        auto f = setup();
        afterPropertiesSet(f);
        return f.resolver.getReturnValueHandlers().getHandlers().length;
    }

    private void assertMethodProcessorCount(ref Fixture f, size_t resolverCount, size_t handlerCount)
    {
        assert(f.resolver.getArgumentResolvers().getResolvers().length == resolverCount);
        assert(f.resolver.getReturnValueHandlers().getHandlers().length == handlerCount);
    }

    private class CustomResponseBodyAdvice : ResponseBodyAdvice
    {
        import flint.core : MethodParameter;
        import flint.http : MediaType;
        import flint.http.server : ServerHttpRequest, ServerHttpResponse;
        import flint.web.servlet.mvc.method.annotation : ResponseBodyAdvice;

        bool supports(MethodParameter returnType, string converterType)
        {
            return false;
        }

        Any beforeBodyWrite(Any body_, MethodParameter returnType, MediaType selectedContentType,
                string selectedConverterType, ServerHttpRequest request, ServerHttpResponse response)
        {
            return Any.init;
        }
    }
}

@("ExceptionHandlerExceptionResolverTests.resolveNoExceptionHandlerForException")
unittest
{
    auto f = setup();
    Exception npe = new NullPointerException();
    HandlerMethod handlerMethod = handlerMethodOf(new IOExceptionController(), "handle");
    afterPropertiesSet(f);
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, npe);

    assert(mav is null, "NPE should not have been handled");
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionModelAndView")
unittest
{
    auto f = setup();
    auto ex = new IllegalArgumentException("Bad argument");
    HandlerMethod handlerMethod = handlerMethodOf(new ModelAndViewController(), "handle");
    afterPropertiesSet(f);
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

    assert(mav !is null);
    assert(!mav.isEmpty());
    assert(mav.getViewName() == "errorView");
    assert(mav.getModel().get("detail").get!string == "Bad argument");
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionResponseBody")
unittest
{
    auto f = setup();
    auto ex = new IllegalArgumentException();
    HandlerMethod handlerMethod = handlerMethodOf(new ResponseBodyController(), "handle");
    afterPropertiesSet(f);
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

    assertExceptionHandledAsBody(f, mav, "IllegalArgumentException");
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionResponseBodyMatchingCauseLevel2")
unittest
{
    auto f = setup();
    Exception ex = exceptionWithCause(exceptionWithCause(new IllegalArgumentException()));
    HandlerMethod handlerMethod = handlerMethodOf(new ResponseBodyController(), "handle");
    afterPropertiesSet(f);
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

    assertExceptionHandledAsBody(f, mav, "IllegalArgumentException");
}

// ServletResponseMethodArgumentResolver does not resolve a `Writer` (or `OutputStream`) parameter.
version (FlintWebResponseWriterArgument)
{
    @("ExceptionHandlerExceptionResolverTests.resolveExceptionResponseWriter")
    unittest
    {
        auto f = setup();
        auto ex = new IllegalArgumentException();
        HandlerMethod handlerMethod = handlerMethodOf(new ResponseWriterController(), "handle");
        afterPropertiesSet(f);
        ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

        assertExceptionHandledAsBody(f, mav, "IllegalArgumentException");
    }
}

// `Model` parameters (ModelMethodProcessor) and `ModelAndView.getModelMap()` are not ported.
version (FlintWebModelArgument)
{
    import flint.ui : Model;

    @("ExceptionHandlerExceptionResolverTests.resolveExceptionModelAtArgument")
    unittest
    {
        auto f = setup();
        auto ex = new IllegalArgumentException();
        HandlerMethod handlerMethod = handlerMethodOf(new ModelArgumentController(), "handle");
        afterPropertiesSet(f);
        ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

        assert(mav !is null);
        assert(mav.getModelMap().size() == 1);
        assert(mav.getModelMap().get("exceptionClassName").get!string == "IllegalArgumentException");
    }

    @Controller private class ModelArgumentController
    {
        void handle()
        {
        }

        @ExceptionHandler void handleException(Exception ex, Model model)
        {
            model.addAttribute("exceptionClassName", Any.of(simpleTypeName(typeid(ex).name)));
        }
    }
}

// Flash attributes are not ported: no FlashMap, RedirectAttributes or DispatcherServlet.OUTPUT_FLASH_MAP_ATTRIBUTE.
version (FlintWebFlashAttributes)
{
    import flint.web.servlet.mvc.support : RedirectAttributes;

    @("ExceptionHandlerExceptionResolverTests.resolveRedirectAttributesAtArgument")
    unittest
    {
        import flint.web.servlet : DispatcherServlet, FlashMap;

        auto f = setup();
        auto ex = new IllegalArgumentException();
        HandlerMethod handlerMethod = handlerMethodOf(new RedirectAttributesController(), "handle");
        afterPropertiesSet(f);
        ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

        assert(mav !is null);
        assert(mav.getViewName() == "redirect:/");
        auto flashMap = cast(FlashMap) f.request.getAttribute(DispatcherServlet.OUTPUT_FLASH_MAP_ATTRIBUTE).asObject();
        assert(flashMap !is null, "output FlashMap should exist");
        assert(flashMap.get("exceptionClassName").get!string == "IllegalArgumentException");
    }

    @Controller private class RedirectAttributesController
    {
        void handle()
        {
        }

        @ExceptionHandler string handleException(Exception ex, RedirectAttributes redirectAttributes)
        {
            redirectAttributes.addFlashAttribute("exceptionClassName", Any.of(simpleTypeName(typeid(ex).name)));
            return "redirect:/";
        }
    }
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionGlobalHandler")
unittest
{
    auto f = setup();
    loadConfiguration!MyConfig(f);

    auto ex = new IllegalAccessException();
    HandlerMethod handlerMethod = handlerMethodOf(new ResponseBodyController(), "handle");
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

    assertExceptionHandledAsBody(f, mav, "AnotherTestExceptionResolver: IllegalAccessException");
}

// Functional endpoints (HandlerFunction, ServerResponse) are not ported, and the resolver applies only to
// HandlerMethod handlers.
version (FlintWebMvcFunctional)
{
    @("ExceptionHandlerExceptionResolverTests.resolveExceptionGlobalHandlerForHandlerFunction")
    unittest
    {
        import flint.web.servlet.function_ : HandlerFunction, ServerRequest, ServerResponse;

        auto f = setup();
        loadConfiguration!MyConfig(f);

        auto ex = new IllegalAccessException();
        HandlerFunction!ServerResponse handlerFunction = (ServerRequest req) {
            throw new IllegalAccessException();
        };
        ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerFunction, ex);

        assertExceptionHandledAsBody(f, mav, "AnotherTestExceptionResolver: IllegalAccessException");
    }
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionGlobalHandlerOrdered")
unittest
{
    auto f = setup();
    loadConfiguration!MyConfig(f);

    auto ex = new IllegalStateException();
    HandlerMethod handlerMethod = handlerMethodOf(new ResponseBodyController(), "handle");
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

    assertExceptionHandledAsBody(f, mav, "TestExceptionResolver: IllegalStateException");
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionGlobalHandlerOrderedMatchingCauseLevel2")
unittest
{
    auto f = setup();
    loadConfiguration!MyConfig(f);

    Exception ex = exceptionWithCause(exceptionWithCause(new IllegalStateException()));
    HandlerMethod handlerMethod = handlerMethodOf(new ResponseBodyController(), "handle");
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

    assertExceptionHandledAsBody(f, mav, "TestExceptionResolver: IllegalStateException");
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionWithHandlerMethodArg")
unittest
{
    auto f = setup();
    loadConfiguration!MyConfig(f);

    auto ex = new ArrayIndexOutOfBoundsException();
    HandlerMethod handlerMethod = handlerMethodOf(new ResponseBodyController(), "handle");
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

    assertExceptionHandledAsBody(f, mav, "HandlerMethod: handle");
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionWithAssertionError")
unittest
{
    auto f = setup();
    loadConfiguration!MyConfig(f);

    auto err = new AssertionError("argh");
    HandlerMethod handlerMethod = handlerMethodOf(new ResponseBodyController(), "handle");
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod,
            new ServletException("Handler dispatch failed", err));

    assertExceptionHandledAsBody(f, mav, javaToString(err));
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionWithAssertionErrorAsRootCause")
unittest
{
    import flint.beans : FatalBeanException;

    auto f = setup();
    loadConfiguration!MyConfig(f);

    auto rootCause = new AssertionError("argh");
    auto cause = new FatalBeanException("wrapped", rootCause);
    Exception ex = exceptionWithCause(cause); // gh-26317
    HandlerMethod handlerMethod = handlerMethodOf(new ResponseBodyController(), "handle");
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

    assertExceptionHandledAsBody(f, mav, javaToString(rootCause));
}

// The resolver has no MessageSource (application context) to resolve an `@ResponseStatus` reason, and
// ExceptionHandlerSpec rows carry no reason.
version (FlintExceptionResolverMessageSource)
{
    @("ExceptionHandlerExceptionResolverTests.resolveExceptionWithReasonResolvedByMessageSource")
    unittest
    {
        import flint.context.i18n : LocaleContextHolder;
        import flint.context.support : StaticMessageSource;
        import flint.java.util : Locale;

        auto f = setup();
        loadConfiguration!MyConfig(f);
        auto context = new StaticMessageSource();
        Locale locale = Locale.ENGLISH;
        context.addMessage("gateway.timeout", locale, "Gateway Timeout");
        LocaleContextHolder.setLocale(locale);
        f.resolver.setMessageSource(context);

        auto ex = new SocketTimeoutException();
        HandlerMethod handlerMethod = handlerMethodOf(new ResponseBodyController(), "handle");
        ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

        assertExceptionHandledAsBody(f, mav, "");
        assert(f.response.getStatus() == HttpStatus.GATEWAY_TIMEOUT.value());
        assert(f.response.getErrorMessage() == "Gateway Timeout");
    }
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionControllerAdviceHandler")
unittest
{
    auto f = setup();
    loadConfiguration!MyControllerAdviceConfig(f);

    auto ex = new IllegalStateException();
    HandlerMethod handlerMethod = handlerMethodOf(new ResponseBodyController(), "handle");
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

    assertExceptionHandledAsBody(f, mav, "BasePackageTestExceptionResolver: IllegalStateException");
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionControllerAdviceHandlerMatchingCauseLevel2")
unittest
{
    auto f = setup();
    loadConfiguration!MyControllerAdviceConfig(f);

    Exception ex = exceptionWithCause(new IllegalStateException());
    HandlerMethod handlerMethod = handlerMethodOf(new ResponseBodyController(), "handle");
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

    assertExceptionHandledAsBody(f, mav, "BasePackageTestExceptionResolver: IllegalStateException");
}

// Spring AOP's ProxyFactory is not ported.
version (FlintAopProxyFactory)
{
    @("ExceptionHandlerExceptionResolverTests.resolveExceptionControllerAdviceAgainstProxy")
    unittest
    {
        import flint.aop.framework : ProxyFactory;

        auto f = setup();
        loadConfiguration!MyControllerAdviceConfig(f);

        auto ex = new IllegalStateException();
        HandlerMethod handlerMethod = handlerMethodOf(cast(ResponseBodyController) new ProxyFactory(
                new ResponseBodyController()).getProxy(), "handle");
        ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

        assertExceptionHandledAsBody(f, mav, "BasePackageTestExceptionResolver: IllegalStateException");
    }
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionControllerAdviceNoHandler")
unittest
{
    auto f = setup();
    loadConfiguration!MyControllerAdviceConfig(f);

    auto ex = new IllegalStateException();
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, null, ex);

    assertExceptionHandledAsBody(f, mav, "DefaultTestExceptionResolver: IllegalStateException");
}

// ExceptionHandlerExceptionResolver.shouldApplyTo's default for ResourceHttpRequestHandler (as for the
// HandlerFunction above): global handlers apply to it, so a NoResourceFoundException reaches the advice.
@("Flint: global exception handlers apply to ResourceHttpRequestHandler, and only global ones")
unittest
{
    import flint.web.servlet.resource : ResourceHttpRequestHandler;

    auto f = setup();
    afterPropertiesSet(f);
    auto handler = new ResourceHttpRequestHandler();
    assert(f.resolver.resolveException(f.request, f.response, handler, new IllegalStateException()) is null);

    f = setup();
    loadConfiguration!MyControllerAdviceConfig(f);
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handler, new IllegalStateException());
    assertExceptionHandledAsBody(f, mav, "DefaultTestExceptionResolver: IllegalStateException");
}

// The resolver has no setMappedHandlerClasses or setMappedHandlerPredicate: it applies only to HandlerMethod
// handlers (or none).
version (FlintExceptionResolverMappedHandlers)
{
    @("ExceptionHandlerExceptionResolverTests.resolveExceptionViaMappedHandler")
    unittest
    {
        import flint.web.servlet.resource : HttpRequestHandler, ResourceHttpRequestHandler;

        auto f = setup();
        f.resolver.setMappedHandlerClasses(typeNameOf!HttpRequestHandler);
        loadConfiguration!MyControllerAdviceConfig(f);

        auto ex = new IllegalStateException();
        auto handler = new ResourceHttpRequestHandler();
        ModelAndView mav = f.resolver.resolveException(f.request, f.response, handler, ex);

        assertExceptionHandledAsBody(f, mav, "DefaultTestExceptionResolver: IllegalStateException");
    }

    @("ExceptionHandlerExceptionResolverTests.resolveExceptionViaMappedHandlerPredicate")
    unittest
    {
        Object handler = new Object();

        auto f = setup();
        f.resolver.setMappedHandlerPredicate((Object h) => h is handler);
        loadConfiguration!MyControllerAdviceConfig(f);

        ModelAndView mav = f.resolver.resolveException(f.request, f.response, handler, new IllegalStateException());

        assertExceptionHandledAsBody(f, mav, "DefaultTestExceptionResolver: IllegalStateException");
    }
}

// AsyncRequestNotUsableException is not ported.
version (FlintAsyncRequestNotUsable)
{
    @("ExceptionHandlerExceptionResolverTests.resolveExceptionAsyncRequestNotUsable")
    unittest
    {
        import flint.jakarta.servlet : ServletOutputStream;
        import flint.jakarta.servlet.http : HttpServletResponse;
        import flint.web.context.request.async : AsyncRequestNotUsableException;

        auto f = setup();
        HttpServletResponse response = new class MockHttpServletResponse
        {
            override ServletOutputStream getOutputStream()
            {
                throw new AsyncRequestNotUsableException("Simulated I/O failure");
            }
        };

        auto ex = new IllegalArgumentException();
        HandlerMethod handlerMethod = handlerMethodOf(new ResponseBodyController(), "handle");
        afterPropertiesSet(f);
        ModelAndView mav = f.resolver.resolveException(f.request, response, handlerMethod, ex);

        assert(mav !is null);
        assert(mav.isEmpty());
    }
}

@("ExceptionHandlerExceptionResolverTests.resolveExceptionJsonMediaType")
unittest
{
    auto f = setup();
    auto ex = new IllegalArgumentException();
    HandlerMethod handlerMethod = handlerMethodOf(new MediaTypeController(), "handle");
    afterPropertiesSet(f);
    f.request.addHeader("Accept", "application/json");
    ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

    assertExceptionHandledAsBody(f, mav, "jsonBody");
}

// The resolver ignores `@ExceptionHandler(produces)`: it picks the first handler for the exception type whatever
// the request accepts.
version (FlintExceptionHandlerMediaTypes)
{
    @("ExceptionHandlerExceptionResolverTests.resolveExceptionHtmlMediaType")
    unittest
    {
        auto f = setup();
        auto ex = new IllegalArgumentException();
        HandlerMethod handlerMethod = handlerMethodOf(new MediaTypeController(), "handle");
        afterPropertiesSet(f);
        f.request.addHeader("Accept", "text/html");
        ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

        assert(mav !is null);
        assert(mav.getViewName() == "htmlView");
    }

    @("ExceptionHandlerExceptionResolverTests.resolveExceptionDefaultMediaType")
    unittest
    {
        auto f = setup();
        auto ex = new IllegalArgumentException();
        HandlerMethod handlerMethod = handlerMethodOf(new MediaTypeController(), "handle");
        afterPropertiesSet(f);
        f.request.addHeader("Accept", "*/*");
        ModelAndView mav = f.resolver.resolveException(f.request, f.response, handlerMethod, ex);

        assert(mav !is null);
        assert(mav.getViewName() == "htmlView");
    }
}

private void assertExceptionHandledAsBody(ref Fixture f, ModelAndView mav, string expectedBody)
{
    assert(mav !is null, "Exception was not handled");
    assert(mav.isEmpty());
    assert(f.response.getContentAsString() == expectedBody);
}

/// `resolver.afterPropertiesSet()`: the resolver over Flint AOT's exception-handler table (the test's controllers
/// and the loaded advice), with the advice beans and their order.
private void afterPropertiesSet(ref Fixture f)
{
    auto adapter = new RequestMappingHandlerAdapter(
            [
        cast(HttpMessageConverter) new ByteArrayHttpMessageConverter(),
        new StringHttpMessageConverter()
    ]);
    f.resolver = new ExceptionHandlerExceptionResolver(controllerHandlers() ~ f.adviceHandlers,
            f.beanFactory, adapter, f.adviceOrder);
}

/// `loadConfiguration(configClass)`: registers the advice beans the configuration declares, then
/// `afterPropertiesSet()`.
private void loadConfiguration(Config...)(ref Fixture f)
{
    static foreach (A; Config)
    {
        f.beanFactory.addBean(beanNameOf!A, new A());
        f.adviceHandlers ~= exceptionHandlersOf!A(beanNameOf!A);
        f.adviceOrder[beanNameOf!A] = orderOf!A();
    }
    afterPropertiesSet(f);
}

/// The `@Order` of advice class `A`.
private int orderOf(A)()
{
    if (auto order = findAnnotation(mergedAnnotations!(__traits(getAttributes, A))(), typeNameOf!Order))
        return order.value.get!Order.value;
    return int.max;
}

/// Flint AOT's exception-handler rows for the test's controllers.
private ExceptionHandlerSpec[] controllerHandlers()
{
    import std.meta : AliasSeq;

    ExceptionHandlerSpec[] rows;
    static foreach (C; AliasSeq!(ModelAndViewController, ResponseWriterController,
            ResponseBodyController, IOExceptionController, MediaTypeController))
        rows ~= exceptionHandlersOf!C(beanNameOf!C);
    version (FlintWebModelArgument)
        rows ~= exceptionHandlersOf!ModelArgumentController(beanNameOf!ModelArgumentController);
    version (FlintWebFlashAttributes)
        rows ~= exceptionHandlersOf!RedirectAttributesController(beanNameOf!RedirectAttributesController);
    return rows;
}

/// `new HandlerMethod(bean, methodName)`: the `HandlerMapping` row Flint AOT writes for the `void` method.
private HandlerMethod handlerMethodOf(C)(C bean, string methodName)
{
    AotHandlerMapping row;
    row.bean = beanNameOf!C;
    row.beanType = typeNameOf!C;
    row.typeAnnotations = mergedAnnotations!(__traits(getAttributes, C))();
    auto method = new MethodDescriptor;
    method.name = methodName;
    method.returnType = "void";
    row.method = method;
    row.returnType = "void";
    row.source = __traits(identifier, C) ~ "." ~ methodName;
    return new HandlerMethod(bean, row.beanType, row);
}

/// Java's `new Exception(cause)`.
private Exception exceptionWithCause(Throwable cause)
{
    return new Exception(javaToString(cause), cause);
}

/// `ClassUtils.getShortName(ex.getClass())`.
private string shortName(const Throwable ex)
{
    return simpleTypeName(typeid(ex).name);
}

/// `java.lang.IllegalAccessException`.
private class IllegalAccessException : Exception
{
    this() pure nothrow @nogc
    {
        super(null);
    }
}

/// `java.lang.ArrayIndexOutOfBoundsException`.
private class ArrayIndexOutOfBoundsException : IndexOutOfBoundsException
{
    this() pure nothrow
    {
        super();
    }
}

/// `java.net.SocketTimeoutException`.
private class SocketTimeoutException : IOException
{
    this() pure nothrow
    {
        super();
    }
}

/// `org.springframework.web.context.support.WebApplicationObjectSupport`, which is not ported.
private abstract class WebApplicationObjectSupport
{
}

@Controller private class ModelAndViewController
{
    void handle()
    {
    }

    @ExceptionHandler ModelAndView handle(Exception ex)
    {
        return new ModelAndView("errorView").addObject("detail", Any.of(ex.msg));
    }
}

@Controller private class ResponseWriterController
{
    void handle()
    {
    }

    @ExceptionHandler void handleException(Exception ex, Writer writer)
    {
        writer.write(shortName(ex));
    }
}

private interface ResponseBodyInterface
{
    void handle();

    @ExceptionHandler @ResponseBody string handleException(IllegalArgumentException ex);
}

@Controller private class ResponseBodyController : WebApplicationObjectSupport, ResponseBodyInterface
{
    override void handle()
    {
    }

    override @ExceptionHandler @ResponseBody string handleException(IllegalArgumentException ex)
    {
        return shortName(ex);
    }
}

@Controller private class IOExceptionController
{
    void handle()
    {
    }

    @ExceptionHandler(classOf!IOException) void handleException()
    {
    }
}

@RestControllerAdvice @Order(1) private class TestExceptionResolver
{
    @ExceptionHandler string handleException(IllegalStateException ex)
    {
        return "TestExceptionResolver: " ~ shortName(ex);
    }

    @ExceptionHandler([classOf!ArrayIndexOutOfBoundsException])
    string handleWithHandlerMethod(HandlerMethod handlerMethod)
    {
        return "HandlerMethod: " ~ handlerMethod.getMethodName();
    }

    @ExceptionHandler(classOf!AssertionError) string handleAssertionError(AssertionError err)
    {
        return javaToString(err);
    }
}

@RestControllerAdvice @Order(2) private class AnotherTestExceptionResolver
{
    @ExceptionHandler([classOf!IllegalStateException, classOf!IllegalAccessException])
    string handleException(Exception ex)
    {
        return "AnotherTestExceptionResolver: " ~ shortName(ex);
    }
}

@RestControllerAdvice @Order(3) private class ResponseStatusTestExceptionResolver
{
    @ExceptionHandler(classOf!SocketTimeoutException)
    @ResponseStatus(code : HttpStatus.GATEWAY_TIMEOUT, reason:
            "gateway.timeout")
    void handleException(SocketTimeoutException ex)
    {
    }
}

/// `MyConfig`'s `@Bean` methods: the advice beans it declares.
private alias MyConfig = imported!"std.meta".AliasSeq!(TestExceptionResolver,
        AnotherTestExceptionResolver, ResponseStatusTestExceptionResolver);

@RestControllerAdvice("java.lang") @Order(1) private class NotCalledTestExceptionResolver
{
    @ExceptionHandler string handleException(IllegalStateException ex)
    {
        return "NotCalledTestExceptionResolver: " ~ shortName(ex);
    }
}

@RestControllerAdvice(assignableTypes : [classOf!WebApplicationObjectSupport]) @Order(2)
private class BasePackageTestExceptionResolver
{
    @ExceptionHandler string handleException(IllegalStateException ex)
    {
        return "BasePackageTestExceptionResolver: " ~ shortName(ex);
    }
}

@RestControllerAdvice @Order(3) private class DefaultTestExceptionResolver
{
    @ExceptionHandler string handleException(IllegalStateException ex)
    {
        return "DefaultTestExceptionResolver: " ~ shortName(ex);
    }
}

/// `MyControllerAdviceConfig`'s `@Bean` methods: the advice beans it declares.
private alias MyControllerAdviceConfig = imported!"std.meta".AliasSeq!(NotCalledTestExceptionResolver,
        BasePackageTestExceptionResolver, DefaultTestExceptionResolver);

@Controller private class MediaTypeController
{
    void handle()
    {
    }

    @ExceptionHandler(exception : [classOf!IllegalArgumentException], produces:
            ["application/json"]) @ResponseBody string handleExceptionJson()
    {
        return "jsonBody";
    }

    @ExceptionHandler(exception : [classOf!IllegalArgumentException], produces:
            ["text/html", "*/*"])
    string handleExceptionHtml()
    {
        return "htmlView";
    }
}
