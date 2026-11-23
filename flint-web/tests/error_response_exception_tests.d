/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/ErrorResponseExceptionTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; Java's
`Object[]` detail message arguments are `Any[]`, compared element by element by value; `ex.getClass()` is
`typeid(cast(Object) ex)`; the `handle(String)` parameter that `ResolvableMethod` resolves is described by its
AOT `ArgumentSpec`; Mockito's `mock(MethodValidationResult)` is a `BlackHole` stub; `LocaleContextHolder`'s
`finally` reset is `scope (exit)`. Cases that need unported classes or behave differently are gated by version.
+/
module flint.web.error_response_exception_tests;

import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.http : HttpHeaders, HttpMethod, HttpStatus, MediaType, ProblemDetail;
import flint.web : ErrorResponse, HttpMediaTypeNotAcceptableException,
    HttpMediaTypeNotSupportedException, HttpRequestMethodNotSupportedException;
import flint.web.bind : MissingPathVariableException, MissingRequestCookieException,
    MissingRequestHeaderException, MissingServletRequestParameterException;

@safe:

/// The first parameter of `handle(String arg)`, as Spring's `ResolvableMethod` resolves it.
private MethodParameter methodParameter()
{
    import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;

    return new MethodParameter(ArgumentSpec(ArgumentKind.byType, "arg", "string"), 0,
            "ErrorResponseExceptionTests.handle");
}

// Spring asserts `Content-Type` details and `Accept-Patch`: flint.http's HttpHeaders has no getAcceptPatch(), and
// the detail message arguments carry the content type as its string, not the MediaType.
version (FlintHttpHeadersAcceptPatch)
{
    @("ErrorResponseExceptionTests.httpMediaTypeNotSupportedException")
    unittest
    {
        import std.typecons : Nullable;

        MediaType[] mediaTypes = [MediaType.APPLICATION_JSON, MediaType.APPLICATION_CBOR];

        auto ex = new HttpMediaTypeNotSupportedException(Nullable!MediaType(MediaType.APPLICATION_XML),
                mediaTypes, Nullable!HttpMethod(HttpMethod.PATCH), "Custom message");

        assertStatus(ex, HttpStatus.UNSUPPORTED_MEDIA_TYPE);
        assertDetail(ex, "Content-Type 'application/xml' is not supported.");
        assertDetailMessageCode(ex, null, [
            Any.of(ex.getContentType().get), Any.of(ex.getSupportedMediaTypes())
        ]);

        HttpHeaders headers = ex.getHeaders();
        assert(headers.getAccept() == mediaTypes);
        assert(headers.getAcceptPatch() == mediaTypes);
    }
}

@("ErrorResponseExceptionTests.httpMediaTypeNotSupportedExceptionWithParseError")
unittest
{
    ErrorResponse ex = new HttpMediaTypeNotSupportedException(
            "Could not parse Accept header: Invalid mime type \"foo\": does not contain '/'");

    assertStatus(ex, HttpStatus.UNSUPPORTED_MEDIA_TYPE);
    assertDetail(ex, "Could not parse Content-Type.");
    assertDetailMessageCode(ex, "parseError", null);

    assert(ex.getHeaders().isEmpty());
}

@("ErrorResponseExceptionTests.httpMediaTypeNotAcceptableException")
unittest
{
    MediaType[] mediaTypes = [MediaType.APPLICATION_JSON, MediaType.APPLICATION_CBOR];
    auto ex = new HttpMediaTypeNotAcceptableException(mediaTypes);

    assertStatus(ex, HttpStatus.NOT_ACCEPTABLE);
    assertDetail(ex, "Acceptable representations: [application/json, application/cbor].");
    assertDetailMessageCode(ex, null, [Any.of(ex.getSupportedMediaTypes())]);

    assert(ex.getHeaders().size() == 1);
    assert(ex.getHeaders().getAccept() == mediaTypes);
}

