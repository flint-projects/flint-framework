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
 * spring-context/src/main/java/org/springframework/context/{ApplicationContext,ConfigurableApplicationContext,
 * ApplicationEvent,ApplicationListener,ApplicationEventPublisher,ApplicationContextAware,EnvironmentAware,
 * ApplicationEventPublisherAware,ResourceLoaderAware,Lifecycle,SmartLifecycle,Phased,LifecycleProcessor,
 * ApplicationContextException}.java. ApplicationListener is an abstract class whose erased dispatch knows its event
 * type (deviation D-23); SmartLifecycle's default methods are mixed in (rule R3).
 */

/++
`org.springframework.context`: the application context API, events and lifecycle.
+/
module flint.context;

import flint.beans : FatalBeanException;
import flint.beans.factory : Aware, HierarchicalBeanFactory, ListableBeanFactory;
import flint.beans.factory.config : ConfigurableListableBeanFactory;
import flint.core.env : ConfigurableEnvironment, Environment, EnvironmentCapable;
import flint.core.io : ResourceLoader;
import flint.engine.aot.any : Any;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : Runnable;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Events

/// Class to be extended by all application events.
abstract class ApplicationEvent
{
    private Object source;
    private long timestamp;

    /// An event published by `source`, stamped with the current time.
    this(Object source)
    {
        import std.datetime.systime : Clock;

        this.source = source;
        timestamp = Clock.currTime().toUnixTime() * 1000L + Clock.currTime().fracSecs.total!"msecs";
    }

    /// The object on which the event initially occurred.
    Object getSource() pure nothrow @nogc
    {
        return source;
    }

    /// When the event occurred, in milliseconds since the epoch.
    final long getTimestamp() const pure nothrow @nogc
    {
        return timestamp;
    }

    /// `ClassName[source=...]`.
    override string toString()
    {
        import flint.engine.aot.objects : objectToString;

        return typeid(this).name ~ "[source=" ~ objectToString(source) ~ "]";
    }
}

/// An `ApplicationEvent` carrying an arbitrary payload, published by `publishEvent(payload)`.
class PayloadApplicationEvent : ApplicationEvent
{
    private Any payload;

    /// A payload event from `source`.
    this(Object source, Any payload)
    {
        super(source);
        this.payload = payload;
    }

    /// The payload.
    Any getPayload() pure nothrow @nogc
    {
        return payload;
    }

    /// The payload as a `T`.
    T getPayload(T)()
    {
        return payload.get!T;
    }
}

/// The erased dispatch every `ApplicationListener!E` provides: the multicaster's view of a listener.
interface GenericApplicationListener
{
    /// Whether this listener accepts `event`.
    bool supportsEvent(Object event);
    /// Deliver `event`; called only when `supportsEvent` returned true.
    void dispatchEvent(Object event);
    /// The listener's order (`Ordered.LOWEST_PRECEDENCE` by default).
    int getListenerOrder();
}

/++
Interface to be implemented by application event listeners: an abstract class here, so it can dispatch on its event
type `E` without reflection (deviation D-23). `E` is an `ApplicationEvent` subclass.
+/
abstract class ApplicationListener(E) : GenericApplicationListener
{
    /// Handle an application event.
    abstract void onApplicationEvent(E event);

    /// Whether the listener supports asynchronous execution (Spring's default: true).
    bool supportsAsyncExecution()
    {
        return true;
    }

    /// Whether `event` is an `E`.
    final bool supportsEvent(Object event)
    {
        return cast(E) event !is null;
    }

    /// Deliver `event` as an `E`.
    final void dispatchEvent(Object event)
    {
        onApplicationEvent(cast(E) event);
    }

    /// `getOrder()` when the listener is `Ordered`, else `LOWEST_PRECEDENCE`.
    int getListenerOrder()
    {
        if (auto ordered = cast(imported!"flint.core".Ordered) this)
            return ordered.getOrder();
        return int.max;
    }

    /// A listener for payloads of type `T`, calling `consumer` (Java's `ApplicationListener.forPayload`).
    static GenericApplicationListener forPayload(T)(void delegate(T) @safe consumer)
    {
        return new PayloadListener!T(consumer);
    }
}

private final class PayloadListener(T) : GenericApplicationListener
{
    private void delegate(T) @safe consumer;

    this(void delegate(T) @safe consumer) pure nothrow @nogc
    {
        this.consumer = consumer;
    }

    bool supportsEvent(Object event)
    {
        auto payload = cast(PayloadApplicationEvent) event;
        return payload !is null && payload.getPayload().holds!T;
    }

    void dispatchEvent(Object event)
    {
        consumer((cast(PayloadApplicationEvent) event).getPayload!T());
    }

    int getListenerOrder()
    {
        return int.max;
    }
}

/++
Interface that encapsulates event publication. Java's overloads are `final` over the erased `publishEventErased`
(deviation D-22).
+/
interface ApplicationEventPublisher
{
    /// The erased primitive: deliver `event` (an `ApplicationEvent`, or a `PayloadApplicationEvent`).
    void publishEventErased(ApplicationEvent event);

    /// Notify every matching listener of `event`.
    final void publishEvent(ApplicationEvent event)
    {
        publishEventErased(event);
    }

