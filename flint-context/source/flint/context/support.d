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
import flint.context : ApplicationContext, ApplicationContextAware, ApplicationContextException,
    ApplicationEvent, ApplicationEventPublisher, ApplicationEventPublisherAware,
    ConfigurableApplicationContext,
    EnvironmentAware, GenericApplicationListener, HierarchicalMessageSource,
    Lifecycle, LifecycleProcessor, MessageSource, MessageSourceAware, MessageSourceResolvable,
    NoSuchMessageException, Phased, ResourceLoaderAware, SmartLifecycle;
import flint.context.event : ApplicationEventMulticaster, ApplicationListenerMethodAdapter, ContextClosedEvent,
    ContextRefreshedEvent, ContextStartedEvent, ContextStoppedEvent, SimpleApplicationEventMulticaster;
import flint.core : Ordered, PriorityOrdered;
import flint.core.annotation.types : AnnotationAwareOrderComparator;
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
import flint.java.util : LinkedHashMap, Locale, Map, Properties, stableSort;
import flint.util : Assert, StringUtils, StringValueResolver;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// DefaultMessageSourceResolvable

/// Spring's default implementation of `MessageSourceResolvable`.
class DefaultMessageSourceResolvable : imported!"flint.context".MessageSourceResolvable
{
    private string[] codes;
    private Any[] arguments;
    private string defaultMessage;

    /// A resolvable for one code.
    this(string code)
    {
        this([code], null, null);
    }

    /// A resolvable for `codes`, `arguments` and `defaultMessage` (each may be null).
    this(string[] codes, Any[] arguments = null, string defaultMessage = null) pure nothrow @nogc
    {
        this.codes = codes;
        this.arguments = arguments;
        this.defaultMessage = defaultMessage;
    }

    /// A copy of `resolvable`.
    this(imported!"flint.context".MessageSourceResolvable resolvable)
    {
        this(resolvable.getCodes(), resolvable.getArguments(), resolvable.getDefaultMessage());
    }

    /// The last code (the most generic), or null.
    string getCode() const pure nothrow @nogc
    {
        return codes.length ? codes[$ - 1] : null;
    }

    /// The codes.
    string[] getCodes()
    {
        return codes;
    }

    /// The arguments.
    Any[] getArguments()
    {
        return arguments;
    }

    /// The default message.
    string getDefaultMessage()
    {
        return defaultMessage;
    }

    /// Whether the default message must be rendered as a message (Spring's default: true).
    bool shouldRenderDefaultMessage()
    {
        return true;
    }

    /// `codes [a,b]; arguments [x]; default message [m]`.
    protected final string resolvableToString()
    {
        string result = "codes [" ~ join(codes) ~ "]; arguments [";
        foreach (i, argument; arguments)
            result ~= (i ? "," : "") ~ argument.toString();
        return result ~ "]; default message [" ~ (defaultMessage is null ? "null" : defaultMessage) ~ "]";
    }

    private static string join(string[] values)
    {
        string result;
        foreach (i, value; values)
            result ~= (i ? "," : "") ~ value;
        return result;
    }

    /// Equal codes, arguments and default messages.
    override bool opEquals(Object other)
    {
        auto that = cast(DefaultMessageSourceResolvable) other;
        return that !is null && typeid(that) is typeid(this) && that.codes == codes
            && that.arguments == arguments && that.defaultMessage == defaultMessage;
    }

    /// Hash of the codes and default message.
    override size_t toHash() nothrow
    {
        return hashOf(codes) ^ hashOf(defaultMessage);
    }

    /// `ClassName: codes [...]; arguments [...]; default message [...]`.
    override string toString()
    {
        return canonicalTypeName(typeid(this).name) ~ ": " ~ resolvableToString();
    }
}

// ---------------------------------------------------------------------------------------------------------------
// AbstractApplicationContext

/// Abstract implementation of `ConfigurableApplicationContext`: the refresh and close template.
abstract class AbstractApplicationContext : DefaultResourceLoader, ConfigurableApplicationContext
{
    /// The name of the `LifecycleProcessor` bean.
    enum LIFECYCLE_PROCESSOR_BEAN_NAME = "lifecycleProcessor";
    /// The name of the `ApplicationEventMulticaster` bean.
    enum APPLICATION_EVENT_MULTICASTER_BEAN_NAME = "applicationEventMulticaster";
    /// The name of the `MessageSource` bean; without one, the context delegates to its parent.
    enum MESSAGE_SOURCE_BEAN_NAME = "messageSource";

