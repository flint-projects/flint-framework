// Ported from spring-framework v7.1.0: spring-context/src/main/java/org/springframework/context/support
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/*
 * Copyright 2002-present the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by the Flint authors: ported from spring-framework v7.1.0,
 * spring-context/src/main/java/org/springframework/context/support/{AbstractApplicationContext,
 * GenericApplicationContext,DefaultLifecycleProcessor,ApplicationContextAwareProcessor,
 * ApplicationListenerDetector,PostProcessorRegistrationDelegate}.java. Bean definitions come from the Flint AOT
 * registry (AOT contract sections 4.9 and 5.4): conditions are evaluated at startup, in definition order.
 */

/++
`org.springframework.context.support`: the application context implementations.

`AbstractApplicationContext.refresh()` follows Spring's sequence: prepare the environment, prepare the factory
(infrastructure dependencies, aware and listener processors, `${...}` resolution), run `BeanFactoryPostProcessor`s,
register `BeanPostProcessor`s, initialize the event multicaster, `onRefresh()`, register listeners (beans,
`@EventListener` methods), create the non-lazy singletons, start `SmartLifecycle` beans, and publish
`ContextRefreshedEvent`. A failure destroys what was created and rethrows.
+/
module flint.context.support;

import flint.beans.factory : BeanFactory, ListableBeanFactory;
import flint.beans.factory.config : BeanDefinition, BeanFactoryPostProcessor, BeanPostProcessor,
    ConfigurableListableBeanFactory;
import flint.beans.factory.support : BeanDefinitionRegistry, DefaultListableBeanFactory, RootBeanDefinition;
import flint.context : ApplicationContext, ApplicationContextAware, ApplicationEvent,
    ApplicationEventPublisher, ApplicationEventPublisherAware,
    ConfigurableApplicationContext,
    EnvironmentAware, GenericApplicationListener,
    Lifecycle, LifecycleProcessor, Phased, ResourceLoaderAware, SmartLifecycle;
import flint.context.event : ApplicationEventMulticaster, ApplicationListenerMethodAdapter, ContextClosedEvent,
    ContextRefreshedEvent, ContextStartedEvent, ContextStoppedEvent, SimpleApplicationEventMulticaster;
import flint.core : Ordered, PriorityOrdered;
import flint.core.convert : ConversionService;
import flint.core.env : ConfigurableEnvironment, Environment, Profiles, StandardEnvironment;
import flint.core.io : DefaultResourceLoader, Resource, ResourceLoader;
import flint.engine.aot.any : Any;
import flint.engine.aot.bean : AotBeanDefinition = BeanDefinition, AotBeanFactory = BeanFactory;
import flint.engine.aot.condition : ConditionContext, propertyMatches;
import flint.engine.aot.descriptor : Descriptor, DescriptorTable, MergedAnnotation;
import flint.engine.aot.event : EventListenerSpec;
import flint.engine.aot.mapping : ExceptionHandlerSpec, HandlerMapping;
import flint.engine.aot.name : canonicalTypeName, typeNameOf;
import flint.engine.aot.query : DerivedQuery;
import flint.engine.aot.registry : AotRegistry, RegistryPopulator, checkContractVersion, installedRegistry;
import flint.java.lang : IllegalStateException, Runnable, valueOf;
import flint.java.util : stableSort;
import flint.util : Assert, StringUtils, StringValueResolver;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// AbstractApplicationContext

/// Abstract implementation of `ConfigurableApplicationContext`: the refresh and close template.
abstract class AbstractApplicationContext : DefaultResourceLoader, ConfigurableApplicationContext
{
    /// The name of the `LifecycleProcessor` bean.
    enum LIFECYCLE_PROCESSOR_BEAN_NAME = "lifecycleProcessor";
    /// The name of the `ApplicationEventMulticaster` bean.
    enum APPLICATION_EVENT_MULTICASTER_BEAN_NAME = "applicationEventMulticaster";

    private string id;
    private string displayName;
    private ApplicationContext parent;
    private ConfigurableEnvironment environment;
    private BeanFactoryPostProcessor[] beanFactoryPostProcessors;
    private GenericApplicationListener[] applicationListeners;
    private ApplicationEvent[] earlyEvents;
    private bool collectingEarlyEvents;
    private ApplicationEventMulticaster multicaster;
    private LifecycleProcessor lifecycleProcessor;
    private long startupDate;
    private bool active;
    private bool closed;
    private bool shutdownHookRegistered;

    /// A context with a generated id.
    this()
    {
        id = typeid(this).name ~ "@" ~ valueOf(cast(int) hashOf(typeid(this).name));
        displayName = id;
    }

    // ---- ApplicationContext

    /// The id.
    string getId()
    {
        return id;
    }

    /// Set the id.
    void setId(string id)
    {
        this.id = id;
    }

    /// The application name: empty by default.
    string getApplicationName()
    {
        return "";
    }

