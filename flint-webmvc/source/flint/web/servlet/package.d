/++
`org.springframework.web.servlet`: `DispatcherServlet` and the strategy contracts it drives.

Ported from spring-projects/spring-framework v7.1.0, spring-webmvc/src/main/java/org/springframework/web/servlet/
(DispatcherServlet.java, FrameworkServlet.java, HandlerMapping.java, HandlerAdapter.java, HandlerInterceptor.java,
HandlerExecutionChain.java, HandlerExceptionResolver.java, LocaleResolver.java, ModelAndView.java, View.java,
ViewResolver.java, NoHandlerFoundException.java) and spring-web's WebUtils.java (error attribute exposure).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. `HandlerInterceptor` is an abstract class
(deviation D-3). `DispatcherServlet` receives its strategies from `WebMvcConfigurationSupport` (or Boot's
auto-configuration) instead of looking them up in a `WebApplicationContext`; the order and defaults are Spring's.
It runs on the request's reactor fiber (ADR-030 section 4).
+/
module flint.web.servlet;

import flint.engine.aot.any : Any;
import flint.http : HttpHeaders, HttpMethod, HttpStatus, HttpStatusCode, MediaType, ProblemDetail;
import flint.jakarta.servlet : RequestDispatcher, ServletException, ServletRequest, ServletResponse;
import flint.jakarta.servlet.http : HttpServlet, HttpServletRequest, HttpServletResponse;
import flint.java.lang : IllegalStateException;
import flint.java.util : LinkedHashMap, Locale;
import flint.web : ErrorResponse, skipBacktrace;

@safe:

/// `HandlerMapping`: maps a request to a handler and its interceptors.
interface HandlerMapping
{
    /// The handler that matched (`HandlerMethod` or another handler object).
    enum string BEST_MATCHING_HANDLER_ATTRIBUTE = "org.springframework.web.servlet.HandlerMapping.bestMatchingHandler";
    /// The lookup path the mapping matched.
    enum string LOOKUP_PATH = "org.springframework.web.util.UrlPathHelper.PATH";
    /// The path within the handler mapping.
    // dfmt off
    enum string PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE =
            "org.springframework.web.servlet.HandlerMapping.pathWithinHandlerMapping";
    // dfmt on
    /// The pattern that matched best.
    enum string BEST_MATCHING_PATTERN_ATTRIBUTE = "org.springframework.web.servlet.HandlerMapping.bestMatchingPattern";
    /// Whether type-level mappings are introspected.
    // dfmt off
    enum string INTROSPECT_TYPE_LEVEL_MAPPING =
            "org.springframework.web.servlet.HandlerMapping.introspectTypeLevelMapping";
    // dfmt on
    /// The URI template variables (`string[2][]`).
    // dfmt off
    enum string URI_TEMPLATE_VARIABLES_ATTRIBUTE =
            "org.springframework.web.servlet.HandlerMapping.uriTemplateVariables";
    // dfmt on
    /// Matrix variables.
    enum string MATRIX_VARIABLES_ATTRIBUTE = "org.springframework.web.servlet.HandlerMapping.matrixVariables";
    /// The producible media types of the matched mapping (`MediaType[]`).
    // dfmt off
    enum string PRODUCIBLE_MEDIA_TYPES_ATTRIBUTE =
            "org.springframework.web.servlet.HandlerMapping.producibleMediaTypes";
    // dfmt on

    /// The handler chain for `request`, or `null` when this mapping has none.
    HandlerExecutionChain getHandler(HttpServletRequest request);
}

/// `HandlerAdapter`: invokes one kind of handler.
interface HandlerAdapter
{
    /// Whether this adapter invokes `handler`.
    bool supports(Object handler);

    /// Invokes `handler`; returns a model and view, or `null` when the response is handled.
    ModelAndView handle(HttpServletRequest request, HttpServletResponse response, Object handler);
}