    /// Publish `payload` wrapped in a `PayloadApplicationEvent` (Java's `publishEvent(Object)`).
    void publishEvent(T)(T payload) if (!is(T : ApplicationEvent))
    {
        publishEventErased(new PayloadApplicationEvent(cast(Object) this, Any.of(payload)));
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Contexts

/// Exception thrown during application context initialization.
class ApplicationContextException : FatalBeanException
{
    /// `msg`, and optionally a `cause`.
    this(string msg, Throwable cause = null) pure nothrow
    {
        super(msg, cause);
    }
}

/// Central interface to provide configuration for an application: beans, environment, events and resources.
interface ApplicationContext : EnvironmentCapable, ListableBeanFactory, HierarchicalBeanFactory,
    ApplicationEventPublisher, ResourceLoader
{
    /// The unique id of this context.
    string getId();
    /// The name of the deployed application.
    string getApplicationName();
    /// A friendly name for this context.
    string getDisplayName();
    /// When this context was first loaded, in milliseconds since the epoch.
    long getStartupDate();
    /// The parent context, or null.
    ApplicationContext getParent();
}

/// SPI interface implemented by most application contexts.
interface ConfigurableApplicationContext : ApplicationContext, Lifecycle, AutoCloseableContext
{
    /// The name of the `ConversionService` bean in the factory.
    enum CONVERSION_SERVICE_BEAN_NAME = "conversionService";
    /// The name of the `Environment` bean in the factory.
    enum ENVIRONMENT_BEAN_NAME = "environment";
    /// The name of the system properties bean in the factory.
    enum SYSTEM_PROPERTIES_BEAN_NAME = "systemProperties";
    /// The name of the system environment bean in the factory.
    enum SYSTEM_ENVIRONMENT_BEAN_NAME = "systemEnvironment";
    /// The name of the shutdown hook thread in Java.
    enum SHUTDOWN_HOOK_THREAD_NAME = "FlintContextShutdownHook";

    /// Set the unique id.
    void setId(string id);
    /// Set the parent context.
    void setParent(ApplicationContext parent);
    /// Set the environment.
    void setEnvironment(ConfigurableEnvironment environment);
    /// The environment, configurable.
    ConfigurableEnvironment getConfigurableEnvironment();
    /// Add a factory post-processor applied on refresh.
    void addBeanFactoryPostProcessor(imported!"flint.beans.factory.config".BeanFactoryPostProcessor postProcessor);
    /// Add a listener notified of context events.
    void addApplicationListener(GenericApplicationListener listener);
    /// Load or refresh the configuration and create every non-lazy singleton.
    void refresh();
    /// Close the context when the process is asked to terminate.
    void registerShutdownHook();
    /// Close the context: destroy every singleton and release resources.
    void close();
    /// Whether the context is refreshed and not yet closed.
    bool isActive();
    /// The internal bean factory. Throws `IllegalStateException` when the context is not active.
    ConfigurableListableBeanFactory getBeanFactory();
}

/// Java's `Closeable` for contexts (`try (var ctx = ...)`): `scope (exit) ctx.close();` in D.
interface AutoCloseableContext
{
    /// Close.
    void close();
}

// ---------------------------------------------------------------------------------------------------------------
// Aware callbacks

/// A bean that wants to know its `ApplicationContext`.
interface ApplicationContextAware : Aware
{
    /// Called after population, before initialization callbacks.
    void setApplicationContext(ApplicationContext applicationContext);
}

/// A bean that wants to know the `Environment`.
interface EnvironmentAware : Aware
{
    /// Called after population, before initialization callbacks.
    void setEnvironment(Environment environment);
}

/// A bean that wants to publish events.
interface ApplicationEventPublisherAware : Aware
{
    /// Called after population, before initialization callbacks.
    void setApplicationEventPublisher(ApplicationEventPublisher applicationEventPublisher);
}

/// A bean that wants to load resources.
interface ResourceLoaderAware : Aware
{
    /// Called after population, before initialization callbacks.
    void setResourceLoader(ResourceLoader resourceLoader);
}

// ---------------------------------------------------------------------------------------------------------------
// Lifecycle

/// A common interface defining methods for start/stop lifecycle control.
interface Lifecycle
{
    /// Start this component.
    void start();
    /// Stop this component.
    void stop();
    /// Whether this component is running.
    bool isRunning();
}

/// An object that may participate in a phased process such as lifecycle management.
interface Phased
{
    /// The phase value: lower phases start earlier and stop later.
    int getPhase();
}

/++
An extension of `Lifecycle` for objects that start on context refresh and stop in phases. Mix in
`SmartLifecycle.Defaults` for Java's default methods (rule R3): auto-startup, `stop(callback)` and the default phase.
+/
interface SmartLifecycle : Lifecycle, Phased
{
    /// The default phase: last to start, first to stop.
    enum int DEFAULT_PHASE = int.max;

    /// Whether to start automatically on context refresh.
    bool isAutoStartup();
    /// Stop, then call `callback` (synchronously in Flint unless the component hands it off).
    void stop(Runnable callback);

    /// Java's default methods.
    mixin template Defaults()
    {
        /// `true`.
        bool isAutoStartup()
        {
            return true;
        }

        /// `stop()`, then `callback.run()`.
        void stop(imported!"flint.java.lang".Runnable callback)
        {
            (cast(imported!"flint.context".Lifecycle) this).stop();
            callback.run();
        }

        /// `DEFAULT_PHASE`.
        int getPhase()
        {
            return imported!"flint.context".SmartLifecycle.DEFAULT_PHASE;
        }
    }
}

/// Strategy interface for processing `Lifecycle` beans within the context.
interface LifecycleProcessor : Lifecycle
{
    /// Notification of context refresh: start auto-startup components.
    void onRefresh();
    /// Notification of context close: stop components.
    void onClose();
}
