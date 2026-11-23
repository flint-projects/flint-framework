/++
`org.springframework.mock.web`: servlet API mocks for tests.

Ported from spring-projects/spring-framework v7.1.0, spring-test/src/main/java/org/springframework/mock/web/
(MockHttpServletRequest.java, MockHttpServletResponse.java, MockServletContext.java, DelegatingServletInputStream,
DelegatingServletOutputStream).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. Header and parameter maps keep Spring's
insertion order and case rules. `sendError` records the status and message and commits the response, as the
Spring mock does; there is no container, so no error page is rendered.
+/
module flint.mock.web;

import flint.engine.aot.any : Any;
import flint.http : HttpHeaders, MediaType;
import flint.jakarta.servlet : DispatcherType, RequestDispatcher, ServletContext,
    ServletInputStream, ServletOutputStream;
import flint.jakarta.servlet.http : Cookie, HttpServletRequest, HttpServletResponse;
import flint.java.io : PrintWriter, Writer;
import flint.java.lang : IllegalStateException;

@safe:

/// `MockServletContext`.
class MockServletContext : ServletContext
{
    private string contextPath = "";
    private Any[string] attributes;

    string getContextPath()
    {
        return contextPath;
    }

    /// Sets the context path.
    void setContextPath(string contextPath) pure nothrow @nogc
    {
        this.contextPath = contextPath;
    }

    Any getAttribute(string name)
    {
        if (auto value = name in attributes)
            return *value;
        return Any.init;
    }

    void setAttribute(string name, Any object)
    {
        attributes[name] = object;
    }

    string getServerInfo()
    {
        return "MockServletContext";
    }

    string getMimeType(string file)
    {
        return null;
    }

    int getMajorVersion()
    {
        return 6;
    }

    int getMinorVersion()
    {
        return 1;
    }
}

private struct Pair
{
    string name;
    string[] values;
}

private ptrdiff_t findPair(Pair[] pairs, scope const(char)[] name, bool ignoreCase) pure nothrow @nogc
{
    foreach (i, ref p; pairs)
        if (ignoreCase ? equalsIgnoreCase(p.name, name) : p.name == name)
            return i;
    return -1;
}

private final class BytesInput : ServletInputStream
{
    private const(ubyte)[] content;
    private size_t position;

    this(const(ubyte)[] content) pure nothrow @nogc
    {
        this.content = content;
    }

    override int read()
    {
        return position < content.length ? content[position++] : -1;
    }

    override ubyte[] readAllBytes()
    {
        auto rest = content[position .. $].dup;
        position = content.length;
        return rest;
    }

    override bool isFinished()
    {
        return position >= content.length;
    }

    override bool isReady()
    {
        return true;
    }
}

/// `MockHttpServletRequest`.
class MockHttpServletRequest : HttpServletRequest
{
    private string method = "";
    private string requestURI = "";
    private string contextPath = "";
    private string servletPath = "";
    private string pathInfo;
    private string queryString;
    private Pair[] parameters;
    private Pair[] headers;
    private string[] attributeNames;
    private Any[string] attributes;
    private const(ubyte)[] content;
    private string characterEncoding;
    private string contentType;
    private Cookie[] cookies;
    private string scheme = "http";
    private string serverName = "localhost";
    private int serverPort = 80;
    private string remoteAddr = "127.0.0.1";
    private string protocol = "HTTP/1.1";
    private DispatcherType dispatcherType = DispatcherType.REQUEST;
    private MockServletContext servletContext;

    /// With a method and request URI.
    this(string method = "", string requestURI = "")
    {
        this.method = method;
        this.requestURI = requestURI;
        servletContext = new MockServletContext;
    }

    /// Sets the method.
    void setMethod(string method) pure nothrow @nogc
    {
        this.method = method;
    }

    /// Sets the request URI.
    void setRequestURI(string requestURI) pure nothrow @nogc
    {
        this.requestURI = requestURI;
    }

    /// Sets the context path.
    void setContextPath(string contextPath) pure nothrow @nogc
    {
        this.contextPath = contextPath;
    }

    /// Sets the servlet path.
    void setServletPath(string servletPath) pure nothrow @nogc
    {
        this.servletPath = servletPath;
    }