/++
`HandlerInterceptor`: callbacks around handler execution. Java's interface with three default methods is an
abstract class (deviation D-3), so an interceptor overrides only what it needs.
+/
abstract class HandlerInterceptor
{
    /// Before the handler; `false` stops the chain.
    bool preHandle(HttpServletRequest request, HttpServletResponse response, Object handler)
    {
        return true;
    }

    /// After the handler, before view rendering.
    void postHandle(HttpServletRequest request, HttpServletResponse response, Object handler, ModelAndView modelAndView)
    {
    }

    /// After completion, with the exception if any.
    void afterCompletion(HttpServletRequest request, HttpServletResponse response, Object handler, Exception ex)
    {
    }
}

/// `HandlerExecutionChain`: a handler and its interceptors.
class HandlerExecutionChain
{
    private Object handler;
    private HandlerInterceptor[] interceptorList;
    private ptrdiff_t interceptorIndex = -1;

    ///
    this(Object handler, HandlerInterceptor[] interceptors = null)
    {
        if (auto chain = cast(HandlerExecutionChain) handler)
        {
            this.handler = chain.handler;
            interceptorList = chain.interceptorList.dup;
        }
        else
            this.handler = handler;
        interceptorList ~= interceptors;
    }

    /// The handler.
    Object getHandler() pure nothrow @nogc
    {
        return handler;
    }

    /// Appends an interceptor.
    void addInterceptor(HandlerInterceptor interceptor) pure nothrow
    {
        interceptorList ~= interceptor;
    }

    /// Inserts an interceptor at `index`.
    void addInterceptor(int index, HandlerInterceptor interceptor) pure nothrow
    {
        interceptorList = interceptorList[0 .. index] ~ interceptor ~ interceptorList[index .. $];
    }

    /// The interceptors.
    HandlerInterceptor[] getInterceptorList() pure nothrow @nogc
    {
        return interceptorList;
    }

    /// Runs `preHandle` in order; on `false`, runs `afterCompletion` for those already applied.
    bool applyPreHandle(HttpServletRequest request, HttpServletResponse response)
    {
        foreach (i, interceptor; interceptorList)
        {
            if (!interceptor.preHandle(request, response, handler))
            {
                triggerAfterCompletion(request, response, null);
                return false;
            }
            interceptorIndex = i;
        }
        return true;
    }

    /// Runs `postHandle` in reverse order.
    void applyPostHandle(HttpServletRequest request, HttpServletResponse response, ModelAndView mv)
    {
        foreach_reverse (interceptor; interceptorList)
            interceptor.postHandle(request, response, handler, mv);
    }

    /// Runs `afterCompletion` in reverse order for the interceptors whose `preHandle` succeeded.
    void triggerAfterCompletion(HttpServletRequest request, HttpServletResponse response, Exception ex)
    {
        for (ptrdiff_t i = interceptorIndex; i >= 0; i--)
        {
            try
                interceptorList[i].afterCompletion(request, response, handler, ex);
            catch (Exception e)
            {
                // Spring logs and continues.
            }
        }
    }

    override string toString() const
    {
        import std.conv : to;

        return "HandlerExecutionChain with [" ~ (handler is null ? "null" : typeid(handler)
                .name) ~ "] and " ~ interceptorList.length.to!string ~ " interceptors";
    }
}

/// `HandlerExceptionResolver`: turns an exception into a response.
interface HandlerExceptionResolver
{
    /// A model and view (possibly empty, meaning "handled"), or `null` to let the next resolver try.
    // dfmt off
    ModelAndView resolveException(HttpServletRequest request, HttpServletResponse response, Object handler,
            Exception ex);
    // dfmt on
}

/// `View`: renders a model.
interface View
{
    /// The model attribute naming the response status.
    enum string RESPONSE_STATUS_ATTRIBUTE = "org.springframework.web.servlet.View.responseStatus";
    /// The model attribute naming path variables.
    enum string PATH_VARIABLES = "org.springframework.web.servlet.View.pathVariables";
    /// The model attribute naming the selected content type.
    enum string SELECTED_CONTENT_TYPE = "org.springframework.web.servlet.View.selectedContentType";