    /// The display name.
    string getDisplayName()
    {
        return displayName;
    }

    /// Set the display name.
    void setDisplayName(string displayName)
    {
        Assert.hasText(displayName, "Display name must not be empty");
        this.displayName = displayName;
    }

    /// The parent context, or null.
    ApplicationContext getParent()
    {
        return parent;
    }

    /// Set the parent context; its environment is merged into this one.
    void setParent(ApplicationContext parent)
    {
        this.parent = parent;
        if (parent !is null)
            if (auto parentEnvironment = cast(ConfigurableEnvironment) parent.getEnvironment())
                getConfigurableEnvironment().merge(parentEnvironment);
    }

    /// When the context was refreshed, in milliseconds since the epoch.
    long getStartupDate()
    {
        return startupDate;
    }

    /// The environment, created on first use (`StandardEnvironment`).
    Environment getEnvironment()
    {
        return getConfigurableEnvironment();
    }

    /// The environment, configurable.
    ConfigurableEnvironment getConfigurableEnvironment()
    {
        if (environment is null)
            environment = createEnvironment();
        return environment;
    }

    /// Set the environment.
    void setEnvironment(ConfigurableEnvironment environment)
    {
        this.environment = environment;
    }

    /// The environment created on first use.
    protected ConfigurableEnvironment createEnvironment()
    {
        return new StandardEnvironment;
    }

    // ---- ResourceLoader

    /// The resource at `location`, through the default loader.
    override Resource getResource(string location)
    {
        return super.getResource(location);
    }

    // ---- Events

    /// Publish `event` to the listeners (queued until the multicaster exists), and to the parent context.
    void publishEventErased(ApplicationEvent event)
    {
        Assert.notNull(event, "Event must not be null");
        if (collectingEarlyEvents)
            earlyEvents ~= event;
        else
            getApplicationEventMulticaster().multicastEvent(event);
        if (parent !is null)
            parent.publishEventErased(event);
    }

    /// The multicaster. Throws `IllegalStateException` before refresh initialized it.
    protected ApplicationEventMulticaster getApplicationEventMulticaster()
    {
        if (multicaster is null)
            throw new IllegalStateException("ApplicationEventMulticaster not initialized - call 'refresh' before "
                    ~ "multicasting events via the context: " ~ toString());
        return multicaster;
    }

    /// Add a listener (registered with the multicaster when it exists).
    void addApplicationListener(GenericApplicationListener listener)
    {
        Assert.notNull(listener, "ApplicationListener must not be null");
        if (multicaster !is null)
            multicaster.addApplicationListener(listener);
        applicationListeners ~= listener;
    }

    /// The statically registered listeners.
    GenericApplicationListener[] getApplicationListeners()
    {
        return applicationListeners.dup;
    }

    /// Add a factory post-processor.
    void addBeanFactoryPostProcessor(BeanFactoryPostProcessor postProcessor)
    {
        Assert.notNull(postProcessor, "BeanFactoryPostProcessor must not be null");
        beanFactoryPostProcessors ~= postProcessor;
    }

    // ---- Refresh

    /// Load the configuration and create every non-lazy singleton.
    void refresh()
    {
        prepareRefresh();
        auto beanFactory = obtainFreshBeanFactory();
        prepareBeanFactory(beanFactory);
        try
        {
            postProcessBeanFactory(beanFactory);
            invokeBeanFactoryPostProcessors(beanFactory);
            registerBeanPostProcessors(beanFactory);
            initApplicationEventMulticaster();
            onRefresh();
            registerListeners();
            finishBeanFactoryInitialization(beanFactory);
            finishRefresh();
        }
        catch (Exception e)
        {
            destroyBeans();
            cancelRefresh(e);
            throw e;
        }
    }

    /// Mark the context active and validate the required properties.
    protected void prepareRefresh()
    {
        import std.datetime.systime : Clock;

        startupDate = Clock.currTime().toUnixTime() * 1000L;
        closed = false;
        active = true;
        initPropertySources();
        getConfigurableEnvironment().validateRequiredProperties();
        collectingEarlyEvents = true;
    }

    /// Replace stub property sources: a hook for web contexts.
    protected void initPropertySources()
    {
    }

    /// The factory, refreshed by the subclass.
    protected ConfigurableListableBeanFactory obtainFreshBeanFactory()
    {
        refreshBeanFactory();
        return getBeanFactory();
    }

