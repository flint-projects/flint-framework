/++
`org.springframework.web.context.request`: the request seen as an attribute holder, independent of servlets.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/context/request/ (RequestAttributes.java, WebRequest.java,
NativeWebRequest.java, ServletRequestAttributes.java, ServletWebRequest.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. Session scope waits for a session port.
`RequestContextHolder` moves to a `FiberLocal!T` holder with the servlet bridge (ADR-030 section 4).
+/
module flint.web.context.request;

import flint.engine.aot.any : Any;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;

@safe:

/// `RequestAttributes`.
interface RequestAttributes
{
    /// Request scope.
    enum int SCOPE_REQUEST = 0;
    /// Session scope.
    enum int SCOPE_SESSION = 1;
    /// `"request"`.
    enum string REFERENCE_REQUEST = "request";
    /// `"session"`.
    enum string REFERENCE_SESSION = "session";

    /// The attribute, or a null `Any`.
    Any getAttribute(string name, int scope_);

    /// Sets an attribute.
    void setAttribute(string name, Any value, int scope_);

    /// Removes an attribute.
    void removeAttribute(string name, int scope_);

    /// The attribute names.
    string[] getAttributeNames(int scope_);
}

/// `WebRequest`: parameters, headers and attributes.
interface WebRequest : RequestAttributes
{
    /// The first value of a header, or `null`.
    string getHeader(string headerName);

    /// Every value of a header, or `null`.
    string[] getHeaderValues(string headerName);

    /// The first value of a parameter, or `null`.
    string getParameter(string paramName);

    /// Every value of a parameter, or `null`.
    string[] getParameterValues(string paramName);

    /// The context path.
    string getContextPath();

    /// A short description for logging.
    string getDescription(bool includeClientInfo);
}

/// `NativeWebRequest`: a `WebRequest` that exposes the servlet request and response.
interface NativeWebRequest : WebRequest
{
    /// The servlet request (Java's `getNativeRequest()`).
    HttpServletRequest getNativeRequest();

    /// The servlet response (Java's `getNativeResponse()`), or `null`.
    HttpServletResponse getNativeResponse();
}

/// `ServletRequestAttributes`.
class ServletRequestAttributes : RequestAttributes
{
    private HttpServletRequest request;
    private HttpServletResponse response;

    ///
    this(HttpServletRequest request, HttpServletResponse response = null) pure nothrow @nogc
    {
        this.request = request;
        this.response = response;
    }

    /// The request.
    final HttpServletRequest getRequest() pure nothrow @nogc
    {
        return request;
    }

    /// The response, or `null`.
    final HttpServletResponse getResponse() pure nothrow @nogc
    {
        return response;
    }

    Any getAttribute(string name, int scope_)
    {
        return scope_ == SCOPE_REQUEST ? request.getAttribute(name) : Any.init;
    }

    void setAttribute(string name, Any value, int scope_)
    {
        if (scope_ == SCOPE_REQUEST)
            request.setAttribute(name, value);
    }

    void removeAttribute(string name, int scope_)
    {
        if (scope_ == SCOPE_REQUEST)
            request.removeAttribute(name);
    }

    string[] getAttributeNames(int scope_)
    {
        return scope_ == SCOPE_REQUEST ? request.getAttributeNames() : null;
    }
}

/// `ServletWebRequest`.
class ServletWebRequest : ServletRequestAttributes, NativeWebRequest
{
    ///
    this(HttpServletRequest request, HttpServletResponse response = null) pure nothrow @nogc
    {
        super(request, response);
    }

    HttpServletRequest getNativeRequest()
    {
        return getRequest();
    }

    HttpServletResponse getNativeResponse()
    {
        return getResponse();
    }

    string getHeader(string headerName)
    {
        return getRequest().getHeader(headerName);
    }

    string[] getHeaderValues(string headerName)
    {
        auto values = getRequest().getHeaders(headerName);
        return values.length == 0 ? null : values;
    }

    string getParameter(string paramName)
    {
        return getRequest().getParameter(paramName);
    }

    string[] getParameterValues(string paramName)
    {
        return getRequest().getParameterValues(paramName);
    }

    string getContextPath()
    {
        return getRequest().getContextPath();
    }

    string getDescription(bool includeClientInfo)
    {
        return "uri=" ~ getRequest().getRequestURI()
            ~ (includeClientInfo ? ";client=" ~ getRequest().getRemoteAddr() : "");
    }

    override string toString()
    {
        return "ServletWebRequest: " ~ getDescription(true);
    }
}