    /// The content type, or `null`.
    string getContentType();

    /// Renders `model`.
    void render(LinkedHashMap!(string, Any) model, HttpServletRequest request, HttpServletResponse response);
}

/// `LocaleResolver`: the locale of a request, which `DispatcherServlet.render` applies to the response
/// (`Content-Language`). Java's `@Nullable Locale` is `Locale.init` here.
interface LocaleResolver
{
    /// The current locale of `request`.
    Locale resolveLocale(HttpServletRequest request);

    /// Changes the current locale; strategies that cannot change it throw `UnsupportedOperationException`.
    void setLocale(HttpServletRequest request, HttpServletResponse response, Locale locale);
}

/// `ViewResolver`: resolves a view name.
interface ViewResolver
{
    /// The view named `viewName`, or `null`.
    View resolveViewName(string viewName);
}

/// `ModelAndView`: a view (or view name) and its model.
class ModelAndView
{
    private string viewName;
    private View view;
    private LinkedHashMap!(string, Any) model;
    private HttpStatusCode status;
    private bool hasStatus;
    private bool cleared;

    /// An empty model and view (meaning "handled, render nothing").
    this()
    {
    }

    /// For a view name.
    this(string viewName)
    {
        this.viewName = viewName;
    }

    /// For a view.
    this(View view)
    {
        this.view = view;
    }

    /// For a view name and model.
    this(string viewName, LinkedHashMap!(string, Any) model)
    {
        this.viewName = viewName;
        this.model = model;
    }

    /// The view name, or `null`.
    string getViewName() const pure nothrow @nogc
    {
        return viewName;
    }

    /// Sets the view name.
    void setViewName(string viewName) pure nothrow @nogc
    {
        this.viewName = viewName;
    }

    /// The view, or `null`.
    View getView() pure nothrow @nogc
    {
        return view;
    }

    /// Sets the view.
    void setView(View view) pure nothrow @nogc
    {
        this.view = view;
    }

    /// Whether there is a view name or view.
    bool hasView() const pure nothrow @nogc
    {
        return viewName !is null || view !is null;
    }

    /// Whether the view is a name to resolve.
    bool isReference() const pure nothrow @nogc
    {
        return view is null;
    }

    /// The model (created on first use).
    LinkedHashMap!(string, Any) getModel()
    {
        if (model is null)
            model = new LinkedHashMap!(string, Any);
        return model;
    }

    /// Adds a model attribute.
    ModelAndView addObject(string attributeName, Any attributeValue)
    {
        getModel().put(attributeName, attributeValue);
        return this;
    }

    /// Sets the response status for rendering.
    void setStatus(HttpStatusCode status) pure nothrow @nogc
    {
        this.status = status;
        hasStatus = true;
    }

    /// The response status, or `null`.
    // dfmt off
    const(HttpStatusCode)* getStatus() const pure nothrow @nogc return
    // dfmt on
    {
        return hasStatus ? &status : null;
    }

    /// Clears view and model.
    void clear() pure nothrow @nogc
    {
        viewName = null;
        view = null;
        model = null;
        cleared = true;
    }

    /// Whether there is neither a view nor a model.
    bool isEmpty()
    {
        return view is null && viewName is null && (model is null || model.isEmpty());
    }

    /// Whether `clear()` emptied this instance.
    bool wasCleared()
    {
        return cleared && isEmpty();
    }
}

/// `NoHandlerFoundException`: no handler for the request (404).
class NoHandlerFoundException : ServletException, ErrorResponse
{
    mixin ErrorResponse.Defaults;

    private string httpMethod;
    private string requestURL;
    private HttpHeaders requestHeaders;
    private ProblemDetail body;

