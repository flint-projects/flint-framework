/++
`jakarta.servlet`: requests, responses, filters and servlets.

Ported from jakartaee/servlet, jakarta.servlet-api 6.1.0 (the sources jar pinned in api/upstreams.json).
Upstream copyright: Copyright (c) 1997, 2024 Oracle and/or its affiliates and others. All rights reserved.
Copyright 2004 The Apache Software Foundation. The upstream project is EPL-2.0 OR GPL-2.0-with-classpath-
exception; Flint distributes this module under EPL-2.0 only (policy/upstream-licences.json, use
"epl-module"). EPL-2.0 applies to this file; applications that import it are not affected.
SPDX-License-Identifier: EPL-2.0 OR GPL-2.0 WITH Classpath-exception-2.0
Modified by the Flint authors: translated to D under the rulebook (docs/spring/api-mapping.md). Only the
API that Flint Web MVC and its tests use is ported; there is no servlet container. `Object` attributes are
`Any` (R1), `Enumeration<String>` is `string[]` and `Map<String, String[]>` is `string[][string]` (R10).
+/
module flint.jakarta.servlet;

import flint.engine.aot.any : Any;
import flint.java.io : InputStream, IOException, OutputStream, PrintWriter;
import flint.java.util : Locale;

@safe:

/// `jakarta.servlet.ServletException`: a general exception a servlet can throw (R8: checked in Java).
class ServletException : Exception
{
    /// With a message and an optional root cause.
    // dfmt off
    this(string message = null, Throwable rootCause = null, string file = __FILE__, size_t line = __LINE__)
            pure nothrow @nogc
    {
        super(message, file, line, rootCause);
    }
    // dfmt on

    /// With a root cause only; the message is the cause's text.
    this(Throwable rootCause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(rootCause is null ? null : typeid(rootCause).name ~ ": " ~ rootCause.msg, file, line, rootCause);
    }

    /// The root cause, or `null`.
    Throwable getRootCause() pure nothrow @nogc
    {
        return next;
    }

    /// Java's `getMessage()`.
    string getMessage() const pure nothrow @nogc
    {
        return msg;
    }

    /// Java's `getCause()`.
    Throwable getCause() pure nothrow @nogc
    {
        return next;
    }
}

/// `jakarta.servlet.DispatcherType`.
enum DispatcherType
{
    FORWARD, ///
    INCLUDE, ///
    REQUEST, ///
    ASYNC, ///
    ERROR ///
}

/// `jakarta.servlet.RequestDispatcher`: the request attribute names of forwards, includes and error dispatches.
interface RequestDispatcher
{
    enum string FORWARD_REQUEST_URI = "jakarta.servlet.forward.request_uri"; ///
    enum string FORWARD_CONTEXT_PATH = "jakarta.servlet.forward.context_path"; ///
    enum string FORWARD_MAPPING = "jakarta.servlet.forward.mapping"; ///
    enum string FORWARD_PATH_INFO = "jakarta.servlet.forward.path_info"; ///
    enum string FORWARD_SERVLET_PATH = "jakarta.servlet.forward.servlet_path"; ///
    enum string FORWARD_QUERY_STRING = "jakarta.servlet.forward.query_string"; ///
    enum string INCLUDE_REQUEST_URI = "jakarta.servlet.include.request_uri"; ///
    enum string INCLUDE_CONTEXT_PATH = "jakarta.servlet.include.context_path"; ///
    enum string INCLUDE_PATH_INFO = "jakarta.servlet.include.path_info"; ///
    enum string INCLUDE_MAPPING = "jakarta.servlet.include.mapping"; ///
    enum string INCLUDE_SERVLET_PATH = "jakarta.servlet.include.servlet_path"; ///
    enum string INCLUDE_QUERY_STRING = "jakarta.servlet.include.query_string"; ///
    enum string ERROR_EXCEPTION = "jakarta.servlet.error.exception"; ///
    enum string ERROR_EXCEPTION_TYPE = "jakarta.servlet.error.exception_type"; ///
    enum string ERROR_MESSAGE = "jakarta.servlet.error.message"; ///
    enum string ERROR_METHOD = "jakarta.servlet.error.method"; ///
    enum string ERROR_REQUEST_URI = "jakarta.servlet.error.request_uri"; ///
    enum string ERROR_QUERY_STRING = "jakarta.servlet.error.query_string"; ///
    enum string ERROR_SERVLET_NAME = "jakarta.servlet.error.servlet_name"; ///
    enum string ERROR_STATUS_CODE = "jakarta.servlet.error.status_code"; ///

