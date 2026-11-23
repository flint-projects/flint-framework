// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core/annotation
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.core.annotation.MergedAnnotationsTests` (v7.1.0), part 4 of 5: the
tests of synthesized annotations, attribute values and defaults, `@AliasFor` validation, implicit aliases and
annotations built from maps. One `unittest` per Java test method, each starting with a `// <JavaTestName>`
comment. See `core_merged_annotations_search_test.d` for the other parts.

Skipped Java tests (14), with reasons:
- getValueFromNonPublicAnnotation, getDefaultValueFromNonPublicAnnotation,
  synthesizeNonPublicWithAttributeAliasesFromDifferentPackage: they read package-private annotation types of
  another package through reflection (`getDeclaredAnnotations()`, `ClassUtils.forName`); D UDAs are read at compile
  time, where visibility is checked by the compiler.
- synthesizedAnnotationShouldReuseJdkProxyClass, synthesizeAlreadySynthesized,
  synthesizeShouldNotResynthesizeAlreadySynthesizedAnnotations,
  synthesizeShouldNotSynthesizeNonsynthesizableAnnotationsWhenUsingMergedAnnotationsFromApi: they check the JDK
  proxy behind a synthesized annotation (its class, `isSameAs` identity, `isSynthesizedAnnotation`); a synthesized
  Flint annotation is the merged UDA struct, a value.
- synthesizeWhenAttributeAliasForWithMissingDefaultValues, synthesizeWithImplicitAliasesWithMissingDefaultValues,
  synthesizeFromMapWithMissingAttributeValue, synthesizeFromMapWithNullAttributeValue: they need annotation
  attributes without a default value; every D struct field has one (`T.init`).
- toStringForSynthesizedAnnotations, toStringForSynthesizedAnnotationsWithSingleValueAttributes,
  toStringForSynthesizedAnnotationsWithNonFiniteFloatingPointValues: they assert the Java annotation-literal text of
  a synthesized proxy's `toString()` (`@pkg.RequestMapping(...)`, `(byte)0xff`, `int[][].class`, `0.0f/0.0f`); D
  UDA structs print through `std.conv`, and Flint defines no annotation `toString`.

Adapted: Java annotations are D UDA structs, `@AliasFor` with named arguments; `@Retention`, `@Target` and
`@Inherited` are dropped. `Class`-valued attributes are `ClassRef`. Flint has no reflection: Java's
`T.class.getAnnotation(A.class)` is `std.traits.getUDAs`, and `MergedAnnotation.from(annotation)` of an annotation
declared on an element is the merged annotation of that element (`MergedAnnotations.from(descriptorOf!T)` for a
type, the merged table of the UDAs for a method or field). Attribute lookups by name read the field of the merged
struct. `assertSynthesized`/`assertNotSynthesized` (JDK proxy checks) are dropped. Arrays returned by a
synthesized annotation are `const` slices: the tests that alter them alter a `.dup` copy. Cases that need unported
features, or where the port behaves differently, wait behind version gates.
+/
module flint.core.merged_annotations_synthesize_test;

import flint.core.annotation : AliasFor, ClassRef, classOf, Order;
import flint.core.annotation.types : AnnotationConfigurationException, MergedAnnotations, SearchStrategy;
import flint.engine.aot.descriptor : descriptorOf, mergedAnnotations;
import flint.engine.aot.name : typeNameOf;
import flint.util.test_support : contains, expectThrows;
import std.algorithm.searching : startsWith;
import std.traits : getUDAs, hasUDA;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fixtures

/// Spring's `org.springframework.core.testfixture.stereotype.Component`.
private struct Component
{
    string value;
}

/// Stands in for `java.lang.Number` as a `Class` attribute value.
private class Number
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
    // All remaining attributes declare default values that are used solely
    // for the purpose of testing the toString() implementations for annotations.
    ClassRef clazz = classOf!RequestMethod;
    ClassRef[] classes = [classOf!(int[][]), classOf!(RequestMethod[])];
    char ch = 'X';
    const(char)[] chars = ['X'];
    byte byteValue = cast(byte) 0xFF;
    const(byte)[] bytes = [cast(byte) 0xFF];
    short shortValue = 9876;
    const(short)[] shorts = [9876];
    long longValue = 42L;
    const(long)[] longs = [42L];
    float floatValue = 3.14f;
    const(float)[] floats = [3.14f];
    double doubleValue = 99.999;
    const(double)[] doubles = [99.999];
}

@RequestMapping(method: [RequestMethod.GET], name: "")
private struct GetMapping
{
    @AliasFor(annotation: classOf!RequestMapping)
    string value = "";
    @AliasFor(annotation: classOf!RequestMapping)
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

    @RequestMapping(value: ["/test"], path: ["/test"], name: "bar", method: [
        RequestMethod.GET, RequestMethod.POST
    ])
    void handleMappedWithSamePathAndValueAttributes()
    {
    }
}

private struct Id
{
}

private struct GeneratedValue
{
    string strategy;
}