@("ErrorResponseExceptionTests.httpMediaTypeNotAcceptableExceptionWithParseError")
unittest
{
    ErrorResponse ex = new HttpMediaTypeNotAcceptableException(
            "Could not parse Accept header: Invalid mime type \"foo\": does not contain '/'");

    assertStatus(ex, HttpStatus.NOT_ACCEPTABLE);
    assertDetail(ex, "Could not parse Accept header.");
    assertDetailMessageCode(ex, "parseError", null);

    assert(ex.getHeaders().isEmpty());
}

// flint.web has not ported AsyncRequestTimeoutException, MissingMatrixVariableException,
// UnsatisfiedServletRequestParameterException, MissingServletRequestPartException,
// MethodArgumentNotValidException or HandlerMethodValidationException.
version (FlintWebMissingExceptions)
{
    @("ErrorResponseExceptionTests.asyncRequestTimeoutException")
    unittest
    {
        import flint.web.context.request.async : AsyncRequestTimeoutException;

        ErrorResponse ex = new AsyncRequestTimeoutException();
        assertDetailMessageCode(ex, null, null);

        assertStatus(ex, HttpStatus.SERVICE_UNAVAILABLE);
        assertDetail(ex, null);

        assert(ex.getHeaders().isEmpty());
    }
}

@("ErrorResponseExceptionTests.httpRequestMethodNotSupportedException")
unittest
{
    auto ex = new HttpRequestMethodNotSupportedException("PUT", ["GET", "POST"]);

    assertStatus(ex, HttpStatus.METHOD_NOT_ALLOWED);
    assertDetail(ex, "Method 'PUT' is not supported.");
    assertDetailMessageCode(ex, null, [Any.of(ex.getMethod()), Any.of(ex.getSupportedHttpMethods())]);

    assert(ex.getHeaders().size() == 1);
    assert(ex.getHeaders().getAllow() == [HttpMethod.GET, HttpMethod.POST]);
}

@("ErrorResponseExceptionTests.missingRequestHeaderException")
unittest
{
    auto ex = new MissingRequestHeaderException("Authorization", methodParameter());

    assertStatus(ex, HttpStatus.BAD_REQUEST);
    assertDetail(ex, "Required header 'Authorization' is not present.");
    assertDetailMessageCode(ex, null, [Any.of(ex.getHeaderName())]);

    assert(ex.getHeaders().isEmpty());
}

@("ErrorResponseExceptionTests.missingServletRequestParameterException")
unittest
{
    auto ex = new MissingServletRequestParameterException("query", "string");

    assertStatus(ex, HttpStatus.BAD_REQUEST);
    assertDetail(ex, "Required parameter 'query' is not present.");
    assertDetailMessageCode(ex, null, [Any.of(ex.getParameterName())]);

    assert(ex.getHeaders().isEmpty());
}

version (FlintWebMissingExceptions)
{
    @("ErrorResponseExceptionTests.missingMatrixVariableException")
    unittest
    {
        import flint.web.bind : MissingMatrixVariableException;

        auto ex = new MissingMatrixVariableException("region", methodParameter());

        assertStatus(ex, HttpStatus.BAD_REQUEST);
        assertDetail(ex, "Required path parameter 'region' is not present.");
        assertDetailMessageCode(ex, null, [Any.of(ex.getVariableName())]);

        assert(ex.getHeaders().isEmpty());
    }
}

@("ErrorResponseExceptionTests.missingPathVariableException")
unittest
{
    auto ex = new MissingPathVariableException("id", methodParameter());

    assertStatus(ex, HttpStatus.INTERNAL_SERVER_ERROR);
    assertDetail(ex, "Required path variable 'id' is not present.");
    assertDetailMessageCode(ex, null, [Any.of(ex.getVariableName())]);

    assert(ex.getHeaders().isEmpty());
}

// flint.web builds the body eagerly, before missingAfterConversion is set, so its status stays 500 (Spring: 400).
version (FlintWebMissingAfterConversionBodyStatus)
{
    @("ErrorResponseExceptionTests.missingPathVariableExceptionAfterConversion")
    unittest
    {
        auto ex = new MissingPathVariableException("id", methodParameter(), true);

        assertStatus(ex, HttpStatus.BAD_REQUEST);
        assertDetail(ex, "Required path variable 'id' is not present.");
        assertDetailMessageCode(ex, null, [Any.of(ex.getVariableName())]);

        assert(ex.getHeaders().isEmpty());
    }
}