    /// Forwards a request to another resource.
    void forward(ServletRequest request, ServletResponse response);

    /// Includes another resource's content in the response.
    void include(ServletRequest request, ServletResponse response);
}

/// `jakarta.servlet.ServletInputStream`: reads the request body.
abstract class ServletInputStream : InputStream
{
    /// Whether every byte has been read.
    abstract bool isFinished();

    /// Whether data can be read without blocking.
    abstract bool isReady();
}

/// `jakarta.servlet.ServletOutputStream`: writes the response body.
abstract class ServletOutputStream : OutputStream
{
    /// Writes `s` as bytes.
    void print(scope const(char)[] s)
    {
        write(cast(const(ubyte)[]) s);
    }

    /// Writes `s` and a CRLF.
    void println(scope const(char)[] s = null)
    {
        print(s);
        print("\r\n");
    }

    /// Whether data can be written without blocking.
    bool isReady()
    {
        return true;
    }
}

/// `jakarta.servlet.ServletContext`, reduced to what a container-less application needs.
interface ServletContext
{
    /// The context path, `""` for the root context.
    string getContextPath();

    /// The context attribute, or a null `Any`.
    Any getAttribute(string name);

    /// Sets a context attribute.
    void setAttribute(string name, Any object);

    /// The servlet container's name and version.
    string getServerInfo();

    /// The MIME type of a file name, or `null`.
    string getMimeType(string file);

    /// Major and minor version of the Servlet API supported.
    int getMajorVersion();
    /// ditto
    int getMinorVersion();

    /// Adds `servlet` under `servletName`, to be mapped with `ServletRegistration.Dynamic.addMapping`. Returns null
    /// when a servlet of that name exists; throws `IllegalStateException` once the context is initialized.
    ServletRegistration.Dynamic addServlet(string servletName, Servlet servlet);

    /// Adds `filter` under `filterName`, to be mapped with `FilterRegistration.Dynamic.addMappingForUrlPatterns`.
    /// Returns null when a filter of that name exists; throws `IllegalStateException` once the context is
    /// initialized.
    FilterRegistration.Dynamic addFilter(string filterName, Filter filter);
}

/// `jakarta.servlet.Registration`: a servlet or filter registered with a `ServletContext`.
interface Registration
{
    /// The servlet or filter name.
    string getName();

    /// The class name of the servlet or filter.
    string getClassName();

    /// Sets an initialization parameter unless one of that name exists; returns whether it was set.
    bool setInitParameter(string name, string value);

    /// An initialization parameter, or `null`.
    string getInitParameter(string name);

    /// `Registration.Dynamic`: configuration allowed until the context is initialized.
    interface Dynamic : Registration
    {
        /// Whether the servlet or filter supports asynchronous operation.
        void setAsyncSupported(bool isAsyncSupported);
    }
}

/// `jakarta.servlet.ServletRegistration`. `Set<String>` is `string[]` (R10).
interface ServletRegistration : Registration
{
    /// Adds URL patterns; returns those already mapped to another servlet, which are left unchanged.
    string[] addMapping(string[] urlPatterns...);

    /// The URL patterns mapped to this servlet.
    string[] getMappings();

    /// The run-as role, or `null`.
    string getRunAsRole();

    /// `ServletRegistration.Dynamic`.
    interface Dynamic : ServletRegistration, Registration.Dynamic
    {
        /// The load-on-startup order; negative for lazy loading.
        void setLoadOnStartup(int loadOnStartup);

        /// Sets the run-as role.
        void setRunAsRole(string roleName);
    }
}

/// `jakarta.servlet.FilterRegistration`. `EnumSet<DispatcherType>` is `DispatcherType[]` and `Collection<String>`
/// is `string[]` (R10).
interface FilterRegistration : Registration
{
    /// Maps the filter to servlet names, before (`isMatchAfter` false) or after the mappings declared so far.
    void addMappingForServletNames(DispatcherType[] dispatcherTypes, bool isMatchAfter, string[] servletNames...);