    /// Infrastructure dependencies, processors and value resolution.
    protected void prepareBeanFactory(ConfigurableListableBeanFactory beanFactory)
    {
        beanFactory.addBeanPostProcessor(new ApplicationContextAwareProcessor(this));
        beanFactory.addBeanPostProcessor(new ApplicationListenerDetector(this));
        if (auto factory = cast(DefaultListableBeanFactory) beanFactory)
        {
            foreach (type; [
                typeNameOf!BeanFactory, typeNameOf!ListableBeanFactory,
                typeNameOf!ConfigurableListableBeanFactory
            ])
                factory.registerResolvableDependency(type, factory);
            foreach (type; [
                typeNameOf!ApplicationContext, typeNameOf!ConfigurableApplicationContext,
                typeNameOf!ResourceLoader, typeNameOf!ApplicationEventPublisher
            ])
                factory.registerResolvableDependency(type, this);
            auto environment = getConfigurableEnvironment();
            foreach (type; [typeNameOf!Environment, typeNameOf!ConfigurableEnvironment])
                factory.registerResolvableDependency(type, cast(Object) environment);
            factory.registerResolvableDependency(canonicalTypeName(typeid(cast(Object) environment)
                    .name), cast(Object) environment);
            factory.registerResolvableDependency(typeNameOf!ConversionService,
                    cast(Object) environment.getConversionService());
        }
        if (!beanFactory.containsLocalBean(ENVIRONMENT_BEAN_NAME))
            beanFactory.registerSingleton(ENVIRONMENT_BEAN_NAME, cast(Object) getConfigurableEnvironment());
        if (!beanFactory.hasEmbeddedValueResolver())
            beanFactory.addEmbeddedValueResolver(new EnvironmentValueResolver(getConfigurableEnvironment()));
        if (beanFactory.getConversionService() is null)
            beanFactory.setConversionService(getConfigurableEnvironment().getConversionService());
    }

    /// Modify the factory after its standard preparation: a hook for subclasses.
    protected void postProcessBeanFactory(ConfigurableListableBeanFactory)
    {
    }

    /// Run the registered and the bean `BeanFactoryPostProcessor`s: `PriorityOrdered`, `Ordered`, then the rest.
    protected void invokeBeanFactoryPostProcessors(ConfigurableListableBeanFactory beanFactory)
    {
        foreach (processor; beanFactoryPostProcessors)
            processor.postProcessBeanFactory(beanFactory);
        Object[] beans;
        foreach (name; beanFactory.getBeanNamesForTypeErased(typeNameOf!BeanFactoryPostProcessor))
            beans ~= beanFactory.getBean(name);
        foreach (bean; sortByOrder(beans))
            (cast(BeanFactoryPostProcessor) bean).postProcessBeanFactory(beanFactory);
    }

    /// Register the `BeanPostProcessor` beans: `PriorityOrdered`, `Ordered`, then the rest.
    protected void registerBeanPostProcessors(ConfigurableListableBeanFactory beanFactory)
    {
        Object[] beans;
        foreach (name; beanFactory.getBeanNamesForTypeErased(typeNameOf!BeanPostProcessor))
            beans ~= beanFactory.getBean(name);
        foreach (bean; sortByOrder(beans))
            beanFactory.addBeanPostProcessor(cast(BeanPostProcessor) bean);
    }

    /// The `applicationEventMulticaster` bean, or a `SimpleApplicationEventMulticaster`.
    protected void initApplicationEventMulticaster()
    {
        auto beanFactory = getBeanFactory();
        if (beanFactory.containsLocalBean(APPLICATION_EVENT_MULTICASTER_BEAN_NAME))
            multicaster = cast(ApplicationEventMulticaster) beanFactory.getBean(
                    APPLICATION_EVENT_MULTICASTER_BEAN_NAME);
        else
        {
            multicaster = new SimpleApplicationEventMulticaster;
            beanFactory.registerSingleton(APPLICATION_EVENT_MULTICASTER_BEAN_NAME, cast(Object) multicaster);
        }
    }

    /// Initialize special beans (a web server): a hook for subclasses.
    protected void onRefresh()
    {
    }

    /// Register static, bean and `@EventListener` listeners, then publish the early events.
    protected void registerListeners()
    {
        foreach (listener; applicationListeners)
            multicaster.addApplicationListener(listener);
        registerAdditionalListeners(multicaster);
        auto early = earlyEvents;
        earlyEvents = null;
        collectingEarlyEvents = false;
        foreach (event; early)
            multicaster.multicastEvent(event);
    }

    /// Add listeners a subclass knows about (the AOT `@EventListener` table).
    protected void registerAdditionalListeners(ApplicationEventMulticaster)
    {
    }

    /// Freeze the configuration and create every non-lazy singleton.
    protected void finishBeanFactoryInitialization(ConfigurableListableBeanFactory beanFactory)
    {
        if (beanFactory.containsBean(CONVERSION_SERVICE_BEAN_NAME))
            if (auto service = cast(ConversionService) beanFactory.getBean(CONVERSION_SERVICE_BEAN_NAME))
                beanFactory.setConversionService(service);
        beanFactory.freezeConfiguration();
        beanFactory.preInstantiateSingletons();
    }

    /// Start auto-startup lifecycle beans and publish `ContextRefreshedEvent`.
    protected void finishRefresh()
    {
        initLifecycleProcessor();
        lifecycleProcessor.onRefresh();
        publishEvent(new ContextRefreshedEvent(this));
    }