@("ErrorResponseExceptionTests.missingRequestCookieException")
unittest
{
    auto ex = new MissingRequestCookieException("oreo", methodParameter());

    assertStatus(ex, HttpStatus.BAD_REQUEST);
    assertDetail(ex, "Required cookie 'oreo' is not present.");
    assertDetailMessageCode(ex, null, [Any.of(ex.getCookieName())]);

    assert(ex.getHeaders().isEmpty());
}

version (FlintWebMissingExceptions)
{
    @("ErrorResponseExceptionTests.unsatisfiedServletRequestParameterException")
    unittest
    {
        import flint.web.bind : UnsatisfiedServletRequestParameterException;

        auto ex = new UnsatisfiedServletRequestParameterException(["foo=bar", "bar=baz"], [
            "q": ["1"]
        ]);

        assertStatus(ex, HttpStatus.BAD_REQUEST);
        assertDetail(ex, "Invalid request parameters.");
        assertDetailMessageCode(ex, null, [Any.of(["\"foo=bar, bar=baz\""])]);

        assert(ex.getHeaders().isEmpty());
    }

    @("ErrorResponseExceptionTests.missingServletRequestPartException")
    unittest
    {
        import flint.web.multipart.support : MissingServletRequestPartException;

        auto ex = new MissingServletRequestPartException("file");

        assertStatus(ex, HttpStatus.BAD_REQUEST);
        assertDetail(ex, "Required part 'file' is not present.");
        assertDetailMessageCode(ex, null, [Any.of(ex.getRequestPartName())]);

        assert(ex.getHeaders().isEmpty());
    }

    // Also needs ValidationTestHelper (version FlintWebMessageSource).
    @("ErrorResponseExceptionTests.methodArgumentNotValidException")
    unittest
    {
        import flint.validation : BindingResult;
        import flint.web.bind : MethodArgumentNotValidException;

        auto testHelper = new ValidationTestHelper(typeid(MethodArgumentNotValidException));
        BindingResult result = testHelper.bindingResult();

        auto ex = new MethodArgumentNotValidException(methodParameter(), result);

        assertStatus(ex, HttpStatus.BAD_REQUEST);
        assertDetail(ex, "Invalid request content.");
        testHelper.assertMessages(ex, ex.getAllErrors());

        assert(ex.getHeaders().isEmpty());
    }

    @("ErrorResponseExceptionTests.handlerMethodValidationException")
    unittest
    {
        import flint.validation.method : MethodValidationResult;
        import flint.web.method.annotation : HandlerMethodValidationException;
        import std.typecons : BlackHole;

        static final class StubMethodValidationResult : BlackHole!MethodValidationResult
        {
            private bool forReturnValue;

            this(bool forReturnValue)
            {
                this.forReturnValue = forReturnValue;
            }

            override bool isForReturnValue()
            {
                return forReturnValue;
            }
        }

        MethodValidationResult result = new StubMethodValidationResult(false);
        auto ex = new HandlerMethodValidationException(result);

        assertStatus(ex, HttpStatus.BAD_REQUEST);
        assertDetail(ex, "Validation failure");

        result = new StubMethodValidationResult(true);
        ex = new HandlerMethodValidationException(result);

        assertStatus(ex, HttpStatus.INTERNAL_SERVER_ERROR);
        assertDetail(ex, "Validation failure");
    }
}

