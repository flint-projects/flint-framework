/++
`org.springframework.test.web.servlet`: MockMvc, server-side tests of Spring MVC without a running server.

Ported from spring-projects/spring-framework v7.1.0,
spring-test/src/main/java/org/springframework/test/web/servlet/ (MockMvc.java, MvcResult.java,
DefaultMvcResult.java, ResultActions.java, RequestBuilder.java, ResultMatcher.java, ResultHandler.java,
TestDispatcherServlet.java) and org/springframework/mock/web/MockFilterChain.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. `ResultMatcher` and `ResultHandler` also take
delegates (R9). Unhandled exceptions propagate out of `perform` as in Spring.
+/
module flint.test.web.servlet;

import flint.engine.aot.any : Any;
import flint.jakarta.servlet : Filter, FilterChain, Servlet, ServletContext, ServletRequest, ServletResponse;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse, MockServletContext;
import flint.web.servlet : DispatcherServlet, DispatcherStrategies, HandlerExecutionChain, HandlerInterceptor,
    ModelAndView;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;

@safe:

/// `RequestBuilder`: builds the `MockHttpServletRequest` of one `perform`.
interface RequestBuilder
{
    /// The request.
    MockHttpServletRequest buildRequest(ServletContext servletContext);
}

/// `ResultMatcher`: an assertion on a result.
interface ResultMatcher
{
    /// Asserts on `result`; throws `AssertionError` on failure.
    void match(MvcResult result);

    /// A matcher over a delegate (R9).
    static ResultMatcher of(void delegate(MvcResult) @safe matcher)
    {
        return new DelegateMatcher(matcher);
    }

    /// Every matcher, in order (Java's `ResultMatcher.matchAll`).
    static ResultMatcher matchAll(ResultMatcher[] matchers...)
    {
        auto all = matchers.dup;
        return of((MvcResult result) {
            foreach (m; all)
                m.match(result);
        });
    }
}

private final class DelegateMatcher : ResultMatcher
{
    private void delegate(MvcResult) @safe matcher;

    this(void delegate(MvcResult) @safe matcher) pure nothrow @nogc
    {
        this.matcher = matcher;
    }

    void match(MvcResult result)
    {
        matcher(result);
    }
}

/// `ResultHandler`: an action on a result (printing, logging).
interface ResultHandler
{
    /// Handles `result`.
    void handle(MvcResult result);
}

/// `MvcResult`: the request, the response, and what Spring MVC did.
interface MvcResult
{
    /// The request.
    MockHttpServletRequest getRequest();

    /// The response.
    MockHttpServletResponse getResponse();

    /// The handler that served the request, or `null`.
    Object getHandler();

    /// The interceptors around the handler.
    HandlerInterceptor[] getInterceptors();

    /// The model and view, or `null`.
    ModelAndView getModelAndView();

    /// The exception a `HandlerExceptionResolver` resolved, or `null`.
    Exception getResolvedException();
}

/// `DefaultMvcResult`.
class DefaultMvcResult : MvcResult
{
    private MockHttpServletRequest request;
    private MockHttpServletResponse response;
    package(flint) Object handler;
    package(flint) HandlerInterceptor[] interceptors;
    package(flint) ModelAndView modelAndView;
    package(flint) Exception resolvedException;

    ///
    this(MockHttpServletRequest request, MockHttpServletResponse response) pure nothrow @nogc
    {
        this.request = request;
        this.response = response;
    }

    MockHttpServletRequest getRequest()
    {
        return request;
    }

    MockHttpServletResponse getResponse()
    {
        return response;
    }

    Object getHandler()
    {
        return handler;
    }

    HandlerInterceptor[] getInterceptors()
    {
        return interceptors;
    }

    ModelAndView getModelAndView()
    {
        return modelAndView;
    }

    Exception getResolvedException()
    {
        return resolvedException;
    }
}

/// `ResultActions`: expectations and actions on a performed request.
interface ResultActions
{
    /// Asserts `matcher`.
    ResultActions andExpect(ResultMatcher matcher);

    /// Asserts every matcher.
    ResultActions andExpectAll(ResultMatcher[] matchers...);

    /// Runs `handler`.
    ResultActions andDo(ResultHandler handler);