    /// The servlet names the filter is mapped to.
    string[] getServletNameMappings();

    /// Maps the filter to URL patterns, before (`isMatchAfter` false) or after the mappings declared so far. A
    /// null `dispatcherTypes` means `REQUEST`.
    void addMappingForUrlPatterns(DispatcherType[] dispatcherTypes, bool isMatchAfter, string[] urlPatterns...);

    /// The URL patterns the filter is mapped to.
    string[] getUrlPatternMappings();

    /// `FilterRegistration.Dynamic`.
    interface Dynamic : FilterRegistration, Registration.Dynamic
    {
    }
}

/// `jakarta.servlet.ServletConfig`.
interface ServletConfig
{
    /// The servlet's name.
    string getServletName();

    /// The context the servlet runs in.
    ServletContext getServletContext();

    /// An initialization parameter, or `null`.
    string getInitParameter(string name);

    /// The initialization parameter names.
    string[] getInitParameterNames();
}

/// `jakarta.servlet.FilterConfig`.
interface FilterConfig
{
    /// The filter's name.
    string getFilterName();

    /// The context the filter runs in.
    ServletContext getServletContext();

    /// An initialization parameter, or `null`.
    string getInitParameter(string name);

    /// The initialization parameter names.
    string[] getInitParameterNames();
}

/// `jakarta.servlet.ServletRequest`.
interface ServletRequest
{
    /// The attribute `name`, or a null `Any`.
    Any getAttribute(string name);

    /// The attribute names.
    string[] getAttributeNames();

    /// The character encoding of the body, or `null`.
    string getCharacterEncoding();

    /// Overrides the character encoding of the body.
    void setCharacterEncoding(string env);

    /// The body length, or `-1`.
    int getContentLength();

    /// ditto
    long getContentLengthLong();

    /// The `Content-Type`, or `null`.
    string getContentType();

    /// The body as bytes.
    ServletInputStream getInputStream();

    /// The first value of a query or form parameter, or `null`.
    string getParameter(string name);

    /// The parameter names in order.
    string[] getParameterNames();

    /// Every value of a parameter, or `null`.
    string[] getParameterValues(string name);

    /// Every parameter and its values.
    string[][string] getParameterMap();

    /// `HTTP/1.1`.
    string getProtocol();

    /// `http` or `https`.
    string getScheme();

    /// The host the request was sent to.
    string getServerName();

    /// The port the request was sent to.
    int getServerPort();

    /// The client address.
    string getRemoteAddr();

    /// The client host name, or its address.
    string getRemoteHost();

    /// Sets an attribute.
    void setAttribute(string name, Any o);

    /// Removes an attribute.
    void removeAttribute(string name);

    /// Whether the request came over a secure channel.
    bool isSecure();

    /// A dispatcher for `path`, or `null`.
    RequestDispatcher getRequestDispatcher(string path);

    /// The client port.
    int getRemotePort();

    /// The local host name.
    string getLocalName();

    /// The local address.
    string getLocalAddr();

    /// The local port.
    int getLocalPort();

    /// The context the request runs in.
    ServletContext getServletContext();

    /// Whether async processing is supported (always `false` in Flint).
    bool isAsyncSupported();

    /// The dispatcher type of the request.
    DispatcherType getDispatcherType();

    /// A container-assigned identifier.
    string getRequestId();

    /// The protocol's own request identifier, or `""`.
    string getProtocolRequestId();

    /// The preferred locale from `Accept-Language`, or the server's default locale when there is none.
    Locale getLocale();

    /// The acceptable locales in decreasing preference, or the server's default locale alone
    /// (`Enumeration<Locale>` is `Locale[]`, R10).
    Locale[] getLocales();
}

/// `jakarta.servlet.ServletResponse`.
interface ServletResponse
{
    /// The response character encoding (`ISO-8859-1` by default).
    string getCharacterEncoding();

    /// The `Content-Type` as set, with its charset, or `null`.
    string getContentType();

    /// The body as bytes.
    ServletOutputStream getOutputStream();

    /// The body as characters, in the response encoding.
    PrintWriter getWriter();

    /// Sets the response encoding.
    void setCharacterEncoding(string charset);

    /// Sets `Content-Length`.
    void setContentLength(int len);

