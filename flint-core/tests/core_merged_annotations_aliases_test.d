// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core/annotation
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.core.annotation.MergedAnnotationsTests` (v7.1.0), part 3 of 5: the
`ConventionBasedAnnotationAttributeOverrideTests` and `AliasForValueAndAttributeLengthTests` nested classes and the
tests of merged attribute values (`@AliasFor` mirrors, explicit and implicit meta-annotation overrides, shadowing
and default values). One `unittest` per Java test method, each starting with a `// <JavaTestName>` comment. See
`core_merged_annotations_search_test.d` for the other parts.

Skipped Java tests: none in this part.

Adapted: Java annotations are D UDA structs, `@AliasFor` with named arguments; `@Retention`, `@Target` and
`@Inherited` are dropped, and an attribute without a Java default has its D type's `init`. `Class`-valued
attributes are `ClassRef` (`Number.class` is `classOf!Number` for a local `Number` class). Flint has no reflection:
`MergedAnnotations.from(T.class, strategy)` is `MergedAnnotations.from(descriptorOf!T, strategy)`, and for a method
it is `MergedAnnotations.from` the merged table of the method's UDAs (every method here carries its annotations
itself, so the `TYPE_HIERARCHY` search adds nothing). Attribute lookups by name (`getStringArray("locations")`)
read the field of the merged struct (`synthesize().locations`). Cases where the port merges differently wait
behind version gates named for the behaviour.
+/
module flint.core.merged_annotations_aliases_test;

import flint.core.annotation : AliasFor, ClassRef, classOf;
import flint.core.annotation.types : MergedAnnotations, SearchStrategy;
import flint.engine.aot.descriptor : descriptorOf, mergedAnnotations;

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
    string value;
    string qualifier = "transactionManager";
    bool readOnly;
}

/// Stands in for `java.lang.Number` as a `Class` attribute value.
private class Number
{
}

private struct PrimitiveArrays
{
    int[] ints;
    long[] longs;
    bool[] booleans;
    const(char)[] chars;
    double[] doubles;
}

@PrimitiveArrays
private struct ComposedPrimitiveSingleValues
{
    @AliasFor(annotation: classOf!PrimitiveArrays, attribute: "ints")
    int anInt = 0;
    @AliasFor(annotation: classOf!PrimitiveArrays, attribute: "longs")
    long aLong = 0L;
    @AliasFor(annotation: classOf!PrimitiveArrays, attribute: "booleans")
    bool aBoolean = false;
    @AliasFor(annotation: classOf!PrimitiveArrays, attribute: "chars")
    char aChar = 'x';
    @AliasFor(annotation: classOf!PrimitiveArrays, attribute: "doubles")
    double aDouble = 0.0;
}

@ComposedPrimitiveSingleValues(anInt: 42, aLong: 42L, aBoolean: true, aChar: 'c', aDouble: 4.2)
private class ComposedPrimitiveSingleValuesClass
{
}

private struct AliasedTransactional
{
    @AliasFor(attribute: "qualifier")
    string value = "";
    @AliasFor(attribute: "value")
    string qualifier = "";
}

@Transactional
private struct TxComposedWithOverride
{
    string qualifier = "txMgr";
}

@AliasedTransactional(value: "aliasForQualifier")
@Component
private struct AliasedTransactionalComponent
{
}

@AliasedTransactionalComponent
private class AliasedTransactionalComponentClass
{
}

@AliasedTransactional
private struct MyAliasedTransactional
{
    @AliasFor(annotation: classOf!AliasedTransactional, attribute: "value")
    string value = "defaultTransactionManager";
}

@MyAliasedTransactional("anotherTransactionManager")
private struct ComposedMyAliasedTransactional
{
}

@ComposedMyAliasedTransactional
private class ComposedTransactionalClass
{
}

@AliasedTransactional("meta")
private struct MetaAliasedTransactional
{
}

@MetaAliasedTransactional
private struct MetaMetaAliasedTransactional
{
}

@MetaMetaAliasedTransactional
private class MetaMetaAliasedTransactionalClass
{
}

@TxComposedWithOverride // Override default "txMgr" from @TxComposedWithOverride with "localTxMgr"
@Transactional(qualifier: "localTxMgr")
private struct MetaAndLocalTxConfig
{
}

@MetaAndLocalTxConfig
private class MetaAndLocalTxConfigClass
{
}

private struct TestPropertySource
{
    @AliasFor(value: "locations")
    string[] value;
    @AliasFor(value: "value")
    string[] locations;
}

