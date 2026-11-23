/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/HandlerExecutionChainTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test fields become a
`Fixture` that `setup` returns. Mockito's `AsyncHandlerInterceptor` mocks are hand-written `StubInterceptor`s that
record their calls; `given(...).willReturn/willThrow` sets the stub's answer and `verify` counts matching calls.
The test lives with flint.mock.web's `MockHttpServletRequest` and `MockHttpServletResponse` in
flint:framework-test. The async case waits behind a version gate.
+/
module flint.web.handler_execution_chain_tests;

import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.servlet : HandlerExecutionChain, HandlerInterceptor, ModelAndView;

@safe:

/// One recorded interceptor call, compared by identity as Mockito compares mock arguments.
private struct Call
{
    string method;
    Object request;
    Object response;
    Object handler;
    ModelAndView mav;
    Exception ex;
}

/// Mockito's `mock(AsyncHandlerInterceptor.class)`: answers `preHandle` as told and records every call.
private final class StubInterceptor : HandlerInterceptor
{
    bool preHandleResult;
    Exception preHandleException;
    Call[] calls;

    override bool preHandle(HttpServletRequest request, HttpServletResponse response, Object handler)
    {
        calls ~= Call("preHandle", cast(Object) request, cast(Object) response, handler);
        if (preHandleException !is null)
            throw preHandleException;
        return preHandleResult;
    }

    override void postHandle(HttpServletRequest request, HttpServletResponse response, Object handler,
            ModelAndView modelAndView)
    {
        calls ~= Call("postHandle", cast(Object) request, cast(Object) response, handler, modelAndView);
    }

    override void afterCompletion(HttpServletRequest req, HttpServletResponse res, Object handler, Exception ex)
    {
        calls ~= Call("afterCompletion", cast(Object) req, cast(Object) res, handler, null, ex);
    }

    /// How many recorded calls equal `expected`.
    size_t count(Call expected) const
    {
        size_t n;
        foreach (c; calls)
            if (c.method == expected.method && c.request is expected.request
                    && c.response is expected.response && c.handler is expected.handler
                    && c.mav is expected.mav && c.ex is expected.ex)
                n++;
        return n;
    }
}

private struct Fixture
{
    Object handler;
    StubInterceptor interceptor1;
    StubInterceptor interceptor2;
    StubInterceptor interceptor3;
    HandlerExecutionChain chain;
    MockHttpServletRequest request;
    MockHttpServletResponse response;

    /// Mockito's `verify(interceptor).postHandle(request, response, handler, mav)`.
    void verifyPostHandle(StubInterceptor interceptor, ModelAndView mav)
    {
        assert(interceptor.count(Call("postHandle", request, response, handler, mav)) == 1);
    }

    /// Mockito's `verify(interceptor).afterCompletion(request, response, handler, ex)`.
    void verifyAfterCompletion(StubInterceptor interceptor, Exception ex)
    {
        assert(interceptor.count(Call("afterCompletion", request, response, handler, null, ex)) == 1);
    }
}

private Fixture setup()
{
    Fixture f;
    f.handler = new Object();
    f.interceptor1 = new StubInterceptor();
    f.interceptor2 = new StubInterceptor();
    f.interceptor3 = new StubInterceptor();
    f.chain = new HandlerExecutionChain(f.handler, [f.interceptor1, f.interceptor2, f.interceptor3]);
    f.request = new MockHttpServletRequest();
    f.response = new MockHttpServletResponse();
    return f;
}

@("HandlerExecutionChainTests.successScenario")
unittest
{
    auto f = setup();
    auto mav = new ModelAndView();

    f.interceptor1.preHandleResult = true;
    f.interceptor2.preHandleResult = true;
    f.interceptor3.preHandleResult = true;

    f.chain.applyPreHandle(f.request, f.response);
    f.chain.applyPostHandle(f.request, f.response, mav);
    f.chain.triggerAfterCompletion(f.request, f.response, null);

    f.verifyPostHandle(f.interceptor1, mav);
    f.verifyPostHandle(f.interceptor2, mav);
    f.verifyPostHandle(f.interceptor3, mav);

    f.verifyAfterCompletion(f.interceptor3, null);
    f.verifyAfterCompletion(f.interceptor2, null);
    f.verifyAfterCompletion(f.interceptor1, null);
}

// flint.web.servlet has no AsyncHandlerInterceptor and HandlerExecutionChain no applyAfterConcurrentHandlingStarted.
version (FlintAsyncHandlerInterceptor)
{
    @("HandlerExecutionChainTests.successAsyncScenario")
    unittest
    {
        auto f = setup();
        f.interceptor1.preHandleResult = true;
        f.interceptor2.preHandleResult = true;
        f.interceptor3.preHandleResult = true;

        f.chain.applyPreHandle(f.request, f.response);
        f.chain.applyAfterConcurrentHandlingStarted(f.request, f.response);
        f.chain.triggerAfterCompletion(f.request, f.response, null);

        foreach (interceptor; [f.interceptor1, f.interceptor2, f.interceptor3])
            assert(interceptor.count(Call("afterConcurrentHandlingStarted", f.request, f.response, f.handler)) == 1);
    }
}

@("HandlerExecutionChainTests.earlyExitInPreHandle")
unittest
{
    auto f = setup();
    f.interceptor1.preHandleResult = true;
    f.interceptor2.preHandleResult = false;

    f.chain.applyPreHandle(f.request, f.response);

    f.verifyAfterCompletion(f.interceptor1, null);
}

@("HandlerExecutionChainTests.exceptionBeforePreHandle")
unittest
{
    auto f = setup();
    f.chain.triggerAfterCompletion(f.request, f.response, null);
    assert(f.interceptor1.calls.length == 0);
    assert(f.interceptor2.calls.length == 0);
    assert(f.interceptor3.calls.length == 0);
}

@("HandlerExecutionChainTests.exceptionDuringPreHandle")
unittest
{
    auto f = setup();
    auto ex = new Exception("");

    f.interceptor1.preHandleResult = true;
    f.interceptor2.preHandleException = ex;

    try
        f.chain.applyPreHandle(f.request, f.response);
    catch (Exception actual)
        assert(actual is ex);
    f.chain.triggerAfterCompletion(f.request, f.response, ex);

    f.verifyAfterCompletion(f.interceptor1, ex);
    assert(f.interceptor3.count(Call("preHandle", f.request, f.response, f.handler)) == 0);
}

@("HandlerExecutionChainTests.exceptionAfterPreHandle")
unittest
{
    auto f = setup();
    auto ex = new Exception("");

    f.interceptor1.preHandleResult = true;
    f.interceptor2.preHandleResult = true;
    f.interceptor3.preHandleResult = true;

    f.chain.applyPreHandle(f.request, f.response);
    f.chain.triggerAfterCompletion(f.request, f.response, ex);

    f.verifyAfterCompletion(f.interceptor3, ex);
    f.verifyAfterCompletion(f.interceptor2, ex);
    f.verifyAfterCompletion(f.interceptor1, ex);
}