    /// The `lifecycleProcessor` bean, or a `DefaultLifecycleProcessor`.
    protected void initLifecycleProcessor()
    {
        auto beanFactory = getBeanFactory();
        if (beanFactory.containsLocalBean(LIFECYCLE_PROCESSOR_BEAN_NAME))
            lifecycleProcessor = cast(LifecycleProcessor) beanFactory.getBean(LIFECYCLE_PROCESSOR_BEAN_NAME);
        else
        {
            lifecycleProcessor = new DefaultLifecycleProcessor(beanFactory);
            beanFactory.registerSingleton(LIFECYCLE_PROCESSOR_BEAN_NAME, cast(Object) lifecycleProcessor);
        }
    }

    /// Reset the active flag after a failed refresh.
    protected void cancelRefresh(Exception)
    {
        active = false;
    }

    /// Destroy every singleton.
    protected void destroyBeans()
    {
        getBeanFactory().destroySingletons();
    }

    /// Re-create or reset the factory: implemented by subclasses.
    protected abstract void refreshBeanFactory();
    /// Release the factory: implemented by subclasses.
    protected abstract void closeBeanFactory();
    abstract ConfigurableListableBeanFactory getBeanFactory();

    // ---- Close

    /// Close the context when the process terminates. Flint has no JVM shutdown hooks: Flint Boot's graceful
    /// shutdown closes registered contexts on SIGTERM and SIGINT; this records the request.
    void registerShutdownHook()
    {
        shutdownHookRegistered = true;
    }

    /// Whether `registerShutdownHook` was called.
    final bool isShutdownHookRegistered() const pure nothrow @nogc
    {
        return shutdownHookRegistered;
    }

    /// Publish `ContextClosedEvent`, stop lifecycle beans, destroy singletons and release the factory.
    void close()
    {
        doClose();
    }

    /// The close sequence; a second call does nothing.
    protected void doClose()
    {
        if (!active || closed)
            return;
        closed = true;
        try
            publishEvent(new ContextClosedEvent(this));
        catch (Exception)
        {
        }
        if (lifecycleProcessor !is null)
        {
            try
                lifecycleProcessor.onClose();
            catch (Exception)
            {
            }
        }
        destroyBeans();
        closeBeanFactory();
        onClose();
        active = false;
    }

    /// Clean up after close: a hook for subclasses.
    protected void onClose()
    {
    }

    /// Whether refreshed and not closed.
    bool isActive()
    {
        return active;
    }

    /// Throw `IllegalStateException` unless active.
    protected void assertBeanFactoryActive()
    {
        if (!active)
            throw new IllegalStateException(getDisplayName() ~ (closed
                    ? " has been closed already" : " has not been refreshed yet"));
    }

    // ---- Lifecycle

    /// Start every lifecycle bean and publish `ContextStartedEvent`.
    void start()
    {
        getLifecycleProcessor().start();
        publishEvent(new ContextStartedEvent(this));
    }

    /// Stop every lifecycle bean and publish `ContextStoppedEvent`.
    void stop()
    {
        getLifecycleProcessor().stop();
        publishEvent(new ContextStoppedEvent(this));
    }

    /// Whether the lifecycle processor is running.
    bool isRunning()
    {
        return lifecycleProcessor !is null && lifecycleProcessor.isRunning();
    }

    private LifecycleProcessor getLifecycleProcessor()
    {
        if (lifecycleProcessor is null)
            throw new IllegalStateException("LifecycleProcessor not initialized - call 'refresh' before invoking "
                    ~ "lifecycle methods via the context: " ~ toString());
        return lifecycleProcessor;
    }

    // ---- BeanFactory delegation

    /// See `BeanFactory.getBeanErased`.
    Object getBeanErased(string name, string requiredType, Any[] args)
    {
        assertBeanFactoryActive();
        return getBeanFactory().getBeanErased(name, requiredType, args);
    }

    /// See `BeanFactory.containsBean`.
    bool containsBean(string name)
    {
        return getBeanFactory().containsBean(name);
    }

    /// See `BeanFactory.isSingleton`.
    bool isSingleton(string name)
    {
        return getBeanFactory().isSingleton(name);
    }

    /// See `BeanFactory.isPrototype`.
    bool isPrototype(string name)
    {
        return getBeanFactory().isPrototype(name);
    }

    /// See `BeanFactory.isTypeMatchErased`.
    bool isTypeMatchErased(string name, string typeName)
    {
        return getBeanFactory().isTypeMatchErased(name, typeName);
    }

    /// See `BeanFactory.getTypeName`.
    string getTypeName(string name)
    {
        return getBeanFactory().getTypeName(name);
    }

    /// See `BeanFactory.getAliases`.
    string[] getAliases(string name)
    {
        return getBeanFactory().getAliases(name);
    }

    /// See `ListableBeanFactory.containsBeanDefinition`.
    bool containsBeanDefinition(string beanName)
    {
        return getBeanFactory().containsBeanDefinition(beanName);
    }

