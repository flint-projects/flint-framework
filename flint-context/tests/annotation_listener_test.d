// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/context/event/AnnotationDrivenEventListenerTests.java
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
 * spring-context/src/test/java/org/springframework/context/event/AnnotationDrivenEventListenerTests.java and
 * spring-context/src/test/java/org/springframework/context/event/test/{EventCollector,TestEvent,
 * IdentifiableApplicationEvent,AbstractIdentifiable,GenericEventPojo}.java.
 */

/++
`AnnotationDrivenEventListenerTests`. Each `@Component` listener is the definition Flint AOT generates for it (its
`@Autowired EventCollector` set by the generated `initialize`), and each `@EventListener` method is an
`EventListenerSpec`; `@EventListener({Boolean.class, Integer.class})` is one spec per class, a meta-annotation is
resolved by the generator, and `@Order` is the spec's order.

Skipped Java tests (35 in the class):
- simpleEventXmlConfig: XML configuration.
- methodSignatureNoEvent: an `@EventListener` method with two parameters is rejected by Flint AOT at build time.
- completableFutureReply, monoReply, fluxReply: asynchronous results.
- eventListenerWorksWithSimpleInterfaceProxy, eventListenerWorksWithAnnotatedInterfaceProxy,
  eventListenerWorksWithCglibProxy, privateMethodOnCglibProxyFails: AOP and scoped proxies.
- eventListenerWorksWithCustomScope: custom scopes are not supported.
- asyncProcessingApplied, asyncProcessingAppliedWithInterfaceProxy, asyncProcessingAppliedWithScopedProxy,
  exceptionNotPropagatedWithAsync: `@Async` on a task executor.
- conditionMatchWithProxy: AOP proxies (MethodValidationPostProcessor).

conditionMatch and conditionDoesNotMatch use the conditions as Flint AOT compiles them (contract 3); the
timestamp is taken one millisecond early, because Flint's event clock has millisecond resolution and Java's test
relies on the event being created strictly later.

simpleEventJavaConfig and metaAnnotationIsDiscovered end in Java by removing listeners by id
(`removeApplicationListeners` and `SmartApplicationListener.getListenerId`), which Flint's multicaster does not
have; those assertions are left out.
+/
module flint.context.annotation_listener_test;

import flint.context : ApplicationContext, ApplicationEvent, PayloadApplicationEvent;
import flint.context.annotation : AnnotationConfigApplicationContext;
import flint.context.event : ApplicationContextEvent, ContextClosedEvent, ContextRefreshedEvent,
    ContextStartedEvent, ContextStoppedEvent;
import flint.engine.aot.any : Any;
import flint.engine.aot.bean : BeanDefinition, BeanFactory;
import flint.engine.aot.event : EventListenerSpec;
import flint.engine.aot.expression : CompiledExpression, EvaluationContext;
import flint.engine.aot.name : typeNameOf;
import flint.engine.aot.registry : AotRegistry;
import flint.java.lang : IllegalStateException;
import std.exception : collectException;

@safe:

// ---- the event test fixtures

private interface Identifiable
{
    string getId();
}

private abstract class AbstractIdentifiable : Identifiable
{
    private static int counter;
    private string id;

    this()
    {
        import flint.java.lang : valueOf;

        id = "listener-" ~ valueOf(++counter);
    }

    string getId()
    {
        return id;
    }
}

private class TestEvent : ApplicationEvent
{
    string msg;

    this(Object source, string msg = "test")
    {
        super(source);
        this.msg = msg;
    }

    this()
    {
        this(new Object);
    }
}

private final class GenericEventPojo(T)
{
    T value;

    this(T value) pure nothrow @nogc
    {
        this.value = value;
    }
}

/// Collects the events every listener received, by listener id.
private final class EventCollector
{
    private Any[][string] content;
    private string[] order;

