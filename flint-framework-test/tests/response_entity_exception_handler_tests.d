/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
ResponseEntityExceptionHandlerTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` returns. Reflection over `ResponseEntityExceptionHandler.handleException` and
`DefaultHandlerExceptionResolver`'s methods becomes compile-time introspection of their merged annotations and
parameters; the `handle(String)` parameter is described by its AOT `ArgumentSpec`. `ResponseEntity<Object>` is
`ResponseEntity`, and a `null` entity is an empty `Nullable!ResponseEntity`. Beans' `TypeMismatchException` is
flint.web's, with the required type by name; spring-web's `MockHttpInputMessage` test fixture is a private class;
Mockito mocks of `MethodValidationResult` are stubs; `LocaleContextHolder`'s `finally` reset is `scope (exit)`.
`StaticWebApplicationContext.registerSingleton` becomes the AOT rows of the registered classes in a
`StaticBeanFactory`. The test lives with flint.mock.web in flint:framework-test. flint.web has no
`ResponseEntityExceptionHandler`, so the whole class is gated by version.
+/
module flint.web.response_entity_exception_handler_tests;

// flint.web has not ported ResponseEntityExceptionHandler. The tests also use pieces that are not ported yet:
// ConversionNotSupportedException, MaxUploadSizeExceededException, AsyncRequestNotUsableException,
// HandlerMethodValidationException, MethodValidationException, ServerHttpObservationFilter and the ObservedExchange
// test fixture, and the DispatcherServlet over an application context.
version (FlintResponseEntityExceptionHandler)
{
    import flint.core : MethodParameter;
    import flint.engine.aot.any : Any;
    import flint.engine.aot.name : typeNameOf;
    import flint.http : HttpHeaders, HttpInputMessage, HttpMethod, HttpStatus, HttpStatusCode,
        MediaType, ProblemDetail, ResponseEntity;
    import flint.http.converter : HttpMessageNotReadableException, HttpMessageNotWritableException;
    import flint.jakarta.servlet : ServletException;
    import flint.java.io : IOException;
    import flint.java.lang : IllegalStateException;
    import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
    import flint.stereotype : Controller;
    import flint.web : ErrorResponse, ErrorResponseException, HttpMediaTypeNotAcceptableException,
        HttpMediaTypeNotSupportedException, HttpRequestMethodNotSupportedException;
    import flint.web.bind : MethodArgumentNotValidException, MissingPathVariableException,
        MissingServletRequestParameterException, ServletRequestBindingException;
    import flint.web.bind.annotation : ControllerAdvice, ExceptionHandler, RequestMapping;
    import flint.web.context.request : ServletWebRequest, WebRequest;
    import flint.web.context.request.async : AsyncRequestTimeoutException;
    import flint.web.method.annotation : TypeMismatchException;
    import flint.web.multipart.support : MissingServletRequestPartException;
    import flint.web.server : ResponseStatusException;
    import flint.web.servlet : ModelAndView, NoHandlerFoundException;
    import flint.web.servlet.mvc.method.annotation : ExceptionHandlerExceptionResolver, ResponseEntityExceptionHandler;
    import flint.web.servlet.mvc.support : DefaultHandlerExceptionResolver;
    import flint.web.servlet.resource : NoResourceFoundException;
    import std.typecons : Nullable;

@safe:

    private struct Fixture
    {
        ResponseEntityExceptionHandler exceptionHandler;
        DefaultHandlerExceptionResolver exceptionResolver;
        MockHttpServletRequest servletRequest;
        MockHttpServletResponse servletResponse;
        WebRequest request;
    }

    private Fixture setup()
    {
        Fixture f;
        f.exceptionHandler = new ApplicationExceptionHandler();
        f.exceptionResolver = new DefaultHandlerExceptionResolver();
        f.servletRequest = new MockHttpServletRequest("GET", "/");
        f.servletResponse = new MockHttpServletResponse();
        f.request = new ServletWebRequest(f.servletRequest, f.servletResponse);
        return f;
    }

    @("ResponseEntityExceptionHandlerTests.supportsAllDefaultHandlerExceptionResolverExceptionTypes")
    unittest
    {
        import flint.engine.aot.descriptor : findAnnotation, mergedAnnotations;
        import std.algorithm.searching : canFind, startsWith;
        import std.traits : Parameters;

        alias handleException = ResponseEntityExceptionHandler.handleException;
        auto annotations = mergedAnnotations!(__traits(getAttributes, handleException))();
        auto annotation = findAnnotation(annotations, typeNameOf!ExceptionHandler).value.get!ExceptionHandler;
        string[] exceptionTypes;
        foreach (type; annotation.value)
            exceptionTypes ~= type.name;

        static foreach (member; __traits(derivedMembers, DefaultHandlerExceptionResolver))
        {
            static if (member.startsWith("handle") && member != "handleErrorResponse"
                    && member != "handleDisconnectedClientException")
            {
                static foreach (method; __traits(getOverloads, DefaultHandlerExceptionResolver, member))
                {
                    static if (Parameters!method.length == 4)
                        assert(exceptionTypes.canFind(typeNameOf!(Parameters!method[0])),
                                "@ExceptionHandler is missing declaration for " ~ typeNameOf!(Parameters!method[0]));
                }
            }
        }
    }

    @("ResponseEntityExceptionHandlerTests.httpRequestMethodNotSupported")
    unittest
    {
        auto f = setup();
        ResponseEntity entity = testException(f, new HttpRequestMethodNotSupportedException("GET", [
            "POST", "DELETE"
        ]));

        assert(entity.getHeaders().getFirst(HttpHeaders.ALLOW) == "POST, DELETE");
    }

    @("ResponseEntityExceptionHandlerTests.httpMediaTypeNotSupported")
    unittest
    {
        auto f = setup();
        ResponseEntity entity = testException(f, new HttpMediaTypeNotSupportedException(MediaType.APPLICATION_JSON,
                [MediaType.APPLICATION_ATOM_XML, MediaType.APPLICATION_XML]));

        assert(entity.getHeaders().getFirst(HttpHeaders.ACCEPT) == "application/atom+xml, application/xml");
        assert(entity.getHeaders().getAcceptPatch().length == 0);
    }

    @("ResponseEntityExceptionHandlerTests.patchHttpMediaTypeNotSupported")
    unittest
    {
        import std.typecons : nullable;

        auto f = setup();
        f.servletRequest = new MockHttpServletRequest("PATCH", "/");
        f.request = new ServletWebRequest(f.servletRequest, f.servletResponse);

        MediaType[] supportedMediaTypes = [
            MediaType.APPLICATION_ATOM_XML, MediaType.APPLICATION_XML
        ];
        ResponseEntity entity = testException(f,
                new HttpMediaTypeNotSupportedException(nullable(MediaType.APPLICATION_JSON),
                    supportedMediaTypes, Nullable!HttpMethod(HttpMethod.PATCH)));

        HttpHeaders headers = entity.getHeaders();
        assert(headers.getFirst(HttpHeaders.ACCEPT) == "application/atom+xml, application/xml");
        assert(headers.getFirst(HttpHeaders.ACCEPT) == "application/atom+xml, application/xml");
        assert(headers.getFirst(HttpHeaders.ACCEPT_PATCH) == "application/atom+xml, application/xml");
    }

    @("ResponseEntityExceptionHandlerTests.queryHttpMediaTypeNotSupported")
    unittest
    {
        import std.typecons : nullable;

        auto f = setup();
        f.servletRequest = new MockHttpServletRequest("QUERY", "/");
        f.request = new ServletWebRequest(f.servletRequest, f.servletResponse);

        MediaType[] supportedMediaTypes = [
            MediaType.APPLICATION_ATOM_XML, MediaType.APPLICATION_XML
        ];
        ResponseEntity entity = testException(f,
                new HttpMediaTypeNotSupportedException(nullable(MediaType.APPLICATION_JSON),
                    supportedMediaTypes, Nullable!HttpMethod(HttpMethod.QUERY)));

        HttpHeaders headers = entity.getHeaders();
        assert(headers.getFirst(HttpHeaders.ACCEPT) == "application/atom+xml, application/xml");
        assert(headers.getFirst(HttpHeaders.ACCEPT_QUERY) == "application/atom+xml, application/xml");
    }

    @("ResponseEntityExceptionHandlerTests.httpMediaTypeNotAcceptable")
    unittest
    {
        auto f = setup();
        testException(f, new HttpMediaTypeNotAcceptableException(""));
    }

    @("ResponseEntityExceptionHandlerTests.missingPathVariable")
    unittest
    {
        auto f = setup();
        testException(f, new MissingPathVariableException("param", handleParameter()));
    }

    @("ResponseEntityExceptionHandlerTests.missingServletRequestParameter")
    unittest
    {
        auto f = setup();
        testException(f, new MissingServletRequestParameterException("param", "type"));
    }

    @("ResponseEntityExceptionHandlerTests.servletRequestBindingException")
    unittest
    {
        auto f = setup();
        testException(f, new ServletRequestBindingException("message"));
    }

    @("ResponseEntityExceptionHandlerTests.errorResponseProblemDetailViaMessageSource")
    unittest
    {
        import flint.context.i18n : LocaleContextHolder;
        import flint.context.support : StaticMessageSource;
        import flint.java.net : URI;
        import flint.java.util : Locale;

        auto f = setup();
        scope (exit)
            LocaleContextHolder.resetLocaleContext();
        Locale locale = Locale.UK;
        LocaleContextHolder.setLocale(locale);

        const type = "https://example.com/probs/unsupported-content";
        const title = "Media type is not valid or not supported";
        const exceptionType = typeid(HttpMediaTypeNotSupportedException);

        auto source = new StaticMessageSource();
        source.addMessage(ErrorResponse.getDefaultTypeMessageCode(exceptionType), locale, type);
        source.addMessage(ErrorResponse.getDefaultTitleMessageCode(exceptionType), locale, title);
        source.addMessage(ErrorResponse.getDefaultDetailMessageCode(exceptionType, null), locale,
                "Content-Type {0} not supported. Supported: {1}");

        f.exceptionHandler.setMessageSource(source);

        ResponseEntity entity = testException(f, new HttpMediaTypeNotSupportedException(MediaType.APPLICATION_JSON,
                [MediaType.APPLICATION_ATOM_XML, MediaType.APPLICATION_XML]));

        auto problem = cast(ProblemDetail) entity.getBody().asObject();
        assert(problem !is null);
        assert(problem.getType() == URI.create(type));
        assert(problem.getTitle() == title);
        assert(problem.getDetail() == "Content-Type application/json not supported. "
                ~ "Supported: [application/atom+xml, application/xml]");
    }

    @("ResponseEntityExceptionHandlerTests.reasonAsDetailShouldBeUpdatedViaMessageSource")
    unittest
    {
        import flint.context.i18n : LocaleContextHolder;
        import flint.context.support : StaticMessageSource;
        import flint.java.util : Locale;

        auto f = setup();
        Locale locale = Locale.UK;
        LocaleContextHolder.setLocale(locale);

        const reason = "bad.request";
        const message = "Breaking Bad Request";
        scope (exit)
            LocaleContextHolder.resetLocaleContext();
        auto messageSource = new StaticMessageSource();
        messageSource.addMessage(reason, locale, message);

        f.exceptionHandler.setMessageSource(messageSource);

        ResponseEntity entity = testException(f, new ResponseStatusException(HttpStatus.BAD_REQUEST, reason));

        auto body_ = cast(ProblemDetail) entity.getBody().asObject();
        assert(body_.getDetail() == message);
    }

    @("ResponseEntityExceptionHandlerTests.conversionNotSupported")
    unittest
    {
        import flint.beans : ConversionNotSupportedException;

        auto f = setup();
        testException(f, new ConversionNotSupportedException(Any.of(new Object()), "object.Object", null));
    }

    @("ResponseEntityExceptionHandlerTests.typeMismatch")
    unittest
    {
        auto f = setup();
        testException(f, new TypeMismatchException(Any.of("foo"), "string", null));
    }

    @("ResponseEntityExceptionHandlerTests.typeMismatchWithProblemDetailViaMessageSource")
    unittest
    {
        import flint.beans : PropertyChangeEvent;
        import flint.context.i18n : LocaleContextHolder;
        import flint.context.support : StaticMessageSource;
        import flint.java.util : Locale;

        auto f = setup();
        Locale locale = Locale.UK;
        LocaleContextHolder.setLocale(locale);

        scope (exit)
            LocaleContextHolder.resetLocaleContext();
        auto messageSource = new StaticMessageSource();
        messageSource.addMessage(ErrorResponse.getDefaultDetailMessageCode(typeid(TypeMismatchException),
                null), locale, "Failed to set {0} to value: {1} for type {2}");

        f.exceptionHandler.setMessageSource(messageSource);

        ResponseEntity entity = testException(f, new TypeMismatchException(new PropertyChangeEvent(new Object(),
                "name", Any.of("John"), Any.of("James")), "string"));

        auto body_ = cast(ProblemDetail) entity.getBody().asObject();
        assert(body_.getDetail() == "Failed to set name to value: James for type String");
    }

    @("ResponseEntityExceptionHandlerTests.httpMessageNotReadable")
    unittest
    {
        auto f = setup();
        testException(f, new HttpMessageNotReadableException("message", null, new MockHttpInputMessage(new ubyte[0])));
    }

    @("ResponseEntityExceptionHandlerTests.httpMessageNotWritable")
    unittest
    {
        auto f = setup();
        testException(f, new HttpMessageNotWritableException(""));
    }

    @("ResponseEntityExceptionHandlerTests.methodArgumentNotValid")
    unittest
    {
        import flint.java.util : Map;
        import flint.validation : MapBindingResult;

        auto f = setup();
        testException(f, new MethodArgumentNotValidException(handleParameter(),
                new MapBindingResult(Map!(string, Any).of(), "name")));
    }

    @("ResponseEntityExceptionHandlerTests.handlerMethodValidationException")
    unittest
    {
        import flint.web.method.annotation : HandlerMethodValidationException;

        auto f = setup();
        testException(f, new HandlerMethodValidationException(new MethodValidationResultStub()));
    }

    @("ResponseEntityExceptionHandlerTests.methodValidationException")
    unittest
    {
        import flint.validation.method : MethodValidationException;

        auto f = setup();
        testException(f, new MethodValidationException(new MethodValidationResultStub()));
    }

    @("ResponseEntityExceptionHandlerTests.missingServletRequestPart")
    unittest
    {
        auto f = setup();
        testException(f, new MissingServletRequestPartException("partName"));
    }

    @("ResponseEntityExceptionHandlerTests.noHandlerFoundException")
    unittest
    {
        auto f = setup();
        HttpHeaders requestHeaders = HttpHeaders.create();
        requestHeaders.setContentType(MediaType.APPLICATION_FORM_URLENCODED); // gh-29626

        ResponseEntity responseEntity = testException(f, new NoHandlerFoundException("GET",
                "/resource", requestHeaders));

        assert(responseEntity.getHeaders().isEmpty());
    }

    @("ResponseEntityExceptionHandlerTests.noResourceFoundException")
    unittest
    {
        auto f = setup();
        testException(f, new NoResourceFoundException(HttpMethod.GET, "/context/resource", "/resource"));
    }

    @("ResponseEntityExceptionHandlerTests.asyncRequestTimeoutException")
    unittest
    {
        auto f = setup();
        testException(f, new AsyncRequestTimeoutException());
    }

    @("ResponseEntityExceptionHandlerTests.asyncRequestNotUsableException")
    unittest
    {
        import flint.web.context.request.async : AsyncRequestNotUsableException;

        auto f = setup();
        auto ex = new AsyncRequestNotUsableException("simulated failure");
        Nullable!ResponseEntity entity = f.exceptionHandler.handleException(ex, f.request);
        assert(entity.isNull);
    }

    @("ResponseEntityExceptionHandlerTests.serverErrorIsRecordedOnObservation")
    unittest
    {
        auto f = setup();
        auto ex = new HttpMessageNotWritableException("simulated failure");

        auto exchange = observe(f, ex);
        assert(exchange.result().getStatusCode() == HttpStatus.INTERNAL_SERVER_ERROR);
        assert(exchange.error() is ex);
    }

    @("ResponseEntityExceptionHandlerTests.serverErrorResponseIsRecordedOnObservation")
    unittest
    {
        auto f = setup();
        auto ex = new ErrorResponseException(HttpStatus.SERVICE_UNAVAILABLE);

        assert(observe(f, ex).error() is ex);
    }

    @("ResponseEntityExceptionHandlerTests.clientErrorIsNotRecordedOnObservation")
    unittest
    {
        auto f = setup();

        assert(observe(f, new TypeMismatchException(Any.of("foo"), "string", null)).error() is null);
    }

    @("ResponseEntityExceptionHandlerTests.clientErrorResponseIsNotRecordedOnObservation")
    unittest
    {
        auto f = setup();

        assert(observe(f, new ErrorResponseException(HttpStatus.CONFLICT)).error() is null);
    }

    @("ResponseEntityExceptionHandlerTests.asyncRequestNotUsableIsNotRecordedOnObservation")
    unittest
    {
        import flint.web.context.request.async : AsyncRequestNotUsableException;
        import flint.web.servlet.mvc : ObservedExchange;

        auto f = setup();
        auto ex = new AsyncRequestNotUsableException("simulated failure");

        auto exchange = ObservedExchange!(Nullable!ResponseEntity).observe(f.servletRequest,
                f.servletResponse, () => f.exceptionHandler.handleException(ex, f.request));
        assert(exchange.result().isNull);
        assert(exchange.error() is null);
    }

    @("ResponseEntityExceptionHandlerTests.writeFailureFromLostConnectionIsRecordedOnObservation")
    unittest
    {
        auto f = setup();
        auto ex = new HttpMessageNotWritableException("simulated failure", new IOException("Broken pipe"));

        // same as DefaultHandlerExceptionResolver, which cannot tell a lost client from a lost remote connection
        assert(observe(f, ex).error() is ex);
    }

    @("ResponseEntityExceptionHandlerTests.serverErrorWithoutObservation")
    unittest
    {
        import flint.web.filter : ServerHttpObservationFilter;

        auto f = setup();
        testException(f, new HttpMessageNotWritableException("simulated failure"));
        assert(ServerHttpObservationFilter.findObservationContext(f.servletRequest).isNull);
    }

    @("ResponseEntityExceptionHandlerTests.maxUploadSizeExceededException")
    unittest
    {
        import flint.web.multipart : MaxUploadSizeExceededException;

        auto f = setup();
        testException(f, new MaxUploadSizeExceededException(1000));
    }

    @("ResponseEntityExceptionHandlerTests.serverErrorWithoutBody")
    unittest
    {
        auto f = setup();
        HttpStatusCode code = HttpStatusCode.valueOf(500);
        Exception ex = new IllegalStateException("internal error");
        f.exceptionHandler.handleExceptionInternal(ex, Any.init, HttpHeaders.create(), code, f.request);

        assert(f.servletRequest.getAttribute("jakarta.servlet.error.exception").asObject() is ex);
    }

    @("ResponseEntityExceptionHandlerTests.controllerAdvice")
    unittest
    {
        auto f = setup();
        ExceptionHandlerExceptionResolver resolver = adviceResolver();

        auto ex = new ServletRequestBindingException("message");
        assert(resolver.resolveException(f.servletRequest, f.servletResponse, null, ex) !is null);

        assert(f.servletResponse.getStatus() == 400);
        assert(f.servletResponse.getContentAsString() == "error content");
        assert(f.servletResponse.getHeader("someHeader") == "someHeaderValue");
    }

    @("ResponseEntityExceptionHandlerTests.controllerAdviceWithNestedException")
    unittest
    {
        auto f = setup();
        ExceptionHandlerExceptionResolver resolver = adviceResolver();

        ModelAndView mav = resolver.resolveException(f.servletRequest, f.servletResponse, null,
                new IllegalStateException(new ServletRequestBindingException("message")));

        assert(mav is null);
    }

    @("ResponseEntityExceptionHandlerTests.controllerAdviceWithinDispatcherServlet")
    unittest
    {
        auto f = setup();
        auto servlet = dispatcherServlet!ExceptionThrowingController();
        servlet.service(f.servletRequest, f.servletResponse);

        assert(f.servletResponse.getStatus() == 400);
        assert(f.servletResponse.getContentAsString() == "error content");
        assert(f.servletResponse.getHeader("someHeader") == "someHeaderValue");
    }

    @("ResponseEntityExceptionHandlerTests.controllerAdviceWithNestedExceptionWithinDispatcherServlet")
    unittest
    {
        auto f = setup();
        auto servlet = dispatcherServlet!NestedExceptionThrowingController();
        try
            servlet.service(f.servletRequest, f.servletResponse);
        catch (ServletException ex)
        {
            assert(cast(IllegalStateException) ex.getRootCause() !is null);
            assert(cast(ServletRequestBindingException)(cast(IllegalStateException) ex.getRootCause())
                    .getCause() !is null);
        }
    }

    private auto observe(ref Fixture f, Exception ex)
    {
        import flint.web.servlet.mvc : ObservedExchange;

        return ObservedExchange!ResponseEntity.observe(f.servletRequest, f.servletResponse, () => testException(f, ex));
    }

    private ResponseEntity testException(ref Fixture f, Exception ex)
    {
        try
        {
            Nullable!ResponseEntity entity = f.exceptionHandler.handleException(ex, f.request);
            assert(!entity.isNull);

            // Verify DefaultHandlerExceptionResolver would set the same status
            f.exceptionResolver.resolveException(f.servletRequest, f.servletResponse, null, ex);
            assert(entity.get.getStatusCode().value() == f.servletResponse.getStatus());

            return entity.get;
        }
        catch (Exception ex2)
            throw new IllegalStateException("handleException threw exception", ex2);
    }

    /// The `ExceptionHandlerExceptionResolver` of a `StaticWebApplicationContext` with the
    /// `ApplicationExceptionHandler` singleton registered as `exceptionHandler`.
    private ExceptionHandlerExceptionResolver adviceResolver()
    {
        import flint.http.converter : ByteArrayHttpMessageConverter, HttpMessageConverter, StringHttpMessageConverter;
        import flint.test.web.servlet.setup : StaticBeanFactory;
        import flint.web.servlet.mvc.method.annotation : RequestMappingHandlerAdapter;
        import flint.web.servlet.mvc.method.aot : exceptionHandlersOf;

        auto ctx = new StaticBeanFactory();
        ctx.addBean("exceptionHandler", new ApplicationExceptionHandler());
        auto adapter = new RequestMappingHandlerAdapter([
            cast(HttpMessageConverter) new ByteArrayHttpMessageConverter(),
            new StringHttpMessageConverter()
        ]);
        return new ExceptionHandlerExceptionResolver(
                exceptionHandlersOf!ApplicationExceptionHandler("exceptionHandler"), ctx, adapter);
    }

    /// A `DispatcherServlet` over a `StaticWebApplicationContext` with controller `C` registered as `controller`
    /// and the `ApplicationExceptionHandler` as `exceptionHandler`, initialized with a `MockServletConfig`.
    private auto dispatcherServlet(C)()
    {
        import flint.mock.web : MockServletConfig;
        import flint.web.context.support : StaticWebApplicationContext;
        import flint.web.servlet : DispatcherServlet;

        auto ctx = new StaticWebApplicationContext();
        ctx.registerSingleton!C("controller");
        ctx.registerSingleton!ApplicationExceptionHandler("exceptionHandler");
        ctx.refresh();

        auto servlet = new DispatcherServlet(ctx);
        servlet.init(new MockServletConfig());
        return servlet;
    }

    /// `new MethodParameter(getClass().getDeclaredMethod("handle", String.class), 0)`.
    private MethodParameter handleParameter()
    {
        import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;

        return new MethodParameter(ArgumentSpec(ArgumentKind.byType, "arg", "string"), 0,
                "ResponseEntityExceptionHandlerTests.handle");
    }

    /// `mock(MethodValidationResult.class)`.
    private final class MethodValidationResultStub : imported!"flint.validation.method".MethodValidationResult
    {
    }

    /// spring-web's `MockHttpInputMessage` test fixture.
    private final class MockHttpInputMessage : HttpInputMessage
    {
        private HttpHeaders headers;
        private const(ubyte)[] content;

        this(const(ubyte)[] content) pure nothrow
        {
            headers = HttpHeaders.create();
            this.content = content;
        }

        HttpHeaders getHeaders()
        {
            return headers;
        }

        const(ubyte)[] getBody()
        {
            return content;
        }
    }

    @Controller private class ExceptionThrowingController
    {
        @RequestMapping("/") void handleRequest()
        {
            throw new ServletRequestBindingException("message");
        }
    }

    @Controller private class NestedExceptionThrowingController
    {
        @RequestMapping("/") void handleRequest()
        {
            throw new IllegalStateException(new ServletRequestBindingException("message"));
        }
    }

    @ControllerAdvice private class ApplicationExceptionHandler : ResponseEntityExceptionHandler
    {
        protected override Nullable!ResponseEntity handleServletRequestBindingException(
                ServletRequestBindingException ex, HttpHeaders headers, HttpStatusCode status, WebRequest request)
        {
            headers = HttpHeaders.create();
            headers.set("someHeader", "someHeaderValue");
            return handleExceptionInternal(ex, Any.of("error content"), headers, status, request);
        }
    }
}