    /// ditto
    void setContentLengthLong(long len);

    /// Sets `Content-Type`, and the encoding when it names a charset.
    void setContentType(string type);

    /// Sets the buffer size.
    void setBufferSize(int size);

    /// The buffer size.
    int getBufferSize();

    /// Commits the response, writing status, headers and buffered body.
    void flushBuffer();

    /// Discards the buffered body. Throws `IllegalStateException` once committed.
    void resetBuffer();

    /// Whether status and headers have been written.
    bool isCommitted();

    /// Discards status, headers and buffered body. Throws `IllegalStateException` once committed.
    void reset();

    /// Sets the response locale, which sets `Content-Language`; ignored once the response is committed.
    void setLocale(Locale loc);

    /// The response locale: the last one set, else the server's default.
    Locale getLocale();
}

/++
`jakarta.servlet.ServletRequestWrapper`: a request that delegates every call to the request it wraps. Filters
subclass it to change part of a request, and pass the wrapper down the chain.
+/
class ServletRequestWrapper : ServletRequest
{
    private ServletRequest request;

    /// Wraps `request`. Throws `IllegalArgumentException` when it is null.
    this(ServletRequest request)
    {
        if (request is null)
            throw new imported!"flint.java.lang".IllegalArgumentException("Request cannot be null");
        this.request = request;
    }

    /// The wrapped request.
    ServletRequest getRequest() pure nothrow @nogc
    {
        return request;
    }

    /// Replaces the wrapped request. Throws `IllegalArgumentException` when it is null.
    void setRequest(ServletRequest request)
    {
        if (request is null)
            throw new imported!"flint.java.lang".IllegalArgumentException("Request cannot be null");
        this.request = request;
    }

    /// Whether this wrapper wraps `wrapped`, directly or through other wrappers.
    bool isWrapperFor(ServletRequest wrapped)
    {
        if (request is wrapped)
            return true;
        if (auto inner = cast(ServletRequestWrapper) request)
            return inner.isWrapperFor(wrapped);
        return false;
    }

    /// Calls `getAttribute` on the wrapped request.
    Any getAttribute(string name)
    {
        return request.getAttribute(name);
    }

    /// Calls `getAttributeNames` on the wrapped request.
    string[] getAttributeNames()
    {
        return request.getAttributeNames();
    }

    /// Calls `getCharacterEncoding` on the wrapped request.
    string getCharacterEncoding()
    {
        return request.getCharacterEncoding();
    }

    /// Calls `setCharacterEncoding` on the wrapped request.
    void setCharacterEncoding(string env)
    {
        request.setCharacterEncoding(env);
    }

    /// Calls `getContentLength` on the wrapped request.
    int getContentLength()
    {
        return request.getContentLength();
    }

    /// Calls `getContentLengthLong` on the wrapped request.
    long getContentLengthLong()
    {
        return request.getContentLengthLong();
    }

    /// Calls `getContentType` on the wrapped request.
    string getContentType()
    {
        return request.getContentType();
    }

    /// Calls `getInputStream` on the wrapped request.
    ServletInputStream getInputStream()
    {
        return request.getInputStream();
    }

    /// Calls `getParameter` on the wrapped request.
    string getParameter(string name)
    {
        return request.getParameter(name);
    }

    /// Calls `getParameterNames` on the wrapped request.
    string[] getParameterNames()
    {
        return request.getParameterNames();
    }

    /// Calls `getParameterValues` on the wrapped request.
    string[] getParameterValues(string name)
    {
        return request.getParameterValues(name);
    }

    /// Calls `getParameterMap` on the wrapped request.
    string[][string] getParameterMap()
    {
        return request.getParameterMap();
    }

    /// Calls `getProtocol` on the wrapped request.
    string getProtocol()
    {
        return request.getProtocol();
    }

    /// Calls `getScheme` on the wrapped request.
    string getScheme()
    {
        return request.getScheme();
    }

    /// Calls `getServerName` on the wrapped request.
    string getServerName()
    {
        return request.getServerName();
    }

    /// Calls `getServerPort` on the wrapped request.
    int getServerPort()
    {
        return request.getServerPort();
    }

    /// Calls `getRemoteAddr` on the wrapped request.
    string getRemoteAddr()
    {
        return request.getRemoteAddr();
    }

