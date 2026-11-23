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
 * spring-core/src/test/java/org/springframework/core/env/{PropertySourcesPropertyResolverTests,
 * AbstractPropertyResolverTests}.java. The `testProperties` java.util.Properties source is a MapPropertySource over
 * a LinkedHashMap named "testProperties".
 *
 * Skipped Java tests:
 * - AbstractPropertyResolverTests (all 7: getDefaultEscapeCharacterWithSpringPropertySetToCharacterMinValue,
 *   getDefaultEscapeCharacterWithSpringPropertySetToXyz, getDefaultEscapeCharacterWithSpringPropertySetToEmptyString,
 *   getDefaultEscapeCharacterWithoutSpringPropertySet, getDefaultEscapeCharacterWithSpringPropertySetToBackslash,
 *   getDefaultEscapeCharacterWithSpringPropertySetToTilde, getDefaultEscapeCharacterFromMultipleThreads): they test
 *   the static, lazily cached `defaultEscapeCharacter` read from SpringProperties; Flint has no SpringProperties and
 *   keeps no mutable module-level state (ADR-030 section 4), so the escape character is a per-resolver setting.
 * - resolveNestedPlaceholdersIfValueIsCharSequence,
 *   resolveNestedPlaceholdersIfValueIsCharSequenceAndStringBuilderIsRequested,
 *   EscapedPlaceholderTests.escapedPlaceholdersAreNotEvaluatedWithCharSequenceValues: Java's CharSequence and
 *   StringBuilder values; D property values are strings.
 */
module flint.core.env_resolver_test;

import flint.core.convert : ConverterNotFoundException;
import flint.core.env : ConfigurablePropertyResolver, MapPropertySource, MissingRequiredPropertiesException,
    MutablePropertySources, PropertyResolver, PropertySourcesPropertyResolver;
import flint.core.testfixture : MockPropertySource;
import flint.engine.aot.any : Any;
import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.java.util : HashMap, LinkedHashMap, Map;
import flint.util : PlaceholderResolutionException;
import std.exception : collectException;

@safe:

private struct Fixture
{
    Map!(string, Any) testProperties;
    MutablePropertySources propertySources;
    PropertySourcesPropertyResolver propertyResolver;
}

private Fixture setUp()
{
    Fixture f;
    f.testProperties = new LinkedHashMap!(string, Any)();
    f.propertySources = new MutablePropertySources;
    f.propertyResolver = new PropertySourcesPropertyResolver(f.propertySources);
    f.propertySources.addFirst(new MapPropertySource("testProperties", f.testProperties));
    return f;
}

private bool contains(string text, string part)
{
    import std.string : indexOf;

    return text.indexOf(part) >= 0;
}

unittest
{
    // containsProperty
    auto f = setUp();
    assert(!f.propertyResolver.containsProperty("foo"));
    f.testProperties.put("foo", Any.of("bar"));
    assert(f.propertyResolver.containsProperty("foo"));
}

unittest
{
    // getProperty
    auto f = setUp();
    assert(f.propertyResolver.getProperty("foo") is null);
    f.testProperties.put("foo", Any.of("bar"));
    assert(f.propertyResolver.getProperty("foo") == "bar");
}

unittest
{
    // getProperty_withDefaultValue
    auto f = setUp();
    assert(f.propertyResolver.getProperty("foo", "myDefault") == "myDefault");
    f.testProperties.put("foo", Any.of("bar"));
    assert(f.propertyResolver.getProperty("foo") == "bar");
}

unittest
{
    // getProperty_propertySourceSearchOrderIsFIFO
    auto f = setUp();
    f.propertySources.addFirst(new MockPropertySource("ps1").withProperty("pName", "ps1Value"));
    assert(f.propertyResolver.getProperty("pName") == "ps1Value");
    f.propertySources.addFirst(new MockPropertySource("ps2").withProperty("pName", "ps2Value"));
    assert(f.propertyResolver.getProperty("pName") == "ps2Value");
    f.propertySources.addFirst(new MockPropertySource("ps3").withProperty("pName", "ps3Value"));
    assert(f.propertyResolver.getProperty("pName") == "ps3Value");
}

unittest
{
    // getProperty_withExplicitNullValue
    auto f = setUp();
    auto nullableProperties = new HashMap!(string, Any)();
    f.propertySources.addLast(new MapPropertySource("nullableProperties", nullableProperties));
    nullableProperties.put("foo", Any.init);
    assert(f.propertyResolver.getProperty("foo") is null);
}

