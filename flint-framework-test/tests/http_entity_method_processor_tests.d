/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
HttpEntityMethodProcessorTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` (`@BeforeEach`) returns, and the test class's own handler methods are described by
the `ArgumentSpec`s Flint AOT writes for them: Java's generic `HttpEntity<T>`, `RequestEntity<T>` and
`ResponseEntity<T>` are the erased flint.http structs, and contract 2's `elementType` carries the `T` of an entity
parameter. `new HandlerMethod(controller, method)` is built from the controller's AOT row (`requestMappingsOf!C`).
`ValidatingBinderFactory` is `DefaultDataBinderFactory` (the processor does not validate). The JSON converter's
mapper holds the Flint AOT descriptors of the test beans, built as the AOT registry would. Java's `Long` is `long`,
`String` and `CharSequence` are `string`. The test lives with flint.mock.web in flint:framework-test. Cases that
need unported features, or where the port behaves differently, wait behind version gates.
+/
module flint.web.http_entity_method_processor_tests;

// flint.web first: importing flint.web.method.support (directly or through flint.web.servlet.config.annotation)
// before it trips a forward-reference error on LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.engine.aot.name : typeNameOf;
import flint.http : HttpEntity, MediaType, ResponseEntity;
import flint.http.converter : ByteArrayHttpMessageConverter, HttpMessageConverter, StringHttpMessageConverter;
import flint.http.converter.json : JacksonJsonHttpMessageConverter;
import flint.jackson.databind : JsonMapper;
import flint.java.util : List;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.bind.support : DefaultDataBinderFactory, WebDataBinderFactory;
import flint.web.context.request : ServletWebRequest;
import flint.web.method.support : ModelAndViewContainer;
import flint.web.servlet.mvc.method.annotation : HttpEntityMethodProcessor;

@safe:

private struct Fixture
{
    MethodParameter paramList;
    MethodParameter paramSimpleBean;
    ModelAndViewContainer mavContainer;
    WebDataBinderFactory binderFactory;
    MockHttpServletRequest servletRequest;
    ServletWebRequest webRequest;
    MockHttpServletResponse servletResponse;
}

private Fixture setup()
{
    Fixture f;
    f.paramList = new MethodParameter(handleArguments()[0], 0, "HttpEntityMethodProcessorTests.handle");
    f.paramSimpleBean = new MethodParameter(handleArguments()[1], 1, "HttpEntityMethodProcessorTests.handle");

    f.mavContainer = new ModelAndViewContainer();
    f.binderFactory = new DefaultDataBinderFactory();
    f.servletRequest = new MockHttpServletRequest();
    f.servletResponse = new MockHttpServletResponse();
    f.servletRequest.setMethod("POST");
    f.webRequest = new ServletWebRequest(f.servletRequest, f.servletResponse);
    return f;
}

/// The `ArgumentSpec` Flint AOT writes for an entity parameter of type `type` whose body is an `elementType`.
private ArgumentSpec entity(string name, string type, string elementType)
{
    ArgumentSpec spec;
    spec.kind = ArgumentKind.byType;
    spec.name = name;
    spec.type = type;
    spec.required = true;
    spec.elementType = elementType;
    return spec;
}

/// `private void handle(HttpEntity<List<SimpleBean>> arg1, HttpEntity<SimpleBean> arg2)`.
private ArgumentSpec[] handleArguments()
{
    return [
        entity("arg1", typeNameOf!HttpEntity, typeNameOf!(List!SimpleBean)),
        entity("arg2", typeNameOf!HttpEntity, typeNameOf!SimpleBean)
    ];
}

/// `new MethodParameter(method, -1)` for a method returning `type`.
private MethodParameter returnType(string type, string method)
{
    ArgumentSpec spec;
    spec.kind = ArgumentKind.byType;
    spec.type = type;
    return new MethodParameter(spec, -1, "HttpEntityMethodProcessorTests." ~ method);
}

/// `private ResponseEntity<CharSequence> handle()`.
private MethodParameter handleReturnType()
{
    return returnType(typeNameOf!ResponseEntity, "handle");
}

/// The descriptors the Flint AOT registry would hold for this module's beans.
private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!Identifiable(), descriptorOf!SimpleBean(), descriptorOf!(List!SimpleBean)()
    ])
        t.add(d);
    return t;
}

/// `new JacksonJsonHttpMessageConverter()`, over this module's descriptors.
private JacksonJsonHttpMessageConverter newJsonConverter()
{
    return new JacksonJsonHttpMessageConverter(JsonMapper.builder().descriptors(table()).build());
}

@("HttpEntityMethodProcessorTests.resolveArgument")
unittest
{
    auto f = setup();
    const content = "{\"name\" : \"Jad\"}";
    f.servletRequest.setContent(cast(const(ubyte)[]) content);
    f.servletRequest.setContentType("application/json");

    HttpMessageConverter[] converters;
    converters ~= newJsonConverter();
    auto processor = new HttpEntityMethodProcessor(converters);

    auto result = processor.resolveArgument(f.paramSimpleBean, f.mavContainer, f.webRequest,
            f.binderFactory).get!HttpEntity;

    assert(result.hasBody());
    assert(result.getBody!SimpleBean().getName() == "Jad");
}

// SPR-12861
@("HttpEntityMethodProcessorTests.resolveArgumentWithEmptyBody")
unittest
{
    auto f = setup();
    f.servletRequest.setContent(new ubyte[0]);
    f.servletRequest.setContentType("application/json");

    HttpMessageConverter[] converters;
    converters ~= newJsonConverter();
    auto processor = new HttpEntityMethodProcessor(converters);

    auto result = processor.resolveArgument(f.paramSimpleBean, f.mavContainer, f.webRequest, f.binderFactory);

    assert(!result.isNull());
    assert(result.get!HttpEntity.getBody().isNull());
}

// ServletServerHttpRequest does not rebuild a form POST body from the request parameters (Spring's
// getBodyFromServletRequestParameters), so the entity has no body for the Content-Length it reports.
version (FlintFormBodyFromParameters)
{
    // gh-36298
    @("HttpEntityMethodProcessorTests.shouldResolveEntityWithMutatedHeaders")
    unittest
    {
        import flint.http : RequestEntity;
        import std.conv : to;

        auto f = setup();
        f.servletRequest.setMethod("POST");
        f.servletRequest.addParameter("project", "spring%20framework");
        f.servletRequest.addHeader("Content-Length", "project=spring%20framework".length.to!string);
        f.servletRequest.setContentType(MediaType.APPLICATION_FORM_URLENCODED_VALUE);

        HttpMessageConverter[] converters;
        converters ~= new ByteArrayHttpMessageConverter();
        auto processor = new HttpEntityMethodProcessor(converters);

        // private void resolveAsByteArray(RequestEntity<byte[]> request)
        auto requestEntity = new MethodParameter(entity("request", typeNameOf!RequestEntity,
                "ubyte[]"), 0, "HttpEntityMethodProcessorTests.resolveAsByteArray");
        auto result = processor.resolveArgument(requestEntity, f.mavContainer, f.webRequest,
                f.binderFactory).get!HttpEntity;

        assert(result.getBody!(ubyte[])().length == result.getHeaders().getContentLength());
    }
}

@("HttpEntityMethodProcessorTests.resolveGenericArgument")
unittest
{
    auto f = setup();
    const content = "[{\"name\" : \"Jad\"}, {\"name\" : \"Robert\"}]";
    f.servletRequest.setContent(cast(const(ubyte)[]) content);
    f.servletRequest.setContentType("application/json");

    HttpMessageConverter[] converters;
    converters ~= newJsonConverter();
    auto processor = new HttpEntityMethodProcessor(converters);

    auto result = processor.resolveArgument(f.paramList, f.mavContainer, f.webRequest, f.binderFactory).get!HttpEntity;

    assert(result.hasBody());
    assert(result.getBody!(List!SimpleBean)().get(0).getName() == "Jad");
    assert(result.getBody!(List!SimpleBean)().get(1).getName() == "Robert");
}

// flint.web has no RequestBodyAdvice (the processors take no advice list).
version (FlintRequestBodyAdvice)
{
    @("HttpEntityMethodProcessorTests.resolveArgumentTypeVariable")
    unittest
    {
        import flint.web.servlet.mvc.method.annotation : ContextClassRequestBodyAdvice;

        auto f = setup();
        // public void handleDto(HttpEntity<DTO> dto), with DTO = SimpleBean in MySimpleParameterizedController
        auto methodParam = new MethodParameter(entity("dto", typeNameOf!HttpEntity,
                typeNameOf!SimpleBean), 0, "MySimpleParameterizedController.handleDto");

        const content = "{\"name\" : \"Jad\"}";
        f.servletRequest.setContent(cast(const(ubyte)[]) content);
        f.servletRequest.setContentType(MediaType.APPLICATION_JSON_VALUE);

        HttpMessageConverter[] converters;
        converters ~= newJsonConverter();
        Object[] requestResponseBodyAdvice;
        requestResponseBodyAdvice ~= new ContextClassRequestBodyAdvice();
        auto processor = new HttpEntityMethodProcessor(converters, requestResponseBodyAdvice);

        auto result = processor.resolveArgument(methodParam, f.mavContainer, f.webRequest,
                f.binderFactory).get!HttpEntity;

        assert(result.hasBody());
        assert(result.getBody!SimpleBean().getName() == "Jad");
    }

    private abstract class MyParameterizedController(DTO : Identifiable)
    {
        void handleDto(HttpEntity dto)
        {
        }
    }

    private class MySimpleParameterizedController : MyParameterizedController!SimpleBean
    {
    }
}

// flint.jackson has no @JsonTypeInfo/@JsonTypeName polymorphic type ids.
version (FlintJacksonGenericTypes)
{
    import flint.jackson.annotation : JsonTypeInfo, JsonTypeName;
    import flint.web.bind.annotation : RequestMapping, ResponseBody;

    // SPR-12811
    @("HttpEntityMethodProcessorTests.jacksonTypeInfoList")
    unittest
    {
        import flint.web.method : HandlerMethod;
        import flint.web.servlet.mvc.method.aot : requestMappingsOf;
        import std.algorithm.searching : canFind;

        auto f = setup();
        auto row = requestMappingsOf!JacksonController("controller")[0];
        auto handlerMethod = new HandlerMethod(new JacksonController(), typeNameOf!JacksonController, row);
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters;
        converters ~= newJsonConverter();
        auto processor = new HttpEntityMethodProcessor(converters);

        auto returnValue = Any.of(new JacksonController().handleList());
        processor.handleReturnValue(returnValue, methodReturnType, f.mavContainer, f.webRequest);

        const content = f.servletResponse.getContentAsString();
        assert(content.canFind("\"type\":\"foo\""), content);
        assert(content.canFind("\"type\":\"bar\""), content);
    }

    @JsonTypeInfo(use : JsonTypeInfo.Id.NAME, include:
            JsonTypeInfo.As.PROPERTY, property:
            "type")
    private class ParentClass
    {
        private string parentProperty;

        this()
        {
        }

        this(string parentProperty)
        {
            this.parentProperty = parentProperty;
        }

        string getParentProperty()
        {
            return parentProperty;
        }

        void setParentProperty(string parentProperty)
        {
            this.parentProperty = parentProperty;
        }
    }

    @JsonTypeName("foo")
    private class Foo : ParentClass
    {
        this(string parentProperty)
        {
            super(parentProperty);
        }
    }

    @JsonTypeName("bar")
    private class Bar : ParentClass
    {
        this(string parentProperty)
        {
            super(parentProperty);
        }
    }

    private class JacksonController
    {
        @RequestMapping
        @ResponseBody
        HttpEntity handleList()
        {
            import flint.java.util : ArrayList;

            List!ParentClass list = new ArrayList!ParentClass();
            list.add(new Foo("foo"));
            list.add(new Bar("bar"));
            return HttpEntity.of(list);
        }
    }
}

// flint.http's StringHttpMessageConverter defaults to UTF-8 as Spring Boot configures it (Spring's is ISO-8859-1);
// D has no CharSequence or StringBuilder, so the body is a string.
version (FlintStringConverterSpringDefaultCharset)
{
    // SPR-13423
    @("HttpEntityMethodProcessorTests.handleReturnValueCharSequence")
    unittest
    {
        auto f = setup();
        HttpMessageConverter[] converters;
        converters ~= new ByteArrayHttpMessageConverter();
        converters ~= new StringHttpMessageConverter();

        auto returnType = handleReturnType();
        auto returnValue = ResponseEntity.ok("Foo");

        auto processor = new HttpEntityMethodProcessor(converters);
        processor.handleReturnValue(Any.of(returnValue), returnType, f.mavContainer, f.webRequest);

        assert(f.servletResponse.getHeader("Content-Type") == "text/plain;charset=ISO-8859-1");
        assert(f.servletResponse.getContentAsString() == "Foo");
    }
}

// flint.web has no ShallowEtagHeaderFilter.
version (FlintShallowEtagHeaderFilter)
{
    // SPR-13423
    @("HttpEntityMethodProcessorTests.handleReturnValueWithETagAndETagFilter")
    unittest
    {
        import flint.http : HttpHeaders;
        import flint.jakarta.servlet : FilterChain, ServletRequest, ServletResponse;
        import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
        import flint.java.lang : IllegalStateException;
        import flint.web.filter : ShallowEtagHeaderFilter;

        auto f = setup();
        const eTagValue = "\"deadb33f8badf00d\"";
        const content = "body";

        auto returnType = handleReturnType();

        FilterChain chain = FilterChain.of((ServletRequest req, ServletResponse res) {
            auto returnValue = ResponseEntity.ok().eTag(eTagValue).body(content);
            try
            {
                auto requestToUse = new ServletWebRequest(cast(HttpServletRequest) req, cast(HttpServletResponse) res);

                new HttpEntityMethodProcessor([
                    cast(HttpMessageConverter) new StringHttpMessageConverter()
                ]).handleReturnValue(Any.of(returnValue), returnType, f.mavContainer, requestToUse);

                assert(f.servletResponse.getContentAsString() == content,
                    "Response body was cached? It should be written directly to the raw response");
            }
            catch (Exception ex)
                throw new IllegalStateException(ex.msg, ex);
        });

        f.servletRequest.setMethod("GET");
        new ShallowEtagHeaderFilter().doFilter(f.servletRequest, f.servletResponse, chain);

        assert(f.servletResponse.getStatus() == 200);
        assert(f.servletResponse.getHeader(HttpHeaders.ETAG) == eTagValue);
        assert(f.servletResponse.getContentAsString() == content);
    }
}

// gh-24539
@("HttpEntityMethodProcessorTests.handleReturnValueWithMalformedAcceptHeader")
unittest
{
    auto f = setup();
    (cast(MockHttpServletRequest) f.webRequest.getNativeRequest()).addHeader("Accept", "null");

    HttpMessageConverter[] converters;
    converters ~= new ByteArrayHttpMessageConverter();
    converters ~= new StringHttpMessageConverter();

    auto returnType = handleReturnType();
    auto returnValue = ResponseEntity.badRequest().body("Foo");

    auto processor = new HttpEntityMethodProcessor(converters);
    processor.handleReturnValue(Any.of(returnValue), returnType, f.mavContainer, f.webRequest);

    assert(f.servletResponse.getStatus() == 400);
    assert(f.servletResponse.getHeader("Content-Type") is null);
    assert(f.servletResponse.getContentAsString().length == 0);
}

// flint.web has no ErrorResponse.Interceptor (the processors take no interceptors).
version (FlintErrorResponseInterceptors)
{
    @("HttpEntityMethodProcessorTests.errorResponseInterceptorsWithRequest")
    unittest
    {
        import flint.http : HttpStatus;
        import flint.web : ErrorResponse, ErrorResponseException;
        import flint.web.accept : ContentNegotiationManager;
        import std.algorithm.searching : canFind;

        auto f = setup();
        f.servletRequest.setRequestURI("/orders/42");
        f.servletRequest.setQueryString("trace=on");
        ErrorResponse.Interceptor[] interceptors = [
            ErrorResponse.Interceptor.of((detail, errorResponse) {
                detail.setProperty("errorResponse", Any.of(errorResponse !is null));
            }), new TraceParamInterceptor()
        ];
        auto processor = new HttpEntityMethodProcessor([
            cast(HttpMessageConverter) newJsonConverter()
        ], new ContentNegotiationManager(), null, interceptors);
        auto returnType = returnType(typeNameOf!ErrorResponse, "handleErrorResponse");

        processor.handleReturnValue(Any.of(new ErrorResponseException(HttpStatus.BAD_REQUEST)),
                returnType, f.mavContainer, f.webRequest);

        assert(f.servletResponse.getStatus() == 400);
        const content = f.servletResponse.getContentAsString();
        assert(content.canFind("\"errorResponse\":true"), content);
        assert(content.canFind("\"trace\":\"on\""), content);
    }

    private class TraceParamInterceptor : imported!"flint.web".ErrorResponse.Interceptor
    {
        import flint.http : HttpRequest, ProblemDetail;
        import flint.web : ErrorResponse;
        import flint.web.util : UriComponentsBuilder;

        void handleError(ProblemDetail detail, ErrorResponse errorResponse)
        {
        }

        void handleError(ProblemDetail detail, ErrorResponse errorResponse, HttpRequest request)
        {
            auto params = UriComponentsBuilder.fromUri(request.getURI()).build().getQueryParams();
            detail.setProperty("trace", Any.of(params.getFirst("trace")));
        }
    }
}

private interface Identifiable
{
    long getId();

    void setId(long id);
}

private class SimpleBean : Identifiable
{
    private long id;
    private string name;

    long getId()
    {
        return id;
    }

    void setId(long id)
    {
        this.id = id;
    }

    string getName()
    {
        return name;
    }

    void setName(string name)
    {
        this.name = name;
    }
}