    /// Sets the query string.
    void setQueryString(string queryString) pure nothrow @nogc
    {
        this.queryString = queryString;
    }

    /// Adds a parameter value.
    void addParameter(string name, string[] values...)
    {
        const i = findPair(parameters, name, false);
        if (i >= 0)
            parameters[i].values ~= values;
        else
            parameters ~= Pair(name, values.dup);
    }

    /// Sets a parameter's values.
    void setParameter(string name, string[] values...)
    {
        const i = findPair(parameters, name, false);
        if (i >= 0)
            parameters[i].values = values.dup;
        else
            parameters ~= Pair(name, values.dup);
    }

    /// Adds a header value; `Content-Type` also sets the content type.
    void addHeader(string name, string value)
    {
        if (equalsIgnoreCase(name, HttpHeaders.CONTENT_TYPE) && contentType is null)
            setContentType(value);
        const i = findPair(headers, name, true);
        if (i >= 0)
            headers[i].values ~= value;
        else
            headers ~= Pair(name, [value]);
    }

    /// Sets the body.
    void setContent(const(ubyte)[] content) pure nothrow @nogc
    {
        this.content = content;
    }

    /// Sets the content type (and the encoding when it names a charset).
    void setContentType(string contentType)
    {
        this.contentType = contentType;
        if (contentType !is null)
        {
            try
            {
                auto mediaType = MediaType.parseMediaType(contentType);
                if (auto charset = mediaType.getCharset())
                    characterEncoding = charset.name();
            }
            catch (Exception)
            {
            }
            const i = findPair(headers, HttpHeaders.CONTENT_TYPE, true);
            if (i >= 0)
                headers[i].values = [contentType];
            else
                headers ~= Pair(HttpHeaders.CONTENT_TYPE, [contentType]);
        }
    }

    /// Sets the cookies.
    void setCookies(Cookie[] cookies...) pure nothrow
    {
        this.cookies = cookies.dup;
    }

    /// Sets the dispatcher type.
    void setDispatcherType(DispatcherType dispatcherType) pure nothrow @nogc
    {
        this.dispatcherType = dispatcherType;
    }

    /// Sets the server name.
    void setServerName(string serverName) pure nothrow @nogc
    {
        this.serverName = serverName;
    }

    /// Sets the server port.
    void setServerPort(int serverPort) pure nothrow @nogc
    {
        this.serverPort = serverPort;
    }

    /// Sets the scheme.
    void setScheme(string scheme) pure nothrow @nogc
    {
        this.scheme = scheme;
    }

    /// Sets the remote address.
    void setRemoteAddr(string remoteAddr) pure nothrow @nogc
    {
        this.remoteAddr = remoteAddr;
    }

    /// The body.
    const(ubyte)[] getContentAsByteArray() pure nothrow @nogc
    {
        return content;
    }

    // ----- ServletRequest

    Any getAttribute(string name)
    {
        if (auto value = name in attributes)
            return *value;
        return Any.init;
    }

    string[] getAttributeNames()
    {
        return attributeNames.dup;
    }

    string getCharacterEncoding()
    {
        return characterEncoding;
    }

    void setCharacterEncoding(string env)
    {
        characterEncoding = env;
    }

    int getContentLength()
    {
        return content is null ? -1 : cast(int) content.length;
    }

    long getContentLengthLong()
    {
        return content is null ? -1 : cast(long) content.length;
    }

    string getContentType()
    {
        return contentType;
    }

    ServletInputStream getInputStream()
    {
        return new BytesInput(content);
    }

    string getParameter(string name)
    {
        const i = findPair(parameters, name, false);
        return i >= 0 && parameters[i].values.length != 0 ? parameters[i].values[0] : null;
    }

    string[] getParameterNames()
    {
        string[] names;
        foreach (p; parameters)
            names ~= p.name;
        return names;
    }

    string[] getParameterValues(string name)
    {
        const i = findPair(parameters, name, false);
        return i >= 0 ? parameters[i].values : null;
    }

    string[][string] getParameterMap()
    {
        string[][string] map;
        foreach (p; parameters)
            map[p.name] = p.values;
        return map;
    }