unittest
{
    // getProperty_withTargetType_andDefaultValue
    auto f = setUp();
    assert(f.propertyResolver.getProperty!int("foo", 42) == 42);
    f.testProperties.put("foo", Any.of(13));
    assert(f.propertyResolver.getProperty!int("foo", 42) == 13);
}

unittest
{
    // getProperty_withStringArrayConversion
    auto f = setUp();
    f.testProperties.put("foo", Any.of("bar,baz"));
    assert(f.propertyResolver.getProperty!(string[])("foo") == ["bar", "baz"]);
}

private class TestType
{
}

unittest
{
    // getProperty_withNonConvertibleTargetType
    auto f = setUp();
    f.testProperties.put("foo", Any.of("bar"));
    assert(collectException!ConverterNotFoundException(f.propertyResolver.getProperty!TestType("foo")) !is null);
}

unittest
{
    // getProperty_doesNotCache_replaceExistingKeyPostConstruction
    auto f = setUp();
    const key = "foo";
    const value1 = "bar";
    const value2 = "biz";
    auto map = new HashMap!(string, Any)();
    map.put(key, Any.of(value1)); // before construction
    f.propertySources.addFirst(new MapPropertySource("testProperties", map));
    PropertyResolver propertyResolver = new PropertySourcesPropertyResolver(f.propertySources);
    assert(propertyResolver.getProperty(key) == value1);
    map.put(key, Any.of(value2)); // after construction and first resolution
    assert(propertyResolver.getProperty(key) == value2);
}

unittest
{
    // getProperty_doesNotCache_addNewKeyPostConstruction
    auto f = setUp();
    auto map = new HashMap!(string, Any)();
    f.propertySources.addFirst(new MapPropertySource("testProperties", map));
    PropertyResolver propertyResolver = new PropertySourcesPropertyResolver(f.propertySources);
    assert(propertyResolver.getProperty("foo") is null);
    map.put("foo", Any.of("42"));
    assert(propertyResolver.getProperty("foo") == "42");
}

unittest
{
    // getPropertySources_replacePropertySource
    auto f = setUp();
    f.propertySources.addLast(new MockPropertySource("local").withProperty("foo", "localValue"));
    f.propertySources.addLast(new MockPropertySource("system").withProperty("foo", "systemValue"));
    assert(f.propertySources.size() == 3);
    // 'local' was added first so has precedence
    assert(f.propertyResolver.getProperty("foo") == "localValue");
    // replace 'local' with new property source
    f.propertySources.replace("local", new MockPropertySource("new").withProperty("foo", "newValue"));
    // 'system' now has precedence
    assert(f.propertyResolver.getProperty("foo") == "newValue");
    assert(f.propertySources.size() == 3);
}

unittest
{
    // getRequiredProperty
    auto f = setUp();
    f.testProperties.put("exists", Any.of("xyz"));
    assert(f.propertyResolver.getRequiredProperty("exists") == "xyz");
    const e = collectException!IllegalStateException(f.propertyResolver.getRequiredProperty("bogus"));
    assert(e !is null && e.msg == "Required key 'bogus' not found");
}

unittest
{
    // getRequiredProperty_withStringArrayConversion
    auto f = setUp();
    f.testProperties.put("exists", Any.of("abc,123"));
    assert(f.propertyResolver.getRequiredProperty!(string[])("exists") == ["abc", "123"]);
    assert(collectException!IllegalStateException(f.propertyResolver.getRequiredProperty!(string[])("bogus")) !is null);
}

unittest
{
    // resolvePlaceholders
    auto f = setUp();
    f.propertySources.addFirst(new MockPropertySource().withProperty("key", "value"));
    assert(f.propertyResolver.resolvePlaceholders("Replace this ${key}") == "Replace this value");
}

unittest
{
    // resolvePlaceholders_withUnresolvable
    auto f = setUp();
    f.propertySources.addFirst(new MockPropertySource().withProperty("key", "value"));
    assert(f.propertyResolver.resolvePlaceholders(
            "Replace this ${key} plus ${unknown}") == "Replace this value plus ${unknown}");
}

unittest
{
    // resolvePlaceholders_withDefaultValue
    auto f = setUp();
    f.propertySources.addFirst(new MockPropertySource().withProperty("key", "value"));
    assert(f.propertyResolver.resolvePlaceholders(
            "Replace this ${key} plus ${unknown:defaultValue}") == "Replace this value plus defaultValue");
}

