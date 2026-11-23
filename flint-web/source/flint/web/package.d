/++
`org.springframework.web`: `ErrorResponse` and the servlet-level exceptions spring-web declares at the root
of its package.

Ported from spring-projects/spring-framework v7.1.0, spring-web/src/main/java/org/springframework/web/
(ErrorResponse.java, ErrorResponseException.java, HttpRequestMethodNotSupportedException.java,
HttpMediaTypeException.java, HttpMediaTypeNotSupportedException.java,
HttpMediaTypeNotAcceptableException.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook (docs/spring/api-mapping.md).
`ErrorResponse`'s default methods are `mixin ErrorResponse.Defaults` (R3). Message codes keep Spring's
Java class names (`problemDetail.org.springframework.web.server.ResponseStatusException`) so existing
`messages.properties` keys keep working. `MessageSource`-based `updateAndGetBody` waits for spring-context's
`MessageSource` (framework-core); `updateAndGetBody()` without one returns the body unchanged, as Spring's
does for a `null` message source.
+/
module flint.web;

import flint.core : NestedRuntimeException;
import flint.engine.aot.any : Any;
import flint.http : HttpHeaders, HttpMethod, HttpStatus, HttpStatusCode, MediaType, ProblemDetail;
import flint.jakarta.servlet : ServletException;
import std.typecons : Nullable, nullable;

@safe:

/++
`ErrorResponse`: an exception that carries an HTTP status, headers and an RFC 9457 body.
Implementors write `mixin ErrorResponse.Defaults;` for Java's default methods (R3).
+/
interface ErrorResponse
{
    /// The status for the response.
    HttpStatusCode getStatusCode();

    /// Headers for the response; `HttpHeaders.EMPTY` by default.
    HttpHeaders getHeaders();

    /// The problem detail for the body.
    ProblemDetail getBody();

    /// The message code for the problem type.
    string getTypeMessageCode();

    /// The message code for the problem title.
    string getTitleMessageCode();

    /// The message code for the problem detail.
    string getDetailMessageCode();

    /// Arguments for the detail message, or `null`.
    Any[] getDetailMessageArguments();

    /// The body after message-source resolution; without a `MessageSource`, the body as it is.
    ProblemDetail updateAndGetBody();

    /// `problemDetail.type.<class name>`.
    static string getDefaultTypeMessageCode(const TypeInfo_Class exceptionType) pure nothrow
    {
        return "problemDetail.type." ~ javaClassName(exceptionType);
    }

    /// `problemDetail.title.<class name>`.
    static string getDefaultTitleMessageCode(const TypeInfo_Class exceptionType) pure nothrow
    {
        return "problemDetail.title." ~ javaClassName(exceptionType);
    }

    /// `problemDetail.<class name>[.<suffix>]`.
    static string getDefaultDetailMessageCode(const TypeInfo_Class exceptionType, string suffix) pure nothrow
    {
        return "problemDetail." ~ javaClassName(exceptionType) ~ (suffix !is null ? "." ~ suffix : "");
    }

    /// Java's default methods.
    mixin template Defaults()
    {
        /// `HttpHeaders.EMPTY`.
        HttpHeaders getHeaders()
        {
            return HttpHeaders.EMPTY();
        }

        ///
        string getTypeMessageCode()
        {
            return ErrorResponse.getDefaultTypeMessageCode(typeid(this));
        }

        ///
        string getTitleMessageCode()
        {
            return ErrorResponse.getDefaultTitleMessageCode(typeid(this));
        }

        ///
        string getDetailMessageCode()
        {
            return ErrorResponse.getDefaultDetailMessageCode(typeid(this), null);
        }

        ///
        Any[] getDetailMessageArguments()
        {
            return null;
        }

        ///
        ProblemDetail updateAndGetBody()
        {
            return getBody();
        }
    }
}

/// Spring's class name for a D class: framework classes map `flint.` back to `org.springframework.` (R1).
package(flint) string javaClassName(const TypeInfo_Class type) pure nothrow
{
    const name = type.name;
    static immutable string[3] thirdParty = ["flint.jakarta.", "flint.jackson.", "flint.java."];
    foreach (prefix; thirdParty)
        if (name.length > prefix.length && name[0 .. prefix.length] == prefix)
            return name[6 .. $];
    if (name.length > 6 && name[0 .. 6] == "flint.")
        return "org.springframework." ~ name[6 .. $];
    return name;
}

/// A trace that records nothing, so framework control-flow exceptions skip backtrace capture (ADR-030 s4).
private final class NoTrace : Throwable.TraceInfo
{
    override int opApply(scope int delegate(ref const(char[])) dg) const
    {
        return 0;
    }

    override int opApply(scope int delegate(ref size_t, ref const(char[])) dg) const
    {
        return 0;
    }

    override string toString() const
    {
        return "";
    }
}

/// Marks `t` so druntime skips its backtrace when it is thrown (druntime only fills an empty `info`).
package(flint) void skipBacktrace(Throwable t) pure nothrow
{
    t.info = new NoTrace;
}

/// `ErrorResponseException`: a `RuntimeException` that is an `ErrorResponse`.
class ErrorResponseException : NestedRuntimeException, ErrorResponse
{
    private HttpStatusCode status;
    private HttpHeaders headers;
    private ProblemDetail body;
    private string messageDetailCode;
    private Any[] messageDetailArguments;

    /// With `status` and a default body.
    this(HttpStatusCode status, Throwable cause = null)
    {
        this(status, ProblemDetail.forStatus(status), cause);
    }

    /// With `status` and `body`.
    this(HttpStatusCode status, ProblemDetail body, Throwable cause)
    {
        this(status, body, cause, null, null);
    }

    /// With every property.
    this(HttpStatusCode status, ProblemDetail body, Throwable cause, string messageDetailCode,
            Any[] messageDetailArguments)
    {
        super(null, cause);
        this.status = status;
        this.headers = HttpHeaders.create();
        this.body = body;
        this.messageDetailCode = messageDetailCode !is null ? messageDetailCode
            : ErrorResponse.getDefaultDetailMessageCode(typeid(this), null);
        this.messageDetailArguments = messageDetailArguments;
        skipBacktrace(this);
        msg = computeMessage();
    }

    HttpStatusCode getStatusCode()
    {
        return status;
    }

    HttpHeaders getHeaders()
    {
        return headers;
    }

    /// Sets the problem type.
    void setType(const(imported!"flint.java.net".URI)* type)
    {
        body.setType(type);
    }

    /// Sets the problem title.
    void setTitle(string title)
    {
        body.setTitle(title);
    }

    /// Sets the problem detail.
    void setDetail(string detail)
    {
        body.setDetail(detail);
        msg = computeMessage();
    }

    /// Sets the problem instance.
    void setInstance(const(imported!"flint.java.net".URI)* instance)
    {
        body.setInstance(instance);
    }

    final ProblemDetail getBody()
    {
        return body;
    }

    string getTypeMessageCode()
    {
        return ErrorResponse.getDefaultTypeMessageCode(typeid(this));
    }

    string getTitleMessageCode()
    {
        return ErrorResponse.getDefaultTitleMessageCode(typeid(this));
    }

    string getDetailMessageCode()
    {
        return messageDetailCode;
    }

    Any[] getDetailMessageArguments()
    {
        return messageDetailArguments;
    }

    ProblemDetail updateAndGetBody()
    {
        return getBody();
    }

    /// `"404 NOT_FOUND, ProblemDetail[...]"`.
    override string getMessage() const
    {
        return msg;
    }

    /// Recomputes Java's `getMessage()` text after a subclass constructor changes what it depends on.
    protected string computeMessage()
    {
        return status.toString() ~ (!headers.isEmpty() ? ", headers=" ~ headers.toString() : "") ~ ", "
            ~ body.toString();
    }
}

/// `HttpRequestMethodNotSupportedException`: the method is not supported by the matched handler (405).
class HttpRequestMethodNotSupportedException : ServletException, ErrorResponse
{
    mixin ErrorResponse.Defaults;

    private string method;
    private string[] supportedMethods;
    private ProblemDetail body;

    /// For `method`, with the supported methods (or `null`).
    this(string method, string[] supportedMethods = null)
    {
        super("Request method '" ~ method ~ "' is not supported");
        this.method = method;
        this.supportedMethods = supportedMethods;
        body = ProblemDetail.forStatusAndDetail(getStatusCode(), "Method '" ~ method ~ "' is not supported.");
        skipBacktrace(this);
    }

    /// The method that was not supported.
    string getMethod()
    {
        return method;
    }

    /// The supported methods, or `null`.
    string[] getSupportedMethods()
    {
        return supportedMethods;
    }

    /// The supported methods as `HttpMethod`s, or `null`.
    HttpMethod[] getSupportedHttpMethods()
    {
        if (supportedMethods is null)
            return null;
        HttpMethod[] result;
        foreach (value; supportedMethods)
        {
            auto candidate = HttpMethod.valueOf(value);
            bool seen;
            foreach (existing; result)
                seen = seen || existing == candidate;
            if (!seen)
                result ~= candidate;
        }
        return result;
    }

    HttpStatusCode getStatusCode()
    {
        return HttpStatus.METHOD_NOT_ALLOWED;
    }

    /// `Allow` with the supported methods, or `HttpHeaders.EMPTY`.
    HttpHeaders getHeaders()
    {
        if (supportedMethods.length == 0)
            return HttpHeaders.EMPTY();
        auto headers = HttpHeaders.create();
        string allow;
        foreach (i, value; supportedMethods)
            allow ~= (i == 0 ? "" : ", ") ~ value;
        headers.add(HttpHeaders.ALLOW, allow);
        return headers;
    }

    ProblemDetail getBody()
    {
        return body;
    }

    Any[] getDetailMessageArguments()
    {
        return [Any.of(method), Any.of(getSupportedHttpMethods())];
    }
}

/// `HttpMediaTypeException`: base of the media-type exceptions.
abstract class HttpMediaTypeException : ServletException, ErrorResponse
{
    mixin ErrorResponse.Defaults;

    private MediaType[] supportedMediaTypes;
    private ProblemDetail body;
    private string messageDetailCode;
    private Any[] messageDetailArguments;

    /// Spring's protected constructor.
    protected this(string message, MediaType[] supportedMediaTypes, string messageDetailCode,
            Any[] messageDetailArguments)
    {
        super(message);
        this.supportedMediaTypes = supportedMediaTypes;
        body = ProblemDetail.forStatus(getStatusCode());
        this.messageDetailCode = messageDetailCode !is null ? messageDetailCode
            : ErrorResponse.getDefaultDetailMessageCode(typeid(this), null);
        this.messageDetailArguments = messageDetailArguments;
        skipBacktrace(this);
    }

    /// The supported media types.
    MediaType[] getSupportedMediaTypes()
    {
        return supportedMediaTypes;
    }

    ProblemDetail getBody()
    {
        return body;
    }

    string getDetailMessageCode()
    {
        return messageDetailCode;
    }

    Any[] getDetailMessageArguments()
    {
        return messageDetailArguments;
    }
}

/// `HttpMediaTypeNotSupportedException`: the request `Content-Type` is not supported (415).
/// A `@Nullable` media type or method is a `Nullable!T` (R5, extended to value types).
class HttpMediaTypeNotSupportedException : HttpMediaTypeException
{
    private Nullable!MediaType contentType;
    private Nullable!HttpMethod httpMethod;

    /// A `Content-Type` that could not be parsed.
    this(string message, MediaType[] mediaTypes = null)
    {
        super(message, mediaTypes, ErrorResponse.getDefaultDetailMessageCode(typeid(HttpMediaTypeNotSupportedException), "parseError"), null);
        getBody().setDetail("Could not parse Content-Type.");
    }

    /// An unsupported `contentType`, with the supported types and the request method.
    this(Nullable!MediaType contentType, MediaType[] supportedMediaTypes,
            Nullable!HttpMethod httpMethod = Nullable!HttpMethod.init)
    {
        this(contentType, supportedMediaTypes, httpMethod, "Content-Type "
                ~ (!contentType.isNull ? "'" ~ contentType.get.toString() ~ "' " : "") ~ "is not supported");
    }

    /// ditto, for a known type.
    this(MediaType contentType, MediaType[] supportedMediaTypes)
    {
        this(nullable(contentType), supportedMediaTypes);
    }

    /// ditto, with a message.
    this(Nullable!MediaType contentType, MediaType[] supportedMediaTypes, Nullable!HttpMethod httpMethod,
            string message)
    {
        super(message, supportedMediaTypes, null, [Any.of(contentType.isNull ? null : contentType.get.toString()),
                Any.of(supportedMediaTypes)]);
        this.contentType = contentType;
        this.httpMethod = httpMethod;
        getBody().setDetail("Content-Type '" ~ (contentType.isNull ? "null" : contentType.get.toString())
                ~ "' is not supported.");
    }

    /// The unsupported type, if known.
    Nullable!MediaType getContentType()
    {
        return contentType;
    }

    HttpStatusCode getStatusCode()
    {
        return HttpStatus.UNSUPPORTED_MEDIA_TYPE;
    }

    /// `Accept` (and `Accept-Patch` for PATCH, `Accept-Query` for QUERY) with the supported types.
    override HttpHeaders getHeaders()
    {
        if (getSupportedMediaTypes().length == 0)
            return HttpHeaders.EMPTY();
        auto headers = HttpHeaders.create();
        headers.setAccept(getSupportedMediaTypes());
        if (!httpMethod.isNull && httpMethod.get == HttpMethod.PATCH)
            headers.set(HttpHeaders.ACCEPT_PATCH, MediaType.toString(getSupportedMediaTypes()));
        else if (!httpMethod.isNull && httpMethod.get == HttpMethod.QUERY)
            headers.set("Accept-Query", MediaType.toString(getSupportedMediaTypes()));
        return headers;
    }
}

/// `HttpMediaTypeNotAcceptableException`: no representation matches `Accept` (406).
class HttpMediaTypeNotAcceptableException : HttpMediaTypeException
{
    /// An `Accept` header that could not be parsed.
    this(string message)
    {
        super(message, null, ErrorResponse.getDefaultDetailMessageCode(typeid(HttpMediaTypeNotAcceptableException), "parseError"), null);
        getBody().setDetail("Could not parse Accept header.");
    }

    /// No acceptable representation among `mediaTypes`.
    this(MediaType[] mediaTypes)
    {
        super("No acceptable representation", mediaTypes, null, [Any.of(mediaTypes)]);
        getBody().setDetail("Acceptable representations: [" ~ MediaType.toString(mediaTypes) ~ "].");
    }

    HttpStatusCode getStatusCode()
    {
        return HttpStatus.NOT_ACCEPTABLE;
    }

    /// `Accept` with the supported types.
    override HttpHeaders getHeaders()
    {
        if (getSupportedMediaTypes().length == 0)
            return HttpHeaders.EMPTY();
        auto headers = HttpHeaders.create();
        headers.setAccept(getSupportedMediaTypes());
        return headers;
    }
}