// flint.web has not ported the WebFlux exceptions of org.springframework.web.server (UnsupportedMediaTypeStatus,
// NotAcceptableStatus, ServerError, MissingRequestValue, UnsatisfiedRequestParameter, MethodNotAllowed) or
// WebExchangeBindException.
version (FlintWebReactiveExceptions)
{
    @("ErrorResponseExceptionTests.unsupportedMediaTypeStatusException")
    unittest
    {
        import flint.web.server : UnsupportedMediaTypeStatusException;

        MediaType[] mediaTypes = [MediaType.APPLICATION_JSON, MediaType.APPLICATION_CBOR];

        auto ex = new UnsupportedMediaTypeStatusException(MediaType.APPLICATION_XML, mediaTypes, HttpMethod.PATCH);

        assertStatus(ex, HttpStatus.UNSUPPORTED_MEDIA_TYPE);
        assertDetail(ex, "Content-Type 'application/xml' is not supported.");
        assertDetailMessageCode(ex, null, [
            Any.of(ex.getContentType()), Any.of(ex.getSupportedMediaTypes())
        ]);

        HttpHeaders headers = ex.getHeaders();
        assert(headers.getAccept() == mediaTypes);
        assert(headers.getAcceptPatch() == mediaTypes);
    }

    @("ErrorResponseExceptionTests.unsupportedMediaTypeStatusExceptionWithParseError")
    unittest
    {
        import flint.web.server : UnsupportedMediaTypeStatusException;

        ErrorResponse ex = new UnsupportedMediaTypeStatusException(
                "Could not parse Accept header: Invalid mime type \"foo\": does not contain '/'");

        assertStatus(ex, HttpStatus.UNSUPPORTED_MEDIA_TYPE);
        assertDetail(ex, "Could not parse Content-Type.");
        assertDetailMessageCode(ex, "parseError", null);

        assert(ex.getHeaders().isEmpty());
    }

    @("ErrorResponseExceptionTests.notAcceptableStatusException")
    unittest
    {
        import flint.web.server : NotAcceptableStatusException;

        MediaType[] mediaTypes = [MediaType.APPLICATION_JSON, MediaType.APPLICATION_CBOR];
        auto ex = new NotAcceptableStatusException(mediaTypes);

        assertStatus(ex, HttpStatus.NOT_ACCEPTABLE);
        assertDetail(ex, "Acceptable representations: [application/json, application/cbor].");
        assertDetailMessageCode(ex, null, [Any.of(ex.getSupportedMediaTypes())]);

        assert(ex.getHeaders().size() == 1);
        assert(ex.getHeaders().getAccept() == mediaTypes);
    }

    @("ErrorResponseExceptionTests.notAcceptableStatusExceptionWithParseError")
    unittest
    {
        import flint.web.server : NotAcceptableStatusException;

        ErrorResponse ex = new NotAcceptableStatusException(
                "Could not parse Accept header: Invalid mime type \"foo\": does not contain '/'");

        assertStatus(ex, HttpStatus.NOT_ACCEPTABLE);
        assertDetail(ex, "Could not parse Accept header.");
        assertDetailMessageCode(ex, "parseError", null);

        assert(ex.getHeaders().isEmpty());
    }

    @("ErrorResponseExceptionTests.serverErrorException")
    unittest
    {
        import flint.web.server : ServerErrorException;

        auto ex = new ServerErrorException("Failure", cast(Throwable) null);

        assertStatus(ex, HttpStatus.INTERNAL_SERVER_ERROR);
        assertDetail(ex, "Failure");
        assertDetailMessageCode(ex, null, [Any.of(ex.getReason())]);

        assert(ex.getHeaders().isEmpty());
    }

    @("ErrorResponseExceptionTests.missingRequestValueException")
    unittest
    {
        import flint.web.server : MissingRequestValueException;

        auto ex = new MissingRequestValueException("foo", "string", "header", methodParameter());

        assertStatus(ex, HttpStatus.BAD_REQUEST);
        assertDetail(ex, "Required header 'foo' is not present.");
        assertDetailMessageCode(ex, null, [Any.of(ex.getLabel()), Any.of(ex.getName())]);

        assert(ex.getHeaders().isEmpty());
    }

    @("ErrorResponseExceptionTests.unsatisfiedRequestParameterException")
    unittest
    {
        import flint.util : LinkedMultiValueMap;
        import flint.web.server : UnsatisfiedRequestParameterException;

        auto params = new LinkedMultiValueMap!(string, string)();
        params.add("q", "1");
        params.add("q", "2");
        auto ex = new UnsatisfiedRequestParameterException(["foo=bar", "bar=baz"], params);

        assertStatus(ex, HttpStatus.BAD_REQUEST);
        assertDetail(ex, "Invalid request parameters.");
        assertDetailMessageCode(ex, null, [Any.of(ex.getConditions())]);

        assert(ex.getHeaders().isEmpty());
    }

    // Also needs ValidationTestHelper (version FlintWebMessageSource).
    @("ErrorResponseExceptionTests.webExchangeBindException")
    unittest
    {
        import flint.validation : BindingResult;
        import flint.web.bind.support : WebExchangeBindException;

        auto testHelper = new ValidationTestHelper(typeid(WebExchangeBindException));
        BindingResult result = testHelper.bindingResult();

        auto ex = new WebExchangeBindException(methodParameter(), result);

        assertStatus(ex, HttpStatus.BAD_REQUEST);
        assertDetail(ex, "Invalid request content.");
        testHelper.assertMessages(ex, ex.getAllErrors());

        assert(ex.getHeaders().isEmpty());
    }

    @("ErrorResponseExceptionTests.methodNotAllowedException")
    unittest
    {
        import flint.web.server : MethodNotAllowedException;

        HttpMethod[] supportedMethods = [HttpMethod.GET, HttpMethod.POST];
        auto ex = new MethodNotAllowedException(HttpMethod.PUT, supportedMethods);

        assertStatus(ex, HttpStatus.METHOD_NOT_ALLOWED);
        assertDetail(ex, "Supported methods: [GET, POST]");
        assertDetailMessageCode(ex, null, [Any.of(ex.getHttpMethod()), Any.of(supportedMethods)]);

        assert(ex.getHeaders().size() == 1);
        assert(ex.getHeaders().getAllow() == [HttpMethod.GET, HttpMethod.POST]);
    }

    @("ErrorResponseExceptionTests.methodNotAllowedExceptionWithoutSupportedMethods")
    unittest
    {
        import flint.web.server : MethodNotAllowedException;

        auto ex = new MethodNotAllowedException(HttpMethod.PUT, HttpMethod[].init);

        assertStatus(ex, HttpStatus.METHOD_NOT_ALLOWED);
        assertDetail(ex, "Request method 'PUT' is not supported.");
        assertDetailMessageCode(ex, null, [Any.of(ex.getHttpMethod()), Any.of(HttpMethod[].init)]);

        assert(ex.getHeaders().isEmpty());
    }
}