    /// See `ListableBeanFactory.getBeanDefinitionCount`.
    int getBeanDefinitionCount()
    {
        return getBeanFactory().getBeanDefinitionCount();
    }

    /// See `ListableBeanFactory.getBeanDefinitionNames`.
    string[] getBeanDefinitionNames()
    {
        return getBeanFactory().getBeanDefinitionNames();
    }

    /// See `ListableBeanFactory.getBeanNamesForTypeErased`.
    string[] getBeanNamesForTypeErased(string typeName, bool includeNonSingletons = true, bool allowEagerInit = true)
    {
        return getBeanFactory().getBeanNamesForTypeErased(typeName, includeNonSingletons, allowEagerInit);
    }

    /// See `ListableBeanFactory.getBeanNamesForAnnotationErased`.
    string[] getBeanNamesForAnnotationErased(string annotationType)
    {
        return getBeanFactory().getBeanNamesForAnnotationErased(annotationType);
    }

    /// The parent context's factory, or null.
    BeanFactory getParentBeanFactory()
    {
        return parent;
    }

    /// See `HierarchicalBeanFactory.containsLocalBean`.
    bool containsLocalBean(string name)
    {
        return getBeanFactory().containsLocalBean(name);
    }

    /// `DisplayName, started on <date>`.
    override string toString()
    {
        return getDisplayName() ~ ", started on " ~ valueOf(startupDate) ~ (parent is null
                ? "" : ", parent: " ~ parent.getDisplayName());
    }
}

/// `PriorityOrdered` first, then `Ordered` by value, then the rest in registration order.
private Object[] sortByOrder(Object[] beans)
{
    auto sorted = beans.dup;
    stableSort(sorted, (Object a, Object b) {
        const pa = cast(PriorityOrdered) a !is null, pb = cast(PriorityOrdered) b !is null;
        if (pa != pb)
            return pa ? -1 : 1;
        const oa = orderOf(a), ob = orderOf(b);
        return oa < ob ? -1 : (oa > ob ? 1 : 0);
    });
    return sorted;
}

private int orderOf(Object bean)
{
    auto ordered = cast(Ordered) bean;
    return ordered is null ? Ordered.LOWEST_PRECEDENCE : ordered.getOrder();
}

/// `${...}` resolution against the environment, strict, for `@Value` and annotation attributes.
private final class EnvironmentValueResolver : StringValueResolver
{
    private ConfigurableEnvironment environment;

    this(ConfigurableEnvironment environment) pure nothrow @nogc
    {
        this.environment = environment;
    }

    string resolveStringValue(string strVal)
    {
        return environment.resolveRequiredPlaceholders(strVal);
    }
}

/// Calls `EnvironmentAware`, `ResourceLoaderAware`, `ApplicationEventPublisherAware` and `ApplicationContextAware`.
class ApplicationContextAwareProcessor : BeanPostProcessor
{
    private ConfigurableApplicationContext applicationContext;

    /// A processor for `applicationContext`.
    this(ConfigurableApplicationContext applicationContext) pure nothrow @nogc
    {
        this.applicationContext = applicationContext;
    }

    /// The aware callbacks, before initialization.
    override Object postProcessBeforeInitialization(Object bean, string beanName)
    {
        if (auto aware = cast(EnvironmentAware) bean)
            aware.setEnvironment(applicationContext.getEnvironment());
        if (auto aware = cast(ResourceLoaderAware) bean)
            aware.setResourceLoader(applicationContext);
        if (auto aware = cast(ApplicationEventPublisherAware) bean)
            aware.setApplicationEventPublisher(applicationContext);
        if (auto aware = cast(ApplicationContextAware) bean)
            aware.setApplicationContext(applicationContext);
        return bean;
    }
}

/// Registers beans that are listeners with the context.
class ApplicationListenerDetector : BeanPostProcessor
{
    private AbstractApplicationContext applicationContext;

    /// A detector for `applicationContext`.
    this(AbstractApplicationContext applicationContext) pure nothrow @nogc
    {
        this.applicationContext = applicationContext;
    }

    /// Register `bean` when it is a listener.
    override Object postProcessAfterInitialization(Object bean, string beanName)
    {
        if (auto listener = cast(GenericApplicationListener) bean)
            applicationContext.addApplicationListener(listener);
        return bean;
    }
}

/++
The default `LifecycleProcessor`: starts `SmartLifecycle` beans with auto-startup on refresh in ascending phase
order, and stops every running `Lifecycle` bean on close in descending phase order.
+/
class DefaultLifecycleProcessor : LifecycleProcessor
{
    private ListableBeanFactory beanFactory;
    private bool running;

    /// A processor over `beanFactory`.
    this(ListableBeanFactory beanFactory) pure nothrow @nogc
    {
        this.beanFactory = beanFactory;
    }

    /// Start every lifecycle bean.
    void start()
    {
        startBeans(false);
        running = true;
    }

