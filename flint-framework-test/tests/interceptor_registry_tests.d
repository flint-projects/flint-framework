/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/config/annotation/InterceptorRegistryTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the `@BeforeEach`
fields become a `Fixture` that `setup` returns. The two `LocaleChangeInterceptor`s are hand-written
`StubInterceptor`s, compared by identity. flint.web.servlet has no `ServletRequestPathUtils`, and
`MappedInterceptor` resolves the lookup path from the request URI, so `getInterceptorsForPath` sets the URI
instead of caching a parsed `RequestPath`. The test lives with flint.mock.web's `MockHttpServletRequest` in
flint:framework-test. Cases that need `WebRequestInterceptor` or a custom `PathMatcher` wait behind version gates.
+/
module flint.web.interceptor_registry_tests;

import flint.core : Ordered;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.servlet : HandlerInterceptor;
import flint.web.servlet.config.annotation : InterceptorRegistry;
import flint.web.servlet.handler : MappedInterceptor;

@safe:

/// Stands in for `LocaleChangeInterceptor`.
private final class StubInterceptor : HandlerInterceptor
{
}

private struct Fixture
{
    InterceptorRegistry registry;
    HandlerInterceptor interceptor1;
    HandlerInterceptor interceptor2;
    MockHttpServletRequest request;
    MockHttpServletResponse response;

    HandlerInterceptor[] getInterceptorsForPath(string lookupPath)
    {
        // Spring caches RequestPath.parse(lookupPath, null) under ServletRequestPathUtils.PATH_ATTRIBUTE.
        request.setRequestURI(lookupPath !is null ? lookupPath : "");
        HandlerInterceptor[] result;
        foreach (interceptor; registry.getInterceptors())
        {
            if (auto mappedInterceptor = cast(MappedInterceptor) interceptor)
            {
                if (mappedInterceptor.matches(request))
                    result ~= mappedInterceptor.getInterceptor();
            }
            else
                result ~= interceptor;
        }
        return result;
    }
}

private Fixture setup()
{
    Fixture f;
    f.interceptor1 = new StubInterceptor();
    f.interceptor2 = new StubInterceptor();
    f.request = new MockHttpServletRequest();
    f.response = new MockHttpServletResponse();
    f.registry = new InterceptorRegistry();
    return f;
}

/// AssertJ's `isEqualTo(List.of(...))` and `containsExactly` on interceptor lists, by identity.
private bool sameElements(const HandlerInterceptor[] actual, const HandlerInterceptor[] expected...)
{
    if (actual.length != expected.length)
        return false;
    foreach (i, interceptor; actual)
        if (interceptor !is expected[i])
            return false;
    return true;
}

@("InterceptorRegistryTests.addInterceptor")
unittest
{
    auto f = setup();
    f.registry.addInterceptor(f.interceptor1);
    const interceptors = f.getInterceptorsForPath(null);
    assert(sameElements(interceptors, f.interceptor1));
}

@("InterceptorRegistryTests.addTwoInterceptors")
unittest
{
    auto f = setup();
    f.registry.addInterceptor(f.interceptor1);
    f.registry.addInterceptor(f.interceptor2);
    const interceptors = f.getInterceptorsForPath(null);
    assert(sameElements(interceptors, f.interceptor1, f.interceptor2));
}

@("InterceptorRegistryTests.addInterceptorsWithUrlPatterns")
unittest
{
    auto f = setup();
    f.registry.addInterceptor(f.interceptor1).addPathPatterns("/path1/**").excludePathPatterns("/path1/secret");
    f.registry.addInterceptor(f.interceptor2).addPathPatterns("/path2");

    assert(sameElements(f.getInterceptorsForPath("/path1/test"), f.interceptor1));
    assert(sameElements(f.getInterceptorsForPath("/path2"), f.interceptor2));
    assert(f.getInterceptorsForPath("/path1/secret").length == 0);
}