    string getProtocol()
    {
        return protocol;
    }

    string getScheme()
    {
        return scheme;
    }

    string getServerName()
    {
        return serverName;
    }

    int getServerPort()
    {
        return serverPort;
    }

    string getRemoteAddr()
    {
        return remoteAddr;
    }

    string getRemoteHost()
    {
        return "localhost";
    }

    void setAttribute(string name, Any o)
    {
        if (o.isNull())
        {
            removeAttribute(name);
            return;
        }
        if (name !in attributes)
            attributeNames ~= name;
        attributes[name] = o;
    }

    void removeAttribute(string name)
    {
        if (name !in attributes)
            return;
        attributes.remove(name);
        foreach (i, n; attributeNames)
            if (n == name)
            {
                attributeNames = attributeNames[0 .. i] ~ attributeNames[i + 1 .. $];
                break;
            }
    }

    bool isSecure()
    {
        return scheme == "https";
    }

    RequestDispatcher getRequestDispatcher(string path)
    {
        return null;
    }

    int getRemotePort()
    {
        return 80;
    }

    string getLocalName()
    {
        return "localhost";
    }

    string getLocalAddr()
    {
        return "127.0.0.1";
    }

    int getLocalPort()
    {
        return 80;
    }

    ServletContext getServletContext()
    {
        return servletContext;
    }

    bool isAsyncSupported()
    {
        return false;
    }

    DispatcherType getDispatcherType()
    {
        return dispatcherType;
    }

    string getRequestId()
    {
        return "";
    }

    string getProtocolRequestId()
    {
        return "";
    }

    // ----- HttpServletRequest

    string getAuthType()
    {
        return null;
    }

    Cookie[] getCookies()
    {
        return cookies.length == 0 ? null : cookies;
    }

    long getDateHeader(string name)
    {
        auto headersView = HttpHeaders.create();
        foreach (value; getHeaders(name))
            headersView.add(name, value);
        return headersView.getFirstDate(name);
    }

    string getHeader(string name)
    {
        const i = findPair(headers, name, true);
        return i >= 0 && headers[i].values.length != 0 ? headers[i].values[0] : null;
    }

    string[] getHeaders(string name)
    {
        const i = findPair(headers, name, true);
        return i >= 0 ? headers[i].values : null;
    }

    string[] getHeaderNames()
    {
        string[] names;
        foreach (h; headers)
            names ~= h.name;
        return names;
    }

    int getIntHeader(string name)
    {
        import std.conv : to;

        const value = getHeader(name);
        return value is null ? -1 : value.to!int;
    }

    string getMethod()
    {
        return method;
    }

    string getPathInfo()
    {
        return pathInfo;
    }

    string getPathTranslated()
    {
        return null;
    }

    string getContextPath()
    {
        return contextPath;
    }

    string getQueryString()
    {
        return queryString;
    }

    string getRemoteUser()
    {
        return null;
    }

    bool isUserInRole(string role)
    {
        return false;
    }

    string getRequestedSessionId()
    {
        return null;
    }

    string getRequestURI()
    {
        return requestURI;
    }

    string getRequestURL()
    {
        import std.conv : to;

        const defaultPort = (scheme == "http" && serverPort == 80) || (scheme == "https" && serverPort == 443);
        return scheme ~ "://" ~ serverName ~ (defaultPort ? "" : ":" ~ serverPort.to!string) ~ requestURI;
    }

    string getServletPath()
    {
        return servletPath;
    }

    bool isRequestedSessionIdValid()
    {
        return false;
    }
}

private final class BytesOutput : ServletOutputStream
{
    private MockHttpServletResponse response;

    this(MockHttpServletResponse response) pure nothrow @nogc
    {
        this.response = response;
    }

    override void write(int b)
    {
        response.content ~= cast(ubyte) b;
    }

    override void write(scope const(ubyte)[] b)
    {
        response.content ~= b;
    }

    override void flush()
    {
        response.setCommitted(true);
    }
}

private final class ContentWriter : Writer
{
    private MockHttpServletResponse response;

    this(MockHttpServletResponse response) pure nothrow @nogc
    {
        this.response = response;
    }

