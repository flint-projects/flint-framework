/++
`jakarta.servlet.http`: HTTP requests, responses, cookies and servlets.

Ported from jakartaee/servlet, jakarta.servlet-api 6.1.0 (the sources jar pinned in api/upstreams.json).
Upstream copyright: Copyright (c) 1997, 2024 Oracle and/or its affiliates and others. All rights reserved.
Copyright 2004 The Apache Software Foundation. The upstream project is EPL-2.0 OR GPL-2.0-with-classpath-
exception; Flint distributes this module under EPL-2.0 only (policy/upstream-licences.json, use
"epl-module"). EPL-2.0 applies to this file; applications that import it are not affected.
Modified by the Flint authors: translated to D under the rulebook (docs/spring/api-mapping.md). Only the
API that Flint Web MVC and its tests use is ported; there is no servlet container. `Object` attributes are
`Any` (R1), `Enumeration<String>` is `string[]` and `Map<String, String[]>` is `string[][string]` (R10).
+/
module flint.jakarta.servlet.http;

import flint.engine.aot.any : Any;
import flint.jakarta.servlet : Filter, FilterChain, GenericFilter, GenericServlet, ServletException,
    ServletRequest, ServletResponse;

@safe:

/// `jakarta.servlet.http.Cookie`.
class Cookie
{
    private string name;
    private string value;
    private string[string] attributes;
    private string[] attributeOrder;

    /// A cookie with `name` and `value`. Throws `IllegalArgumentException` for an invalid name.
    this(string name, string value)
    {
        import flint.java.lang : IllegalArgumentException;

        if (name.length == 0)
            throw new IllegalArgumentException("Cookie name must not be null or empty");
        foreach (c; name)
            if (c <= ' ' || c >= 0x7f || c == ';' || c == ',' || c == '=' || c == '$')
                throw new IllegalArgumentException("Cookie name [" ~ name ~ "] is a reserved token");
        this.name = name;
        this.value = value;
    }

    /// The name.
    string getName() const pure nothrow @nogc
    {
        return name;
    }

    /// The value.
    string getValue() const pure nothrow @nogc
    {
        return value;
    }

    /// Sets the value.
    void setValue(string newValue) pure nothrow @nogc
    {
        value = newValue;
    }

    /// `Domain`, or `null`.
    string getDomain() const pure nothrow
    {
        return getAttribute("Domain");
    }

    /// Sets `Domain` (lowercased).
    void setDomain(string domain) pure nothrow
    {
        import flint.util : toLowerAscii;

        setAttribute("Domain", domain is null ? null : toLowerAscii(domain));
    }

    /// `Path`, or `null`.
    string getPath() const pure nothrow
    {
        return getAttribute("Path");
    }

    /// Sets `Path`.
    void setPath(string uri) pure nothrow
    {
        setAttribute("Path", uri);
    }

    /// `Max-Age` in seconds, or `-1`.
    int getMaxAge() const pure
    {
        import std.conv : to;

        const maxAge = getAttribute("Max-Age");
        return maxAge is null ? -1 : maxAge.to!int;
    }

    /// Sets `Max-Age`.
    void setMaxAge(int expiry) pure
    {
        import std.conv : to;

        setAttribute("Max-Age", expiry < 0 ? null : expiry.to!string);
    }

    /// Whether `Secure` is set.
    bool getSecure() const pure nothrow
    {
        return getAttribute("Secure") == "";
    }

    /// Sets `Secure`.
    void setSecure(bool flag) pure nothrow
    {
        setAttribute("Secure", flag ? "" : null);
    }

    /// Whether `HttpOnly` is set.
    bool isHttpOnly() const pure nothrow
    {
        return getAttribute("HttpOnly") == "";
    }

    /// Sets `HttpOnly`.
    void setHttpOnly(bool isHttpOnly) pure nothrow
    {
        setAttribute("HttpOnly", isHttpOnly ? "" : null);
    }

