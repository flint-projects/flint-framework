/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
ServletCookieValueMethodArgumentResolverTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` returns. The `SynthesizingMethodParameter`s that reflection finds on `params` are
built from the `ArgumentSpec`s Flint AOT writes for them. The port's servlet resolver is flint.web's
`CookieValueMethodArgumentResolver`, which takes no bean factory. The test lives with flint.mock.web in
flint:framework-test, which depends on flint:web. A case that needs an unported method is gated by version.
+/
module flint.web.servlet_cookie_value_method_argument_resolver_tests;

import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : MergedAnnotation;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.engine.aot.name : typeNameOf;
import flint.jakarta.servlet.http : Cookie;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.bind.annotation : CookieValue, ValueConstants;
import flint.web.context.request : ServletWebRequest;
import flint.web.method.annotation : CookieValueMethodArgumentResolver;

@safe:

private struct Fixture
{
    CookieValueMethodArgumentResolver resolver;
    MockHttpServletRequest request;
    ServletWebRequest webRequest;
    MethodParameter cookieParameter;
    MethodParameter cookieStringParameter;
}

private Fixture setup()
{
    Fixture f;
    f.resolver = new CookieValueMethodArgumentResolver();
    f.request = new MockHttpServletRequest();
    f.webRequest = new ServletWebRequest(f.request, new MockHttpServletResponse());

    f.cookieParameter = param(0, typeNameOf!Cookie, cookieValue("name"));
    f.cookieStringParameter = param(1, "string", cookieValue("name", "bar"));
    return f;
}

/// `@CookieValue` as Flint AOT merges it: `name` and its alias `value` agree.
private CookieValue cookieValue(string name, string defaultValue = ValueConstants.DEFAULT_NONE)
{
    CookieValue annotation;
    annotation.name = name;
    annotation.value = name;
    annotation.defaultValue = defaultValue;
    return annotation;
}

/// Parameter `index` of `params`, from the `ArgumentSpec` Flint AOT writes for a `@CookieValue` parameter.
private MethodParameter param(int index, string type, CookieValue annotation)
{
    ArgumentSpec spec;
    spec.kind = ArgumentKind.cookieValue;
    spec.name = annotation.name;
    spec.type = type;
    spec.required = annotation.required;
    spec.defaultValue = annotation.defaultValue;
    spec.annotations = [MergedAnnotation(typeNameOf!CookieValue, Any.of(annotation), 0)];
    return new MethodParameter(spec, index, "ServletCookieValueMethodArgumentResolverTests.params");
}

@("ServletCookieValueMethodArgumentResolverTests.resolveCookieArgument")
unittest
{
    auto f = setup();
    auto expected = new Cookie("name", "foo");
    f.request.setCookies(expected);

    auto result = cast(Cookie) f.resolver.resolveArgument(f.cookieParameter, null, f.webRequest, null).asObject();
    assert(result is expected, "Invalid result");
}

@("ServletCookieValueMethodArgumentResolverTests.resolveCookieStringArgument")
unittest
{
    auto f = setup();
    auto cookie = new Cookie("name", "foo");
    f.request.setCookies(cookie);

    const result = f.resolver.resolveArgument(f.cookieStringParameter, null, f.webRequest, null).get!string;
    assert(result == cookie.getValue(), "Invalid result");
}

// The port's cookie resolver has no setUrlDecode (Spring's UrlPathHelper decoding switch).
version (FlintWebCookieUrlDecode)
{
    // gh-26989
    @("ServletCookieValueMethodArgumentResolverTests.resolveCookieWithEncodingTurnedOff")
    unittest
    {
        auto f = setup();
        auto cookie = new Cookie("name", "Tl=Q/0AUSOx[n)2z4(t]20FZv#?[Ge%H");
        f.request.setCookies(cookie);

        f.resolver.setUrlDecode(false);
        const result = f.resolver.resolveArgument(f.cookieStringParameter, null, f.webRequest, null).get!string;

        assert(result == cookie.getValue(), "Invalid result");
    }
}