    void addEvent(Identifiable listener, Any event)
    {
        if ((listener.getId() in content) is null)
            order ~= listener.getId();
        content[listener.getId()] ~= event;
    }

    Any[] getEvents(Identifiable listener)
    {
        return content.get(listener.getId(), null);
    }

    void assertNoEventReceived(Identifiable listener)
    {
        assert(getEvents(listener).length == 0, "Expected no events");
    }

    /// The listener received exactly `events`: objects by identity, strings and numbers by value.
    void assertEvent(Values...)(Identifiable listener, Values events)
    {
        auto actual = getEvents(listener);
        assert(actual.length == events.length, "Wrong number of events");
        static foreach (i, V; Values)
        {
            static if (is(V == class))
                assert(actual[i].asObject() is events[i], "Wrong event");
            else
                assert(actual[i].get!V == events[i], "Wrong event");
        }
    }

    void assertTotalEventsCount(size_t number)
    {
        size_t actual;
        foreach (events; content)
            actual += events.length;
        assert(actual == number, "Wrong number of total events");
    }

    void clear()
    {
        content = null;
        order = null;
    }
}

private abstract class AbstractTestEventListener : AbstractIdentifiable
{
    private EventCollector eventCollector; // @Autowired

    protected void collectEvent(T)(T content)
    {
        eventCollector.addEvent(this, Any.of(content));
    }
}

private class TestEventListener : AbstractTestEventListener
{
    void handle(TestEvent event) // @EventListener
    {
        collectEvent(event);
    }

    void handleString(string content) // @EventListener
    {
        collectEvent(content);
    }

    void handleBooleanOrInteger(Any content) // @EventListener({Boolean.class, Integer.class})
    {
        eventCollector.addEvent(this, content);
    }
}

private final class MetaAnnotationListenerTestBean : AbstractTestEventListener
{
    void handleIt(TestEvent event) // @FooListener, meta-annotated with @EventListener(id = "foo")
    {
        collectEvent(event);
    }
}

private final class ContextEventListener : AbstractTestEventListener
{
    void handleContextEvent(ApplicationContextEvent event) // @EventListener
    {
        collectEvent(event);
    }
}

private final class ExceptionEventListener : AbstractTestEventListener
{
    void handle(TestEvent event) // @EventListener
    {
        collectEvent(event);
        if (event.msg == "fail")
            throw new IllegalStateException("Test exception");
    }
}

private final class GenericEventListener : AbstractTestEventListener
{
    void handleString(PayloadApplicationEvent event) // @EventListener, PayloadApplicationEvent<String>
    {
        collectEvent(event.getPayload!string());
    }
}

private final class ResolvableTypeEventListener : AbstractTestEventListener
{
    void handleString(GenericEventPojo!string value) // @EventListener
    {
        collectEvent(value);
    }
}

private final class OrderedTestListener : TestEventListener
{
    string[] order;

    void handleThird(string) // @EventListener @Order(50)
    {
        order ~= "third";
    }

    void handleFirst(string) // @EventListener @Order(-50)
    {
        order ~= "first";
    }

    void handleSecond(string) // @EventListener
    {
        order ~= "second";
    }
}

private final class PublicSubclassWithInheritedEventListener : TestEventListener
{
}

private final class MyEventListener
{
    void hear(TestEvent) // @EventListener
    {
        assert(false);
    }
}

private final class UseMissingEventListener
{
    this(MyEventListener notHere) // @Inject Optional<MyEventListener>
    {
        assert(notHere is null);
    }
}

// ---- what Flint AOT generates

private Object create(T)(BeanFactory)
{
    return new T;
}

private void autowireCollector(Object bean, BeanFactory factory)
{
    (cast(AbstractTestEventListener) bean).eventCollector = cast(
            EventCollector) factory.getBeanOfType(typeNameOf!EventCollector);
}

private void listenHandle(Object bean, ref Any event)
{
    (cast(TestEventListener) bean).handle(event.get!TestEvent);
}