private struct ContextConfiguration
{
    @AliasFor(attribute: "locations")
    string[] value;
    @AliasFor(attribute: "value")
    string[] locations;
    ClassRef[] classes;
}

@ContextConfiguration
private struct ConventionBasedComposedContextConfiguration
{
    // Do NOT use @AliasFor here
    string[] locations;
    // Do NOT use @AliasFor here
    ClassRef[] classes;
}

@ContextConfiguration
private struct HalfConventionBasedAndHalfAliasedComposedContextConfiguration
{
    // Do NOT use @AliasFor here
    string[] locations;
    @AliasFor(annotation: classOf!ContextConfiguration, attribute: "locations")
    string[] xmlConfigFiles;
}

@ContextConfiguration
private struct AliasedComposedContextConfiguration
{
    @AliasFor(annotation: classOf!ContextConfiguration, attribute: "locations")
    string[] xmlConfigFiles;
}

@ContextConfiguration
private struct AliasedValueComposedContextConfiguration
{
    @AliasFor(annotation: classOf!ContextConfiguration, attribute: "value")
    string[] locations;
}

@ContextConfiguration
private struct ImplicitAliasesContextConfiguration
{
    @AliasFor(annotation: classOf!ContextConfiguration, attribute: "locations")
    string[] groovyScripts;
    @AliasFor(annotation: classOf!ContextConfiguration, attribute: "locations")
    string[] xmlFiles;
    // intentionally omitted: attribute = "locations"
    @AliasFor(annotation: classOf!ContextConfiguration)
    string[] locations;
    // intentionally omitted: attribute = "locations" (SPR-14069)
    @AliasFor(annotation: classOf!ContextConfiguration)
    string[] value;
}

@ImplicitAliasesContextConfiguration(xmlFiles: ["A.xml", "B.xml"])
private struct ComposedImplicitAliasesContextConfiguration
{
}

@ImplicitAliasesContextConfiguration
private struct TransitiveImplicitAliasesContextConfiguration
{
    @AliasFor(annotation: classOf!ImplicitAliasesContextConfiguration, attribute: "xmlFiles")
    string[] xml;
    @AliasFor(annotation: classOf!ImplicitAliasesContextConfiguration, attribute: "groovyScripts")
    string[] groovy;
}

@ImplicitAliasesContextConfiguration
private struct SingleLocationTransitiveImplicitAliasesContextConfiguration
{
    @AliasFor(annotation: classOf!ImplicitAliasesContextConfiguration, attribute: "xmlFiles")
    string xml = "";
    @AliasFor(annotation: classOf!ImplicitAliasesContextConfiguration, attribute: "groovyScripts")
    string groovy = "";
}

@ImplicitAliasesContextConfiguration
private struct TransitiveImplicitAliasesWithSkippedLevelContextConfiguration
{
    @AliasFor(annotation: classOf!ContextConfiguration, attribute: "locations")
    string[] xml;
    @AliasFor(annotation: classOf!ImplicitAliasesContextConfiguration, attribute: "groovyScripts")
    string[] groovy;
}

@ImplicitAliasesContextConfiguration
{
    private struct SingleLocationTransitiveImplicitAliasesWithSkippedLevelContextConfiguration
    {
        @AliasFor(annotation: classOf!ContextConfiguration, attribute: "locations")
        string xml = "";
        @AliasFor(annotation: classOf!ImplicitAliasesContextConfiguration, attribute: "groovyScripts")
        string groovy = "";
    }
}

@ContextConfiguration(value: ["duplicateDeclaration"])
private struct ShadowedAliasComposedContextConfiguration
{
    @AliasFor(annotation: classOf!ContextConfiguration, attribute: "locations")
    string[] xmlConfigFiles;
}

@ContextConfiguration(locations: ["shadowed.xml"])
@TestPropertySource(locations: ["test.properties"])
private struct AliasedComposedContextConfigurationAndTestPropertySource
{
    @AliasFor(annotation: classOf!ContextConfiguration, attribute: "locations")
    string[] xmlConfigFiles = ["default.xml"];
}

@ContextConfiguration
private struct SpringApplicationConfiguration
{
    @AliasFor(annotation: classOf!ContextConfiguration, attribute: "locations")
    string[] locations;
    // Do NOT use @AliasFor(annotation = ...)
    @AliasFor(value: "value")
    ClassRef[] classes;
    // Do NOT use @AliasFor(annotation = ...)
    @AliasFor(value: "classes")
    ClassRef[] value;
}

private struct Filter
{
    string pattern;
}