    /// Sets an attribute; `null` removes it.
    void setAttribute(string name, string value) pure nothrow
    {
        import flint.util : equalsIgnoreCase;

        foreach (i, existing; attributeOrder)
        {
            if (equalsIgnoreCase(existing, name))
            {
                if (value is null)
                {
                    attributes.remove(existing);
                    attributeOrder = attributeOrder[0 .. i] ~ attributeOrder[i + 1 .. $];
                }
                else
                    attributes[existing] = value;
                return;
            }
        }
        if (value is null)
            return;
        attributeOrder ~= name;
        attributes[name] = value;
    }

    /// An attribute, ignoring case, or `null`.
    string getAttribute(string name) const pure nothrow
    {
        import flint.util : equalsIgnoreCase;

        foreach (existing; attributeOrder)
            if (equalsIgnoreCase(existing, name))
                return attributes[existing];
        return null;
    }

    /// Every attribute in order.
    string[2][] getAttributes() const pure nothrow
    {
        string[2][] result;
        foreach (existing; attributeOrder)
            result ~= [existing, attributes[existing]];
        return result;
    }
}

/// `jakarta.servlet.http.HttpServletRequest`.
interface HttpServletRequest : ServletRequest
{
    /// `BASIC`, `FORM`, ..., or `null`.
    string getAuthType();

    /// The cookies sent, or `null` when there are none.
    Cookie[] getCookies();

    /// A date header in milliseconds since the epoch, or `-1`.
    long getDateHeader(string name);

    /// The first value of a header, ignoring case, or `null`.
    string getHeader(string name);

    /// Every value of a header.
    string[] getHeaders(string name);

    /// The header names.
    string[] getHeaderNames();

    /// A header as an `int`, or `-1`.
    int getIntHeader(string name);

    /// The method: `GET`, `POST`, ...
    string getMethod();

    /// Path after the servlet path, or `null`.
    string getPathInfo();

    /// The real path of `getPathInfo`, or `null`.
    string getPathTranslated();

    /// The context path.
    string getContextPath();

    /// The query string, or `null`.
    string getQueryString();

    /// The authenticated user's login, or `null`.
    string getRemoteUser();

    /// Whether the user has `role`.
    bool isUserInRole(string role);

    /// The session id the client sent, or `null`.
    string getRequestedSessionId();

    /// The path part of the request URL, still encoded, without the query string.
    string getRequestURI();

    /// The reconstructed URL without the query string (Java returns a `StringBuffer`).
    string getRequestURL();

    /// The servlet path.
    string getServletPath();

    /// Whether the requested session id is valid.
    bool isRequestedSessionIdValid();
}

/// `jakarta.servlet.http.HttpServletResponse`.
interface HttpServletResponse : ServletResponse
{
    enum int SC_CONTINUE = 100; ///
    enum int SC_SWITCHING_PROTOCOLS = 101; ///
    enum int SC_OK = 200; ///
    enum int SC_CREATED = 201; ///
    enum int SC_ACCEPTED = 202; ///
    enum int SC_NON_AUTHORITATIVE_INFORMATION = 203; ///
    enum int SC_NO_CONTENT = 204; ///
    enum int SC_RESET_CONTENT = 205; ///
    enum int SC_PARTIAL_CONTENT = 206; ///
    enum int SC_MULTIPLE_CHOICES = 300; ///
    enum int SC_MOVED_PERMANENTLY = 301; ///
    enum int SC_MOVED_TEMPORARILY = 302; ///
    enum int SC_FOUND = 302; ///
    enum int SC_SEE_OTHER = 303; ///
    enum int SC_NOT_MODIFIED = 304; ///
    enum int SC_USE_PROXY = 305; ///
    enum int SC_TEMPORARY_REDIRECT = 307; ///
    enum int SC_PERMANENT_REDIRECT = 308; ///
    enum int SC_BAD_REQUEST = 400; ///
    enum int SC_UNAUTHORIZED = 401; ///
    enum int SC_PAYMENT_REQUIRED = 402; ///
    enum int SC_FORBIDDEN = 403; ///
    enum int SC_NOT_FOUND = 404; ///
    enum int SC_METHOD_NOT_ALLOWED = 405; ///
    enum int SC_NOT_ACCEPTABLE = 406; ///
    enum int SC_PROXY_AUTHENTICATION_REQUIRED = 407; ///
    enum int SC_REQUEST_TIMEOUT = 408; ///
    enum int SC_CONFLICT = 409; ///
    enum int SC_GONE = 410; ///
    enum int SC_LENGTH_REQUIRED = 411; ///
    enum int SC_PRECONDITION_FAILED = 412; ///
    enum int SC_REQUEST_ENTITY_TOO_LARGE = 413; ///
    enum int SC_REQUEST_URI_TOO_LONG = 414; ///
    enum int SC_UNSUPPORTED_MEDIA_TYPE = 415; ///
    enum int SC_REQUESTED_RANGE_NOT_SATISFIABLE = 416; ///
    enum int SC_EXPECTATION_FAILED = 417; ///
    enum int SC_MISDIRECTED_REQUEST = 421; ///
    enum int SC_UNPROCESSABLE_CONTENT = 422; ///
    enum int SC_UPGRADE_REQUIRED = 426; ///
    enum int SC_INTERNAL_SERVER_ERROR = 500; ///
    enum int SC_NOT_IMPLEMENTED = 501; ///
    enum int SC_BAD_GATEWAY = 502; ///
    enum int SC_SERVICE_UNAVAILABLE = 503; ///
    enum int SC_GATEWAY_TIMEOUT = 504; ///
    enum int SC_HTTP_VERSION_NOT_SUPPORTED = 505; ///

