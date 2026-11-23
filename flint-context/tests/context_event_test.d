// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/context/event/ApplicationContextEventTests.java
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
 * spring-context/src/test/java/org/springframework/context/event/ApplicationContextEventTests.java and
 * spring-context/src/test/java/org/springframework/context/testfixture/beans/{BeanThatListens,
 * BeanThatBroadcasts}.java.
 */

/++
`ApplicationContextEventTests`. `StaticApplicationContext` is a `GenericApplicationContext` here; Mockito listeners
are recording listeners; a Java lambda listener is an anonymous `ApplicationListener!E` subclass (rule R13). D
templates are reified, so `GenericTestEvent!string` and `GenericTestEvent!long` are distinct event classes and the
generic-event tests need no `ResolvableType`.

Skipped Java tests (37 in the class):
- multicastGenericEventWildcardSubType, multicastSmartGenericTypeGenericListener,
  multicastSmartGenericWrongTypeGenericListener: wildcard types and `ResolvableTypeProvider`.
- simpleApplicationEventMulticasterWithTaskExecutor,
  simpleApplicationEventMulticasterWithTaskExecutorAndNonAsyncListener: the multicaster has no task executor.
- orderedListenersWithAnnotation: `@Order` on a listener class needs its descriptor, which the multicaster lacks.
- proxiedListeners, proxiedListenersMixedWithTargetListeners, eventForSelfInjectedProxiedListenerFiredOnlyOnce:
  AOP `ProxyFactory` and aspects.
- eventPublicationInterceptorWithEventClass, eventPublicationInterceptorWithEventFactory,
  eventPublicationInterceptorWithMethodFailure, eventPublicationInterceptorWithCustomFailure:
  `EventPublicationInterceptor` (AOP) is not ported.
- listenersInApplicationContext, nonSingletonListenerInApplicationContext, beanPostProcessorPublishesEvents,
  initMethodPublishesAsyncEventBeforeListenerInitialized: listener beans resolved by name per event (lazy and
  prototype listeners, listeners not yet created) need the event type before instantiation; Flint registers a
  listener when its singleton is created.
- listenersInApplicationContextWithNestedChild, innerBeanAsListener: a nested context bean with an init method,
  FactoryBean listeners and inner beans.
- lambdaAsListenerWithJava8StyleClassCastMessage, lambdaAsListenerWithJava9StyleClassCastMessage: JVM lambda type
  erasure.
- initMethodPublishesAsyncEvent: publishing from another thread.
+/
module flint.context.context_event_test;

import flint.beans.factory : InitializingBean;
import flint.context : ApplicationContext, ApplicationContextAware, ApplicationEvent, ApplicationEventPublisher,
    ApplicationEventPublisherAware, ApplicationListener, GenericApplicationListener, PayloadApplicationEvent;
import flint.context.event : ContextClosedEvent, ContextRefreshedEvent, SimpleApplicationEventMulticaster;
import flint.context.support : GenericApplicationContext;
import flint.core : Ordered;
import flint.engine.aot.bean : BeanDefinition, BeanFactory;
import flint.engine.aot.name : typeNameOf;
import flint.engine.aot.registry : AotRegistry;
import flint.java.lang : RuntimeException;
import std.exception : collectException;

@safe:

private class MyEvent : ApplicationEvent
{
    this(Object source)
    {
        super(source);
    }
}

private class MyOtherEvent : ApplicationEvent
{
    this(Object source)
    {
        super(source);
    }
}

private class GenericTestEvent(T) : ApplicationEvent
{
    T payload;

    this(Object source, T payload)
    {
        super(source);
        this.payload = payload;
    }
}

private final class StringEvent : GenericTestEvent!string
{
    this(Object source, string payload)
    {
        super(source, payload);
    }
}

private final class LongEvent : GenericTestEvent!long
{
    this(Object source, long payload)
    {
        super(source, payload);
    }
}

/// A Mockito `ApplicationListener<E>` mock: records what it receives, and optionally throws.
private final class RecordingListener(E) : ApplicationListener!E
{
    ApplicationEvent[] received;
    Exception failure;

    override void onApplicationEvent(E event)
    {
        received ~= event;
        if (failure !is null)
            throw failure;
    }
}

private alias StringEventListener = RecordingListener!(GenericTestEvent!string);

private void multicastEvent(L)(bool match, ApplicationEvent event)
{
    auto listener = new L;
    auto smc = new SimpleApplicationEventMulticaster;
    smc.addApplicationListener(listener);
    smc.multicastEvent(event);
    assert(listener.received.length == (match ? 1 : 0));
    assert(!match || listener.received[0] is event);
}

unittest
{
    // multicastSimpleEvent
    multicastEvent!(RecordingListener!ApplicationEvent)(true, new ContextRefreshedEvent(new GenericApplicationContext));
    multicastEvent!(RecordingListener!ApplicationEvent)(true, new ContextClosedEvent(new GenericApplicationContext));
}

