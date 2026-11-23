/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
ServletRequestMethodArgumentResolverTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the `@BeforeEach`
fields become a `Fixture` that `setup` returns. `new MethodParameter(method, index)` over the test class's
`supportedParams` and `supportedParamsWithAnnotatedPrincipal` is the `ArgumentSpec` table Flint AOT writes for
their parameters (`supportedParams`, `annotatedPrincipalParam`), picked by position (`Param`); unported parameter
types are named as Flint AOT would write them. Resolved values are `Any`; `isSameAs` compares references with
`is`, and `HttpMethod` (a struct) by value. The test lives with flint.mock.web in flint:framework-test. Cases that
need unported features wait behind version gates.
+/
module flint.web.servlet_request_method_argument_resolver_tests;

// flint.web first: importing flint.web.method.support before it trips a forward-reference error on
// LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : MergedAnnotation;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.engine.aot.name : typeNameOf;
import flint.http : HttpMethod;
import flint.jakarta.servlet : ServletRequest;
import flint.java.io : InputStream;
import flint.java.time : ZoneId;
import flint.java.util : Locale;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.context.request : ServletWebRequest, WebRequest;
import flint.web.method.support : ModelAndViewContainer;
import flint.web.servlet.mvc.method.annotation : ServletRequestMethodArgumentResolver;

@safe:

private struct Fixture
{
    ServletRequestMethodArgumentResolver resolver;
    ModelAndViewContainer mavContainer;
    MockHttpServletRequest servletRequest;
    ServletWebRequest webRequest;
}

private Fixture setup()
{
    Fixture f;
    f.resolver = new ServletRequestMethodArgumentResolver();
    f.mavContainer = new ModelAndViewContainer();
    f.servletRequest = new MockHttpServletRequest("GET", "");
    f.webRequest = new ServletWebRequest(f.servletRequest, new MockHttpServletResponse());
    return f;
}

@("ServletRequestMethodArgumentResolverTests.servletRequest")
unittest
{
    auto f = setup();
    MethodParameter servletRequestParameter = param(Param.p0);
    assert(f.resolver.supportsParameter(servletRequestParameter), "ServletRequest not supported");

    const result = f.resolver.resolveArgument(servletRequestParameter, f.mavContainer, f.webRequest, null);
    assert(result.asObject() is f.servletRequest, "Invalid result");
    assert(!f.mavContainer.isRequestHandled(), "The requestHandled flag shouldn't change");
}

// The resolver supports only ServletRequest, WebRequest and HttpMethod parameters (no HttpSession, Principal,
// Locale, TimeZone, ZoneId, InputStream, Reader or PushBuilder), and those types' mocks are not ported.
version (FlintServletRequestResolverTypes)
{
    import flint.java.security : Principal;
    import flint.java.util : TimeZone;
    import flint.mock.web : MockHttpSession;

    @("ServletRequestMethodArgumentResolverTests.session")
    unittest
    {
        auto f = setup();
        auto session = new MockHttpSession();
        f.servletRequest.setSession(session);

        MethodParameter sessionParameter = param(Param.p2);
        assert(f.resolver.supportsParameter(sessionParameter), "Session not supported");

        const result = f.resolver.resolveArgument(sessionParameter, f.mavContainer, f.webRequest, null);
        assert(result.asObject() is session, "Invalid result");
        assert(!f.mavContainer.isRequestHandled(), "The requestHandled flag shouldn't change");
    }

    /// Spring's `() -> "Foo"` principal.
    private final class FooPrincipal : Principal
    {
        string getName()
        {
            return "Foo";
        }
    }

    @("ServletRequestMethodArgumentResolverTests.principal")
    unittest
    {
        auto f = setup();
        Principal principal = new FooPrincipal();
        f.servletRequest.setUserPrincipal(principal);

        MethodParameter principalParameter = param(Param.p3);
        assert(f.resolver.supportsParameter(principalParameter), "Principal not supported");

        const result = f.resolver.resolveArgument(principalParameter, null, f.webRequest, null);
        assert(result.asObject() is cast(Object) principal, "Invalid result");
    }

    @("ServletRequestMethodArgumentResolverTests.principalAsNull")
    unittest
    {
        auto f = setup();
        MethodParameter principalParameter = param(Param.p3);
        assert(f.resolver.supportsParameter(principalParameter), "Principal not supported");

        const result = f.resolver.resolveArgument(principalParameter, null, f.webRequest, null);
        assert(result.isNull(), "Invalid result");
    }
}

// gh-25780
@("ServletRequestMethodArgumentResolverTests.annotatedPrincipal")
unittest
{
    auto f = setup();
    MethodParameter principalParameter = annotatedPrincipalParam();
    assert(!f.resolver.supportsParameter(principalParameter), "Principal not supported");
}