    /// Calls `getRemoteHost` on the wrapped request.
    string getRemoteHost()
    {
        return request.getRemoteHost();
    }

    /// Calls `setAttribute` on the wrapped request.
    void setAttribute(string name, Any o)
    {
        request.setAttribute(name, o);
    }

    /// Calls `removeAttribute` on the wrapped request.
    void removeAttribute(string name)
    {
        request.removeAttribute(name);
    }

    /// Calls `isSecure` on the wrapped request.
    bool isSecure()
    {
        return request.isSecure();
    }

    /// Calls `getRequestDispatcher` on the wrapped request.
    RequestDispatcher getRequestDispatcher(string path)
    {
        return request.getRequestDispatcher(path);
    }

    /// Calls `getRemotePort` on the wrapped request.
    int getRemotePort()
    {
        return request.getRemotePort();
    }

    /// Calls `getLocalName` on the wrapped request.
    string getLocalName()
    {
        return request.getLocalName();
    }

    /// Calls `getLocalAddr` on the wrapped request.
    string getLocalAddr()
    {
        return request.getLocalAddr();
    }

    /// Calls `getLocalPort` on the wrapped request.
    int getLocalPort()
    {
        return request.getLocalPort();
    }

    /// Calls `getServletContext` on the wrapped request.
    ServletContext getServletContext()
    {
        return request.getServletContext();
    }

    /// Calls `isAsyncSupported` on the wrapped request.
    bool isAsyncSupported()
    {
        return request.isAsyncSupported();
    }

    /// Calls `getDispatcherType` on the wrapped request.
    DispatcherType getDispatcherType()
    {
        return request.getDispatcherType();
    }

    /// Calls `getRequestId` on the wrapped request.
    string getRequestId()
    {
        return request.getRequestId();
    }

    /// Calls `getProtocolRequestId` on the wrapped request.
    string getProtocolRequestId()
    {
        return request.getProtocolRequestId();
    }

    /// Calls `getLocale` on the wrapped request.
    Locale getLocale()
    {
        return request.getLocale();
    }

    /// Calls `getLocales` on the wrapped request.
    Locale[] getLocales()
    {
        return request.getLocales();
    }
}

/++
`jakarta.servlet.ServletResponseWrapper`: a response that delegates every call to the response it wraps.
+/
class ServletResponseWrapper : ServletResponse
{
    private ServletResponse response;

    /// Wraps `response`. Throws `IllegalArgumentException` when it is null.
    this(ServletResponse response)
    {
        if (response is null)
            throw new imported!"flint.java.lang".IllegalArgumentException("Response cannot be null");
        this.response = response;
    }

    /// The wrapped response.
    ServletResponse getResponse() pure nothrow @nogc
    {
        return response;
    }

    /// Replaces the wrapped response. Throws `IllegalArgumentException` when it is null.
    void setResponse(ServletResponse response)
    {
        if (response is null)
            throw new imported!"flint.java.lang".IllegalArgumentException("Response cannot be null");
        this.response = response;
    }

    /// Whether this wrapper wraps `wrapped`, directly or through other wrappers.
    bool isWrapperFor(ServletResponse wrapped)
    {
        if (response is wrapped)
            return true;
        if (auto inner = cast(ServletResponseWrapper) response)
            return inner.isWrapperFor(wrapped);
        return false;
    }

    /// Calls `getCharacterEncoding` on the wrapped response.
    string getCharacterEncoding()
    {
        return response.getCharacterEncoding();
    }

    /// Calls `getContentType` on the wrapped response.
    string getContentType()
    {
        return response.getContentType();
    }

    /// Calls `getOutputStream` on the wrapped response.
    ServletOutputStream getOutputStream()
    {
        return response.getOutputStream();
    }

    /// Calls `getWriter` on the wrapped response.
    PrintWriter getWriter()
    {
        return response.getWriter();
    }

    /// Calls `setCharacterEncoding` on the wrapped response.
    void setCharacterEncoding(string charset)
    {
        response.setCharacterEncoding(charset);
    }

    /// Calls `setContentLength` on the wrapped response.
    void setContentLength(int len)
    {
        response.setContentLength(len);
    }

    /// Calls `setContentLengthLong` on the wrapped response.
    void setContentLengthLong(long len)
    {
        response.setContentLengthLong(len);
    }

