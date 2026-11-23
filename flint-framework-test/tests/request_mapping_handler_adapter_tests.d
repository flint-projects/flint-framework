/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
RequestMappingHandlerAdapterTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; `@BeforeAll`'s
processor counts are `ProcessorCounts.of()`, and the test's fields become a `Fixture` that `setup` (`@BeforeEach`)
returns. `handlerMethod(handler, name)` (Java's `new InvocableHandlerMethod(handler, method)`) is built from the
handler row Flint AOT writes for the D method. flint.web.servlet's `RequestMappingHandlerAdapter` takes its
converters and custom resolvers through its constructor and has no application context, `afterPropertiesSet`,
`@ModelAttribute` methods, body advice, cache settings or async support yet, so every case waits behind a version
gate; the shared fixture compiles with any of them. The test lives with flint.mock.web in flint:framework-test.
+/
module flint.web.request_mapping_handler_adapter_tests;

@safe:

// The adapter fixture serves every gate below.
version (FlintWebContentGenerator) version = RequestMappingHandlerAdapterFixture;
version (FlintRedirectAttributes) version = RequestMappingHandlerAdapterFixture;
version (FlintHandlerAdapterResolverConfiguration) version = RequestMappingHandlerAdapterFixture;
version (FlintSseEmitter) version = RequestMappingHandlerAdapterFixture;
version (FlintModelAttributeMethods) version = RequestMappingHandlerAdapterFixture;
version (FlintResponseBodyAdvice) version = RequestMappingHandlerAdapterFixture;
version (FlintRequestBodyAdvice) version = RequestMappingHandlerAdapterFixture;
version (FlintAsyncWebRequest) version = RequestMappingHandlerAdapterFixture;

version (RequestMappingHandlerAdapterFixture)
{
    // flint.web first: importing flint.web.method.support (directly or through flint.web.servlet.config.annotation)
    // before it trips a forward-reference error on LinkedHashMap!(string, Any) in this compiler.
    import flint.web;
    import flint.engine.aot.any : Any;
    import flint.engine.aot.name : typeNameOf;
    import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
    import flint.web.context.support : StaticWebApplicationContext;
    import flint.web.method : HandlerMethod;
    import flint.web.method.support : InvocableHandlerMethod;
    import flint.web.servlet.mvc.method.annotation : RequestMappingHandlerAdapter;
    import flint.web.servlet.mvc.method.aot : handlerMappingOf;

    /// `@BeforeAll setupOnce()`: the default adapter's processor counts.
    private struct ProcessorCounts
    {
        size_t resolvers;
        size_t initBinderResolvers;
        size_t handlers;

        static ProcessorCounts of()
        {
            auto adapter = new RequestMappingHandlerAdapter();
            adapter.setApplicationContext(new StaticWebApplicationContext());
            adapter.afterPropertiesSet();

            ProcessorCounts counts;
            counts.resolvers = adapter.getArgumentResolvers().length;
            counts.initBinderResolvers = adapter.getInitBinderArgumentResolvers().length;
            counts.handlers = adapter.getReturnValueHandlers().length;
            return counts;
        }
    }

    private struct Fixture
    {
        RequestMappingHandlerAdapter handlerAdapter;
        MockHttpServletRequest request;
        MockHttpServletResponse response;
        StaticWebApplicationContext webAppContext;
    }

    private Fixture setup()
    {
        Fixture f;
        f.webAppContext = new StaticWebApplicationContext();
        f.handlerAdapter = new RequestMappingHandlerAdapter();
        f.handlerAdapter.setApplicationContext(f.webAppContext);
        f.request = new MockHttpServletRequest("GET", "/");
        f.response = new MockHttpServletResponse();
        return f;
    }

    /// `new InvocableHandlerMethod(handler, C.class.getDeclaredMethod(methodName, paramTypes))`.
    private HandlerMethod handlerMethod(C)(C handler, string methodName)
    {
        return new InvocableHandlerMethod(new HandlerMethod(handler, typeNameOf!C,
                handlerMappingOf!C("handler", methodName)));
    }

    private void assertMethodProcessorCount(Fixture f, size_t resolverCount,
            size_t initBinderResolverCount, size_t handlerCount)
    {
        assert(f.handlerAdapter.getArgumentResolvers().length == resolverCount);
        assert(f.handlerAdapter.getInitBinderArgumentResolvers().length == initBinderResolverCount);
        assert(f.handlerAdapter.getReturnValueHandlers().length == handlerCount);
    }

    private class TestController
    {
        import flint.http : HttpStatus, ResponseEntity;
        import flint.java.io : OutputStream;
        import flint.java.util : Map;
        import flint.ui : Model;
        import flint.web.bind.annotation : ModelAttribute, RequestBody, ResponseBody;

        @ModelAttribute void addAttributes(Model model)
        {
            model.addAttribute("attr1", Any.of("lAttr1"));
        }

        string handle()
        {
            return null;
        }

        ResponseEntity handleWithResponseEntity()
        {
            return ResponseEntity.of(["foo": "bar"], HttpStatus.OK);
        }

        ResponseEntity handleBadRequest()
        {
            return ResponseEntity.of("body", HttpStatus.BAD_REQUEST);
        }

        @ResponseBody string handleBody(@RequestBody(false) Map!(string, string) body_)
        {
            return "Body: " ~ (body_ is null ? "null" : body_.toString());
        }

        void handleOutputStream(OutputStream outputStream)
        {
            outputStream.write(cast(const(ubyte)[]) "body");
        }
    }
}

// The adapter has no WebContentGenerator cache settings (setCacheSeconds), nor @SessionAttributes.
version (FlintWebContentGenerator)
{
    import flint.web.bind.annotation : SessionAttributes;
    import std.algorithm.searching : canFind;

    @("RequestMappingHandlerAdapterTests.cacheControlWithoutSessionAttributes")
    unittest
    {
        auto f = setup();
        auto handlerMethod = handlerMethod(new TestController(), "handle");
        f.handlerAdapter.setCacheSeconds(100);
        f.handlerAdapter.afterPropertiesSet();

        f.handlerAdapter.handle(f.request, f.response, handlerMethod);
        assert(f.response.getHeader("Cache-Control").canFind("max-age"));
    }

    @("RequestMappingHandlerAdapterTests.cacheControlWithSessionAttributes")
    unittest
    {
        auto f = setup();
        auto handler = new SessionAttributeController();
        f.handlerAdapter.setCacheSeconds(100);
        f.handlerAdapter.afterPropertiesSet();

        f.handlerAdapter.handle(f.request, f.response, handlerMethod(handler, "handle"));
        assert(f.response.getHeader("Cache-Control") == "no-store");
    }

    @SessionAttributes("attr1")
    private class SessionAttributeController
    {
        void handle()
        {
        }
    }
}

// flint.web has no RedirectAttributes or Model argument resolvers (RedirectAttributesMethodArgumentResolver,
// ModelMethodProcessor), nor FlashMap.
version (FlintRedirectAttributes)
{
    @("RequestMappingHandlerAdapterTests.setAlwaysUseRedirectAttributes")
    unittest
    {
        import flint.web.method.annotation : ModelMethodProcessor;
        import flint.web.method.support : HandlerMethodArgumentResolver, HandlerMethodReturnValueHandler;
        import flint.web.servlet : DispatcherServlet, FlashMap;
        import flint.web.servlet.mvc.method.annotation : RedirectAttributesMethodArgumentResolver,
            ViewNameMethodReturnValueHandler;

        auto f = setup();
        HandlerMethodArgumentResolver redirectAttributesResolver = new RedirectAttributesMethodArgumentResolver();
        HandlerMethodArgumentResolver modelResolver = new ModelMethodProcessor();
        HandlerMethodReturnValueHandler viewHandler = new ViewNameMethodReturnValueHandler();

        f.handlerAdapter.setArgumentResolvers([redirectAttributesResolver, modelResolver]);
        f.handlerAdapter.setReturnValueHandlers([viewHandler]);
        f.handlerAdapter.afterPropertiesSet();

        f.request.setAttribute(DispatcherServlet.OUTPUT_FLASH_MAP_ATTRIBUTE, Any.of(new FlashMap()));

        auto handlerMethod = handlerMethod(new RedirectAttributeController(), "handle");
        auto mav = f.handlerAdapter.handle(f.request, f.response, handlerMethod);

        assert(mav.getModel().isEmpty(), "Without RedirectAttributes arg, model should be empty");
    }

    private class RedirectAttributeController
    {
        import flint.ui : Model;

        string handle(Model model)
        {
            model.addAttribute("someAttr", Any.of("someAttrValue"));
            return "redirect:/path";
        }
    }
}

// The adapter takes custom resolvers and handlers only through its constructor: it has no
// set(Custom)ArgumentResolvers/ReturnValueHandlers setters, no afterPropertiesSet and no init-binder resolvers.
version (FlintHandlerAdapterResolverConfiguration)
{
    import flint.web.method.support : HandlerMethodArgumentResolver, HandlerMethodReturnValueHandler;
    import flint.web.servlet.mvc.method.annotation : ServletRequestMethodArgumentResolver,
        ViewNameMethodReturnValueHandler;
    import std.algorithm.searching : canFind;

    @("RequestMappingHandlerAdapterTests.setCustomArgumentResolvers")
    unittest
    {
        const counts = ProcessorCounts.of();
        auto f = setup();
        HandlerMethodArgumentResolver resolver = new ServletRequestMethodArgumentResolver();
        f.handlerAdapter.setCustomArgumentResolvers([resolver]);
        f.handlerAdapter.afterPropertiesSet();

        assert(f.handlerAdapter.getArgumentResolvers().canFind(resolver));
        assertMethodProcessorCount(f, counts.resolvers + 1, counts.initBinderResolvers + 1, counts.handlers);
    }

    @("RequestMappingHandlerAdapterTests.setArgumentResolvers")
    unittest
    {
        const counts = ProcessorCounts.of();
        auto f = setup();
        HandlerMethodArgumentResolver resolver = new ServletRequestMethodArgumentResolver();
        f.handlerAdapter.setArgumentResolvers([resolver]);
        f.handlerAdapter.afterPropertiesSet();

        assertMethodProcessorCount(f, 1, counts.initBinderResolvers, counts.handlers);
    }

    @("RequestMappingHandlerAdapterTests.setInitBinderArgumentResolvers")
    unittest
    {
        const counts = ProcessorCounts.of();
        auto f = setup();
        HandlerMethodArgumentResolver resolver = new ServletRequestMethodArgumentResolver();
        f.handlerAdapter.setInitBinderArgumentResolvers([resolver]);
        f.handlerAdapter.afterPropertiesSet();

        assertMethodProcessorCount(f, counts.resolvers, 1, counts.handlers);
    }

    @("RequestMappingHandlerAdapterTests.setCustomReturnValueHandlers")
    unittest
    {
        const counts = ProcessorCounts.of();
        auto f = setup();
        HandlerMethodReturnValueHandler handler = new ViewNameMethodReturnValueHandler();
        f.handlerAdapter.setCustomReturnValueHandlers([handler]);
        f.handlerAdapter.afterPropertiesSet();

        assert(f.handlerAdapter.getReturnValueHandlers().canFind(handler));
        assertMethodProcessorCount(f, counts.resolvers, counts.initBinderResolvers, counts.handlers + 1);
    }

    @("RequestMappingHandlerAdapterTests.setReturnValueHandlers")
    unittest
    {
        import flint.web.method.annotation : ModelMethodProcessor;

        const counts = ProcessorCounts.of();
        auto f = setup();
        HandlerMethodReturnValueHandler handler = new ModelMethodProcessor();
        f.handlerAdapter.setReturnValueHandlers([handler]);
        f.handlerAdapter.afterPropertiesSet();

        assertMethodProcessorCount(f, counts.resolvers, counts.initBinderResolvers, 1);
    }
}

// flint.web has no SseEmitter (ResponseBodyEmitter return values) nor async request support.
version (FlintSseEmitter)
{
    // gh-35153
    @("RequestMappingHandlerAdapterTests.responseEntityWithWildCardAndConditionalStream")
    unittest
    {
        auto f = setup();
        auto handlerMethod = handlerMethod(new SseController(), "handle");
        f.handlerAdapter.afterPropertiesSet();

        f.request.setAsyncSupported(true);
        f.request.addParameter("q", "sse");

        f.handlerAdapter.handle(f.request, f.response, handlerMethod);

        assert(f.response.getStatus() == 200);
        assert(f.response.getHeader("Content-Type") == "text/event-stream");
        assert(f.response.getContentAsString() == "data: event 1\n\ndata: event 2\n\n");
    }

    private class SseController
    {
        import flint.http : ResponseEntity;
        import flint.web.bind.annotation : RequestParam;
        import flint.web.servlet.mvc.method.annotation : SseEmitter;

        ResponseEntity handle(@RequestParam string q)
        {
            if (q == "sse")
            {
                auto emitter = new SseEmitter();
                emitter.send(Any.of("event 1"));
                emitter.send(Any.of("event 2"));
                emitter.complete();
                return ResponseEntity.ok().body(emitter);
            }
            return ResponseEntity.ok("text");
        }
    }
}

// The adapter invokes no @ModelAttribute methods (of the controller or of @ControllerAdvice beans) and has no
// application context to find advice in; flint.web has no Model.
version (FlintModelAttributeMethods)
{
    import flint.ui : Model;
    import flint.web.bind.annotation : ControllerAdvice, ModelAttribute;

    @("RequestMappingHandlerAdapterTests.modelAttributeAdvice")
    unittest
    {
        auto f = setup();
        f.webAppContext.registerSingleton!ModelAttributeAdvice("maa");
        f.webAppContext.refresh();

        auto handlerMethod = handlerMethod(new TestController(), "handle");
        f.handlerAdapter.afterPropertiesSet();
        auto mav = f.handlerAdapter.handle(f.request, f.response, handlerMethod);

        assert(mav.getModel().get("attr1") == Any.of("lAttr1"));
        assert(mav.getModel().get("attr2") == Any.of("gAttr2"));
    }

    @("RequestMappingHandlerAdapterTests.prototypeControllerAdvice")
    unittest
    {
        auto f = setup();
        f.webAppContext.registerPrototype!ModelAttributeAdvice("maa");
        f.webAppContext.refresh();

        auto handlerMethod = handlerMethod(new TestController(), "handle");
        f.handlerAdapter.afterPropertiesSet();
        auto model1 = f.handlerAdapter.handle(f.request, f.response, handlerMethod).getModel();
        auto model2 = f.handlerAdapter.handle(f.request, f.response, handlerMethod).getModel();

        assert(model1.get("instance").asObject() !is model2.get("instance").asObject());
    }

    @("RequestMappingHandlerAdapterTests.modelAttributeAdviceInParentContext")
    unittest
    {
        auto f = setup();
        auto parent = new StaticWebApplicationContext();
        parent.registerSingleton!ModelAttributeAdvice("maa");
        parent.refresh();
        f.webAppContext.setParent(parent);
        f.webAppContext.refresh();

        auto handlerMethod = handlerMethod(new TestController(), "handle");
        f.handlerAdapter.afterPropertiesSet();
        auto mav = f.handlerAdapter.handle(f.request, f.response, handlerMethod);

        assert(mav.getModel().get("attr1") == Any.of("lAttr1"));
        assert(mav.getModel().get("attr2") == Any.of("gAttr2"));
    }

    @("RequestMappingHandlerAdapterTests.modelAttributePackageNameAdvice")
    unittest
    {
        auto f = setup();
        f.webAppContext.registerSingleton!ModelAttributePackageAdvice("mapa");
        f.webAppContext.registerSingleton!ModelAttributeNotUsedPackageAdvice("manupa");
        f.webAppContext.refresh();

        auto handlerMethod = handlerMethod(new TestController(), "handle");
        f.handlerAdapter.afterPropertiesSet();
        auto mav = f.handlerAdapter.handle(f.request, f.response, handlerMethod);

        assert(mav.getModel().get("attr1") == Any.of("lAttr1"));
        assert(mav.getModel().get("attr2") == Any.of("gAttr2"));
        assert(mav.getModel().get("attr3").isNull());
    }

    @ControllerAdvice private class ModelAttributeAdvice
    {
        @ModelAttribute void addAttributes(Model model)
        {
            model.addAttribute("attr1", Any.of("gAttr1"));
            model.addAttribute("attr2", Any.of("gAttr2"));
            model.addAttribute("instance", Any.of(this));
        }
    }

    // Spring's test package and `java.lang`: this module's package, and D's `object`.
    @ControllerAdvice(["flint.web", "object"])
    private class ModelAttributePackageAdvice
    {
        @ModelAttribute void addAttributes(Model model)
        {
            model.addAttribute("attr2", Any.of("gAttr2"));
        }
    }

    @ControllerAdvice("object")
    private class ModelAttributeNotUsedPackageAdvice
    {
        @ModelAttribute void addAttributes(Model model)
        {
            model.addAttribute("attr3", Any.of("gAttr3"));
        }
    }
}

// flint.web has no ResponseBodyAdvice (nor RequestBodyAdvice), so advice cannot rewrite a body before it is
// written.
version (FlintResponseBodyAdvice)
{
    import flint.core : MethodParameter;
    import flint.http : HttpInputMessage, HttpStatus, MediaType;
    import flint.http.converter : HttpMessageConverter, StringHttpMessageConverter;
    import flint.http.converter.json : JacksonJsonHttpMessageConverter;
    import flint.http.server : ServerHttpRequest, ServerHttpResponse, ServletServerHttpResponse;
    import flint.web.bind.annotation : ControllerAdvice;
    import flint.web.servlet.mvc.method.annotation : RequestBodyAdvice, ResponseBodyAdvice;

    // gh-15486
    @("RequestMappingHandlerAdapterTests.responseBodyAdvice")
    unittest
    {
        auto f = setup();
        HttpMessageConverter[] converters;
        converters ~= new JacksonJsonHttpMessageConverter();
        f.handlerAdapter.setMessageConverters(converters);

        f.webAppContext.registerSingleton!ResponseCodeSuppressingAdvice("rba");
        f.webAppContext.refresh();

        f.request.addHeader("Accept", MediaType.APPLICATION_JSON_VALUE);
        f.request.setParameter("c", "callback");

        auto handlerMethod = handlerMethod(new TestController(), "handleBadRequest");
        f.handlerAdapter.afterPropertiesSet();
        f.handlerAdapter.handle(f.request, f.response, handlerMethod);

        assert(f.response.getStatus() == 200);
        assert(f.response.getContentAsString() == "{\"status\":400,\"message\":\"body\"}");
    }

    /++
    This class additionally implements `RequestBodyAdvice` solely for the purpose of verifying that controller
    advice implementing both `ResponseBodyAdvice` and `RequestBodyAdvice` does not get registered twice
    (gh-22638).
    +/
    @ControllerAdvice private class ResponseCodeSuppressingAdvice : ResponseBodyAdvice, RequestBodyAdvice
    {
        bool supports(MethodParameter returnType, string converterType)
        {
            return typeNameOf!JacksonJsonHttpMessageConverter == converterType;
        }

        Any beforeBodyWrite(Any body_, MethodParameter returnType, MediaType contentType,
                string converterType, ServerHttpRequest request, ServerHttpResponse response)
        {
            import flint.java.util : LinkedHashMap, Map;

            const status = (cast(ServletServerHttpResponse) response).getServletResponse().getStatus();
            response.setStatusCode(HttpStatus.OK);

            Map!(string, Any) map = new LinkedHashMap!(string, Any)();
            map.put("status", Any.of(status));
            map.put("message", body_);
            return Any.of(map);
        }

        bool supports(MethodParameter methodParameter, string targetType, string converterType)
        {
            return typeNameOf!StringHttpMessageConverter == converterType;
        }

        HttpInputMessage beforeBodyRead(HttpInputMessage inputMessage, MethodParameter parameter,
                string targetType, string converterType)
        {
            return inputMessage;
        }

        Any afterBodyRead(Any body_, HttpInputMessage inputMessage, MethodParameter parameter,
                string targetType, string converterType)
        {
            return body_;
        }

        Any handleEmptyBody(Any body_, HttpInputMessage inputMessage, MethodParameter parameter,
                string targetType, string converterType)
        {
            return Any.of("default value for empty body");
        }
    }
}

// flint.web has no RequestBodyAdvice (handleEmptyBody cannot supply a body).
version (FlintRequestBodyAdvice)
{
    import flint.core : MethodParameter;
    import flint.http : HttpInputMessage;
    import flint.java.lang : UnsupportedOperationException;
    import flint.web.bind.annotation : ControllerAdvice;
    import flint.web.servlet.mvc.method.annotation : RequestBodyAdvice;

    // gh-30522
    @("RequestMappingHandlerAdapterTests.responseBodyAdviceWithEmptyBody")
    unittest
    {
        auto f = setup();
        f.webAppContext.registerBean!EmptyBodyAdvice("rba");
        f.webAppContext.refresh();

        auto handlerMethod = handlerMethod(new TestController(), "handleBody");
        f.handlerAdapter.afterPropertiesSet();
        f.handlerAdapter.handle(f.request, f.response, handlerMethod);

        assert(f.response.getStatus() == 200);
        assert(f.response.getContentAsString() == "Body: {foo=bar}");
    }

    @ControllerAdvice private class EmptyBodyAdvice : RequestBodyAdvice
    {
        bool supports(MethodParameter param, string targetType, string type)
        {
            return true;
        }

        HttpInputMessage beforeBodyRead(HttpInputMessage message, MethodParameter param, string targetType, string type)
        {
            throw new UnsupportedOperationException();
        }

        Any afterBodyRead(Any body_, HttpInputMessage message, MethodParameter param, string targetType, string type)
        {
            throw new UnsupportedOperationException();
        }

        Any handleEmptyBody(Any body_, HttpInputMessage message, MethodParameter param, string targetType, string type)
        {
            import flint.java.util : Map;

            return Any.of(Map!(string, string).of("foo", "bar"));
        }
    }
}

// flint.web has no async request support (StandardServletAsyncWebRequest, WebAsyncManager,
// AsyncRequestNotUsableException), nor MockAsyncContext.
version (FlintAsyncWebRequest)
{
    @("RequestMappingHandlerAdapterTests.asyncRequestNotUsable")
    unittest
    {
        import flint.jakarta.servlet : AsyncEvent;
        import flint.mock.web : MockAsyncContext;
        import flint.web.context.request.async : AsyncRequestNotUsableException,
            StandardServletAsyncWebRequest, WebAsyncUtils;
        import std.exception : assertThrown;

        auto f = setup();

        // Put AsyncWebRequest in ERROR state
        auto asyncRequest = new StandardServletAsyncWebRequest(f.request, f.response);
        asyncRequest.onError(new AsyncEvent(new MockAsyncContext(f.request, f.response), new Exception("")));

        // Set it as the current AsyncWebRequest, from the initial REQUEST dispatch
        auto asyncManager = WebAsyncUtils.getAsyncManager(f.request);
        asyncManager.setAsyncWebRequest(asyncRequest);

        // AsyncWebRequest created for current dispatch should inherit state
        auto handlerMethod = handlerMethod(new TestController(), "handleOutputStream");
        f.handlerAdapter.afterPropertiesSet();

        // Use of response should be rejected
        assertThrown!AsyncRequestNotUsableException(f.handlerAdapter.handle(f.request, f.response, handlerMethod));
    }
}