private struct ComponentScan
{
    @AliasFor(value: "basePackages")
    string[] value;
    @AliasFor(value: "value")
    string[] basePackages;
    Filter[] excludeFilters;
}

@ComponentScan(excludeFilters: [Filter(pattern: "*Test"), Filter(pattern: "*Tests")])
private struct TestComponentScan
{
    @AliasFor(attribute: "basePackages", annotation: classOf!ComponentScan)
    string[] packages;
}

@ComponentScan
private struct ConventionBasedSinglePackageComponentScan
{
    // Do NOT use @AliasFor here
    string basePackages;
}

@ComponentScan
private struct AliasForBasedSinglePackageComponentScan
{
    @AliasFor(attribute: "basePackages", annotation: classOf!ComponentScan)
    string pkg;
}

@ConventionBasedComposedContextConfiguration(locations: ["explicitDeclaration"])
private class ConventionBasedComposedContextConfigurationClass
{
}

@HalfConventionBasedAndHalfAliasedComposedContextConfiguration(xmlConfigFiles: [
    "explicitDeclaration"
])
private class HalfConventionBasedAndHalfAliasedComposedContextConfigurationClass1
{
}

@HalfConventionBasedAndHalfAliasedComposedContextConfiguration(locations: ["explicitDeclaration"])
private class HalfConventionBasedAndHalfAliasedComposedContextConfigurationClass2
{
}

@AliasedComposedContextConfiguration(xmlConfigFiles: ["test.xml"])
private class AliasedComposedContextConfigurationClass
{
}

@AliasedValueComposedContextConfiguration(locations: ["test.xml"])
private class AliasedValueComposedContextConfigurationClass
{
}

@ImplicitAliasesContextConfiguration(value: ["foo.xml"])
private class ImplicitAliasesContextConfigurationClass1
{
}

@ImplicitAliasesContextConfiguration(locations: ["bar.xml"])
private class ImplicitAliasesContextConfigurationClass2
{
}

@ImplicitAliasesContextConfiguration(xmlFiles: ["baz.xml"])
private class ImplicitAliasesContextConfigurationClass3
{
}

@TransitiveImplicitAliasesContextConfiguration(groovy: ["test.groovy"])
private class TransitiveImplicitAliasesContextConfigurationClass
{
}

@SingleLocationTransitiveImplicitAliasesContextConfiguration(groovy: "test.groovy")
private class SingleLocationTransitiveImplicitAliasesContextConfigurationClass
{
}

@TransitiveImplicitAliasesWithSkippedLevelContextConfiguration(xml: ["test.xml"])
private class TransitiveImplicitAliasesWithSkippedLevelContextConfigurationClass
{
}

@SingleLocationTransitiveImplicitAliasesWithSkippedLevelContextConfiguration(xml: "test.xml")
private class SingleLocationTransitiveImplicitAliasesWithSkippedLevelContextConfigurationClass
{
}

@ComposedImplicitAliasesContextConfiguration
private class ComposedImplicitAliasesContextConfigurationClass
{
}

@ShadowedAliasComposedContextConfiguration(xmlConfigFiles: ["test.xml"])
private class ShadowedAliasComposedContextConfigurationClass
{
}

@AliasedComposedContextConfigurationAndTestPropertySource(xmlConfigFiles: ["test.xml"])
private class AliasedComposedContextConfigurationAndTestPropertySourceClass
{
}

@ComponentScan(value: ["com.example.app.test"], basePackages: ["com.example.app.test"])
private class ComponentScanWithBasePackagesAndValueAliasClass
{
}

@TestComponentScan(packages: ["com.example.app.test"])
private class TestComponentScanClass
{
}

@ConventionBasedSinglePackageComponentScan(basePackages: "com.example.app.test")
private class ConventionBasedSinglePackageComponentScanClass
{
}

@AliasForBasedSinglePackageComponentScan(pkg: "com.example.app.test")
private class AliasForBasedSinglePackageComponentScanClass
{
}

@SpringApplicationConfiguration(value: [classOf!Number])
private class SpringApplicationConfigurationClass
{
}

private enum RequestMethod
{
    GET,
    POST
}

private struct RequestMapping
{
    string name;
    @AliasFor(value: "path")
    string[] value = [""];
    @AliasFor(attribute: "value")
    string[] path = [""];
    RequestMethod[] method;
}

@RequestMapping(method: [RequestMethod.GET], name: "")
private struct GetMapping
{
    @AliasFor(annotation: classOf!RequestMapping)
    string value = "";
    @AliasFor(annotation: classOf!RequestMapping)
    string path = "";
}