version (FlintServletRequestResolverTypes)
{
    @("ServletRequestMethodArgumentResolverTests.locale")
    unittest
    {
        auto f = setup();
        const locale = Locale.ENGLISH;
        f.servletRequest.addPreferredLocale(locale);

        MethodParameter localeParameter = param(Param.p4);
        assert(f.resolver.supportsParameter(localeParameter), "Locale not supported");

        const result = f.resolver.resolveArgument(localeParameter, null, f.webRequest, null);
        assert(result.get!Locale == locale, "Invalid result");
    }
}

// FixedLocaleResolver and DispatcherServlet.LOCALE_RESOLVER_ATTRIBUTE are not ported (the cases also need
// FlintServletRequestResolverTypes).
version (FlintWebLocaleResolver)
{
    import flint.web.servlet : DispatcherServlet;
    import flint.web.servlet.i18n : FixedLocaleResolver;

    @("ServletRequestMethodArgumentResolverTests.localeFromResolver")
    unittest
    {
        auto f = setup();
        const locale = Locale.ENGLISH;
        f.servletRequest.setAttribute(DispatcherServlet.LOCALE_RESOLVER_ATTRIBUTE,
                Any.of(new FixedLocaleResolver(locale)));

        MethodParameter localeParameter = param(Param.p4);
        assert(f.resolver.supportsParameter(localeParameter), "Locale not supported");

        const result = f.resolver.resolveArgument(localeParameter, null, f.webRequest, null);
        assert(result.get!Locale == locale, "Invalid result");
    }
}

version (FlintServletRequestResolverTypes)
{
    @("ServletRequestMethodArgumentResolverTests.timeZone")
    unittest
    {
        auto f = setup();
        MethodParameter timeZoneParameter = param(Param.p8);
        assert(f.resolver.supportsParameter(timeZoneParameter), "TimeZone not supported");

        const result = f.resolver.resolveArgument(timeZoneParameter, null, f.webRequest, null);
        assert(result.get!TimeZone == TimeZone.getDefault(), "Invalid result");
    }
}

version (FlintWebLocaleResolver)
{
    @("ServletRequestMethodArgumentResolverTests.timeZoneFromResolver")
    unittest
    {
        auto f = setup();
        auto timeZone = TimeZone.getTimeZone("America/Los_Angeles");
        f.servletRequest.setAttribute(DispatcherServlet.LOCALE_RESOLVER_ATTRIBUTE,
                Any.of(new FixedLocaleResolver(Locale.US, timeZone)));

        MethodParameter timeZoneParameter = param(Param.p8);
        assert(f.resolver.supportsParameter(timeZoneParameter), "TimeZone not supported");

        const result = f.resolver.resolveArgument(timeZoneParameter, null, f.webRequest, null);
        assert(result.get!TimeZone == timeZone, "Invalid result");
    }
}

version (FlintServletRequestResolverTypes)
{
    @("ServletRequestMethodArgumentResolverTests.zoneId")
    unittest
    {
        auto f = setup();
        MethodParameter zoneIdParameter = param(Param.p9);
        assert(f.resolver.supportsParameter(zoneIdParameter), "ZoneId not supported");

        const result = f.resolver.resolveArgument(zoneIdParameter, null, f.webRequest, null);
        assert(result.get!ZoneId == ZoneId.systemDefault(), "Invalid result");
    }
}

version (FlintWebLocaleResolver)
{
    @("ServletRequestMethodArgumentResolverTests.zoneIdFromResolver")
    unittest
    {
        auto f = setup();
        auto timeZone = TimeZone.getTimeZone("America/New_York");
        f.servletRequest.setAttribute(DispatcherServlet.LOCALE_RESOLVER_ATTRIBUTE,
                Any.of(new FixedLocaleResolver(Locale.US, timeZone)));
        MethodParameter zoneIdParameter = param(Param.p9);

        assert(f.resolver.supportsParameter(zoneIdParameter), "ZoneId not supported");

        const result = f.resolver.resolveArgument(zoneIdParameter, null, f.webRequest, null);
        assert(result.get!ZoneId == timeZone.toZoneId(), "Invalid result");
    }
}

version (FlintServletRequestResolverTypes)
{
    @("ServletRequestMethodArgumentResolverTests.inputStream")
    unittest
    {
        auto f = setup();
        MethodParameter inputStreamParameter = param(Param.p5);
        assert(f.resolver.supportsParameter(inputStreamParameter), "InputStream not supported");

        const result = f.resolver.resolveArgument(inputStreamParameter, null, f.webRequest, null);
        assert(result.asObject() is f.webRequest.getRequest().getInputStream(), "Invalid result");
    }

    @("ServletRequestMethodArgumentResolverTests.reader")
    unittest
    {
        auto f = setup();
        MethodParameter readerParameter = param(Param.p6);
        assert(f.resolver.supportsParameter(readerParameter), "Reader not supported");

        const result = f.resolver.resolveArgument(readerParameter, null, f.webRequest, null);
        assert(result.asObject() is f.webRequest.getRequest().getReader(), "Invalid result");
    }
}

