// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core/annotation
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.core.annotation.OrderUtilsTests` (v7.1.0): one `unittest` per Java
test method, each starting with a `// <JavaTestName>` comment.

Skipped Java tests: none.

Adapted: `OrderUtils` reads the Flint AOT descriptor of a type (`descriptorOf!T`) instead of a `Class`. Java's
`getOrder(Class, null)` returns a nullable `Integer`; its D counterpart is `getOrder(descriptor, out found)`, and
the nullable `getPriority` result is an `Optional!int`. Each Java test calls twice (to exercise Spring's cache);
the port keeps both calls.
+/
module flint.core.order_utils_test;

import flint.core.annotation : Order;
import flint.core.annotation.types : OrderUtils;
import flint.engine.aot.descriptor : descriptorOf;
import flint.jakarta.annotation : Priority;

@safe:

@Order(50) private final class SimpleOrder
{
}

@Priority(55) private final class SimplePriority
{
}

@Order(50) @Priority(55) private final class OrderAndPriority
{
}

private final class NoOrder
{
}

/// `OrderUtils.getOrder(T.class, null)`: the order, which must be present.
private int orderOf(T)()
{
    bool found;
    const order = OrderUtils.getOrder(descriptorOf!T, found);
    assert(found, T.stringof ~ " has no order");
    return order;
}

unittest
{
    // getSimpleOrder
    assert(orderOf!SimpleOrder() == 50);
    assert(orderOf!SimpleOrder() == 50);
}

unittest
{
    // getPriorityOrder
    assert(orderOf!SimplePriority() == 55);
    assert(orderOf!SimplePriority() == 55);
}

unittest
{
    // getOrderWithBoth
    assert(orderOf!OrderAndPriority() == 50);
    assert(orderOf!OrderAndPriority() == 50);
}

unittest
{
    // getDefaultOrder
    assert(OrderUtils.getOrder(descriptorOf!NoOrder, 33) == 33);
    assert(OrderUtils.getOrder(descriptorOf!NoOrder, 33) == 33);
}

unittest
{
    // getPriorityValueNoAnnotation
    assert(!OrderUtils.getPriority(descriptorOf!SimpleOrder).isPresent());
    assert(!OrderUtils.getPriority(descriptorOf!SimpleOrder).isPresent());
}

unittest
{
    // getPriorityValue
    assert(OrderUtils.getPriority(descriptorOf!OrderAndPriority).get() == 55);
    assert(OrderUtils.getPriority(descriptorOf!OrderAndPriority).get() == 55);
}
