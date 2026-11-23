/++
`org.springframework.web.servlet.config.annotation`: `WebMvcConfigurer`, its registries, and
`WebMvcConfigurationSupport`, which builds the `DispatcherServlet` strategies.

Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/main/java/org/springframework/web/servlet/config/annotation/ (WebMvcConfigurer.java,
InterceptorRegistry.java, InterceptorRegistration.java, WebMvcConfigurationSupport.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: `WebMvcConfigurer` is an abstract class (deviation D-3). Configuration support takes
Flint AOT's tables and bean factory instead of scanning a `WebApplicationContext`; strategies, order and defaults
are Spring's. Spring Boot's `WebMvcAutoConfiguration` (flint-boot) builds on it.
+/
module flint.web.servlet.config.annotation;

import flint.engine.aot.bean : BeanFactory;
import flint.engine.aot.descriptor : DescriptorTable;
import flint.engine.aot.mapping : AotHandlerMapping = HandlerMapping, ExceptionHandlerSpec;
import flint.http.converter : ByteArrayHttpMessageConverter, HttpMessageConverter, StringHttpMessageConverter;
import flint.http.converter.json : JacksonJsonHttpMessageConverter;
import flint.web.method.support : HandlerMethodArgumentResolver, HandlerMethodReturnValueHandler;
import flint.web.servlet : DispatcherStrategies, HandlerExceptionResolver, HandlerInterceptor, HandlerMapping,
    ViewResolver;
import flint.web.servlet.handler : MappedInterceptor;
import flint.web.servlet.mvc.annotation : ResponseStatusExceptionResolver;
import flint.web.servlet.mvc.method.annotation : ExceptionHandlerExceptionResolver, RequestMappingHandlerAdapter,
    RequestMappingHandlerMapping;
import flint.web.servlet.mvc.support : DefaultHandlerExceptionResolver;
import flint.web.servlet.resource : HttpRequestHandlerAdapter, ResourceHttpRequestHandler, SimpleUrlHandlerMapping;

@safe:

/// `InterceptorRegistration`: one interceptor and its path patterns.
class InterceptorRegistration
{
    private HandlerInterceptor interceptor;
    private string[] includePatterns;
    private string[] excludePatterns;
    private int orderValue;

    ///
    this(HandlerInterceptor interceptor) pure nothrow @nogc
    {
        this.interceptor = interceptor;
    }

    /// Adds include patterns.
    InterceptorRegistration addPathPatterns(string[] patterns...) pure nothrow
    {
        includePatterns ~= patterns;
        return this;
    }

    /// Adds exclude patterns.
    InterceptorRegistration excludePathPatterns(string[] patterns...) pure nothrow
    {
        excludePatterns ~= patterns;
        return this;
    }

    /// Sets the order.
    InterceptorRegistration order(int order) pure nothrow @nogc
    {
        orderValue = order;
        return this;
    }

    /// The order.
    int getOrder() const pure nothrow @nogc
    {
        return orderValue;
    }

    package(flint) HandlerInterceptor getInterceptor()
    {
        if (includePatterns.length == 0 && excludePatterns.length == 0)
            return interceptor;
        return new MappedInterceptor(includePatterns, excludePatterns, interceptor);
    }
}

/// `InterceptorRegistry`.
class InterceptorRegistry
{
    private InterceptorRegistration[] registrations;

    /// Adds `interceptor`.
    InterceptorRegistration addInterceptor(HandlerInterceptor interceptor)
    {
        auto registration = new InterceptorRegistration(interceptor);
        registrations ~= registration;
        return registration;
    }

    /// The interceptors, sorted by order (stable).
    HandlerInterceptor[] getInterceptors()
    {
        auto sorted = registrations.dup;
        for (size_t i = 1; i < sorted.length; i++)
        {
            auto r = sorted[i];
            size_t j = i;
            while (j > 0 && sorted[j - 1].getOrder() > r.getOrder())
            {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = r;
        }
        HandlerInterceptor[] result;
        foreach (r; sorted)
            result ~= r.getInterceptor();
        return result;
    }
}

/++
`WebMvcConfigurer`: callbacks to customize Spring MVC. Java's interface of default methods is an abstract class
(deviation D-3), so a configurer overrides only what it needs.
+/
abstract class WebMvcConfigurer
{
    /// Adds interceptors.
    void addInterceptors(InterceptorRegistry registry)
    {
    }

    /// Adds argument resolvers, consulted after the built-in ones.
    void addArgumentResolvers(ref HandlerMethodArgumentResolver[] resolvers)
    {
    }

    /// Adds return value handlers, consulted after the built-in ones.
    void addReturnValueHandlers(ref HandlerMethodReturnValueHandler[] handlers)
    {
    }

    /// Replaces the default message converters (Spring 7: `configureMessageConverters`).
    void configureMessageConverters(ref HttpMessageConverter[] converters)
    {
    }

    /// Extends the configured message converters.
    void extendMessageConverters(ref HttpMessageConverter[] converters)
    {
    }

    /// Replaces the default exception resolvers.
    void configureHandlerExceptionResolvers(ref HandlerExceptionResolver[] resolvers)
    {
    }

    /// Extends the configured exception resolvers.
    void extendHandlerExceptionResolvers(ref HandlerExceptionResolver[] resolvers)
    {
    }
}

/// `WebMvcConfigurationSupport`: the strategies of `@EnableWebMvc` (or Boot's auto-configuration).
class WebMvcConfigurationSupport
{
    private AotHandlerMapping[] mappings;
    private ExceptionHandlerSpec[] exceptionHandlers;
    private BeanFactory beanFactory;
    private WebMvcConfigurer[] configurers;
    private DescriptorTable descriptors;
    private HttpMessageConverter[] converters;
    private HandlerExceptionResolver[] firstResolvers;
    private ViewResolver[] viewResolvers;
    private int[string] adviceOrder;

    /// Over Flint AOT's tables, the bean factory and the application's configurers.
    this(AotHandlerMapping[] mappings, ExceptionHandlerSpec[] exceptionHandlers, BeanFactory beanFactory,
            WebMvcConfigurer[] configurers = null, DescriptorTable descriptors = null)
    {
        this.mappings = mappings;
        this.exceptionHandlers = exceptionHandlers;
        this.beanFactory = beanFactory;
        this.configurers = configurers;
        this.descriptors = descriptors;
    }

    /// The message converters to use (Spring Boot's `HttpMessageConverters`), replacing the defaults.
    WebMvcConfigurationSupport setMessageConverters(HttpMessageConverter[] converters) pure nothrow @nogc
    {
        this.converters = converters;
        return this;
    }

    /// Exception resolvers that run before Spring MVC's (Spring Boot puts `DefaultErrorAttributes` first).
    WebMvcConfigurationSupport addFirstExceptionResolvers(HandlerExceptionResolver[] resolvers...) pure nothrow
    {
        firstResolvers ~= resolvers;
        return this;
    }

    /// View resolvers (Spring Boot's error view, for instance).
    WebMvcConfigurationSupport addViewResolvers(ViewResolver[] resolvers...) pure nothrow
    {
        viewResolvers ~= resolvers;
        return this;
    }

    /// `@Order` of advice beans, by bean name.
    WebMvcConfigurationSupport setAdviceOrder(int[string] order) pure nothrow @nogc
    {
        adviceOrder = order;
        return this;
    }

    /// Spring's default converters: byte arrays, strings (UTF-8, as Boot sets), and Jackson JSON.
    HttpMessageConverter[] getMessageConverters()
    {
        HttpMessageConverter[] result = converters;
        if (result is null)
        {
            foreach (configurer; configurers)
                configurer.configureMessageConverters(result);
            if (result is null)
                result = [cast(HttpMessageConverter) new ByteArrayHttpMessageConverter, new StringHttpMessageConverter,
                    new JacksonJsonHttpMessageConverter];
        }
        foreach (configurer; configurers)
            configurer.extendMessageConverters(result);
        return result;
    }

    /// Builds the `DispatcherServlet` strategies.
    DispatcherStrategies build()
    {
        auto registry = new InterceptorRegistry;
        foreach (configurer; configurers)
            configurer.addInterceptors(registry);
        auto interceptors = registry.getInterceptors();

        auto requestMappings = new RequestMappingHandlerMapping(mappings, beanFactory);
        requestMappings.setInterceptors(interceptors);
        auto resources = new SimpleUrlHandlerMapping;
        resources.setOrder(int.max - 1);
        resources.registerHandler("/**", new ResourceHttpRequestHandler);
        resources.setInterceptors(interceptors);

        HandlerMethodArgumentResolver[] customResolvers;
        HandlerMethodReturnValueHandler[] customHandlers;
        foreach (configurer; configurers)
        {
            configurer.addArgumentResolvers(customResolvers);
            configurer.addReturnValueHandlers(customHandlers);
        }
        auto adapter = new RequestMappingHandlerAdapter(getMessageConverters(), null, customResolvers, customHandlers);

        HandlerExceptionResolver[] resolvers;
        foreach (configurer; configurers)
            configurer.configureHandlerExceptionResolvers(resolvers);
        if (resolvers is null)
            resolvers = [cast(HandlerExceptionResolver) new ExceptionHandlerExceptionResolver(exceptionHandlers,
                    beanFactory, adapter, adviceOrder), new ResponseStatusExceptionResolver(descriptors),
                new DefaultHandlerExceptionResolver];
        foreach (configurer; configurers)
            configurer.extendHandlerExceptionResolvers(resolvers);

        DispatcherStrategies strategies;
        strategies.handlerMappings = [cast(HandlerMapping) requestMappings, resources];
        strategies.handlerAdapters = [cast(imported!"flint.web.servlet".HandlerAdapter) adapter, new HttpRequestHandlerAdapter];
        strategies.handlerExceptionResolvers = firstResolvers ~ resolvers;
        strategies.viewResolvers = viewResolvers;
        return strategies;
    }
}
