/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/method/annotation/CookieValueMethodArgumentResolverTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setUp` returns. The `SynthesizingMethodParameter`s that reflection finds on `params` are
built from the `ArgumentSpec`s Flint AOT writes for them. The port has no `AbstractCookieValueMethodArgumentResolver`
(its `CookieValueMethodArgumentResolver` is the servlet one), so the test resolver extends that and overrides
`resolveName`. The test lives with flint.mock.web in flint:framework-test, which depends on flint:web.
+/
module flint.web.cookie_value_method_argument_resolver_tests;

import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : MergedAnnotation;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.engine.aot.name : typeNameOf;
import flint.jakarta.servlet.http : Cookie;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.bind : ServletRequestBindingException;
import flint.web.bind.annotation : CookieValue, ValueConstants;
import flint.web.context.request : NativeWebRequest, ServletWebRequest;
import flint.web.method.annotation : CookieValueMethodArgumentResolver;

@safe:

private struct Fixture
{
    CookieValueMethodArgumentResolver resolver;
    MethodParameter paramNamedCookie;
    MethodParameter paramNamedDefaultValueString;
    MethodParameter paramString;
    ServletWebRequest webRequest;
    MockHttpServletRequest request;
}

private Fixture setUp()
{
    Fixture f;
    f.resolver = new TestCookieValueMethodArgumentResolver();

    f.paramNamedCookie = param(0, "param1", typeNameOf!Cookie, cookieValue("name"));
    f.paramNamedDefaultValueString = param(1, "param2", "string", cookieValue("name", "bar"));
    f.paramString = plainParam(2, "param3", "string");

    f.request = new MockHttpServletRequest();
    f.webRequest = new ServletWebRequest(f.request, new MockHttpServletResponse());
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
private MethodParameter param(int index, string parameterName, string type, CookieValue annotation)
{
    ArgumentSpec spec;
    spec.kind = ArgumentKind.cookieValue;
    spec.name = annotation.name.length != 0 ? annotation.name : parameterName;
    spec.type = type;
    spec.required = annotation.required;
    spec.defaultValue = annotation.defaultValue;
    spec.annotations = [MergedAnnotation(typeNameOf!CookieValue, Any.of(annotation), 0)];
    return new MethodParameter(spec, index, "CookieValueMethodArgumentResolverTests.params");
}

/// Parameter `index` of `params` without a binding annotation: Flint AOT makes a simple type a request parameter.
private MethodParameter plainParam(int index, string parameterName, string type)
{
    ArgumentSpec spec;
    spec.kind = ArgumentKind.requestParam;
    spec.name = parameterName;
    spec.type = type;
    spec.defaultValue = ValueConstants.DEFAULT_NONE;
    return new MethodParameter(spec, index, "CookieValueMethodArgumentResolverTests.params");
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

@("CookieValueMethodArgumentResolverTests.supportsParameter")
unittest
{
    auto f = setUp();
    assert(f.resolver.supportsParameter(f.paramNamedCookie), "Cookie parameter not supported");
    assert(f.resolver.supportsParameter(f.paramNamedDefaultValueString), "Cookie string parameter not supported");
    assert(!f.resolver.supportsParameter(f.paramString), "non-@CookieValue parameter supported");
}

@("CookieValueMethodArgumentResolverTests.resolveCookieDefaultValue")
unittest
{
    auto f = setUp();
    const result = f.resolver.resolveArgument(f.paramNamedDefaultValueString, null, f.webRequest, null);

    assert(result.holds!string);
    assert(result.get!string == "bar", "Invalid result");
}

@("CookieValueMethodArgumentResolverTests.notFound")
unittest
{
    auto f = setUp();
    assert(thrown!ServletRequestBindingException(() {
            f.resolver.resolveArgument(f.paramNamedCookie, null, f.webRequest, null);
        }) !is null);
}

private final class TestCookieValueMethodArgumentResolver : CookieValueMethodArgumentResolver
{
    protected override Any resolveName(string name, MethodParameter parameter, NativeWebRequest request)
    {
        return Any.init;
    }
}
