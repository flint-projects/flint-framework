// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core/annotation
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.core.annotation.MergedAnnotationsTests` (v7.1.0), part 1 of 5: the
`FluentSearchApiTests` nested class and the class-level search tests (presence, distance, search strategies,
`@Inherited` and type-hierarchy lookups, aggregate indexes and sources). One `unittest` per Java test method, each
starting with a `// <JavaTestName>` comment. The other parts are `core_merged_annotations_methods_test.d`,
`core_merged_annotations_aliases_test.d`, `core_merged_annotations_synthesize_test.d` and
`core_merged_annotations_repeatable_test.d`.

Skipped Java tests: none in this part.

Adapted: Java annotations are D UDA structs; `@Retention`, `@Target` and `@Inherited` have no D counterpart and are
dropped. Flint has no reflection: `MergedAnnotations.from(T.class, strategy)` is
`MergedAnnotations.from(descriptorOf!T, strategy)`, over the merged annotation table of the type's Flint AOT
descriptor; attribute lookups by name (`getString("value")`, `getBoolean("readOnly")`) read the field of the merged
struct (`synthesize().value`). `stream().map(MergedAnnotation::getType)` is `typeNames()`, and `stream(A)` of a
non-repeatable annotation is empty exactly when `!isPresent!A`. For a method, `MergedAnnotations.from(method)` is
`MergedAnnotations.from` the merged table of the method's UDAs. Spring's
`org.springframework.core.testfixture.stereotype.Component` (meta-annotated with `@Indexed`) and `Indexed` are local
UDAs; `jakarta.annotation.Resource` is `flint.jakarta.annotation.Resource`. Cases that need unported features wait
behind version gates.
+/
module flint.core.merged_annotations_search_test;

import flint.core.annotation : AliasFor, Order;
import flint.core.annotation.types : MergedAnnotations, SearchStrategy;
import flint.engine.aot.descriptor : descriptorOf, mergedAnnotations;
import flint.engine.aot.name : typeNameOf;
import flint.jakarta.annotation : Resource;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fixtures

/// Spring's `org.springframework.core.testfixture.stereotype.Indexed`.
private struct Indexed
{
}

/// Spring's `org.springframework.core.testfixture.stereotype.Component`.
@Indexed
private struct Component
{
    string value;
}

private struct Transactional
{
    string value;
    string qualifier = "transactionManager";
    bool readOnly;
}

@Transactional
@Component
private struct TransactionalComponent
{
}

@TransactionalComponent
private struct ComposedTransactionalComponent
{
}

private class NonAnnotatedClass
{
}

@Component
private class AnnotatedClass
{
    class NonAnnotatedInnerClass
    {
    }

    static class NonAnnotatedStaticNestedClass
    {
    }
}

private interface NonAnnotatedInterface
{
}

@TransactionalComponent
private class TransactionalComponentClass
{
}

private class SubTransactionalComponentClass : TransactionalComponentClass
{
}

@ComposedTransactionalComponent
private class ComposedTransactionalComponentClass
{
}

@Transactional(qualifier : "composed1")
private struct InheritedComposed
{
}

@Transactional(qualifier : "composed2", readOnly:
        true)
private struct Composed
{
}

@Transactional("TxInheritedComposed")
private struct TxInheritedComposed
{
}

@Transactional("TxComposed")
private struct TxComposed
{
}

private struct TestConfiguration
{
    @AliasFor(value : "location")
    string value = "";
    @AliasFor(value : "value")
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

@Transactional
private class ClassWithInheritedAnnotation
{
}

@Composed
private class SubClassWithInheritedAnnotation : ClassWithInheritedAnnotation
{
}

private class SubSubClassWithInheritedAnnotation : SubClassWithInheritedAnnotation
{
}

@InheritedComposed
private class ClassWithInheritedComposedAnnotation
{
}

@Composed
private class SubClassWithInheritedComposedAnnotation : ClassWithInheritedComposedAnnotation
{
}

private class SubSubClassWithInheritedComposedAnnotation : SubClassWithInheritedComposedAnnotation
{
}

@Transactional("TxConfig")
private class TxConfig
{
}

@Transactional("DerivedTxConfig")
private class DerivedTxConfig : TxConfig
{
}

@TxInheritedComposed
@TxComposed
private class TxFromMultipleComposedAnnotations
{
}

@Transactional
private interface InterfaceWithInheritedAnnotation
{
    @Order
    void handleFromInterface();
}

private abstract class AbstractClassWithInheritedAnnotation(T) : InterfaceWithInheritedAnnotation
{
    @Transactional
    abstract void handle();