@Id
@GeneratedValue(strategy: "AUTO")
private long getId()
{
    return 42L;
}

private struct PlainAttributeMetaAnnotation
{
    string value = "enigma";
}

@PlainAttributeMetaAnnotation
private struct ComposedPlainAttributeAnnotation
{
}

@ComposedPlainAttributeAnnotation
private class ComponentWithPlainAttributeMetaAnnotation
{
}

private struct RootAnnotation
{
    string value = "";
    bool flag = false;
}

@RootAnnotation
private struct ComposedRootAnnotation
{
    @AliasFor(annotation: classOf!RootAnnotation, attribute: "flag")
    bool enabled = true;
}

@ComposedRootAnnotation
private struct DoublyComposedRootAnnotation
{
}

private class DomainType
{
    @RootAnnotation
    Object directlyAnnotated;

    @ComposedRootAnnotation
    Object metaAnnotated;

    @DoublyComposedRootAnnotation
    Object metaMetaAnnotated;
}

private struct TestConfiguration
{
    @AliasFor(value: "location")
    string value = "";
    @AliasFor(value: "value")
    string location = "";
    ClassRef configClass = classOf!Object;
}

private struct Hierarchy
{
    TestConfiguration[] value;
}

@Hierarchy([TestConfiguration("A"), TestConfiguration(location: "B")])
private class HierarchyClass
{
}

@TestConfiguration("simple.xml")
private class TestConfigurationClass
{
}

private struct CharsContainer
{
    @AliasFor(attribute: "chars")
    const(char)[] value;
    @AliasFor(attribute: "value")
    const(char)[] chars;
}

@CharsContainer(chars: ['x', 'y', 'z'])
private class GroupOfCharsClass
{
}

private struct AliasForWithMissingAttributeDeclaration
{
    @AliasFor
    string foo = "";
}

@AliasForWithMissingAttributeDeclaration
private class AliasForWithMissingAttributeDeclarationClass
{
}

private struct AliasForWithDuplicateAttributeDeclaration
{
    @AliasFor(value: "bar", attribute: "baz")
    string foo = "";
}

@AliasForWithDuplicateAttributeDeclaration
private class AliasForWithDuplicateAttributeDeclarationClass
{
}

private struct AliasForNonexistentAttribute
{
    @AliasFor(value: "bar")
    string foo = "";
}

@AliasForNonexistentAttribute
private class AliasForNonexistentAttributeClass
{
}

private struct AliasForWithMirroredAliasForWrongAttribute
{
    @AliasFor(attribute: "bar")
    string[] foo = [""];
    @AliasFor(attribute: "quux")
    string[] bar = [""];
}

@AliasForWithMirroredAliasForWrongAttribute
private class AliasForWithMirroredAliasForWrongAttributeClass
{
}

private struct AliasForAttributeOfDifferentType
{
    @AliasFor(value: "bar")
    string[] foo = [""];
    @AliasFor(value: "foo")
    bool bar = true;
}

@AliasForAttributeOfDifferentType
private class AliasForAttributeOfDifferentTypeClass
{
}

private struct AliasForAttributeWithDifferentDefaultValue
{
    @AliasFor(value: "bar")
    string foo = "X";
    @AliasFor(value: "foo")
    string bar = "Z";
}

@AliasForAttributeWithDifferentDefaultValue
private class AliasForAttributeWithDifferentDefaultValueClass
{
}

private struct AliasedComposedTestConfigurationNotMetaPresent
{
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string xmlConfigFile;
}

@AliasedComposedTestConfigurationNotMetaPresent(xmlConfigFile: "test.xml")
private class AliasedComposedTestConfigurationNotMetaPresentClass
{
}

@TestConfiguration
private struct ImplicitAliasesTestConfiguration
{
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string xmlFile = "";
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string groovyScript = "";
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string value = "";
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string location1 = "";
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string location2 = "";
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string location3 = "";
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "configClass")
    ClassRef configClass = classOf!Object;
    string nonAliasedAttribute = "";
}

@ImplicitAliasesTestConfiguration(groovyScript: "groovyScript")
private class GroovyImplicitAliasesSimpleTestConfigurationClass
{
}

@ImplicitAliasesTestConfiguration(xmlFile: "xmlFile")
private class XmlImplicitAliasesTestConfigurationClass
{
}

@ImplicitAliasesTestConfiguration(value: "value")
private class ValueImplicitAliasesTestConfigurationClass
{
}

@ImplicitAliasesTestConfiguration(location1: "location1")
private class Location1ImplicitAliasesTestConfigurationClass
{
}

@TestConfiguration
private struct ImplicitAliasesWithImpliedAliasNamesOmittedTestConfiguration
{
    @AliasFor(annotation: classOf!TestConfiguration)
    string value = "";
    @AliasFor(annotation: classOf!TestConfiguration)
    string location = "";
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string xmlFile = "";
}

@ImplicitAliasesWithImpliedAliasNamesOmittedTestConfiguration(value: "value")
private class ValueImplicitAliasesWithImpliedAliasNamesOmittedTestConfigurationClass
{
}