@RequestMapping(method: [RequestMethod.POST], name: "")
private struct PostMapping
{
    // Do NOT use @AliasFor here
    string path = "";
}

@Component("webController")
private class WebController
{
    @RequestMapping(value: ["/test"], name: "foo")
    void handleMappedWithValueAttribute()
    {
    }

    @RequestMapping(path: ["/test"], name: "bar", method: [RequestMethod.GET, RequestMethod.POST])
    void handleMappedWithPathAttribute()
    {
    }

    @GetMapping("/test")
    void getMappedWithValueAttribute()
    {
    }

    @GetMapping(path: "/test")
    void getMappedWithPathAttribute()
    {
    }

    @PostMapping(path: "/test")
    void postMappedWithPathAttribute()
    {
    }

    @RequestMapping(value: ["/enigma"], path: ["/test"], name: "baz")
    void handleMappedWithDifferentPathAndValueAttributes()
    {
    }
}

private struct DefaultOverrideRoot
{
    string text = "root";
}

@DefaultOverrideRoot
private struct DefaultOverrideMeta
{
}

@DefaultOverrideMeta
private struct DefaultOverrideMetaMeta
{
    string text = "metameta";
}

@DefaultOverrideMetaMeta
private struct DefaultOverrideMetaMetaMeta
{
}

@DefaultOverrideMetaMetaMeta
private class DefaultOverrideClass
{
}

@DefaultOverrideRoot
private struct DefaultOverrideImplicitAlias
{
    @AliasFor(annotation: classOf!DefaultOverrideRoot, attribute: "text")
    string text1 = "alias";
    @AliasFor(annotation: classOf!DefaultOverrideRoot, attribute: "text")
    string text2 = "alias";
}

@DefaultOverrideImplicitAlias(text1: "alias-meta-1")
private struct DefaultOverrideAliasImplicitMeta1
{
}

@DefaultOverrideImplicitAlias(text2: "alias-meta-2")
private struct DefaultOverrideImplicitAliasMeta2
{
}

@DefaultOverrideAliasImplicitMeta1
private class DefaultOverrideImplicitAliasMetaClass1
{
}

@DefaultOverrideImplicitAliasMeta2
private class DefaultOverrideImplicitAliasMetaClass2
{
}

private struct DefaultOverrideExplicitAliasRoot
{
    @AliasFor(value: "value")
    string text = "";
    @AliasFor(value: "text")
    string value = "";
}

@DefaultOverrideExplicitAliasRoot("meta")
private struct DefaultOverrideExplicitAliasRootMeta
{
}

@DefaultOverrideExplicitAliasRootMeta
private struct DefaultOverrideExplicitAliasRootMetaMeta
{
}

@DefaultOverrideExplicitAliasRootMetaMeta
private class DefaultOverrideExplicitAliasRootMetaMetaClass
{
}

private struct ValueAttribute
{
    string[] value;
}

@ValueAttribute(["FromValueAttributeMeta"])
private struct ValueAttributeMeta
{
    string[] value;
}

@ValueAttributeMeta(["FromValueAttributeMetaMeta"])
private struct ValueAttributeMetaMeta
{
}

