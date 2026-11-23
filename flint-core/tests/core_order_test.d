// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core
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
 * spring-core/src/test/java/org/springframework/core/OrderComparatorTests.java.
 *
 * Skipped Java tests: none. Java's boxed `5L` is a small `LongValue` class with value equality, and an array order
 * source (`new Object[] {...}`) is a `flint.java.util` list of objects, D arrays not being `Object`s.
 */
module flint.core.order_test;

import flint.core : OrderComparator, Ordered, PriorityOrdered;
import flint.java.util : ArrayList, List;

@safe:

private class StubOrdered : Ordered
{
    private int order;

    this(int order)
    {
        this.order = order;
    }

    int getOrder()
    {
        return order;
    }
}

private class StubPriorityOrdered : PriorityOrdered
{
    private int order;

    this(int order)
    {
        this.order = order;
    }

    int getOrder()
    {
        return order;
    }
}

private final class LongValue
{
    private long value;

    this(long value)
    {
        this.value = value;
    }
}

private class TestSourceProvider : OrderComparator.OrderSourceProvider
{
    private LongValue target;
    private Object orderSource;

    this(LongValue target, Object orderSource)
    {
        this.target = target;
        this.orderSource = orderSource;
    }

    Object getOrderSource(Object obj)
    {
        auto candidate = cast(LongValue) obj;
        return candidate !is null && candidate.value == target.value ? orderSource : null;
    }
}

private OrderComparator comparator()
{
    return new OrderComparator;
}

private Object objects(Object[] elements...)
{
    List!Object list = new ArrayList!Object();
    foreach (element; elements)
        list.add(element);
    return cast(Object) list;
}

private void assertThatPriorityOrderedAlwaysWins(StubPriorityOrdered priority, StubOrdered standard)
{
    assert(comparator().compare(priority, standard) == -1);
    assert(comparator().compare(standard, priority) == 1);
}

unittest
{
    // compareOrderedInstancesBefore
    assert(comparator().compare(new StubOrdered(100), new StubOrdered(2000)) == -1);
}

unittest
{
    // compareOrderedInstancesSame
    assert(comparator().compare(new StubOrdered(100), new StubOrdered(100)) == 0);
}

unittest
{
    // compareOrderedInstancesAfter
    assert(comparator().compare(new StubOrdered(982_300), new StubOrdered(100)) == 1);
}

unittest
{
    // compareOrderedInstancesNullFirst
    assert(comparator().compare(null, new StubOrdered(100)) == 1);
}

unittest
{
    // compareOrderedInstancesNullLast
    assert(comparator().compare(new StubOrdered(100), null) == -1);
}

unittest
{
    // compareOrderedInstancesDoubleNull
    assert(comparator().compare(null, null) == 0);
}

unittest
{
    // compareTwoNonOrderedInstancesEndsUpAsSame
    assert(comparator().compare(new Object, new Object) == 0);
}

unittest
{
    // comparePriorityOrderedInstancesBefore
    assert(comparator().compare(new StubPriorityOrdered(100), new StubPriorityOrdered(2000)) == -1);
}

unittest
{
    // comparePriorityOrderedInstancesSame
    assert(comparator().compare(new StubPriorityOrdered(100), new StubPriorityOrdered(100)) == 0);
}

unittest
{
    // comparePriorityOrderedInstancesAfter
    assert(comparator().compare(new StubPriorityOrdered(982_300), new StubPriorityOrdered(100)) == 1);
}

unittest
{
    // comparePriorityOrderedInstanceToStandardOrderedInstanceWithHigherPriority
    assertThatPriorityOrderedAlwaysWins(new StubPriorityOrdered(200), new StubOrdered(100));
}

unittest
{
    // comparePriorityOrderedInstanceToStandardOrderedInstanceWithSamePriority
    assertThatPriorityOrderedAlwaysWins(new StubPriorityOrdered(100), new StubOrdered(100));
}

unittest
{
    // comparePriorityOrderedInstanceToStandardOrderedInstanceWithLowerPriority
    assertThatPriorityOrderedAlwaysWins(new StubPriorityOrdered(100), new StubOrdered(200));
}

unittest
{
    // compareWithSimpleSourceProvider
    auto provider = new TestSourceProvider(new LongValue(5), new StubOrdered(25));
    auto customComparator = comparator().withSourceProvider(provider);
    assert(customComparator(new StubOrdered(10), new LongValue(5)) == -1);
}

unittest
{
    // compareWithSourceProviderArray
    auto customComparator = comparator().withSourceProvider(new TestSourceProvider(new LongValue(5),
            objects(new StubOrdered(10), new StubOrdered(-25))));
    assert(customComparator(new LongValue(5), new Object) == -1);
}

unittest
{
    // compareWithSourceProviderArrayNoMatch
    auto customComparator = comparator().withSourceProvider(new TestSourceProvider(new LongValue(5),
            objects(new Object, new Object)));
    assert(customComparator(new Object, new LongValue(5)) == 0);
}

unittest
{
    // compareWithSourceProviderEmpty
    auto customComparator = comparator().withSourceProvider(new TestSourceProvider(new LongValue(50), new Object));
    assert(customComparator(new Object, new LongValue(5)) == 0);
}
