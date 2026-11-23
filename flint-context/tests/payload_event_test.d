// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/context/event/PayloadApplicationEventTests.java
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
 * spring-context/src/test/java/org/springframework/context/event/PayloadApplicationEventTests.java.
 */

/++
`PayloadApplicationEventTests`. The `@Component` listeners and their `@EventListener` methods are the bean
definitions and `EventListenerSpec` entries Flint AOT generates. D templates are reified, so `NumberHolder!int` and
`AuditablePayloadEvent!string` carry the generic types Java passes as `ResolvableType`s; a payload type hint is not
needed.

Skipped Java tests (14 in the class):
- payloadApplicationEventWithNoTypeUsesInstance, payloadApplicationEventWithType: `ResolvableType`
  introspection of `PayloadApplicationEvent` (not ported).
+/
module flint.context.payload_event_test;

import flint.context : ApplicationContext, ApplicationListener, PayloadApplicationEvent;
import flint.context.annotation : AnnotationConfigApplicationContext;
import flint.context.support : GenericApplicationContext;
import flint.engine.aot.any : Any;
import flint.engine.aot.bean : BeanDefinition, BeanFactory;
import flint.engine.aot.event : EventListenerSpec;
import flint.engine.aot.name : typeNameOf;
import flint.engine.aot.registry : AotRegistry;

@safe:

private final class NumberHolder(T)
{
    T number;

    this(T number) pure nothrow @nogc
    {
        this.number = number;
    }
}

private final class NumberHolderListener
{
    NumberHolder!int[] events;

    void onEvent(NumberHolder!int event)
    {
        events ~= event;
    }
}

private interface Auditable
{
}

private final class AuditablePayloadEvent(T) : PayloadApplicationEvent, Auditable
{
    this(Object source, T payload)
    {
        super(source, Any.of(payload));
    }
}

private final class AuditableListener
{
    Auditable[] events;

    void onEvent(Auditable event)
    {
        events ~= event;
    }
}

private final class PlainPayloadListener
{
    string[] events;

    void onEvent(string event)
    {
        events ~= event;
    }
}

// ---- what Flint AOT generates for the three @Component listeners

private Object create(T)(BeanFactory)
{
    return new T;
}

private void listenNumberHolder(Object bean, ref Any event)
{
    (cast(NumberHolderListener) bean).onEvent(event.get!(NumberHolder!int));
}

private void listenAuditable(Object bean, ref Any event)
{
    (cast(AuditableListener) bean).onEvent(event.get!Auditable);
}

private void listenPlainPayload(Object bean, ref Any event)
{
    (cast(PlainPayloadListener) bean).onEvent(event.get!string);
}

private void register(T)(scope AotRegistry registry, string name, string eventType,
        void function(Object, ref Any) @safe invoke)
{
    BeanDefinition definition;
    definition.name = name;
    definition.type = typeNameOf!T;
    definition.types = [typeNameOf!T];
    definition.create = &create!T;
    registry.begin(1, 1);
    registry.bean(definition);
    registry.listener(EventListenerSpec(name, eventType, null, int.max, invoke));
    registry.end();
}

private void numberHolderListener(scope AotRegistry registry)
{
    register!NumberHolderListener(registry, "numberHolderListener",
            typeNameOf!(NumberHolder!int), &listenNumberHolder);
}

private void auditableListener(scope AotRegistry registry)
{
    register!AuditableListener(registry, "auditableListener", typeNameOf!Auditable, &listenAuditable);
}

private void plainPayloadListener(scope AotRegistry registry)
{
    register!PlainPayloadListener(registry, "plainPayloadListener", "string", &listenPlainPayload);
}

private bool containsSame(T, U)(T[] values, U value)
{
    foreach (candidate; values)
        if (cast(Object) candidate is cast(Object) value)
            return true;
    return false;
}

unittest
{
    // eventClassWithPayloadType
    auto ac = new AnnotationConfigApplicationContext(&numberHolderListener);
    auto event = new PayloadApplicationEvent(null, Any.of(new NumberHolder!int(42)));
    ac.publishEvent(event);
    assert(containsSame(ac.getBean!NumberHolderListener().events, event.getPayload!(NumberHolder!int)()));
    ac.close();
}

unittest
{
    // eventClassWithPayloadTypeOnParentContext
    auto parent = new AnnotationConfigApplicationContext(&numberHolderListener);
    auto ac = new GenericApplicationContext(parent);
    ac.refresh();
    auto event = new PayloadApplicationEvent(null, Any.of(new NumberHolder!int(42)));
    ac.publishEvent(event);
    assert(containsSame(parent.getBean!NumberHolderListener().events, event.getPayload!(NumberHolder!int)()));
    ac.close();
    parent.close();
}