unittest
{
    // multicastGenericEvent
    multicastEvent!StringEventListener(true, new GenericTestEvent!string(null, "test"));
}

unittest
{
    // multicastGenericEventWrongType
    multicastEvent!StringEventListener(false, new GenericTestEvent!long(null, 123L));
}

unittest
{
    // multicastConcreteTypeGenericListener
    multicastEvent!StringEventListener(true, new StringEvent(null, "test"));
}

unittest
{
    // multicastConcreteWrongTypeGenericListener
    multicastEvent!StringEventListener(false, new LongEvent(null, 123L));
}

unittest
{
    // simpleApplicationEventMulticasterWithException
    auto listener = new RecordingListener!ApplicationEvent;
    auto evt = new ContextClosedEvent(new GenericApplicationContext);
    auto smc = new SimpleApplicationEventMulticaster;
    smc.addApplicationListener(listener);
    auto thrown = new RuntimeException();
    listener.failure = thrown;
    assert(collectException!RuntimeException(smc.multicastEvent(evt)) is thrown);
}

unittest
{
    // simpleApplicationEventMulticasterWithErrorHandler
    auto listener = new RecordingListener!ApplicationEvent;
    auto evt = new ContextClosedEvent(new GenericApplicationContext);
    auto smc = new SimpleApplicationEventMulticaster;
    smc.setErrorHandler((Exception) {}); // TaskUtils.LOG_AND_SUPPRESS_ERROR_HANDLER
    smc.addApplicationListener(listener);
    listener.failure = new RuntimeException();
    smc.multicastEvent(evt);
    assert(listener.received.length == 1);
}

private final class MyOrderedListener1 : ApplicationListener!ApplicationEvent, Ordered
{
    ApplicationEvent[] seenEvents;

    override void onApplicationEvent(ApplicationEvent event)
    {
        seenEvents ~= event;
    }

    int getOrder()
    {
        return 0;
    }
}

private final class MyOrderedListener2 : ApplicationListener!MyEvent, Ordered
{
    private MyOrderedListener1 otherListener;

    this(MyOrderedListener1 otherListener) pure nothrow @nogc
    {
        this.otherListener = otherListener;
    }

    override void onApplicationEvent(MyEvent event)
    {
        bool seen;
        foreach (other; otherListener.seenEvents)
            seen |= other is event;
        assert(seen);
    }

    int getOrder()
    {
        return 1;
    }
}

unittest
{
    // orderedListeners
    auto listener1 = new MyOrderedListener1;
    auto listener2 = new MyOrderedListener2(listener1);
    auto smc = new SimpleApplicationEventMulticaster;
    smc.addApplicationListener(listener2);
    smc.addApplicationListener(listener1);
    smc.multicastEvent(new MyEvent(null));
    smc.multicastEvent(new MyOtherEvent(null));
    assert(listener1.seenEvents.length == 2);
}

private final class MyPayloadListener : ApplicationListener!PayloadApplicationEvent
{
    string[] seenPayloads;

    override void onApplicationEvent(PayloadApplicationEvent event)
    {
        seenPayloads ~= event.getPayload!string();
    }
}

unittest
{
    // listenersInApplicationContextWithPayloadEvents
    // (The multicaster's retriever cache is not ported.)
    auto context = new GenericApplicationContext;
    context.registerBean!MyPayloadListener("listener");
    context.refresh();
    const listener = context.getBean!MyPayloadListener("listener");
    context.publishEvent("event1");
    context.publishEvent("event2");
    context.publishEvent("event3");
    context.publishEvent("event4");
    assert(listener.seenPayloads == ["event1", "event2", "event3", "event4"]);
    context.close();
}

// ---- BeanThatBroadcasts and BeanThatListens, with their generated factories

private final class BeanThatBroadcasts : ApplicationContextAware
{
    ApplicationContext applicationContext;
    int receivedCount;

    void setApplicationContext(ApplicationContext applicationContext)
    {
        this.applicationContext = applicationContext;
        if (contains(applicationContext.getDisplayName(), "listener"))
            applicationContext.getBean("listener");
    }

    private static bool contains(string text, string part) pure nothrow @nogc
    {
        foreach (i; 0 .. text.length)
            if (text[i .. $].length >= part.length && text[i .. i + part.length] == part)
                return true;
        return false;
    }
}

private final class BeanThatListens : ApplicationListener!ApplicationEvent
{
    private BeanThatBroadcasts beanThatBroadcasts;
    private int eventCount;

    this() pure nothrow @nogc
    {
    }

    this(BeanThatBroadcasts beanThatBroadcasts)
    {
        import flint.java.lang : IllegalStateException;

        this.beanThatBroadcasts = beanThatBroadcasts;
        auto beans = beanThatBroadcasts.applicationContext.getBeansOfType!BeanThatListens();
        if (!beans.isEmpty())
            throw new IllegalStateException("Shouldn't have found any BeanThatListens instances");
    }

    override void onApplicationEvent(ApplicationEvent)
    {
        eventCount++;
        if (beanThatBroadcasts !is null)
            beanThatBroadcasts.receivedCount++;
    }

