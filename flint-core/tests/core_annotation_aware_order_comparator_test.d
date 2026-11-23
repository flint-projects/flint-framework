// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core/annotation
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.core.annotation.AnnotationAwareOrderComparatorTests` (v7.1.0): one
`unittest` per Java test method, each starting with a `// <JavaTestName>` comment.

Skipped Java tests: none.

Adapted: Flint's `AnnotationAwareOrderComparator` reads `@Order` and `@Priority` from the Flint AOT descriptors it
is given, not from a global reflective lookup, so Java's static `AnnotationAwareOrderComparator.sort(list)` is
`sort(list)` below: a stable sort with a comparator over the descriptors of this module's fixtures (in D,
`AnnotationAwareOrderComparator.sort` names the inherited `OrderComparator.sort`, which ignores `@Order`).
`hasExactlyElementsOfTypes` compares each element's exact class (`typeid`). Java's `Class` objects as sort
elements are D `TypeInfo_Class` objects (`typeid(A)`).
+/
module flint.core.annotation_aware_order_comparator_test;

import flint.core.annotation : Order;
import flint.core.annotation.types : AnnotationAwareOrderComparator;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jakarta.annotation : Priority;
import flint.java.util : ArrayList, Comparator, List;

@safe:

@Order(1) private class A
{
}

@Order(2) private class B
{
}

private class C : A
{
}

@Priority(1) private class A2
{
}

@Priority(2) private class B2
{
}

/// The comparator `sort` uses, over the descriptors of the fixtures above.
private final class FixtureComparator : Comparator!Object
{
    private AnnotationAwareOrderComparator comparator;

    this()
    {
        auto table = new DescriptorTable;
        table.add(descriptorOf!A);
        table.add(descriptorOf!B);
        table.add(descriptorOf!C);
        table.add(descriptorOf!A2);
        table.add(descriptorOf!B2);
        comparator = new AnnotationAwareOrderComparator(table);
    }

    int compare(Object o1, Object o2)
    {
        return comparator.compare(o1, o2);
    }
}

/// Java's `AnnotationAwareOrderComparator.sort(list)`.
private void sort(List!Object list)
{
    list.sort(new FixtureComparator);
}

/// AssertJ's `hasExactlyElementsOfTypes`: element `i` is exactly of class `types[i]`.
private bool hasExactlyElementsOfTypes(List!Object list, TypeInfo_Class[] types...)
{
    if (list.size() != types.length)
        return false;
    foreach (i, type; types)
        if (list.get(cast(int) i) is null || typeid(list.get(cast(int) i)) !is type)
            return false;
    return true;
}

unittest
{
    // instanceVariableIsAnAnnotationAwareOrderComparator
    assert(cast(AnnotationAwareOrderComparator) AnnotationAwareOrderComparator.INSTANCE() !is null);
}

unittest
{
    // sortInstances
    List!Object list = new ArrayList!Object();
    list.add(new B);
    list.add(new A);
    sort(list);
    assert(hasExactlyElementsOfTypes(list, typeid(A), typeid(B)));
}

unittest
{
    // sortInstancesWithPriority
    List!Object list = new ArrayList!Object();
    list.add(new B2);
    list.add(new A2);
    sort(list);
    assert(hasExactlyElementsOfTypes(list, typeid(A2), typeid(B2)));
}

unittest
{
    // sortInstancesWithOrderAndPriority
    List!Object list = new ArrayList!Object();
    list.add(new B);
    list.add(new A2);
    sort(list);
    assert(hasExactlyElementsOfTypes(list, typeid(A2), typeid(B)));
}

// The comparator reads only the object's own class descriptor: C (a subclass of @Order(1) A) gets no order and
// sorts after @Order(2) B, where Spring finds A's @Order through the type hierarchy.
version (FlintOrderFromSuperclass)
{
    unittest
    {
        // sortInstancesWithSubclass
        List!Object list = new ArrayList!Object();
        list.add(new B);
        list.add(new C);
        sort(list);
        assert(hasExactlyElementsOfTypes(list, typeid(C), typeid(B)));
    }
}

// The comparator has no order lookup for class objects (Java's `Class` order sources).
version (FlintOrderComparatorClasses)
{
    unittest
    {
        // sortClasses
        List!Object list = new ArrayList!Object();
        list.add(typeid(B));
        list.add(typeid(A));
        sort(list);
        assert(list.get(0) is typeid(A) && list.get(1) is typeid(B));
    }

    unittest
    {
        // sortClassesWithSubclass
        List!Object list = new ArrayList!Object();
        list.add(typeid(B));
        list.add(typeid(C));
        sort(list);
        assert(list.get(0) is typeid(C) && list.get(1) is typeid(B));
    }

    unittest
    {
        // sortWithNulls
        List!Object list = new ArrayList!Object();
        list.add(null);
        list.add(typeid(B));
        list.add(null);
        list.add(typeid(A));
        sort(list);
        assert(list.get(0) is typeid(A) && list.get(1) is typeid(B));
        assert(list.get(2) is null && list.get(3) is null);
    }
}
