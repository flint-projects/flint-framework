/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/handler/MappedInterceptorTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; each
`@PathPatternsParameterizedTest` is one unittest that loops over the named request factories of
`PathPatternsTestUtils.requestArguments()`. flint.web.servlet has no `ServletRequestPathUtils` or `UrlPathHelper`
and `MappedInterceptor` resolves the lookup path from the request itself, so both factories only build the request.
The `LocaleChangeInterceptor` delegate and Mockito's `HandlerInterceptor` mocks are a hand-written
`StubInterceptor` that counts its calls; mocked requests, responses, models and exceptions are flint.mock.web
objects and plain instances. The test lives with flint.mock.web's `MockHttpServletRequest` in flint:framework-test.
Cases that need partial-segment or mid-pattern `**` path patterns, a custom `PathMatcher` or HTTP method
conditions wait behind version gates.
+/
module flint.web.mapped_interceptor_tests;

import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.servlet : HandlerInterceptor, ModelAndView;
import flint.web.servlet.handler : MappedInterceptor;

@safe:

private alias RequestFactory = MockHttpServletRequest delegate(string path) @safe;

private struct NamedFactory
{
    string name;
    RequestFactory factory;
}

/// `PathPatternsTestUtils.requestArguments()`.
private NamedFactory[] pathPatternsArguments()
{
    // Spring also calls ServletRequestPathUtils.parseAndCache or UrlPathHelper.resolveAndCacheLookupPath here.
    return [
        NamedFactory("ServletRequestPathUtils", (path) => new MockHttpServletRequest("GET", path)),
        NamedFactory("UrlPathHelper", (path) => new MockHttpServletRequest("GET", path)),
    ];
}

/// Stands in for `LocaleChangeInterceptor` and Mockito's `mock(HandlerInterceptor.class)`: counts its calls.
private final class StubInterceptor : HandlerInterceptor
{
    int preHandleCalls;
    int postHandleCalls;
    int afterCompletionCalls;

    override bool preHandle(HttpServletRequest, HttpServletResponse, Object)
    {
        preHandleCalls++;
        return true;
    }

    override void postHandle(HttpServletRequest, HttpServletResponse, Object, ModelAndView)
    {
        postHandleCalls++;
    }

    override void afterCompletion(HttpServletRequest, HttpServletResponse, Object, Exception)
    {
        afterCompletionCalls++;
    }
}

/// The class's `static final LocaleChangeInterceptor delegate`.
private HandlerInterceptor delegate_()
{
    return new StubInterceptor();
}

@("MappedInterceptorTests.noPatterns")
unittest
{
    foreach (named; pathPatternsArguments())
    {
        auto interceptor = new MappedInterceptor(null, null, delegate_());
        assert(interceptor.matches(named.factory("/foo")), named.name);
    }
}

@("MappedInterceptorTests.includePattern")
unittest
{
    foreach (named; pathPatternsArguments())
    {
        auto interceptor = new MappedInterceptor(["/foo/*"], null, delegate_());

        assert(interceptor.matches(named.factory("/foo/bar")), named.name);
        assert(!interceptor.matches(named.factory("/bar/foo")), named.name);
    }
}

// Segments that mix literal text with `*` (Spring's RegexPathElement) are not ported; the parser rejects them.
version (FlintPathPatternPartialSegments)
{
    @("MappedInterceptorTests.includePatternWithMatrixVariables")
    unittest
    {
        foreach (named; pathPatternsArguments())
        {
            auto interceptor = new MappedInterceptor(["/foo*/*"], null, delegate_());
            assert(interceptor.matches(named.factory("/foo;q=1/bar;s=2")), named.name);
        }
    }
}

@("MappedInterceptorTests.excludePattern")
unittest
{
    foreach (named; pathPatternsArguments())
    {
        auto interceptor = new MappedInterceptor(null, ["/admin/**"], delegate_());

        assert(interceptor.matches(named.factory("/foo")), named.name);
        assert(!interceptor.matches(named.factory("/admin/foo")), named.name);
    }
}

@("MappedInterceptorTests.includeAndExcludePatterns")
unittest
{
    foreach (named; pathPatternsArguments())
    {
        auto interceptor = new MappedInterceptor(["/**"], ["/admin/**"], delegate_());

        assert(interceptor.matches(named.factory("/foo")), named.name);
        assert(!interceptor.matches(named.factory("/admin/foo")), named.name);
    }
}

// `**` followed by more pattern elements (allowed since Spring 7.0) is not ported; the parser accepts it only last.
version (FlintPathPatternLeadingCatchAll)
{
    @("MappedInterceptorTests.includePatternWithFallbackOnPathMatcher")
    unittest
    {
        // gh-26690
        foreach (named; pathPatternsArguments())
        {
            auto interceptor = new MappedInterceptor(["/path1/**/path2"], null, delegate_());

            assert(interceptor.matches(named.factory("/path1/foo/bar/path2")), named.name);
            assert(!interceptor.matches(named.factory("/path1/foo/bar/path3")), named.name);
            assert(!interceptor.matches(named.factory("/path3/foo/bar/path2")), named.name);
        }
    }
}