// flint.web has no WebRequestInterceptor and InterceptorRegistry no addWebRequestInterceptor.
version (FlintWebRequestInterceptor)
{
    import flint.ui : ModelMap;
    import flint.web.context.request : WebRequest, WebRequestInterceptor;
    import flint.web.servlet.handler : WebRequestHandlerInterceptorAdapter;

    @("InterceptorRegistryTests.addWebRequestInterceptor")
    unittest
    {
        auto f = setup();
        auto webInterceptor1 = new TestWebRequestInterceptor();
        f.registry.addWebRequestInterceptor(webInterceptor1);
        auto interceptors = f.getInterceptorsForPath(null);

        assert(interceptors.length == 1);
        verifyWebInterceptor(f, interceptors[0], webInterceptor1);
    }

    @("InterceptorRegistryTests.addWebRequestInterceptors")
    unittest
    {
        auto f = setup();
        auto webInterceptor1 = new TestWebRequestInterceptor();
        auto webInterceptor2 = new TestWebRequestInterceptor();
        f.registry.addWebRequestInterceptor(webInterceptor1);
        f.registry.addWebRequestInterceptor(webInterceptor2);
        auto interceptors = f.getInterceptorsForPath(null);

        assert(interceptors.length == 2);
        verifyWebInterceptor(f, interceptors[0], webInterceptor1);
        verifyWebInterceptor(f, interceptors[1], webInterceptor2);
    }

    @("InterceptorRegistryTests.addWebRequestInterceptorsWithUrlPatterns")
    unittest
    {
        auto f = setup();
        auto webInterceptor1 = new TestWebRequestInterceptor();
        auto webInterceptor2 = new TestWebRequestInterceptor();
        f.registry.addWebRequestInterceptor(webInterceptor1).addPathPatterns("/path1");
        f.registry.addWebRequestInterceptor(webInterceptor2).addPathPatterns("/path2");

        auto interceptors = f.getInterceptorsForPath("/path1");
        assert(interceptors.length == 1);
        verifyWebInterceptor(f, interceptors[0], webInterceptor1);

        interceptors = f.getInterceptorsForPath("/path2");
        assert(interceptors.length == 1);
        verifyWebInterceptor(f, interceptors[0], webInterceptor2);
    }

    private void verifyWebInterceptor(ref Fixture f, HandlerInterceptor interceptor,
            TestWebRequestInterceptor webInterceptor)
    {
        assert(cast(WebRequestHandlerInterceptorAdapter) interceptor !is null);
        interceptor.preHandle(f.request, f.response, null);
        assert(webInterceptor.preHandleInvoked);
    }

    private final class TestWebRequestInterceptor : WebRequestInterceptor
    {
        private bool preHandleInvoked = false;

        void preHandle(WebRequest)
        {
            preHandleInvoked = true;
        }

        void postHandle(WebRequest, ModelMap)
        {
        }

        void afterCompletion(WebRequest, Exception)
        {
        }
    }
}

// flint.web.servlet's InterceptorRegistration and MappedInterceptor have no PathMatcher (pathMatcher/getPathMatcher).
version (FlintPathMatcher)
{
    @("InterceptorRegistryTests.addInterceptorsWithCustomPathMatcher")
    unittest
    {
        import flint.util : AntPathMatcher, PathMatcher;

        auto f = setup();
        PathMatcher pathMatcher = new AntPathMatcher();
        f.registry.addInterceptor(f.interceptor1).addPathPatterns("/path1/**").pathMatcher(pathMatcher);

        auto mappedInterceptor = cast(MappedInterceptor) f.registry.getInterceptors()[0];
        assert(mappedInterceptor.getPathMatcher() is pathMatcher);
    }
}

@("InterceptorRegistryTests.addInterceptorWithExcludePathPatternOnly")
unittest
{
    // SPR-11130
    auto f = setup();
    f.registry.addInterceptor(f.interceptor1).excludePathPatterns("/path1/secret");
    f.registry.addInterceptor(f.interceptor2).addPathPatterns("/path2");

    assert(sameElements(f.getInterceptorsForPath("/path1"), f.interceptor1));
    assert(sameElements(f.getInterceptorsForPath("/path2"), f.interceptor1, f.interceptor2));
    assert(sameElements(f.getInterceptorsForPath("/path1/secret")));
}

@("InterceptorRegistryTests.orderedInterceptors")
unittest
{
    auto f = setup();
    f.registry.addInterceptor(f.interceptor1).order(Ordered.LOWEST_PRECEDENCE);
    f.registry.addInterceptor(f.interceptor2).order(Ordered.HIGHEST_PRECEDENCE);

    const interceptors = f.registry.getInterceptors();
    assert(interceptors.length == 2);

    assert(interceptors[0] is f.interceptor2);
    assert(interceptors[1] is f.interceptor1);
}

@("InterceptorRegistryTests.nonOrderedInterceptors")
unittest
{
    auto f = setup();
    f.registry.addInterceptor(f.interceptor1).order(0);
    f.registry.addInterceptor(f.interceptor2).order(0);

    const interceptors = f.registry.getInterceptors();
    assert(interceptors.length == 2);

    assert(interceptors[0] is f.interceptor1);
    assert(interceptors[1] is f.interceptor2);
}