private void listenHandleString(Object bean, ref Any event)
{
    (cast(TestEventListener) bean).handleString(event.get!string);
}

private void listenHandleBooleanOrInteger(Object bean, ref Any event)
{
    (cast(TestEventListener) bean).handleBooleanOrInteger(event);
}

private void listenMeta(Object bean, ref Any event)
{
    (cast(MetaAnnotationListenerTestBean) bean).handleIt(event.get!TestEvent);
}

private void listenContext(Object bean, ref Any event)
{
    (cast(ContextEventListener) bean).handleContextEvent(event.get!ApplicationContextEvent);
}

private void listenException(Object bean, ref Any event)
{
    (cast(ExceptionEventListener) bean).handle(event.get!TestEvent);
}

private void listenGeneric(Object bean, ref Any event)
{
    (cast(GenericEventListener) bean).handleString(event.get!PayloadApplicationEvent);
}

private void listenPojo(Object bean, ref Any event)
{
    (cast(ResolvableTypeEventListener) bean).handleString(event.get!(GenericEventPojo!string));
}

private void listenThird(Object bean, ref Any event)
{
    (cast(OrderedTestListener) bean).handleThird(event.get!string);
}

private void listenFirst(Object bean, ref Any event)
{
    (cast(OrderedTestListener) bean).handleFirst(event.get!string);
}

private void listenSecond(Object bean, ref Any event)
{
    (cast(OrderedTestListener) bean).handleSecond(event.get!string);
}

private void listenHear(Object bean, ref Any event)
{
    (cast(MyEventListener) bean).hear(event.get!TestEvent);
}

private BeanDefinition record(T)(string name, Object function(BeanFactory) @safe create)
{
    BeanDefinition definition;
    definition.name = name;
    definition.type = typeNameOf!T;
    definition.types = [typeNameOf!T];
    definition.create = create;
    return definition;
}

/// BasicConfiguration and its EventCollector bean.
private void basicConfiguration(scope AotRegistry registry)
{
    registry.bean(record!Object("basicConfiguration", &create!Object));
    registry.bean(record!EventCollector("eventCollector", &create!EventCollector));
}

private void listenerBean(T)(scope AotRegistry registry, string name)
{
    auto definition = record!T(name, &create!T);
    definition.initialize = &autowireCollector;
    registry.bean(definition);
}

private void testEventListenerSpecs(scope AotRegistry registry, string bean)
{
    registry.listener(EventListenerSpec(bean, typeNameOf!TestEvent, null, int.max, &listenHandle));
    registry.listener(EventListenerSpec(bean, "string", null, int.max, &listenHandleString));
    registry.listener(EventListenerSpec(bean, "bool", null, int.max, &listenHandleBooleanOrInteger));
    registry.listener(EventListenerSpec(bean, "int", null, int.max, &listenHandleBooleanOrInteger));
}

/// Java's `load(classes)`: BasicConfiguration plus the listener `T`, whose specs `listeners` registers.
private void load(T, alias listeners)(scope AotRegistry registry)
{
    registry.begin(1, 1);
    basicConfiguration(registry);
    listenerBean!T(registry, "listener");
    listeners(registry);
    registry.end();
}

private void testEventListener(scope AotRegistry registry)
{
    testEventListenerSpecs(registry, "listener");
}

private void metaListener(scope AotRegistry registry)
{
    registry.listener(EventListenerSpec("listener", typeNameOf!TestEvent, null, int.max, &listenMeta));
}

private void contextListener(scope AotRegistry registry)
{
    registry.listener(EventListenerSpec("listener", typeNameOf!ApplicationContextEvent, null,
            int.max, &listenContext));
}

private void exceptionListener(scope AotRegistry registry)
{
    registry.listener(EventListenerSpec("listener", typeNameOf!TestEvent, null, int.max, &listenException));
}

