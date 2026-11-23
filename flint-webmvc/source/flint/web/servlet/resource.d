/++
`org.springframework.web.servlet.resource`: static resources, and the 404 for a path nothing serves.

Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/main/java/org/springframework/web/servlet/resource/ (NoResourceFoundException.java,
ResourceHttpRequestHandler.java) and .../mvc/HttpRequestHandlerAdapter.java, .../handler/SimpleUrlHandlerMapping.java,
spring-web's HttpRequestHandler.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: Spring Boot maps `/**` to the static locations; a Flint application has no
classpath resources, so `ResourceHttpRequestHandler` serves nothing yet and raises `NoResourceFoundException`, which
is how Boot answers an unmapped path (a JSON 404 from the error controller).
+/
module flint.web.servlet.resource;

import flint.engine.aot.any : Any;
import flint.http : HttpMethod, HttpStatus, HttpStatusCode, ProblemDetail;
import flint.jakarta.servlet : ServletException;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.web : ErrorResponse, skipBacktrace;
import flint.web.servlet : HandlerAdapter, HandlerMapping, ModelAndView;
import flint.web.servlet.handler : AbstractHandlerMapping, lookupPath;
import flint.web.util.pattern : PathPattern, PathPatternParser;

@safe:

/// `HttpRequestHandler`: a plain request handler.
interface HttpRequestHandler
{
    /// Handles the request.
    void handleRequest(HttpServletRequest request, HttpServletResponse response);
}

/// `NoResourceFoundException`: no static resource for the path (404).
class NoResourceFoundException : ServletException, ErrorResponse
{
    mixin ErrorResponse.Defaults;

    private HttpMethod httpMethod;
    private string resourcePath;
    private ProblemDetail body;

    ///
    this(HttpMethod httpMethod, string requestUri, string resourcePath)
    {
        super("No static resource " ~ resourcePath ~ " for request '" ~ requestUri ~ "'.");
        this.httpMethod = httpMethod;
        this.resourcePath = resourcePath;
        body = ProblemDetail.forStatusAndDetail(getStatusCode(), "No static resource " ~ resourcePath ~ ".");
        skipBacktrace(this);
    }

    /// The method.
    HttpMethod getHttpMethod() const pure nothrow @nogc
    {
        return httpMethod;
    }

    /// The resource path.
    string getResourcePath() const pure nothrow @nogc
    {
        return resourcePath;
    }

    HttpStatusCode getStatusCode()
    {
        return HttpStatus.NOT_FOUND;
    }

    ProblemDetail getBody()
    {
        return
        body;
    }
}

/// `ResourceHttpRequestHandler`: serves static resources; none are configured, so every path is a 404.
class ResourceHttpRequestHandler : HttpRequestHandler
{
    void handleRequest(HttpServletRequest request, HttpServletResponse response)
    {
        auto pathWithin = request.getAttribute(HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE);
        string path = pathWithin.isNull() ? lookupPath(request) : pathWithin.get!string;
        while (path.length != 0 && path[0] == '/')
            path = path[1 .. $];
        throw new NoResourceFoundException(HttpMethod.valueOf(request.getMethod()), request.getRequestURI(), path);
    }
}

/// `HttpRequestHandlerAdapter`.
class HttpRequestHandlerAdapter : HandlerAdapter
{
    bool supports(Object handler)
    {
        return cast(HttpRequestHandler) handler !is null;
    }

    ModelAndView handle(HttpServletRequest request, HttpServletResponse response, Object handler)
    {
        (cast(HttpRequestHandler) handler).handleRequest(request, response);
        return null;
    }
}

/// `SimpleUrlHandlerMapping`: URL patterns to handler objects (lowest precedence for `/**`).
class SimpleUrlHandlerMapping : AbstractHandlerMapping
{
    private static struct Entry
    {
        PathPattern pattern;
        Object handler;
    }

    private Entry[] entries;

    /// Maps `pattern` to `handler`.
    void registerHandler(string pattern, Object handler)
    {
        entries ~= Entry(new PathPatternParser().parse(pattern), handler);
    }

    protected override Object getHandlerInternal(HttpServletRequest request)
    {
        const path = lookupPath(request);
        foreach (entry; entries)
        {
            if (auto info = entry.pattern.matchAndExtract(path))
            {
                request.setAttribute(HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE,
                        Any.of(entry.pattern.getPatternString()));
                request.setAttribute(HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE, Any.of(path));
                return entry.handler;
            }
        }
        return null;
    }
}
