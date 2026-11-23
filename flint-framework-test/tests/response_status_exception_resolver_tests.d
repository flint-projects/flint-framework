/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/annotation/ResponseStatusExceptionResolverTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` returns. The resolver reads `@ResponseStatus` from the Flint AOT descriptors of the
exception classes (`descriptorOf`) instead of reflection; it has no warn log category to set. Beans'
`TypeMismatchException` is flint.web's, with the required type by name, and `ITestBean` is a private interface.
The test lives with flint.mock.web in flint:framework-test. Cases that need unported classes or behave differently
are gated by version.
+/
module flint.web.response_status_exception_resolver_tests;

import flint.core.annotation : AliasFor;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.http : HttpHeaders, HttpMethod, HttpStatus;
import flint.java.lang : classOf;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.bind.annotation : ResponseStatus;
import flint.web.method.annotation : TypeMismatchException;
import flint.web.server : ResponseStatusException;
import flint.web.servlet : ModelAndView;
import flint.web.servlet.mvc.annotation : ResponseStatusExceptionResolver;

@safe:

private struct Fixture
{
    ResponseStatusExceptionResolver exceptionResolver;
    MockHttpServletRequest request;
    MockHttpServletResponse response;
}

private Fixture setup()
{
    Fixture f;
    auto descriptors = DescriptorTable.withBuiltins();
    descriptors.add(descriptorOf!StatusCodeException());
    descriptors.add(descriptorOf!ServerErrorException());
    descriptors.add(descriptorOf!StatusCodeAndReasonException());
    descriptors.add(descriptorOf!StatusCodeAndReasonMessageException());
    descriptors.add(descriptorOf!StatusCodeFromComposedResponseStatusException());
    f.exceptionResolver = new ResponseStatusExceptionResolver(descriptors);
    f.request = new MockHttpServletRequest("GET", "");
    f.response = new MockHttpServletResponse();
    return f;
}

@("ResponseStatusExceptionResolverTests.statusCode")
unittest
{
    auto f = setup();
    auto ex = new StatusCodeException();
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assertResolved(f, mav, 400, null);
}

@("ResponseStatusExceptionResolverTests.statusCodeFromComposedResponseStatus")
unittest
{
    auto f = setup();
    auto ex = new StatusCodeFromComposedResponseStatusException();
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assertResolved(f, mav, 400, null);
}

@("ResponseStatusExceptionResolverTests.statusCodeAndReason")
unittest
{
    auto f = setup();
    auto ex = new StatusCodeAndReasonException();
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assertResolved(f, mav, 410, "You suck!");
}

// ResponseStatusExceptionResolver has no setMessageSource: reasons are not resolved as message codes.
version (FlintExceptionResolverMessageSource)
{
    @("ResponseStatusExceptionResolverTests.statusCodeAndReasonMessage")
    unittest
    {
        import flint.context.i18n : LocaleContextHolder;
        import flint.context.support : StaticMessageSource;
        import flint.java.util : Locale;

        auto f = setup();
        Locale locale = Locale.CHINESE;
        LocaleContextHolder.setLocale(locale);
        scope (exit)
            LocaleContextHolder.resetLocaleContext();
        auto messageSource = new StaticMessageSource();
        messageSource.addMessage("gone.reason", locale, "Gone reason message");
        f.exceptionResolver.setMessageSource(messageSource);

        auto ex = new StatusCodeAndReasonMessageException();
        f.exceptionResolver.resolveException(f.request, f.response, null, ex);
        assert(f.response.getErrorMessage() == "Gone reason message", "Invalid status reason");
    }
}

@("ResponseStatusExceptionResolverTests.notAnnotated")
unittest
{
    auto f = setup();
    auto ex = new Exception(null);
    f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav is null, "ModelAndView returned");
}

@("ResponseStatusExceptionResolverTests.nestedException")
unittest
{
    auto f = setup();
    Exception cause = new StatusCodeAndReasonMessageException();
    auto ex = new TypeMismatchException(Any.of("value"), typeNameOf!ITestBean, cause);
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assertResolved(f, mav, 410, "gone.reason");
}

@("ResponseStatusExceptionResolverTests.responseStatusException")
unittest
{
    auto f = setup();
    auto ex = new ResponseStatusException(HttpStatus.BAD_REQUEST);
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assertResolved(f, mav, 400, null);
}

@("ResponseStatusExceptionResolverTests.responseStatusExceptionWithReason")
unittest
{
    auto f = setup();
    auto ex = new ResponseStatusException(HttpStatus.BAD_REQUEST, "The reason");
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assertResolved(f, mav, 400, "The reason");
}

// flint.web has not ported the WebFlux exceptions of org.springframework.web.server (MethodNotAllowedException).
version (FlintWebReactiveExceptions)
{
    @("ResponseStatusExceptionResolverTests.responseStatusExceptionWithHeaders")
    unittest
    {
        import flint.web.server : MethodNotAllowedException;

        auto f = setup();
        Exception ex = new MethodNotAllowedException(HttpMethod.GET, [
            HttpMethod.POST, HttpMethod.PUT
        ]);

        ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);

        assertResolved(f, mav, 405, "Request method 'GET' is not supported.");
        assert(f.response.getHeader(HttpHeaders.ALLOW) == "POST,PUT");
    }
}

// No observation support: ServerHttpObservationFilter and the ObservedExchange test fixture are not ported.
version (FlintWebObservation)
{
    import flint.web.servlet.mvc : ObservedExchange;

    @("ResponseStatusExceptionResolverTests.serverErrorResponseStatusExceptionIsRecordedOnObservation")
    unittest
    {
        auto f = setup();
        auto ex = new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE);

        ObservedExchange!ModelAndView exchange = observe(f, ex);
        assertResolved(f, exchange.result(), 503, null);
        assert(exchange.error() is ex);
    }

    @("ResponseStatusExceptionResolverTests.serverErrorResponseStatusIsRecordedOnObservation")
    unittest
    {
        auto f = setup();
        auto ex = new ServerErrorException();

        ObservedExchange!ModelAndView exchange = observe(f, ex);
        assertResolved(f, exchange.result(), 500, null);
        assert(exchange.error() is ex);
    }

    @("ResponseStatusExceptionResolverTests.nestedServerErrorResponseStatusIsRecordedOnObservation")
    unittest
    {
        auto f = setup();
        Exception cause = new ServerErrorException();
        auto ex = new TypeMismatchException(Any.of("value"), typeNameOf!ITestBean, cause);

        ObservedExchange!ModelAndView exchange = observe(f, ex);
        assertResolved(f, exchange.result(), 500, null);
        assert(exchange.error() is cause);
    }

    @("ResponseStatusExceptionResolverTests.clientErrorIsNotRecordedOnObservation")
    unittest
    {
        auto f = setup();

        assert(observe(f, new StatusCodeException()).error() is null);
    }

    @("ResponseStatusExceptionResolverTests.clientErrorResponseStatusExceptionIsNotRecordedOnObservation")
    unittest
    {
        auto f = setup();

        assert(observe(f, new ResponseStatusException(HttpStatus.NOT_FOUND)).error() is null);
    }

    private ObservedExchange!ModelAndView observe(Fixture f, Exception ex)
    {
        return ObservedExchange!ModelAndView.observe(f.request, f.response,
                () => f.exceptionResolver.resolveException(f.request, f.response, null, ex));
    }
}

@("ResponseStatusExceptionResolverTests.serverErrorWithoutObservation")
unittest
{
    auto f = setup();
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, new ServerErrorException());
    assertResolved(f, mav, 500, null);
}

private void assertResolved(Fixture f, ModelAndView mav, int status, string reason)
{
    assert(mav !is null && mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == status);
    assert(f.response.getErrorMessage() == reason);
    assert(f.response.isCommitted());
}

/// `org.springframework.beans.testfixture.beans.ITestBean`.
private interface ITestBean
{
}

@ResponseStatus(HttpStatus.BAD_REQUEST)
private class StatusCodeException : Exception
{
    this() pure nothrow @nogc
    {
        super(null);
    }
}

@ResponseStatus(HttpStatus.INTERNAL_SERVER_ERROR)
private class ServerErrorException : Exception
{
    this() pure nothrow @nogc
    {
        super(null);
    }
}

@ResponseStatus(code: HttpStatus.GONE, reason: "You suck!")
private class StatusCodeAndReasonException : Exception
{
    this() pure nothrow @nogc
    {
        super(null);
    }
}

@ResponseStatus(code: HttpStatus.GONE, reason: "gone.reason")
private class StatusCodeAndReasonMessageException : Exception
{
    this() pure nothrow @nogc
    {
        super(null);
    }
}

@ResponseStatus
private struct ComposedResponseStatus
{
    @AliasFor(annotation: classOf!ResponseStatus, attribute: "code")
    HttpStatus responseStatus = HttpStatus.INTERNAL_SERVER_ERROR;
}

@ComposedResponseStatus(responseStatus: HttpStatus.BAD_REQUEST)
private class StatusCodeFromComposedResponseStatusException : Exception
{
    this() pure nothrow @nogc
    {
        super(null);
    }
}