    /// Adds `Set-Cookie` for `cookie`.
    void addCookie(Cookie cookie);

    /// Whether the header has been set.
    bool containsHeader(string name);

    /// `url` with the session id when needed.
    string encodeURL(string url);

    /// ditto, for redirects.
    string encodeRedirectURL(string url);

    /// Sends an error: clears the buffer, sets the status, and lets the container produce the error page.
    void sendError(int sc, string msg);

    /// ditto, without a message.
    void sendError(int sc);

    /// Sends a 302 redirect to `location`.
    void sendRedirect(string location);

    /// Sets a date header.
    void setDateHeader(string name, long date);

    /// Adds a date header.
    void addDateHeader(string name, long date);

    /// Sets a header, replacing its values.
    void setHeader(string name, string value);

    /// Adds a header value.
    void addHeader(string name, string value);

    /// Sets an integer header.
    void setIntHeader(string name, int value);

    /// Adds an integer header.
    void addIntHeader(string name, int value);

    /// Sets the status.
    void setStatus(int sc);

    /// The status.
    int getStatus();

    /// The first value of a header, or `null`.
    string getHeader(string name);

    /// Every value of a header.
    string[] getHeaders(string name);

    /// The header names.
    string[] getHeaderNames();
}

/// `jakarta.servlet.http.HttpServlet`: dispatches `service` to `doGet`, `doPost`, ...
abstract class HttpServlet : GenericServlet
{
    private enum string METHOD_DELETE = "DELETE";
    private enum string METHOD_HEAD = "HEAD";
    private enum string METHOD_GET = "GET";
    private enum string METHOD_OPTIONS = "OPTIONS";
    private enum string METHOD_POST = "POST";
    private enum string METHOD_PUT = "PUT";
    private enum string METHOD_TRACE = "TRACE";
    private enum string METHOD_PATCH = "PATCH";

    /// Handles GET; the default sends 405.
    protected void doGet(HttpServletRequest req, HttpServletResponse resp)
    {
        sendMethodNotAllowed(req, resp, "http.method_get_not_supported");
    }

    /// Handles HEAD as GET without a body.
    protected void doHead(HttpServletRequest req, HttpServletResponse resp)
    {
        doGet(req, resp);
    }

    /// Handles POST; the default sends 405.
    protected void doPost(HttpServletRequest req, HttpServletResponse resp)
    {
        sendMethodNotAllowed(req, resp, "http.method_post_not_supported");
    }

    /// Handles PUT; the default sends 405.
    protected void doPut(HttpServletRequest req, HttpServletResponse resp)
    {
        sendMethodNotAllowed(req, resp, "http.method_put_not_supported");
    }

