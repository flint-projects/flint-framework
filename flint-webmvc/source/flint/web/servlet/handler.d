/++
`org.springframework.web.servlet.handler`: handler-mapping and exception-resolver base classes.

Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/main/java/org/springframework/web/servlet/handler/ (AbstractHandlerMapping.java,
AbstractHandlerExceptionResolver.java, HandlerExceptionResolverComposite.java, MappedInterceptor.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. CORS processing lands with
`flint.web.cors` in the next slice; the hook (`getCorsConfiguration`) is in place.
+/
module flint.web.servlet.handler;

import flint.engine.aot.any : Any;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.web.cors : CorsConfiguration, CorsConfigurationSource, CorsProcessor, CorsUtils, DefaultCorsProcessor;
import flint.web.servlet : HandlerExceptionResolver, HandlerExecutionChain, HandlerInterceptor,
    HandlerMapping, ModelAndView;
import flint.web.servlet.resource : HttpRequestHandler;
import flint.web.util.pattern : PathPattern, PathPatternParser;

@safe:

/// `MappedInterceptor`: an interceptor applied to include patterns minus exclude patterns.
final class MappedInterceptor : HandlerInterceptor
{
    private PathPattern[] includePatterns;
    private PathPattern[] excludePatterns;
    private HandlerInterceptor interceptor;

    ///
    this(string[] includePatterns, string[] excludePatterns, HandlerInterceptor interceptor)
    {
        auto parser = new PathPatternParser;
        foreach (p; includePatterns)
            this.includePatterns ~= parser.parse(p);
        foreach (p; excludePatterns)
            this.excludePatterns ~= parser.parse(p);
        this.interceptor = interceptor;
    }

    /// The wrapped interceptor.
    HandlerInterceptor getInterceptor() pure nothrow @nogc
    {
        return interceptor;
    }

    /// Whether the interceptor applies to `request`.
    bool matches(HttpServletRequest request)
    {
        const path = lookupPath(request);
        foreach (pattern; excludePatterns)
            if (pattern.matches(path))
                return false;
        if (includePatterns.length == 0)
            return true;
        foreach (pattern; includePatterns)
            if (pattern.matches(path))
                return true;
        return false;
    }

    override bool preHandle(HttpServletRequest request, HttpServletResponse response, Object handler)
    {
        return interceptor.preHandle(request, response, handler);
    }

    override void postHandle(HttpServletRequest request, HttpServletResponse response, Object handler,
            ModelAndView modelAndView)
    {
        interceptor.postHandle(request, response, handler, modelAndView);
    }

    // dfmt off
    override void afterCompletion(HttpServletRequest request, HttpServletResponse response, Object handler,
            Exception ex)
     // dfmt on
    {
        interceptor.afterCompletion(request, response, handler, ex);
    }
}

/// The application-relative, still-encoded request path (Spring 6's parsed `RequestPath.pathWithinApplication()`).
string lookupPath(HttpServletRequest request)
{
    const uri = request.getRequestURI();
    const contextPath = request.getContextPath();
    if (contextPath.length != 0 && uri.length >= contextPath.length && uri[0 .. contextPath.length] == contextPath)
        return uri[contextPath.length .. $];
    return uri;
}

/// `AbstractHandlerMapping`: interceptors and ordering around `getHandlerInternal`.
abstract class AbstractHandlerMapping : HandlerMapping
{
    private int order = int.max;
    private HandlerInterceptor[] adaptedInterceptors;
    private CorsConfigurationSource corsConfigurationSource;
    private CorsProcessor corsProcessor;

    /// The order among handler mappings (lower first).
    void setOrder(int order) pure nothrow @nogc
    {
        this.order = order;
    }

    /// ditto
    int getOrder() const pure nothrow @nogc
    {
        return order;
    }

    /// Sets the interceptors (plain or `MappedInterceptor`).
    void setInterceptors(HandlerInterceptor[] interceptors...)
    {
        adaptedInterceptors = interceptors.dup;
    }

    /// The interceptors.
    HandlerInterceptor[] getAdaptedInterceptors() pure nothrow @nogc
    {
        return adaptedInterceptors;
    }

    /// Sets the global CORS configuration (Spring Boot's `CorsRegistry`).
    void setCorsConfigurationSource(CorsConfigurationSource source) pure nothrow @nogc
    {
        corsConfigurationSource = source;
    }

    /// Sets the CORS processor (`DefaultCorsProcessor` by default).
    void setCorsProcessor(CorsProcessor processor) pure nothrow @nogc
    {
        corsProcessor = processor;
    }

    HandlerExecutionChain getHandler(HttpServletRequest request)
    {
        Object handler = getHandlerInternal(request);
        if (handler is null)
            return null;
        auto chain = getHandlerExecutionChain(handler, request);
        if (hasCorsConfigurationSource(handler) || CorsUtils.isPreFlightRequest(request))
        {
            CorsConfiguration config = getCorsConfiguration(handler, request);
            if (corsConfigurationSource !is null)
            {
                auto globalConfig = corsConfigurationSource.getCorsConfiguration(request);
                config = globalConfig !is null ? globalConfig.combine(config) : config;
            }
            if (config !is null)
                config.validateAllowCredentials();
            chain = getCorsHandlerExecutionChain(request, chain, config);
        }
        return chain;
    }

    /// Whether `handler` has CORS configuration (its own or global).
    protected bool hasCorsConfigurationSource(Object handler)
    {
        return cast(CorsConfigurationSource) handler !is null || corsConfigurationSource !is null;
    }

    /// The handler's own CORS configuration, or `null`.
    protected CorsConfiguration getCorsConfiguration(Object handler, HttpServletRequest request)
    {
        if (auto source = cast(CorsConfigurationSource) handler)
            return source.getCorsConfiguration(request);
        return null;
    }

    /// A preflight handler, or the CORS interceptor first in `chain`.
    protected HandlerExecutionChain getCorsHandlerExecutionChain(HttpServletRequest request,
            HandlerExecutionChain chain, CorsConfiguration config)
    {
        auto processor = corsProcessor !is null ? corsProcessor : new DefaultCorsProcessor;
        if (CorsUtils.isPreFlightRequest(request))
            return new HandlerExecutionChain(new PreFlightHandler(config, processor), chain.getInterceptorList());
        chain.addInterceptor(0, new CorsInterceptor(config, processor));
        return chain;
    }

    /// The handler for `request`, or `null`.
    protected abstract Object getHandlerInternal(HttpServletRequest request);

    /// The chain for `handler`, with the interceptors that apply to `request`.
    protected HandlerExecutionChain getHandlerExecutionChain(Object handler, HttpServletRequest request)
    {
        auto chain = cast(HandlerExecutionChain) handler;
        if (chain is null)
            chain = new HandlerExecutionChain(handler);
        foreach (interceptor; adaptedInterceptors)
        {
            if (auto mapped = cast(MappedInterceptor) interceptor)
            {
                if (mapped.matches(request))
                    chain.addInterceptor(mapped.getInterceptor());
            }
            else
                chain.addInterceptor(interceptor);
        }
        return chain;
    }
}

/// `AbstractHandlerMapping.PreFlightHandler`.
final class PreFlightHandler : HttpRequestHandler, CorsConfigurationSource
{
    private CorsConfiguration config;
    private CorsProcessor processor;

    ///
    this(CorsConfiguration config, CorsProcessor processor) pure nothrow @nogc
    {
        this.config = config;
        this.processor = processor;
    }

    void handleRequest(HttpServletRequest request, HttpServletResponse response)
    {
        processor.processRequest(config, request, response);
    }

    CorsConfiguration getCorsConfiguration(HttpServletRequest request)
    {
        return config;
    }
}

/// `AbstractHandlerMapping.CorsInterceptor`.
final class CorsInterceptor : HandlerInterceptor
{
    private CorsConfiguration config;
    private CorsProcessor processor;

    ///
    this(CorsConfiguration config, CorsProcessor processor) pure nothrow @nogc
    {
        this.config = config;
        this.processor = processor;
    }

    override bool preHandle(HttpServletRequest request, HttpServletResponse response, Object handler)
    {
        return processor.processRequest(config, request, response);
    }
}

/// `AbstractHandlerExceptionResolver`: response caching headers and the `shouldApplyTo` filter.
abstract class AbstractHandlerExceptionResolver : HandlerExceptionResolver
{
    private int order = int.max;
    private bool preventResponseCaching;

    /// The order among resolvers.
    void setOrder(int order) pure nothrow @nogc
    {
        this.order = order;
    }

    /// ditto
    int getOrder() const pure nothrow @nogc
    {
        return order;
    }

    /// Whether to add `Cache-Control: no-store` to resolved responses.
    void setPreventResponseCaching(bool preventResponseCaching) pure nothrow @nogc
    {
        this.preventResponseCaching = preventResponseCaching;
    }

    // dfmt off
    ModelAndView resolveException(HttpServletRequest request, HttpServletResponse response, Object handler,
            Exception ex)
     // dfmt on
    {
        if (!shouldApplyTo(request, handler))
            return null;
        if (preventResponseCaching)
            response.addHeader("Cache-Control", "no-store");
        return doResolveException(request, response, handler, ex);
    }

    /// Whether this resolver applies to `handler`.
    protected bool shouldApplyTo(HttpServletRequest request, Object handler)
    {
        return true;
    }

    /// Resolves `ex`, or returns `null`.
    protected abstract ModelAndView doResolveException(HttpServletRequest request,
            HttpServletResponse response, Object handler, Exception ex);
}

/// `HandlerExceptionResolverComposite`.
class HandlerExceptionResolverComposite : HandlerExceptionResolver
{
    private HandlerExceptionResolver[] resolvers;

    /// Sets the resolvers.
    void setExceptionResolvers(HandlerExceptionResolver[] resolvers) pure nothrow @nogc
    {
        this.resolvers = resolvers;
    }

    /// The resolvers.
    HandlerExceptionResolver[] getExceptionResolvers() pure nothrow @nogc
    {
        return resolvers;
    }

    // dfmt off
    ModelAndView resolveException(HttpServletRequest request, HttpServletResponse response, Object handler,
            Exception ex)
     // dfmt on
    {
        foreach (resolver; resolvers)
            if (auto mav = resolver.resolveException(request, response, handler, ex))
                return mav;
        return null;
    }
}