// flint.web.servlet's MappedInterceptor matches parsed PathPatterns only (no PathMatcher, no setPathMatcher).
version (FlintPathMatcher)
{
    import flint.java.util : Comparator, Map;
    import flint.util : PathMatcher;

    @("MappedInterceptorTests.customPathMatcher")
    unittest
    {
        foreach (named; pathPatternsArguments())
        {
            auto interceptor = new MappedInterceptor(["/foo/[0-9]*"], null, delegate_());
            interceptor.setPathMatcher(new TestPathMatcher());

            assert(interceptor.matches(named.factory("/foo/123")), named.name);
            assert(!interceptor.matches(named.factory("/foo/bar")), named.name);
        }
    }

    private final class TestPathMatcher : PathMatcher
    {
        bool isPattern(string)
        {
            return false;
        }

        bool match(string pattern, string path)
        {
            import std.regex : matchFirst, regex;

            auto m = matchFirst(path, regex("^(?:" ~ pattern ~ ")$"));
            return !m.empty;
        }

        bool matchStart(string, string)
        {
            return false;
        }

        string extractPathWithinPattern(string, string)
        {
            return null;
        }

        Map!(string, string) extractUriTemplateVariables(string, string)
        {
            return null;
        }

        Comparator!string getPatternComparator(string)
        {
            return null;
        }

        string combine(string, string)
        {
            return null;
        }
    }
}

// flint.web.servlet's MappedInterceptor has no HTTP method conditions (the six-argument constructor).
version (FlintMappedInterceptorHttpMethods)
{
    import flint.http : HttpMethod;

    @("MappedInterceptorTests.includeMultipleMethods")
    unittest
    {
        testHttpMethods([HttpMethod.GET, HttpMethod.POST], [], "GET", "POST");
    }

    @("MappedInterceptorTests.excludeMultipleMethods")
    unittest
    {
        testHttpMethods([], [HttpMethod.GET, HttpMethod.POST, HttpMethod.OPTIONS], "HEAD", "PUT",
                "DELETE", "TRACE", "PATCH", "QUERY");
    }

    private void testHttpMethods(HttpMethod[] include, HttpMethod[] exclude, string[] expected...)
    {
        import std.algorithm.searching : canFind;

        auto interceptor = new MappedInterceptor(null, null, include, exclude, delegate_(), null);
        foreach (httpMethod; HttpMethod.values())
        {
            const matches = expected.canFind(httpMethod.name());
            assert(interceptor.matches(requestWithMethod(httpMethod.name())) == matches,
                    "Expected " ~ httpMethod.name() ~ " to " ~ (matches ? "" : "not ") ~ "match");
        }
    }

    private MockHttpServletRequest requestWithMethod(string method)
    {
        auto request = new MockHttpServletRequest();
        request.setRequestURI("/some/path");
        request.setMethod(method);
        return request;
    }

    @("MappedInterceptorTests.includePatternAndHttMethods")
    unittest
    {
        foreach (named; pathPatternsArguments())
        {
            auto getInterceptor = new MappedInterceptor(["/foo/*"], null, [HttpMethod.GET], null, delegate_(), null);

            auto putInterceptor = new MappedInterceptor(["/foo/*"], null, [HttpMethod.PUT], null, delegate_(), null);

            assert(getInterceptor.matches(named.factory("/foo/bar")), named.name);
            assert(!putInterceptor.matches(named.factory("/foo/bar")), named.name);
        }
    }
}

@("MappedInterceptorTests.preHandle")
unittest
{
    auto delegate_ = new StubInterceptor();

    new MappedInterceptor(null, null, delegate_).preHandle(new MockHttpServletRequest(),
            new MockHttpServletResponse(), null);

    assert(delegate_.preHandleCalls == 1);
}

@("MappedInterceptorTests.postHandle")
unittest
{
    auto delegate_ = new StubInterceptor();

    new MappedInterceptor(null, null, delegate_).postHandle(new MockHttpServletRequest(),
            new MockHttpServletResponse(), null, new ModelAndView());

    assert(delegate_.postHandleCalls == 1);
}

@("MappedInterceptorTests.afterCompletion")
unittest
{
    auto delegate_ = new StubInterceptor();

    new MappedInterceptor(null, null, delegate_).afterCompletion(new MockHttpServletRequest(),
            new MockHttpServletResponse(), null, new Exception(""));

    assert(delegate_.afterCompletionCalls == 1);
}