private void genericListener(scope AotRegistry registry)
{
    registry.listener(EventListenerSpec("listener", typeNameOf!PayloadApplicationEvent, null,
            int.max, &listenGeneric));
}

private void pojoListener(scope AotRegistry registry)
{
    registry.listener(EventListenerSpec("listener", typeNameOf!(GenericEventPojo!string), null,
            int.max, &listenPojo));
}

private void orderedListener(scope AotRegistry registry)
{
    testEventListenerSpecs(registry, "listener");
    registry.listener(EventListenerSpec("listener", "string", null, 50, &listenThird));
    registry.listener(EventListenerSpec("listener", "string", null, -50, &listenFirst));
    registry.listener(EventListenerSpec("listener", "string", null, int.max, &listenSecond));
}

private Object createMissing(BeanFactory)
{
    return null; // @Bean MyEventListener missing() { return null; }
}

private Object createUseMissing(BeanFactory factory)
{
    return new UseMissingEventListener(cast(MyEventListener) factory.findBeanOfType(typeNameOf!MyEventListener));
}

private void populateMissing(scope AotRegistry registry)
{
    registry.begin(1, 1);
    basicConfiguration(registry);
    registry.bean(record!Object("missingEventListener", &create!Object));
    registry.bean(record!UseMissingEventListener("useMissingEventListener", &createUseMissing));
    registry.bean(record!MyEventListener("missing", &createMissing));
    registry.listener(EventListenerSpec("missing", typeNameOf!TestEvent, null, int.max, &listenHear));
    registry.end();
}

private struct Loaded
{
    AnnotationConfigApplicationContext context;
    EventCollector eventCollector;
}

private Loaded doLoad(void function(scope AotRegistry) @safe populate)
{
    auto context = new AnnotationConfigApplicationContext(populate);
    return Loaded(context, context.getBean!EventCollector());
}

unittest
{
    // simpleEventJavaConfig
    auto loaded = doLoad(&load!(TestEventListener, testEventListener));
    auto event = new TestEvent(null, "test");
    auto listener = loaded.context.getBean!TestEventListener();

    loaded.eventCollector.assertNoEventReceived(listener);
    loaded.context.publishEvent(event);
    loaded.eventCollector.assertEvent(listener, event);
    loaded.eventCollector.assertTotalEventsCount(1);

    loaded.eventCollector.clear();
    auto otherEvent = new TestEvent(null, "1");
    loaded.context.publishEvent(otherEvent);
    loaded.eventCollector.assertEvent(listener, otherEvent);
    loaded.eventCollector.assertTotalEventsCount(1);
    loaded.context.close();
}

unittest
{
    // metaAnnotationIsDiscovered
    auto loaded = doLoad(&load!(MetaAnnotationListenerTestBean, metaListener));
    auto bean = loaded.context.getBean!MetaAnnotationListenerTestBean();
    loaded.eventCollector.assertNoEventReceived(bean);
    auto event = new TestEvent;
    loaded.context.publishEvent(event);
    loaded.eventCollector.assertEvent(bean, event);
    loaded.eventCollector.assertTotalEventsCount(1);
    loaded.context.close();
}

