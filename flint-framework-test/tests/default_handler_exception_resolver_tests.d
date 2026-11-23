/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/support/DefaultHandlerExceptionResolverTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` returns, and the resolver has no warn log category to set. The `handle(String)`
parameter that reflection finds is described by its AOT `ArgumentSpec`. Beans' `TypeMismatchException` is
flint.web's, with the required type by name; `TestBean` is a private class; spring-web's `MockHttpInputMessage`
test fixture is a private class. Java's `Arrays.asList` and `Collections.singletonList` are D arrays. The test
lives with flint.mock.web in flint:framework-test. Cases that need unported classes or behave differently are gated
by version.
+/
module flint.web.default_handler_exception_resolver_tests;

import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.http : HttpHeaders, HttpInputMessage, HttpMethod, HttpStatus, MediaType;
import flint.http.converter : HttpMessageNotReadableException, HttpMessageNotWritableException;
import flint.http.server : ServletServerHttpRequest;
import flint.java.io : IOException;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web : ErrorResponseException, HttpMediaTypeNotSupportedException, HttpRequestMethodNotSupportedException;
import flint.web.bind : MethodArgumentNotValidException, MissingPathVariableException,
    MissingServletRequestParameterException, ServletRequestBindingException;
import flint.web.context.request.async : AsyncRequestTimeoutException;
import flint.web.method.annotation : TypeMismatchException;
import flint.web.multipart.support : MissingServletRequestPartException;
import flint.web.servlet : ModelAndView, NoHandlerFoundException;
import flint.web.servlet.mvc.support : DefaultHandlerExceptionResolver;
import flint.web.servlet.resource : NoResourceFoundException;

@safe:

private struct Fixture
{
    DefaultHandlerExceptionResolver exceptionResolver;
    MockHttpServletRequest request;
    MockHttpServletResponse response;
}

private Fixture setup()
{
    Fixture f;
    f.exceptionResolver = new DefaultHandlerExceptionResolver();
    f.request = new MockHttpServletRequest("GET", "/");
    f.response = new MockHttpServletResponse();
    return f;
}

@("DefaultHandlerExceptionResolverTests.handleHttpRequestMethodNotSupported")
unittest
{
    auto f = setup();
    auto ex = new HttpRequestMethodNotSupportedException("GET", ["POST", "PUT"]);
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 405, "Invalid status code");
    assert(f.response.getHeader("Allow") == "POST, PUT", "Invalid Allow header");
}

@("DefaultHandlerExceptionResolverTests.handleHttpMediaTypeNotSupported")
unittest
{
    auto f = setup();
    auto ex = new HttpMediaTypeNotSupportedException(MediaType("text", "plain"), [
        MediaType("application", "pdf")
    ]);
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 415, "Invalid status code");
    assert(f.response.getHeader("Accept") == "application/pdf", "Invalid Accept header");
}

@("DefaultHandlerExceptionResolverTests.patchHttpMediaTypeNotSupported")
unittest
{
    import std.typecons : Nullable, nullable;

    auto f = setup();
    auto ex = new HttpMediaTypeNotSupportedException(nullable(MediaType("text", "plain")),
            [MediaType("application", "pdf")], Nullable!HttpMethod(HttpMethod.PATCH));
    auto request = new MockHttpServletRequest("PATCH", "/");
    ModelAndView mav = f.exceptionResolver.resolveException(request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 415, "Invalid status code");
    assert(f.response.getHeader("Accept-Patch") == "application/pdf", "Invalid Accept header");
}

@("DefaultHandlerExceptionResolverTests.handleMissingPathVariable")
unittest
{
    auto f = setup();
    MethodParameter parameter = handleParameter();
    auto ex = new MissingPathVariableException("foo", parameter);
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 500, "Invalid status code");
    assert(f.response.getErrorMessage() == "Required path variable 'foo' is not present.");
}

@("DefaultHandlerExceptionResolverTests.handleMissingServletRequestParameter")
unittest
{
    auto f = setup();
    auto ex = new MissingServletRequestParameterException("foo", "bar");
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 400, "Invalid status code");
    assert(f.response.getErrorMessage() == "Required parameter 'foo' is not present.");
}

@("DefaultHandlerExceptionResolverTests.handleServletRequestBindingException")
unittest
{
    auto f = setup();
    const message = "Missing required value - header, cookie, or pathvar";
    auto ex = new ServletRequestBindingException(message);
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 400, "Invalid status code");
}

@("DefaultHandlerExceptionResolverTests.handleTypeMismatch")
unittest
{
    auto f = setup();
    auto ex = new TypeMismatchException(Any.of("foo"), "string", null);
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 400, "Invalid status code");
}

@("DefaultHandlerExceptionResolverTests.handleHttpMessageNotReadable")
unittest
{
    auto f = setup();
    auto ex = new HttpMessageNotReadableException("foo", null, new MockHttpInputMessage(new ubyte[0]));
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 400, "Invalid status code");
}

@("DefaultHandlerExceptionResolverTests.handleHttpMessageNotWritable")
unittest
{
    auto f = setup();
    auto ex = new HttpMessageNotWritableException("foo");
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 500, "Invalid status code");
}

@("DefaultHandlerExceptionResolverTests.handleMethodArgumentNotValid")
unittest
{
    import flint.validation : BeanPropertyBindingResult;

    auto f = setup();
    auto errors = new BeanPropertyBindingResult(Any.of(new TestBean()), "testBean");
    errors.rejectValue("name", "invalid");
    MethodParameter parameter = handleParameter();
    auto ex = new MethodArgumentNotValidException(parameter, errors);
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 400, "Invalid status code");
}

@("DefaultHandlerExceptionResolverTests.handleMissingServletRequestPartException")
unittest
{
    import std.algorithm.searching : canFind;

    auto f = setup();
    auto ex = new MissingServletRequestPartException("name");
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 400, "Invalid status code");
    assert(f.response.getErrorMessage().canFind("part"));
    assert(f.response.getErrorMessage().canFind("name"));
    assert(f.response.getErrorMessage().canFind("not present"));
}

@("DefaultHandlerExceptionResolverTests.handleNoHandlerFoundException")
unittest
{
    auto f = setup();
    auto req = new ServletServerHttpRequest(new MockHttpServletRequest("GET", "/resource"));
    auto ex = new NoHandlerFoundException(req.getMethod().name(), req.getServletRequest()
            .getRequestURI(), req.getHeaders());
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 404, "Invalid status code");
}

@("DefaultHandlerExceptionResolverTests.handleNoResourceFoundException")
unittest
{
    auto f = setup();
    auto ex = new NoResourceFoundException(HttpMethod.GET, "/context/resource", "/resource");
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 404, "Invalid status code");
}

// Beans' ConversionNotSupportedException is not ported (only its MethodArgumentConversionNotSupportedException).
version (FlintBeansConversionNotSupported)
{
    @("DefaultHandlerExceptionResolverTests.handleConversionNotSupportedException")
    unittest
    {
        import flint.beans : ConversionNotSupportedException;

        auto f = setup();
        auto ex = new ConversionNotSupportedException(Any.of(new Object()), "string", new Exception(null));
        ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
        assert(mav !is null, "No ModelAndView returned");
        assert(mav.isEmpty(), "No Empty ModelAndView returned");
        assert(f.response.getStatus() == 500, "Invalid status code");

        // SPR-9653
        assert(f.request.getAttribute("jakarta.servlet.error.exception").asObject() is ex);
    }
}

@("DefaultHandlerExceptionResolverTests.handleAsyncRequestTimeoutException")
unittest
{
    auto f = setup();
    Exception ex = new AsyncRequestTimeoutException();
    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null, "No ModelAndView returned");
    assert(mav.isEmpty(), "No Empty ModelAndView returned");
    assert(f.response.getStatus() == 503, "Invalid status code");
}

// MaxUploadSizeExceededException, like the rest of Spring's multipart support, is not ported.
version (FlintWebMultipart)
{
    @("DefaultHandlerExceptionResolverTests.handleMaxUploadSizeExceededException")
    unittest
    {
        import flint.web.multipart : MaxUploadSizeExceededException;

        auto f = setup();
        auto ex = new MaxUploadSizeExceededException(1000);
        ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
        assert(mav !is null, "No ModelAndView returned");
        assert(mav.isEmpty(), "No Empty ModelAndView returned");
        assert(f.response.getStatus() == 413, "Invalid status code");
        assert(f.response.getErrorMessage() == "Maximum upload size exceeded");
    }
}

// DefaultHandlerExceptionResolver has no per-exception protected hooks (handleHttpRequestMethodNotSupported and
// the like): every ErrorResponse goes through handleErrorResponse.
version (FlintDefaultHandlerExceptionResolverHooks)
{
    @("DefaultHandlerExceptionResolverTests.customModelAndView")
    unittest
    {
        import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
        import flint.web.servlet : HandlerExceptionResolver;

        auto f = setup();
        auto expected = new ModelAndView();

        HandlerExceptionResolver resolver = new class DefaultHandlerExceptionResolver
        {
            protected override ModelAndView handleHttpRequestMethodNotSupported(
                    HttpRequestMethodNotSupportedException ex,
                    HttpServletRequest request, HttpServletResponse response, Object handler)
            {
                return expected;
            }
        };

        auto ex = new HttpRequestMethodNotSupportedException("GET");

        ModelAndView actual = resolver.resolveException(f.request, f.response, null, ex);
        assert(actual is expected);
    }
}

// DefaultHandlerExceptionResolver does not handle a disconnected client (DisconnectedClientHelper): an
// IOException("Broken pipe") is left unresolved instead of sending a server error (likely bug).
version (FlintDisconnectedClientException)
{
    @("DefaultHandlerExceptionResolverTests.handleDisconnectedClientException")
    unittest
    {
        auto f = setup();
        Exception ex = new IOException("Broken pipe");
        ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
        assert(mav !is null, "No ModelAndView returned");
        assert(mav.isEmpty(), "No Empty ModelAndView returned");
        assert(f.response.getStatus() == 500, "Should attempt to send server error");
    }
}

// No observation support: ServerHttpObservationFilter and the ObservedExchange test fixture are not ported.
version (FlintWebObservation)
{
    import flint.web.servlet.mvc : ObservedExchange;

    @("DefaultHandlerExceptionResolverTests.serverErrorResponseIsRecordedOnObservation")
    unittest
    {
        auto f = setup();
        auto ex = new MissingPathVariableException("foo", handleParameter());

        assert(observe(f, ex).error() is ex);
        assert(f.response.getStatus() == 500);
    }

    @("DefaultHandlerExceptionResolverTests.serviceUnavailableErrorResponseIsRecordedOnObservation")
    unittest
    {
        auto f = setup();
        auto ex = new ErrorResponseException(HttpStatus.SERVICE_UNAVAILABLE);

        assert(observe(f, ex).error() is ex);
        assert(f.response.getStatus() == 503);
    }

    @("DefaultHandlerExceptionResolverTests.clientErrorResponseIsNotRecordedOnObservation")
    unittest
    {
        auto f = setup();
        auto ex = new MissingServletRequestParameterException("foo", "bar");

        assert(observe(f, ex).error() is null);
        assert(f.response.getStatus() == 400);
    }

    private ObservedExchange!ModelAndView observe(Fixture f, Exception ex)
    {
        return ObservedExchange!ModelAndView.observe(f.request, f.response,
                () => f.exceptionResolver.resolveException(f.request, f.response, null, ex));
    }
}

@("DefaultHandlerExceptionResolverTests.serverErrorResponseWithoutObservation")
unittest
{
    auto f = setup();
    auto ex = new ErrorResponseException(HttpStatus.SERVICE_UNAVAILABLE);

    ModelAndView mav = f.exceptionResolver.resolveException(f.request, f.response, null, ex);
    assert(mav !is null);
    assert(f.response.getStatus() == 503);
}

/// `new MethodParameter(getClass().getMethod("handle", String.class), 0)`: the parameter of `handle(String arg)`.
private MethodParameter handleParameter()
{
    import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;

    return new MethodParameter(ArgumentSpec(ArgumentKind.byType, "arg", "string"), 0,
            "DefaultHandlerExceptionResolverTests.handle");
}

/// `org.springframework.beans.testfixture.beans.TestBean`, reduced to the property the test rejects.
private final class TestBean
{
    string name;
}

/// spring-web's `MockHttpInputMessage` test fixture.
private final class MockHttpInputMessage : HttpInputMessage
{
    private HttpHeaders headers;
    private const(ubyte)[] content;

    this(const(ubyte)[] content) pure nothrow
    {
        headers = HttpHeaders.create();
        this.content = content;
    }

    HttpHeaders getHeaders()
    {
        return headers;
    }

    const(ubyte)[] getBody()
    {
        return content;
    }
}