    int getEventCount() const pure nothrow @nogc
    {
        return eventCount;
    }
}

private Object createBroadcaster(BeanFactory)
{
    return new BeanThatBroadcasts;
}

private Object createListener(BeanFactory factory)
{
    return new BeanThatListens(cast(BeanThatBroadcasts) factory.getBean("broadcaster"));
}

private void populateBroadcasting(scope AotRegistry registry)
{
    registry.begin(1, 1);
    BeanDefinition broadcaster;
    broadcaster.name = "broadcaster";
    broadcaster.type = typeNameOf!BeanThatBroadcasts;
    broadcaster.types = [typeNameOf!BeanThatBroadcasts, typeNameOf!ApplicationContextAware];
    broadcaster.create = &createBroadcaster;
    registry.bean(broadcaster);
    BeanDefinition listener;
    listener.name = "listener";
    listener.type = typeNameOf!BeanThatListens;
    listener.types = [typeNameOf!BeanThatListens, typeNameOf!GenericApplicationListener];
    listener.create = &createListener;
    registry.bean(listener);
    registry.end();
}

unittest
{
    // listenerAndBroadcasterWithCircularReference
    auto context = new GenericApplicationContext;
    context.loadAotRegistry(&populateBroadcasting);
    context.refresh();
    const broadcaster = context.getBean!BeanThatBroadcasts("broadcaster");
    context.publishEvent(new MyEvent(cast(Object) context));
    assert(broadcaster.receivedCount == 2, "The event was not received by the listener");
    context.close();
}

/// Java's `(MyEvent event) -> seenEvents.add(event)` and `seenEvents::add`.
private final class MyEventRecorder : ApplicationListener!MyEvent
{
    MyEvent[] seenEvents;

    override void onApplicationEvent(MyEvent event)
    {
        seenEvents ~= event;
    }
}

unittest
{
    // anonymousClassAsListener
    auto context = new GenericApplicationContext;
    auto listener = new MyEventRecorder;
    context.addApplicationListener(listener);
    context.refresh();
    auto event1 = new MyEvent(cast(Object) context);
    context.publishEvent(event1);
    context.publishEvent(new MyOtherEvent(cast(Object) context));
    auto event2 = new MyEvent(cast(Object) context);
    context.publishEvent(event2);
    assert(listener.seenEvents == [event1, event2]);
    context.close();
}

unittest
{
    // lambdaAsListener
    auto context = new GenericApplicationContext;
    auto listener = new MyEventRecorder;
    context.addApplicationListener(listener);
    context.refresh();
    auto event1 = new MyEvent(cast(Object) context);
    context.publishEvent(event1);
    context.publishEvent(new MyOtherEvent(cast(Object) context));
    auto event2 = new MyEvent(cast(Object) context);
    context.publishEvent(event2);
    assert(listener.seenEvents == [event1, event2]);
    context.close();
}

unittest
{
    // lambdaAsListenerWithErrorHandler
    auto context = new GenericApplicationContext;
    auto multicaster = new SimpleApplicationEventMulticaster;
    multicaster.setErrorHandler((Exception e) { throw e; }); // ReflectionUtils::rethrowRuntimeException
    context.getBeanFactory().registerSingleton("applicationEventMulticaster", multicaster);
    auto listener = new MyEventRecorder;
    context.addApplicationListener(listener);
    context.refresh();
    auto event1 = new MyEvent(cast(Object) context);
    context.publishEvent(event1);
    context.publishEvent(new MyOtherEvent(cast(Object) context));
    auto event2 = new MyEvent(cast(Object) context);
    context.publishEvent(event2);
    assert(listener.seenEvents == [event1, event2]);
    context.close();
}

unittest
{
    // addListenerWithConsumer
    ContextRefreshedEvent[] captured;
    auto context = new GenericApplicationContext;
    context.addApplicationListener(
            GenericApplicationListener.forEventType!ContextRefreshedEvent((ContextRefreshedEvent event) {
            captured ~= event;
        }));
    context.refresh();
    assert(captured.length == 1);
    assert(captured[0].getApplicationContext() is context);
}

private final class EventPublishingInitMethod : ApplicationEventPublisherAware, InitializingBean
{
    private ApplicationEventPublisher publisher;

    void setApplicationEventPublisher(ApplicationEventPublisher applicationEventPublisher)
    {
        publisher = applicationEventPublisher;
    }

    void afterPropertiesSet()
    {
        publisher.publishEvent(new MyEvent(this));
    }
}

unittest
{
    // initMethodPublishesEvent
    // gh-25799 (the Java test's StaticMessageSource bean plays no part here and is left out).
    auto context = new GenericApplicationContext;
    context.registerBean!BeanThatListens("listener");
    context.registerBean!EventPublishingInitMethod("initMethod");
    context.refresh();
    context.publishEvent(new MyEvent(null));
    auto listener = context.getBean!BeanThatListens();
    assert(listener.getEventCount() == 3);
    context.close();
}