unittest
{
    // payloadObjectWithPayloadType
    auto payload = new NumberHolder!int(42);
    auto ac = new class(&numberHolderListener) AnnotationConfigApplicationContext
    {
        this(typeof(&numberHolderListener) populate)
        {
            super(populate);
        }

        protected override void finishRefresh()
        {
            super.finishRefresh();
            // This is not recommended: use publishEvent(new PayloadApplicationEvent(...)) instead
            publishEvent(payload);
        }
    };
    assert(containsSame(ac.getBean!NumberHolderListener().events, payload));
    ac.close();
}

unittest
{
    // payloadObjectWithPayloadTypeOnParentContext
    auto payload = new NumberHolder!int(42);
    auto parent = new AnnotationConfigApplicationContext(&numberHolderListener);
    auto ac = new class(parent) GenericApplicationContext
    {
        this(ApplicationContext parent)
        {
            super(parent);
        }

        protected override void finishRefresh()
        {
            super.finishRefresh();
            // This is not recommended: use publishEvent(new PayloadApplicationEvent(...)) instead
            publishEvent(payload);
        }
    };
    ac.refresh();
    assert(containsSame(parent.getBean!NumberHolderListener().events, payload));
    ac.close();
    parent.close();
}

unittest
{
    // eventClassWithInterface
    auto ac = new AnnotationConfigApplicationContext(&auditableListener);
    auto event = new AuditablePayloadEvent!string(null, "xyz");
    ac.publishEvent(event);
    assert(containsSame(ac.getBean!AuditableListener().events, event));
    ac.close();
}

unittest
{
    // eventClassWithInterfaceOnParentContext
    auto parent = new AnnotationConfigApplicationContext(&auditableListener);
    auto ac = new GenericApplicationContext(parent);
    ac.refresh();
    auto event = new AuditablePayloadEvent!string(null, "xyz");
    ac.publishEvent(event);
    assert(containsSame(parent.getBean!AuditableListener().events, event));
    ac.close();
    parent.close();
}

/// Java's `events::add` and `PayloadApplicationEvent::getPayload` lambdas as listeners (anonymous classes, R13).
private final class AuditableRecorder(T) : ApplicationListener!(AuditablePayloadEvent!T)
{
    Auditable[] events;

    override void onApplicationEvent(AuditablePayloadEvent!T event)
    {
        events ~= event;
    }
}

unittest
{
    // programmaticEventListener
    auto listener = new AuditableRecorder!string;
    auto mismatch = new AuditableRecorder!int;
    auto ac = new GenericApplicationContext;
    ac.addApplicationListener(listener);
    ac.addApplicationListener(mismatch);
    ac.refresh();
    auto event = new AuditablePayloadEvent!string(null, "xyz");
    ac.publishEvent(event);
    assert(containsSame(listener.events, event));
    assert(mismatch.events.length == 0);
    ac.close();
}

unittest
{
    // programmaticEventListenerOnParentContext
    auto listener = new AuditableRecorder!string;
    auto mismatch = new AuditableRecorder!int;
    auto parent = new GenericApplicationContext;
    parent.addApplicationListener(listener);
    parent.addApplicationListener(mismatch);
    parent.refresh();
    auto ac = new GenericApplicationContext(parent);
    ac.refresh();
    auto event = new AuditablePayloadEvent!string(null, "xyz");
    ac.publishEvent(event);
    assert(containsSame(listener.events, event));
    ac.close();
    parent.close();
}

private alias PayloadListener = ApplicationListener!PayloadApplicationEvent;

unittest
{
    // programmaticPayloadListener
    string[] events;
    int[] mismatches;
    auto ac = new GenericApplicationContext;
    ac.addApplicationListener(PayloadListener.forPayload!string((string payload) { events ~= payload; }));
    ac.addApplicationListener(PayloadListener.forPayload!int((int payload) { mismatches ~= payload; }));
    ac.refresh();
    const payload = "xyz";
    ac.publishEvent(payload);
    assert(events == [payload] && mismatches.length == 0);
    ac.close();
}

unittest
{
    // programmaticPayloadListenerOnParentContext
    string[] events;
    auto parent = new GenericApplicationContext;
    parent.addApplicationListener(PayloadListener.forPayload!string((string payload) {
            events ~= payload;
        }));
    parent.addApplicationListener(PayloadListener.forPayload!int((int) {}));
    parent.refresh();
    auto ac = new GenericApplicationContext(parent);
    ac.refresh();
    const payload = "xyz";
    ac.publishEvent(payload);
    assert(events == [payload]);
    ac.close();
    parent.close();
}

unittest
{
    // plainPayloadListener
    auto ac = new AnnotationConfigApplicationContext(&plainPayloadListener);
    const payload = "xyz";
    ac.publishEvent(payload);
    assert(ac.getBean!PlainPayloadListener().events == [payload]);
    ac.close();
}

unittest
{
    // plainPayloadListenerOnParentContext
    auto parent = new AnnotationConfigApplicationContext(&plainPayloadListener);
    auto ac = new GenericApplicationContext(parent);
    ac.refresh();
    const payload = "xyz";
    ac.publishEvent(payload);
    assert(parent.getBean!PlainPayloadListener().events == [payload]);
    ac.close();
    parent.close();
}