    /// Handles PATCH; the default sends 405.
    protected void doPatch(HttpServletRequest req, HttpServletResponse resp)
    {
        sendMethodNotAllowed(req, resp, "http.method_patch_not_supported");
    }

    /// Handles DELETE; the default sends 405.
    protected void doDelete(HttpServletRequest req, HttpServletResponse resp)
    {
        sendMethodNotAllowed(req, resp, "http.method_delete_not_supported");
    }

    /// Handles OPTIONS: `Allow` lists the methods this servlet handles, in the order Tomcat writes them.
    protected void doOptions(HttpServletRequest req, HttpServletResponse resp)
    {
        const declared = getDeclaredMethods();
        bool has(string m)
        {
            foreach (d; declared)
                if (d == m)
                    return true;
            return false;
        }

        string allow;
        void add(string m)
        {
            allow ~= (allow.length != 0 ? ", " : "") ~ m;
        }

        if (has(METHOD_GET))
        {
            add(METHOD_GET);
            add(METHOD_HEAD);
        }
        if (has(METHOD_PATCH))
            add(METHOD_PATCH);
        if (has(METHOD_POST))
            add(METHOD_POST);
        if (has(METHOD_PUT))
            add(METHOD_PUT);
        if (has(METHOD_DELETE))
            add(METHOD_DELETE);
        add(METHOD_OPTIONS);
        add(METHOD_TRACE);
        resp.setHeader("Allow", allow);
    }

    /// The `doXxx` methods a subclass implements (Java finds them by reflection; R4-style, a subclass lists them).
    protected string[] getDeclaredMethods()
    {
        return null;
    }

    /// Handles TRACE; Flint answers 405 (Tomcat disables TRACE by default).
    protected void doTrace(HttpServletRequest req, HttpServletResponse resp)
    {
        resp.sendError(HttpServletResponse.SC_METHOD_NOT_ALLOWED);
    }

    /// The `Last-Modified` time, or `-1`.
    protected long getLastModified(HttpServletRequest req)
    {
        return -1;
    }

    /// Dispatches by method.
    protected void service(HttpServletRequest req, HttpServletResponse resp)
    {
        const method = req.getMethod();
        switch (method)
        {
        case METHOD_GET:
            doGet(req, resp);
            break;
        case METHOD_HEAD:
            doHead(req, resp);
            break;
        case METHOD_POST:
            doPost(req, resp);
            break;
        case METHOD_PUT:
            doPut(req, resp);
            break;
        case METHOD_PATCH:
            doPatch(req, resp);
            break;
        case METHOD_DELETE:
            doDelete(req, resp);
            break;
        case METHOD_OPTIONS:
            doOptions(req, resp);
            break;
        case METHOD_TRACE:
            doTrace(req, resp);
            break;
        default:
            resp.sendError(HttpServletResponse.SC_NOT_IMPLEMENTED, "Method [" ~ method ~ "] is not implemented by this Servlet for this URI");
        }
    }

    override void service(ServletRequest req, ServletResponse res)
    {
        auto request = cast(HttpServletRequest) req;
        auto response = cast(HttpServletResponse) res;
        if (request is null || response is null)
            throw new ServletException("non-HTTP request or response");
        service(request, response);
    }

    private void sendMethodNotAllowed(HttpServletRequest req, HttpServletResponse resp, string key)
    {
        const protocol = req.getProtocol();
        if (protocol.length == 0 || protocol == "HTTP/0.9" || protocol == "HTTP/1.0")
            resp.sendError(HttpServletResponse.SC_BAD_REQUEST);
        else
            resp.sendError(HttpServletResponse.SC_METHOD_NOT_ALLOWED);
    }
}

/// `jakarta.servlet.http.HttpFilter`.
abstract class HttpFilter : GenericFilter
{
    override void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
    {
        auto request = cast(HttpServletRequest) req;
        auto response = cast(HttpServletResponse) res;
        if (request is null || response is null)
            throw new ServletException("non-HTTP request or response");
        doFilter(request, response, chain);
    }

    /// Filters one HTTP request; the default passes it on.
    protected void doFilter(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
    {
        chain.doFilter(req, res);
    }
}