    /// Calls `setContentType` on the wrapped response.
    void setContentType(string type)
    {
        response.setContentType(type);
    }

    /// Calls `setBufferSize` on the wrapped response.
    void setBufferSize(int size)
    {
        response.setBufferSize(size);
    }

    /// Calls `getBufferSize` on the wrapped response.
    int getBufferSize()
    {
        return response.getBufferSize();
    }

    /// Calls `flushBuffer` on the wrapped response.
    void flushBuffer()
    {
        response.flushBuffer();
    }

    /// Calls `resetBuffer` on the wrapped response.
    void resetBuffer()
    {
        response.resetBuffer();
    }

    /// Calls `isCommitted` on the wrapped response.
    bool isCommitted()
    {
        return response.isCommitted();
    }

    /// Calls `reset` on the wrapped response.
    void reset()
    {
        response.reset();
    }

    /// Calls `setLocale` on the wrapped response.
    void setLocale(Locale loc)
    {
        response.setLocale(loc);
    }

    /// Calls `getLocale` on the wrapped response.
    Locale getLocale()
    {
        return response.getLocale();
    }
}

/// `jakarta.servlet.FilterChain`.
interface FilterChain
{
    /// Invokes the next filter, or the servlet at the end of the chain.
    void doFilter(ServletRequest request, ServletResponse response);
}

/// `jakarta.servlet.Filter`. `init` and `destroy` are defaults: `mixin Filter.Defaults;` (R3).
interface Filter
{
    /// Called once before the filter is used.
    void init(FilterConfig filterConfig);

    /// Filters one request.
    void doFilter(ServletRequest request, ServletResponse response, FilterChain chain);

    /// Called once when the filter is taken out of service.
    void destroy();

    /// Java's default methods. Names resolve where the template is mixed in, so the type is named by its module.
    mixin template Defaults()
    {
        ///
        void init(imported!"flint.jakarta.servlet".FilterConfig filterConfig)
        {
        }

        ///
        void destroy()
        {
        }
    }
}

/// `jakarta.servlet.Servlet`.
interface Servlet
{
    /// Called once before the servlet serves requests.
    void init(ServletConfig config);

    /// The configuration passed to `init`.
    ServletConfig getServletConfig();

    /// Serves one request.
    void service(ServletRequest req, ServletResponse res);

    /// Author, version and copyright.
    string getServletInfo();

    /// Called once when the servlet is taken out of service.
    void destroy();
}

/// `jakarta.servlet.GenericServlet`.
abstract class GenericServlet : Servlet, ServletConfig
{
    private ServletConfig config;

    override void destroy()
    {
    }

    override string getInitParameter(string name)
    {
        return config is null ? null : config.getInitParameter(name);
    }

    override string[] getInitParameterNames()
    {
        return config is null ? null : config.getInitParameterNames();
    }

    override ServletConfig getServletConfig()
    {
        return config;
    }

    override ServletContext getServletContext()
    {
        return config is null ? null : config.getServletContext();
    }

    override string getServletInfo()
    {
        return "";
    }

    override void init(ServletConfig config)
    {
        this.config = config;
        init();
    }

    /// Called by `init(ServletConfig)`; override instead of it.
    void init()
    {
    }

    override string getServletName()
    {
        return config is null ? null : config.getServletName();
    }

    abstract override void service(ServletRequest req, ServletResponse res);
}

/// `jakarta.servlet.GenericFilter`.
abstract class GenericFilter : Filter, FilterConfig
{
    private FilterConfig config;

    override string getInitParameter(string name)
    {
        return config is null ? null : config.getInitParameter(name);
    }

    override string[] getInitParameterNames()
    {
        return config is null ? null : config.getInitParameterNames();
    }

    /// The configuration passed to `init`.
    FilterConfig getFilterConfig()
    {
        return config;
    }

    override ServletContext getServletContext()
    {
        return config is null ? null : config.getServletContext();
    }

    override void init(FilterConfig filterConfig)
    {
        config = filterConfig;
        init();
    }

    /// Called by `init(FilterConfig)`.
    void init()
    {
    }

    override string getFilterName()
    {
        return config is null ? null : config.getFilterName();
    }

    override void destroy()
    {
    }
}
