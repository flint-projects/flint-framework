// Ported from spring-framework v7.1.0: spring-context/src/main/java/org/springframework/context/event
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
 * spring-context/src/main/java/org/springframework/context/event/{EventListener,ApplicationContextEvent,
 * ContextRefreshedEvent,ContextStartedEvent,ContextStoppedEvent,ContextClosedEvent,ApplicationEventMulticaster,
 * AbstractApplicationEventMulticaster,SimpleApplicationEventMulticaster,ApplicationListenerMethodAdapter}.java.
 * @EventListener methods are dispatched through Flint AOT's EventListenerSpec tables; event types match by the
 * runtime class chain (TypeInfo_Class), not by reflection on members.
 */

/++
`org.springframework.context.event`: context events, `@EventListener` and the event multicaster.
+/
module flint.context.event;

import flint.context : ApplicationContext, ApplicationEvent, GenericApplicationListener, PayloadApplicationEvent;
import flint.core.annotation : AliasFor, ClassRef;
import flint.engine.aot.any : Any;
import flint.engine.aot.event : EventListenerSpec;
import flint.engine.aot.expression : EvaluationContext;
import flint.engine.aot.name : canonicalTypeName;
import flint.java.lang : IllegalStateException;
import flint.java.util : stableSort;

@safe:

/++
Marks a method as a listener for application events. The event type is the method's parameter type, or the
`classes` listed. `condition` is a SpEL expression (compiled by Flint AOT, contract section 9).
+/
struct EventListener
{
    /// Alias for `classes`.
    @AliasFor("classes") ClassRef[] value;
    /// The event classes this listener handles.
    @AliasFor("value") ClassRef[] classes;
    /// A SpEL condition; empty for unconditional handling.
    string condition;
    /// Whether the listener is invoked by default.
    bool defaultExecution = true;
    /// An optional identifier for the listener.
    string id;
}

/// Base class for events raised for an `ApplicationContext`.
abstract class ApplicationContextEvent : ApplicationEvent
{
    /// An event raised by `source`.
    this(ApplicationContext source)
    {
        super(cast(Object) source);
    }

    /// The context that raised the event.
    final ApplicationContext getApplicationContext()
    {
        return cast(ApplicationContext) getSource();
    }
}

/// Raised when an `ApplicationContext` gets initialized or refreshed.
class ContextRefreshedEvent : ApplicationContextEvent
{
    /// An event raised by `source`.
    this(ApplicationContext source)
    {
        super(source);
    }
}

/// Raised when an `ApplicationContext` gets started.
class ContextStartedEvent : ApplicationContextEvent
{
    /// An event raised by `source`.
    this(ApplicationContext source)
    {
        super(source);
    }
}

/// Raised when an `ApplicationContext` gets stopped.
class ContextStoppedEvent : ApplicationContextEvent
{
    /// An event raised by `source`.
    this(ApplicationContext source)
    {
        super(source);
    }
}

/// Raised when an `ApplicationContext` gets closed.
class ContextClosedEvent : ApplicationContextEvent
{
    /// An event raised by `source`.
    this(ApplicationContext source)
    {
        super(source);
    }
}

/// Interface for objects that manage listeners and publish events to them.
interface ApplicationEventMulticaster
{
    /// Add a listener.
    void addApplicationListener(GenericApplicationListener listener);
    /// Remove a listener.
    void removeApplicationListener(GenericApplicationListener listener);
    /// Remove every listener.
    void removeAllListeners();
    /// Deliver `event` to every listener that supports it, in order.
    void multicastEvent(ApplicationEvent event);
}

/// The `ApplicationEventMulticaster` that calls listeners in the publishing fiber, ordered by their order values.
class SimpleApplicationEventMulticaster : ApplicationEventMulticaster
{
    private GenericApplicationListener[] listeners;
    private void delegate(Exception) @safe errorHandler;

    /// Add a listener.
    void addApplicationListener(GenericApplicationListener listener)
    {
        removeApplicationListener(listener);
        listeners ~= listener;
    }

    /// Remove a listener.
    void removeApplicationListener(GenericApplicationListener listener)
    {
        GenericApplicationListener[] kept;
        foreach (existing; listeners)
            if (cast(Object) existing !is cast(Object) listener) // one object may reach the interface by two paths
                kept ~= existing;
        listeners = kept;
    }

    /// Remove every listener.
    void removeAllListeners()
    {
        listeners = null;
    }

    /// Handle listener exceptions with `handler` instead of propagating them.
    void setErrorHandler(void delegate(Exception) @safe handler)
    {
        errorHandler = handler;
    }

    /// The listeners supporting `event`, ordered (stable) by their order values.
    GenericApplicationListener[] getApplicationListeners(ApplicationEvent event)
    {
        GenericApplicationListener[] matching;
        foreach (listener; listeners)
            if (listener.supportsEvent(event))
                matching ~= listener;
        stableSort(matching, (GenericApplicationListener a, GenericApplicationListener b) {
            const x = a.getListenerOrder(), y = b.getListenerOrder();
            return x < y ? -1 : (x > y ? 1 : 0);
        });
        return matching;
    }

    /// Deliver `event`.
    void multicastEvent(ApplicationEvent event)
    {
        foreach (listener; getApplicationListeners(event))
        {
            if (errorHandler is null)
            {
                listener.dispatchEvent(event);
                continue;
            }
            try
                listener.dispatchEvent(event);
            catch (Exception e)
                errorHandler(e);
        }
    }
}