@("ServletRequestMethodArgumentResolverTests.webRequest")
unittest
{
    auto f = setup();
    MethodParameter webRequestParameter = param(Param.p7);
    assert(f.resolver.supportsParameter(webRequestParameter), "WebRequest not supported");

    const result = f.resolver.resolveArgument(webRequestParameter, null, f.webRequest, null);
    assert(result.asObject() is f.webRequest, "Invalid result");
}

@("ServletRequestMethodArgumentResolverTests.httpMethod")
unittest
{
    auto f = setup();
    MethodParameter httpMethodParameter = param(Param.p10);
    assert(f.resolver.supportsParameter(httpMethodParameter), "HttpMethod not supported");

    const result = f.resolver.resolveArgument(httpMethodParameter, null, f.webRequest, null);
    assert(result.get!HttpMethod == HttpMethod.valueOf(f.webRequest.getRequest().getMethod()), "Invalid result");
}

version (FlintServletRequestResolverTypes)
{
    import flint.jakarta.servlet.http : PushBuilder;

    /// Spring's anonymous `MockHttpServletRequest` subclass answering `newPushBuilder` with a mock.
    private final class PushBuilderRequest : MockHttpServletRequest
    {
        private PushBuilder pushBuilder;

        this(string method, string requestURI, PushBuilder pushBuilder)
        {
            super(method, requestURI);
            this.pushBuilder = pushBuilder;
        }

        override PushBuilder newPushBuilder()
        {
            return pushBuilder;
        }
    }

    /// Mockito's `mock(PushBuilder.class)`.
    private final class StubPushBuilder : PushBuilder
    {
    }

    @("ServletRequestMethodArgumentResolverTests.pushBuilder")
    unittest
    {
        auto f = setup();
        PushBuilder pushBuilder = new StubPushBuilder();
        f.servletRequest = new PushBuilderRequest("GET", "", pushBuilder);
        auto webRequest = new ServletWebRequest(f.servletRequest, new MockHttpServletResponse());

        MethodParameter pushBuilderParameter = param(Param.p11);
        assert(f.resolver.supportsParameter(pushBuilderParameter), "PushBuilder not supported");

        const result = f.resolver.resolveArgument(pushBuilderParameter, null, webRequest, null);
        assert(result.asObject() is cast(Object) pushBuilder, "Invalid result");
    }
}

/// The parameters of Spring's `supportedParams` method, in declaration order.
private enum Param
{
    p0, /// `ServletRequest`
    p1, /// `MultipartRequest`
    p2, /// `HttpSession`
    p3, /// `Principal`
    p4, /// `Locale`
    p5, /// `InputStream`
    p6, /// `Reader`
    p7, /// `WebRequest`
    p8, /// `TimeZone`
    p9, /// `ZoneId`
    p10, /// `HttpMethod`
    p11, /// `PushBuilder`
}

/// The `ArgumentSpec` Flint AOT writes for a parameter resolved by type.
private ArgumentSpec byType(string name, string type, MergedAnnotation[] annotations = null)
{
    ArgumentSpec spec;
    spec.kind = ArgumentKind.byType;
    spec.name = name;
    spec.type = type;
    spec.required = true;
    spec.annotations = annotations;
    return spec;
}

// Unported parameter types name the types Flint AOT would write for them.
private ArgumentSpec[] supportedParams()
{
    return [
        byType("p0", typeNameOf!ServletRequest), byType("p1", "flint.web.multipart.MultipartRequest"),
        byType("p2", "flint.jakarta.servlet.http.HttpSession"),
        byType("p3", "flint.java.security.Principal"), byType("p4", typeNameOf!Locale),
        byType("p5", typeNameOf!InputStream), byType("p6", "flint.java.io.Reader"),
        byType("p7", typeNameOf!WebRequest), byType("p8", "flint.java.util.TimeZone"),
        byType("p9", typeNameOf!ZoneId), byType("p10", typeNameOf!HttpMethod),
        byType("p11", "flint.jakarta.servlet.http.PushBuilder"),
    ];
}

/// `new MethodParameter(method, index)` for `supportedParams`.
private MethodParameter param(Param index)
{
    return new MethodParameter(supportedParams()[index], index,
            "ServletRequestMethodArgumentResolverTests.supportedParams");
}

/// The test's parameter annotation.
private struct AuthenticationPrincipal
{
}

/// `new MethodParameter(method, 0)` for `supportedParamsWithAnnotatedPrincipal(@AuthenticationPrincipal Principal p)`.
private MethodParameter annotatedPrincipalParam()
{
    auto annotation = MergedAnnotation(typeNameOf!AuthenticationPrincipal, Any.of(AuthenticationPrincipal()), 0);
    return new MethodParameter(byType("p", "flint.java.security.Principal", [annotation]), 0,
            "ServletRequestMethodArgumentResolverTests.supportedParamsWithAnnotatedPrincipal");
}