@ValueAttributeMetaMeta
private class ValueAttributeMetaMetaClass
{
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

/// `testGetWithInherited(T.class, expected)`.
private void assertGetWithInherited(T)(string[] expected...)
{
    const annotation = from!T(SearchStrategy.INHERITED_ANNOTATIONS).get!ContextConfiguration().synthesize();
    assert(annotation.locations == expected, T.stringof);
    assert(annotation.value == expected, T.stringof);
    assert(annotation.classes.length == 0, T.stringof);
}

/// `testGetWithTypeHierarchy(T.class, expected)`; the Java helper also returns the annotation, which
/// `componentScanOf!T` gives here.
private void assertGetWithTypeHierarchy(T)(string[] expected...)
{
    const annotation = componentScanOf!T();
    assert(annotation.value == expected, T.stringof);
    assert(annotation.basePackages == expected, T.stringof);
}

/// `MergedAnnotations.from(T.class, TYPE_HIERARCHY).get(ComponentScan.class)`, synthesized.
private const(ComponentScan) componentScanOf(T)()
{
    return from!T(SearchStrategy.TYPE_HIERARCHY).get!ComponentScan().synthesize();
}

// ---------------------------------------------------------------------------------------------------------------
// ConventionBasedAnnotationAttributeOverrideTests

unittest
{
    // getWithInheritedAnnotationsAttributesWithConventionBasedComposedAnnotation
    const annotation = from!ConventionBasedComposedContextConfigurationClass(SearchStrategy.INHERITED_ANNOTATIONS)
        .get!ContextConfiguration();
    assert(annotation.isPresent());
    // Convention-based annotation attribute overrides are no longer supported as of
    // Spring Framework 7.0. Otherwise, we would expect "explicitDeclaration".
    assert(annotation.synthesize().locations.length == 0);
    assert(annotation.synthesize().value.length == 0);
}

unittest
{
    // getWithInheritedAnnotationsFromHalfConventionBasedAndHalfAliasedComposedAnnotation1
    // SPR-13554: convention mapping mixed with AliasFor annotations
    // xmlConfigFiles can be used because it has an AliasFor annotation
    const annotation = from!HalfConventionBasedAndHalfAliasedComposedContextConfigurationClass1(
            SearchStrategy.INHERITED_ANNOTATIONS).get!ContextConfiguration();
    assert(annotation.synthesize().locations == ["explicitDeclaration"]);
    assert(annotation.synthesize().value == ["explicitDeclaration"]);
}

unittest
{
    // getWithInheritedAnnotationsFromHalfConventionBasedAndHalfAliasedComposedAnnotation2
    // SPR-13554: convention mapping mixed with AliasFor annotations
    // locations doesn't apply because it has no AliasFor annotation
    const annotation = from!HalfConventionBasedAndHalfAliasedComposedContextConfigurationClass2(
            SearchStrategy.INHERITED_ANNOTATIONS).get!ContextConfiguration();
    assert(annotation.synthesize().locations.length == 0);
    assert(annotation.synthesize().value.length == 0);
}

unittest
{
    // getWithTypeHierarchyWithSingleElementOverridingAnArrayViaConvention
    // Convention-based annotation attribute overrides are no longer supported as of
    // Spring Framework 7.0. Otherwise, we would expect "com.example.app.test".
    assertGetWithTypeHierarchy!ConventionBasedSinglePackageComponentScanClass();
}

unittest
{
    // getWithTypeHierarchyWithLocalAliasesThatConflictWithAttributesInMetaAnnotationByConvention
    const annotation = from!SpringApplicationConfigurationClass(SearchStrategy.TYPE_HIERARCHY)
        .get!ContextConfiguration().synthesize();
    assert(annotation.locations.length == 0);
    assert(annotation.value.length == 0);
    // Convention-based annotation attribute overrides are no longer supported as of
    // Spring Framework 7.0. Otherwise, we would expect Number.class.
    assert(annotation.classes.length == 0);
}

/// `testGetWithTypeHierarchyWebMapping(method, expectedPath)`.
private void assertGetWithTypeHierarchyWebMapping(alias method)(string expectedPath)
{
    const annotation = fromMethod!method().get!RequestMapping().synthesize();
    assert(annotation.value == [expectedPath]);
    assert(annotation.path == [expectedPath]);
}

unittest
{
    // getWithTypeHierarchyOnMethodWithSingleElementOverridingAnArrayViaConvention
    // Convention-based annotation attribute overrides are no longer supported as of
    // Spring Framework 7.0. Otherwise, we would expect "/test".
    assertGetWithTypeHierarchyWebMapping!(WebController.postMappedWithPathAttribute)("");
}

// ---------------------------------------------------------------------------------------------------------------
// AliasForValueAndAttributeLengthTests (gh-37404)

private struct AliasedAnnotation
{
    string foo = "";
}

@AliasedAnnotation
private struct BothNonBlank
{
    @AliasFor(annotation: classOf!AliasedAnnotation, value: "foo", attribute: "foo")
    string bar = "bothNonBlank";
}

@AliasedAnnotation
private struct BothBlank
{
    @AliasFor(annotation: classOf!AliasedAnnotation, value: " ", attribute: " ")
    string bar = "bothBlank";
}

@AliasedAnnotation
private struct BlankValue
{
    @AliasFor(annotation: classOf!AliasedAnnotation, value: " ", attribute: "foo")
    string bar = "blankValue";
}

@AliasedAnnotation
private struct BlankAttribute
{
    @AliasFor(annotation: classOf!AliasedAnnotation, value: "foo", attribute: " ")
    string bar = "blankAttribute";
}

@AliasedAnnotation
private struct OnlyBlankValue
{
    @AliasFor(annotation: classOf!AliasedAnnotation, value: " ")
    string bar = "onlyBlankValue";
}

@AliasedAnnotation
private struct OnlyBlankAttribute
{
    @AliasFor(annotation: classOf!AliasedAnnotation, attribute: " ")
    string bar = "onlyBlankAttribute";
}

@AliasedAnnotation
private struct OnlyValue
{
    @AliasFor(annotation: classOf!AliasedAnnotation, value: "foo")
    string bar = "fromValue";
}

@AliasedAnnotation
private struct OnlyAttribute
{
    @AliasFor(annotation: classOf!AliasedAnnotation, attribute: "foo")
    string bar = "fromAttribute";
}

@AliasedAnnotation
private struct NeitherSet
{
    @AliasFor(annotation: classOf!AliasedAnnotation)
    string foo = "fromSelf";
}

@BothNonBlank
private class WithBothNonBlank
{
}

@BothBlank
private class WithBothBlank
{
}

@BlankValue
private class WithBlankValue
{
}

@BlankAttribute
private class WithBlankAttribute
{
}

@OnlyBlankValue
private class WithOnlyBlankValue
{
}

@OnlyBlankAttribute
private class WithOnlyBlankAttribute
{
}

@OnlyValue
private class WithOnlyValue
{
}

@OnlyAttribute
private class WithOnlyAttribute
{
}

@NeitherSet
private class WithNeitherSet
{
}

import flint.core.annotation.types : AnnotationConfigurationException;
import flint.util.test_support : contains, expectThrows;

private void assertOnlyOnePermitted(T)()
{
    const e = expectThrows!AnnotationConfigurationException(() { from!T().get!AliasedAnnotation(); });
    assert(e.msg.contains("but only one is permitted"), e.msg);
}

private void assertNonexistentBlankAttribute(T)()
{
    const e = expectThrows!AnnotationConfigurationException(() { from!T().get!AliasedAnnotation(); });
    assert(e.msg.contains("is declared as an @AliasFor nonexistent attribute ' '"), e.msg);
}

unittest
{
    // bothNonBlankValueAndAttribute
    assertOnlyOnePermitted!WithBothNonBlank();
}

unittest
{
    // bothBlankValueAndAttribute
    assertOnlyOnePermitted!WithBothBlank();
}

unittest
{
    // blankValueAndNonBlankAttribute
    assertOnlyOnePermitted!WithBlankValue();
}

unittest
{
    // nonBlankValueAndBlankAttribute
    assertOnlyOnePermitted!WithBlankAttribute();
}

unittest
{
    // onlyBlankValue
    assertNonexistentBlankAttribute!WithOnlyBlankValue();
}

unittest
{
    // onlyBlankAttribute
    assertNonexistentBlankAttribute!WithOnlyBlankAttribute();
}

unittest
{
    // onlyValue
    const merged = from!WithOnlyValue().get!AliasedAnnotation();
    assert(merged.synthesize().foo == "fromValue");
}

unittest
{
    // onlyAttribute
    const merged = from!WithOnlyAttribute().get!AliasedAnnotation();
    assert(merged.synthesize().foo == "fromAttribute");
}

unittest
{
    // neitherValueNorAttribute
    const merged = from!WithNeitherSet().get!AliasedAnnotation();
    assert(merged.synthesize().foo == "fromSelf");
}

// ---------------------------------------------------------------------------------------------------------------
// Merged attribute values

unittest
{
    // withInheritedAnnotationsFromAliasedComposedAnnotation
    const annotation = from!AliasedComposedContextConfigurationClass(SearchStrategy.INHERITED_ANNOTATIONS)
        .get!ContextConfiguration().synthesize();
    assert(annotation.value == ["test.xml"]);
    assert(annotation.locations == ["test.xml"]);
}

unittest
{
    // withInheritedAnnotationsFromAliasedValueComposedAnnotation
    const annotation = from!AliasedValueComposedContextConfigurationClass(SearchStrategy.INHERITED_ANNOTATIONS)
        .get!ContextConfiguration().synthesize();
    assert(annotation.value == ["test.xml"]);
    assert(annotation.locations == ["test.xml"]);
}

unittest
{
    // getWithInheritedAnnotationsFromImplicitAliasesInMetaAnnotationOnComposedAnnotation
    const annotation = from!ComposedImplicitAliasesContextConfigurationClass(SearchStrategy.INHERITED_ANNOTATIONS)
        .get!ImplicitAliasesContextConfiguration().synthesize();
    assert(annotation.groovyScripts == ["A.xml", "B.xml"]);
    assert(annotation.xmlFiles == ["A.xml", "B.xml"]);
    assert(annotation.locations == ["A.xml", "B.xml"]);
    assert(annotation.value == ["A.xml", "B.xml"]);
}

unittest
{
    // getWithInheritedAnnotationsFromAliasedValueComposedAnnotation
    assertGetWithInherited!AliasedValueComposedContextConfigurationClass("test.xml");
}

unittest
{
    // getWithInheritedAnnotationsFromImplicitAliasesForSameAttributeInComposedAnnotation
    assertGetWithInherited!ImplicitAliasesContextConfigurationClass1("foo.xml");
    assertGetWithInherited!ImplicitAliasesContextConfigurationClass2("bar.xml");
    assertGetWithInherited!ImplicitAliasesContextConfigurationClass3("baz.xml");
}

unittest
{
    // getWithInheritedAnnotationsFromTransitiveImplicitAliases
    assertGetWithInherited!TransitiveImplicitAliasesContextConfigurationClass("test.groovy");
}

unittest
{
    // getWithInheritedAnnotationsFromTransitiveImplicitAliasesWithSingleElementOverridingAnArrayViaAliasFor
    assertGetWithInherited!SingleLocationTransitiveImplicitAliasesContextConfigurationClass("test.groovy");
}

unittest
{
    // getWithInheritedAnnotationsFromTransitiveImplicitAliasesWithSkippedLevel
    assertGetWithInherited!TransitiveImplicitAliasesWithSkippedLevelContextConfigurationClass("test.xml");
}

unittest
{
    // getWithInheritedAnnotationsFromTransitiveImplicitAliasesWithSkippedLevel...
    // ...WithSingleElementOverridingAnArrayViaAliasFor (one Java test name, split at the line limit)
    assertGetWithInherited!SingleLocationTransitiveImplicitAliasesWithSkippedLevelContextConfigurationClass("test.xml");
}

unittest
{
    // getWithSingleValuePrimitiveAttributesOverridingPrimitiveArraysViaAliasFor
    const annotation = from!ComposedPrimitiveSingleValuesClass().get!PrimitiveArrays();
    assert(annotation.isPresent());
    assert(annotation.synthesize().ints == [42]);
    assert(annotation.synthesize().longs == [42L]);
    assert(annotation.synthesize().booleans == [true]);
    assert(annotation.synthesize().chars == ['c']);
    assert(annotation.synthesize().doubles == [4.2]);
}

unittest
{
    // getWithInheritedAnnotationsFromShadowedAliasComposedAnnotation
    const annotation = from!ShadowedAliasComposedContextConfigurationClass(SearchStrategy.INHERITED_ANNOTATIONS)
        .get!ContextConfiguration().synthesize();
    assert(annotation.locations == ["test.xml"]);
    assert(annotation.value == ["test.xml"]);
}

unittest
{
    // getWithTypeHierarchyFromClassWithMetaAndLocalTxConfig
    const annotation = from!MetaAndLocalTxConfigClass(SearchStrategy.TYPE_HIERARCHY).get!Transactional();
    assert(annotation.synthesize().qualifier == "localTxMgr");
}

unittest
{
    // getWithTypeHierarchyFromClassWithAttributeAliasesInTargetAnnotation
    const mergedAnnotation = from!AliasedTransactionalComponentClass(SearchStrategy.TYPE_HIERARCHY)
        .get!AliasedTransactional();
    const synthesizedAnnotation = mergedAnnotation.synthesize();
    const qualifier = "aliasForQualifier";
    assert(mergedAnnotation.synthesize().value == qualifier);
    assert(mergedAnnotation.synthesize().qualifier == qualifier);
    assert(synthesizedAnnotation.value == qualifier);
    assert(synthesizedAnnotation.qualifier == qualifier);
}

unittest
{
    // getWithTypeHierarchyFromClassWithComposedMetaTransactionalAnnotation
    const mergedAnnotation = from!ComposedTransactionalClass(SearchStrategy.TYPE_HIERARCHY).get!AliasedTransactional();
    assert(mergedAnnotation.synthesize().value == "anotherTransactionManager");
    assert(mergedAnnotation.synthesize().qualifier == "anotherTransactionManager");
}

unittest
{
    // getWithTypeHierarchyFromClassWithMetaMetaAliasedTransactional
    const mergedAnnotation = from!MetaMetaAliasedTransactionalClass(SearchStrategy.TYPE_HIERARCHY)
        .get!AliasedTransactional();
    assert(mergedAnnotation.synthesize().value == "meta");
    assert(mergedAnnotation.synthesize().qualifier == "meta");
}

unittest
{
    // getWithTypeHierarchyFromClassWithAttributeAliasInComposedAnnotationAndNestedAnnotationsInTargetAnnotation
    assertGetWithTypeHierarchy!TestComponentScanClass("com.example.app.test");
    const annotation = componentScanOf!TestComponentScanClass();
    string[] patterns;
    foreach (filter; annotation.excludeFilters)
        patterns ~= filter.pattern;
    assert(patterns == ["*Test", "*Tests"]);
}

unittest
{
    // getWithTypeHierarchyFromClassWithBothAttributesOfAnAliasPairDeclared
    assertGetWithTypeHierarchy!ComponentScanWithBasePackagesAndValueAliasClass("com.example.app.test");
}

unittest
{
    // getWithTypeHierarchyWithSingleElementOverridingAnArrayViaAliasFor
    assertGetWithTypeHierarchy!AliasForBasedSinglePackageComponentScanClass("com.example.app.test");
}

unittest
{
    // getWithTypeHierarchyWhenMultipleMetaAnnotationsHaveClashingAttributeNames
    const annotations = from!AliasedComposedContextConfigurationAndTestPropertySourceClass(
            SearchStrategy.TYPE_HIERARCHY);
    const contextConfig = annotations.get!ContextConfiguration().synthesize();
    assert(contextConfig.locations == ["test.xml"]);
    assert(contextConfig.value == ["test.xml"]);
    const testPropSource = annotations.get!TestPropertySource().synthesize();
    assert(testPropSource.locations == ["test.properties"]);
    assert(testPropSource.value == ["test.properties"]);
}

unittest
{
    // getWithTypeHierarchyOnMethodWithSingleElementOverridingAnArrayViaAliasFor
    assertGetWithTypeHierarchyWebMapping!(WebController.getMappedWithValueAttribute)("/test");
    assertGetWithTypeHierarchyWebMapping!(WebController.getMappedWithPathAttribute)("/test");
}

unittest
{
    // getDirectWithAttributeAliases1
    const annotation = fromMethod!(WebController.handleMappedWithValueAttribute)().get!RequestMapping().synthesize();
    assert(annotation.name == "foo");
    assert(annotation.value == ["/test"]);
    assert(annotation.path == ["/test"]);
}

unittest
{
    // getDirectWithAttributeAliases2
    const annotation = fromMethod!(WebController.handleMappedWithPathAttribute)().get!RequestMapping().synthesize();
    assert(annotation.name == "bar");
    assert(annotation.value == ["/test"]);
    assert(annotation.path == ["/test"]);
}

unittest
{
    // getDirectWithAttributeAliasesWithDifferentValues
    import flint.core.annotation.types : AnnotationConfigurationException;
    import flint.util.test_support : contains, expectThrows;

    const e = expectThrows!AnnotationConfigurationException(() {
        fromMethod!(WebController.handleMappedWithDifferentPathAndValueAttributes)().get!RequestMapping();
    });
    assert(e.msg.contains("attribute 'path' and its alias 'value'"));
    assert(e.msg.contains("values of [{/test}] and [{/enigma}]"));
}

unittest
{
    // getValueWhenHasDefaultOverride
    const annotation = from!DefaultOverrideClass().get!DefaultOverrideRoot();
    // Convention-based annotation attribute overrides are no longer supported as of
    // Spring Framework 7.0. Otherwise, we would expect "metameta".
    assert(annotation.synthesize().text == "root");
}

unittest
{
    // getValueWhenHasDefaultOverrideWithImplicitAlias
    const annotation1 = from!DefaultOverrideImplicitAliasMetaClass1().get!DefaultOverrideRoot();
    assert(annotation1.synthesize().text == "alias-meta-1");
    const annotation2 = from!DefaultOverrideImplicitAliasMetaClass2().get!DefaultOverrideRoot();
    assert(annotation2.synthesize().text == "alias-meta-2");
}

unittest
{
    // getValueWhenHasDefaultOverrideWithExplicitAlias
    const annotation = from!DefaultOverrideExplicitAliasRootMetaMetaClass().get!DefaultOverrideExplicitAliasRoot();
    assert(annotation.synthesize().text == "meta");
    assert(annotation.synthesize().value == "meta");
}

unittest
{
    // getValueWhenThreeDeepMetaWithValue
    const annotation = from!ValueAttributeMetaMetaClass().get!ValueAttribute();
    assert(annotation.synthesize().value == ["FromValueAttributeMeta"]);
}
