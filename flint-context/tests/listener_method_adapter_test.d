// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/context/event/ApplicationListenerMethodAdapterTests.java
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
 * spring-context/src/test/java/org/springframework/context/event/ApplicationListenerMethodAdapterTests.java and
 * spring-context/src/test/java/org/springframework/context/event/AbstractApplicationEventListenerTests.java.
 */

/++
`ApplicationListenerMethodAdapterTests`. A `java.lang.reflect.Method` is the `EventListenerSpec` Flint AOT emits for
the `@EventListener` method: one per event class, so `@EventListener({String.class, Integer.class})` is two specs and
two adapters, which together stand for Java's one adapter. The adapter is bound to the spied `SampleEvents`, which
records its calls (Mockito's `verify`).

Flint matches listeners against event instances, not types: Java's `supportsEventType(eventType)` is `supportsEvent`
with an event of that type, `createPayloadEventType(X.class)` a `PayloadApplicationEvent` with an `X` payload, and
`onApplicationEvent` the erased `dispatchEvent`. Java's `onApplicationEvent` skips a payload of another type
(`resolveArguments`); Flint's adapter leaves that check to `supportsEvent`, which the multicaster calls before
dispatching, so `invokeListener` does the same. D templates are reified: `GenericTestEvent!string` and
`GenericTestEvent!int` are distinct classes, and an event always has a resolved type, so the assertions on raw types
(`ResolvableType.forClass(GenericTestEvent.class)`, `EntityWrapper<?>`) are left out of the gh-30399 tests, and
`listenerWithSubTypeSeveralGenerics` uses `PayloadTestEvent!(long, string)`.

The specs of the parameterless `handleStringAnnotationValue`, `handleStringAnnotationClasses` and
`handleStringOrInteger` are written out here: the generator takes the event type from the method's only parameter
and rejects a method without one (FLINT-E1108), whatever `@EventListener(classes)` names.

Skipped Java tests (39 in the class):
- genericListenerWithUnresolvedGenerics, listenerWithPayloadTypeErasure: raw (unresolved) event types.
- listenerWithTooManyParameters, listenerWithNoParameter, listenerWithMoreThanOneParameter: Flint AOT rejects such
  methods at build time (FLINT-E1108).
- invokeListenerWithAnyGenericPayload, rawGenericPayloadDoesNotSupportArbitraryGenericEventType,
  genericRawApplicationEventSupportsRawTypeAndAnySpecificType: wildcard parameter types (`EntityWrapper<?>`,
  `GenericTestEvent<?>`).
- invokeListenerCheckedException: `UndeclaredThrowableException` wraps a Java checked exception; D has none.
- invokeListenerInvalidProxy: AOP `ProxyFactory` is not ported.
+/
module flint.context.listener_method_adapter_test;

import flint.context : ApplicationEvent, PayloadApplicationEvent;
import flint.context.event : ApplicationListenerMethodAdapter, ContextRefreshedEvent;
import flint.core : Ordered;
import flint.engine.aot.any : Any;
import flint.engine.aot.event : EventListenerSpec;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : IllegalStateException;
import std.exception : collectException;
import std.string : indexOf;

@safe:

// ---- AbstractApplicationEventListenerTests' events

private class GenericTestEvent(T) : ApplicationEvent
{
    private T payload;

    this(Object source, T payload)
    {
        super(source);
        this.payload = payload;
    }

    T getPayload()
    {
        return payload;
    }
}

/// A `ResolvableTypeProvider` in Java; D's `SmartGenericTestEvent!T` is a `GenericTestEvent!T` already.
private final class SmartGenericTestEvent(T) : GenericTestEvent!T
{
    this(Object source, T payload)
    {
        super(source, payload);
    }
}

private GenericTestEvent!T createGenericTestEvent(T)(T payload)
{
    return new GenericTestEvent!T(null, payload);
}

/// A plain `ApplicationEvent`: `ResolvableType.forClass(ApplicationEvent.class)`.
private final class PlainEvent : ApplicationEvent
{
    this()
    {
        super(null);
    }
}

private final class EntityWrapper(T)
{
    private T entity;

    this(T entity) pure nothrow @nogc
    {
        this.entity = entity;
    }
}

private class PayloadTestEvent(V, T) : PayloadApplicationEvent
{
    private V something;

    this(Object source, T payload, V something)
    {
        super(source, Any.of(payload));
        this.something = something;
    }
}

private final class PayloadStringTestEvent : PayloadTestEvent!(long, string)
{
    this(Object source, string payload, long something)
    {
        super(source, payload, something);
    }
}

/// `ResolvableType.forClassWithGenerics(PayloadApplicationEvent.class, T)`: a payload event carrying a `T`.
private PayloadApplicationEvent createPayloadEvent(T)(T payload)
{
    return new PayloadApplicationEvent(null, Any.of(payload));
}

// ---- SampleEvents, spied

private final class SampleEvents
{
    /// The arguments of each call, by method name.
    Any[][string] calls;

    private void called(string method, Any argument = Any.init)
    {
        calls[method] ~= argument;
    }

    /// How many times `method` was called.
    size_t times(string method)
    {
        return calls.get(method, null).length;
    }

    // @EventListener @Order(42)
    void handleRaw(ApplicationEvent event)
    {
        called("handleRaw", Any.of(event));
    }

    // @EventListener
    void handleGenericString(GenericTestEvent!string event)
    {
        called("handleGenericString", Any.of(event));
    }

    // @EventListener
    void handleUnrelated(ContextRefreshedEvent event)
    {
        called("handleUnrelated", Any.of(event));
    }

    // @EventListener
    void handleString(string payload)
    {
        called("handleString", Any.of(payload));
    }

    // @EventListener(String.class)
    void handleStringAnnotationValue()
    {
        called("handleStringAnnotationValue");
    }

    // @EventListener(classes = String.class)
    void handleStringAnnotationClasses()
    {
        called("handleStringAnnotationClasses");
    }

    // @EventListener(String.class)
    void handleStringAnnotationValueAndParameter(string payload)
    {
        called("handleStringAnnotationValueAndParameter", Any.of(payload));
    }

    // @EventListener({String.class, Integer.class})
    void handleStringOrInteger()
    {
        called("handleStringOrInteger");
    }

    // @EventListener
    void handleGenericStringPayload(EntityWrapper!string event)
    {
        called("handleGenericStringPayload", Any.of(event));
    }

    // @EventListener
    void generateRuntimeException(GenericTestEvent!string event)
    {
        if ("fail" == event.getPayload())
            throw new IllegalStateException("Test exception");
    }
}

// ---- what Flint AOT generates for the @EventListener methods

/// The generated invoker of `method`, which takes the event as a `T` (or nothing, for `T` = `void`).
private void invoke(string method, T)(Object bean, ref Any event)
{
    static if (is(T == void))
        __traits(getMember, cast(SampleEvents) bean, method)();
    else
        __traits(getMember, cast(SampleEvents) bean, method)(event.get!T);
}

/// The spec of `method` for the event type `E`, invoking it with a `T`.
private EventListenerSpec spec(string method, E, T = E)(int order = int.max, string bean = "unused")
{
    return EventListenerSpec(bean, typeNameOf!E, null, order, &invoke!(method, T));
}

/// Java's `Method`: the specs Flint AOT emits for one `@EventListener` method.
private alias Method = EventListenerSpec[];

private Method handleRaw()
{
    return [spec!("handleRaw", ApplicationEvent)(42)];
}

private Method handleGenericString()
{
    return [spec!("handleGenericString", GenericTestEvent!string)()];
}

private Method handleUnrelated()
{
    return [spec!("handleUnrelated", ContextRefreshedEvent)()];
}

private Method handleString()
{
    return [spec!("handleString", string)()];
}

private Method handleStringAnnotationValue()
{
    return [spec!("handleStringAnnotationValue", string, void)()];
}

private Method handleStringAnnotationClasses()
{
    return [spec!("handleStringAnnotationClasses", string, void)()];
}

private Method handleStringAnnotationValueAndParameter()
{
    return [spec!("handleStringAnnotationValueAndParameter", string)()];
}

private Method handleStringOrInteger()
{
    auto forString = spec!("handleStringOrInteger", string, void)();
    auto forInteger = spec!("handleStringOrInteger", int, void)();
    return [forString, forInteger];
}

private Method handleGenericStringPayload()
{
    return [spec!("handleGenericStringPayload", EntityWrapper!string)()];
}

private Method generateRuntimeException()
{
    return [spec!("generateRuntimeException", GenericTestEvent!string)()];
}

// ---- the test's helpers

private ApplicationListenerMethodAdapter[] createTestInstance(Method method, SampleEvents sampleEvents)
{
    ApplicationListenerMethodAdapter[] adapters;
    foreach (spec; method)
        adapters ~= new ApplicationListenerMethodAdapter(spec, () => cast(Object) sampleEvents);
    return adapters;
}

private bool supports(ApplicationListenerMethodAdapter[] adapters, ApplicationEvent event)
{
    foreach (adapter; adapters)
        if (adapter.supportsEvent(event))
            return true;
    return false;
}

private void supportsEventType(bool match, Method method, ApplicationEvent event)
{
    auto adapters = createTestInstance(method, new SampleEvents);
    assert(supports(adapters, event) == match, "Wrong match for event '" ~ event.toString() ~ "'");
}

private void invokeListener(Method method, ApplicationEvent event, SampleEvents sampleEvents)
{
    foreach (adapter; createTestInstance(method, sampleEvents))
        if (adapter.supportsEvent(event))
            adapter.dispatchEvent(event);
}

unittest
{
    // rawListener
    supportsEventType(true, handleRaw(), new PlainEvent);
}

unittest
{
    // rawListenerWithGenericEvent
    supportsEventType(true, handleRaw(), createGenericTestEvent("test"));
}

unittest
{
    // genericListener
    supportsEventType(true, handleGenericString(), createGenericTestEvent("test"));
}

unittest
{
    // genericListenerWrongParameterizedType
    supportsEventType(false, handleGenericString(), createGenericTestEvent(123L));
}

unittest
{
    // listenerWithPayloadAndGenericInformation
    supportsEventType(true, handleString(), createPayloadEvent("test"));
}

unittest
{
    // listenerWithInvalidPayloadAndGenericInformation
    supportsEventType(false, handleString(), createPayloadEvent(123));
}

unittest
{
    // listenerWithSubTypeSeveralGenerics
    supportsEventType(true, handleString(), new PayloadTestEvent!(long, string)(null, "test", 123L));
}

unittest
{
    // listenerWithSubTypeSeveralGenericsResolved
    supportsEventType(true, handleString(), new PayloadStringTestEvent(null, "test", 123L));
}

unittest
{
    // listenerWithAnnotationValue
    supportsEventType(true, handleStringAnnotationValue(), createPayloadEvent("test"));
}

unittest
{
    // listenerWithAnnotationClasses
    supportsEventType(true, handleStringAnnotationClasses(), createPayloadEvent("test"));
}

unittest
{
    // listenerWithAnnotationValueAndParameter
    supportsEventType(true, handleStringAnnotationValueAndParameter(), createPayloadEvent("test"));
}

unittest
{
    // listenerWithSeveralTypes
    supportsEventType(true, handleStringOrInteger(), createPayloadEvent("test"));
    supportsEventType(true, handleStringOrInteger(), createPayloadEvent(123));
    supportsEventType(false, handleStringOrInteger(), createPayloadEvent(23.2));
}

unittest
{
    // defaultOrder
    auto adapter = createTestInstance(handleGenericString(), new SampleEvents)[0];
    assert(adapter.getListenerOrder() == Ordered.LOWEST_PRECEDENCE);
}

unittest
{
    // specifiedOrder
    auto adapter = createTestInstance(handleRaw(), new SampleEvents)[0];
    assert(adapter.getListenerOrder() == 42);
}

unittest
{
    // invokeListener
    auto sampleEvents = new SampleEvents;
    auto event = createGenericTestEvent("test");
    invokeListener(handleGenericString(), event, sampleEvents);
    assert(sampleEvents.times("handleGenericString") == 1);
    assert(sampleEvents.calls["handleGenericString"][0].asObject() is event);
}

unittest
{
    // invokeListenerWithGenericEvent
    auto sampleEvents = new SampleEvents;
    GenericTestEvent!string event = new SmartGenericTestEvent!string(null, "test");
    invokeListener(handleGenericString(), event, sampleEvents);
    assert(sampleEvents.times("handleGenericString") == 1);
    assert(sampleEvents.calls["handleGenericString"][0].asObject() is event);
}

unittest
{
    // invokeListenerWithGenericPayload
    auto sampleEvents = new SampleEvents;
    auto payload = new EntityWrapper!string("test");
    invokeListener(handleGenericStringPayload(), createPayloadEvent(payload), sampleEvents);
    assert(sampleEvents.times("handleGenericStringPayload") == 1);
    assert(sampleEvents.calls["handleGenericStringPayload"][0].asObject() is payload);
}

unittest
{
    // invokeListenerWithWrongGenericPayload
    auto sampleEvents = new SampleEvents;
    auto payload = new EntityWrapper!int(123);
    invokeListener(handleGenericStringPayload(), createPayloadEvent(payload), sampleEvents);
    assert(sampleEvents.times("handleGenericStringPayload") == 0);
}

unittest
{
    // invokeListenerRuntimeException
    auto event = createGenericTestEvent("fail");

    auto method = generateRuntimeException();
    auto e = collectException!IllegalStateException(invokeListener(method, event, new SampleEvents));
    assert(e !is null);
    assert(e.msg.indexOf("Test exception") >= 0);
    assert(e.getCause() is null);
}

unittest
{
    // invokeListenerWithPayload
    auto sampleEvents = new SampleEvents;
    auto event = createPayloadEvent("test");
    invokeListener(handleString(), event, sampleEvents);
    assert(sampleEvents.times("handleString") == 1);
    assert(sampleEvents.calls["handleString"][0].get!string == "test");
}

unittest
{
    // invokeListenerWithPayloadWrongType
    auto sampleEvents = new SampleEvents;
    auto event = createPayloadEvent(123L);
    invokeListener(handleString(), event, sampleEvents);
    assert(sampleEvents.times("handleString") == 0);
}

unittest
{
    // invokeListenerWithAnnotationValue
    auto sampleEvents = new SampleEvents;
    auto event = createPayloadEvent("test");
    invokeListener(handleStringAnnotationClasses(), event, sampleEvents);
    assert(sampleEvents.times("handleStringAnnotationClasses") == 1);
}

unittest
{
    // invokeListenerWithAnnotationValueAndParameter
    auto sampleEvents = new SampleEvents;
    auto event = createPayloadEvent("test");
    invokeListener(handleStringAnnotationValueAndParameter(), event, sampleEvents);
    assert(sampleEvents.times("handleStringAnnotationValueAndParameter") == 1);
    assert(sampleEvents.calls["handleStringAnnotationValueAndParameter"][0].get!string == "test");
}

unittest
{
    // invokeListenerWithSeveralTypes
    auto sampleEvents = new SampleEvents;
    auto event = createPayloadEvent("test");
    invokeListener(handleStringOrInteger(), event, sampleEvents);
    assert(sampleEvents.times("handleStringOrInteger") == 1);
    auto event2 = createPayloadEvent(123);
    invokeListener(handleStringOrInteger(), event2, sampleEvents);
    assert(sampleEvents.times("handleStringOrInteger") == 2);
    auto event3 = createPayloadEvent(23.2);
    invokeListener(handleStringOrInteger(), event3, sampleEvents);
    assert(sampleEvents.times("handleStringOrInteger") == 2);
}

unittest
{
    // beanInstanceRetrievedAtEveryInvocation
    auto sampleEvents = new SampleEvents;
    int getBeanCalls; // context.getBean("testBean")
    Object getBean()
    {
        getBeanCalls++;
        return sampleEvents;
    }

    auto method = spec!("handleGenericString", GenericTestEvent!string)(int.max, "testBean");
    auto listener = new ApplicationListenerMethodAdapter(method, &getBean);
    auto event = createGenericTestEvent("test");

    listener.dispatchEvent(event);
    assert(sampleEvents.times("handleGenericString") == 1);
    assert(getBeanCalls == 1);

    listener.dispatchEvent(event);
    assert(sampleEvents.times("handleGenericString") == 2);
    assert(getBeanCalls == 2);
}

unittest
{
    // simplePayloadDoesNotSupportArbitraryGenericEventType (gh-30399)
    auto adapter = createTestInstance(handleString(), new SampleEvents)[0];

    assert(!adapter.supportsEvent(createPayloadEvent(new EntityWrapper!int(123))),
            "handleString(String) with EntityWrapper<Integer>");
    assert(adapter.supportsEvent(createPayloadEvent("test")), "handleString(String) with String");
}

unittest
{
    // genericPayloadDoesNotSupportArbitraryGenericEventType (gh-30399)
    auto adapter = createTestInstance(handleGenericStringPayload(), new SampleEvents)[0];

    assert(!adapter.supportsEvent(createPayloadEvent(new EntityWrapper!int(123))),
            "handleGenericStringPayload(EntityWrapper<String>) with EntityWrapper<Integer>");
    assert(adapter.supportsEvent(createPayloadEvent(new EntityWrapper!string("test"))),
            "handleGenericStringPayload(EntityWrapper<String>) with EntityWrapper<String>");
}

unittest
{
    // genericApplicationEventSupportsSpecificType (gh-30399)
    auto adapter = createTestInstance(handleGenericString(), new SampleEvents)[0];

    assert(!adapter.supportsEvent(createGenericTestEvent(123)),
            "handleGenericString(GenericTestEvent<String>) with GenericTestEvent<Integer>");
    assert(adapter.supportsEvent(createGenericTestEvent("test")),
            "handleGenericString(GenericTestEvent<String>) with GenericTestEvent<String>");
}

unittest
{
    // unrelatedApplicationEventDoesNotSupportRawTypeOrAnySpecificType (gh-30399)
    auto adapter = createTestInstance(handleUnrelated(), new SampleEvents)[0];

    assert(!adapter.supportsEvent(createGenericTestEvent("test")),
            "handleUnrelated(ContextRefreshedEvent) with GenericTestEvent<String>");
    assert(!adapter.supportsEvent(createGenericTestEvent(123)),
            "handleUnrelated(ContextRefreshedEvent) with GenericTestEvent<Integer>");
}