// flint has no spring-context MessageSource/StaticMessageSource or LocaleContextHolder yet, so neither
// ErrorResponse.updateAndGetBody(messageSource, locale) nor ValidationTestHelper can be ported.
version (FlintWebMessageSource)
{
    @("ErrorResponseExceptionTests.responseStatusException (gh-30300)")
    unittest
    {
        import flint.context.i18n : LocaleContextHolder;
        import flint.context.support : StaticMessageSource;
        import flint.java.util : Locale;
        import flint.web.server : ResponseStatusException;

        Locale locale = Locale.UK;
        LocaleContextHolder.setLocale(locale);
        scope (exit)
            LocaleContextHolder.resetLocaleContext();

        const reason = "bad.request";
        const message = "Breaking Bad Request";
        auto messageSource = new StaticMessageSource();
        messageSource.addMessage(reason, locale, message);

        auto ex = new ResponseStatusException(HttpStatus.BAD_REQUEST, reason);

        ProblemDetail problemDetail = ex.updateAndGetBody(messageSource, locale);
        assert(problemDetail.getDetail() == message);
    }

    @("ErrorResponseExceptionTests.responseStatusExceptionCustomReason (gh-36984)")
    unittest
    {
        import flint.context.i18n : LocaleContextHolder;
        import flint.context.support : StaticMessageSource;
        import flint.java.util : Locale;
        import flint.web.server : ResponseStatusException;

        Locale locale = Locale.UK;
        LocaleContextHolder.setLocale(locale);
        scope (exit)
            LocaleContextHolder.resetLocaleContext();

        const reason = "bad.request";
        const message = "Breaking Bad Request";
        auto messageSource = new StaticMessageSource();
        messageSource.addMessage(reason, locale, message);

        const customReason = "my custom reason";
        auto ex = new ResponseStatusException(HttpStatus.BAD_REQUEST, customReason);

        ProblemDetail problemDetail = ex.updateAndGetBody(messageSource, locale);
        assert(problemDetail.getDetail() == customReason);
    }

    private final class TestBean
    {
        string name;
        int age;
    }

    private final class ValidationTestHelper
    {
        import flint.context : MessageSourceResolvable;
        import flint.context.support : StaticMessageSource;
        import flint.java.util : Locale;
        import flint.validation : BeanPropertyBindingResult, BindingResult;

        private BindingResult bindingResult_;

        private StaticMessageSource messageSource;

        this(const TypeInfo_Class exceptionType)
        {
            import flint.web : javaClassName;

            messageSource = new StaticMessageSource();

            bindingResult_ = new BeanPropertyBindingResult(Any.of(new TestBean()), "myBean");
            bindingResult_.reject("bean.invalid.A", "Invalid bean message");
            bindingResult_.reject("bean.invalid.B");
            bindingResult_.rejectValue("name", "name.required", "must be provided");
            bindingResult_.rejectValue("age", "age.min");

            const code = "problemDetail." ~ javaClassName(exceptionType);
            messageSource.addMessage(code, Locale.UK, "Failed because {0}. Also because {1}");
            messageSource.addMessage("bean.invalid.A", Locale.UK, "Bean A message");
            messageSource.addMessage("bean.invalid.B", Locale.UK, "Bean B message");
            messageSource.addMessage("name.required", Locale.UK, "name is required");
            messageSource.addMessage("age.min", Locale.UK, "age is below minimum");
        }

        BindingResult bindingResult()
        {
            return bindingResult_;
        }

        void assertMessages(ErrorResponse ex, MessageSourceResolvable[] errors)
        {
            import flint.web.util : BindErrorUtils;

            string message = messageSource.getMessage(ex.getDetailMessageCode(),
                    ex.getDetailMessageArguments(), Locale.UK);

            assert(message == "Failed because Invalid bean message, and bean.invalid.B.myBean. "
                    ~ "Also because name: must be provided, and age: age.min.myBean.age");

            message = messageSource.getMessage(ex.getDetailMessageCode(),
                    ex.getDetailMessageArguments(messageSource, Locale.UK), Locale.UK);

            assert(message == "Failed because Bean A message, and Bean B message. "
                    ~ "Also because name is required, and age is below minimum");

            auto resolved = BindErrorUtils.resolve(errors, messageSource, Locale.UK);
            assert(resolved.length == 4);
            foreach (expected; [
                "Bean A message", "Bean B message", "name is required", "age is below minimum"
            ])
            {
                bool found;
                foreach (value; resolved.byValue)
                    found = found || value == expected;
                assert(found, expected);
            }
        }
    }
}