    private string id;
    private string displayName;
    private ApplicationContext parent;
    private ConfigurableEnvironment environment;
    private BeanFactoryPostProcessor[] beanFactoryPostProcessors;
    private GenericApplicationListener[] applicationListeners;
    private GenericApplicationListener[] earlyApplicationListeners; // the listeners registered before refresh
    private ApplicationEvent[] earlyEvents;
    private bool collectingEarlyEvents;
    private ApplicationEventMulticaster multicaster;
    private MessageSource messageSource;
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

    /// Publish `event` to the listeners (queued during refresh until the multicaster exists; dropped before refresh
    /// and after close, as in Spring), and to the parent context.
    void publishEventErased(ApplicationEvent event)
    {
        Assert.notNull(event, "Event must not be null");
        if (collectingEarlyEvents)
            earlyEvents ~= event;
        else if (multicaster !is null)
            multicaster.multicastEvent(event);
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
            initMessageSource();
            initApplicationEventMulticaster();
            onRefresh();
            registerListeners();
            finishBeanFactoryInitialization(beanFactory);
            finishRefresh();
        }
        catch (Exception e)
        {
            // Stop already started Lifecycle beans, then destroy the created singletons.
            if (lifecycleProcessor !is null && lifecycleProcessor.isRunning())
            {
                try
                    lifecycleProcessor.stop();
                catch (Exception)
                {
                }
            }
            destroyBeans();
            cancelRefresh(e);
            throw e;
        }
    }

    /// Mark the context active and validate the required properties.
    protected void prepareRefresh()
    {
        import flint.engine.aot.clock : currentTimeMillis;

        startupDate = currentTimeMillis();
        closed = false;
        active = true;
        initPropertySources();
        getConfigurableEnvironment().validateRequiredProperties();
        if (earlyApplicationListeners is null)
            earlyApplicationListeners = applicationListeners.dup;
        else
            applicationListeners = earlyApplicationListeners.dup;
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

    /// The `messageSource` bean (given the parent context as its parent), or a `DelegatingMessageSource` to the
    /// parent context.
    protected void initMessageSource()
    {
        auto beanFactory = getBeanFactory();
        if (beanFactory.containsLocalBean(MESSAGE_SOURCE_BEAN_NAME))
        {
            messageSource = cast(MessageSource) beanFactory.getBean(MESSAGE_SOURCE_BEAN_NAME);
            auto hierarchical = cast(HierarchicalMessageSource) messageSource;
            if (hierarchical !is null && getParent() !is null && hierarchical.getParentMessageSource() is null)
                hierarchical.setParentMessageSource(getParent());
        }
        else
        {
            auto delegating = new DelegatingMessageSource;
            delegating.setParentMessageSource(getParent());
            messageSource = delegating;
            beanFactory.registerSingleton(MESSAGE_SOURCE_BEAN_NAME, delegating);
        }
    }

    /// The context's message source. Throws `IllegalStateException` before `refresh`.
    protected MessageSource getMessageSource()
    {
        if (messageSource is null)
            throw new IllegalStateException("MessageSource not initialized - call 'refresh' before accessing "
                    ~ "messages via the context: " ~ getDisplayName());
        return messageSource;
    }

    /// See `MessageSource`.
    string getMessage(string code, Any[] args, string defaultMessage, Locale locale)
    {
        return getMessageSource().getMessage(code, args, defaultMessage, locale);
    }

    /// See `MessageSource`.
    string getMessage(string code, Any[] args, Locale locale)
    {
        return getMessageSource().getMessage(code, args, locale);
    }

    /// See `MessageSource`.
    string getMessage(MessageSourceResolvable resolvable, Locale locale)
    {
        return getMessageSource().getMessage(resolvable, locale);
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
        // Reset local application listeners to the pre-refresh state, and drop the per-refresh delegates.
        if (earlyApplicationListeners !is null)
            applicationListeners = earlyApplicationListeners.dup;
        multicaster = null;
        lifecycleProcessor = null;
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
        if (auto aware = cast(MessageSourceAware) bean)
            aware.setMessageSource(applicationContext);
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

    /// Register `bean` when it is a singleton listener (a listener of another scope cannot reliably receive events).
    override Object postProcessAfterInitialization(Object bean, string beanName)
    {
        if (auto listener = cast(GenericApplicationListener) bean)
        {
            auto factory = applicationContext.getBeanFactory();
            if (!factory.containsBeanDefinition(beanName) || factory.getBeanDefinition(beanName).isSingleton())
                applicationContext.addApplicationListener(listener);
        }
        return bean;
    }
}

/++
The default `LifecycleProcessor`, as Spring's: on refresh it starts the auto-startup `SmartLifecycle` beans in
ascending phase groups, each after the beans it depends on; on stop and close it stops every running `Lifecycle`
bean in descending phase groups, each after the beans that depend on it. A plain `Lifecycle` bean is in phase 0.
Stop callbacks run synchronously in the stopping fiber unless the bean hands them off.
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

    /// Start every lifecycle bean. A failing bean propagates `ApplicationContextException`.
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

    /// Start the auto-startup `SmartLifecycle` beans; when one fails, stop those already started and rethrow.
    void onRefresh()
    {
        try
            startBeans(true);
        catch (ApplicationContextException e)
        {
            stopBeans();
            throw e;
        }
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

    /// The `Lifecycle` beans by name: the existing singletons, and the `SmartLifecycle` beans (created if needed).
    protected Map!(string, Lifecycle) getLifecycleBeans()
    {
        Map!(string, Lifecycle) beans = new LinkedHashMap!(string, Lifecycle)();
        auto configurable = cast(ConfigurableListableBeanFactory) beanFactory;
        foreach (name; beanFactory.getBeanNamesForTypeErased(typeNameOf!Lifecycle, false, false))
        {
            const existing = configurable is null || configurable.containsSingleton(name);
            if (!existing && !beanFactory.isTypeMatchErased(name, typeNameOf!SmartLifecycle))
                continue;
            if (auto lifecycle = cast(Lifecycle) beanFactory.getBean(name))
                if (cast(Object) lifecycle !is this)
                    beans.put(name, lifecycle);
        }
        return beans;
    }

    /// The phase of `bean`: its `Phased.getPhase()`, else 0.
    protected int getPhase(Lifecycle bean)
    {
        auto phased = cast(Phased) bean;
        return phased is null ? 0 : phased.getPhase();
    }

    private void startBeans(bool autoStartupOnly)
    {
        auto lifecycleBeans = getLifecycleBeans();
        foreach (phase; phasesOf(lifecycleBeans, true, autoStartupOnly))
            foreach (name; lifecycleBeans.keySet().toArray())
                if (lifecycleBeans.containsKey(name) && getPhase(lifecycleBeans.get(name)) == phase
                        && (!autoStartupOnly || isAutoStartupCandidate(lifecycleBeans.get(name))))
                    doStart(lifecycleBeans, name, autoStartupOnly);
    }

    private int[] phasesOf(Map!(string, Lifecycle) lifecycleBeans, bool ascending, bool autoStartupOnly)
    {
        int[] phases;
        foreach (bean; lifecycleBeans.values().toArray())
        {
            if (autoStartupOnly && !isAutoStartupCandidate(bean))
                continue;
            const phase = getPhase(bean);
            bool seen;
            foreach (existing; phases)
                seen |= existing == phase;
            if (!seen)
                phases ~= phase;
        }
        stableSort(phases, (int a, int b) => ascending ? comparePhases(a, b) : comparePhases(b, a));
        return phases;
    }

    private static int comparePhases(int a, int b) pure nothrow @nogc
    {
        return a < b ? -1 : (a > b ? 1 : 0);
    }

    private static bool isAutoStartupCandidate(Lifecycle bean)
    {
        auto smart = cast(SmartLifecycle) bean;
        return smart !is null && smart.isAutoStartup();
    }

    private void doStart(Map!(string, Lifecycle) lifecycleBeans, string beanName, bool autoStartupOnly)
    {
        auto bean = lifecycleBeans.remove(beanName);
        if (bean is null)
            return;
        foreach (dependency; dependenciesOf(beanName, false))
            doStart(lifecycleBeans, dependency, autoStartupOnly);
        auto smart = cast(SmartLifecycle) bean;
        if (bean.isRunning() || (autoStartupOnly && smart !is null && !smart.isAutoStartup()))
            return;
        try
            bean.start();
        catch (Exception e)
            throw new ApplicationContextException("Failed to start bean '" ~ beanName ~ "'", e);
    }

    private string[] dependenciesOf(string beanName, bool dependents)
    {
        auto configurable = cast(ConfigurableListableBeanFactory) beanFactory;
        if (configurable is null)
            return null;
        return dependents ? configurable.getDependentBeans(beanName) : configurable.getDependenciesForBean(beanName);
    }

    private void stopBeans()
    {
        auto lifecycleBeans = getLifecycleBeans();
        foreach (phase; phasesOf(lifecycleBeans, false, false))
            foreach (name; lifecycleBeans.keySet().toArray())
                if (lifecycleBeans.containsKey(name) && getPhase(lifecycleBeans.get(name)) == phase)
                    doStop(lifecycleBeans, name);
    }

    private void doStop(Map!(string, Lifecycle) lifecycleBeans, string beanName)
    {
        auto bean = lifecycleBeans.remove(beanName);
        if (bean is null)
            return;
        foreach (dependent; dependenciesOf(beanName, true))
            doStop(lifecycleBeans, dependent);
        try
        {
            if (!bean.isRunning())
                return;
            if (auto smart = cast(SmartLifecycle) bean)
                smart.stop(new NoOpRunnable);
            else
                bean.stop();
        }
        catch (Exception)
        {
            // Spring logs a failure to stop and goes on with the other beans.
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

    /// A context with a new factory and `parent`.
    this(ApplicationContext parent)
    {
        this();
        assignParent(parent);
    }

    /// Set the parent context, and make its factory the parent of this context's factory.
    override void setParent(ApplicationContext parent)
    {
        assignParent(parent);
    }

    private void assignParent(ApplicationContext parent)
    {
        super.setParent(parent);
        if (auto configurable = cast(ConfigurableApplicationContext) parent)
            beanFactory.setParentBeanFactory(configurable.getBeanFactory());
        else
            beanFactory.setParentBeanFactory(parent);
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
        if (beanFactory.getDependencyComparator() is null) // AnnotationConfigUtils' comparator: @Order and @Priority
            beanFactory.setDependencyComparator(new AnnotationAwareOrderComparator(descriptors));
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
            multicaster.addApplicationListener(new ApplicationListenerMethodAdapter(spec,
                    beanSupplier(spec.bean), (ApplicationEvent event) { publishEvent(event); },
                    (string name) => beanFactory.getBean(name),
                    (string text) => getEnvironment().resolveRequiredPlaceholders(text)));
    }

    /// A supplier of the bean `name`, in a frame of its own: a lambda in the loop above would share the loop
    /// variable, so every listener would resolve the last one's bean.
    private Object delegate() @safe beanSupplier(string name)
    {
        return () => beanFactory.getBean(name);
    }

    // ---- Programmatic registration

    /++
    Register a bean of type `T` named `beanName`, created by `supplier`, after applying `customizers` to its
    definition (Java's `registerBean(String, Class, Supplier, BeanDefinitionCustomizer...)`; the customizers are
    delegates, rule R9).
    +/
    void registerBean(T)(string beanName, T delegate() @safe supplier,
            void delegate(BeanDefinition) @safe[] customizers...)
    {
        auto definition = new RootBeanDefinition(definitionFor!T(beanName));
        definition.setInstanceSupplier(() => cast(Object) supplier());
        foreach (customizer; customizers)
            customizer(definition);
        registerBeanDefinition(beanName, definition);
    }

    /// Register a bean of type `T` created by `supplier`, named by `generateBeanName` (Java's
    /// `registerBean(Class, Supplier, BeanDefinitionCustomizer...)`).
    void registerBean(T)(T delegate() @safe supplier, void delegate(BeanDefinition) @safe[] customizers...)
    {
        registerBean!T(generateBeanName(typeNameOf!T), supplier, customizers);
    }

    /// Register a bean of type `T` created with `new T()`, named by `generateBeanName` (Java's
    /// `registerBean(Class)`).
    void registerBean(T)()
    {
        registerBean!T(generateBeanName(typeNameOf!T), () => new T());
    }

    /// Register a bean of type `T` named `beanName`, created with `new T()`.
    void registerBean(T)(string beanName)
    {
        registerBean!T(beanName, () => new T());
    }

    /// The name of a bean registered without one: its class name, as `GenericApplicationContext` names it.
    protected string generateBeanName(string typeName)
    {
        return typeName;
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

// ---------------------------------------------------------------------------------------------------------------
// Message sources

/// The message-format support of message sources (Spring's `MessageSourceSupport`).
abstract class MessageSourceSupport
{
    private bool alwaysUseMessageFormat;

    /// Parse messages without arguments with `MessageFormat` too (so `''` becomes `'`); off by default.
    void setAlwaysUseMessageFormat(bool alwaysUseMessageFormat) pure nothrow @nogc
    {
        this.alwaysUseMessageFormat = alwaysUseMessageFormat;
    }

    /// Whether every message is parsed with `MessageFormat`.
    protected bool isAlwaysUseMessageFormat() const pure nothrow @nogc
    {
        return alwaysUseMessageFormat;
    }

    /// `defaultMessage` rendered with `args` (Spring's `renderDefaultMessage`).
    protected string renderDefaultMessage(string defaultMessage, Any[] args, Locale locale)
    {
        return formatMessage(defaultMessage, args, locale);
    }

    /// `msg` formatted with `args` by `MessageFormat`, or as is without arguments unless always formatting.
    protected string formatMessage(string msg, Any[] args, Locale locale)
    {
        import flint.java.text : MessageFormat;

        if (msg is null || (!alwaysUseMessageFormat && args.length == 0))
            return msg;
        return new MessageFormat(msg, locale).format(args);
    }
}

/++
Spring's `AbstractMessageSource`: resolves codes through `resolveCode`/`resolveCodeWithoutArguments`, then the
parent, then common messages; renders `MessageSourceResolvable` arguments (field names) recursively.
+/
abstract class AbstractMessageSource : MessageSourceSupport, HierarchicalMessageSource
{
    private MessageSource parentMessageSource;
    private Properties commonMessages;
    private bool useCodeAsDefaultMessage;

    /// Set the parent.
    void setParentMessageSource(MessageSource parent)
    {
        parentMessageSource = parent;
    }

    /// The parent, or null.
    MessageSource getParentMessageSource()
    {
        return parentMessageSource;
    }

    /// Locale-independent messages, consulted after the bundles and the parent.
    void setCommonMessages(Properties commonMessages)
    {
        this.commonMessages = commonMessages;
    }

    /// The common messages, or null.
    Properties getCommonMessages()
    {
        return commonMessages;
    }

    /// Use the code itself as the message when none is found (instead of throwing).
    void setUseCodeAsDefaultMessage(bool useCodeAsDefaultMessage) pure nothrow @nogc
    {
        this.useCodeAsDefaultMessage = useCodeAsDefaultMessage;
    }

    /// Whether the code is the default message.
    protected bool isUseCodeAsDefaultMessage() const pure nothrow @nogc
    {
        return useCodeAsDefaultMessage;
    }

    /// See `MessageSource`.
    final string getMessage(string code, Any[] args, string defaultMessage, Locale locale)
    {
        auto msg = getMessageInternal(code, args, locale);
        if (msg !is null)
            return msg;
        if (defaultMessage is null)
            return getDefaultMessage(code);
        return renderDefaultMessage(defaultMessage, resolveArguments(args, locale), locale);
    }

    /// See `MessageSource`.
    final string getMessage(string code, Any[] args, Locale locale)
    {
        auto msg = getMessageInternal(code, args, locale);
        if (msg !is null)
            return msg;
        auto fallback = getDefaultMessage(code);
        if (fallback !is null)
            return fallback;
        throw new NoSuchMessageException(code, locale);
    }

    /// See `MessageSource`.
    final string getMessage(MessageSourceResolvable resolvable, Locale locale)
    {
        auto codes = resolvable.getCodes();
        foreach (code; codes)
            if (auto message = getMessageInternal(code, resolvable.getArguments(), locale))
                return message;
        if (auto fallback = getDefaultMessage(resolvable, locale))
            return fallback;
        throw new NoSuchMessageException(codes.length ? codes[$ - 1] : null, locale);
    }

    /// The message for `code`, from this source, the parent or the common messages; null when none.
    protected string getMessageInternal(string code, Any[] args, Locale locale)
    {
        if (code is null)
            return null;
        Any[] arguments = args;
        if (!isAlwaysUseMessageFormat() && args.length == 0)
        {
            if (auto message = resolveCodeWithoutArguments(code, locale))
                return message;
        }
        else
        {
            arguments = resolveArguments(args, locale);
            if (auto message = resolveCode(code, arguments, locale))
                return message;
        }
        if (commonMessages !is null)
        {
            auto common = commonMessages.getProperty(code);
            if (common !is null)
                return formatMessage(common, arguments, locale);
        }
        return getMessageFromParent(code, arguments, locale);
    }

    /// The parent's message for `code`, or null.
    protected string getMessageFromParent(string code, Any[] args, Locale locale)
    {
        if (parentMessageSource is null)
            return null;
        if (auto parent = cast(AbstractMessageSource) parentMessageSource)
            return parent.getMessageInternal(code, args, locale);
        return parentMessageSource.getMessage(code, args, null, locale);
    }

    /// The resolvable's default message (rendered when it asks to be), else its last code when the code is the
    /// default message; null otherwise.
    protected string getDefaultMessage(MessageSourceResolvable resolvable, Locale locale)
    {
        auto defaultMessage = resolvable.getDefaultMessage();
        auto codes = resolvable.getCodes();
        if (defaultMessage !is null)
        {
            auto resolvableSupport = cast(DefaultMessageSourceResolvable) resolvable;
            if (resolvableSupport !is null && !resolvableSupport.shouldRenderDefaultMessage())
                return defaultMessage;
            if (codes.length && defaultMessage == codes[0])
                return defaultMessage;
            return renderDefaultMessage(defaultMessage, resolveArguments(resolvable.getArguments(), locale), locale);
        }
        return codes.length ? getDefaultMessage(codes[0]) : null;
    }

    /// The code when it is the default message, else null.
    protected string getDefaultMessage(string code)
    {
        return useCodeAsDefaultMessage ? code : null;
    }

    /// The arguments with each `MessageSourceResolvable` resolved to its message.
    protected Any[] resolveArguments(Any[] args, Locale locale)
    {
        if (args.length == 0)
            return args;
        Any[] resolved;
        foreach (arg; args)
        {
            if (auto resolvable = cast(MessageSourceResolvable) arg.asObject())
                resolved ~= Any.of(getMessage(resolvable, locale));
            else
                resolved ~= arg;
        }
        return resolved;
    }

    /// The message for `code` without arguments, or null: `resolveCode` with no arguments by default.
    protected string resolveCodeWithoutArguments(string code, Locale locale)
    {
        return resolveCode(code, null, locale);
    }

    /// The message for `code` formatted with `args`, or null.
    protected abstract string resolveCode(string code, Any[] args, Locale locale);
}

/// A `MessageSource` holding messages registered in code (Spring's `StaticMessageSource`), for tests.
class StaticMessageSource : AbstractMessageSource
{
    private string[string] messages;

    /// Register `msg` for `code` in `locale`.
    void addMessage(string code, Locale locale, string msg)
    {
        Assert.notNull(code, "Code must not be null");
        Assert.notNull(msg, "Message must not be null");
        messages[code ~ "_" ~ locale.toString()] = msg;
    }

    /// Register every entry of `messages` in `locale`.
    void addMessages(string[string] messages, Locale locale)
    {
        foreach (code, msg; messages)
            addMessage(code, locale, msg);
    }

    protected override string resolveCodeWithoutArguments(string code, Locale locale)
    {
        return messages.get(code ~ "_" ~ locale.toString(), null);
    }

    protected override string resolveCode(string code, Any[] args, Locale locale)
    {
        auto msg = resolveCodeWithoutArguments(code, locale);
        return msg is null ? null : formatMessage(msg, args, locale);
    }

    /// `StaticMessageSource: {code_locale=message, ...}`.
    override string toString()
    {
        string result = "StaticMessageSource: {";
        bool first = true;
        foreach (key, value; messages)
        {
            result ~= (first ? "" : ", ") ~ key ~ "=" ~ value;
            first = false;
        }
        return result ~ "}";
    }
}

/// A `MessageSource` that delegates every call to its parent; the context's default (Spring's
/// `DelegatingMessageSource`).
class DelegatingMessageSource : MessageSourceSupport, HierarchicalMessageSource
{
    private MessageSource parentMessageSource;

    /// Set the parent.
    void setParentMessageSource(MessageSource parent)
    {
        parentMessageSource = parent;
    }

    /// The parent, or null.
    MessageSource getParentMessageSource()
    {
        return parentMessageSource;
    }

    /// The parent's message, else `defaultMessage` rendered with `args`.
    string getMessage(string code, Any[] args, string defaultMessage, Locale locale)
    {
        if (parentMessageSource !is null)
            return parentMessageSource.getMessage(code, args, defaultMessage, locale);
        return defaultMessage is null ? null : renderDefaultMessage(defaultMessage, args, locale);
    }

    /// The parent's message. Throws `NoSuchMessageException` without a parent.
    string getMessage(string code, Any[] args, Locale locale)
    {
        if (parentMessageSource !is null)
            return parentMessageSource.getMessage(code, args, locale);
        throw new NoSuchMessageException(code, locale);
    }

    /// The parent's message, else the resolvable's default message. Throws `NoSuchMessageException` without either.
    string getMessage(MessageSourceResolvable resolvable, Locale locale)
    {
        if (parentMessageSource !is null)
            return parentMessageSource.getMessage(resolvable, locale);
        if (resolvable.getDefaultMessage() !is null)
            return renderDefaultMessage(resolvable.getDefaultMessage(), resolvable.getArguments(), locale);
        auto codes = resolvable.getCodes();
        throw new NoSuchMessageException(codes.length ? codes[0] : null, locale);
    }

    /// `parent` or `Empty MessageSource`.
    override string toString()
    {
        return parentMessageSource !is null ? valueOf(cast(Object) parentMessageSource) : "Empty MessageSource";
    }
}

/// The basenames and settings of a resource-based message source (Spring's `AbstractResourceBasedMessageSource`).
abstract class AbstractResourceBasedMessageSource : AbstractMessageSource
{
    private string[] basenames;
    private string defaultEncoding;
    private bool fallbackToSystemLocale = true;
    private Locale defaultLocale;
    private bool hasDefaultLocale;
    private long cacheMillis = -1;

    /// A single basename (`messages/messages` reads `messages/messages[_<locale>].properties`).
    void setBasename(string basename)
    {
        setBasenames(basename);
    }

    /// The basenames, consulted in order.
    void setBasenames(string[] basenames...)
    {
        this.basenames = null;
        addBasenames(basenames);
    }

    /// Add basenames, trimmed, without duplicates.
    void addBasenames(string[] basenames...)
    {
        foreach (basename; basenames)
        {
            Assert.hasText(basename, "Basename must not be empty");
            const trimmed = StringUtils.trimWhitespace(basename);
            bool present;
            foreach (existing; this.basenames)
                present |= existing == trimmed;
            if (!present)
                this.basenames ~= trimmed;
        }
    }

    /// The basenames.
    string[] getBasenameSet()
    {
        return basenames.dup;
    }

    /// The encoding of the properties files (UTF-8 when unset, as Java's properties bundles). Throws
    /// `UnsupportedCharsetException` for an unknown name.
    void setDefaultEncoding(string defaultEncoding)
    {
        import flint.java.nio.charset : Charset;

        if (defaultEncoding !is null)
            cast(void) Charset.forName(defaultEncoding);
        this.defaultEncoding = defaultEncoding;
    }

    /// The encoding, or null.
    protected string getDefaultEncoding()
    {
        return defaultEncoding;
    }

    /// Fall back to the default locale's files when the requested locale has none (default true).
    void setFallbackToSystemLocale(bool fallbackToSystemLocale) pure nothrow @nogc
    {
        this.fallbackToSystemLocale = fallbackToSystemLocale;
    }

    /// Whether to fall back to the system locale.
    protected bool isFallbackToSystemLocale() const pure nothrow @nogc
    {
        return fallbackToSystemLocale;
    }

    /// The locale to fall back to instead of the system's.
    void setDefaultLocale(Locale defaultLocale)
    {
        this.defaultLocale = defaultLocale;
        hasDefaultLocale = true;
    }

    /// Whether there is a locale to fall back to: a configured one, or the system's when falling back.
    protected bool hasFallbackLocale() const pure nothrow @nogc
    {
        return hasDefaultLocale || fallbackToSystemLocale;
    }

    /// The fallback locale: the configured one, else the system's (`hasFallbackLocale` says whether to use it).
    protected Locale getDefaultLocale()
    {
        return hasDefaultLocale ? defaultLocale : Locale.getDefault();
    }

    /// How long loaded files stay cached, in seconds; -1 caches forever.
    void setCacheSeconds(int cacheSeconds) pure nothrow @nogc
    {
        cacheMillis = cacheSeconds * 1000L;
    }

    /// How long loaded files stay cached, in milliseconds; -1 caches forever. Flint caches forever.
    void setCacheMillis(long cacheMillis) pure nothrow @nogc
    {
        this.cacheMillis = cacheMillis;
    }

    /// The cache duration.
    protected long getCacheMillis() const pure nothrow @nogc
    {
        return cacheMillis;
    }
}

/++
A message source reading `<basename>[_<language>[_<COUNTRY>]].properties` through the resource loader
(`classpath:` by default), with Java's `ResourceBundle` lookup: the most specific file first, then less specific
ones, then the default locale's files when falling back, then the base file. Files are read once.
+/
class ResourceBundleMessageSource : AbstractResourceBasedMessageSource
{
    import flint.core.io : DefaultResourceLoader, ResourceLoader;

    private ResourceLoader resourceLoader;
    private Properties[string] bundles; // by file name; null for a missing file

    /// A source reading from the class path.
    this()
    {
        resourceLoader = new DefaultResourceLoader;
    }

    /// Read files through `resourceLoader`.
    void setResourceLoader(ResourceLoader resourceLoader)
    {
        this.resourceLoader = resourceLoader is null ? new DefaultResourceLoader : resourceLoader;
    }

    protected override string resolveCodeWithoutArguments(string code, Locale locale)
    {
        foreach (basename; getBasenameSet())
            foreach (file; candidateFiles(basename, locale))
                if (auto bundle = loadBundle(file))
                {
                    auto msg = bundle.getProperty(code);
                    if (msg !is null)
                        return msg;
                }
        return null;
    }

    protected override string resolveCode(string code, Any[] args, Locale locale)
    {
        auto msg = resolveCodeWithoutArguments(code, locale);
        return msg is null ? null : formatMessage(msg, args, locale);
    }

    /// The files consulted for `locale`, most specific first (Java's `ResourceBundle.Control` candidates).
    protected string[] candidateFiles(string basename, Locale locale)
    {
        string[] files = localeFiles(basename, locale);
        bool anyExists;
        foreach (file; files)
            anyExists |= loadBundle(file) !is null;
        if (!anyExists && hasFallbackLocale() && getDefaultLocale() != locale)
            files ~= localeFiles(basename, getDefaultLocale());
        return files ~ (basename ~ ".properties");
    }

    private static string[] localeFiles(string basename, Locale locale)
    {
        string[] files;
        if (locale.getVariant().length)
            files ~= basename ~ "_" ~ locale.getLanguage() ~ "_" ~ locale.getCountry() ~ "_" ~ locale.getVariant()
                ~ ".properties";
        if (locale.getCountry().length)
            files ~= basename ~ "_" ~ locale.getLanguage() ~ "_" ~ locale.getCountry() ~ ".properties";
        if (locale.getLanguage().length)
            files ~= basename ~ "_" ~ locale.getLanguage() ~ ".properties";
        return files;
    }

    /// The properties of `file`, read once; null when it does not exist.
    protected Properties loadBundle(string file)
    {
        if (auto cached = file in bundles)
            return *cached;
        auto resource = resourceLoader.getResource(file);
        Properties properties;
        if (resource.exists())
        {
            properties = new Properties;
            properties.load(decode(resource.getContentAsByteArray()));
        }
        bundles[file] = properties;
        return properties;
    }

    /// The file's text: ISO-8859-1 when that is the encoding, else UTF-8.
    private string decode(ubyte[] content)
    {
        import flint.java.nio.charset : Charset, StandardCharsets;

        const encoding = getDefaultEncoding();
        if (encoding is null || Charset.forName(encoding) != StandardCharsets.ISO_8859_1)
            return cast(string) content.idup;
        import flint.engine.aot.text : utf8;

        string text;
        foreach (b; content)
            text ~= utf8(cast(dchar) b);
        return text;
    }

    /// `ResourceBundleMessageSource: basenames=[...]`.
    override string toString()
    {
        return "ResourceBundleMessageSource: basenames=[" ~ joinNames(getBasenameSet()) ~ "]";
    }

    private static string joinNames(string[] names)
    {
        string result;
        foreach (i, name; names)
            result ~= (i ? ", " : "") ~ name;
        return result;
    }
}

/// Convenient access to a `MessageSource` with a default locale (Spring's `MessageSourceAccessor`).
class MessageSourceAccessor
{
    private MessageSource messageSource;
    private Locale defaultLocale;
    private bool hasDefaultLocale;

    /// An accessor using `LocaleContextHolder`'s locale by default.
    this(MessageSource messageSource)
    {
        this.messageSource = messageSource;
    }

    /// An accessor using `defaultLocale`.
    this(MessageSource messageSource, Locale defaultLocale)
    {
        this.messageSource = messageSource;
        this.defaultLocale = defaultLocale;
        hasDefaultLocale = true;
    }

    /// The default locale: the given one, else the current fiber's.
    protected Locale getDefaultLocale()
    {
        import flint.context.i18n : LocaleContextHolder;

        return hasDefaultLocale ? defaultLocale : LocaleContextHolder.getLocale();
    }

    /// The message for `code` in the default locale.
    string getMessage(string code, Any[] args = null)
    {
        return messageSource.getMessage(code, args, getDefaultLocale());
    }

    /// The message for `code` in `locale`.
    string getMessage(string code, Any[] args, Locale locale)
    {
        return messageSource.getMessage(code, args, locale);
    }

    /// The message for `code`, else `defaultMessage`.
    string getMessage(string code, Any[] args, string defaultMessage)
    {
        return messageSource.getMessage(code, args, defaultMessage, getDefaultLocale());
    }

    /// The message for `resolvable` in the default locale.
    string getMessage(MessageSourceResolvable resolvable)
    {
        return messageSource.getMessage(resolvable, getDefaultLocale());
    }
}
