/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
RequestResponseBodyMethodProcessorTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` returns, and the test class's own handler methods (`handle`, `getImage`, ...) are
module functions. `new MethodParameter(method, index)` is the `ArgumentSpec` Flint AOT writes for the D method's
parameter (its declared type, `@RequestBody` as a body argument) or return type; `new HandlerMethod(controller,
method)` is built from the controller's AOT row (`requestMappingsOf!C`). Generic Java methods are D templates, so
their type variables are resolved when the D method is instantiated. Java's package access to the protected
`writeWithMessageConverters(value, returnType, webRequest)` and `readWithMessageConverters` is a test subclass
(`TestProcessor`) that calls them. `ValidatingBinderFactory` is `DefaultDataBinderFactory` (the processor does
not validate these arguments). The JSON converter's mapper holds the Flint AOT descriptors of the test beans, built
as the AOT registry would. Java's `Long` is `long`, `String` and `CharSequence` are `string`. The test lives with
flint.mock.web in flint:framework-test. Cases that need unported features, or where the port behaves differently,
wait behind version gates.
+/
module flint.web.request_response_body_method_processor_tests;

import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf, findAnnotation, mergedAnnotations;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.engine.aot.name : typeNameOf;
import flint.http : HttpStatus, MediaType, ProblemDetail;
import flint.http.converter : ByteArrayHttpMessageConverter, HttpMessageConverter,
    HttpMessageNotReadableException, StringHttpMessageConverter;
import flint.http.converter.json : JacksonJsonHttpMessageConverter;
import flint.jackson.databind : JsonMapper;
import flint.java.util : Arrays, List;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.test.web.servlet.setup : StaticBeanFactory;
import flint.util : MultiValueMap;
import flint.web.accept : ContentNegotiationManager;
import flint.web.bind.annotation : RequestBody, RequestMapping, ResponseBody, RestController;
import flint.web.bind.support : DefaultDataBinderFactory, WebDataBinderFactory;
import flint.web.context.request : NativeWebRequest, ServletWebRequest;
import flint.web.method : HandlerMethod;
import flint.web.method.support : ModelAndViewContainer;
import flint.web.servlet.mvc.method.annotation : RequestResponseBodyMethodProcessor;
import flint.web.servlet.mvc.method.aot : requestMappingsOf;
import std.algorithm.searching : canFind;

@safe:

private struct Fixture
{
    ModelAndViewContainer container;
    MockHttpServletRequest servletRequest;
    MockHttpServletResponse servletResponse;
    NativeWebRequest request;
    WebDataBinderFactory factory;
    MethodParameter paramGenericList;
    MethodParameter paramSimpleBean;
    MethodParameter paramMultiValueMap;
    MethodParameter paramString;
    MethodParameter returnTypeString;
}

private Fixture setup()
{
    Fixture f;
    f.container = new ModelAndViewContainer();
    f.servletRequest = new MockHttpServletRequest();
    f.servletResponse = new MockHttpServletResponse();
    f.request = new ServletWebRequest(f.servletRequest, f.servletResponse);
    f.factory = new DefaultDataBinderFactory();
    f.paramGenericList = methodParameter!handle(0);
    f.paramSimpleBean = methodParameter!handle(1);
    f.paramMultiValueMap = methodParameter!handle(2);
    f.paramString = methodParameter!handle(3);
    f.returnTypeString = methodParameter!handle(-1);
    return f;
}

/// `new MethodParameter(method, index)`: the `ArgumentSpec` Flint AOT writes for parameter `index` of `method`
/// (-1 for its return type).
private MethodParameter methodParameter(alias method)(int index)
{
    import std.traits : ParameterIdentifierTuple, ReturnType;

    ArgumentSpec spec;
    spec.kind = ArgumentKind.byType;
    spec.required = true;
    if (index < 0)
        spec.type = typeNameOf!(ReturnType!method);
    static if (is(typeof(method) Params == __parameters))
    {
        static foreach (i; 0 .. Params.length)
        {
            if (i == index)
            {
                spec.type = typeNameOf!(Params[i]);
                spec.name = ParameterIdentifierTuple!method[i];
                spec.annotations = mergedAnnotations!(__traits(getAttributes, Params[i .. i + 1]))();
                if (auto requestBody = findAnnotation(spec.annotations, typeNameOf!RequestBody))
                {
                    spec.kind = ArgumentKind.requestBody;
                    spec.required = requestBody.value.get!RequestBody.required;
                }
            }
        }
    }
    return new MethodParameter(spec, index, __traits(identifier, method));
}

/// `new HandlerMethod(controller, Declaring.class.getMethod(name))`: from the AOT row of `Declaring`'s method.
private HandlerMethod newHandlerMethod(Declaring)(Object controller, string name)
{
    foreach (row; requestMappingsOf!Declaring("controller"))
        if (row.method.name == name)
            return new HandlerMethod(controller, typeid(controller).name, row);
    assert(false, name);
}

/// The descriptors the Flint AOT registry would hold for this module's beans.
private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!Identifiable(), descriptorOf!SimpleBean(),
        descriptorOf!(List!SimpleBean)(), descriptorOf!(List!Identifiable)()
    ])
        t.add(d);
    return t;
}

/// `new JacksonJsonHttpMessageConverter()`, over this module's descriptors.
private JacksonJsonHttpMessageConverter newJsonConverter()
{
    return new JacksonJsonHttpMessageConverter(JsonMapper.builder().descriptors(table()).build());
}

/// The processor with Java's package access to its protected message-converter methods.
private final class TestProcessor : RequestResponseBodyMethodProcessor
{
    this(HttpMessageConverter[] converters, ContentNegotiationManager manager = null)
    {
        super(converters, manager);
    }

    /// `writeWithMessageConverters(value, returnType, webRequest)`.
    void writeWithMessageConverters(T)(T value, MethodParameter returnType, NativeWebRequest webRequest)
    {
        super.writeWithMessageConverters(Any.of(value), returnType, webRequest, createOutputMessage(webRequest));
    }

    /// `readWithMessageConverters(webRequest, parameter, paramType)`.
    override Any readWithMessageConverters(NativeWebRequest webRequest, MethodParameter parameter, string paramType)
    {
        return super.readWithMessageConverters(webRequest, parameter, paramType);
    }
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

@("RequestResponseBodyMethodProcessorTests.resolveArgumentParameterizedType")
unittest
{
    auto f = setup();
    const content = "[{\"name\" : \"Jad\"}, {\"name\" : \"Robert\"}]";
    f.servletRequest.setContent(cast(const(ubyte)[]) content);
    f.servletRequest.setContentType(MediaType.APPLICATION_JSON_VALUE);

    HttpMessageConverter[] converters = [newJsonConverter()];
    auto processor = new RequestResponseBodyMethodProcessor(converters);

    auto result = processor.resolveArgument(f.paramGenericList, f.container, f.request, f.factory)
        .get!(List!SimpleBean);

    assert(result.size() == 2);
    assert(result.get(0).getName() == "Jad");
    assert(result.get(1).getName() == "Robert");
}

@("RequestResponseBodyMethodProcessorTests.resolveArgumentClassJson")
unittest
{
    auto f = setup();
    const content = "{\"name\" : \"Jad\"}";
    f.servletRequest.setContent(cast(const(ubyte)[]) content);
    f.servletRequest.setContentType("application/json");

    HttpMessageConverter[] converters = [newJsonConverter()];
    auto processor = new RequestResponseBodyMethodProcessor(converters);

    auto result = processor.resolveArgument(f.paramSimpleBean, f.container, f.request, f.factory).get!SimpleBean;

    assert(result !is null);
    assert(result.getName() == "Jad");
}

// SPR-9964
@("RequestResponseBodyMethodProcessorTests.resolveArgumentTypeVariable")
unittest
{
    auto f = setup();
    auto methodParam = methodParameter!(MySimpleParameterizedController.handleDto)(0);

    const content = "{\"name\" : \"Jad\"}";
    f.servletRequest.setContent(cast(const(ubyte)[]) content);
    f.servletRequest.setContentType(MediaType.APPLICATION_JSON_VALUE);

    HttpMessageConverter[] converters = [newJsonConverter()];
    auto processor = new RequestResponseBodyMethodProcessor(converters);

    auto result = processor.resolveArgument(methodParam, f.container, f.request, f.factory).get!SimpleBean;

    assert(result !is null);
    assert(result.getName() == "Jad");
}

// SPR-14470
@("RequestResponseBodyMethodProcessorTests.resolveParameterizedWithTypeVariableArgument")
unittest
{
    auto f = setup();
    auto methodParam = methodParameter!(MySimpleParameterizedControllerWithList.handleDto)(0);

    const content = "[{\"name\" : \"Jad\"}, {\"name\" : \"Robert\"}]";
    f.servletRequest.setContent(cast(const(ubyte)[]) content);
    f.servletRequest.setContentType(MediaType.APPLICATION_JSON_VALUE);

    HttpMessageConverter[] converters = [newJsonConverter()];
    auto processor = new RequestResponseBodyMethodProcessor(converters);

    auto result = processor.resolveArgument(methodParam, f.container, f.request, f.factory).get!(List!SimpleBean);

    assert(result.size() == 2);
    assert(result.get(0).getName() == "Jad");
    assert(result.get(1).getName() == "Robert");
}

// SPR-11225
@("RequestResponseBodyMethodProcessorTests.resolveArgumentTypeVariableWithNonGenericConverter")
unittest
{
    auto f = setup();
    auto methodParam = methodParameter!(MySimpleParameterizedController.handleDto)(0);

    const content = "{\"name\" : \"Jad\"}";
    f.servletRequest.setContent(cast(const(ubyte)[]) content);
    f.servletRequest.setContentType(MediaType.APPLICATION_JSON_VALUE);

    HttpMessageConverter target = newJsonConverter();
    HttpMessageConverter proxy = new ConverterProxy(target);
    HttpMessageConverter[] converters = [proxy];
    auto processor = new RequestResponseBodyMethodProcessor(converters);

    auto result = processor.resolveArgument(methodParam, f.container, f.request, f.factory).get!SimpleBean;

    assert(result !is null);
    assert(result.getName() == "Jad");
}

/// `ProxyFactory.getProxy(HttpMessageConverter.class, new SingletonTargetSource(target))`: an interface
/// proxy that delegates every call to `target`.
private final class ConverterProxy : HttpMessageConverter
{
    import flint.http : HttpInputMessage, HttpOutputMessage;

    private HttpMessageConverter target;

    this(HttpMessageConverter target)
    {
        this.target = target;
    }

    bool canRead(string typeName, scope const(MediaType)* mediaType)
    {
        return target.canRead(typeName, mediaType);
    }

    bool canWrite(string typeName, scope const(MediaType)* mediaType)
    {
        return target.canWrite(typeName, mediaType);
    }

    MediaType[] getSupportedMediaTypes()
    {
        return target.getSupportedMediaTypes();
    }

    MediaType[] getSupportedMediaTypes(string typeName)
    {
        return target.getSupportedMediaTypes(typeName);
    }

    Any read(string typeName, HttpInputMessage inputMessage)
    {
        return target.read(typeName, inputMessage);
    }

    void write(Any value, scope const(MediaType)* contentType, HttpOutputMessage outputMessage)
    {
        target.write(value, contentType, outputMessage);
    }
}

private abstract class MyParameterizedController(DTO : Identifiable)
{
    void handleDto(@RequestBody DTO dto)
    {
    }
}

private class MySimpleParameterizedController : MyParameterizedController!SimpleBean
{
}

private abstract class MyParameterizedControllerWithList(DTO : Identifiable)
{
    void handleDto(@RequestBody List!DTO dto)
    {
    }
}

private class MySimpleParameterizedControllerWithList : MyParameterizedControllerWithList!SimpleBean
{
}

// flint.http has no FormHttpMessageConverter.
version (FlintFormHttpMessageConverter)
{
    @("RequestResponseBodyMethodProcessorTests.resolveArgumentRawTypeFromParameterizedType")
    unittest
    {
        import flint.http.converter : FormHttpMessageConverter;

        auto f = setup();
        const content = "fruit=apple&vegetable=kale";
        f.servletRequest.setMethod("GET");
        f.servletRequest.setContent(cast(const(ubyte)[]) content);
        f.servletRequest.setContentType(MediaType.APPLICATION_FORM_URLENCODED_VALUE);

        HttpMessageConverter[] converters = [new FormHttpMessageConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters);

        auto result = processor.resolveArgument(f.paramMultiValueMap, f.container, f.request,
                f.factory).get!(MultiValueMap!(string, string));

        assert(result !is null);
        assert(result.getFirst("fruit") == "apple");
        assert(result.getFirst("vegetable") == "kale");
    }
}

@("RequestResponseBodyMethodProcessorTests.resolveArgumentClassString")
unittest
{
    auto f = setup();
    const content = "foobarbaz";
    f.servletRequest.setContent(cast(const(ubyte)[]) content);
    f.servletRequest.setContentType("application/json");

    HttpMessageConverter[] converters = [new StringHttpMessageConverter()];
    auto processor = new RequestResponseBodyMethodProcessor(converters);

    const result = processor.resolveArgument(f.paramString, f.container, f.request, f.factory).get!string;

    assert(result == "foobarbaz");
}

// SPR-9942
@("RequestResponseBodyMethodProcessorTests.resolveArgumentRequiredNoContent")
unittest
{
    auto f = setup();
    f.servletRequest.setContent(new ubyte[0]);
    f.servletRequest.setContentType("text/plain");
    HttpMessageConverter[] converters = [new StringHttpMessageConverter()];
    auto processor = new RequestResponseBodyMethodProcessor(converters);
    assert(thrown!HttpMessageNotReadableException(() {
            processor.resolveArgument(f.paramString, f.container, f.request, f.factory);
        }) !is null);
}

// flint.web has no RequestBodyAdvice (the processors take no advice list).
version (FlintRequestBodyAdvice)
{
    // SPR-12778
    @("RequestResponseBodyMethodProcessorTests.resolveArgumentRequiredNoContentDefaultValue")
    unittest
    {
        auto f = setup();
        f.servletRequest.setContent(new ubyte[0]);
        f.servletRequest.setContentType("text/plain");
        HttpMessageConverter[] converters = [new StringHttpMessageConverter()];
        Object[] advice = [new EmptyRequestBodyAdvice()];
        auto processor = new RequestResponseBodyMethodProcessor(converters, advice);
        const arg = processor.resolveArgument(f.paramString, f.container, f.request, f.factory).get!string;
        assert(arg == "default value for empty body");
    }

    private class EmptyRequestBodyAdvice : imported!"flint.web.servlet.mvc.method.annotation".RequestBodyAdvice
    {
        import flint.http : HttpInputMessage;

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

// SPR-9160
@("RequestResponseBodyMethodProcessorTests.handleReturnValueSortByQuality")
unittest
{
    auto f = setup();
    f.servletRequest.addHeader("Accept", "text/plain; q=0.5, application/json");

    HttpMessageConverter[] converters = [newJsonConverter(), new StringHttpMessageConverter()];
    auto processor = new TestProcessor(converters);

    processor.writeWithMessageConverters("Foo", f.returnTypeString, f.request);

    assert(f.servletResponse.getHeader("Content-Type") == MediaType.APPLICATION_JSON_VALUE);
}

// flint.http's StringHttpMessageConverter defaults to UTF-8 as Spring Boot configures it (Spring's is ISO-8859-1);
// D has no CharSequence or StringBuilder, so a CharSequence return value is a string.
version (FlintStringConverterSpringDefaultCharset)
{
    @("RequestResponseBodyMethodProcessorTests.handleReturnValueString")
    unittest
    {
        auto f = setup();
        HttpMessageConverter[] converters = [
            new ByteArrayHttpMessageConverter(), new StringHttpMessageConverter()
        ];
        auto processor = new RequestResponseBodyMethodProcessor(converters);
        processor.handleReturnValue(Any.of("Foo"), f.returnTypeString, f.container, f.request);

        assert(f.servletResponse.getHeader("Content-Type") == "text/plain;charset=ISO-8859-1");
        assert(f.servletResponse.getContentAsString() == "Foo");
    }

    // SPR-13423
    @("RequestResponseBodyMethodProcessorTests.handleReturnValueCharSequence")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!ResponseBodyController(new ResponseBodyController(),
                "handleWithCharSequence");
        auto returnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [
            new ByteArrayHttpMessageConverter(), new StringHttpMessageConverter()
        ];
        auto processor = new RequestResponseBodyMethodProcessor(converters);
        processor.handleReturnValue(Any.of("Foo"), returnType, f.container, f.request);

        assert(f.servletResponse.getHeader("Content-Type") == "text/plain;charset=ISO-8859-1");
        assert(f.servletResponse.getContentAsString() == "Foo");
    }
}

@("RequestResponseBodyMethodProcessorTests.handleReturnValueStringAcceptCharset")
unittest
{
    auto f = setup();
    f.servletRequest.addHeader("Accept", "text/plain;charset=UTF-8");

    HttpMessageConverter[] converters = [
        new ByteArrayHttpMessageConverter(), new StringHttpMessageConverter()
    ];
    auto processor = new TestProcessor(converters);

    processor.writeWithMessageConverters("Foo", f.returnTypeString, f.request);

    assert(f.servletResponse.getHeader("Content-Type") == "text/plain;charset=UTF-8");
}

// flint.http has no ResourceHttpMessageConverter, flint.core.io no ClassPathResource.
version (FlintResourceHttpMessageConverter)
{
    import flint.core.io : ClassPathResource, Resource;

    // SPR-12894
    @("RequestResponseBodyMethodProcessorTests.handleReturnValueImage")
    unittest
    {
        import flint.http.converter : ResourceHttpMessageConverter;

        auto f = setup();
        f.servletRequest.addHeader("Accept", "*/*");

        auto returnType = methodParameter!getImage(-1);

        HttpMessageConverter[] converters = [new ResourceHttpMessageConverter()];
        auto processor = new TestProcessor(converters);

        auto resource = new ClassPathResource("logo.jpg", typeNameOf!Fixture);
        processor.writeWithMessageConverters(resource, returnType, f.request);

        assert(f.servletResponse.getHeader("Content-Type") == "image/jpeg");
    }

    private Resource getImage()
    {
        return null;
    }
}

// flint.http's JacksonJsonHttpMessageConverter has no registerMappersForType.
version (FlintJacksonMapperRegistrations)
{
    // gh-26212
    @("RequestResponseBodyMethodProcessorTests.handleReturnValueWithObjectMapperByTypeRegistration")
    unittest
    {
        import flint.jackson.databind : SerializationFeature;

        auto f = setup();
        auto halFormsMediaType = MediaType.parseMediaType("application/prs.hal-forms+json");
        auto halMediaType = MediaType.parseMediaType("application/hal+json");

        f.servletRequest.addHeader("Accept", halFormsMediaType.toString() ~ "," ~ halMediaType.toString());

        auto mapper = JsonMapper.builder().descriptors(table()).enable(SerializationFeature.INDENT_OUTPUT).build();

        auto simpleBean = new SimpleBean();
        simpleBean.setId(12L);
        simpleBean.setName("Jason");

        auto converter = newJsonConverter();
        converter.registerMappersForType(typeNameOf!SimpleBean, (map) {
            map.put(halMediaType, mapper);
        });
        auto processor = new TestProcessor([cast(HttpMessageConverter) converter]);
        auto returnType = methodParameter!getSimpleBean(-1);
        processor.writeWithMessageConverters(simpleBean, returnType, f.request);

        assert(f.servletResponse.getHeader("Content-Type") == halMediaType.toString());
        assert(f.servletResponse.getContentAsString() == "{\n  \"id\" : 12,\n  \"name\" : \"Jason\"\n}");
    }

    private SimpleBean getSimpleBean()
    {
        return null;
    }
}

// The JSON half of Spring's problemDetail* tests below: without the XML converter, every request ends in
// application/problem+json (AbstractJacksonHttpMessageConverter.getMediaTypesForProblemDetail).
@("Flint: a ProblemDetail is written as application/problem+json whatever JSON the request accepts")
unittest
{
    foreach (accept; [
        null, MediaType.APPLICATION_JSON_VALUE,
        MediaType.APPLICATION_JSON_VALUE ~ "," ~ MediaType.APPLICATION_PROBLEM_JSON_VALUE,
        MediaType.APPLICATION_PDF_VALUE
    ])
    {
        auto f = setup();
        if (accept !is null)
            f.servletRequest.addHeader("Accept", accept);
        f.servletRequest.setRequestURI("/path");
        auto processor = new RequestResponseBodyMethodProcessor([
            cast(HttpMessageConverter) newJsonConverter()
        ]);
        auto returnType = methodParameter!handleAndReturnPlainProblemDetail(-1);
        processor.handleReturnValue(Any.of(ProblemDetail.forStatus(HttpStatus.BAD_REQUEST.value())),
                returnType, f.container, f.request);

        assert(f.servletResponse.getStatus() == HttpStatus.BAD_REQUEST.value());
        assert(f.servletResponse.getContentType() == MediaType.APPLICATION_PROBLEM_JSON_VALUE,
                f.servletResponse.getContentType());
        const content = f.servletResponse.getContentAsString();
        assert(content.canFind(`"title":"Bad Request"`), content);
    }
}

private ProblemDetail handleAndReturnPlainProblemDetail()
{
    return null;
}

// flint.http has no JacksonXmlHttpMessageConverter (nor XML problem details).
version (FlintJacksonXml)
{
    @("RequestResponseBodyMethodProcessorTests.problemDetailDefaultMediaType")
    unittest
    {
        auto f = setup();
        testProblemDetailMediaType(f, MediaType.APPLICATION_PROBLEM_JSON_VALUE);
    }

    @("RequestResponseBodyMethodProcessorTests.problemDetailWhenJsonRequested")
    unittest
    {
        auto f = setup();
        f.servletRequest.addHeader("Accept", MediaType.APPLICATION_JSON_VALUE);
        testProblemDetailMediaType(f, MediaType.APPLICATION_PROBLEM_JSON_VALUE);
    }

    // gh-29588
    @("RequestResponseBodyMethodProcessorTests.problemDetailWhenJsonAndProblemJsonRequested")
    unittest
    {
        auto f = setup();
        f.servletRequest.addHeader("Accept",
                MediaType.APPLICATION_JSON_VALUE ~ "," ~ MediaType.APPLICATION_PROBLEM_JSON_VALUE);
        testProblemDetailMediaType(f, MediaType.APPLICATION_PROBLEM_JSON_VALUE);
    }

    @("RequestResponseBodyMethodProcessorTests.problemDetailWhenNoMatchingMediaTypeRequested")
    unittest
    {
        auto f = setup();
        f.servletRequest.addHeader("Accept", MediaType.APPLICATION_PDF_VALUE);
        testProblemDetailMediaType(f, MediaType.APPLICATION_PROBLEM_JSON_VALUE);
    }

    @("RequestResponseBodyMethodProcessorTests.problemDetailWhenProblemXmlRequested")
    unittest
    {
        auto f = setup();
        f.servletRequest.addHeader("Accept", MediaType.APPLICATION_PROBLEM_XML_VALUE);
        testProblemDetailMediaType(f, MediaType.APPLICATION_PROBLEM_XML_VALUE);
    }

    private void testProblemDetailMediaType(Fixture f, string expectedContentType)
    {
        import flint.http.converter.xml : JacksonXmlHttpMessageConverter;

        auto problemDetail = new MyProblemDetail(HttpStatus.BAD_REQUEST);

        f.servletRequest.setRequestURI("/path");

        auto processor = new RequestResponseBodyMethodProcessor([
            cast(HttpMessageConverter) newJsonConverter(), new JacksonXmlHttpMessageConverter()
        ]);

        auto returnType = methodParameter!handleAndReturnProblemDetail(-1);

        processor.handleReturnValue(Any.of(problemDetail), returnType, f.container, f.request);

        assert(f.servletResponse.getStatus() == HttpStatus.BAD_REQUEST.value());
        assert(f.servletResponse.getContentType() == expectedContentType);

        if (expectedContentType == MediaType.APPLICATION_PROBLEM_XML_VALUE)
        {
            assert(f.servletResponse.getContentAsString() == `<problem xmlns="urn:ietf:rfc:7807">`
                    ~ "<status>400</status><title>Bad Request</title></problem>");
        }
        else
        {
            const content = f.servletResponse.getContentAsString();
            assert(content.canFind(`"title":"Bad Request"`), content);
            assert(content.canFind(`"status":400`), content);
        }
    }

    private MyProblemDetail handleAndReturnProblemDetail()
    {
        return null;
    }

    private class MyProblemDetail : ProblemDetail
    {
        this(HttpStatus status)
        {
            super(status.value());
        }
    }
}

// flint.web has no ErrorResponse.Interceptor (the processors take no interceptors).
version (FlintErrorResponseInterceptors)
{
    @("RequestResponseBodyMethodProcessorTests.errorResponseInterceptorsWithRequest")
    unittest
    {
        import flint.web : ErrorResponse;

        auto f = setup();
        f.servletRequest.setRequestURI("/orders/42");
        f.servletRequest.setQueryString("trace=on");
        ErrorResponse.Interceptor[] interceptors = [
            ErrorResponse.Interceptor.of((detail, errorResponse) {
                detail.setProperty("errorResponse", Any.of(errorResponse !is null));
            }), new TraceParamInterceptor()
        ];
        auto processor = new RequestResponseBodyMethodProcessor([
            cast(HttpMessageConverter) newJsonConverter()
        ], null, null, interceptors);
        auto returnType = methodParameter!handleAndReturnProblemDetail(-1);

        processor.handleReturnValue(Any.of(new MyProblemDetail(HttpStatus.BAD_REQUEST)), returnType,
                f.container, f.request);

        const content = f.servletResponse.getContentAsString();
        assert(content.canFind("\"errorResponse\":false"), content);
        assert(content.canFind("\"trace\":\"on\""), content);
    }

    private MyProblemDetail handleAndReturnProblemDetail()
    {
        return null;
    }

    private class MyProblemDetail : ProblemDetail
    {
        this(HttpStatus status)
        {
            super(status.value());
        }
    }

    private class TraceParamInterceptor : imported!"flint.web".ErrorResponse.Interceptor
    {
        import flint.http : HttpRequest;
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

// SPR-13135
@("RequestResponseBodyMethodProcessorTests.handleReturnValueWithInvalidReturnType")
unittest
{
    import flint.java.io : ByteArrayOutputStream;
    import flint.web : HttpMediaTypeNotAcceptableException;

    auto f = setup();
    auto returnType = methodParameter!handleAndReturnOutputStream(-1);
    HttpMessageConverter[] converters = [new StringHttpMessageConverter()];
    auto processor = new TestProcessor(converters);
    assert(thrown!HttpMediaTypeNotAcceptableException(() {
            processor.writeWithMessageConverters(new ByteArrayOutputStream(), returnType, f.request);
        }) !is null);
}

@RequestMapping private imported!"flint.java.io".OutputStream handleAndReturnOutputStream()
{
    return null;
}

// flint.web has no ContentNegotiationManagerFactoryBean, and the processor adds no Content-Disposition for
// unknown path extensions (Spring's reflected-file-download protection).
version (FlintRfdContentDisposition)
{
    import flint.web.accept : ContentNegotiationManagerFactoryBean;

    @("RequestResponseBodyMethodProcessorTests.addContentDispositionHeader")
    unittest
    {
        import flint.web.util : WebUtils;

        auto f = setup();
        auto factory = new ContentNegotiationManagerFactoryBean();
        factory.addMediaType("pdf", MediaType("application", "pdf"));
        factory.afterPropertiesSet();

        auto processor = new RequestResponseBodyMethodProcessor(
                [cast(HttpMessageConverter) new StringHttpMessageConverter()], factory.getObject());

        assertContentDisposition(f, processor, false, "/hello.json", "safe extension");
        assertContentDisposition(f, processor, false, "/hello.pdf", "registered extension");
        assertContentDisposition(f, processor, true, "/hello.dataless", "unknown extension");

        // path parameters
        assertContentDisposition(f, processor, false, "/hello.json;a=b", "path param shouldn't cause issue");
        assertContentDisposition(f, processor, true, "/hello.json;a=b;setup.dataless", "unknown ext in path params");
        assertContentDisposition(f, processor, true, "/hello.dataless;a=b;setup.json", "unknown ext in filename");
        assertContentDisposition(f, processor, false, "/hello.json;a=b;setup.json", "safe extensions");
        assertContentDisposition(f, processor, true, "/hello.json;jsessionid=foo.bar",
                "jsessionid shouldn't cause issue");

        // encoded dot
        assertContentDisposition(f, processor, true, "/hello%2Edataless;a=b;setup.json", "encoded dot in filename");
        assertContentDisposition(f, processor, true, "/hello.json;a=b;setup%2Edataless", "encoded dot in path params");
        assertContentDisposition(f, processor, true, "/hello.dataless%3Bsetup.bat", "encoded dot in path params");

        f.servletRequest.setAttribute(WebUtils.FORWARD_REQUEST_URI_ATTRIBUTE, Any.of("/hello.bat"));
        assertContentDisposition(f, processor, true, "/bonjour", "forwarded URL");
        f.servletRequest.removeAttribute(WebUtils.FORWARD_REQUEST_URI_ATTRIBUTE);
    }

    @("RequestResponseBodyMethodProcessorTests.addContentDispositionHeaderToErrorResponse")
    unittest
    {
        auto f = setup();
        auto factory = new ContentNegotiationManagerFactoryBean();
        factory.addMediaType("pdf", MediaType("application", "pdf"));
        factory.afterPropertiesSet();

        auto processor = new RequestResponseBodyMethodProcessor(
                [cast(HttpMessageConverter) new StringHttpMessageConverter()], factory.getObject());

        f.servletRequest.setRequestURI("/hello.dataless");
        f.servletResponse.setStatus(400);

        processor.handleReturnValue(Any.of("body"), f.returnTypeString, f.container, f.request);

        const header = f.servletResponse.getHeader("Content-Disposition");
        assert(header == "inline;filename=f.txt");
    }

    private void assertContentDisposition(Fixture f, RequestResponseBodyMethodProcessor processor,
            bool expectContentDisposition, string requestURI, string comment)
    {
        f.servletRequest.setRequestURI(requestURI);
        processor.handleReturnValue(Any.of("body"), f.returnTypeString, f.container, f.request);

        const header = f.servletResponse.getHeader("Content-Disposition");
        if (expectContentDisposition)
            assert(header == "inline;filename=f.txt",
                    "Expected 'Content-Disposition' header. Use case: '" ~ comment ~ "'");
        else
            assert(header is null, "Did not expect 'Content-Disposition' header. Use case: '" ~ comment ~ "'");

        f.servletRequest.clearAttributes();
        f.servletResponse.setCommitted(false);
        f.servletResponse.reset();
    }
}

@("RequestResponseBodyMethodProcessorTests.supportsReturnTypeResponseBodyOnType")
unittest
{
    auto handlerMethod = newHandlerMethod!ResponseBodyController(new ResponseBodyController(), "handle");
    auto returnType = handlerMethod.getReturnType();

    HttpMessageConverter[] converters = [new StringHttpMessageConverter()];
    auto processor = new RequestResponseBodyMethodProcessor(converters);

    assert(processor.supportsReturnType(returnType), "Failed to recognize type-level @ResponseBody");
}

@("RequestResponseBodyMethodProcessorTests.supportsReturnTypeRestController")
unittest
{
    auto handlerMethod = newHandlerMethod!TestRestController(new TestRestController(), "handle");
    auto returnType = handlerMethod.getReturnType();

    HttpMessageConverter[] converters = [new StringHttpMessageConverter()];
    auto processor = new RequestResponseBodyMethodProcessor(converters);

    assert(processor.supportsReturnType(returnType), "Failed to recognize type-level @RestController");
}

// flint.jackson has no @JsonView and flint.web no JsonViewRequestBodyAdvice/JsonViewResponseBodyAdvice; the
// Jackson 2 (MappingJackson2*) and XML converters are not ported either.
version (FlintJacksonJsonView)
{
    import flint.http : HttpEntity, ResponseEntity;
    import flint.http.converter.json : MappingJackson2HttpMessageConverter;
    import flint.http.converter.xml : JacksonXmlHttpMessageConverter, MappingJackson2XmlHttpMessageConverter;
    import flint.jackson.annotation : JsonView;
    import flint.java.lang : classOf;
    import flint.web.servlet.mvc.method.annotation : HttpEntityMethodProcessor,
        JsonViewRequestBodyAdvice, JsonViewResponseBodyAdvice;

    private void assertJsonViewWritten(string content)
    {
        assert(!content.canFind("\"withView1\":\"with\""), content);
        assert(content.canFind("\"withView2\":\"with\""), content);
        assert(!content.canFind("\"withoutView\":\"without\""), content);
    }

    private void assertXmlViewWritten(string content)
    {
        assert(!content.canFind("<withView1>with</withView1>"), content);
        assert(content.canFind("<withView2>with</withView2>"), content);
        assert(!content.canFind("<withoutView>without</withoutView>"), content);
    }

    private void assertViewRead(JacksonViewBean result)
    {
        assert(result !is null);
        assert(result.getWithView1() == "with");
        assert(result.getWithView2() is null);
        assert(result.getWithoutView() is null);
    }

    private enum jsonViewContent = "{\"withView1\" : \"with\", \"withView2\" : \"with\", "
        ~ "\"withoutView\" : \"without\"}";
    private enum xmlViewContent = "<root>" ~ "<withView1>with</withView1>"
        ~ "<withView2>with</withView2>" ~ "<withoutView>without</withoutView></root>";

    @("RequestResponseBodyMethodProcessorTests.jacksonJsonViewWithResponseBodyAndJsonMessageConverter")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleResponseBody");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [newJsonConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters, null,
                [cast(Object) new JsonViewResponseBodyAdvice()]);

        auto returnValue = Any.of(new JacksonController().handleResponseBody());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        assertJsonViewWritten(f.servletResponse.getContentAsString());
    }

    @("RequestResponseBodyMethodProcessorTests.jackson2JsonViewWithResponseBodyAndJsonMessageConverter")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleResponseBody");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [new MappingJackson2HttpMessageConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters, null,
                [cast(Object) new JsonViewResponseBodyAdvice()]);

        auto returnValue = Any.of(new JacksonController().handleResponseBody());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        assertJsonViewWritten(f.servletResponse.getContentAsString());
    }

    @("RequestResponseBodyMethodProcessorTests.jacksonJsonViewWithResponseEntityAndJsonMessageConverter")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleResponseEntity");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [newJsonConverter()];
        auto processor = new HttpEntityMethodProcessor(converters, null,
                [cast(Object) new JsonViewResponseBodyAdvice()]);

        auto returnValue = Any.of(new JacksonController().handleResponseEntity());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        assertJsonViewWritten(f.servletResponse.getContentAsString());
    }

    @("RequestResponseBodyMethodProcessorTests.jackson2JsonViewWithResponseEntityAndJsonMessageConverter")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleResponseEntity");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [new MappingJackson2HttpMessageConverter()];
        auto processor = new HttpEntityMethodProcessor(converters, null,
                [cast(Object) new JsonViewResponseBodyAdvice()]);

        auto returnValue = Any.of(new JacksonController().handleResponseEntity());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        assertJsonViewWritten(f.servletResponse.getContentAsString());
    }

    @("RequestResponseBodyMethodProcessorTests.jacksonJsonViewWithResponseBodyAndXmlMessageConverter")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleResponseBody");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [new JacksonXmlHttpMessageConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters, null,
                [cast(Object) new JsonViewResponseBodyAdvice()]);

        auto returnValue = Any.of(new JacksonController().handleResponseBody());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        assertXmlViewWritten(f.servletResponse.getContentAsString());
    }

    // SPR-12149
    @("RequestResponseBodyMethodProcessorTests.jackson2JsonViewWithResponseBodyAndXmlMessageConverter")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleResponseBody");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [new MappingJackson2XmlHttpMessageConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters, null,
                [cast(Object) new JsonViewResponseBodyAdvice()]);

        auto returnValue = Any.of(new JacksonController().handleResponseBody());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        assertXmlViewWritten(f.servletResponse.getContentAsString());
    }

    @("RequestResponseBodyMethodProcessorTests.jacksonJsonViewWithResponseEntityAndXmlMessageConverter")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleResponseEntity");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [new JacksonXmlHttpMessageConverter()];
        auto processor = new HttpEntityMethodProcessor(converters, null,
                [cast(Object) new JsonViewResponseBodyAdvice()]);

        auto returnValue = Any.of(new JacksonController().handleResponseEntity());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        assertXmlViewWritten(f.servletResponse.getContentAsString());
    }

    // SPR-12149
    @("RequestResponseBodyMethodProcessorTests.jackson2JsonViewWithResponseEntityAndXmlMessageConverter")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleResponseEntity");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [new MappingJackson2XmlHttpMessageConverter()];
        auto processor = new HttpEntityMethodProcessor(converters, null,
                [cast(Object) new JsonViewResponseBodyAdvice()]);

        auto returnValue = Any.of(new JacksonController().handleResponseEntity());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        assertXmlViewWritten(f.servletResponse.getContentAsString());
    }

    @("RequestResponseBodyMethodProcessorTests.resolveArgumentWithJacksonJsonView")
    unittest
    {
        auto f = setup();
        f.servletRequest.setContent(cast(const(ubyte)[]) jsonViewContent);
        f.servletRequest.setContentType(MediaType.APPLICATION_JSON_VALUE);

        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleRequestBody");
        auto methodParameter = handlerMethod.getMethodParameters()[0];

        HttpMessageConverter[] converters = [newJsonConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters, null,
                [cast(Object) new JsonViewRequestBodyAdvice()]);

        assertViewRead(processor.resolveArgument(methodParameter, f.container, f.request,
                f.factory).get!JacksonViewBean);
    }

    // SPR-12501
    @("RequestResponseBodyMethodProcessorTests.resolveArgumentWithJackson2JsonView")
    unittest
    {
        auto f = setup();
        f.servletRequest.setContent(cast(const(ubyte)[]) jsonViewContent);
        f.servletRequest.setContentType(MediaType.APPLICATION_JSON_VALUE);

        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleRequestBody");
        auto methodParameter = handlerMethod.getMethodParameters()[0];

        HttpMessageConverter[] converters = [new MappingJackson2HttpMessageConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters, null,
                [cast(Object) new JsonViewRequestBodyAdvice()]);

        assertViewRead(processor.resolveArgument(methodParameter, f.container, f.request,
                f.factory).get!JacksonViewBean);
    }

    @("RequestResponseBodyMethodProcessorTests.resolveHttpEntityArgumentWithJacksonJsonView")
    unittest
    {
        auto f = setup();
        f.servletRequest.setContent(cast(const(ubyte)[]) jsonViewContent);
        f.servletRequest.setContentType(MediaType.APPLICATION_JSON_VALUE);

        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleHttpEntity");
        auto methodParameter = handlerMethod.getMethodParameters()[0];

        HttpMessageConverter[] converters = [newJsonConverter()];
        auto processor = new HttpEntityMethodProcessor(converters, null, [
            cast(Object) new JsonViewRequestBodyAdvice()
        ]);

        auto result = processor.resolveArgument(methodParameter, f.container, f.request, f.factory).get!HttpEntity;

        assert(result.hasBody());
        assertViewRead(result.getBody!JacksonViewBean());
    }

    // SPR-12501
    @("RequestResponseBodyMethodProcessorTests.resolveHttpEntityArgumentWithJackson2JsonView")
    unittest
    {
        auto f = setup();
        f.servletRequest.setContent(cast(const(ubyte)[]) jsonViewContent);
        f.servletRequest.setContentType(MediaType.APPLICATION_JSON_VALUE);

        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleHttpEntity");
        auto methodParameter = handlerMethod.getMethodParameters()[0];

        HttpMessageConverter[] converters = [new MappingJackson2HttpMessageConverter()];
        auto processor = new HttpEntityMethodProcessor(converters, null, [
            cast(Object) new JsonViewRequestBodyAdvice()
        ]);

        auto result = processor.resolveArgument(methodParameter, f.container, f.request, f.factory).get!HttpEntity;

        assert(result.hasBody());
        assertViewRead(result.getBody!JacksonViewBean());
    }

    @("RequestResponseBodyMethodProcessorTests.resolveArgumentWithJacksonJsonViewAndXmlMessageConverter")
    unittest
    {
        auto f = setup();
        f.servletRequest.setContent(cast(const(ubyte)[]) xmlViewContent);
        f.servletRequest.setContentType(MediaType.APPLICATION_XML_VALUE);

        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleRequestBody");
        auto methodParameter = handlerMethod.getMethodParameters()[0];

        HttpMessageConverter[] converters = [new JacksonXmlHttpMessageConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters, null,
                [cast(Object) new JsonViewRequestBodyAdvice()]);

        assertViewRead(processor.resolveArgument(methodParameter, f.container, f.request,
                f.factory).get!JacksonViewBean);
    }

    // SPR-12501
    @("RequestResponseBodyMethodProcessorTests.resolveArgumentWithJackson2JsonViewAndXmlMessageConverter")
    unittest
    {
        auto f = setup();
        f.servletRequest.setContent(cast(const(ubyte)[]) xmlViewContent);
        f.servletRequest.setContentType(MediaType.APPLICATION_XML_VALUE);

        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleRequestBody");
        auto methodParameter = handlerMethod.getMethodParameters()[0];

        HttpMessageConverter[] converters = [new MappingJackson2XmlHttpMessageConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters, null,
                [cast(Object) new JsonViewRequestBodyAdvice()]);

        assertViewRead(processor.resolveArgument(methodParameter, f.container, f.request,
                f.factory).get!JacksonViewBean);
    }

    @("RequestResponseBodyMethodProcessorTests.resolveHttpEntityArgumentWithJacksonJsonViewAndXmlMessageConverter")
    unittest
    {
        auto f = setup();
        f.servletRequest.setContent(cast(const(ubyte)[]) xmlViewContent);
        f.servletRequest.setContentType(MediaType.APPLICATION_XML_VALUE);

        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleHttpEntity");
        auto methodParameter = handlerMethod.getMethodParameters()[0];

        HttpMessageConverter[] converters = [new JacksonXmlHttpMessageConverter()];
        auto processor = new HttpEntityMethodProcessor(converters, null, [
            cast(Object) new JsonViewRequestBodyAdvice()
        ]);

        auto result = processor.resolveArgument(methodParameter, f.container, f.request, f.factory).get!HttpEntity;

        assert(result.hasBody());
        assertViewRead(result.getBody!JacksonViewBean());
    }

    // SPR-12501
    @("RequestResponseBodyMethodProcessorTests.resolveHttpEntityArgumentWithJackson2JsonViewAndXmlMessageConverter")
    unittest
    {
        auto f = setup();
        f.servletRequest.setContent(cast(const(ubyte)[]) xmlViewContent);
        f.servletRequest.setContentType(MediaType.APPLICATION_XML_VALUE);

        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleHttpEntity");
        auto methodParameter = handlerMethod.getMethodParameters()[0];

        HttpMessageConverter[] converters = [new MappingJackson2XmlHttpMessageConverter()];
        auto processor = new HttpEntityMethodProcessor(converters, null, [
            cast(Object) new JsonViewRequestBodyAdvice()
        ]);

        auto result = processor.resolveArgument(methodParameter, f.container, f.request, f.factory).get!HttpEntity;

        assert(result.hasBody());
        assertViewRead(result.getBody!JacksonViewBean());
    }

    private interface MyJacksonView1
    {
    }

    private interface MyJacksonView2
    {
    }

    private class JacksonViewBean
    {
        @JsonView(classOf!MyJacksonView1) private string withView1;
        @JsonView(classOf!MyJacksonView2) private string withView2;
        private string withoutView;

        string getWithView1()
        {
            return withView1;
        }

        void setWithView1(string withView1)
        {
            this.withView1 = withView1;
        }

        string getWithView2()
        {
            return withView2;
        }

        void setWithView2(string withView2)
        {
            this.withView2 = withView2;
        }

        string getWithoutView()
        {
            return withoutView;
        }

        void setWithoutView(string withoutView)
        {
            this.withoutView = withoutView;
        }
    }
}

// flint.jackson has no @JsonTypeInfo/@JsonTypeName polymorphic type ids.
version (FlintJacksonGenericTypes)
{
    import flint.jackson.annotation : JsonTypeInfo, JsonTypeName;

    @("RequestResponseBodyMethodProcessorTests.jacksonTypeInfoList")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!(BaseController!ParentClass)(new JacksonController(),
                "handleTypeInfoList");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [newJsonConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters);

        auto returnValue = Any.of(new JacksonController().handleTypeInfoList());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        const content = f.servletResponse.getContentAsString();
        assert(content.canFind("\"type\":\"foo\""), content);
        assert(content.canFind("\"type\":\"bar\""), content);
    }

    @JsonTypeInfo(use : JsonTypeInfo.Id.NAME, property:
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

    private class BaseController(T)
    {
        @RequestMapping @ResponseBody List!T handleTypeInfoList()
        {
            return Arrays.asList!T(cast(T) new Foo("foo"), cast(T) new Bar("bar"));
        }
    }

}

// flint.http has no MappingJackson2HttpMessageConverter (Jackson 2, deprecated for removal in Spring 7).
version (FlintJackson2)
{
    import flint.http.converter.json : MappingJackson2HttpMessageConverter;

    // SPR-12811
    @("RequestResponseBodyMethodProcessorTests.jackson2TypeInfoList")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!(BaseController!ParentClass)(new JacksonController(),
                "handleTypeInfoList");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [new MappingJackson2HttpMessageConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters);

        auto returnValue = Any.of(new JacksonController().handleTypeInfoList());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        const content = f.servletResponse.getContentAsString();
        assert(content.canFind("\"type\":\"foo\""), content);
        assert(content.canFind("\"type\":\"bar\""), content);
    }

    // SPR-13318
    @("RequestResponseBodyMethodProcessorTests.jackson2SubType")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleSubType");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [new MappingJackson2HttpMessageConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters);

        auto returnValue = Any.of(new JacksonController().handleSubType());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        const content = f.servletResponse.getContentAsString();
        assert(content.canFind("\"id\":123"), content);
        assert(content.canFind("\"name\":\"foo\""), content);
    }

    // SPR-13318
    @("RequestResponseBodyMethodProcessorTests.jackson2SubTypeList")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleSubTypeList");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [new MappingJackson2HttpMessageConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters);

        auto returnValue = Any.of(new JacksonController().handleSubTypeList());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        const content = f.servletResponse.getContentAsString();
        assert(content.canFind("\"id\":123"), content);
        assert(content.canFind("\"name\":\"foo\""), content);
        assert(content.canFind("\"id\":456"), content);
        assert(content.canFind("\"name\":\"bar\""), content);
    }
}

// Behaviour: the processor and the JSON converter take a value's type from its declared D type (Any's type name),
// not its runtime class, so SimpleBeans returned as Identifiable are written with the interface's (empty) properties.
version (FlintRuntimeValueType)
{
    @("RequestResponseBodyMethodProcessorTests.jacksonSubType")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleSubType");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [newJsonConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters);

        auto returnValue = Any.of(new JacksonController().handleSubType());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        const content = f.servletResponse.getContentAsString();
        assert(content.canFind("\"id\":123"), content);
        assert(content.canFind("\"name\":\"foo\""), content);
    }

    @("RequestResponseBodyMethodProcessorTests.jacksonSubTypeList")
    unittest
    {
        auto f = setup();
        auto handlerMethod = newHandlerMethod!JacksonController(new JacksonController(), "handleSubTypeList");
        auto methodReturnType = handlerMethod.getReturnType();

        HttpMessageConverter[] converters = [newJsonConverter()];
        auto processor = new RequestResponseBodyMethodProcessor(converters);

        auto returnValue = Any.of(new JacksonController().handleSubTypeList());
        processor.handleReturnValue(returnValue, methodReturnType, f.container, f.request);

        const content = f.servletResponse.getContentAsString();
        assert(content.canFind("\"id\":123"), content);
        assert(content.canFind("\"name\":\"foo\""), content);
        assert(content.canFind("\"id\":456"), content);
        assert(content.canFind("\"name\":\"bar\""), content);
    }
}

// SPR-14520
@("RequestResponseBodyMethodProcessorTests.resolveArgumentTypeVariableWithGenericInterface")
unittest
{
    auto f = setup();
    f.servletRequest.setContent(cast(const(ubyte)[]) "\"foo\"");
    f.servletRequest.setContentType(MediaType.APPLICATION_JSON_VALUE);

    // Spring finds @RequestBody on the interface method the controller inherits.
    auto methodParameter = methodParameter!(MappingInterface!string.handle)(0);

    HttpMessageConverter[] converters = [newJsonConverter()];
    auto processor = new TestProcessor(converters);

    assert(processor.supportsParameter(methodParameter));
    const value = processor.readWithMessageConverters(f.request, methodParameter,
            methodParameter.getParameterType()).get!string;
    assert(value == "foo");
}

// gh-24127
@("RequestResponseBodyMethodProcessorTests.resolveArgumentTypeVariableWithGenericInterfaceAndSubclass")
unittest
{
    auto f = setup();
    f.servletRequest.setContent(cast(const(ubyte)[]) "\"foo\"");
    f.servletRequest.setContentType(MediaType.APPLICATION_JSON_VALUE);

    // Spring finds @RequestBody on the interface method that SubControllerImplementingInterface overrides.
    auto methodParameter = methodParameter!(MappingInterface!string.handle)(0);

    HttpMessageConverter[] converters = [newJsonConverter()];
    auto processor = new TestProcessor(converters);

    assert(processor.supportsParameter(methodParameter));
    const value = processor.readWithMessageConverters(f.request, methodParameter,
            methodParameter.getParameterType()).get!string;
    assert(value == "foo");
}

// gh-25788
@("RequestResponseBodyMethodProcessorTests.resolveArgumentTypeVariableWithAbstractMethod")
unittest
{
    auto f = setup();
    f.servletRequest.setContent(cast(const(ubyte)[]) "\"foo\"");
    f.servletRequest.setContentType(MediaType.APPLICATION_JSON_VALUE);

    // Spring finds @RequestBody on the abstract method that SubControllerImplementingAbstractMethod implements.
    auto methodParameter = methodParameter!(MyControllerWithAbstractMethod!string.handle)(0);

    HttpMessageConverter[] converters = [newJsonConverter()];
    auto processor = new TestProcessor(converters);

    assert(processor.supportsParameter(methodParameter));
    const value = processor.readWithMessageConverters(f.request, methodParameter,
            methodParameter.getParameterType()).get!string;
    assert(value == "foo");
}

// gh-36300
@("RequestResponseBodyMethodProcessorTests.shouldNotDuplicateInCompatibleMediaTypes")
unittest
{
    import std.conv : to;

    auto f = setup();
    auto handlerMethod = newHandlerMethod!TestRestController(new TestRestController(), "handle");
    auto returnType = handlerMethod.getReturnType();

    HttpMessageConverter[] converters = [new StringHttpMessageConverter(), newJsonConverter()];
    auto processor = new TestProcessor(converters);

    string accept;
    foreach (i; 1 .. 49)
        accept ~= (i == 1 ? "" : ",") ~ "application/" ~ i.to!string;
    accept = accept ~ ", application/json";
    f.servletRequest.addHeader("Accept", accept);

    processor.writeWithMessageConverters("spring framework", returnType, f.request);
}

private string handle(@RequestBody List!SimpleBean list, @RequestBody SimpleBean simpleBean,
        @RequestBody MultiValueMap!(string, string) multiValueMap, @RequestBody string string_)
{
    return null;
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

@ResponseBody private class ResponseBodyController
{
    @RequestMapping string handle()
    {
        return "hello";
    }

    @RequestMapping string handleWithCharSequence()
    {
        return null;
    }
}

@RestController private class TestRestController
{
    @RequestMapping string handle()
    {
        return "hello";
    }
}

// BaseController!ParentClass waits for @JsonTypeInfo.
version (FlintJacksonGenericTypes)
    private alias JacksonControllerBase = BaseController!ParentClass;
else
    private alias JacksonControllerBase = Object;

private class JacksonController : JacksonControllerBase
{
    version (FlintJacksonJsonView)
    {
        import flint.http : HttpEntity, ResponseEntity;
        import flint.jackson.annotation : JsonView;
        import flint.java.lang : classOf;

        @RequestMapping @ResponseBody @JsonView(classOf!MyJacksonView2) JacksonViewBean handleResponseBody()
        {
            auto bean = new JacksonViewBean();
            bean.setWithView1("with");
            bean.setWithView2("with");
            bean.setWithoutView("without");
            return bean;
        }

        @RequestMapping @JsonView(classOf!MyJacksonView2) ResponseEntity handleResponseEntity()
        {
            auto bean = new JacksonViewBean();
            bean.setWithView1("with");
            bean.setWithView2("with");
            bean.setWithoutView("without");
            return ResponseEntity.of(bean, HttpStatus.OK);
        }

        @RequestMapping @ResponseBody JacksonViewBean handleRequestBody(
                @JsonView(classOf!MyJacksonView1) @RequestBody JacksonViewBean bean)
        {
            return bean;
        }

        @RequestMapping @ResponseBody JacksonViewBean handleHttpEntity(
                @JsonView(classOf!MyJacksonView1) HttpEntity entity)
        {
            return entity.getBody!JacksonViewBean();
        }
    }

    @RequestMapping @ResponseBody Identifiable handleSubType()
    {
        auto foo = new SimpleBean();
        foo.setId(123L);
        foo.setName("foo");
        return foo;
    }

    @RequestMapping @ResponseBody List!Identifiable handleSubTypeList()
    {
        auto foo = new SimpleBean();
        foo.setId(123L);
        foo.setName("foo");
        auto bar = new SimpleBean();
        bar.setId(456L);
        bar.setName("bar");
        return Arrays.asList!Identifiable(foo, bar);
    }

    @RequestMapping(produces : [MediaType.APPLICATION_JSON_VALUE]) @ResponseBody string defaultCharset()
    {
        return "foo";
    }
}

private interface MappingInterface(A)
{
    A handle(@RequestBody A arg);
}

private class MyControllerImplementingInterface : MappingInterface!string
{
    string handle(string arg)
    {
        return arg;
    }
}

private class SubControllerImplementingInterface : MyControllerImplementingInterface
{
    override string handle(string arg)
    {
        return arg;
    }
}

private abstract class MyControllerWithAbstractMethod(A)
{
    abstract A handle(@RequestBody A arg);
}

private class SubControllerImplementingAbstractMethod : MyControllerWithAbstractMethod!string
{
    override string handle(string arg)
    {
        return arg;
    }
}