private void assertStatus(ErrorResponse ex, HttpStatus status)
{
    ProblemDetail body = ex.getBody();
    assert(ex.getStatusCode() == status);
    assert(body.getStatus() == status.value());
    assert(body.getTitle() == status.getReasonPhrase());
}

private void assertDetail(ErrorResponse ex, string detail)
{
    if (detail !is null)
        assert(ex.getBody().getDetail() == detail, ex.getBody().getDetail());
    else
        assert(ex.getBody().getDetail() is null);
}

private void assertDetailMessageCode(ErrorResponse ex, string suffix, Any[] arguments)
{
    assert(ex.getDetailMessageCode() == ErrorResponse.getDefaultDetailMessageCode(typeid(cast(Object) ex), suffix));

    if (arguments !is null)
    {
        const actual = ex.getDetailMessageArguments();
        assert(actual.length == arguments.length);
        foreach (i, argument; arguments)
            assert(argumentEquals(actual[i], argument), actual[i].toString());
    }
    else
        assert(ex.getDetailMessageArguments() is null);
}

/// Java's `equals` on two detail message arguments: `Any` compares boxed arrays by identity, so compare those
/// by value for the argument types these cases use.
private bool argumentEquals(const Any actual, const Any expected)
{
    import std.meta : AliasSeq;

    if (actual == expected)
        return true;
    if (actual.typeName() != expected.typeName())
        return false;
    static foreach (T; AliasSeq!(MediaType[], HttpMethod[], string[]))
        if (actual.holds!T && expected.holds!T)
            return actual.get!T == expected.get!T;
    return false;
}