    override void write(scope const(char)[] text)
    {
        response.content ~= cast(const(ubyte)[]) text;
    }

    override void flush()
    {
        response.setCommitted(true);
    }
}

/// `MockHttpServletResponse`.
class MockHttpServletResponse : HttpServletResponse
{
    private int status = HttpServletResponse.SC_OK;
    private string errorMessage;
    private Pair[] headers;
    private string contentType;
    private string characterEncoding = "ISO-8859-1";
    private bool characterEncodingSet;
    private long contentLength = -1;
    package ubyte[] content;
    private bool committed;
    private Cookie[] cookies;
    private string redirectedUrl;
    private ServletOutputStream outputStream;
    private PrintWriter writer;

    // ----- inspection

    /// The body bytes.
    const(ubyte)[] getContentAsByteArray() const pure nothrow @nogc
    {
        return content;
    }

    /// The body decoded with the response encoding (`ISO-8859-1` unless set).
    string getContentAsString() const
    {
        if (characterEncoding == "UTF-8" || characterEncoding == "utf-8")
            return cast(string) content.idup;
        // ISO-8859-1: each byte is one code point.
        string result;
        foreach (b; content)
            result ~= cast(dchar) b;
        return result;
    }

    /// The body decoded as `charset` (UTF-8 or ISO-8859-1).
    string getContentAsString(string charset) const
    {
        if (equalsIgnoreCase(charset, "UTF-8"))
            return cast(string) content.idup;
        string result;
        foreach (b; content)
            result ~= cast(dchar) b;
        return result;
    }

    /// The `sendError` message, or `null`.
    string getErrorMessage() const pure nothrow @nogc
    {
        return errorMessage;
    }

    /// The `sendRedirect` target, or `null`.
    string getRedirectedUrl() const pure nothrow @nogc
    {
        return redirectedUrl;
    }

    /// The cookies added.
    Cookie[] getCookies() pure nothrow @nogc
    {
        return cookies;
    }

    /// Marks the response committed.
    void setCommitted(bool committed) pure nothrow @nogc
    {
        this.committed = committed;
    }

    // ----- ServletResponse

    string getCharacterEncoding()
    {
        return characterEncoding;
    }

    string getContentType()
    {
        return contentType;
    }

    ServletOutputStream getOutputStream()
    {
        if (outputStream is null)
            outputStream = new BytesOutput(this);
        return outputStream;
    }

    PrintWriter getWriter()
    {
        if (writer is null)
            writer = new PrintWriter(new ContentWriter(this));
        return writer;
    }

    void setCharacterEncoding(string charset)
    {
        characterEncoding = charset;
        characterEncodingSet = true;
        updateContentTypeHeader();
    }

    void setContentLength(int len)
    {
        setContentLengthLong(len);
    }

    void setContentLengthLong(long len)
    {
        import std.conv : to;

        contentLength = len;
        setHeaderValue(HttpHeaders.CONTENT_LENGTH, len.to!string, false);
    }

    /// The content length set, or `-1`.
    long getContentLengthLong() const pure nothrow @nogc
    {
        return contentLength;
    }

    void setContentType(string type)
    {
        contentType = type;
        if (type !is null)
        {
            try
            {
                auto mediaType = MediaType.parseMediaType(type);
                if (auto charset = mediaType.getCharset())
                {
                    characterEncoding = charset.name();
                    characterEncodingSet = true;
                }
            }
            catch (Exception)
            {
            }
            updateContentTypeHeader();
        }
        else
        {
            const i = findPair(headers, HttpHeaders.CONTENT_TYPE, true);
            if (i >= 0)
                headers = headers[0 .. i] ~ headers[i + 1 .. $];
        }
    }

    private void updateContentTypeHeader()
    {
        if (contentType is null)
            return;
        string value = contentType;
        if (characterEncodingSet && !containsCharset(value))
            value ~= ";charset=" ~ characterEncoding;
        contentType = value;
        setHeaderValue(HttpHeaders.CONTENT_TYPE, value, false);
    }

    private static bool containsCharset(string type)
    {
        import std.uni : toLower;

        foreach (i; 0 .. type.length)
            if (i + 8 <= type.length && type[i .. i + 8].toLower == "charset=")
                return true;
        return false;
    }