unittest
{
    // NEEDS-UTIL: PropertyPlaceholderHelper.replacePlaceholders asserts that the value is not null
    // resolvePlaceholders_withNullInput
    version (none)
    {
        auto f = setUp();
        assert(collectException!IllegalArgumentException(f.propertyResolver.resolvePlaceholders(null)) !is null);
    }
}

unittest
{
    // resolveRequiredPlaceholders
    auto f = setUp();
    f.propertySources.addFirst(new MockPropertySource().withProperty("key", "value"));
    assert(f.propertyResolver.resolveRequiredPlaceholders("Replace this ${key}") == "Replace this value");
}

unittest
{
    // resolveRequiredPlaceholders_withUnresolvable
    auto f = setUp();
    f.propertySources.addFirst(new MockPropertySource().withProperty("key", "value"));
    assert(collectException!PlaceholderResolutionException(
            f.propertyResolver.resolveRequiredPlaceholders("Replace this ${key} plus ${unknown}")) !is null);
}

unittest
{
    // resolveRequiredPlaceholders_withDefaultValue
    auto f = setUp();
    f.propertySources.addFirst(new MockPropertySource().withProperty("key", "value"));
    assert(f.propertyResolver.resolveRequiredPlaceholders(
            "Replace this ${key} plus ${unknown:defaultValue}") == "Replace this value plus defaultValue");
}

unittest
{
    // NEEDS-UTIL: PropertyPlaceholderHelper.replacePlaceholders asserts that the value is not null
    // resolveRequiredPlaceholders_withNullInput
    version (none)
    {
        auto resolver = setUp().propertyResolver;
        assert(collectException!IllegalArgumentException(resolver.resolveRequiredPlaceholders(null)) !is null);
    }
}

unittest
{
    // setRequiredProperties_andValidateRequiredProperties
    auto f = setUp();
    // no properties have been marked as required -> validation should pass
    f.propertyResolver.validateRequiredProperties();
    // mark which properties are required
    f.propertyResolver.setRequiredProperties("foo", "bar");
    // neither foo nor bar properties are present -> validating should throw
    auto e = collectException!MissingRequiredPropertiesException(f.propertyResolver.validateRequiredProperties());
    enum message = "The following properties were declared as required but could not be resolved: ";
    assert(e !is null && e.msg == message ~ "[foo, bar]");
    // add foo property -> validation should fail only on missing 'bar' property
    f.testProperties.put("foo", Any.of("fooValue"));
    e = collectException!MissingRequiredPropertiesException(f.propertyResolver.validateRequiredProperties());
    assert(e !is null
            && e.msg == "The following properties were declared as required " ~ "but could not be resolved: [bar]");
    // add bar property -> validation should pass, even with an empty string value
    f.testProperties.put("bar", Any.of(""));
    f.propertyResolver.validateRequiredProperties();
}

unittest
{
    // NEEDS-UTIL: Spring's exact "Could not resolve placeholder ... in value" message and circular-reference detection
    // resolveNestedPropertyPlaceholders
    version (none)
    {
        auto ps = new MutablePropertySources;
        ps.addFirst(new MockPropertySource().withProperty("p1", "v1").withProperty("p2", "v2")
                .withProperty("p3", "${p1}:${p2}") // nested placeholders
                .withProperty("p4", "${p3}") // deeply nested placeholders
                .withProperty("p5", "${p1}:${p2}:${bogus}") // unresolvable placeholder
                .withProperty("p6",
                    "${p1}:${p2}:${bogus:def}") // unresolvable w/ default
                .withProperty("pL", "${pR}") // cyclic reference left
                .withProperty("pR", "${pL}")); // cyclic reference right
        ConfigurablePropertyResolver pr = new PropertySourcesPropertyResolver(ps);
        assert(pr.getProperty("p1") == "v1");
        assert(pr.getProperty("p2") == "v2");
        assert(pr.getProperty("p3") == "v1:v2");
        assert(pr.getProperty("p4") == "v1:v2");
        auto e = collectException!PlaceholderResolutionException(pr.getProperty("p5"));
        assert(e !is null && contains(e.msg, `Could not resolve placeholder 'bogus' in value "${p1}:${p2}:${bogus}"`));
        assert(pr.getProperty("p6") == "v1:v2:def");
        e = collectException!PlaceholderResolutionException(pr.getProperty("pL"));
        assert(e !is null && contains(e.msg, "Circular"));
    }
}

