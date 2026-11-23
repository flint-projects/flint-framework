// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core/annotation
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.core.annotation.AnnotationUtilsTests` (v7.1.0): one `unittest` per
Java test method, each starting with a `// <JavaTestName>` comment.

Skipped Java tests (9), with reasons:
- findMethodAnnotationOnBridgeMethod: it looks annotations up on the bridge method javac generates for
  `SimpleFoo.something(Object)` (`isBridge()`); D generics are templates and have no bridge methods.
- isAnnotationMetaPresentForPlainType: it checks that `@Order` is meta-annotated with
  `java.lang.annotation.Documented`; Flint's `@Order` is a plain UDA struct without JDK meta-annotations.
- getValueFromNonPublicAnnotation, getDefaultValueFromNonPublicAnnotation: they read a package-private annotation
  type of another package through reflection (`getDeclaredAnnotations()`); D UDAs are read at compile time, where
  visibility is checked by the compiler.
- findRepeatableAnnotation: it finds the JDK's `java.lang.annotation.Repeatable` meta-annotation; D has no
  `@Repeatable` (repeated UDAs are simply repeated).
- synthesizeAnnotationWithImplicitAliasesWithMissingDefaultValues, synthesizeAnnotationFromMapWithMissingAttributeValue,
  synthesizeAnnotationFromMapWithNullAttributeValue: they need annotation attributes without a default value;
  every D struct field has one (`T.init`).
- findDeprecatedAnnotation: `java.lang.Deprecated` is an annotation; D's `deprecated` is a storage class, not a UDA.

Adapted: Java annotations are D UDA structs (`@AliasFor` with named arguments); `@Retention`, `@Target` and
`@Inherited` have no D counterpart and are dropped. Flint has no reflection: `AnnotationUtils` reads the merged
annotations of a type's Flint AOT descriptor (`descriptorOf!T`), and `findAnnotation(T.class, A.class)` is
`findAnnotation!(A, T)(found)`, with `found` false where Java returns null. Java's own reflection
(`Class.getAnnotation`, `Method.getAnnotation`) is `std.traits.getUDAs`/`hasUDA`. Spring's
`org.springframework.core.testfixture.stereotype.Component` is a local `Component` UDA. In the repeatable
annotation tests, the halves that check the JDK's `getAnnotationsByType` (marked `// Java`) are dropped. Cases
that need unported features, or where the port behaves differently, wait behind version gates.
+/
module flint.core.annotation_utils_test;

import flint.core.annotation : AliasFor, ClassRef, classOf, Order;
import flint.core.annotation.types : AnnotationUtils;
import flint.engine.aot.descriptor : descriptorOf;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fixtures

/// Spring's `org.springframework.core.testfixture.stereotype.Component`.
private struct Component
{
    string value;
}

private struct Transactional
{
    bool readOnly;
}

@Component("meta1") @Order private struct Meta1
{
}

@Component("meta2") @Transactional(true) private struct Meta2
{
}

@Meta2 private struct MetaMeta
{
}

@MetaMeta private struct MetaMetaMeta
{
}

@MetaCycle3 private struct MetaCycle1
{
}

@MetaCycle1 private struct MetaCycle2
{
}

@MetaCycle2 private struct MetaCycle3
{
}

@Meta1 private interface InterfaceWithMetaAnnotation
{
}

@Meta2 private class ClassWithLocalMetaAnnotationAndMetaAnnotatedInterface : InterfaceWithMetaAnnotation
{
}

@Meta1 private class ClassWithInheritedMetaAnnotation
{
}

@Meta2 private class SubClassWithInheritedMetaAnnotation : ClassWithInheritedMetaAnnotation
{
}

private class SubSubClassWithInheritedMetaAnnotation : SubClassWithInheritedMetaAnnotation
{
}

@Transactional private class ClassWithInheritedAnnotation
{
}

@Meta2 private class SubClassWithInheritedAnnotation : ClassWithInheritedAnnotation
{
}

private class SubSubClassWithInheritedAnnotation : SubClassWithInheritedAnnotation
{
}

@MetaMeta private class MetaMetaAnnotatedClass
{
}

@MetaMetaMeta private class MetaMetaMetaAnnotatedClass
{
}

@MetaCycle3 private class MetaCycleAnnotatedClass
{
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

private abstract class Foo(T)
{
    @Order(1) abstract void something(T arg);
}

private class SimpleFoo : Foo!string
{
    @Transactional override void something(string arg)
    {
    }
}

@Transactional private interface InheritedAnnotationInterface
{
}

private interface SubInheritedAnnotationInterface : InheritedAnnotationInterface
{
}

private interface SubSubInheritedAnnotationInterface : SubInheritedAnnotationInterface
{
}

@Order private interface NonInheritedAnnotationInterface
{
}

private interface SubNonInheritedAnnotationInterface : NonInheritedAnnotationInterface
{
}

private interface SubSubNonInheritedAnnotationInterface : SubNonInheritedAnnotationInterface
{
}

private class NonAnnotatedClass
{
}

private interface NonAnnotatedInterface
{
}

@Transactional private class InheritedAnnotationClass
{
}

private class SubInheritedAnnotationClass : InheritedAnnotationClass
{
}

@Order private class NonInheritedAnnotationClass
{
}

private class SubNonInheritedAnnotationClass : NonInheritedAnnotationClass
{
}

@Transactional private class TransactionalClass
{
}

@Order private class TransactionalAndOrderedClass : TransactionalClass
{
}

private class SubTransactionalAndOrderedClass : TransactionalAndOrderedClass
{
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

private struct MyRepeatableContainer
{
    MyRepeatable[] value;
}

/// Java's `@Repeatable(MyRepeatableContainer.class)`.
private struct MyRepeatable
{
    string value;
}

@MyRepeatable("meta1") private struct MyRepeatableMeta1
{
}

@MyRepeatable("meta2") private struct MyRepeatableMeta2
{
}

@MyRepeatable("meta1") @MyRepeatable("meta2") private struct MyRepeatableMeta1And2
{
}

@MyRepeatableMeta1And2 private void methodWithComposedAnnotationMetaAnnotatedWithRepeatableAnnotations()
{
}

/// `@MyRepeatableContainer({@MyRepeatable("B"), @MyRepeatable("C")})`.
private enum containerOfBAndC = MyRepeatableContainer([MyRepeatable("B"), MyRepeatable("C")]);

/// `@MyRepeatableContainer({@MyRepeatable("Y"), @MyRepeatable("Z")})`.
private enum containerOfYAndZ = MyRepeatableContainer([MyRepeatable("Y"), MyRepeatable("Z")]);

private interface InterfaceWithRepeated
{
    @MyRepeatable("A") @containerOfBAndC @MyRepeatableMeta1 void foo();
}

@MyRepeatable("A") @containerOfBAndC @MyRepeatableMeta1 private class MyRepeatableClass
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

private enum RequestMethod
{
    GET,
    POST
}

private struct WebMapping
{
    string name;
    @AliasFor(value : "path") string[] value = [""];
    @AliasFor(attribute : "value") string[] path = [""];
    RequestMethod[] method;
}

@WebMapping(method : [RequestMethod.GET], name:
        "") private struct Get
{
    @AliasFor(annotation : classOf!WebMapping) string value = "";
    @AliasFor(annotation : classOf!WebMapping) string path = "";
}

@Component("webController") private class WebController
{
    @WebMapping(value : ["/test"], name:
            "foo") void handleMappedWithValueAttribute()
    {
    }

