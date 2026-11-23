// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core/annotation
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.core.annotation.MergedAnnotationsTests` (v7.1.0), part 2 of 5: the
method-level tests (`MergedAnnotations.from(Method, ...)`). One `unittest` per Java test method, each starting with
a `// <JavaTestName>` comment. See `core_merged_annotations_search_test.d` for the other parts.

Skipped Java tests (2), with reasons:
- getWithTypeHierarchyFromBridgeMethod, getFromMethodWithBridgeMethod: they look annotations up on the bridge
  method javac generates for a generic override (`isBridge()`); D generics are templates and have no bridge methods.
  The bridged (non-bridge) method is covered by getFromMethodWithBridgedMethod.

Adapted: Java annotations are D UDA structs. Flint has no reflection: `MergedAnnotations.from(method)` is
`MergedAnnotations.from` the merged table of the method's own UDAs (`mergedAnnotations!(__traits(getAttributes,
method))`), and Java's `method.getAnnotation(A.class) != null` is `std.traits.hasUDA`. A method's table holds only
its own UDAs, so the `SearchStrategy.TYPE_HIERARCHY` halves, which reach overridden and interface methods, wait
behind the `FlintAnnotationUtilsMethods` gate (inside the test when the direct half runs). Attribute lookups by
name (`getInt("value")`) read the field of the merged struct. `AnnotationsScannerTests.Hello2Impl` and
`TestAnnotation1` are local fixtures.
+/
module flint.core.merged_annotations_methods_test;

import flint.core.annotation : Order;
import flint.core.annotation.types : MergedAnnotations, SearchStrategy;
import flint.engine.aot.descriptor : mergedAnnotations;
import std.traits : hasUDA;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fixtures

/// Spring's `org.springframework.core.testfixture.stereotype.Indexed`.
private struct Indexed
{
}

/// Spring's `org.springframework.core.testfixture.stereotype.Component`.
@Indexed private struct Component
{
    string value;
}

private struct Transactional
{
    string value;
    string qualifier = "transactionManager";
    bool readOnly;
}

@Component("meta1") @Order private struct Meta1
{
}

@Component("meta2") @Transactional(readOnly : true) private struct Meta2
{
}

@Meta2 private struct MetaMeta
{
}

@Transactional private interface InterfaceWithInheritedAnnotation
{
    @Order void handleFromInterface();
}

private abstract class AbstractClassWithInheritedAnnotation(T) : InterfaceWithInheritedAnnotation
{
    @Transactional abstract void handle();

    @Transactional void handleParameterized(T t)
    {
    }
}

private class ConcreteClassWithInheritedAnnotation : AbstractClassWithInheritedAnnotation!string
{
    override void handle()
    {
    }

    override void handleParameterized(string s)
    {
    }

    void handleFromInterface()
    {
    }
}

/// `AnnotationsScannerTests.TestAnnotation1`.
private struct TestAnnotation1
{
}

/// `AnnotationsScannerTests.Hello1`.
private interface Hello1
{
    @TestAnnotation1 void method();
}

/// `AnnotationsScannerTests.Hello2`.
private interface Hello2 : Hello1
{
}

/// `AnnotationsScannerTests.Hello2Impl`.
private class Hello2Impl : Hello2
{
    void method()
    {
    }
}

private interface AnnotatedInterface
{
    @Order(0) void fromInterfaceImplementedByRoot();
}

private class Root : AnnotatedInterface
{
    @Order(27) void annotatedOnRoot()
    {
    }

    @Meta1 void metaAnnotatedOnRoot()
    {
    }

    void overrideToAnnotate()
    {
    }

    @Order(27) void overrideWithoutNewAnnotation()
    {
    }

    void notAnnotated()
    {
    }

    void fromInterfaceImplementedByRoot()
    {
    }
}

private class Leaf : Root
{
    @Order(25) void annotatedOnLeaf()
    {
    }

    @Meta1 void metaAnnotatedOnLeaf()
    {
    }

    @MetaMeta void metaMetaAnnotatedOnLeaf()
    {
    }

    @Order(1) override void overrideToAnnotate()
    {
    }

    override void overrideWithoutNewAnnotation()
    {
    }
}

private abstract class SimpleGeneric(T)
{
    @Order(1) abstract void something(T arg);
}

private class TransactionalStringGeneric : SimpleGeneric!string
{
    @Transactional override void something(string arg)
    {
    }
}

private interface InterfaceWithAnnotatedMethod
{
    @Order void foo();
}

private class ImplementsInterfaceWithAnnotatedMethod : InterfaceWithAnnotatedMethod
{
    void foo()
    {
    }
}

private class SubOfImplementsInterfaceWithAnnotatedMethod : ImplementsInterfaceWithAnnotatedMethod
{
    override void foo()
    {
    }
}

private abstract class AbstractDoesNotImplementInterfaceWithAnnotatedMethod : InterfaceWithAnnotatedMethod
{
}

private class SubOfAbstractImplementsInterfaceWithAnnotatedMethod : AbstractDoesNotImplementInterfaceWithAnnotatedMethod
{
    void foo()
    {
    }
}

private interface InterfaceWithGenericAnnotatedMethod(T)
{
    @Order void foo(T t);
}

private class ImplementsInterfaceWithGenericAnnotatedMethod : InterfaceWithGenericAnnotatedMethod!string
{
    void foo(string t)
    {
    }
}

private abstract class BaseClassWithGenericAnnotatedMethod(T)
{
    @Order abstract void foo(T t);
}

private class ExtendsBaseClassWithGenericAnnotatedMethod : BaseClassWithGenericAnnotatedMethod!string
{
    override void foo(string t)
    {
    }
}

private interface GenericInterface(A, B)
{
    @Transactional void processOneAndTwo(A value1, B value2);
}

private abstract class GenericAbstractSuperclass(C) : GenericInterface!(long, C)
{
    void processOneAndTwo(long value1, C value2)
    {
    }
}

private class GenericInterfaceImpl : GenericAbstractSuperclass!string
{
    // The compiler does not require us to declare a concrete
    // processOneAndTwo(long, string) method, and we intentionally
    // do not declare one here.
}

/// `MergedAnnotations.from(method)`: the merged table of the method's own UDAs.
private MergedAnnotations fromMethod(alias method)()
{
    return MergedAnnotations.from(mergedAnnotations!(__traits(getAttributes, method))());
}

// MergedAnnotations has no method lookup through overridden and interface methods: a method's table holds only its
// own UDAs, and Flint AOT method descriptors are not searched.
version (FlintAnnotationUtilsMethods)
{
    import flint.engine.aot.descriptor : methodDescriptorOf;

    /// `MergedAnnotations.from(T.class.getMethod(name), TYPE_HIERARCHY)`.
    private MergedAnnotations fromTypeHierarchy(T, string name)()
    {
        return MergedAnnotations.from(methodDescriptorOf!(T, name), SearchStrategy.TYPE_HIERARCHY);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Tests

version (FlintAnnotationUtilsMethods)
{
    unittest
    {
        // getWithTypeHierarchyInheritedFromInterfaceMethod
        alias Concrete = ConcreteClassWithInheritedAnnotation;
        const annotation = fromTypeHierarchy!(Concrete, "handleFromInterface")().get!Order();
        assert(annotation.isPresent());
        assert(annotation.getAggregateIndex() == 1);
    }

    unittest
    {
        // streamWithTypeHierarchyInheritedFromSuperInterfaceMethod
        const count = MergedAnnotations.search(SearchStrategy.TYPE_HIERARCHY)
            .from(methodDescriptorOf!(Hello2Impl, "method")).stream!TestAnnotation1().length;
        assert(count == 1);
    }

    unittest
    {
        // getWithTypeHierarchyInheritedFromAbstractMethod
        const annotation = fromTypeHierarchy!(ConcreteClassWithInheritedAnnotation, "handle")().get!Transactional();
        assert(annotation.isPresent());
        assert(annotation.getAggregateIndex() == 1);
    }

    unittest
    {
        // getWithTypeHierarchyInheritedFromBridgedMethod
        const annotation = fromTypeHierarchy!(ConcreteClassWithInheritedAnnotation, "handleParameterized")()
            .get!Transactional();
        assert(annotation.isPresent());
        assert(annotation.getAggregateIndex() == 1);
    }
}

unittest
{
    // getFromMethodWithMethodAnnotationOnLeaf
    assert(hasUDA!(Leaf.annotatedOnLeaf, Order));
    assert(fromMethod!(Leaf.annotatedOnLeaf)().get!Order().getDistance() == 0);
    version (FlintAnnotationUtilsMethods)
        assert(fromTypeHierarchy!(Leaf, "annotatedOnLeaf")().get!Order().getDistance() == 0);
}

unittest
{
    // getFromMethodWithAnnotationOnMethodInInterface
    assert(!hasUDA!(Leaf.fromInterfaceImplementedByRoot, Order));
    assert(fromMethod!(Leaf.fromInterfaceImplementedByRoot)().get!Order().getDistance() == -1);
    version (FlintAnnotationUtilsMethods)
        assert(fromTypeHierarchy!(Leaf, "fromInterfaceImplementedByRoot")().get!Order().getDistance() == 0);
}

unittest
{
    // getFromMethodWithMetaAnnotationOnLeaf
    assert(!hasUDA!(Leaf.metaAnnotatedOnLeaf, Order));
    assert(fromMethod!(Leaf.metaAnnotatedOnLeaf)().get!Order().getDistance() == 1);
    version (FlintAnnotationUtilsMethods)
        assert(fromTypeHierarchy!(Leaf, "metaAnnotatedOnLeaf")().get!Order().getDistance() == 1);
}

unittest
{
    // getFromMethodWithMetaMetaAnnotationOnLeaf
    assert(!hasUDA!(Leaf.metaMetaAnnotatedOnLeaf, Component));
    assert(fromMethod!(Leaf.metaMetaAnnotatedOnLeaf)().get!Component().getDistance() == 2);
    version (FlintAnnotationUtilsMethods)
        assert(fromTypeHierarchy!(Leaf, "metaMetaAnnotatedOnLeaf")().get!Component().getDistance() == 2);
}

unittest
{
    // getWithAnnotationOnRoot
    assert(hasUDA!(Leaf.annotatedOnRoot, Order));
    assert(fromMethod!(Leaf.annotatedOnRoot)().get!Order().getDistance() == 0);
    version (FlintAnnotationUtilsMethods)
        assert(fromTypeHierarchy!(Leaf, "annotatedOnRoot")().get!Order().getDistance() == 0);
}

unittest
{
    // getFromMethodWithMetaAnnotationOnRoot
    assert(!hasUDA!(Leaf.metaAnnotatedOnRoot, Order));
    assert(fromMethod!(Leaf.metaAnnotatedOnRoot)().get!Order().getDistance() == 1);
    version (FlintAnnotationUtilsMethods)
        assert(fromTypeHierarchy!(Leaf, "metaAnnotatedOnRoot")().get!Order().getDistance() == 1);
}

unittest
{
    // getFromMethodWithOnRootButOverridden
    assert(!hasUDA!(Leaf.overrideWithoutNewAnnotation, Order));
    assert(fromMethod!(Leaf.overrideWithoutNewAnnotation)().get!Order().getDistance() == -1);
    version (FlintAnnotationUtilsMethods)
        assert(fromTypeHierarchy!(Leaf, "overrideWithoutNewAnnotation")().get!Order().getDistance() == 0);
}

unittest
{
    // getFromMethodWithNotAnnotated
    assert(!hasUDA!(Leaf.notAnnotated, Order));
    assert(fromMethod!(Leaf.notAnnotated)().get!Order().getDistance() == -1);
    version (FlintAnnotationUtilsMethods)
        assert(fromTypeHierarchy!(Leaf, "notAnnotated")().get!Order().getDistance() == -1);
}

unittest
{
    // getFromMethodWithBridgedMethod
    alias method = TransactionalStringGeneric.something;
    assert(!hasUDA!(method, Order));
    assert(fromMethod!method().get!Order().getDistance() == -1);
    version (FlintAnnotationUtilsMethods)
        assert(fromTypeHierarchy!(TransactionalStringGeneric, "something")().get!Order().getDistance() == 0);
    assert(hasUDA!(method, Transactional));
    assert(fromMethod!method().get!Transactional().getDistance() == 0);
    version (FlintAnnotationUtilsMethods)
        assert(fromTypeHierarchy!(TransactionalStringGeneric, "something")().get!Transactional().getDistance() == 0);
}

version (FlintAnnotationUtilsMethods)
{
    unittest
    {
        // getFromMethodWithInterface
        assert(fromTypeHierarchy!(ImplementsInterfaceWithAnnotatedMethod, "foo")().get!Order().getDistance() == 0);
    }

    unittest
    {
        // getFromMethodWithGenericInterface
        assert(fromTypeHierarchy!(ImplementsInterfaceWithGenericAnnotatedMethod, "foo")()
                .get!Order().getDistance() == 0);
    }

    unittest
    {
        // getFromMethodWithGenericSuperclass
        assert(fromTypeHierarchy!(ExtendsBaseClassWithGenericAnnotatedMethod, "foo")().get!Order().getDistance() == 0);
    }

    unittest
    {
        // getFromMethodWithUnresolvedGenericsInGenericTypeHierarchy
        // The following method is GenericAbstractSuperclass.processOneAndTwo(long, C), where 'C' is a generic of
        // the superclass.
        assert(fromTypeHierarchy!(GenericInterfaceImpl, "processOneAndTwo")().get!Transactional().isDirectlyPresent());
    }

    unittest
    {
        // getFromMethodWithInterfaceOnSuper
        assert(fromTypeHierarchy!(SubOfImplementsInterfaceWithAnnotatedMethod, "foo")().get!Order().getDistance() == 0);
    }

    unittest
    {
        // getFromMethodWhenInterfaceWhenSuperDoesNotImplementMethod
        assert(fromTypeHierarchy!(SubOfAbstractImplementsInterfaceWithAnnotatedMethod, "foo")()
                .get!Order().getDistance() == 0);
    }

    unittest
    {
        // getValueFromAnnotation
        const annotation = fromTypeHierarchy!(TransactionalStringGeneric, "something")().get!Order();
        assert(annotation.synthesize().value == 1);
    }

    unittest
    {
        // getDefaultValueFromAnnotation
        import flint.core : Ordered;

        const annotation = fromTypeHierarchy!(TransactionalStringGeneric, "something")().get!Order();
        assert(annotation.getDefaultValue("value").get!int == Ordered.LOWEST_PRECEDENCE);
    }
}