/++
An `@EventListener` method as Flint AOT describes it, bound to its bean: Spring's
`ApplicationListenerMethodAdapter`. A payload event matches when the payload's type matches.
+/
class ApplicationListenerMethodAdapter : GenericApplicationListener
{
    private EventListenerSpec spec;
    private Object delegate() @safe beanSupplier;
    private void delegate(ApplicationEvent) @safe resultPublisher;
    private Object delegate(string) @safe beanResolver;
    private string delegate(string) @safe placeholderResolver;

    /// An adapter for `spec`, resolving its bean with `beanSupplier` and publishing non-null results through
    /// `resultPublisher`. A condition's `@name` beans and `${...}` placeholders resolve through `beanResolver` and
    /// `placeholderResolver`.
    this(EventListenerSpec spec, Object delegate() @safe beanSupplier,
            void delegate(ApplicationEvent) @safe resultPublisher = null, Object delegate(
                string) @safe beanResolver = null, string delegate(string) @safe placeholderResolver = null)
    {
        if (spec.condition.length && spec.conditionExpression is null)
            throw new IllegalStateException("@EventListener condition '" ~ spec.condition ~ "' on bean '"
                    ~ spec.bean ~ "' was not compiled (generated before AOT contract 3); rebuild with flint build");
        this.spec = spec;
        this.beanSupplier = beanSupplier;
        this.resultPublisher = resultPublisher;
        this.beanResolver = beanResolver;
        this.placeholderResolver = placeholderResolver;
    }

    /// Whether `event` (or its payload) is an instance of the listener's event type.
    bool supportsEvent(Object event)
    {
        if (isInstanceOf(event, spec.eventType))
            return true;
        if (auto payload = cast(PayloadApplicationEvent) event)
        {
            auto value = payload.getPayload();
            if (value.typeName == spec.eventType)
                return true;
            if (auto object = value.asObject())
                return isInstanceOf(object, spec.eventType);
        }
        return false;
    }

    /// Call the method with the event, or with the payload of a payload event of another type.
    void dispatchEvent(Object event)
    {
        Any argument;
        auto payload = cast(PayloadApplicationEvent) event;
        if (payload !is null && !isInstanceOf(event, spec.eventType))
            argument = payload.getPayload();
        else
            argument = Any.of(event);
        if (!shouldHandle(event, argument))
            return;
        auto bean = beanSupplier();
        if (bean is null)
            return; // the listener bean's factory returned null: nothing to call, as in Spring
        spec.invoke(bean, argument);
    }

    /// Whether the compiled condition, if any, holds for `event` (Spring's `shouldHandle`).
    private bool shouldHandle(Object event, Any argument)
    {
        import flint.engine.aot.expression : isTrue;

        if (spec.conditionExpression is null)
            return true;
        return isTrue(spec.conditionExpression(new EventEvaluationContext(event, argument,
                beanResolver, placeholderResolver)));
    }

    /// The `@Order` of the method.
    int getListenerOrder()
    {
        return spec.order;
    }

    /// The bean declaring the method.
    string getBeanName() const pure nothrow @nogc
    {
        return spec.bean;
    }
}

/// The evaluation context of an `@EventListener` condition: the listener's argument, and `event` and `args` on
/// the root (Spring's `EventExpressionRootObject`).
private final class EventEvaluationContext : EvaluationContext
{
    private Object event;
    private Any argument_;
    private Object delegate(string) @safe beanResolver;
    private string delegate(string) @safe placeholderResolver;

    this(Object event, Any argument, Object delegate(string) @safe beanResolver,
            string delegate(string) @safe placeholderResolver)
    {
        this.event = event;
        this.argument_ = argument;
        this.beanResolver = beanResolver;
        this.placeholderResolver = placeholderResolver;
    }

    Any argument(size_t index)
    {
        return index == 0 ? argument_ : Any.init;
    }

    Any result()
    {
        return Any.init;
    }

    string methodName()
    {
        return null;
    }

    Any rootFunction(string name, scope Any[])
    {
        throw new IllegalStateException("@EventListener conditions have no root function '" ~ name ~ "'");
    }

    Any rootProperty(string name)
    {
        if (name == "event")
            return Any.of(event);
        if (name == "args")
            return Any.of([argument_]);
        throw new IllegalStateException("@EventListener conditions have no root property '" ~ name ~ "'");
    }

    Object bean(string name)
    {
        if (beanResolver is null)
            throw new IllegalStateException("No bean resolver for @" ~ name);
        return beanResolver(name);
    }

    string placeholder(string text)
    {
        return placeholderResolver is null ? text : placeholderResolver(text);
    }
}

/// Whether `object`'s class is `typeName` or derives from or implements it (by canonical names).
bool isInstanceOf(Object object, string typeName)
{
    if (object is null)
        return false;
    for (auto info = typeid(object); info !is null; info = info.base)
    {
        if (canonicalTypeName(info.name) == typeName)
            return true;
        if (implementsInterface(info, typeName))
            return true;
    }
    return false;
}

private bool implementsInterface(const TypeInfo_Class info, string typeName)
{
    foreach (iface; info.interfaces)
    {
        if (canonicalTypeName(iface.classinfo.name) == typeName)
            return true;
        if (implementsInterface(iface.classinfo, typeName))
            return true;
    }
    return false;
}