@ImplicitAliasesWithImpliedAliasNamesOmittedTestConfiguration(location: "location")
private class LocationsImplicitAliasesWithImpliedAliasNamesOmittedTestConfigurationClass
{
}

@ImplicitAliasesWithImpliedAliasNamesOmittedTestConfiguration(xmlFile: "xmlFile")
private class XmlFilesImplicitAliasesWithImpliedAliasNamesOmittedTestConfigurationClass
{
}

@TestConfiguration
private struct ImplicitAliasesWithDifferentDefaultValuesTestConfiguration
{
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string location1 = "foo";
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string location2 = "bar";
}

@ImplicitAliasesWithDifferentDefaultValuesTestConfiguration(location1: "1", location2: "2")
private class ImplicitAliasesWithDifferentDefaultValuesTestConfigurationClass
{
}

@TestConfiguration
private struct ImplicitAliasesWithDuplicateValuesTestConfiguration
{
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string location1 = "";
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string location2 = "";
}

@ImplicitAliasesWithDuplicateValuesTestConfiguration(location1: "1", location2: "2")
private class ImplicitAliasesWithDuplicateValuesTestConfigurationClass
{
}

@TestConfiguration
private struct ImplicitAliasesForAliasPairTestConfiguration
{
    @AliasFor(annotation: classOf!TestConfiguration, attribute: "location")
    string xmlFile = "";
    @AliasFor(annotation: classOf!TestConfiguration, value: "value")
    string groovyScript = "";
}

@ImplicitAliasesForAliasPairTestConfiguration(xmlFile: "test.xml")
private class ImplicitAliasesForAliasPairTestConfigurationClass
{
}

@ImplicitAliasesTestConfiguration
private struct TransitiveImplicitAliasesTestConfiguration
{
    @AliasFor(annotation: classOf!ImplicitAliasesTestConfiguration, attribute: "xmlFile")
    string xml = "";
    @AliasFor(annotation: classOf!ImplicitAliasesTestConfiguration, attribute: "groovyScript")
    string groovy = "";
}

@TransitiveImplicitAliasesTestConfiguration(xml: "test.xml")
{
    private class TransitiveImplicitAliasesTestConfigurationClass
    {
    }
}

@ImplicitAliasesForAliasPairTestConfiguration
private struct TransitiveImplicitAliasesForAliasPairTestConfiguration
{
    @AliasFor(annotation: classOf!ImplicitAliasesForAliasPairTestConfiguration, attribute: "xmlFile")
    string xml = "";
    @AliasFor(annotation: classOf!ImplicitAliasesForAliasPairTestConfiguration, attribute: "groovyScript")
    string groovy = "";
}

