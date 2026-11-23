// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core/annotation
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.core.annotation.MergedAnnotationsTests` (v7.1.0), part 5 of 5: the
repeatable-annotation tests (`stream(A)` over `@Repeatable` annotations and their containers). One `unittest` per
Java test method, each starting with a `// <JavaTestName>` comment. See `core_merged_annotations_search_test.d` for
the other parts.

Skipped Java tests: none in this part.

Adapted: Java annotations are D UDA structs; `@Retention` and `@Inherited` are dropped, and Java's
`@Repeatable(MyRepeatableContainer.class)` is recorded in a comment. `MergedAnnotations.from(T.class, strategy,
containers)` is `MergedAnnotations.from(descriptorOf!T, strategy, containers)`. In `testRepeatables`, the half that
checks the JDK's `getAnnotationsByType` (`testJavaRepeatables`) is dropped: D has no `@Repeatable`, so
`std.traits.getUDAs` returns the repeated UDAs as declared, without unwrapping a container. Every test waits behind
the `FlintAnnotationUtilsRepeatable` gate.
+/
module flint.core.merged_annotations_repeatable_test;

import flint.core.annotation : AliasFor;
import flint.core.annotation.types : MergedAnnotations, SearchStrategy;
import flint.engine.aot.descriptor : descriptorOf;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fixtures

private struct MyRepeatableContainer
{
    MyRepeatable[] value;
}

/// Java's `@Repeatable(MyRepeatableContainer.class)`.
private struct MyRepeatable
{
    string value;
}

@MyRepeatable("meta1")
private struct MyRepeatableMeta1
{
}

@MyRepeatable("meta2")
private struct MyRepeatableMeta2
{
}

/// `@MyRepeatableContainer({@MyRepeatable("B"), @MyRepeatable("C")})`.
private enum containerOfBAndC = MyRepeatableContainer([MyRepeatable("B"), MyRepeatable("C")]);

/// `@MyRepeatableContainer({@MyRepeatable("Y"), @MyRepeatable("Z")})`.
private enum containerOfYAndZ = MyRepeatableContainer([MyRepeatable("Y"), MyRepeatable("Z")]);

private interface InterfaceWithRepeated
{
    @MyRepeatable("A")
    @containerOfBAndC
    @MyRepeatableMeta1
    void foo();
}

@MyRepeatable("A")
@containerOfBAndC
@MyRepeatableMeta1
private class MyRepeatableClass
{
}

private class SubMyRepeatableClass : MyRepeatableClass
{
}

@MyRepeatable("X") @containerOfYAndZ @MyRepeatableMeta2
{
    private class SubMyRepeatableWithAdditionalLocalDeclarationsClass : MyRepeatableClass
    {
    }
}

private class SubSubMyRepeatableWithAdditionalLocalDeclarationsClass
    : SubMyRepeatableWithAdditionalLocalDeclarationsClass
{
}

private struct TestConfiguration
{
    @AliasFor(value: "location")
    string value = "";
    @AliasFor(value: "value")
    string location = "";
}

private struct Hierarchy
{
    TestConfiguration[] value;
}

@Hierarchy([TestConfiguration("A"), TestConfiguration(location: "B")])
private class HierarchyClass
{
}

// ---------------------------------------------------------------------------------------------------------------
// Tests

// MergedAnnotations has no repeatable-annotation support: no stream(A) of every merged A, no RepeatableContainers
// and no MergedAnnotationPredicates; repeated D UDAs are separate annotations (the first one of a type wins), not a
// container.
version (FlintAnnotationUtilsRepeatable)
{
    import flint.core.annotation.types : AnnotationFilter, MergedAnnotationPredicates, RepeatableContainers;
    import flint.engine.aot.descriptor : methodDescriptorOf;

    /// The `value` of each streamed annotation (`map(annotation -> annotation.getString("value"))`).
    private string[] valuesOf(R)(R annotations)
    {
        string[] values;
        foreach (annotation; annotations)
            values ~= annotation.synthesize().value;
        return values;
    }

    private void assertRepeatables(T)(SearchStrategy searchStrategy, string[] expectedValuesSpring)
    {
        assertExplicitRepeatables!T(searchStrategy, expectedValuesSpring);
        assertStandardRepeatables!T(searchStrategy, expectedValuesSpring);
    }

    private void assertExplicitRepeatables(T)(SearchStrategy searchStrategy, string[] expected)
    {
        const annotations = MergedAnnotations.from(descriptorOf!T, searchStrategy,
                RepeatableContainers.explicitRepeatable!(MyRepeatable, MyRepeatableContainer)());
        const values = valuesOf(MergedAnnotationPredicates.firstRunOfAggregateIndex(annotations.stream!MyRepeatable()));
        assert(values == expected, T.stringof);
    }

    private void assertStandardRepeatables(T)(SearchStrategy searchStrategy, string[] expected)
    {
        const values = valuesOf(MergedAnnotationPredicates.firstRunOfAggregateIndex(
                MergedAnnotations.from(descriptorOf!T, searchStrategy).stream!MyRepeatable()));
        assert(values == expected, T.stringof);
    }

    unittest
    {
        // streamRepeatableDeclaredOnMethod
        const annotations = MergedAnnotations.from(methodDescriptorOf!(InterfaceWithRepeated,
                "foo"), SearchStrategy.TYPE_HIERARCHY).stream!MyRepeatable();
        assert(valuesOf(annotations) == ["A", "B", "C", "meta1"]);
    }

    unittest
    {
        // streamRepeatableDeclaredOnClassWithAttributeAliases
        assert(MergedAnnotations.from(descriptorOf!HierarchyClass).stream!TestConfiguration().length == 0);
        const containers = RepeatableContainers.explicitRepeatable!(TestConfiguration, Hierarchy)();
        const annotations = MergedAnnotations.from(descriptorOf!HierarchyClass,
                SearchStrategy.DIRECT, containers, AnnotationFilter.NONE);
        string[] locations, values;
        foreach (annotation; annotations.stream!TestConfiguration())
        {
            locations ~= annotation.synthesize().location;
            values ~= annotation.synthesize().value;
        }
        assert(locations == ["A", "B"]);
        assert(values == ["A", "B"]);
    }

    unittest
    {
        // streamRepeatableDeclaredOnClass
        assertRepeatables!MyRepeatableClass(SearchStrategy.SUPERCLASS, ["A", "B", "C", "meta1"]);
    }

    unittest
    {
        // streamRepeatableDeclaredOnSuperclass
        assertRepeatables!SubMyRepeatableClass(SearchStrategy.SUPERCLASS, ["A", "B", "C", "meta1"]);
    }

    unittest
    {
        // streamRepeatableDeclaredOnClassAndSuperclass
        assertRepeatables!SubMyRepeatableWithAdditionalLocalDeclarationsClass(SearchStrategy.SUPERCLASS,
                ["X", "Y", "Z", "meta2"]);
    }

    unittest
    {
        // streamRepeatableDeclaredOnMultipleSuperclasses
        assertRepeatables!SubSubMyRepeatableWithAdditionalLocalDeclarationsClass(SearchStrategy.SUPERCLASS,
                ["X", "Y", "Z", "meta2"]);
    }

    unittest
    {
        // streamDirectRepeatablesDeclaredOnClass
        assertRepeatables!MyRepeatableClass(SearchStrategy.DIRECT, ["A", "B", "C", "meta1"]);
    }

    unittest
    {
        // streamDirectRepeatablesDeclaredOnSuperclass
        assertRepeatables!SubMyRepeatableClass(SearchStrategy.DIRECT, []);
    }
}