unittest
{
    // contextEventsAreReceived
    auto loaded = doLoad(&load!(ContextEventListener, contextListener));
    auto context = loaded.context;
    auto listener = context.getBean!ContextEventListener();

    auto events = loaded.eventCollector.getEvents(listener);
    assert(events.length == 1, "Wrong number of initial context events");
    assert(typeid(events[0].asObject()) is typeid(ContextRefreshedEvent));

    context.start();
    auto eventsAfterStart = loaded.eventCollector.getEvents(listener);
    assert(eventsAfterStart.length == 2, "Wrong number of context events on start");
    assert(typeid(eventsAfterStart[1].asObject()) is typeid(ContextStartedEvent));
    loaded.eventCollector.assertTotalEventsCount(2);

    context.stop();
    auto eventsAfterStop = loaded.eventCollector.getEvents(listener);
    assert(eventsAfterStop.length == 3, "Wrong number of context events on stop");
    assert(typeid(eventsAfterStop[2].asObject()) is typeid(ContextStoppedEvent));
    loaded.eventCollector.assertTotalEventsCount(3);

    context.close();
    auto eventsAfterClose = loaded.eventCollector.getEvents(listener);
    assert(eventsAfterClose.length == 4, "Wrong number of context events on close");
    assert(typeid(eventsAfterClose[3].asObject()) is typeid(ContextClosedEvent));
    loaded.eventCollector.assertTotalEventsCount(4);

    // Further events are supposed to be ignored after context close
    context.publishEvent(new ContextClosedEvent(context));
    loaded.eventCollector.assertTotalEventsCount(4);
}

unittest
{
    // exceptionPropagated
    auto loaded = doLoad(&load!(ExceptionEventListener, exceptionListener));
    auto event = new TestEvent(null, "fail");
    auto listener = loaded.context.getBean!ExceptionEventListener();
    loaded.eventCollector.assertNoEventReceived(listener);
    auto e = collectException!IllegalStateException(loaded.context.publishEvent(event));
    assert(e !is null && e.getMessage() == "Test exception");
    loaded.eventCollector.assertEvent(listener, event);
    loaded.eventCollector.assertTotalEventsCount(1);
    loaded.context.close();
}

unittest
{
    // listenerWithSimplePayload
    auto loaded = doLoad(&load!(TestEventListener, testEventListener));
    auto listener = loaded.context.getBean!TestEventListener();
    loaded.eventCollector.assertNoEventReceived(listener);
    loaded.context.publishEvent("test");
    loaded.eventCollector.assertEvent(listener, "test");
    loaded.eventCollector.assertTotalEventsCount(1);
    loaded.context.close();
}

unittest
{
    // listenerWithNonMatchingPayload
    auto loaded = doLoad(&load!(TestEventListener, testEventListener));
    auto listener = loaded.context.getBean!TestEventListener();
    loaded.eventCollector.assertNoEventReceived(listener);
    loaded.context.publishEvent(123L);
    loaded.eventCollector.assertNoEventReceived(listener);
    loaded.eventCollector.assertTotalEventsCount(0);
    loaded.context.close();
}

unittest
{
    // listenerWithGenericApplicationEvent
    auto loaded = doLoad(&load!(GenericEventListener, genericListener));
    auto listener = loaded.context.getBean!GenericEventListener();
    loaded.eventCollector.assertNoEventReceived(listener);
    loaded.context.publishEvent("TEST");
    loaded.eventCollector.assertEvent(listener, "TEST");
    loaded.eventCollector.assertTotalEventsCount(1);
    loaded.context.close();
}

unittest
{
    // listenerWithResolvableTypeEvent
    auto loaded = doLoad(&load!(ResolvableTypeEventListener, pojoListener));
    auto listener = loaded.context.getBean!ResolvableTypeEventListener();
    loaded.eventCollector.assertNoEventReceived(listener);
    auto event = new GenericEventPojo!string("TEST");
    loaded.context.publishEvent(event);
    loaded.eventCollector.assertEvent(listener, event);
    loaded.eventCollector.assertTotalEventsCount(1);
    loaded.context.close();
}

unittest
{
    // listenerWithResolvableTypeEventWrongGeneric
    auto loaded = doLoad(&load!(ResolvableTypeEventListener, pojoListener));
    auto listener = loaded.context.getBean!ResolvableTypeEventListener();
    loaded.eventCollector.assertNoEventReceived(listener);
    loaded.context.publishEvent(new GenericEventPojo!long(123L));
    loaded.eventCollector.assertNoEventReceived(listener);
    loaded.eventCollector.assertTotalEventsCount(0);
    loaded.context.close();
}