    ///
    this(string httpMethod, string requestURL, HttpHeaders headers)
    {
        super("No endpoint " ~ httpMethod ~ " " ~ requestURL ~ ".");
        this.httpMethod = httpMethod;
        this.requestURL = requestURL;
        requestHeaders = headers;
        body = ProblemDetail.forStatusAndDetail(getStatusCode(), getMessage());
        skipBacktrace(this);
    }

    HttpStatusCode getStatusCode()
    {
        return HttpStatus.NOT_FOUND;
    }

    /// The method.
    string getHttpMethod() const pure nothrow @nogc
    {
        return httpMethod;
    }

    /// The URL.
    string getRequestURL() const pure nothrow @nogc
    {
        return requestURL;
    }

    /// The request headers.
    HttpHeaders getRequestHeaders() pure nothrow @nogc
    {
        return requestHeaders;
    }

    ProblemDetail getBody()
    {
        return
        body;
    }
}

/// The strategies `DispatcherServlet` uses, in Spring's order.
struct DispatcherStrategies
{
    HandlerMapping[] handlerMappings; ///
    HandlerAdapter[] handlerAdapters; ///
    HandlerExceptionResolver[] handlerExceptionResolvers; ///
    ViewResolver[] viewResolvers; ///
    /// `null` falls back to `request.getLocale()`, as in Spring.
    LocaleResolver localeResolver;
}