    void setBufferSize(int size)
    {
    }

    int getBufferSize()
    {
        return 4096;
    }

    void flushBuffer()
    {
        committed = true;
    }

    void resetBuffer()
    {
        if (committed)
            throw new IllegalStateException("Cannot reset buffer - response is already committed");
        content = null;
    }

    bool isCommitted()
    {
        return committed;
    }

    void reset()
    {
        resetBuffer();
        characterEncoding = "ISO-8859-1";
        characterEncodingSet = false;
        contentLength = -1;
        contentType = null;
        headers = null;
        status = HttpServletResponse.SC_OK;
        errorMessage = null;
    }

    // ----- HttpServletResponse

    void addCookie(Cookie cookie)
    {
        cookies ~= cookie;
        addHeader("Set-Cookie", cookie.getName() ~ "=" ~ cookie.getValue());
    }

    bool containsHeader(string name)
    {
        return findPair(headers, name, true) >= 0;
    }

    string encodeURL(string url)
    {
        return url;
    }

    string encodeRedirectURL(string url)
    {
        return url;
    }

    void sendError(int sc, string msg)
    {
        if (committed)
            throw new IllegalStateException("Cannot set error status - response is already committed");
        status = sc;
        errorMessage = msg;
        committed = true;
    }

    void sendError(int sc)
    {
        sendError(sc, null);
    }

    void sendRedirect(string location)
    {
        if (committed)
            throw new IllegalStateException("Cannot send redirect - response is already committed");
        setHeader(HttpHeaders.LOCATION, location);
        setStatus(HttpServletResponse.SC_MOVED_TEMPORARILY);
        redirectedUrl = location;
        committed = true;
    }

    void setDateHeader(string name, long date)
    {
        setHeaderValue(name, HttpHeaders.formatDate(date), false);
    }

    void addDateHeader(string name, long date)
    {
        setHeaderValue(name, HttpHeaders.formatDate(date), true);
    }

    void setHeader(string name, string value)
    {
        if (equalsIgnoreCase(name, HttpHeaders.CONTENT_TYPE))
            setContentType(value);
        else if (equalsIgnoreCase(name, HttpHeaders.CONTENT_LENGTH))
        {
            import std.conv : to;

            setContentLengthLong(value.to!long);
        }
        else
            setHeaderValue(name, value, false);
    }

    void addHeader(string name, string value)
    {
        if (equalsIgnoreCase(name, HttpHeaders.CONTENT_TYPE))
            setContentType(value);
        else if (equalsIgnoreCase(name, HttpHeaders.CONTENT_LENGTH))
            setHeader(name, value);
        else
            setHeaderValue(name, value, true);
    }

    void setIntHeader(string name, int value)
    {
        import std.conv : to;

        setHeaderValue(name, value.to!string, false);
    }

    void addIntHeader(string name, int value)
    {
        import std.conv : to;

        setHeaderValue(name, value.to!string, true);
    }

    void setStatus(int sc)
    {
        if (!committed)
            status = sc;
    }

    int getStatus()
    {
        return status;
    }

    string getHeader(string name)
    {
        const i = findPair(headers, name, true);
        return i >= 0 && headers[i].values.length != 0 ? headers[i].values[0] : null;
    }

    string[] getHeaders(string name)
    {
        const i = findPair(headers, name, true);
        return i >= 0 ? headers[i].values : null;
    }

    string[] getHeaderNames()
    {
        string[] names;
        foreach (h; headers)
            names ~= h.name;
        return names;
    }

    private void setHeaderValue(string name, string value, bool add)
    {
        const i = findPair(headers, name, true);
        if (i >= 0)
        {
            if (add)
                headers[i].values ~= value;
            else
                headers[i].values = [value];
        }
        else
            headers ~= Pair(name, [value]);
    }
}

/// Java's `String.equalsIgnoreCase` for ASCII header names.
private bool equalsIgnoreCase(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (index, c; a)
    {
        const x = c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
        const y = b[index] >= 'A' && b[index] <= 'Z' ? cast(char)(b[index] + 32) : b[index];
        if (x != y)
            return false;
    }
    return true;
}