unittest
{
    // orderedListeners
    auto loaded = doLoad(&load!(OrderedTestListener, orderedListener));
    auto listener = loaded.context.getBean!OrderedTestListener();
    assert(listener.order.length == 0);
    loaded.context.publishEvent("whatever");
    foreach (expected; ["first", "second", "third"])
    {
        bool found;
        foreach (actual; listener.order)
            found |= actual == expected;
        assert(found);
    }
    assert(listener.order[0] == "first");
    loaded.context.close();
}

unittest
{
    // publicSubclassWithInheritedEventListener
    auto loaded = doLoad(&load!(PublicSubclassWithInheritedEventListener, testEventListener));
    auto listener = loaded.context.getBean!PublicSubclassWithInheritedEventListener();
    loaded.eventCollector.assertNoEventReceived(listener);
    loaded.context.publishEvent("test");
    loaded.eventCollector.assertEvent(listener, "test");
    loaded.eventCollector.assertTotalEventsCount(1);
    loaded.context.close();
}

unittest
{
    // missingListenerBeanIgnored
    auto context = new AnnotationConfigApplicationContext(&populateMissing);
    context.getBean!UseMissingEventListener();
    context.publishEvent(new TestEvent(null));
    context.close();
}

// ---- conditionMatch, conditionDoesNotMatch (contract 3: conditions compiled to D)

private final class TestConditionEvaluator
{
    bool valid(double ratio)
    {
        return ratio == 42;
    }
}

private final class ConditionalEventListener : TestEventListener
{
    void handleTimestamp(long timestamp) // @ConditionalEvent("#root.event.timestamp > #p0")
    {
        collectEvent(timestamp);
    }

    void handleRatio(double ratio) // @ConditionalEvent("@conditionEvaluator.valid(#p0)")
    {
        collectEvent(ratio);
    }
}

private void listenTimestamp(Object bean, ref Any event)
{
    (cast(ConditionalEventListener) bean).handleTimestamp(event.get!long);
}

private void listenRatio(Object bean, ref Any event)
{
    (cast(ConditionalEventListener) bean).handleRatio(event.get!double);
}

private Any conditionMsgOk(EvaluationContext context) // "'OK'.equals(#root.event.msg)"
{
    return Any.of((cast(TestEvent) context.rootProperty("event").asObject()).msg == "OK");
}

private Any conditionPayloadOk(EvaluationContext context) // "#payload.startsWith('OK')"
{
    const payload = context.argument(0).get!string;
    return Any.of(payload.length >= 2 && payload[0 .. 2] == "OK");
}

private Any conditionTimestamp(EvaluationContext context) // "#root.event.timestamp > #p0"
{
    auto event = cast(ApplicationEvent) context.rootProperty("event").asObject();
    return Any.of(event.getTimestamp() > context.argument(0).get!long);
}

private Any conditionRatio(EvaluationContext context) // "@conditionEvaluator.valid(#p0)"
{
    return Any.of((cast(TestConditionEvaluator) context.bean("conditionEvaluator"))
            .valid(context.argument(0).get!double));
}

private EventListenerSpec conditional(string eventType, string condition, void function(Object,
        ref Any) @safe invoke, CompiledExpression expression)
{
    auto spec = EventListenerSpec("listener", eventType, condition, int.max, invoke);
    spec.conditionExpression = expression;
    return spec;
}

private void populateConditional(scope AotRegistry registry)
{
    registry.begin(3, 1);
    basicConfiguration(registry);
    registry.bean(record!TestConditionEvaluator("conditionEvaluator", &create!TestConditionEvaluator));
    listenerBean!ConditionalEventListener(registry, "listener");
    registry.listener(conditional(typeNameOf!TestEvent, "'OK'.equals(#root.event.msg)",
            &listenHandle, &conditionMsgOk));
    registry.listener(conditional("string", "#payload.startsWith('OK')", &listenHandleString, &conditionPayloadOk));
    registry.listener(EventListenerSpec("listener", "bool", null, int.max, &listenHandleBooleanOrInteger));
    registry.listener(EventListenerSpec("listener", "int", null, int.max, &listenHandleBooleanOrInteger));
    registry.listener(conditional("long", "#root.event.timestamp > #p0", &listenTimestamp, &conditionTimestamp));
    registry.listener(conditional("double", "@conditionEvaluator.valid(#p0)", &listenRatio, &conditionRatio));
    registry.end();
}