/++
`DispatcherServlet` (with `FrameworkServlet`'s request processing): dispatches to handlers, resolves
exceptions and renders views.
+/
class DispatcherServlet : HttpServlet
{
    /// The request attribute naming the servlet's web application context (none in Flint).
    enum string WEB_APPLICATION_CONTEXT_ATTRIBUTE = "org.springframework.web.servlet.DispatcherServlet.CONTEXT";
    /// The request attribute holding the exception resolved to an empty model and view.
    enum string EXCEPTION_ATTRIBUTE = "org.springframework.web.servlet.DispatcherServlet.EXCEPTION";

    private DispatcherStrategies strategies;
    private bool dispatchOptionsRequest = true;
    private bool dispatchTraceRequest;
    private string servletName = "dispatcherServlet";

    /// With the given strategies.
    this(DispatcherStrategies strategies)
    {
        this.strategies = strategies;
    }

    /// The handler mappings.
    HandlerMapping[] getHandlerMappings() pure nothrow @nogc
    {
        return strategies.handlerMappings;
    }

    /// Whether OPTIONS requests reach handlers (Spring's default: true).
    void setDispatchOptionsRequest(bool dispatchOptionsRequest) pure nothrow @nogc
    {
        this.dispatchOptionsRequest = dispatchOptionsRequest;
    }

    /// Whether TRACE requests reach handlers (default: false).
    void setDispatchTraceRequest(bool dispatchTraceRequest) pure nothrow @nogc
    {
        this.dispatchTraceRequest = dispatchTraceRequest;
    }

    override string getServletName()
    {
        return servletName;
    }

    /// FrameworkServlet implements every `doXxx` and routes PATCH through `service`.
    protected override string[] getDeclaredMethods()
    {
        return ["GET", "POST", "PUT", "DELETE", "PATCH"];
    }

    alias service = HttpServlet.service;

    // FrameworkServlet: every method goes through processRequest.
    protected override void service(HttpServletRequest request, HttpServletResponse response)
    {
        const method = request.getMethod();
        if (method == "PATCH" || HttpMethod.valueOf(method).name() != method || !isStandard(method))
            processRequest(request, response);
        else
            super.service(request, response);
    }

    private static bool isStandard(string method) pure nothrow @nogc
    {
        switch (method)
        {
        case "GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "TRACE":
            return true;
        default:
            return false;
        }
    }

    protected override void doGet(HttpServletRequest request, HttpServletResponse response)
    {
        processRequest(request, response);
    }

    protected override void doHead(HttpServletRequest request, HttpServletResponse response)
    {
        // The container discards the body of a HEAD response and keeps its Content-Length.
        processRequest(request, response);
    }

    protected override void doPost(HttpServletRequest request, HttpServletResponse response)
    {
        processRequest(request, response);
    }

    protected override void doPut(HttpServletRequest request, HttpServletResponse response)
    {
        processRequest(request, response);
    }

    protected override void doDelete(HttpServletRequest request, HttpServletResponse response)
    {
        processRequest(request, response);
    }

    protected override void doOptions(HttpServletRequest request, HttpServletResponse response)
    {
        if (dispatchOptionsRequest || isPreFlightRequest(request))
        {
            processRequest(request, response);
            if (response.containsHeader(HttpHeaders.ALLOW))
                return;
        }
        super.doOptions(request, response);
    }

    protected override void doTrace(HttpServletRequest request, HttpServletResponse response)
    {
        if (dispatchTraceRequest)
        {
            processRequest(request, response);
            if ("message/http" == response.getContentType())
                return;
        }
        super.doTrace(request, response);
    }

    private static bool isPreFlightRequest(HttpServletRequest request)
    {
        return request.getMethod() == "OPTIONS" && request.getHeader(HttpHeaders.ORIGIN) !is null
            && request.getHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD) !is null;
    }

    /// FrameworkServlet's `processRequest`: dispatch, and wrap non-runtime failures.
    protected final void processRequest(HttpServletRequest request, HttpServletResponse response)
    {
        doService(request, response);
    }

    /// Exposes servlet attributes and dispatches.
    protected void doService(HttpServletRequest request, HttpServletResponse response)
    {
        doDispatch(request, response);
    }

    /// Spring's `doDispatch`.
    protected void doDispatch(HttpServletRequest request, HttpServletResponse response)
    {
        HandlerExecutionChain mappedHandler;
        try
        {
            ModelAndView mv;
            Exception dispatchException;
            try
            {
                mappedHandler = getHandler(request);
                if (mappedHandler is null)
                {
                    noHandlerFound(request, response);
                    return;
                }
                auto ha = getHandlerAdapter(mappedHandler.getHandler());
                if (!mappedHandler.applyPreHandle(request, response))
                    return;
                mv = ha.handle(request, response, mappedHandler.getHandler());
                mappedHandler.applyPostHandle(request, response, mv);
            }
            catch (Exception ex)
                dispatchException = ex;
            processDispatchResult(request, response, mappedHandler, mv, dispatchException);
        }
        catch (Exception ex)
        {
            if (mappedHandler !is null)
                mappedHandler.triggerAfterCompletion(request, response, ex);
            throw ex;
        }
    }

    private void processDispatchResult(HttpServletRequest request, HttpServletResponse response,
            HandlerExecutionChain mappedHandler, ModelAndView mv, Exception exception)
    {
        bool errorView;
        if (exception !is null)
        {
            Object handler = mappedHandler !is null ? mappedHandler.getHandler() : null;
            mv = processHandlerException(request, response, handler, exception);
            errorView = mv !is null;
        }
        if (mv !is null && !mv.wasCleared())
        {
            render(mv, request, response);
            if (errorView)
                clearErrorRequestAttributes(request);
        }
        if (mappedHandler !is null)
            mappedHandler.triggerAfterCompletion(request, response, null);
    }

    /// The first handler chain any mapping returns, or `null`.
    protected HandlerExecutionChain getHandler(HttpServletRequest request)
    {
        foreach (mapping; strategies.handlerMappings)
            if (auto handler = mapping.getHandler(request))
                return handler;
        return null;
    }

    /// Throws `NoHandlerFoundException` (Spring 6.1+'s default).
    protected void noHandlerFound(HttpServletRequest request, HttpServletResponse response)
    {
        auto headers = HttpHeaders.create();
        foreach (name; request.getHeaderNames())
            foreach (value; request.getHeaders(name))
                headers.add(name, value);
        throw new NoHandlerFoundException(request.getMethod(), request.getRequestURI(), headers);
    }

    /// The adapter that supports `handler`.
    protected HandlerAdapter getHandlerAdapter(Object handler)
    {
        foreach (adapter; strategies.handlerAdapters)
            if (adapter.supports(handler))
                return adapter;
        throw new ServletException("No adapter for handler [" ~ (handler is null ? "null" : typeid(handler)
                .name) ~ "]: The DispatcherServlet configuration needs to include a HandlerAdapter that "
                ~ "supports this handler");
    }

    /// Spring's `processHandlerException`.
    protected ModelAndView processHandlerException(HttpServletRequest request,
            HttpServletResponse response, Object handler, Exception ex)
    {
        request.removeAttribute(HandlerMapping.PRODUCIBLE_MEDIA_TYPES_ATTRIBUTE);
        ModelAndView exMv;
        foreach (resolver; strategies.handlerExceptionResolvers)
        {
            exMv = resolver.resolveException(request, response, handler, ex);
            if (exMv !is null)
                break;
        }
        if (exMv !is null)
        {
            if (exMv.isEmpty())
            {
                request.setAttribute(EXCEPTION_ATTRIBUTE, Any.of(cast(Object) ex));
                return null;
            }
            exposeErrorRequestAttributes(request, ex, getServletName());
            return exMv;
        }
        throw ex;
    }

    /// Spring's `render`: resolves the view and renders the model.
    protected void render(ModelAndView mv, HttpServletRequest request, HttpServletResponse response)
    {
        // Determine locale for request and apply it to the response.
        const locale = strategies.localeResolver !is null
            ? strategies.localeResolver.resolveLocale(request) : request.getLocale();
        response.setLocale(locale);
        View view;
        if (mv.isReference())
        {
            foreach (resolver; strategies.viewResolvers)
                if ((view = resolver.resolveViewName(mv.getViewName())) !is null)
                    break;
            if (view is null)
                throw new ServletException("Could not resolve view with name '" ~ mv.getViewName()
                        ~ "' in servlet with name '" ~ getServletName() ~ "'");
        }
        else
            view = mv.getView();
        if (auto status = mv.getStatus())
            response.setStatus(status.value());
        view.render(mv.getModel(), request, response);
    }

    // WebUtils.exposeErrorRequestAttributes / clearErrorRequestAttributes
    private static void exposeErrorRequestAttributes(HttpServletRequest request, Exception ex, string servletName)
    {
        if (request.getAttribute(RequestDispatcher.ERROR_STATUS_CODE).isNull())
            request.setAttribute(RequestDispatcher.ERROR_STATUS_CODE, Any.of(200));
        request.setAttribute(RequestDispatcher.ERROR_EXCEPTION_TYPE, Any.of(typeid(ex).name));
        request.setAttribute(RequestDispatcher.ERROR_MESSAGE, Any.of(ex.msg));
        request.setAttribute(RequestDispatcher.ERROR_EXCEPTION, Any.of(cast(Object) ex));
        request.setAttribute(RequestDispatcher.ERROR_REQUEST_URI, Any.of(request.getRequestURI()));
        if (servletName !is null)
            request.setAttribute(RequestDispatcher.ERROR_SERVLET_NAME, Any.of(servletName));
    }

    private static void clearErrorRequestAttributes(HttpServletRequest request)
    {
        foreach (name; [
            RequestDispatcher.ERROR_STATUS_CODE, RequestDispatcher.ERROR_EXCEPTION_TYPE,
            RequestDispatcher.ERROR_MESSAGE, RequestDispatcher.ERROR_EXCEPTION,
            RequestDispatcher.ERROR_REQUEST_URI, RequestDispatcher.ERROR_SERVLET_NAME
        ])
            request.removeAttribute(name);
    }
}