@TransitiveImplicitAliasesForAliasPairTestConfiguration(xml: "test.xml")
private class TransitiveImplicitAliasesForAliasPairTestConfigurationClass
{
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

@ComponentScan(excludeFilters: [Filter(pattern: "*Foo"), Filter(pattern: "*Bar")])
private class ComponentScanClass
{
}

private struct ComponentScanSingleFilter
{
    Filter value;
}

@ComponentScanSingleFilter(Filter(pattern: "*Foo"))
private class ComponentScanSingleFilterClass
{
}

private struct AnnotationWithDefaults
{
    string text = "enigma";
    bool predicate = true;
    const(char)[] characters = ['a', 'b', 'c'];
}

@TestConfiguration(value: "foo", location: "bar")
private interface TestConfigurationMismatch
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

@SpringApplicationConfiguration(value: [classOf!Number])
private class SpringApplicationConfigurationClass
{
}

/// `MergedAnnotations.from(T.class, strategy)`.
private MergedAnnotations from(T)(SearchStrategy strategy = SearchStrategy.DIRECT)
{
    return MergedAnnotations.from(descriptorOf!T, strategy);
}

/// `MergedAnnotations.from(element)` for a method or field: the merged table of its own UDAs.
private MergedAnnotations fromElement(alias element)()
{
    return MergedAnnotations.from(mergedAnnotations!(__traits(getAttributes, element))());
}

/// `MergedAnnotations.from(field)`: the merged table of the field's UDAs `udas`.
private MergedAnnotations fromField(udas...)()
{
    return MergedAnnotations.from(mergedAnnotations!udas());
}

/// `MergedAnnotation.from(annotation)` for the annotation `A` declared on `T`: the synthesized merged `A`.
private const(A) synthesized(A, T)()
{
    return from!T().get!A().synthesize();
}

// ---------------------------------------------------------------------------------------------------------------
// Attribute values

unittest
{
    // getDirectWithoutAttributeAliases
    const annotation = from!WebController().get!Component();
    assert(annotation.synthesize().value == "webController");
}

unittest
{
    // getDirectWithNestedAnnotations
    const annotation = from!ComponentScanClass().get!ComponentScan();
    string[] patterns;
    foreach (filter; annotation.synthesize().excludeFilters)
        patterns ~= filter.pattern;
    assert(patterns == ["*Foo", "*Bar"]);
}

// MergedAnnotation has no name-based attribute model: no getValue/getDefaultValue by name, asMap,
// asAnnotationAttributes or Adapt, and no MergedAnnotation.of(type[, map]) or MergedAnnotation.from(annotation).
version (FlintAnnotationUtilsAttributes)
{
    import flint.core.annotation.types : Adapt, MergedAnnotation;
    import flint.engine.aot.any : Any;
    import flint.java.lang : IllegalStateException;
    import flint.java.util : LinkedHashMap, Map;

    /// Java's `Collections.singletonMap(key, value)`.
    private Map!(string, Any) singletonMap(string key, Any value)
    {
        auto map = new LinkedHashMap!(string, Any)();
        map.put(key, value);
        return map;
    }

    unittest
    {
        // getDefaultValueFromAnnotationType
        import flint.core : Ordered;

        const annotation = MergedAnnotation!Order.of();
        assert(annotation.getDefaultValue("value").get!int == Ordered.LOWEST_PRECEDENCE);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Synthesis

unittest
{
    // synthesizeWithoutAttributeAliases
    const component = getUDAs!(WebController, Component)[0];
    const synthesizedComponent = synthesized!(Component, WebController)();
    assert(synthesizedComponent == component);
    assert(synthesizedComponent.value == "webController");
}

unittest
{
    // synthesizeShouldNotSynthesizeNonsynthesizableAnnotations
    // A bare `@Id` UDA is the type itself: the annotation is `Id.init`.
    static assert(hasUDA!(getId, Id));
    const id = Id.init;
    const synthesizedId = fromElement!getId().get!Id().synthesize();
    assert(id == synthesizedId);

    const generatedValue = getUDAs!(getId, GeneratedValue)[0];
    const synthesizedGeneratedValue = fromElement!getId().get!GeneratedValue().synthesize();
    assert(generatedValue == synthesizedGeneratedValue);
}

unittest
{
    // synthesizeWhenUsingMergedAnnotationsFromApi
    RootAnnotation rootAnnotation = fromField!(__traits(getAttributes, DomainType.directlyAnnotated))()
        .get!RootAnnotation().synthesize();
    assert(!rootAnnotation.flag);

    rootAnnotation = fromField!(__traits(getAttributes, DomainType.metaAnnotated))().get!RootAnnotation().synthesize();
    assert(rootAnnotation.flag);

    rootAnnotation = fromField!(__traits(getAttributes, DomainType.metaMetaAnnotated))().get!RootAnnotation()
        .synthesize();
    assert(rootAnnotation.flag);
}

unittest
{
    // synthesizeShouldNotSynthesizeMetaAnnotationsWithNonOverriddenAttributes
    const annotations = from!ComponentWithPlainAttributeMetaAnnotation();
    const plainAttributeMetaAnnotation = annotations.get!PlainAttributeMetaAnnotation().synthesize();
    assert(plainAttributeMetaAnnotation.value == "enigma");
}

// ---------------------------------------------------------------------------------------------------------------
// @AliasFor validation

unittest
{
    // synthesizeWhenAliasForIsMissingAttributeDeclaration
    const e = expectThrows!AnnotationConfigurationException(() {
        synthesized!(AliasForWithMissingAttributeDeclaration, AliasForWithMissingAttributeDeclarationClass)();
    });
    assert(e.msg.startsWith("@AliasFor declaration on attribute 'foo' in annotation"));
    assert(e.msg.contains(typeNameOf!AliasForWithMissingAttributeDeclaration));
    assert(e.msg.contains("points to itself"));
}

unittest
{
    // synthesizeWhenAliasForHasDuplicateAttributeDeclaration
    const e = expectThrows!AnnotationConfigurationException(() {
        synthesized!(AliasForWithDuplicateAttributeDeclaration, AliasForWithDuplicateAttributeDeclarationClass)();
    });
    assert(e.msg.startsWith("In @AliasFor declared on attribute 'foo' in annotation"));
    assert(e.msg.contains(typeNameOf!AliasForWithDuplicateAttributeDeclaration));
    assert(e.msg.contains("attribute 'attribute' and its alias 'value' are present with values of 'baz' and 'bar'"));
}

unittest
{
    // synthesizeWhenAttributeAliasForNonexistentAttribute
    const e = expectThrows!AnnotationConfigurationException(() {
        synthesized!(AliasForNonexistentAttribute, AliasForNonexistentAttributeClass)();
    });
    assert(e.msg.startsWith("@AliasFor declaration on attribute 'foo' in annotation"));
    assert(e.msg.contains(typeNameOf!AliasForNonexistentAttribute));
    assert(e.msg.contains("declares an alias for 'bar' which is not present"));
}

unittest
{
    // synthesizeWhenAttributeAliasWithMirroredAliasForWrongAttribute
    const e = expectThrows!AnnotationConfigurationException(() {
        synthesized!(AliasForWithMirroredAliasForWrongAttribute, AliasForWithMirroredAliasForWrongAttributeClass)();
    });
    assert(e.msg == "@AliasFor declaration on attribute 'bar' in annotation ["
            ~ typeNameOf!AliasForWithMirroredAliasForWrongAttribute
            ~ "] declares an alias for 'quux' which is not present.");
}

unittest
{
    // synthesizeWhenAttributeAliasForAttributeOfDifferentType
    const e = expectThrows!AnnotationConfigurationException(() {
        synthesized!(AliasForAttributeOfDifferentType, AliasForAttributeOfDifferentTypeClass)();
    });
    assert(e.msg.startsWith("Misconfigured aliases"));
    assert(e.msg.contains(typeNameOf!AliasForAttributeOfDifferentType));
    assert(e.msg.contains("attribute 'foo'"));
    assert(e.msg.contains("attribute 'bar'"));
    assert(e.msg.contains("same return type"));
}

unittest
{
    // synthesizeWhenAttributeAliasForAttributeWithDifferentDefaultValue
    const e = expectThrows!AnnotationConfigurationException(() {
        synthesized!(AliasForAttributeWithDifferentDefaultValue, AliasForAttributeWithDifferentDefaultValueClass)();
    });
    assert(e.msg.startsWith("Misconfigured aliases"));
    assert(e.msg.contains(typeNameOf!AliasForAttributeWithDifferentDefaultValue));
    assert(e.msg.contains("attribute 'foo' in annotation"));
    assert(e.msg.contains("attribute 'bar' in annotation"));
    assert(e.msg.contains("same default value"));
}

unittest
{
    // synthesizeWhenAttributeAliasForMetaAnnotationThatIsNotMetaPresent
    const e = expectThrows!AnnotationConfigurationException(() {
        synthesized!(AliasedComposedTestConfigurationNotMetaPresent,
            AliasedComposedTestConfigurationNotMetaPresentClass)();
    });
    assert(e.msg.startsWith("@AliasFor declaration on attribute 'xmlConfigFile' in annotation"));
    assert(e.msg.contains(typeNameOf!AliasedComposedTestConfigurationNotMetaPresent));
    assert(e.msg.contains("declares an alias for attribute 'location' in annotation"));
    assert(e.msg.contains(typeNameOf!TestConfiguration));
    assert(e.msg.contains("not meta-present"));
}

// ---------------------------------------------------------------------------------------------------------------
// Implicit aliases

/// `testSynthesisWithImplicitAliases(T.class, expected)`.
private void assertSynthesisWithImplicitAliases(T)(string expected)
{
    const config = synthesized!(ImplicitAliasesTestConfiguration, T)();
    assert(config.value == expected, T.stringof);
    assert(config.location1 == expected, T.stringof);
    assert(config.xmlFile == expected, T.stringof);
    assert(config.groovyScript == expected, T.stringof);
}

/// `testSynthesisWithImplicitAliasesWithImpliedAliasNamesOmitted(T.class, expected)`.
private void assertSynthesisWithImplicitAliasesWithImpliedAliasNamesOmitted(T)(string expected)
{
    const config = synthesized!(ImplicitAliasesWithImpliedAliasNamesOmittedTestConfiguration, T)();
    assert(config.value == expected, T.stringof);
    assert(config.location == expected, T.stringof);
    assert(config.xmlFile == expected, T.stringof);
}

unittest
{
    // synthesizeWithImplicitAliases
    assertSynthesisWithImplicitAliases!ValueImplicitAliasesTestConfigurationClass("value");
    assertSynthesisWithImplicitAliases!Location1ImplicitAliasesTestConfigurationClass("location1");
    assertSynthesisWithImplicitAliases!XmlImplicitAliasesTestConfigurationClass("xmlFile");
    assertSynthesisWithImplicitAliases!GroovyImplicitAliasesSimpleTestConfigurationClass("groovyScript");
}

unittest
{
    // synthesizeWithImplicitAliasesWithImpliedAliasNamesOmitted
    assertSynthesisWithImplicitAliasesWithImpliedAliasNamesOmitted!(
            ValueImplicitAliasesWithImpliedAliasNamesOmittedTestConfigurationClass)("value");
    assertSynthesisWithImplicitAliasesWithImpliedAliasNamesOmitted!(
            LocationsImplicitAliasesWithImpliedAliasNamesOmittedTestConfigurationClass)("location");
    assertSynthesisWithImplicitAliasesWithImpliedAliasNamesOmitted!(
            XmlFilesImplicitAliasesWithImpliedAliasNamesOmittedTestConfigurationClass)("xmlFile");
}

unittest
{
    // synthesizeWithImplicitAliasesForAliasPair
    const config = synthesized!(ImplicitAliasesForAliasPairTestConfiguration,
            ImplicitAliasesForAliasPairTestConfigurationClass)();
    assert(config.xmlFile == "test.xml");
    assert(config.groovyScript == "test.xml");
}

unittest
{
    // synthesizeWithTransitiveImplicitAliases
    const config = synthesized!(TransitiveImplicitAliasesTestConfiguration,
            TransitiveImplicitAliasesTestConfigurationClass)();
    assert(config.xml == "test.xml");
    assert(config.groovy == "test.xml");
}

unittest
{
    // synthesizeWithTransitiveImplicitAliasesForAliasPair
    const config = synthesized!(TransitiveImplicitAliasesForAliasPairTestConfiguration,
            TransitiveImplicitAliasesForAliasPairTestConfigurationClass)();
    assert(config.xml == "test.xml");
    assert(config.groovy == "test.xml");
}

unittest
{
    // synthesizeWithImplicitAliasesWithDifferentDefaultValues
    alias Clazz = ImplicitAliasesWithDifferentDefaultValuesTestConfigurationClass;
    alias AnnotationType = ImplicitAliasesWithDifferentDefaultValuesTestConfiguration;
    const e = expectThrows!AnnotationConfigurationException(() {
        synthesized!(AnnotationType, Clazz)();
    });
    assert(e.msg.startsWith("Misconfigured aliases:"));
    assert(e.msg.contains("attribute 'location1' in annotation [" ~ typeNameOf!AnnotationType ~ "]"));
    assert(e.msg.contains("attribute 'location2' in annotation [" ~ typeNameOf!AnnotationType ~ "]"));
    assert(e.msg.contains("same default value"));
}

unittest
{
    // synthesizeWithImplicitAliasesWithDuplicateValues
    alias Clazz = ImplicitAliasesWithDuplicateValuesTestConfigurationClass;
    alias AnnotationType = ImplicitAliasesWithDuplicateValuesTestConfiguration;
    const e = expectThrows!AnnotationConfigurationException(() {
        synthesized!(AnnotationType, Clazz)();
    });
    assert(e.msg.startsWith("Different @AliasFor mirror values for annotation"));
    assert(e.msg.contains(typeNameOf!AnnotationType));
    assert(e.msg.contains("declared on class"));
    assert(e.msg.contains(typeNameOf!Clazz));
    assert(e.msg.contains("are declared with values of"));
}

// ---------------------------------------------------------------------------------------------------------------
// Synthesis from maps and defaults

version (FlintAnnotationUtilsAttributes)
{
    unittest
    {
        // synthesizeFromMapWithoutAttributeAliases
        const map = singletonMap("value", Any.of("webController"));
        const annotation = MergedAnnotation!Component.of(map);

        const synthesizedComponent = annotation.synthesize();
        assert(synthesizedComponent.value == "webController");
    }

    unittest
    {
        // synthesizeFromMapWithNestedMap
        const componentScan = getUDAs!(ComponentScanSingleFilterClass, ComponentScanSingleFilter)[0];
        assert(componentScan.value.pattern == "*Foo");
        auto map = MergedAnnotation!ComponentScanSingleFilter.from(componentScan).asMap(Adapt.ANNOTATION_TO_MAP);
        auto filterMap = map.get("value").get!(Map!(string, Any));
        assert(filterMap.get("pattern").get!string == "*Foo");
        filterMap.put("pattern", Any.of("newFoo"));
        filterMap.put("enigma", Any.of(42));
        const annotation = MergedAnnotation!ComponentScanSingleFilter.of(map);
        const synthesizedComponentScan = annotation.synthesize();
        assert(synthesizedComponentScan.value.pattern == "newFoo");
    }

    unittest
    {
        // synthesizeFromMapWithNestedArrayOfMaps
        const componentScan = getUDAs!(ComponentScanClass, ComponentScan)[0];
        auto map = MergedAnnotation!ComponentScan.from(componentScan).asMap(Adapt.ANNOTATION_TO_MAP);
        auto filters = map.get("excludeFilters").get!(Map!(string, Any)[]);
        string[] patterns;
        foreach (m; filters)
            patterns ~= m.get("pattern").get!string;
        assert(patterns == ["*Foo", "*Bar"]);
        filters[0].put("pattern", Any.of("newFoo"));
        filters[0].put("enigma", Any.of(42));
        filters[1].put("pattern", Any.of("newBar"));
        filters[1].put("enigma", Any.of(42));
        const annotation = MergedAnnotation!ComponentScan.of(map);
        const synthesizedComponentScan = annotation.synthesize();
        patterns = null;
        foreach (filter; synthesizedComponentScan.excludeFilters)
            patterns ~= filter.pattern;
        assert(patterns == ["newFoo", "newBar"]);
    }

    unittest
    {
        // synthesizeFromDefaultsWithoutAttributeAliases
        const annotation = MergedAnnotation!AnnotationWithDefaults.of();
        const synthesized = annotation.synthesize();
        assert(synthesized.text == "enigma");
        assert(synthesized.predicate);
        assert(synthesized.characters == ['a', 'b', 'c']);
    }

    unittest
    {
        // synthesizeFromDefaultsWithAttributeAliases
        const annotation = MergedAnnotation!TestConfiguration.of();
        const synthesized = annotation.synthesize();
        assert(synthesized.value.length == 0);
        assert(synthesized.location.length == 0);
    }
}

unittest
{
    // synthesizeWhenAttributeAliasesWithDifferentValues
    expectThrows!AnnotationConfigurationException(() {
        synthesized!(TestConfiguration, TestConfigurationMismatch)();
    });
}

version (FlintAnnotationUtilsAttributes)
{
    unittest
    {
        // synthesizeFromMapWithMinimalAttributesWithAttributeAliases
        const map = singletonMap("location", Any.of("test.xml"));
        const annotation = MergedAnnotation!TestConfiguration.of(map);
        const synthesized = annotation.synthesize();
        assert(synthesized.value == "test.xml");
        assert(synthesized.location == "test.xml");
    }

    private void synthesizeFromMapWithAttributeAliasesThatOverrideArraysWithSingleElements(Map!(string, Any) map)
    {
        const annotation = MergedAnnotation!GetMapping.of(map);
        const synthesized = annotation.synthesize();
        assert(synthesized.value == "/foo");
        assert(synthesized.path == "/foo");
    }

    unittest
    {
        // synthesizeFromMapWithAttributeAliasesThatOverrideArraysWithSingleElements
        auto map = singletonMap("value", Any.of("/foo"));
        synthesizeFromMapWithAttributeAliasesThatOverrideArraysWithSingleElements(map);
        map = singletonMap("path", Any.of("/foo"));
        synthesizeFromMapWithAttributeAliasesThatOverrideArraysWithSingleElements(map);
    }

    private void assertSynthesisFromMapWithImplicitAliases(string attributeNameAndValue)
    {
        const map = singletonMap(attributeNameAndValue, Any.of(attributeNameAndValue));
        const annotation = MergedAnnotation!ImplicitAliasesTestConfiguration.of(map);
        const synthesized = annotation.synthesize();

        assert(synthesized.value == attributeNameAndValue);
        assert(synthesized.location1 == attributeNameAndValue);
        assert(synthesized.location2 == attributeNameAndValue);
        assert(synthesized.location2 == attributeNameAndValue);
        assert(synthesized.xmlFile == attributeNameAndValue);
        assert(synthesized.groovyScript == attributeNameAndValue);
    }

    unittest
    {
        // synthesizeFromMapWithImplicitAttributeAliases
        assertSynthesisFromMapWithImplicitAliases("value");
        assertSynthesisFromMapWithImplicitAliases("location1");
        assertSynthesisFromMapWithImplicitAliases("location2");
        assertSynthesisFromMapWithImplicitAliases("location3");
        assertSynthesisFromMapWithImplicitAliases("xmlFile");
        assertSynthesisFromMapWithImplicitAliases("groovyScript");
    }

    unittest
    {
        // synthesizeFromMapWithAttributeOfIncorrectType
        const map = singletonMap("value", Any.of(42L));
        const annotation = MergedAnnotation!Component.of(map);
        const e = expectThrows!IllegalStateException(() { annotation.synthesize().value; });
        assert(e.msg == "Attribute 'value' in annotation " ~ typeNameOf!Component
                ~ " should be compatible with string but a long value was returned");
    }

    unittest
    {
        // synthesizeFromMapWithAttributeOfIncorrectArrayType
        const map = singletonMap("value", Any.of([42]));
        const annotation = MergedAnnotation!TestPropertySource.of(map);
        const e = expectThrows!IllegalStateException(() { annotation.synthesize().value; });
        assert(e.msg == "Attribute 'value' in annotation " ~ typeNameOf!TestPropertySource
                ~ " should be compatible with string[] but a int[] value was returned");
    }

    unittest
    {
        // synthesizeFromAnnotationAttributesWithoutAttributeAliases
        const component = getUDAs!(WebController, Component)[0];
        const attributes = MergedAnnotation!Component.from(component).asMap();

        const synthesized = MergedAnnotation!Component.of(attributes).synthesize();
        assert(synthesized == component);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Equality and arrays

unittest
{
    // equalsForSynthesizedAnnotations
    const webMappingWithAliases = getUDAs!(WebController.handleMappedWithPathAttribute, RequestMapping)[0];
    const webMappingWithPathAndValue = getUDAs!(WebController.handleMappedWithSamePathAndValueAttributes,
            RequestMapping)[0];
    const synthesizedWebMapping1 = fromElement!(WebController.handleMappedWithPathAttribute)().get!RequestMapping()
        .synthesize();
    const synthesizedWebMapping2 = fromElement!(WebController.handleMappedWithSamePathAndValueAttributes)()
        .get!RequestMapping().synthesize();
    // Equality amongst standard annotations
    assert(webMappingWithAliases == webMappingWithAliases);
    assert(webMappingWithPathAndValue == webMappingWithPathAndValue);
    // Inequality amongst standard annotations
    assert(webMappingWithAliases != webMappingWithPathAndValue);
    assert(webMappingWithPathAndValue != webMappingWithAliases);
    // Equality amongst synthesized annotations
    assert(synthesizedWebMapping1 == synthesizedWebMapping1);
    assert(synthesizedWebMapping2 == synthesizedWebMapping2);
    assert(synthesizedWebMapping1 == synthesizedWebMapping2);
    assert(synthesizedWebMapping2 == synthesizedWebMapping1);
    // Equality between standard and synthesized annotations
    assert(synthesizedWebMapping1 == webMappingWithPathAndValue);
    assert(webMappingWithPathAndValue == synthesizedWebMapping1);
    // Inequality between standard and synthesized annotations
    assert(synthesizedWebMapping1 != webMappingWithAliases);
    assert(webMappingWithAliases != synthesizedWebMapping1);
}

unittest
{
    // hashCodeForSynthesizedAnnotations
    const webMappingWithAliases = getUDAs!(WebController.handleMappedWithPathAttribute, RequestMapping)[0];
    const webMappingWithPathAndValue = getUDAs!(WebController.handleMappedWithSamePathAndValueAttributes,
            RequestMapping)[0];
    const synthesizedWebMapping1 = fromElement!(WebController.handleMappedWithPathAttribute)().get!RequestMapping()
        .synthesize();
    const synthesizedWebMapping2 = fromElement!(WebController.handleMappedWithSamePathAndValueAttributes)()
        .get!RequestMapping().synthesize();
    // Equality amongst standard annotations
    assert(hashOf(webMappingWithAliases) == hashOf(webMappingWithAliases));
    assert(hashOf(webMappingWithPathAndValue) == hashOf(webMappingWithPathAndValue));
    // Inequality amongst standard annotations
    assert(hashOf(webMappingWithAliases) != hashOf(webMappingWithPathAndValue));
    assert(hashOf(webMappingWithPathAndValue) != hashOf(webMappingWithAliases));
    // Equality amongst synthesized annotations
    assert(hashOf(synthesizedWebMapping1) == hashOf(synthesizedWebMapping1));
    assert(hashOf(synthesizedWebMapping2) == hashOf(synthesizedWebMapping2));
    assert(hashOf(synthesizedWebMapping1) == hashOf(synthesizedWebMapping2));
    assert(hashOf(synthesizedWebMapping2) == hashOf(synthesizedWebMapping1));
    // Equality between standard and synthesized annotations
    assert(hashOf(synthesizedWebMapping1) == hashOf(webMappingWithPathAndValue));
    assert(hashOf(webMappingWithPathAndValue) == hashOf(synthesizedWebMapping1));
    // Inequality between standard and synthesized annotations
    assert(hashOf(synthesizedWebMapping1) != hashOf(webMappingWithAliases));
    assert(hashOf(webMappingWithAliases) != hashOf(synthesizedWebMapping1));
}

// Behaviour: @AliasFor mirrors are resolved only in the merged annotation itself, not in nested annotation values:
// the synthesized Hierarchy holds TestConfiguration(value: "A", location: "") and (value: "", location: "B").
version (FlintAliasForNestedAnnotations)
{
    unittest
    {
        // synthesizeWithArrayOfAnnotations
        const synthesizedHierarchy = synthesized!(Hierarchy, HierarchyClass)();
        auto configs = synthesizedHierarchy.value.dup;
        string[] values, locations;
        foreach (config; configs)
        {
            values ~= config.value;
            locations ~= config.location;
        }
        assert(values == ["A", "B"]);
        assert(locations == ["A", "B"]);

        const contextConfig = getUDAs!(TestConfigurationClass, TestConfiguration)[0];
        // Alter array returned from synthesized annotation
        configs[0] = contextConfig;
        assert(configs[0].value == "simple.xml" && configs[1].value == "B");
        // Re-retrieve the array from the synthesized annotation
        configs = synthesizedHierarchy.value.dup;
        assert(configs[0].value == "A" && configs[1].value == "B");
    }
}

unittest
{
    // synthesizeWithArrayOfChars
    const synthesizedCharsContainer = synthesized!(CharsContainer, GroupOfCharsClass)();
    auto chars = synthesizedCharsContainer.chars.dup;
    assert(chars == ['x', 'y', 'z']);
    // Alter array returned from synthesized annotation
    chars[0] = '?';
    // Re-retrieve the array from the synthesized annotation
    chars = synthesizedCharsContainer.chars.dup;
    assert(chars == ['x', 'y', 'z']);
}

version (FlintAnnotationUtilsAttributes)
{
    unittest
    {
        // asAnnotationAttributesReturnsPopulatedAnnotationAttributes
        const annotation = from!SpringApplicationConfigurationClass().get!SpringApplicationConfiguration();
        const attributes = annotation.asAnnotationAttributes(Adapt.CLASS_TO_STRING);
        assert(attributes.getStringArray("classes") == [typeNameOf!Number]);
        assert(attributes.annotationType() == typeNameOf!SpringApplicationConfiguration);
    }
}
