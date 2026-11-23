/++
`org.springframework.test.web.servlet.setup`: building `MockMvc` instances.

Ported from spring-projects/spring-framework v7.1.0,
spring-test/src/main/java/org/springframework/test/web/servlet/setup/ (MockMvcBuilders.java,
StandaloneMockMvcBuilder.java, AbstractMockMvcBuilder.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: `standaloneSetup(Object... controllers)` is a template over the controller types
(R4), because their request-mapping rows are built at compile time until Flint AOT generates them. The rest is
Spring's: a `DispatcherServlet` with Spring MVC's default strategies, the given advice, interceptors, converters
and filters. `webAppContextSetup` arrives with the application context (Boot's `@AutoConfigureMockMvc`).
+/
module flint.test.web.servlet.setup;

import flint.engine.aot.any : Any;
import flint.engine.aot.bean : BeanFactory;
import flint.engine.aot.descriptor : Descriptor, DescriptorTable;
import flint.engine.aot.mapping : AotHandlerMapping = HandlerMapping, ExceptionHandlerSpec;
import flint.http.converter : HttpMessageConverter;
import flint.http.converter.json : JacksonJsonHttpMessageConverter;
import flint.jakarta.servlet : Filter;
import flint.java.lang : IllegalStateException;
import flint.test.web.servlet : MockMvc, ResultHandler, ResultMatcher, TestDispatcherServlet;
import flint.web.servlet : HandlerInterceptor;
import flint.web.servlet.config.annotation : InterceptorRegistry, WebMvcConfigurationSupport, WebMvcConfigurer;
import flint.web.servlet.mvc.method.aot : exceptionHandlersOf, handlerDescriptorsOf, requestMappingsOf;

@safe:

/// `MockMvcBuilders`.
struct MockMvcBuilders
{
    /// A builder over the given controller instances, with Spring MVC's default configuration.
    static StandaloneMockMvcBuilder standaloneSetup(Controllers...)(Controllers controllers)
    {
        auto builder = new StandaloneMockMvcBuilder;
        static foreach (i, C; Controllers)
            builder.addController(beanNameOf!C, controllers[i], requestMappingsOf!C(beanNameOf!C),
                    exceptionHandlersOf!C(beanNameOf!C), handlerDescriptorsOf!C());
        return builder;
    }
}

/// Spring's default bean name: the simple class name with its first letter lowered, unless the first two are
/// capitals (`URLService` stays).
template beanNameOf(C)
{
    enum string simple = __traits(identifier, C);
    static if (simple.length > 1 && simple[0] >= 'A' && simple[0] <= 'Z' && simple[1] >= 'A' && simple[1] <= 'Z')
        enum string beanNameOf = simple;
    else
        enum string beanNameOf = cast(char)(simple[0] | 0x20) ~ simple[1 .. $];
}

/// A bean factory over fixed instances (the controllers and advice of a standalone setup).
final class StaticBeanFactory : BeanFactory
{
    private Object[string] beans;
    private string[] order;

    /// Registers `bean` as `name`.
    void addBean(string name, Object bean)
    {
        if (name !in beans)
            order ~= name;
        beans[name] = bean;
    }

    Object getBean(string name)
    {
        if (auto bean = name in beans)
            return *bean;
        throw new IllegalStateException("No bean named '" ~ name ~ "' available");
    }

    Object getBeanOfType(string type, string qualifier = null)
    {
        if (auto bean = findBeanOfType(type, qualifier))
            return bean;
        throw new IllegalStateException("No qualifying bean of type '" ~ type ~ "' available");
    }

    Object findBeanOfType(string type, string qualifier = null)
    {
        foreach (name; order)
            if (typeid(beans[name]).name == type)
                return beans[name];
        return null;
    }

    Object[] getBeansOfType(string type)
    {
        Object[] result;
        foreach (name; order)
            if (typeid(beans[name]).name == type)
                result ~= beans[name];
        return result;
    }

    Any resolveValue(string expression, string targetType)
    {
        throw new IllegalStateException("@Value is not available in a standalone MockMvc setup");
    }

    void bind(string prefix, Any target)
    {
    }

    Any bindConstructor(string prefix, string type)
    {
        throw new IllegalStateException("@ConfigurationProperties is not available in a standalone MockMvc setup");
    }
}

/// `StandaloneMockMvcBuilder`.
final class StandaloneMockMvcBuilder
{
    private StaticBeanFactory beanFactory;
    private AotHandlerMapping[] mappings;
    private ExceptionHandlerSpec[] exceptionHandlers;
    private Descriptor[] descriptors;
    private HandlerInterceptor[] interceptors;
    private HttpMessageConverter[] messageConverters;
    private WebMvcConfigurer[] configurers;
    private Filter[] filters;
    private ResultMatcher[] globalMatchers;
    private ResultHandler[] globalHandlers;
    private int[string] adviceOrder;

    package(flint) this()
    {
        beanFactory = new StaticBeanFactory;
    }

    package(flint) void addController(string name, Object controller, AotHandlerMapping[] rows,
            ExceptionHandlerSpec[] handlers, Descriptor[] types)
    {
        beanFactory.addBean(name, controller);
        mappings ~= rows;
        exceptionHandlers ~= handlers;
        descriptors ~= types;
    }

    /// Registers `@ControllerAdvice` instances, in order of precedence.
    StandaloneMockMvcBuilder setControllerAdvice(Advices...)(Advices advices)
    {
        static foreach (i, A; Advices)
        {
            beanFactory.addBean(beanNameOf!A, advices[i]);
            exceptionHandlers ~= exceptionHandlersOf!A(beanNameOf!A);
            adviceOrder[beanNameOf!A] = cast(int) i;
        }
        return this;
    }

    /// Adds interceptors for every request.
    StandaloneMockMvcBuilder addInterceptors(HandlerInterceptor[] interceptors...)
    {
        this.interceptors ~= interceptors;
        return this;
    }

    /// Replaces the message converters.
    StandaloneMockMvcBuilder setMessageConverters(HttpMessageConverter[] messageConverters...)
    {
        this.messageConverters = messageConverters.dup;
        return this;
    }

    /// Adds `WebMvcConfigurer`-style customizations.
    StandaloneMockMvcBuilder addConfigurer(WebMvcConfigurer configurer)
    {
        configurers ~= configurer;
        return this;
    }

    /// Adds servlet filters, run before the `DispatcherServlet`.
    StandaloneMockMvcBuilder addFilters(Filter[] filters...)
    {
        this.filters ~= filters;
        return this;
    }

    /// Matchers applied to every result.
    StandaloneMockMvcBuilder alwaysExpect(ResultMatcher matcher)
    {
        globalMatchers ~= matcher;
        return this;
    }

    /// Handlers applied to every result.
    StandaloneMockMvcBuilder alwaysDo(ResultHandler handler)
    {
        globalHandlers ~= handler;
        return this;
    }

    /// Builds the `MockMvc`.
    MockMvc build()
    {
        auto table = DescriptorTable.withBuiltins();
        foreach (descriptor; descriptors)
            table.add(descriptor);
        auto interceptorList = interceptors;
        auto configurerList = configurers ~ [
            cast(WebMvcConfigurer) new class WebMvcConfigurer
            {
                override void addInterceptors(InterceptorRegistry registry)
                {
                    foreach (interceptor; interceptorList)
                        registry.addInterceptor(interceptor);
                }
            }

        ];
        auto support = new WebMvcConfigurationSupport(mappings, exceptionHandlers, beanFactory, configurerList, table);
        support.setAdviceOrder(adviceOrder);
        HttpMessageConverter[] converters = messageConverters;
        if (converters is null)
            converters = support.getMessageConverters();
        foreach (converter; converters)
            if (auto json = cast(JacksonJsonHttpMessageConverter) converter)
                foreach (descriptor; descriptors)
                    json.getMapper().registerDescriptor(descriptor);
        support.setMessageConverters(converters);
        auto servlet = new TestDispatcherServlet(support.build());
        auto mockMvc = new MockMvc(servlet, filters);
        mockMvc.setGlobalResultMatchers(globalMatchers);
        mockMvc.setGlobalResultHandlers(globalHandlers);
        return mockMvc;
    }
}