unittest
{
    // resolveNestedPlaceHolderIfValueShouldConvertToOtherTypes
    auto ps = new MutablePropertySources;
    ps.addFirst(new MockPropertySource().withProperty("new.enabled", "${old.enabled:true}"));
    ConfigurablePropertyResolver pr = new PropertySourcesPropertyResolver(ps);
    assert(pr.getProperty!bool("new.enabled", false));
}

unittest
{
    // NEEDS-UTIL: Spring's exact "Could not resolve placeholder ... in value" message
    // ignoreUnresolvableNestedPlaceholdersIsConfigurable
    version (none)
    {
        enum message = `Could not resolve placeholder 'bogus' in value "${p1}:${p2}:${bogus}"`;
        auto ps = new MutablePropertySources;
        ps.addFirst(new MockPropertySource().withProperty("p1", "v1").withProperty("p2", "v2")
                .withProperty("p3", "${p1}:${p2}:${bogus:def}") // unresolvable w/ default
                .withProperty("p4", "${p1}:${p2}:${bogus}")); // unresolvable placeholder
        ConfigurablePropertyResolver pr = new PropertySourcesPropertyResolver(ps);
        assert(pr.getProperty("p1") == "v1");
        assert(pr.getProperty("p2") == "v2");
        assert(pr.getProperty("p3") == "v1:v2:def");
        // placeholders nested within the value of "p4" are unresolvable and cause an exception by default
        auto e = collectException!PlaceholderResolutionException(pr.getProperty("p4"));
        assert(e !is null && contains(e.msg, message));
        // relax the treatment of unresolvable nested placeholders and observe they now pass through unresolved
        pr.setIgnoreUnresolvableNestedPlaceholders(true);
        assert(pr.getProperty("p4") == "v1:v2:${bogus}");
        // resolve[Nested]Placeholders methods behave as usual regardless of ignoreUnresolvableNestedPlaceholders
        assert(pr.resolvePlaceholders("${p1}:${p2}:${bogus}") == "v1:v2:${bogus}");
        e = collectException!PlaceholderResolutionException(pr.resolveRequiredPlaceholders("${p1}:${p2}:${bogus}"));
        assert(e !is null && contains(e.msg, message));
    }
}

// EscapedPlaceholderTests

unittest
{
    // NEEDS-UTIL: placeholder escapes (gh-34720)
    // escapedPlaceholdersAreNotEvaluated
    version (none)
    {
        auto f = setUp();
        f.testProperties.put("prop1", Any.of("value1"));
        f.testProperties.put("prop2", Any.of(`value2\${prop1}`));
        assert(f.propertyResolver.getProperty("prop2") == "value2${prop1}");
    }
}

unittest
{
    // NEEDS-UTIL: placeholder escapes (gh-34720)
    // multipleEscapedPlaceholdersArePreserved
    version (none)
    {
        auto f = setUp();
        f.testProperties.put("prop1", Any.of("value1"));
        f.testProperties.put("prop2", Any.of("value2"));
        f.testProperties.put("complex", Any.of(`start\${prop1}middle\${prop2}end`));
        assert(f.propertyResolver.getProperty("complex") == "start${prop1}middle${prop2}end");
    }
}

unittest
{
    // NEEDS-UTIL: placeholder escapes (gh-34720)
    // doubleBackslashesAreProcessedCorrectly
    version (none)
    {
        auto f = setUp();
        f.testProperties.put("prop1", Any.of("value1"));
        f.testProperties.put("doubleEscaped", Any.of(`value2\\${prop1}`));
        assert(f.propertyResolver.getProperty("doubleEscaped") == `value2\${prop1}`);
    }
}

unittest
{
    // NEEDS-UTIL: placeholder escapes (gh-34720)
    // escapedPlaceholdersInNestedPropertiesAreNotEvaluated
    version (none)
    {
        auto f = setUp();
        f.testProperties.put("p1", Any.of("v1"));
        f.testProperties.put("p2", Any.of("v2"));
        f.testProperties.put("escaped", Any.of(`prefix-\${p1}`));
        f.testProperties.put("nested", Any.of("${escaped}-${p2}"));
        assert(f.propertyResolver.getProperty("nested") == "prefix-${p1}-v2");
    }
}