unittest
{
    // conditionMatch
    auto loaded = doLoad(&populateConditional);
    const long timestamp = new TestEvent().getTimestamp() - 1;
    auto event = new TestEvent(new Object, "OK");
    auto listener = loaded.context.getBean!ConditionalEventListener();
    loaded.eventCollector.assertNoEventReceived(listener);
    loaded.context.publishEvent(event);
    loaded.eventCollector.assertEvent(listener, event);
    loaded.eventCollector.assertTotalEventsCount(1);
    loaded.context.publishEvent("OK");
    loaded.eventCollector.assertEvent(listener, event, "OK");
    loaded.eventCollector.assertTotalEventsCount(2);
    loaded.context.publishEvent("NOT OK");
    loaded.eventCollector.assertTotalEventsCount(2);
    loaded.context.publishEvent(timestamp);
    loaded.eventCollector.assertEvent(listener, event, "OK", timestamp);
    loaded.eventCollector.assertTotalEventsCount(3);
    loaded.context.publishEvent(42.0);
    loaded.eventCollector.assertEvent(listener, event, "OK", timestamp, 42.0);
    loaded.eventCollector.assertTotalEventsCount(4);
}

unittest
{
    // conditionDoesNotMatch
    auto loaded = doLoad(&populateConditional);
    auto listener = loaded.context.getBean!ConditionalEventListener();
    loaded.context.publishEvent(new TestEvent(new Object, "KO"));
    loaded.context.publishEvent("KO");
    loaded.context.publishEvent(long.max);
    loaded.context.publishEvent(24.0);
    loaded.eventCollector.assertNoEventReceived(listener);
    loaded.eventCollector.assertTotalEventsCount(0);
}

unittest
{
    // A condition without its compiled form (generated code before contract 3) fails at refresh.
    static void populate(scope AotRegistry registry) @safe
    {
        registry.begin(2, 1);
        basicConfiguration(registry);
        listenerBean!ConditionalEventListener(registry, "listener");
        registry.listener(EventListenerSpec("listener", "string", "#payload == 'x'", int.max, &listenHandleString));
        registry.end();
    }

    assert(collectException!IllegalStateException(new AnnotationConfigApplicationContext(&populate)) !is null);
}

// ---- simpleReply, nullReplyIgnored, arrayReply, collectionReply, collectionReplyNullValue, replyWithPayload

private final class AnotherTestEvent : ApplicationEvent
{
    Any content;

    this(Object source, Any content)
    {
        super(source);
        this.content = content;
    }
}

private final class ReplyEventListener : AbstractTestEventListener
{
    Any handle(AnotherTestEvent event) // @EventListener, returning Object
    {
        collectEvent(event);
        if (event.content.isNull)
            return Any.init;
        if (event.content.typeName == "string")
        {
            const s = event.content.get!string;
            return s == "String" ? event.content : Any.of(cast(ApplicationEvent) new TestEvent(this, s));
        }
        return event.content;
    }
}

private Any listenReply(Object bean, ref Any event)
{
    return (cast(ReplyEventListener) bean).handle(event.get!AnotherTestEvent);
}

private void populateReply(scope AotRegistry registry)
{
    registry.begin(3, 1);
    basicConfiguration(registry);
    listenerBean!TestEventListener(registry, "listener");
    listenerBean!ReplyEventListener(registry, "replyEventListener");
    testEventListenerSpecs(registry, "listener");
    auto spec = EventListenerSpec("replyEventListener", typeNameOf!AnotherTestEvent, null, int.max, null);
    spec.invokeForResult = &listenReply;
    registry.listener(spec);
    registry.end();
}