    /// Stop every lifecycle bean.
    void stop()
    {
        stopBeans();
        running = false;
    }

    /// Start auto-startup `SmartLifecycle` beans.
    void onRefresh()
    {
        startBeans(true);
        running = true;
    }

    /// Stop every lifecycle bean.
    void onClose()
    {
        stopBeans();
        running = false;
    }

    /// Whether started.
    bool isRunning()
    {
        return running;
    }

    private Lifecycle[] lifecycleBeans()
    {
        Lifecycle[] result;
        foreach (name; beanFactory.getBeanNamesForTypeErased(typeNameOf!Lifecycle))
            if (auto lifecycle = cast(Lifecycle) beanFactory.getBean(name))
                result ~= lifecycle;
        foreach (name; beanFactory.getBeanNamesForTypeErased(typeNameOf!SmartLifecycle))
        {
            auto lifecycle = cast(Lifecycle) beanFactory.getBean(name);
            bool seen;
            foreach (existing; result)
                seen |= existing is lifecycle;
            if (!seen && lifecycle !is null)
                result ~= lifecycle;
        }
        return result;
    }

    private static int phaseOf(Lifecycle bean)
    {
        auto phased = cast(Phased) bean;
        return phased is null ? 0 : phased.getPhase();
    }

    private void startBeans(bool autoStartupOnly)
    {
        auto beans = lifecycleBeans();
        stableSort(beans, (Lifecycle a, Lifecycle b) {
            const x = phaseOf(a), y = phaseOf(b);
            return x < y ? -1 : (x > y ? 1 : 0);
        });
        foreach (bean; beans)
        {
            auto smart = cast(SmartLifecycle) bean;
            if (autoStartupOnly && (smart is null || !smart.isAutoStartup()))
                continue;
            if (!bean.isRunning())
                bean.start();
        }
    }

    private void stopBeans()
    {
        auto beans = lifecycleBeans();
        stableSort(beans, (Lifecycle a, Lifecycle b) {
            const x = phaseOf(a), y = phaseOf(b);
            return x > y ? -1 : (x < y ? 1 : 0);
        });
        foreach (bean; beans)
        {
            if (!bean.isRunning())
                continue;
            if (auto smart = cast(SmartLifecycle) bean)
                smart.stop(new NoOpRunnable);
            else
                bean.stop();
        }
    }
}

private final class NoOpRunnable : Runnable
{
    void run()
    {
    }
}

// ---------------------------------------------------------------------------------------------------------------
// GenericApplicationContext

/++
A generic application context over one `DefaultListableBeanFactory`, refreshed once. Definitions come from the
Flint AOT registry (`loadAotRegistry`), from `registerBean`, or from `registerBeanDefinition`.
+/
class GenericApplicationContext : AbstractApplicationContext, BeanDefinitionRegistry
{
    private DefaultListableBeanFactory beanFactory;
    private bool refreshed;
    private DescriptorTable descriptors;
    private EventListenerSpec[] eventListeners;
    private HandlerMapping[] mappings;
    private ExceptionHandlerSpec[] exceptionHandlers;
    private DerivedQuery[] queries;
    private string applicationType;
    private string[] scanPackages;
    private string webApplicationType = "NONE";
    private RegistryPopulator deferredRegistry;

    /// A context with a new factory.
    this()
    {
        this(new DefaultListableBeanFactory);
    }

    /// A context over `beanFactory`.
    this(DefaultListableBeanFactory beanFactory)
    {
        super();
        this.beanFactory = beanFactory;
        descriptors = DescriptorTable.withBuiltins();
    }

    /// The factory, whether or not the context is active.
    final DefaultListableBeanFactory getDefaultListableBeanFactory() pure nothrow @nogc
    {
        return beanFactory;
    }

    /// The factory.
    override ConfigurableListableBeanFactory getBeanFactory()
    {
        return beanFactory;
    }

    /// Mark refreshed; a second refresh throws, as in Spring.
    protected override void refreshBeanFactory()
    {
        if (refreshed)
            throw new IllegalStateException(
                    "GenericApplicationContext does not support multiple refresh attempts: just call 'refresh' once");
        refreshed = true;
        beanFactory.setConversionService(getConfigurableEnvironment().getConversionService());
        beanFactory.setDescriptorTable(descriptors);
    }

    /// Nothing to release beyond the destroyed singletons.
    protected override void closeBeanFactory()
    {
    }

    /// Whether definitions may override each other (Flint Boot sets false).
    void setAllowBeanDefinitionOverriding(bool allowBeanDefinitionOverriding)
    {
        beanFactory.setAllowBeanDefinitionOverriding(allowBeanDefinitionOverriding);
    }

    /// The application type for `@ConditionalOnWebApplication`: `NONE`, `SERVLET` or `REACTIVE`.
    final void setWebApplicationType(string type) pure nothrow @nogc
    {
        webApplicationType = type;
    }

    // ---- AOT registry