    @Transactional
    void handleParameterized(T t)
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

@Transactional
private interface InheritedAnnotationInterface
{
}

private interface SubInheritedAnnotationInterface : InheritedAnnotationInterface
{
}

private interface SubSubInheritedAnnotationInterface : SubInheritedAnnotationInterface
{
}

@Order
private interface NonInheritedAnnotationInterface
{
}

private interface SubNonInheritedAnnotationInterface : NonInheritedAnnotationInterface
{
}

private interface SubSubNonInheritedAnnotationInterface : SubNonInheritedAnnotationInterface
{
}

@Component("meta1")
@Order
private struct Meta1
{
}

@Component("meta2")
@Transactional(readOnly : true)
private struct Meta2
{
}

@Meta2
private struct MetaMeta
{
}

@MetaMeta
private struct MetaMetaMeta
{
}

@MetaCycle3
private struct MetaCycle1
{
}

@MetaCycle1
private struct MetaCycle2
{
}

@MetaCycle2
private struct MetaCycle3
{
}

@Meta1
private interface InterfaceWithMetaAnnotation
{
}

@Meta2
private class ClassWithLocalMetaAnnotationAndMetaAnnotatedInterface : InterfaceWithMetaAnnotation
{
}

@Meta1
private class ClassWithInheritedMetaAnnotation
{
}

@Meta2
private class SubClassWithInheritedMetaAnnotation : ClassWithInheritedMetaAnnotation
{
}

private class SubSubClassWithInheritedMetaAnnotation : SubClassWithInheritedMetaAnnotation
{
}

@MetaMeta
private class MetaMetaAnnotatedClass
{
}

@MetaMetaMeta
private class MetaMetaMetaAnnotatedClass
{
}

@MetaCycle3
private class MetaCycleAnnotatedClass
{
}

@Transactional
private class InheritedAnnotationClass
{
}

private class SubInheritedAnnotationClass : InheritedAnnotationClass
{
}

@Order
private class NonInheritedAnnotationClass
{
}

private class SubNonInheritedAnnotationClass : NonInheritedAnnotationClass
{
}

@Transactional
private class TransactionalClass
{
}

@Order
private class TransactionalAndOrderedClass : TransactionalClass
{
}

private class SubTransactionalAndOrderedClass : TransactionalAndOrderedClass
{
}

@Resource(name : "x")
private class ResourceHolder
{
}

private interface TransactionalService
{
    @Transactional
    void doIt();
}

private class TransactionalServiceImpl : TransactionalService
{
    void doIt()
    {
    }
}

/// `MergedAnnotations.from(T.class, strategy)`.
private MergedAnnotations from(T)(SearchStrategy strategy = SearchStrategy.DIRECT)
{
    return MergedAnnotations.from(descriptorOf!T, strategy);
}

/// `MergedAnnotations.from(method)`: the merged table of the method's own UDAs.
private MergedAnnotations fromMethod(alias method)()
{
    return MergedAnnotations.from(mergedAnnotations!(__traits(getAttributes, method))());
}

// ---------------------------------------------------------------------------------------------------------------
// FluentSearchApiTests

// MergedAnnotations has no fluent search API: no MergedAnnotations.search(SearchStrategy), AnnotationFilter,
// RepeatableContainers or enclosing-class predicates, and from() takes neither containers nor a filter.
version (FlintMergedAnnotationsSearchApi)
{
    import flint.core.annotation.types : AnnotationFilter, RepeatableContainers, Search;
    import flint.java.lang : IllegalArgumentException, IllegalStateException;
    import flint.util.test_support : expectThrows;
    import std.algorithm.searching : endsWith;

    unittest
    {
        // preconditions
        auto e = expectThrows!IllegalArgumentException(() { MergedAnnotations.search(null); });
        assert(e.msg == "SearchStrategy must not be null");

        auto search = MergedAnnotations.search(SearchStrategy.SUPERCLASS);

        e = expectThrows!IllegalArgumentException(() { search.withEnclosingClasses(null); });
        assert(e.msg == "Predicate must not be null");
        const s = expectThrows!IllegalStateException(() {
            search.withEnclosingClasses(Search.always);
        });
        assert(s.msg == "A custom 'searchEnclosingClass' predicate can only be combined with "
                ~ "SearchStrategy.TYPE_HIERARCHY");

        e = expectThrows!IllegalArgumentException(() { search.withAnnotationFilter(null); });
        assert(e.msg == "AnnotationFilter must not be null");

        e = expectThrows!IllegalArgumentException(() { search.withRepeatableContainers(null); });
        assert(e.msg == "RepeatableContainers must not be null");

        e = expectThrows!IllegalArgumentException(() { search.from(null); });
        assert(e.msg == "AnnotatedElement must not be null");
    }

    unittest
    {
        // searchFromClassWithDefaultAnnotationFilterAndDefaultRepeatableContainers
        const classes = MergedAnnotations.search(SearchStrategy.DIRECT)
            .from(descriptorOf!TransactionalComponent).typeNames();
        assert(classes == [typeNameOf!Transactional, typeNameOf!Component, typeNameOf!Indexed]);
    }

    unittest
    {
        // searchFromClassWithCustomAnnotationFilter
        const classes = MergedAnnotations.search(SearchStrategy.DIRECT).withAnnotationFilter(
                (string annotationName) => annotationName.endsWith("Indexed"))
            .from(descriptorOf!TransactionalComponent).typeNames();
        assert(classes == [typeNameOf!Transactional, typeNameOf!Component]);
    }

    unittest
    {
        // searchFromClassWithCustomRepeatableContainers
        assert(MergedAnnotations.from(descriptorOf!HierarchyClass).stream!TestConfiguration().length == 0);
        const containers = RepeatableContainers.explicitRepeatable!(TestConfiguration, Hierarchy)();

        const annotations = MergedAnnotations.search(SearchStrategy.DIRECT)
            .withRepeatableContainers(containers).from(descriptorOf!HierarchyClass);
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
        // searchFromNonAnnotatedInnerClassWithAnnotatedEnclosingClassWithEnclosingClassPredicates
        const testCase = descriptorOf!(AnnotatedClass.NonAnnotatedInnerClass);
        auto search = MergedAnnotations.search(SearchStrategy.TYPE_HIERARCHY);

        assert(search.from(testCase).size() == 0);
        assert(search.withEnclosingClasses(Search.never).from(testCase).size() == 0);
        assert(search.withEnclosingClasses(Search.isStaticClass).from(testCase).size() == 0);

        auto classes = search.withEnclosingClasses(Search.isInnerClass).from(testCase).typeNames();
        assert(classes == [typeNameOf!Component, typeNameOf!Indexed]);

        classes = search.withEnclosingClasses(Search.always).from(testCase).typeNames();
        assert(classes == [typeNameOf!Component, typeNameOf!Indexed]);

        classes = search.withEnclosingClasses(Search.isInnerClass)
            .withRepeatableContainers(RepeatableContainers.none())
            .withAnnotationFilter((string annotationName) => annotationName.endsWith("Indexed")).from(testCase)
            .typeNames();
        assert(classes == [typeNameOf!Component]);
    }

    unittest
    {
        // searchFromNonAnnotatedStaticNestedClassWithAnnotatedEnclosingClassWithEnclosingClassPredicates
        const testCase = descriptorOf!(AnnotatedClass.NonAnnotatedStaticNestedClass);
        auto search = MergedAnnotations.search(SearchStrategy.TYPE_HIERARCHY);

        assert(search.from(testCase).size() == 0);
        assert(search.withEnclosingClasses(Search.never).from(testCase).size() == 0);
        assert(search.withEnclosingClasses(Search.isInnerClass).from(testCase).size() == 0);

        auto classes = search.withEnclosingClasses(Search.isStaticClass).from(testCase).typeNames();
        assert(classes == [typeNameOf!Component, typeNameOf!Indexed]);

        classes = search.withEnclosingClasses(Search.always).from(testCase).typeNames();
        assert(classes == [typeNameOf!Component, typeNameOf!Indexed]);
    }

    unittest
    {
        // fromPreconditions
        const strategy = SearchStrategy.DIRECT;
        const containers = RepeatableContainers.standardRepeatables();

        auto e = expectThrows!IllegalArgumentException(() {
            MergedAnnotations.from(descriptorOf!NonAnnotatedClass, strategy, null, AnnotationFilter.PLAIN);
        });
        assert(e.msg == "RepeatableContainers must not be null");
        e = expectThrows!IllegalArgumentException(() {
            MergedAnnotations.from(descriptorOf!NonAnnotatedClass, strategy, containers, null);
        });
        assert(e.msg == "AnnotationFilter must not be null");

        e = expectThrows!IllegalArgumentException(() {
            MergedAnnotations.from(typeNameOf!NonAnnotatedClass, null, null, AnnotationFilter.PLAIN);
        });
        assert(e.msg == "RepeatableContainers must not be null");
        e = expectThrows!IllegalArgumentException(() {
            MergedAnnotations.from(typeNameOf!NonAnnotatedClass, null, containers, null);
        });
        assert(e.msg == "AnnotationFilter must not be null");
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Presence and distance

unittest
{
    // streamWhenFromNonAnnotatedClass
    assert(!from!NonAnnotatedClass().isPresent!TransactionalComponent);
}

unittest
{
    // streamWhenFromClassWithMetaDepth1
    const classes = from!TransactionalComponent().typeNames();
    assert(classes == [typeNameOf!Transactional, typeNameOf!Component, typeNameOf!Indexed]);
}

unittest
{
    // streamWhenFromClassWithMetaDepth2
    const classes = from!ComposedTransactionalComponent().typeNames();
    assert(classes == [
        typeNameOf!TransactionalComponent, typeNameOf!Transactional, typeNameOf!Component,
        typeNameOf!Indexed
    ]);
}

unittest
{
    // isPresentWhenFromNonAnnotatedClass
    assert(!from!NonAnnotatedClass().isPresent!Transactional);
}

unittest
{
    // isPresentWhenFromAnnotationClassWithMetaDepth0
    assert(!from!TransactionalComponent().isPresent!TransactionalComponent);
}

unittest
{
    // isPresentWhenFromAnnotationClassWithMetaDepth1
    const annotations = from!TransactionalComponent();
    assert(annotations.isPresent!Transactional);
    assert(annotations.isPresent!Component);
}

unittest
{
    // isPresentWhenFromAnnotationClassWithMetaDepth2
    const annotations = from!ComposedTransactionalComponent();
    assert(annotations.isPresent!Transactional);
    assert(annotations.isPresent!Component);
    assert(!annotations.isPresent!ComposedTransactionalComponent);
}

unittest
{
    // isPresentWhenFromClassWithMetaDepth0
    assert(from!TransactionalComponentClass().isPresent!TransactionalComponent);
}

unittest
{
    // isPresentWhenFromSubclassWithMetaDepth0
    assert(!from!SubTransactionalComponentClass().isPresent!TransactionalComponent);
}

unittest
{
    // isPresentWhenFromClassWithMetaDepth1
    const annotations = from!TransactionalComponentClass();
    assert(annotations.isPresent!Transactional);
    assert(annotations.isPresent!Component);
}

unittest
{
    // isPresentWhenFromClassWithMetaDepth2
    const annotations = from!ComposedTransactionalComponentClass();
    assert(annotations.isPresent!Transactional);
    assert(annotations.isPresent!Component);
    assert(annotations.isPresent!ComposedTransactionalComponent);
}

// MergedAnnotation records only its type and distance: no getMetaSource, getRoot, getMetaTypes, getAggregateIndex
// or getSource.
version (FlintMergedAnnotationMetaSource)
{
    unittest
    {
        // getParent
        const annotations = from!ComposedTransactionalComponentClass();
        assert(annotations.get!TransactionalComponent().getMetaSource()
                .getType() == typeNameOf!ComposedTransactionalComponent);
    }
}

unittest
{
    // getRootWhenNotDirect
    const annotations = from!ComposedTransactionalComponentClass();
    const annotation = annotations.get!TransactionalComponent();
    assert(annotation.getDistance() > 0);
    version (FlintMergedAnnotationMetaSource)
        assert(annotation.getRoot().getType() == typeNameOf!ComposedTransactionalComponent);
}

version (FlintMergedAnnotationMetaSource)
{
    unittest
    {
        // getRootWhenDirect
        const annotations = from!ComposedTransactionalComponentClass();
        const annotation = annotations.get!ComposedTransactionalComponent();
        assert(annotation.getDistance() == 0);
        assert(annotation.getRoot() is annotation);
    }

    unittest
    {
        // getMetaTypes
        const annotation = from!ComposedTransactionalComponentClass().get!TransactionalComponent();
        assert(annotation.getMetaTypes() == [
            typeNameOf!ComposedTransactionalComponent, typeNameOf!TransactionalComponent
        ]);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// MergedAnnotationCollectors

// MergedAnnotations has no stream(A) of every merged A and there is no MergedAnnotationCollectors.toMultiValueMap.
version (FlintMergedAnnotationCollectors)
{
    import flint.core.annotation.types : MergedAnnotationCollectors;
    import flint.engine.aot.any : Any;

    /// `from(T.class, strategy).stream(Transactional.class).collect(toMultiValueMap())`.
    private auto collectTransactional(T)(SearchStrategy strategy = SearchStrategy.DIRECT)
    {
        return MergedAnnotationCollectors.toMultiValueMap(from!T(strategy).stream!Transactional());
    }

    /// The string values collected for `key`.
    private string[] stringsOf(M)(M map, string key)
    {
        string[] result;
        foreach (value; map.get(key))
            result ~= value.get!string;
        return result;
    }

    unittest
    {
        // collectMultiValueMapFromNonAnnotatedClass
        assert(collectTransactional!NonAnnotatedClass().isEmpty());
    }

    unittest
    {
        // collectMultiValueMapFromClassWithLocalAnnotation
        assert(stringsOf(collectTransactional!TxConfig(), "value") == ["TxConfig"]);
    }

    unittest
    {
        // collectMultiValueMapFromClassWithLocalComposedAnnotationAndInheritedAnnotation
        const map = collectTransactional!SubClassWithInheritedAnnotation(SearchStrategy.INHERITED_ANNOTATIONS);
        assert(stringsOf(map, "qualifier") == ["composed2", "transactionManager"]);
    }

    unittest
    {
        // collectMultiValueMapFavorsInheritedAnnotationsOverMoreLocallyDeclaredComposedAnnotations
        const map = collectTransactional!SubSubClassWithInheritedAnnotation(SearchStrategy.INHERITED_ANNOTATIONS);
        assert(stringsOf(map, "qualifier") == ["transactionManager"]);
    }

    unittest
    {
        // collectMultiValueMapFavorsInheritedComposedAnnotationsOverMoreLocallyDeclaredComposedAnnotations
        const map = collectTransactional!SubSubClassWithInheritedComposedAnnotation(
                SearchStrategy.INHERITED_ANNOTATIONS);
        assert(stringsOf(map, "qualifier") == ["composed1"]);
    }

    unittest
    {
        // collectMultiValueMapFromClassWithLocalAnnotationThatShadowsAnnotationFromSuperclass
        // If the "value" entry contains both "DerivedTxConfig" AND "TxConfig", then the algorithm is accidentally
        // picking up shadowed annotations of the same type within the class hierarchy.
        const map = collectTransactional!DerivedTxConfig(SearchStrategy.INHERITED_ANNOTATIONS);
        assert(stringsOf(map, "value") == ["DerivedTxConfig"]);
    }

    unittest
    {
        // collectMultiValueMapFromClassWithMultipleComposedAnnotations
        const map = collectTransactional!TxFromMultipleComposedAnnotations(SearchStrategy.INHERITED_ANNOTATIONS);
        assert(stringsOf(map, "value") == ["TxInheritedComposed", "TxComposed"]);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// SearchStrategy.INHERITED_ANNOTATIONS

unittest
{
    // getWithInheritedAnnotationsFromClassWithLocalAnnotation
    const annotation = from!TxConfig(SearchStrategy.INHERITED_ANNOTATIONS).get!Transactional();
    assert(annotation.synthesize().value == "TxConfig");
}

unittest
{
    // getWithInheritedAnnotationsFromClassWithLocalAnnotationThatShadowsAnnotationFromSuperclass
    const annotation = from!DerivedTxConfig(SearchStrategy.INHERITED_ANNOTATIONS).get!Transactional();
    assert(annotation.synthesize().value == "DerivedTxConfig");
}

unittest
{
    // getWithInheritedAnnotationsFromMetaCycleAnnotatedClassWithMissingTargetMetaAnnotation
    const annotation = from!MetaCycleAnnotatedClass(SearchStrategy.INHERITED_ANNOTATIONS).get!Transactional();
    assert(!annotation.isPresent());
}

unittest
{
    // getWithInheritedAnnotationsFavorsLocalComposedAnnotationOverInheritedAnnotation
    const annotation = from!SubClassWithInheritedAnnotation(SearchStrategy.INHERITED_ANNOTATIONS).get!Transactional();
    assert(annotation.synthesize().readOnly);
}

// `@Inherited` is not modelled: INHERITED_ANNOTATIONS reads the type's own annotations (aggregate 0), so a
// superclass's @Inherited annotation is not found.
version (FlintInheritedAnnotations)
{
    unittest
    {
        // getWithInheritedAnnotationsFavorsInheritedAnnotationsOverMoreLocallyDeclaredComposedAnnotations
        const annotation = from!SubSubClassWithInheritedAnnotation(SearchStrategy.INHERITED_ANNOTATIONS)
            .get!Transactional();
        assert(!annotation.synthesize().readOnly);
    }

    unittest
    {
        // getWithInheritedAnnotationsFavorsInheritedComposedAnnotationsOverMoreLocallyDeclaredComposedAnnotations
        const annotation = from!SubSubClassWithInheritedComposedAnnotation(SearchStrategy.INHERITED_ANNOTATIONS)
            .get!Transactional();
        assert(!annotation.synthesize().readOnly);
    }
}

unittest
{
    // getWithInheritedAnnotationsFromInterfaceImplementedBySuperclass
    const annotation = from!ConcreteClassWithInheritedAnnotation(SearchStrategy.INHERITED_ANNOTATIONS)
        .get!Transactional();
    assert(!annotation.isPresent());
}

unittest
{
    // getWithInheritedAnnotationsFromInheritedAnnotationInterface
    const annotation = from!InheritedAnnotationInterface(SearchStrategy.INHERITED_ANNOTATIONS).get!Transactional();
    assert(annotation.isPresent());
}

unittest
{
    // getWithInheritedAnnotationsFromNonInheritedAnnotationInterface
    const annotation = from!NonInheritedAnnotationInterface(SearchStrategy.INHERITED_ANNOTATIONS).get!Order();
    assert(annotation.isPresent());
}

// ---------------------------------------------------------------------------------------------------------------
// SearchStrategy.TYPE_HIERARCHY on interfaces

unittest
{
    // getWithTypeHierarchyFromInheritedAnnotationInterface
    const annotation = from!InheritedAnnotationInterface(SearchStrategy.TYPE_HIERARCHY).get!Transactional();
    assert(annotation.isPresent());
    version (FlintMergedAnnotationMetaSource)
        assert(annotation.getAggregateIndex() == 0);
}

unittest
{
    // getWithTypeHierarchyFromSubInheritedAnnotationInterface
    const annotation = from!SubInheritedAnnotationInterface(SearchStrategy.TYPE_HIERARCHY).get!Transactional();
    assert(annotation.isPresent());
    assert(annotation.getAggregateIndex() == 1);
}

unittest
{
    // getWithTypeHierarchyFromSubSubInheritedAnnotationInterface
    const annotation = from!SubSubInheritedAnnotationInterface(SearchStrategy.TYPE_HIERARCHY).get!Transactional();
    assert(annotation.isPresent());
    assert(annotation.getAggregateIndex() == 2);
}

unittest
{
    // getWithTypeHierarchyFromNonInheritedAnnotationInterface
    const annotation = from!NonInheritedAnnotationInterface(SearchStrategy.TYPE_HIERARCHY).get!Order();
    assert(annotation.isPresent());
    version (FlintMergedAnnotationMetaSource)
        assert(annotation.getAggregateIndex() == 0);
}

unittest
{
    // getWithTypeHierarchyFromSubNonInheritedAnnotationInterface
    const annotation = from!SubNonInheritedAnnotationInterface(SearchStrategy.TYPE_HIERARCHY).get!Order();
    assert(annotation.isPresent());
    assert(annotation.getAggregateIndex() == 1);
}

unittest
{
    // getWithTypeHierarchyFromSubSubNonInheritedAnnotationInterface
    const annotation = from!SubSubNonInheritedAnnotationInterface(SearchStrategy.TYPE_HIERARCHY).get!Order();
    assert(annotation.isPresent());
    assert(annotation.getAggregateIndex() == 2);
}

unittest
{
    // getDirectWithJavaxAnnotationType
    assert(from!ResourceHolder(SearchStrategy.DIRECT).get!Resource().synthesize().name == "x");
}

unittest
{
    // streamInheritedFromClassWithInterface
    assert(!fromMethod!(TransactionalServiceImpl.doIt)().isPresent!Transactional);
}

// MergedAnnotations has no method lookup through overridden and interface methods: a method's table holds only its
// own UDAs, and Flint AOT method descriptors are not searched.
version (FlintAnnotationUtilsMethods)
{
    import flint.engine.aot.descriptor : methodDescriptorOf;

    unittest
    {
        // streamTypeHierarchyFromClassWithInterface
        const annotations = MergedAnnotations.from(methodDescriptorOf!(TransactionalServiceImpl,
                "doIt"), SearchStrategy.TYPE_HIERARCHY);
        assert(annotations.stream!Transactional().length == 1);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// getDirectFromClass*

unittest
{
    // getDirectFromClassFavorsMoreLocallyDeclaredComposedAnnotationsOverAnnotationsOnInterfaces
    const annotation = from!ClassWithLocalMetaAnnotationAndMetaAnnotatedInterface(SearchStrategy.TYPE_HIERARCHY)
        .get!Component();
    assert(annotation.synthesize().value == "meta2");
}

unittest
{
    // getDirectFromClassFavorsMoreLocallyDeclaredComposedAnnotationsOverInheritedAnnotations
    const annotation = from!SubSubClassWithInheritedAnnotation(SearchStrategy.TYPE_HIERARCHY).get!Transactional();
    assert(annotation.synthesize().readOnly);
}

unittest
{
    // getDirectFromClassFavorsMoreLocallyDeclaredComposedAnnotationsOverInheritedComposedAnnotations
    const annotation = from!SubSubClassWithInheritedMetaAnnotation(SearchStrategy.TYPE_HIERARCHY).get!Component();
    assert(annotation.synthesize().value == "meta2");
}

unittest
{
    // getDirectFromClassWithMetaMetaAnnotatedClass
    const annotation = from!MetaMetaAnnotatedClass(SearchStrategy.TYPE_HIERARCHY).get!Component();
    assert(annotation.synthesize().value == "meta2");
}

unittest
{
    // getDirectFromClassWithMetaMetaMetaAnnotatedClass
    const annotation = from!MetaMetaMetaAnnotatedClass(SearchStrategy.TYPE_HIERARCHY).get!Component();
    assert(annotation.synthesize().value == "meta2");
}

unittest
{
    // getDirectFromClassWithAnnotatedClassWithMissingTargetMetaAnnotation
    // TransactionalClass is NOT annotated or meta-annotated with @Component
    const annotation = from!TransactionalClass(SearchStrategy.TYPE_HIERARCHY).get!Component();
    assert(!annotation.isPresent());
}

unittest
{
    // getDirectFromClassWithMetaCycleAnnotatedClassWithMissingTargetMetaAnnotation
    const annotation = from!MetaCycleAnnotatedClass(SearchStrategy.TYPE_HIERARCHY).get!Component();
    assert(!annotation.isPresent());
}

version (FlintMergedAnnotationMetaSource)
{
    unittest
    {
        // getDirectFromClassWithInheritedAnnotationInterface
        const annotation = from!InheritedAnnotationInterface(SearchStrategy.TYPE_HIERARCHY).get!Transactional();
        assert(annotation.getAggregateIndex() == 0);
    }
}

unittest
{
    // getDirectFromClassWithSubInheritedAnnotationInterface
    const annotation = from!SubInheritedAnnotationInterface(SearchStrategy.TYPE_HIERARCHY).get!Transactional();
    assert(annotation.getAggregateIndex() == 1);
}

unittest
{
    // getDirectFromClassWithSubSubInheritedAnnotationInterface
    const annotation = from!SubSubInheritedAnnotationInterface(SearchStrategy.TYPE_HIERARCHY).get!Transactional();
    assert(annotation.getAggregateIndex() == 2);
}

version (FlintMergedAnnotationMetaSource)
{
    unittest
    {
        // getDirectFromClassWithNonInheritedAnnotationInterface
        const annotation = from!NonInheritedAnnotationInterface(SearchStrategy.TYPE_HIERARCHY).get!Order();
        assert(annotation.getAggregateIndex() == 0);
    }
}

unittest
{
    // getDirectFromClassWithSubNonInheritedAnnotationInterface
    const annotation = from!SubNonInheritedAnnotationInterface(SearchStrategy.TYPE_HIERARCHY).get!Order();
    assert(annotation.getAggregateIndex() == 1);
}

unittest
{
    // getDirectFromClassWithSubSubNonInheritedAnnotationInterface
    const annotation = from!SubSubNonInheritedAnnotationInterface(SearchStrategy.TYPE_HIERARCHY).get!Order();
    assert(annotation.getAggregateIndex() == 2);
}

// ---------------------------------------------------------------------------------------------------------------
// Sources and aggregate indexes

version (FlintMergedAnnotationMetaSource)
{
    import flint.core.annotation.types : MergedAnnotationPredicates;

    /// `MergedAnnotations.from(T.class, SUPERCLASS).get(A.class).getSource()`: a type name, null for none.
    private string superclassSource(A, T)()
    {
        return from!T(SearchStrategy.SUPERCLASS).get!A().getSource();
    }

    /// `getSuperClassSourceWithTypeIn(T.class, annotationTypes)`.
    private string superclassSourceWithTypeIn(T)(const string[] annotationTypes)
    {
        foreach (annotation; from!T(SearchStrategy.SUPERCLASS).stream())
            if (MergedAnnotationPredicates.typeIn(annotationTypes)(annotation) && annotation.isDirectlyPresent())
                return annotation.getSource();
        return null;
    }

    unittest
    {
        // getSuperClassForAllScenarios
        // no class-level annotation
        assert(superclassSource!(Transactional, NonAnnotatedInterface)() is null);
        assert(superclassSource!(Transactional, NonAnnotatedClass)() is null);
        // inherited class-level annotation; note: @Transactional is inherited
        assert(superclassSource!(Transactional,
                InheritedAnnotationInterface)() == typeNameOf!InheritedAnnotationInterface);
        assert(superclassSource!(Transactional, SubInheritedAnnotationInterface)() is null);
        assert(superclassSource!(Transactional, InheritedAnnotationClass)() == typeNameOf!InheritedAnnotationClass);
        assert(superclassSource!(Transactional, SubInheritedAnnotationClass)() == typeNameOf!InheritedAnnotationClass);
        // non-inherited class-level annotation; note: @Order is not inherited,
        // but we should still find it on classes.
        assert(superclassSource!(Order,
                NonInheritedAnnotationInterface)() == typeNameOf!NonInheritedAnnotationInterface);
        assert(superclassSource!(Order, SubNonInheritedAnnotationInterface)() is null);
        assert(superclassSource!(Order, NonInheritedAnnotationClass)() == typeNameOf!NonInheritedAnnotationClass);
        assert(superclassSource!(Order, SubNonInheritedAnnotationClass)() == typeNameOf!NonInheritedAnnotationClass);
    }

    unittest
    {
        // getSuperClassSourceForTypesWithSingleCandidateType
        // no class-level annotation
        const transactionalCandidateList = [typeNameOf!Transactional];
        assert(superclassSourceWithTypeIn!NonAnnotatedInterface(transactionalCandidateList) is null);
        assert(superclassSourceWithTypeIn!NonAnnotatedClass(transactionalCandidateList) is null);
        // inherited class-level annotation; note: @Transactional is inherited
        assert(superclassSourceWithTypeIn!InheritedAnnotationInterface(
                transactionalCandidateList) == typeNameOf!InheritedAnnotationInterface);
        assert(superclassSourceWithTypeIn!SubInheritedAnnotationInterface(transactionalCandidateList) is null);
        assert(superclassSourceWithTypeIn!InheritedAnnotationClass(
                transactionalCandidateList) == typeNameOf!InheritedAnnotationClass);
        assert(superclassSourceWithTypeIn!SubInheritedAnnotationClass(
                transactionalCandidateList) == typeNameOf!InheritedAnnotationClass);
        // non-inherited class-level annotation; note: @Order is not inherited,
        // but should still find it on classes.
        const orderCandidateList = [typeNameOf!Order];
        assert(superclassSourceWithTypeIn!NonInheritedAnnotationInterface(
                orderCandidateList) == typeNameOf!NonInheritedAnnotationInterface);
        assert(superclassSourceWithTypeIn!SubNonInheritedAnnotationInterface(orderCandidateList) is null);
        assert(superclassSourceWithTypeIn!NonInheritedAnnotationClass(
                orderCandidateList) == typeNameOf!NonInheritedAnnotationClass);
        assert(superclassSourceWithTypeIn!SubNonInheritedAnnotationClass(
                orderCandidateList) == typeNameOf!NonInheritedAnnotationClass);
    }

    unittest
    {
        // getSuperClassSourceForTypesWithMultipleCandidateTypes
        const candidates = [typeNameOf!Transactional, typeNameOf!Order];
        // no class-level annotation
        assert(superclassSourceWithTypeIn!NonAnnotatedInterface(candidates) is null);
        assert(superclassSourceWithTypeIn!NonAnnotatedClass(candidates) is null);
        // inherited class-level annotation; note: @Transactional is inherited
        assert(superclassSourceWithTypeIn!InheritedAnnotationInterface(
                candidates) == typeNameOf!InheritedAnnotationInterface);
        assert(superclassSourceWithTypeIn!SubInheritedAnnotationInterface(candidates) is null);
        assert(superclassSourceWithTypeIn!InheritedAnnotationClass(candidates) == typeNameOf!InheritedAnnotationClass);
        assert(superclassSourceWithTypeIn!SubInheritedAnnotationClass(
                candidates) == typeNameOf!InheritedAnnotationClass);
        // non-inherited class-level annotation; note: @Order is not inherited,
        // but findAnnotationDeclaringClassForTypes() should still find it on
        // classes.
        assert(superclassSourceWithTypeIn!NonInheritedAnnotationInterface(
                candidates) == typeNameOf!NonInheritedAnnotationInterface);
        assert(superclassSourceWithTypeIn!SubNonInheritedAnnotationInterface(candidates) is null);
        assert(superclassSourceWithTypeIn!NonInheritedAnnotationClass(
                candidates) == typeNameOf!NonInheritedAnnotationClass);
        assert(superclassSourceWithTypeIn!SubNonInheritedAnnotationClass(
                candidates) == typeNameOf!NonInheritedAnnotationClass);
        // class hierarchy mixed with @Transactional and @Order declarations
        assert(superclassSourceWithTypeIn!TransactionalClass(candidates) == typeNameOf!TransactionalClass);
        assert(superclassSourceWithTypeIn!TransactionalAndOrderedClass(
                candidates) == typeNameOf!TransactionalAndOrderedClass);
        assert(superclassSourceWithTypeIn!SubTransactionalAndOrderedClass(
                candidates) == typeNameOf!TransactionalAndOrderedClass);
    }
}

unittest
{
    // isDirectlyPresentForAllScenarios
    // no class-level annotation
    assert(!from!NonAnnotatedInterface(SearchStrategy.DIRECT).get!Transactional().isDirectlyPresent());
    assert(!from!NonAnnotatedInterface(SearchStrategy.DIRECT).isDirectlyPresent!Transactional);
    assert(!from!NonAnnotatedClass(SearchStrategy.DIRECT).get!Transactional().isDirectlyPresent());
    assert(!from!NonAnnotatedClass(SearchStrategy.DIRECT).isDirectlyPresent!Transactional);
    // inherited class-level annotation; note: @Transactional is inherited
    assert(from!InheritedAnnotationInterface(SearchStrategy.DIRECT).get!Transactional().isDirectlyPresent());
    assert(from!InheritedAnnotationInterface(SearchStrategy.DIRECT).isDirectlyPresent!Transactional);
    assert(!from!SubInheritedAnnotationInterface(SearchStrategy.DIRECT).get!Transactional().isDirectlyPresent());
    assert(!from!SubInheritedAnnotationInterface(SearchStrategy.DIRECT).isDirectlyPresent!Transactional);
    assert(from!InheritedAnnotationClass(SearchStrategy.DIRECT).get!Transactional().isDirectlyPresent());
    assert(from!InheritedAnnotationClass(SearchStrategy.DIRECT).isDirectlyPresent!Transactional);
    assert(!from!SubInheritedAnnotationClass(SearchStrategy.DIRECT).get!Transactional().isDirectlyPresent());
    assert(!from!SubInheritedAnnotationClass(SearchStrategy.DIRECT).isDirectlyPresent!Transactional);
    // non-inherited class-level annotation; note: @Order is not inherited
    assert(from!NonInheritedAnnotationInterface(SearchStrategy.DIRECT).get!Order().isDirectlyPresent());
    assert(from!NonInheritedAnnotationInterface(SearchStrategy.DIRECT).isDirectlyPresent!Order);
    assert(!from!SubNonInheritedAnnotationInterface(SearchStrategy.DIRECT).get!Order().isDirectlyPresent());
    assert(!from!SubNonInheritedAnnotationInterface(SearchStrategy.DIRECT).isDirectlyPresent!Order);
    assert(from!NonInheritedAnnotationClass(SearchStrategy.DIRECT).get!Order().isDirectlyPresent());
    assert(from!NonInheritedAnnotationClass(SearchStrategy.DIRECT).isDirectlyPresent!Order);
    assert(!from!SubNonInheritedAnnotationClass(SearchStrategy.DIRECT).get!Order().isDirectlyPresent());
    assert(!from!SubNonInheritedAnnotationClass(SearchStrategy.DIRECT).isDirectlyPresent!Order);
}

version (FlintMergedAnnotationMetaSource)
{
    /// `MergedAnnotations.from(T.class, INHERITED_ANNOTATIONS).get(A.class).getAggregateIndex()`.
    private int aggregateIndex(A, T)()
    {
        return from!T(SearchStrategy.INHERITED_ANNOTATIONS).get!A().getAggregateIndex();
    }

    unittest
    {
        // getAggregateIndexForAllScenarios
        // no class-level annotation
        assert(aggregateIndex!(Transactional, NonAnnotatedInterface)() == -1);
        assert(aggregateIndex!(Transactional, NonAnnotatedClass)() == -1);
        // inherited class-level annotation; note: @Transactional is inherited
        assert(aggregateIndex!(Transactional, InheritedAnnotationInterface)() == 0);
        // Since we're not traversing interface hierarchies the following,
        // though perhaps counterintuitive, must be false:
        assert(aggregateIndex!(Transactional, SubInheritedAnnotationInterface)() == -1);
        assert(aggregateIndex!(Transactional, InheritedAnnotationClass)() == 0);
        assert(aggregateIndex!(Transactional, SubInheritedAnnotationClass)() == 1);
        // non-inherited class-level annotation; note: @Order is not inherited
        assert(aggregateIndex!(Order, NonInheritedAnnotationInterface)() == 0);
        assert(aggregateIndex!(Order, SubNonInheritedAnnotationInterface)() == -1);
        assert(aggregateIndex!(Order, NonInheritedAnnotationClass)() == 0);
        assert(aggregateIndex!(Order, SubNonInheritedAnnotationClass)() == -1);
    }
}