    /// The result.
    MvcResult andReturn();
}

private final class DefaultResultActions : ResultActions
{
    private MvcResult result;

    this(MvcResult result) pure nothrow @nogc
    {
        this.result = result;
    }

    ResultActions andExpect(ResultMatcher matcher)
    {
        matcher.match(result);
        return this;
    }

    ResultActions andExpectAll(ResultMatcher[] matchers...)
    {
        // Spring's SoftAssertions-like behavior: run every matcher, then report the first failure.
        Exception first;
        foreach (m; matchers)
        {
            try
                m.match(result);
            catch (Exception e)
                if (first is null)
                    first = e;
        }
        if (first !is null)
            throw first;
        return this;
    }

    ResultActions andDo(ResultHandler handler)
    {
        handler.handle(result);
        return this;
    }

    MvcResult andReturn()
    {
        return result;
    }
}

/// `TestDispatcherServlet`: a `DispatcherServlet` that records the handler and the resolved exception.
class TestDispatcherServlet : DispatcherServlet
{
    private DefaultMvcResult current;

    ///
    this(DispatcherStrategies strategies)
    {
        super(strategies);
    }

    package(flint) void setCurrent(DefaultMvcResult result) pure nothrow @nogc
    {
        current = result;
    }

    protected override HandlerExecutionChain getHandler(HttpServletRequest request)
    {
        auto chain = super.getHandler(request);
        if (current !is null && chain !is null)
        {
            current.handler = chain.getHandler();
            current.interceptors = chain.getInterceptorList();
        }
        return chain;
    }

    protected override ModelAndView processHandlerException(HttpServletRequest request, HttpServletResponse response,
            Object handler, Exception ex)
    {
        auto mav = super.processHandlerException(request, response, handler, ex);
        if (current !is null)
        {
            current.resolvedException = ex;
            current.modelAndView = mav;
        }
        return mav;
    }
}

/// `MockFilterChain`: runs filters, then the servlet.
class MockFilterChain : FilterChain
{
    private Filter[] filters;
    private Servlet servlet;
    private size_t position;

    ///
    this(Servlet servlet, Filter[] filters...)
    {
        this.servlet = servlet;
        this.filters = filters.dup;
    }

    void doFilter(ServletRequest request, ServletResponse response)
    {
        if (position < filters.length)
        {
            auto filter = filters[position++];
            filter.doFilter(request, response, this);
        }
        else if (servlet !is null)
            servlet.service(request, response);
    }
}

/// `MockMvc`: the entry point of server-side Spring MVC tests.
final class MockMvc
{
    private TestDispatcherServlet servlet;
    private Filter[] filters;
    private MockServletContext servletContext;
    private RequestBuilder defaultRequestBuilder;
    private ResultMatcher[] defaultResultMatchers;
    private ResultHandler[] defaultResultHandlers;

    package(flint) this(TestDispatcherServlet servlet, Filter[] filters)
    {
        this.servlet = servlet;
        this.filters = filters;
        servletContext = new MockServletContext;
    }

    package(flint) void setGlobalResultMatchers(ResultMatcher[] matchers) pure nothrow @nogc
    {
        defaultResultMatchers = matchers;
    }

    package(flint) void setGlobalResultHandlers(ResultHandler[] handlers) pure nothrow @nogc
    {
        defaultResultHandlers = handlers;
    }

    /// The servlet that serves requests.
    DispatcherServlet getDispatcherServlet() pure nothrow @nogc
    {
        return servlet;
    }

    /// Performs a request and returns the result actions.
    ResultActions perform(RequestBuilder requestBuilder)
    {
        auto request = requestBuilder.buildRequest(servletContext);
        auto response = new MockHttpServletResponse;
        auto result = new DefaultMvcResult(request, response);
        servlet.setCurrent(result);
        scope (exit)
            servlet.setCurrent(null);
        auto chain = new MockFilterChain(servlet, filters);
        chain.doFilter(request, response);
        auto actions = new DefaultResultActions(result);
        foreach (matcher; defaultResultMatchers)
            actions.andExpect(matcher);
        foreach (handler; defaultResultHandlers)
            actions.andDo(handler);
        return actions;
    }
}