    /++
    Load the generated registry during `refresh()`, before the `BeanFactoryPostProcessor`s run (where Spring's
    `ConfigurationClassPostProcessor` evaluates conditions), so singletons registered after construction (Boot's
    application arguments, banner and binder) are visible to startup conditions. Null means the installed registry.
    +/
    final void deferAotRegistry(RegistryPopulator populate = null)
    {
        deferredRegistry = populate is null ? installedRegistry() : populate;
    }

    /// Load a deferred registry, then run the factory post-processors.
    protected override void invokeBeanFactoryPostProcessors(ConfigurableListableBeanFactory beanFactory)
    {
        if (deferredRegistry !is null)
        {
            auto populate = deferredRegistry;
            deferredRegistry = null;
            loadAotRegistry(populate);
        }
        super.invokeBeanFactoryPostProcessors(beanFactory);
    }

    /// Load `populate`'s definitions (by default the installed generated registry) now, evaluating conditions in order.
    void loadAotRegistry(RegistryPopulator populate = null)
    {
        if (populate is null)
            populate = installedRegistry();
        if (populate is null)
            return;
        auto loader = new RegistryLoader(this);
        populate(loader);
    }

    /// The descriptors registered by Flint AOT, with the built-in scalar descriptors.
    final DescriptorTable getDescriptorTable() pure nothrow @nogc
    {
        return descriptors;
    }

    /// The request mappings registered by Flint AOT, for the web layer.
    final HandlerMapping[] getAotHandlerMappings() pure nothrow
    {
        return mappings.dup;
    }

    /// The exception handlers registered by Flint AOT, for the web layer.
    final ExceptionHandlerSpec[] getAotExceptionHandlers() pure nothrow
    {
        return exceptionHandlers.dup;
    }

    /// The derived queries registered by Flint AOT, for the data layer.
    final DerivedQuery[] getAotQueries() pure nothrow
    {
        return queries.dup;
    }

    /// The `@FlintBootApplication` type and its scanned packages, when registered.
    final string getApplicationType() const pure nothrow @nogc
    {
        return applicationType;
    }

    /// Register the `@EventListener` methods of the AOT table.
    protected override void registerAdditionalListeners(ApplicationEventMulticaster multicaster)
    {
        foreach (spec; eventListeners)
        {
            const bean = spec.bean;
            multicaster.addApplicationListener(new ApplicationListenerMethodAdapter(spec,
                    () => beanFactory.getBean(bean), (ApplicationEvent event) { publishEvent(event); }));
        }
    }

    // ---- Programmatic registration

    /// Register a bean of type `T` created by `supplier` (Java's `registerBean(Class, Supplier)`).
    void registerBean(T)(string beanName, T delegate() @safe supplier)
    {
        auto definition = new RootBeanDefinition(definitionFor!T(beanName));
        definition.setInstanceSupplier(() => cast(Object) supplier());
        registerBeanDefinition(beanName, definition);
    }

    /// Register a bean of type `T` named after its class (decapitalized), created with `new T()`.
    void registerBean(T)()
    {
        registerBean!T(defaultBeanName!T(), () => new T());
    }

    /// Register a bean of type `T` named `beanName`, created with `new T()`.
    void registerBean(T)(string beanName)
    {
        registerBean!T(beanName, () => new T());
    }

    private static AotBeanDefinition definitionFor(T)(string beanName)
    {
        import std.traits : BaseClassesTuple, InterfacesTuple;

        AotBeanDefinition record;
        record.name = beanName;
        record.type = typeNameOf!T;
        record.types = [typeNameOf!T];
        static if (is(T == class))
        {
            static foreach (S; BaseClassesTuple!T)
                static if (!is(S == Object))
                    record.types ~= typeNameOf!S;
        }
        static foreach (I; InterfacesTuple!T)
            record.types ~= typeNameOf!I;
        record.source = "registerBean " ~ typeNameOf!T;
        return record;
    }

    private static string defaultBeanName(T)()
    {
        import flint.engine.aot.name : simpleTypeName;

        const simple = simpleTypeName(typeNameOf!T);
        if (simple.length >= 2 && simple[0] >= 'A' && simple[0] <= 'Z' && simple[1] >= 'A' && simple[1] <= 'Z')
            return simple;
        return [cast(char)(simple[0] >= 'A' && simple[0] <= 'Z' ? simple[0] + 32 : simple[0])] ~ simple[1 .. $];
    }

    // ---- BeanDefinitionRegistry

    /// Register a definition.
    void registerBeanDefinition(string beanName, BeanDefinition beanDefinition)
    {
        beanFactory.registerBeanDefinition(beanName, beanDefinition);
    }

    /// Remove a definition.
    void removeBeanDefinition(string beanName)
    {
        beanFactory.removeBeanDefinition(beanName);
    }

    /// The definition.
    BeanDefinition getBeanDefinition(string beanName)
    {
        return beanFactory.getBeanDefinition(beanName);
    }

