/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
ServletResponseMethodArgumentResolverTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the `@BeforeEach`
fields become a `Fixture` that `setup` returns. `new MethodParameter(method, index)` over the test class's
`supportedParams(ServletResponse, OutputStream, Writer)` is the `ArgumentSpec` table Flint AOT writes for its
parameters (`supportedParams`), picked by position. Resolved values are `Any`, and `isSameAs` compares references
with `is`. The test lives with flint.mock.web in flint:framework-test. Cases that need unported features wait
behind a version gate.
+/
module flint.web.servlet_response_method_argument_resolver_tests;

// flint.web first: importing flint.web.method.support before it trips a forward-reference error on
// LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.core : MethodParameter;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.engine.aot.name : typeNameOf;
import flint.jakarta.servlet : ServletResponse;
import flint.java.io : OutputStream, Writer;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.context.request : ServletWebRequest;
import flint.web.method.support : ModelAndViewContainer;
import flint.web.servlet.mvc.method.annotation : ServletResponseMethodArgumentResolver;

@safe:

private struct Fixture
{
    ServletResponseMethodArgumentResolver resolver;
    ModelAndViewContainer mavContainer;
    MockHttpServletResponse servletResponse;
    ServletWebRequest webRequest;
}

private Fixture setup()
{
    Fixture f;
    f.resolver = new ServletResponseMethodArgumentResolver();
    f.mavContainer = new ModelAndViewContainer();
    f.servletResponse = new MockHttpServletResponse();
    f.webRequest = new ServletWebRequest(new MockHttpServletRequest(), f.servletResponse);
    return f;
}

@("ServletResponseMethodArgumentResolverTests.servletResponse")
unittest
{
    auto f = setup();
    MethodParameter servletResponseParameter = param(0);
    assert(f.resolver.supportsParameter(servletResponseParameter), "ServletResponse not supported");

    const result = f.resolver.resolveArgument(servletResponseParameter, f.mavContainer, f.webRequest, null);
    assert(result.asObject() is f.servletResponse, "Invalid result");
    assert(f.mavContainer.isRequestHandled());
}

// SPR-8983
@("ServletResponseMethodArgumentResolverTests.servletResponseNoMavContainer")
unittest
{
    auto f = setup();
    MethodParameter servletResponseParameter = param(0);
    assert(f.resolver.supportsParameter(servletResponseParameter), "ServletResponse not supported");

    const result = f.resolver.resolveArgument(servletResponseParameter, null, f.webRequest, null);
    assert(result.asObject() is f.servletResponse, "Invalid result");
}

// The resolver supports only ServletResponse parameters, not OutputStream or Writer.
version (FlintServletResponseResolverTypes)
{
    @("ServletResponseMethodArgumentResolverTests.outputStream")
    unittest
    {
        auto f = setup();
        MethodParameter outputStreamParameter = param(1);
        assert(f.resolver.supportsParameter(outputStreamParameter), "OutputStream not supported");

        const result = f.resolver.resolveArgument(outputStreamParameter, f.mavContainer, f.webRequest, null);
        assert(result.asObject() is f.servletResponse.getOutputStream(), "Invalid result");
        assert(f.mavContainer.isRequestHandled());
    }

    @("ServletResponseMethodArgumentResolverTests.writer")
    unittest
    {
        auto f = setup();
        MethodParameter writerParameter = param(2);
        assert(f.resolver.supportsParameter(writerParameter), "Writer not supported");

        const result = f.resolver.resolveArgument(writerParameter, f.mavContainer, f.webRequest, null);
        assert(result.asObject() is f.servletResponse.getWriter(), "Invalid result");
        assert(f.mavContainer.isRequestHandled());
    }
}

/// The `ArgumentSpec` Flint AOT writes for a parameter resolved by type.
private ArgumentSpec byType(string name, string type)
{
    ArgumentSpec spec;
    spec.kind = ArgumentKind.byType;
    spec.name = name;
    spec.type = type;
    spec.required = true;
    return spec;
}

/// Spring's `supportedParams(ServletResponse p0, OutputStream p1, Writer p2)`.
private ArgumentSpec[] supportedParams()
{
    return [
        byType("p0", typeNameOf!ServletResponse), byType("p1", typeNameOf!OutputStream),
        byType("p2", typeNameOf!Writer)
    ];
}

/// `new MethodParameter(method, index)` for `supportedParams`.
private MethodParameter param(int index)
{
    return new MethodParameter(supportedParams()[index], index,
            "ServletResponseMethodArgumentResolverTests.supportedParams");
}