private struct ReplyFixture
{
    Loaded loaded;
    ReplyEventListener reply;
    TestEventListener listener;
}

private ReplyFixture replyFixture()
{
    auto loaded = doLoad(&populateReply);
    auto fixture = ReplyFixture(loaded, loaded.context.getBean!ReplyEventListener(),
            loaded.context.getBean!TestEventListener());
    loaded.eventCollector.assertNoEventReceived(fixture.listener);
    loaded.eventCollector.assertNoEventReceived(fixture.reply);
    return fixture;
}

unittest
{
    // simpleReply: the returned event is published.
    auto f = replyFixture();
    auto event = new AnotherTestEvent(new Object, Any.of("dummy"));
    f.loaded.context.publishEvent(event);
    f.loaded.eventCollector.assertEvent(f.reply, event);
    auto received = f.loaded.eventCollector.getEvents(f.listener);
    assert(received.length == 1 && (cast(TestEvent) received[0].asObject()).msg == "dummy");
    assert((cast(TestEvent) received[0].asObject()).getSource() is f.reply);
    f.loaded.eventCollector.assertTotalEventsCount(2);
}

unittest
{
    // nullReplyIgnored
    auto f = replyFixture();
    auto event = new AnotherTestEvent(new Object, Any.init);
    f.loaded.context.publishEvent(event);
    f.loaded.eventCollector.assertEvent(f.reply, event);
    f.loaded.eventCollector.assertNoEventReceived(f.listener);
    f.loaded.eventCollector.assertTotalEventsCount(1);
}

unittest
{
    // arrayReply: each element is published.
    auto f = replyFixture();
    auto event = new AnotherTestEvent(new Object, Any.of(["first", "second"]));
    f.loaded.context.publishEvent(event);
    f.loaded.eventCollector.assertEvent(f.reply, event);
    f.loaded.eventCollector.assertEvent(f.listener, "first", "second");
    f.loaded.eventCollector.assertTotalEventsCount(3);
}

unittest
{
    // collectionReply: each element is published; nothing listens for the long.
    import flint.java.util : LinkedHashSet;

    auto f = replyFixture();
    auto replies = new LinkedHashSet!Any;
    replies.add(Any.of("first"));
    replies.add(Any.of(4L));
    replies.add(Any.of("third"));
    auto event = new AnotherTestEvent(new Object, Any.of(replies));
    f.loaded.context.publishEvent(event);
    f.loaded.eventCollector.assertEvent(f.reply, event);
    f.loaded.eventCollector.assertEvent(f.listener, "first", "third");
    f.loaded.eventCollector.assertTotalEventsCount(3);
}

unittest
{
    // collectionReplyNullValue: a null element is skipped.
    import flint.java.util : ArrayList;

    auto f = replyFixture();
    auto replies = new ArrayList!Any;
    replies.add(Any.init);
    replies.add(Any.of("test"));
    auto event = new AnotherTestEvent(new Object, Any.of(replies));
    f.loaded.context.publishEvent(event);
    f.loaded.eventCollector.assertEvent(f.reply, event);
    f.loaded.eventCollector.assertEvent(f.listener, "test");
    f.loaded.eventCollector.assertTotalEventsCount(2);
}

unittest
{
    // replyWithPayload: a non-event result is published as a payload.
    auto f = replyFixture();
    auto event = new AnotherTestEvent(new Object, Any.of("String"));
    f.loaded.context.publishEvent(event);
    f.loaded.eventCollector.assertEvent(f.reply, event);
    f.loaded.eventCollector.assertEvent(f.listener, "String");
    f.loaded.eventCollector.assertTotalEventsCount(2);
}