    /// Whether the name is in use.
    bool isBeanNameInUse(string beanName)
    {
        return beanFactory.isBeanNameInUse(beanName);
    }

    /// Register an alias.
    void registerAlias(string beanName, string alias_)
    {
        beanFactory.registerAlias(beanName, alias_);
    }

    /// Remove an alias.
    void removeAlias(string alias_)
    {
        beanFactory.removeAlias(alias_);
    }

    /// Whether `beanName` is an alias.
    bool isAlias(string beanName)
    {
        return beanFactory.isAlias(beanName);
    }

    override string[] getAliases(string name)
    {
        return beanFactory.getAliases(name);
    }

    override bool containsBeanDefinition(string beanName)
    {
        return beanFactory.containsBeanDefinition(beanName);
    }

    override string[] getBeanDefinitionNames()
    {
        return beanFactory.getBeanDefinitionNames();
    }

    override int getBeanDefinitionCount()
    {
        return beanFactory.getBeanDefinitionCount();
    }
}

/// The `AotRegistry` a context loads the generated registry with.
private final class RegistryLoader : AotRegistry
{
    private GenericApplicationContext context;
    private ContextConditions conditions;

    this(GenericApplicationContext context) pure nothrow
    {
        this.context = context;
        conditions = new ContextConditions(context);
    }

    void begin(uint contractVersion, size_t) scope
    {
        checkContractVersion(contractVersion);
    }

    void bean(AotBeanDefinition definition) scope
    {
        if (definition.condition !is null && !definition.condition(conditions))
            return;
        context.beanFactory.registerAotDefinition(definition);
    }

    void descriptor(Descriptor descriptor) scope
    {
        context.descriptors.add(descriptor);
    }

    void mapping(HandlerMapping mapping) scope
    {
        context.mappings ~= mapping;
    }

    void exceptionHandler(ExceptionHandlerSpec handler) scope
    {
        context.exceptionHandlers ~= handler;
    }

    void listener(EventListenerSpec listener) scope
    {
        if (context.beanFactory.containsBeanDefinition(listener.bean))
            context.eventListeners ~= listener;
    }

    void query(DerivedQuery query) scope
    {
        context.queries ~= query;
    }

    void application(string type, string[] scanPackages) scope
    {
        context.applicationType = type;
        context.scanPackages = scanPackages;
    }

    void end() scope
    {
        auto factory = context.beanFactory;
        foreach (name; factory.getBeanDefinitionNames())
        {
            auto definition = factory.getBeanDefinition(name);
            if (auto descriptor = context.descriptors.find(definition.getBeanClassName()))
                definition.setAttribute("flint.annotations", Any.of(descriptor.annotations.dup));
        }
    }

}

/// The `ConditionContext` generated conditions see: what is registered so far, and the environment.
private final class ContextConditions : ConditionContext
{
    private GenericApplicationContext context;

    this(GenericApplicationContext context) pure nothrow @nogc
    {
        this.context = context;
    }

    bool acceptsProfile(string profile)
    {
        return context.getConfigurableEnvironment().acceptsProfiles(Profiles.of(profile));
    }

    bool property(string name, string havingValue, bool matchIfMissing)
    {
        auto environment = context.getConfigurableEnvironment();
        const present = environment.containsProperty(name);
        return propertyMatches(present, present ? environment.getProperty(name) : null, havingValue, matchIfMissing);
    }

    bool hasBeanOfType(string type)
    {
        return context.beanFactory.getBeanNamesForTypeErased(type).length != 0;
    }

    bool hasBeanNamed(string name)
    {
        return context.beanFactory.containsBean(name);
    }

    bool hasSingleCandidate(string type)
    {
        auto names = context.beanFactory.getBeanNamesForTypeErased(type);
        if (names.length == 1)
            return true;
        size_t primaries;
        foreach (name; names)
            if (context.beanFactory.getBeanDefinition(name).isPrimary())
                primaries++;
        return primaries == 1;
    }

    bool isWebApplication(string type)
    {
        if (context.webApplicationType == "NONE")
            return false;
        return type == "ANY" || type == context.webApplicationType;
    }

    bool isAutoConfigurationExcluded(string type)
    {
        foreach (excluded; excludedAutoConfigurations())
            if (excluded == type)
                return true;
        return false;
    }

    /// `flint.autoconfigure.exclude`: through the binder when Flint Boot registered one (comma or indexed lists,
    /// the `spring.` alias), else the comma list the environment resolves.
    private string[] excludedAutoConfigurations()
    {
        enum key = "flint.autoconfigure.exclude";
        if (auto binder = context.beanFactory.getConfigurationPropertiesBinder())
            return binder.bindList(key);
        string[] result;
        foreach (entry; StringUtils.commaDelimitedListToStringArray(context.getConfigurableEnvironment()
                .getProperty(key)))
            result ~= StringUtils.trimWhitespace(entry);
        return result;
    }
}
