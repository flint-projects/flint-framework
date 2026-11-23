/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/filter/OncePerRequestFilterTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. The test filter exposes
the protected `getAlreadyFilteredAttributeName`, which Java's test reaches through its package. Flint adds a case
for a filter that is not an HTTP filter's request, and one for the attribute's removal after the filter ran.
+/
module flint.web.once_per_request_filter_tests;

import flint.engine.aot.any : Any;
import flint.jakarta.servlet : DispatcherType, FilterChain, ServletException, ServletRequest, ServletResponse;
import flint.jakarta.servlet.http : HttpServlet, HttpServletRequest, HttpServletResponse;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.test.web.servlet : MockFilterChain;
import flint.web.filter : OncePerRequestFilter;

@safe:

private enum errorRequestUriAttribute = "jakarta.servlet.error.request_uri";

private final class TestOncePerRequestFilter : OncePerRequestFilter
{
    bool shouldNotFilterFlag;
    bool shouldNotFilterAsyncDispatchFlag = true;
    bool shouldNotFilterErrorDispatchFlag = true;
    bool didFilter;
    bool didFilterNestedErrorDispatch;
    string seenAttribute;

    void setShouldNotFilterErrorDispatch(bool shouldNotFilterErrorDispatch)
    {
        shouldNotFilterErrorDispatchFlag = shouldNotFilterErrorDispatch;
    }

    string alreadyFilteredAttributeName()
    {
        return getAlreadyFilteredAttributeName();
    }

    protected override bool shouldNotFilter(HttpServletRequest request)
    {
        return shouldNotFilterFlag;
    }

    protected override bool shouldNotFilterAsyncDispatch()
    {
        return shouldNotFilterAsyncDispatchFlag;
    }

    protected override bool shouldNotFilterErrorDispatch()
    {
        return shouldNotFilterErrorDispatchFlag;
    }

    protected override void doFilterInternal(HttpServletRequest request,
            HttpServletResponse response, FilterChain filterChain)
    {
        didFilter = true;
        const marker = request.getAttribute(getAlreadyFilteredAttributeName());
        seenAttribute = marker.isNull() ? null : "set";
    }

    protected override void doFilterNestedErrorDispatch(HttpServletRequest request,
            HttpServletResponse response, FilterChain filterChain)
    {
        didFilterNestedErrorDispatch = true;
        super.doFilterNestedErrorDispatch(request, response, filterChain);
    }

    void reset()
    {
        didFilter = false;
        didFilterNestedErrorDispatch = false;
    }
}

private struct Fixture
{
    TestOncePerRequestFilter filter;
    MockHttpServletRequest request;
    MockFilterChain filterChain;
}

private Fixture setup()
{
    Fixture f;
    f.filter = new TestOncePerRequestFilter();
    f.request = new MockHttpServletRequest();
    f.request.setScheme("http");
    f.request.setServerName("localhost");
    f.request.setServerPort(80);
    f.filterChain = new MockFilterChain(new class HttpServlet
        {
    }
);
    return f;
}

private void initErrorDispatch(MockHttpServletRequest request)
{
    request.setDispatcherType(DispatcherType.ERROR);
    request.setAttribute(errorRequestUriAttribute, Any.of("/error"));
}

@("OncePerRequestFilterTests.filterOnce")
unittest
{
    auto f = setup();
    // Already filtered
    f.request.setAttribute(f.filter.alreadyFilteredAttributeName(), Any.of(true));
    f.filter.doFilter(f.request, new MockHttpServletResponse(), f.filterChain);
    assert(!f.filter.didFilter);
    assert(!f.filter.didFilterNestedErrorDispatch);

    // Remove already filtered
    f.request.removeAttribute(f.filter.alreadyFilteredAttributeName());
    f.filter.reset();
    f.filter.doFilter(f.request, new MockHttpServletResponse(), f.filterChain);
    assert(f.filter.didFilter);
    assert(!f.filter.didFilterNestedErrorDispatch);
}

@("OncePerRequestFilterTests.shouldNotFilterErrorDispatch")
unittest
{
    auto f = setup();
    initErrorDispatch(f.request);
    f.filter.doFilter(f.request, new MockHttpServletResponse(), f.filterChain);
    assert(!f.filter.didFilter);
    assert(!f.filter.didFilterNestedErrorDispatch);
}

@("OncePerRequestFilterTests.shouldNotFilterNestedErrorDispatch")
unittest
{
    auto f = setup();
    initErrorDispatch(f.request);
    f.request.setAttribute(f.filter.alreadyFilteredAttributeName(), Any.of(true));
    f.filter.doFilter(f.request, new MockHttpServletResponse(), f.filterChain);
    assert(!f.filter.didFilter);
    assert(!f.filter.didFilterNestedErrorDispatch);
}

// gh-23196
@("OncePerRequestFilterTests.filterNestedErrorDispatch")
unittest
{
    auto f = setup();
    // Opt in for ERROR dispatch
    f.filter.setShouldNotFilterErrorDispatch(false);
    f.request.setAttribute(f.filter.alreadyFilteredAttributeName(), Any.of(true));
    initErrorDispatch(f.request);
    f.filter.doFilter(f.request, new MockHttpServletResponse(), f.filterChain);
    assert(!f.filter.didFilter);
    assert(f.filter.didFilterNestedErrorDispatch);
}

@("Flint: OncePerRequestFilter marks the request while it runs and clears the mark afterwards")
unittest
{
    auto f = setup();
    f.filter.setBeanName("testFilter");
    assert(f.filter.alreadyFilteredAttributeName() == "testFilter.FILTERED");
    f.filter.doFilter(f.request, new MockHttpServletResponse(), f.filterChain);
    assert(f.filter.didFilter && f.filter.seenAttribute == "set");
    assert(f.request.getAttribute("testFilter.FILTERED").isNull());
}

@("Flint: OncePerRequestFilter rejects a request that is not HTTP")
unittest
{
    auto f = setup();
    bool thrown;
    try
        f.filter.doFilter(cast(ServletRequest) null, new MockHttpServletResponse(), f.filterChain);
    catch (ServletException ex)
        thrown = ex.msg == "OncePerRequestFilter only supports HTTP requests";
    assert(thrown);
}