    @WebMapping(path : ["/test"], name:
            "bar", method:
            [RequestMethod.GET, RequestMethod.POST])
    void handleMappedWithPathAttribute()
    {
    }

    @WebMapping(value : ["/enigma"], path:
            ["/test"], name:
            "baz")
    void handleMappedWithDifferentPathAndValueAttributes()
    {
    }
}

private struct ContextConfig
{
    @AliasFor(value : "location") string value = "";
    @AliasFor(value : "value") string location = "";
    ClassRef klass = classOf!Object;
}

private struct Hierarchy
{
    ContextConfig[] value;
}

@Hierarchy([ContextConfig("A"), ContextConfig(location: "B")]) private class ConfigHierarchyTestCase
{
}

private struct CharsContainer
{
    @AliasFor(attribute : "chars") const(char)[] value;
    @AliasFor(attribute : "value") const(char)[] chars;
}

@ContextConfig private struct ImplicitAliasesContextConfig
{
    @AliasFor(annotation : classOf!ContextConfig, attribute:
            "location") string xmlFile = "";
    @AliasFor(annotation : classOf!ContextConfig, attribute:
            "location") string groovyScript = "";
    @AliasFor(annotation : classOf!ContextConfig, attribute:
            "location") string value = "";
    @AliasFor(annotation : classOf!ContextConfig, attribute:
            "location") string location1 = "";
    @AliasFor(annotation : classOf!ContextConfig, attribute:
            "location") string location2 = "";
    @AliasFor(annotation : classOf!ContextConfig, attribute:
            "location") string location3 = "";
    @AliasFor(annotation : classOf!ContextConfig, attribute:
            "klass") ClassRef configClass = classOf!Object;
    string nonAliasedAttribute = "";
}

@ContextConfig private struct ImplicitAliasesWithDifferentDefaultValuesContextConfig
{
    @AliasFor(annotation : classOf!ContextConfig, attribute:
            "location") string location1 = "foo";
    @AliasFor(annotation : classOf!ContextConfig, attribute:
            "location") string location2 = "bar";
}

@ImplicitAliasesWithDifferentDefaultValuesContextConfig(location1 : "1", location2:
        "2")
private class ImplicitAliasesWithDifferentDefaultValuesContextConfigClass
{
}

@ContextConfig private struct ImplicitAliasesWithDuplicateValuesContextConfig
{
    @AliasFor(annotation : classOf!ContextConfig, attribute:
            "location") string location1 = "";
    @AliasFor(annotation : classOf!ContextConfig, attribute:
            "location") string location2 = "";
}

@ImplicitAliasesWithDuplicateValuesContextConfig(location1 : "1", location2:
        "2")
private class ImplicitAliasesWithDuplicateValuesContextConfigClass
{
}

private struct Filter
{
    string pattern;
}

private struct ComponentScan
{
    Filter[] excludeFilters;
}

@ComponentScan(excludeFilters : [Filter(pattern: "*Foo"), Filter(pattern: "*Bar")]) private class ComponentScanClass
{
}

private struct ComponentScanSingleFilter
{
    Filter value;
}

@ComponentScanSingleFilter(Filter(pattern: "*Foo")) private class ComponentScanSingleFilterClass
{
}

private struct AnnotationWithDefaults
{
    string text = "enigma";
    bool predicate = true;
    const(char)[] characters = ['a', 'b', 'c'];
}

/// Java's `@Repeatable(TestRepeatableContainer.class)`.
private struct TestRepeatable
{
    string value;
}

private struct TestRepeatableContainer
{
    TestRepeatable[] value;
}

@TestRepeatable("a") @TestRepeatable("b") private class TestRepeatablesClass
{
}

/// `AnnotationUtils.findAnnotation(T.class, A.class)`; `found` is false where Java returns null.
private const(A) findAnnotation(A, T)(out bool found)
{
    return AnnotationUtils.findAnnotation!A(descriptorOf!T, found);
}

/// `AnnotationUtils.isAnnotationDeclaredLocally(A.class, T.class)`.
private bool isAnnotationDeclaredLocally(A, T)()
{
    return AnnotationUtils.isAnnotationDeclaredLocally!A(descriptorOf!T);
}

/// The `value` of each repeatable annotation (`stream().map(MyRepeatable::value)`).
private string[] valuesOf(A)(const(A)[] annotations)
{
    string[] values;
    foreach (annotation; annotations)
        values ~= annotation.value;
    return values;
}

// ---------------------------------------------------------------------------------------------------------------
// Tests

// AnnotationUtils has no method-level lookups: findAnnotation, getAnnotation and getRepeatableAnnotations take only
// a type's descriptor, and Flint AOT method descriptors are not searched through overridden and interface methods.
version (FlintAnnotationUtilsMethods)
{
    import flint.engine.aot.descriptor : methodDescriptorOf;
    import std.traits : hasUDA;

    /// `T.class.getMethod(name).getAnnotation(A.class) != null`: declared on the method itself.
    private bool declaredOnMethod(A, T, string name)()
    {
        return hasUDA!(__traits(getMember, T, name), A);
    }

    /// `AnnotationUtils.getAnnotation(T.class.getMethod(name), A.class) != null`.
    private bool getAnnotationOnMethod(A, T, string name)()
    {
        bool found;
        AnnotationUtils.getAnnotation!A(methodDescriptorOf!(T, name), found);
        return found;
    }

    /// `AnnotationUtils.findAnnotation(T.class.getMethod(name), A.class)`; `found` is false for Java's null.
    private const(A) findAnnotationOnMethod(A, T, string name)(out bool found)
    {
        return AnnotationUtils.findAnnotation!A(methodDescriptorOf!(T, name), found);
    }

    private bool findsAnnotationOnMethod(A, T, string name)()
    {
        bool found;
        findAnnotationOnMethod!(A, T, name)(found);
        return found;
    }

    unittest
    {
        // findMethodAnnotationOnLeaf
        assert(declaredOnMethod!(Order, Leaf, "annotatedOnLeaf"));
        assert(getAnnotationOnMethod!(Order, Leaf, "annotatedOnLeaf"));
        assert(findsAnnotationOnMethod!(Order, Leaf, "annotatedOnLeaf"));
    }

    unittest
    {
        // findMethodAnnotationWithAnnotationOnMethodInInterface
        // @Order is not @Inherited
        assert(!declaredOnMethod!(Order, Leaf, "fromInterfaceImplementedByRoot"));
        // getAnnotation() does not search on interfaces
        assert(!getAnnotationOnMethod!(Order, Leaf, "fromInterfaceImplementedByRoot"));
        // findAnnotation() does search on interfaces
        assert(findsAnnotationOnMethod!(Order, Leaf, "fromInterfaceImplementedByRoot"));
    }

    unittest
    {
        // findMethodAnnotationWithMetaAnnotationOnLeaf
        assert(!declaredOnMethod!(Order, Leaf, "metaAnnotatedOnLeaf"));
        assert(getAnnotationOnMethod!(Order, Leaf, "metaAnnotatedOnLeaf"));
        assert(findsAnnotationOnMethod!(Order, Leaf, "metaAnnotatedOnLeaf"));
    }

    unittest
    {
        // findMethodAnnotationWithMetaMetaAnnotationOnLeaf
        assert(!declaredOnMethod!(Component, Leaf, "metaMetaAnnotatedOnLeaf"));
        assert(!getAnnotationOnMethod!(Component, Leaf, "metaMetaAnnotatedOnLeaf"));
        assert(findsAnnotationOnMethod!(Component, Leaf, "metaMetaAnnotatedOnLeaf"));
    }

    unittest
    {
        // findMethodAnnotationOnRoot
        assert(declaredOnMethod!(Order, Leaf, "annotatedOnRoot"));
        assert(getAnnotationOnMethod!(Order, Leaf, "annotatedOnRoot"));
        assert(findsAnnotationOnMethod!(Order, Leaf, "annotatedOnRoot"));
    }

    unittest
    {
        // findMethodAnnotationWithMetaAnnotationOnRoot
        assert(!declaredOnMethod!(Order, Leaf, "metaAnnotatedOnRoot"));
        assert(getAnnotationOnMethod!(Order, Leaf, "metaAnnotatedOnRoot"));
        assert(findsAnnotationOnMethod!(Order, Leaf, "metaAnnotatedOnRoot"));
    }

    unittest
    {
        // findMethodAnnotationOnRootButOverridden
        assert(!declaredOnMethod!(Order, Leaf, "overrideWithoutNewAnnotation"));
        assert(!getAnnotationOnMethod!(Order, Leaf, "overrideWithoutNewAnnotation"));
        assert(findsAnnotationOnMethod!(Order, Leaf, "overrideWithoutNewAnnotation"));
    }

    unittest
    {
        // findMethodAnnotationNotAnnotated
        assert(!findsAnnotationOnMethod!(Order, Leaf, "notAnnotated"));
    }

    unittest
    {
        // findMethodAnnotationOnBridgedMethod
        assert(!declaredOnMethod!(Order, SimpleFoo, "something"));
        assert(!getAnnotationOnMethod!(Order, SimpleFoo, "something"));
        assert(findsAnnotationOnMethod!(Order, SimpleFoo, "something"));

        assert(declaredOnMethod!(Transactional, SimpleFoo, "something"));
        assert(getAnnotationOnMethod!(Transactional, SimpleFoo, "something"));
        assert(findsAnnotationOnMethod!(Transactional, SimpleFoo, "something"));
    }

    unittest
    {
        // findMethodAnnotationFromInterface
        assert(findsAnnotationOnMethod!(Order, ImplementsInterfaceWithAnnotatedMethod, "foo"));
    }

    unittest
    {
        // findMethodAnnotationFromGenericInterface
        assert(findsAnnotationOnMethod!(Order, ImplementsInterfaceWithGenericAnnotatedMethod, "foo"));
    }

    unittest
    {
        // findMethodAnnotationFromGenericSuperclass
        assert(findsAnnotationOnMethod!(Order, ExtendsBaseClassWithGenericAnnotatedMethod, "foo"));
    }

    unittest
    {
        // findMethodAnnotationFromInterfaceOnSuper
        assert(findsAnnotationOnMethod!(Order, SubOfImplementsInterfaceWithAnnotatedMethod, "foo"));
    }

    unittest
    {
        // findMethodAnnotationFromInterfaceWhenSuperDoesNotImplementMethod
        assert(findsAnnotationOnMethod!(Order, SubOfAbstractImplementsInterfaceWithAnnotatedMethod, "foo"));
    }
}

unittest
{
    // findClassAnnotationFavorsMoreLocallyDeclaredComposedAnnotationsOverAnnotationsOnInterfaces
    bool found;
    const component = findAnnotation!(Component, ClassWithLocalMetaAnnotationAndMetaAnnotatedInterface)(found);
    assert(found);
    assert(component.value == "meta2");
}

unittest
{
    // findClassAnnotationFavorsMoreLocallyDeclaredComposedAnnotationsOverInheritedAnnotations
    bool found;
    const transactional = findAnnotation!(Transactional, SubSubClassWithInheritedAnnotation)(found);
    assert(found);
    assert(transactional.readOnly, "readOnly flag for SubSubClassWithInheritedAnnotation");
}

unittest
{
    // findClassAnnotationFavorsMoreLocallyDeclaredComposedAnnotationsOverInheritedComposedAnnotations
    bool found;
    const component = findAnnotation!(Component, SubSubClassWithInheritedMetaAnnotation)(found);
    assert(found);
    assert(component.value == "meta2");
}

unittest
{
    // findClassAnnotationOnMetaMetaAnnotatedClass
    bool found;
    const component = findAnnotation!(Component, MetaMetaAnnotatedClass)(found);
    assert(found, "Should find meta-annotation on composed annotation on class");
    assert(component.value == "meta2");
}

unittest
{
    // findClassAnnotationOnMetaMetaMetaAnnotatedClass
    bool found;
    const component = findAnnotation!(Component, MetaMetaMetaAnnotatedClass)(found);
    assert(found, "Should find meta-annotation on meta-annotation on composed annotation on class");
    assert(component.value == "meta2");
}

unittest
{
    // findClassAnnotationOnAnnotatedClassWithMissingTargetMetaAnnotation
    // TransactionalClass is NOT annotated or meta-annotated with @Component
    bool found;
    findAnnotation!(Component, TransactionalClass)(found);
    assert(!found, "Should not find @Component on TransactionalClass");
}

unittest
{
    // findClassAnnotationOnMetaCycleAnnotatedClassWithMissingTargetMetaAnnotation
    bool found;
    findAnnotation!(Component, MetaCycleAnnotatedClass)(found);
    assert(!found, "Should not find @Component on MetaCycleAnnotatedClass");
}

unittest
{
    // findClassAnnotationOnInheritedAnnotationInterface
    bool found;
    findAnnotation!(Transactional, InheritedAnnotationInterface)(found);
    assert(found, "Should find @Transactional on InheritedAnnotationInterface");
}

unittest
{
    // findClassAnnotationOnSubInheritedAnnotationInterface
    bool found;
    findAnnotation!(Transactional, SubInheritedAnnotationInterface)(found);
    assert(found, "Should find @Transactional on SubInheritedAnnotationInterface");
}

unittest
{
    // findClassAnnotationOnSubSubInheritedAnnotationInterface
    bool found;
    findAnnotation!(Transactional, SubSubInheritedAnnotationInterface)(found);
    assert(found, "Should find @Transactional on SubSubInheritedAnnotationInterface");
}

unittest
{
    // findClassAnnotationOnNonInheritedAnnotationInterface
    bool found;
    findAnnotation!(Order, NonInheritedAnnotationInterface)(found);
    assert(found, "Should find @Order on NonInheritedAnnotationInterface");
}

unittest
{
    // findClassAnnotationOnSubNonInheritedAnnotationInterface
    bool found;
    findAnnotation!(Order, SubNonInheritedAnnotationInterface)(found);
    assert(found, "Should find @Order on SubNonInheritedAnnotationInterface");
}

unittest
{
    // findClassAnnotationOnSubSubNonInheritedAnnotationInterface
    bool found;
    findAnnotation!(Order, SubSubNonInheritedAnnotationInterface)(found);
    assert(found, "Should find @Order on SubSubNonInheritedAnnotationInterface");
}

// AnnotationUtils has no findAnnotationDeclaringClass, findAnnotationDeclaringClassForTypes or
// isAnnotationInherited.
version (FlintAnnotationUtilsDeclaringClass)
{
    import flint.engine.aot.name : typeNameOf;

    /// `findAnnotationDeclaringClass(A.class, T.class)`: the declaring type's name, null for none.
    private string findAnnotationDeclaringClass(A, T)()
    {
        return AnnotationUtils.findAnnotationDeclaringClass!A(descriptorOf!T);
    }

    /// `findAnnotationDeclaringClassForTypes(candidates, T.class)`.
    private string findAnnotationDeclaringClassForTypes(T)(string[] candidates)
    {
        return AnnotationUtils.findAnnotationDeclaringClassForTypes(candidates, descriptorOf!T);
    }

    /// `isAnnotationInherited(A.class, T.class)`.
    private bool isAnnotationInherited(A, T)()
    {
        return AnnotationUtils.isAnnotationInherited!A(descriptorOf!T);
    }

    unittest
    {
        // findAnnotationDeclaringClassForAllScenarios
        // no class-level annotation
        assert(findAnnotationDeclaringClass!(Transactional, NonAnnotatedInterface)() is null);
        assert(findAnnotationDeclaringClass!(Transactional, NonAnnotatedClass)() is null);

        // inherited class-level annotation; note: @Transactional is inherited
        assert(findAnnotationDeclaringClass!(Transactional,
                InheritedAnnotationInterface)() == typeNameOf!InheritedAnnotationInterface);
        assert(findAnnotationDeclaringClass!(Transactional, SubInheritedAnnotationInterface)() is null);
        assert(findAnnotationDeclaringClass!(Transactional,
                InheritedAnnotationClass)() == typeNameOf!InheritedAnnotationClass);
        assert(findAnnotationDeclaringClass!(Transactional,
                SubInheritedAnnotationClass)() == typeNameOf!InheritedAnnotationClass);

        // non-inherited class-level annotation; note: @Order is not inherited,
        // but findAnnotationDeclaringClass() should still find it on classes.
        assert(findAnnotationDeclaringClass!(Order,
                NonInheritedAnnotationInterface)() == typeNameOf!NonInheritedAnnotationInterface);
        assert(findAnnotationDeclaringClass!(Order, SubNonInheritedAnnotationInterface)() is null);
        assert(findAnnotationDeclaringClass!(Order,
                NonInheritedAnnotationClass)() == typeNameOf!NonInheritedAnnotationClass);
        assert(findAnnotationDeclaringClass!(Order,
                SubNonInheritedAnnotationClass)() == typeNameOf!NonInheritedAnnotationClass);
    }

    unittest
    {
        // findAnnotationDeclaringClassForTypesWithSingleCandidateType
        // no class-level annotation
        const transactionalCandidates = [typeNameOf!Transactional];
        assert(findAnnotationDeclaringClassForTypes!NonAnnotatedInterface(transactionalCandidates) is null);
        assert(findAnnotationDeclaringClassForTypes!NonAnnotatedClass(transactionalCandidates) is null);

        // inherited class-level annotation; note: @Transactional is inherited
        assert(findAnnotationDeclaringClassForTypes!InheritedAnnotationInterface(
                transactionalCandidates) == typeNameOf!InheritedAnnotationInterface);
        assert(findAnnotationDeclaringClassForTypes!SubInheritedAnnotationInterface(transactionalCandidates) is null);
        assert(findAnnotationDeclaringClassForTypes!InheritedAnnotationClass(
                transactionalCandidates) == typeNameOf!InheritedAnnotationClass);
        assert(findAnnotationDeclaringClassForTypes!SubInheritedAnnotationClass(
                transactionalCandidates) == typeNameOf!InheritedAnnotationClass);

        // non-inherited class-level annotation; note: @Order is not inherited,
        // but findAnnotationDeclaringClassForTypes() should still find it on classes.
        const orderCandidates = [typeNameOf!Order];
        assert(findAnnotationDeclaringClassForTypes!NonInheritedAnnotationInterface(
                orderCandidates) == typeNameOf!NonInheritedAnnotationInterface);
        assert(findAnnotationDeclaringClassForTypes!SubNonInheritedAnnotationInterface(orderCandidates) is null);
        assert(findAnnotationDeclaringClassForTypes!NonInheritedAnnotationClass(
                orderCandidates) == typeNameOf!NonInheritedAnnotationClass);
        assert(findAnnotationDeclaringClassForTypes!SubNonInheritedAnnotationClass(
                orderCandidates) == typeNameOf!NonInheritedAnnotationClass);
    }

    unittest
    {
        // findAnnotationDeclaringClassForTypesWithMultipleCandidateTypes
        const candidates = [typeNameOf!Transactional, typeNameOf!Order];

        // no class-level annotation
        assert(findAnnotationDeclaringClassForTypes!NonAnnotatedInterface(candidates) is null);
        assert(findAnnotationDeclaringClassForTypes!NonAnnotatedClass(candidates) is null);

        // inherited class-level annotation; note: @Transactional is inherited
        assert(findAnnotationDeclaringClassForTypes!InheritedAnnotationInterface(
                candidates) == typeNameOf!InheritedAnnotationInterface);
        assert(findAnnotationDeclaringClassForTypes!SubInheritedAnnotationInterface(candidates) is null);
        assert(findAnnotationDeclaringClassForTypes!InheritedAnnotationClass(
                candidates) == typeNameOf!InheritedAnnotationClass);
        assert(findAnnotationDeclaringClassForTypes!SubInheritedAnnotationClass(
                candidates) == typeNameOf!InheritedAnnotationClass);

        // non-inherited class-level annotation; note: @Order is not inherited,
        // but findAnnotationDeclaringClassForTypes() should still find it on classes.
        assert(findAnnotationDeclaringClassForTypes!NonInheritedAnnotationInterface(
                candidates) == typeNameOf!NonInheritedAnnotationInterface);
        assert(findAnnotationDeclaringClassForTypes!SubNonInheritedAnnotationInterface(candidates) is null);
        assert(findAnnotationDeclaringClassForTypes!NonInheritedAnnotationClass(
                candidates) == typeNameOf!NonInheritedAnnotationClass);
        assert(findAnnotationDeclaringClassForTypes!SubNonInheritedAnnotationClass(
                candidates) == typeNameOf!NonInheritedAnnotationClass);

        // class hierarchy mixed with @Transactional and @Order declarations
        assert(findAnnotationDeclaringClassForTypes!TransactionalClass(candidates) == typeNameOf!TransactionalClass);
        assert(findAnnotationDeclaringClassForTypes!TransactionalAndOrderedClass(
                candidates) == typeNameOf!TransactionalAndOrderedClass);
        assert(findAnnotationDeclaringClassForTypes!SubTransactionalAndOrderedClass(
                candidates) == typeNameOf!TransactionalAndOrderedClass);
    }
}

unittest
{
    // isAnnotationDeclaredLocallyForAllScenarios
    // no class-level annotation
    assert(!isAnnotationDeclaredLocally!(Transactional, NonAnnotatedInterface)());
    assert(!isAnnotationDeclaredLocally!(Transactional, NonAnnotatedClass)());

    // inherited class-level annotation; note: @Transactional is inherited
    assert(isAnnotationDeclaredLocally!(Transactional, InheritedAnnotationInterface)());
    assert(!isAnnotationDeclaredLocally!(Transactional, SubInheritedAnnotationInterface)());
    assert(isAnnotationDeclaredLocally!(Transactional, InheritedAnnotationClass)());
    assert(!isAnnotationDeclaredLocally!(Transactional, SubInheritedAnnotationClass)());

    // non-inherited class-level annotation; note: @Order is not inherited
    assert(isAnnotationDeclaredLocally!(Order, NonInheritedAnnotationInterface)());
    assert(!isAnnotationDeclaredLocally!(Order, SubNonInheritedAnnotationInterface)());
    assert(isAnnotationDeclaredLocally!(Order, NonInheritedAnnotationClass)());
    assert(!isAnnotationDeclaredLocally!(Order, SubNonInheritedAnnotationClass)());
}

version (FlintAnnotationUtilsDeclaringClass)
{
    unittest
    {
        // isAnnotationInheritedForAllScenarios
        // no class-level annotation
        assert(!isAnnotationInherited!(Transactional, NonAnnotatedInterface)());
        assert(!isAnnotationInherited!(Transactional, NonAnnotatedClass)());

        // inherited class-level annotation; note: @Transactional is inherited
        assert(!isAnnotationInherited!(Transactional, InheritedAnnotationInterface)());
        // isAnnotationInherited() does not currently traverse interface hierarchies.
        // Thus the following, though perhaps counterintuitive, must be false:
        assert(!isAnnotationInherited!(Transactional, SubInheritedAnnotationInterface)());
        assert(!isAnnotationInherited!(Transactional, InheritedAnnotationClass)());
        assert(isAnnotationInherited!(Transactional, SubInheritedAnnotationClass)());

        // non-inherited class-level annotation; note: @Order is not inherited
        assert(!isAnnotationInherited!(Order, NonInheritedAnnotationInterface)());
        assert(!isAnnotationInherited!(Order, SubNonInheritedAnnotationInterface)());
        assert(!isAnnotationInherited!(Order, NonInheritedAnnotationClass)());
        assert(!isAnnotationInherited!(Order, SubNonInheritedAnnotationClass)());
    }
}

// AnnotationUtils has no AnnotationAttributes: no getAnnotationAttributes, getValue, getDefaultValue or
// synthesizeAnnotation (from an annotation, a map or defaults), and no @AliasFor validation at run time.
version (FlintAnnotationUtilsAttributes)
{
    import flint.core.annotation.types : AnnotationAttributes, AnnotationConfigurationException;
    import flint.core : Ordered;
    import flint.engine.aot.any : Any;
    import flint.engine.aot.name : typeNameOf;
    import flint.java.lang : IllegalStateException;
    import flint.java.util : LinkedHashMap, Map;
    import flint.util.test_support : contains, expectThrows;
    import std.traits : getUDAs;

    private alias VALUE = AnnotationUtils.VALUE;

    /// Java's `Collections.singletonMap(key, value)`.
    private Map!(string, Any) singletonMap(string key, Any value)
    {
        auto map = new LinkedHashMap!(string, Any)();
        map.put(key, value);
        return map;
    }

    private string[] patternsOf(const(Filter)[] filters)
    {
        string[] patterns;
        foreach (filter; filters)
            patterns ~= filter.pattern;
        return patterns;
    }

    unittest
    {
        // getAnnotationAttributesWithoutAttributeAliases
        const component = getUDAs!(WebController, Component)[0];

        auto attributes = AnnotationUtils.getAnnotationAttributes(component);
        assert(attributes !is null);
        assert(attributes.getString(VALUE) == "webController", "value attribute: ");
        assert(attributes.annotationType() == typeNameOf!Component);
    }

    unittest
    {
        // getAnnotationAttributesWithNestedAnnotations
        const componentScan = getUDAs!(ComponentScanClass, ComponentScan)[0];

        auto attributes = AnnotationUtils.getAnnotationAttributes(typeNameOf!ComponentScanClass, componentScan);
        assert(attributes !is null);
        assert(attributes.annotationType() == typeNameOf!ComponentScan);

        const filters = attributes.getAnnotationArray!Filter("excludeFilters");
        assert(filters !is null);
        assert(patternsOf(filters) == ["*Foo", "*Bar"]);
    }

    unittest
    {
        // getAnnotationAttributesWithAttributeAliases
        auto webMapping = getUDAs!(WebController.handleMappedWithValueAttribute, WebMapping)[0];
        auto attributes = AnnotationUtils.getAnnotationAttributes(webMapping);
        assert(attributes !is null);
        assert(attributes.annotationType() == typeNameOf!WebMapping);
        assert(attributes.getString("name") == "foo", "name attribute: ");
        assert(attributes.getStringArray(VALUE) == ["/test"], "value attribute: ");
        assert(attributes.getStringArray("path") == ["/test"], "path attribute: ");

        webMapping = getUDAs!(WebController.handleMappedWithPathAttribute, WebMapping)[0];
        attributes = AnnotationUtils.getAnnotationAttributes(webMapping);
        assert(attributes !is null);
        assert(attributes.annotationType() == typeNameOf!WebMapping);
        assert(attributes.getString("name") == "bar", "name attribute: ");
        assert(attributes.getStringArray(VALUE) == ["/test"], "value attribute: ");
        assert(attributes.getStringArray("path") == ["/test"], "path attribute: ");
    }

    unittest
    {
        // getAnnotationAttributesWithAttributeAliasesWithDifferentValues
        const webMapping = getUDAs!(WebController.handleMappedWithDifferentPathAndValueAttributes, WebMapping)[0];
        const e = expectThrows!AnnotationConfigurationException(() {
            AnnotationUtils.getAnnotationAttributes(webMapping);
        });
        assert(e.msg.contains("attribute 'path' and its alias 'value'"));
        assert(e.msg.contains("values of [{/test}] and [{/enigma}]"));
    }

    unittest
    {
        // getDefaultValueFromAnnotationType
        assert(AnnotationUtils.getDefaultValue!Order(VALUE).get!int == Ordered.LOWEST_PRECEDENCE);
        assert(AnnotationUtils.getDefaultValue!Order().get!int == Ordered.LOWEST_PRECEDENCE);
    }

    unittest
    {
        // synthesizeAnnotationWithImplicitAliasesWithDifferentDefaultValues
        alias Clazz = ImplicitAliasesWithDifferentDefaultValuesContextConfigClass;
        alias AnnotationType = ImplicitAliasesWithDifferentDefaultValuesContextConfig;
        const config = getUDAs!(Clazz, AnnotationType)[0];
        const e = expectThrows!AnnotationConfigurationException(() {
            AnnotationUtils.synthesizeAnnotation(config, typeNameOf!Clazz);
        });
        assert(e.msg.length >= 22 && e.msg[0 .. 22] == "Misconfigured aliases:");
        assert(e.msg.contains("attribute 'location1' in annotation [" ~ typeNameOf!AnnotationType ~ "]"));
        assert(e.msg.contains("attribute 'location2' in annotation [" ~ typeNameOf!AnnotationType ~ "]"));
        assert(e.msg.contains("same default value"));
    }

    unittest
    {
        // synthesizeAnnotationWithImplicitAliasesWithDuplicateValues
        alias Clazz = ImplicitAliasesWithDuplicateValuesContextConfigClass;
        alias AnnotationType = ImplicitAliasesWithDuplicateValuesContextConfig;
        const config = getUDAs!(Clazz, AnnotationType)[0];
        const e = expectThrows!AnnotationConfigurationException(() {
            AnnotationUtils.synthesizeAnnotation(config, typeNameOf!Clazz).location1;
        });
        enum prefix = "Different @AliasFor mirror values";
        assert(e.msg.length >= prefix.length && e.msg[0 .. prefix.length] == prefix);
        assert(e.msg.contains(typeNameOf!AnnotationType));
        assert(e.msg.contains("declared on class"));
        assert(e.msg.contains(typeNameOf!Clazz));
        assert(e.msg.contains("attribute 'location1' and its alias 'location2'"));
        assert(e.msg.contains("with values of [1] and [2]"));
    }

    unittest
    {
        // synthesizeAnnotationFromMapWithoutAttributeAliases
        const component = getUDAs!(WebController, Component)[0];

        auto map = singletonMap(VALUE, Any.of("webController"));
        const synthesizedComponent = AnnotationUtils.synthesizeAnnotation!Component(map, typeNameOf!WebController);

        assert(component.value == "webController", "value from component: ");
        assert(synthesizedComponent.value == "webController", "value from synthesized component: ");
    }

    unittest
    {
        // synthesizeAnnotationFromMapWithNestedMap
        const componentScan = getUDAs!(ComponentScanSingleFilterClass, ComponentScanSingleFilter)[0];
        assert(componentScan.value.pattern == "*Foo", "value from ComponentScan: ");

        auto attributes = AnnotationUtils.getAnnotationAttributes(typeNameOf!ComponentScanSingleFilterClass,
                componentScan, false, true);
        assert(attributes !is null);
        assert(attributes.annotationType() == typeNameOf!ComponentScanSingleFilter);

        auto filterMap = attributes.get("value").get!(Map!(string, Any));
        assert(filterMap !is null);
        assert(filterMap.get("pattern").get!string == "*Foo");

        // Modify nested map
        filterMap.put("pattern", Any.of("newFoo"));
        filterMap.put("enigma", Any.of(42));

        const synthesizedComponentScan = AnnotationUtils.synthesizeAnnotation!ComponentScanSingleFilter(attributes,
                typeNameOf!ComponentScanSingleFilterClass);
        assert(synthesizedComponentScan.value.pattern == "newFoo", "value from synthesized ComponentScan: ");
    }

    unittest
    {
        // synthesizeAnnotationFromMapWithNestedArrayOfMaps
        const componentScan = getUDAs!(ComponentScanClass, ComponentScan)[0];

        auto attributes = AnnotationUtils.getAnnotationAttributes(typeNameOf!ComponentScanClass,
                componentScan, false, true);
        assert(attributes !is null);
        assert(attributes.annotationType() == typeNameOf!ComponentScan);

        auto filters = attributes.get("excludeFilters").get!(Map!(string, Any)[]);
        assert(filters !is null);

        string[] patterns;
        foreach (filter; filters)
            patterns ~= filter.get("pattern").get!string;
        assert(patterns == ["*Foo", "*Bar"]);

        // Modify nested maps
        filters[0].put("pattern", Any.of("newFoo"));
        filters[0].put("enigma", Any.of(42));
        filters[1].put("pattern", Any.of("newBar"));
        filters[1].put("enigma", Any.of(42));

        const synthesizedComponentScan = AnnotationUtils.synthesizeAnnotation!ComponentScan(attributes,
                typeNameOf!ComponentScanClass);
        assert(patternsOf(synthesizedComponentScan.excludeFilters) == ["newFoo", "newBar"]);
    }

    unittest
    {
        // synthesizeAnnotationFromDefaultsWithoutAttributeAliases
        const annotationWithDefaults = AnnotationUtils.synthesizeAnnotation!AnnotationWithDefaults();
        assert(annotationWithDefaults.text == "enigma", "text: ");
        assert(annotationWithDefaults.predicate, "predicate: ");
        assert(annotationWithDefaults.characters == ['a', 'b', 'c'], "characters: ");
    }

    unittest
    {
        // synthesizeAnnotationFromDefaultsWithAttributeAliases
        const contextConfig = AnnotationUtils.synthesizeAnnotation!ContextConfig();
        assert(contextConfig.value.length == 0, "value: ");
        assert(contextConfig.location.length == 0, "location: ");
    }

    unittest
    {
        // synthesizeAnnotationFromMapWithMinimalAttributesWithAttributeAliases
        auto map = singletonMap("location", Any.of("test.xml"));
        const contextConfig = AnnotationUtils.synthesizeAnnotation!ContextConfig(map, null);
        assert(contextConfig.value == "test.xml", "value: ");
        assert(contextConfig.location == "test.xml", "location: ");
    }

    unittest
    {
        // synthesizeAnnotationFromMapWithAttributeAliasesThatOverrideArraysWithSingleElements
        auto map = singletonMap("value", Any.of("/foo"));
        auto get = AnnotationUtils.synthesizeAnnotation!Get(map, null);
        assert(get.value == "/foo", "value: ");
        assert(get.path == "/foo", "path: ");

        map = singletonMap("path", Any.of("/foo"));
        get = AnnotationUtils.synthesizeAnnotation!Get(map, null);
        assert(get.value == "/foo", "value: ");
        assert(get.path == "/foo", "path: ");
    }

    private void assertAnnotationSynthesisFromMapWithImplicitAliases(string attributeNameAndValue)
    {
        auto map = singletonMap(attributeNameAndValue, Any.of(attributeNameAndValue));
        const config = AnnotationUtils.synthesizeAnnotation!ImplicitAliasesContextConfig(map, null);
        assert(config.value == attributeNameAndValue, "value: ");
        assert(config.location1 == attributeNameAndValue, "location1: ");
        assert(config.location2 == attributeNameAndValue, "location2: ");
        assert(config.location3 == attributeNameAndValue, "location3: ");
        assert(config.xmlFile == attributeNameAndValue, "xmlFile: ");
        assert(config.groovyScript == attributeNameAndValue, "groovyScript: ");
    }

    unittest
    {
        // synthesizeAnnotationFromMapWithImplicitAttributeAliases
        assertAnnotationSynthesisFromMapWithImplicitAliases("value");
        assertAnnotationSynthesisFromMapWithImplicitAliases("location1");
        assertAnnotationSynthesisFromMapWithImplicitAliases("location2");
        assertAnnotationSynthesisFromMapWithImplicitAliases("location3");
        assertAnnotationSynthesisFromMapWithImplicitAliases("xmlFile");
        assertAnnotationSynthesisFromMapWithImplicitAliases("groovyScript");
    }

    unittest
    {
        // synthesizeAnnotationFromMapWithAttributeOfIncorrectType
        auto map = singletonMap(VALUE, Any.of(42L));
        const e = expectThrows!IllegalStateException(() {
            AnnotationUtils.synthesizeAnnotation!Component(map, null).value;
        });
        assert(e.msg.contains("Attribute 'value' in annotation " ~ typeNameOf!Component
                ~ " should be compatible with string but a long value was returned"));
    }

    unittest
    {
        // synthesizeAnnotationFromMapWithAttributeOfIncorrectArrayType
        auto map = singletonMap(VALUE, Any.of([42]));
        const e = expectThrows!IllegalStateException(() {
            AnnotationUtils.synthesizeAnnotation!CharsContainer(map, null).chars;
        });
        assert(e.msg.contains("Attribute 'chars' in annotation " ~ typeNameOf!CharsContainer
                ~ " should be compatible with const(char)[] but a int[] value was returned"));
    }

    unittest
    {
        // synthesizeAnnotationFromAnnotationAttributesWithoutAttributeAliases
        // 1) Get an annotation
        const component = getUDAs!(WebController, Component)[0];

        // 2) Convert the annotation into AnnotationAttributes
        AnnotationAttributes attributes = AnnotationUtils.getAnnotationAttributes(typeNameOf!WebController, component);
        assert(attributes !is null);

        // 3) Synthesize the AnnotationAttributes back into an annotation
        const synthesizedComponent = AnnotationUtils.synthesizeAnnotation!Component(attributes,
                typeNameOf!WebController);

        // 4) Verify that the original and synthesized annotations are equivalent
        assert(synthesizedComponent == component);
        assert(component.value == "webController", "value from component: ");
        assert(synthesizedComponent.value == "webController", "value from synthesized component: ");
    }
}

version (FlintAnnotationUtilsMethods)
{
    unittest
    {
        // getValueFromAnnotation
        bool found;
        const order = findAnnotationOnMethod!(Order, SimpleFoo, "something")(found);
        assert(AnnotationUtils.getValue(order, AnnotationUtils.VALUE).get!int == 1);
        assert(AnnotationUtils.getValue(order).get!int == 1);
    }

    unittest
    {
        // getDefaultValueFromAnnotation
        import flint.core : Ordered;

        bool found;
        const order = findAnnotationOnMethod!(Order, SimpleFoo, "something")(found);
        assert(AnnotationUtils.getDefaultValue(order, AnnotationUtils.VALUE).get!int == Ordered.LOWEST_PRECEDENCE);
        assert(AnnotationUtils.getDefaultValue(order).get!int == Ordered.LOWEST_PRECEDENCE);
    }

    unittest
    {
        // getRepeatableAnnotationsDeclaredOnMethod
        const annotations = AnnotationUtils.getRepeatableAnnotations!(MyRepeatable,
                MyRepeatableContainer)(methodDescriptorOf!(InterfaceWithRepeated, "foo"));
        assert(valuesOf(annotations) == ["A", "B", "C", "meta1"]);
    }
}

// AnnotationUtils has no repeatable-annotation support (getRepeatableAnnotations, getDeclaredRepeatableAnnotations,
// containers); repeated D UDAs are separate annotations, not a container.
version (FlintAnnotationUtilsRepeatable)
{
    unittest
    {
        // getRepeatableAnnotationsDeclaredOnClassWithAttributeAliases
        const expectedLocations = ["A", "B"];

        auto annotations = AnnotationUtils.getRepeatableAnnotations!ContextConfig(
                descriptorOf!ConfigHierarchyTestCase);
        assert(annotations.length == 0, "size if container type is omitted: ");

        annotations = AnnotationUtils.getRepeatableAnnotations!(ContextConfig,
                Hierarchy)(descriptorOf!ConfigHierarchyTestCase);

        string[] locations;
        foreach (annotation; annotations)
            locations ~= annotation.location;
        assert(locations == expectedLocations);

        assert(valuesOf(annotations) == expectedLocations);
    }

    /// The Spring halves of the getRepeatableAnnotations tests on `T`.
    private void assertRepeatableAnnotations(T)(string[] expectedValuesSpring)
    {
        auto set = AnnotationUtils.getRepeatableAnnotations!(MyRepeatable, MyRepeatableContainer)(descriptorOf!T);
        assert(valuesOf(set) == expectedValuesSpring);

        // When container type is omitted and therefore inferred from @Repeatable
        set = AnnotationUtils.getRepeatableAnnotations!MyRepeatable(descriptorOf!T);
        assert(valuesOf(set) == expectedValuesSpring);
    }

    unittest
    {
        // getRepeatableAnnotationsDeclaredOnClass
        assertRepeatableAnnotations!MyRepeatableClass(["A", "B", "C", "meta1"]);
    }

    unittest
    {
        // getRepeatableAnnotationsDeclaredOnSuperclass
        assertRepeatableAnnotations!SubMyRepeatableClass(["A", "B", "C", "meta1"]);
    }

    unittest
    {
        // getRepeatableAnnotationsDeclaredOnClassAndSuperclass
        assertRepeatableAnnotations!SubMyRepeatableWithAdditionalLocalDeclarationsClass([
            "X", "Y", "Z", "meta2"
        ]);
    }

    unittest
    {
        // getRepeatableAnnotationsDeclaredOnMultipleSuperclasses
        assertRepeatableAnnotations!SubSubMyRepeatableWithAdditionalLocalDeclarationsClass([
            "X", "Y", "Z", "meta2"
        ]);
    }

    unittest
    {
        // getDeclaredRepeatableAnnotationsDeclaredOnClass
        const expectedValuesSpring = ["A", "B", "C", "meta1"];

        auto set = AnnotationUtils.getDeclaredRepeatableAnnotations!(MyRepeatable,
                MyRepeatableContainer)(descriptorOf!MyRepeatableClass);
        assert(valuesOf(set) == expectedValuesSpring);

        // When container type is omitted and therefore inferred from @Repeatable
        set = AnnotationUtils.getDeclaredRepeatableAnnotations!MyRepeatable(descriptorOf!MyRepeatableClass);
        assert(valuesOf(set) == expectedValuesSpring);
    }

    unittest
    {
        // getDeclaredRepeatableAnnotationsDeclaredOnSuperclass
        auto set = AnnotationUtils.getDeclaredRepeatableAnnotations!(MyRepeatable,
                MyRepeatableContainer)(descriptorOf!SubMyRepeatableClass);
        assert(set.length == 0);

        // When container type is omitted and therefore inferred from @Repeatable
        set = AnnotationUtils.getDeclaredRepeatableAnnotations!MyRepeatable(descriptorOf!SubMyRepeatableClass);
        assert(set.length == 0);
    }

    unittest
    {
        // findAnnotationWithRepeatablesElements
        bool found;
        findAnnotation!(TestRepeatable, TestRepeatablesClass)(found);
        assert(!found);
        findAnnotation!(TestRepeatableContainer, TestRepeatablesClass)(found);
        assert(found);
    }

    unittest
    {
        // findAnnotationFindsRepeatableContainerOnComposedAnnotationMetaAnnotatedWithRepeatableAnnotations
        bool found;
        const annotation = findAnnotation!(MyRepeatableContainer, MyRepeatableMeta1And2)(found);
        assert(found);
        assert(valuesOf(annotation.value) == ["meta1", "meta2"]);
    }
}

version (FlintAnnotationUtilsMethods)
{
    unittest
    {
        // findAnnotationFindsRepeatableContainerOnComposedAnnotationMetaAnnotatedWithRepeatableAnnotationsOnMethod
        bool found;
        const annotation = AnnotationUtils.findAnnotation!MyRepeatableContainer(
                methodDescriptorOf!methodWithComposedAnnotationMetaAnnotatedWithRepeatableAnnotations, found);
        assert(found);
        assert(valuesOf(annotation.value) == ["meta1", "meta2"]);
    }
}
