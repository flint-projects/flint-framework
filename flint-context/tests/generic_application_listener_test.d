// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/context/event/GenericApplicationListenerTests.java
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
 * spring-context/src/test/java/org/springframework/context/event/GenericApplicationListenerTests.java and
 * spring-context/src/test/java/org/springframework/context/event/AbstractApplicationEventListenerTests.java.
 */

/++
`GenericApplicationListenerTests`. Flint matches listeners against event instances, not types: Java's
`supportsEventType(ResolvableType.forClass(X.class))` is `supportsEvent` with an `X`, and `onApplicationEvent` is the
erased `dispatchEvent`. D templates are reified, so the raw `GenericTestEvent.class` of `forEventTypeWithSubClass` is
`GenericTestEvent!string`, the superclass `StringEvent` extends. The Mockito `Consumer` records its calls.
+/
module flint.context.generic_application_listener_test;

import flint.context : ApplicationEvent, GenericApplicationListener;

@safe:

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

private final class StringEvent : GenericTestEvent!string
{
    this(Object source, string payload)
    {
        super(source, payload);
    }
}

unittest
{
    // forEventTypeWithStrictTypeMatching
    auto listener = GenericApplicationListener.forEventType!StringEvent((StringEvent event) {});
    assert(listener.supportsEvent(new StringEvent(null, "test")));
}

unittest
{
    // forEventTypeWithSubClass
    alias Event = GenericTestEvent!string;
    auto listener = GenericApplicationListener.forEventType!Event((Event event) {});
    assert(listener.supportsEvent(new StringEvent(null, "test")));
}

unittest
{
    // forEventTypeWithSuperClass
    auto listener = GenericApplicationListener.forEventType!StringEvent((StringEvent event) {});
    assert(!listener.supportsEvent(new GenericTestEvent!string(null, "test")));
}

unittest
{
    // forEventTypeInvokesConsumer
    StringEvent[] accepted;
    auto listener = GenericApplicationListener.forEventType!StringEvent((StringEvent event) {
        accepted ~= event;
    });
    auto event = new StringEvent(null, "one");
    auto event2 = new StringEvent(null, "two");
    listener.dispatchEvent(event);
    listener.dispatchEvent(event2);
    assert(accepted.length == 2);
    assert(accepted[0] is event);
    assert(accepted[1] is event2);
}
