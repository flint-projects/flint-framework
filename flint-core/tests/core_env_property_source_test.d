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
 * spring-core/src/test/java/org/springframework/core/env/{PropertySourceTests,CompositePropertySourceTests,
 * MutablePropertySourcesTests,SystemEnvironmentPropertySourceTests}.java.
 *
 * Skipped Java tests:
 * - PropertySourceTests.toStringDoesNotDependOnLogLevel: asserts on PropertySource's commons-logging logger, which
 *   Flint's PropertySource does not carry.
 * Adapted: the PropertiesPropertySource assertions in PropertySourceTests.equals and toStringUsesConciseFormat are
 * dropped (Flint has no java.util.Properties, so no PropertiesPropertySource); the MapPropertySource ones are kept.
 */
module flint.core.env_property_source_test;

import flint.core.env : CompositePropertySource, MapPropertySource, MutablePropertySources,
    PropertySource, SystemEnvironmentPropertySource;
import flint.core.testfixture : MockPropertySource;
import flint.engine.aot.any : Any;
import flint.engine.aot.objects : objectEquals, objectToString;
import flint.java.lang : IllegalArgumentException, UnsupportedOperationException;
import flint.java.util : ArrayList, HashMap, List, Map;
import std.exception : collectException;

@safe:

private Map!(string, Any) mapOf(string[] keysAndValues...)
{
    auto map = new HashMap!(string, Any)();
    for (size_t i = 0; i + 1 < keysAndValues.length; i += 2)
        map.put(keysAndValues[i], Any.of(keysAndValues[i + 1]));
    return map;
}

private bool sameSource(Object a, Object b)
{
    return objectEquals(a, b);
}

private bool hasSubsequence(string text, string[] parts...)
{
    import std.string : indexOf;

    size_t from;
    foreach (part; parts)
    {
        const index = text[from .. $].indexOf(part);
        if (index < 0)
            return false;
        from += index + part.length;
    }
    return true;
}

private string stringProperty(PropertySource ps, string name)
{
    auto value = ps.getProperty(name);
    return value.isNull ? null : value.get!string;
}

// PropertySourceTests

unittest
{
    // equals
    auto map1 = mapOf("a", "b");
    auto map2 = mapOf("c", "d");
    auto mps = new MapPropertySource("mps", map1);
    assert(sameSource(mps, mps));
    assert(sameSource(new MapPropertySource("x", map1), new MapPropertySource("x", map1)));
    assert(sameSource(new MapPropertySource("x", map1), new MapPropertySource("x", map2)));
    assert(!sameSource(new MapPropertySource("x", map1), new Object));
    assert(!sameSource(new MapPropertySource("x", map1), new MapPropertySource("y", map1)));
    assert(!sameSource(new MapPropertySource("x", map1), new MapPropertySource("y", map2)));
}

unittest
{
    // collectionsOperations
    auto map1 = mapOf("a", "b");
    auto map2 = mapOf("c", "d");
    PropertySource ps1 = new MapPropertySource("ps1", map1);
    ps1.getSource();
    List!PropertySource propertySources = new ArrayList!PropertySource();
    assert(propertySources.add(ps1));
    assert(propertySources.contains(ps1));
    assert(propertySources.contains(PropertySource.named("ps1")));
    PropertySource ps1replacement = new MapPropertySource("ps1", map2); // notice - different map
    assert(propertySources.add(ps1replacement)); // true because the list allows duplicates
    assert(propertySources.size() == 2);
    assert(propertySources.remove(PropertySource.named("ps1")));
    assert(propertySources.size() == 1);
    assert(propertySources.remove(PropertySource.named("ps1")));
    assert(propertySources.isEmpty());
    PropertySource ps2 = new MapPropertySource("ps2", map2);
    propertySources.add(ps1);
    propertySources.add(ps2);
    assert(propertySources.indexOf(PropertySource.named("ps1")) == 0);
    assert(propertySources.indexOf(PropertySource.named("ps2")) == 1);
    propertySources.clear();
}

unittest
{
    // toStringUsesConciseFormat
    assert(objectToString(new MapPropertySource("mps", mapOf("a", "b"))) == "MapPropertySource {name='mps'}");
    assert(objectToString(new SystemEnvironmentPropertySource("seps", mapOf("A",
            "b"))) == "SystemEnvironmentPropertySource {name='seps'}");
}

// CompositePropertySourceTests

unittest
{
    // addFirst
    PropertySource p1 = new MapPropertySource("p1", mapOf());
    PropertySource p2 = new MapPropertySource("p2", mapOf());
    PropertySource p3 = new MapPropertySource("p3", mapOf());
    auto composite = new CompositePropertySource("c");
    composite.addPropertySource(p2);
    composite.addPropertySource(p3);
    composite.addPropertySource(p1);
    composite.addFirstPropertySource(p1);
    string[] names;
    foreach (source; composite.getPropertySources())
        names ~= source.getName();
    assert(names == ["p1", "p2", "p3"]);
    assert(hasSubsequence(objectToString(composite), "name='p1'", "name='p2'", "name='p3'"));
}

unittest
{
    // getPropertyNamesRemovesDuplicates
    auto composite = new CompositePropertySource("c");
    composite.addPropertySource(new MapPropertySource("p1", mapOf("p1.property", "value")));
    composite.addPropertySource(new MapPropertySource("p2", mapOf("p2.property1", "value",
            "p1.property", "value", "p2.property2", "value")));
    auto names = composite.getPropertyNames();
    assert(names.length == 3);
    foreach (expected; ["p1.property", "p2.property1", "p2.property2"])
    {
        bool found;
        foreach (name; names)
            found |= name == expected;
        assert(found, expected);
    }
}

unittest
{
    // toStringUsesConciseFormatForNestedPropertySources
    auto composite = new CompositePropertySource("c");
    composite.addPropertySource(new MapPropertySource("p1", mapOf("p1.property", "value")));
    composite.addPropertySource(new MapPropertySource("p2", mapOf("p2.property", "value")));
    assert(objectToString(composite) == "CompositePropertySource {name='c', propertySources="
            ~ "[MapPropertySource {name='p1'}, MapPropertySource {name='p2'}]}");
}

// MutablePropertySourcesTests

private void assertPrecedence(MutablePropertySources sources, string[] names...)
{
    foreach (i, name; names)
        assert(sources.precedenceOf(PropertySource.named(name)) == i, name);
}

private void assertRelativeAdditionRules(MutablePropertySources sources)
{
    auto e = collectException!IllegalArgumentException(sources.addAfter("bogus", new MockPropertySource("h")));
    assert(e !is null && e.msg == "PropertySource named 'bogus' does not exist");
    sources.addFirst(new MockPropertySource("a"));
    assert(sources.size() == 7);
    assertPrecedence(sources, "a", "b", "c");
    sources.replace("a", new MockPropertySource("a-replaced"));
    assert(sources.size() == 7);
    assertPrecedence(sources, "a-replaced", "b", "c");
    sources.replace("a-replaced", new MockPropertySource("a"));
    e = collectException!IllegalArgumentException(sources.replace("bogus", new MockPropertySource("bogus-replaced")));
    assert(e !is null && e.msg == "PropertySource named 'bogus' does not exist");
    e = collectException!IllegalArgumentException(sources.addBefore("b", new MockPropertySource("b")));
    assert(e !is null && e.msg == "PropertySource named 'b' cannot be added relative to itself");
    e = collectException!IllegalArgumentException(sources.addAfter("b", new MockPropertySource("b")));
    assert(e !is null && e.msg == "PropertySource named 'b' cannot be added relative to itself");
}

unittest
{
    // test
    auto sources = new MutablePropertySources;
    sources.addLast(new MockPropertySource("b").withProperty("p1", "bValue"));
    sources.addLast(new MockPropertySource("d").withProperty("p1", "dValue"));
    sources.addLast(new MockPropertySource("f").withProperty("p1", "fValue"));
    assert(sources.size() == 3);
    foreach (name; ["a", "c", "e", "g"])
        assert(!sources.contains(name));
    foreach (name; ["b", "d", "f"])
        assert(sources.contains(name));
    assert(sources.get("b") !is null);
    assert(stringProperty(sources.get("b"), "p1") == "bValue");
    assert(sources.get("d") !is null);
    assert(stringProperty(sources.get("d"), "p1") == "dValue");
    sources.addBefore("b", new MockPropertySource("a"));
    sources.addAfter("b", new MockPropertySource("c"));
    assert(sources.size() == 5);
    assertPrecedence(sources, "a", "b", "c", "d", "f");
    sources.addBefore("f", new MockPropertySource("e"));
    sources.addAfter("f", new MockPropertySource("g"));
    assert(sources.size() == 7);
    assertPrecedence(sources, "a", "b", "c", "d", "e", "f", "g");
    sources.addLast(new MockPropertySource("a"));
    assert(sources.size() == 7);
    assertPrecedence(sources, "b", "c", "d", "e", "f", "g", "a");
    sources.addFirst(new MockPropertySource("a"));
    assert(sources.size() == 7);
    assertPrecedence(sources, "a", "b", "c", "d", "e", "f", "g");
    assert(sameSource(PropertySource.named("a"), sources.remove("a")));
    assert(sources.size() == 6);
    assert(!sources.contains("a"));
    assert(sources.remove("a") is null);
    assert(sources.size() == 6);
    assertRelativeAdditionRules(sources);
}

unittest
{
    // getNonExistentPropertySourceReturnsNull
    auto sources = new MutablePropertySources;
    assert(sources.get("bogus") is null);
}

unittest
{
    // iteratorContainsPropertySource
    auto sources = new MutablePropertySources;
    sources.addLast(new MockPropertySource("test"));
    auto it = sources.iterator();
    assert(it.hasNext());
    assert(it.next().getName() == "test");
    assert(collectException!UnsupportedOperationException(it.remove()) !is null);
    assert(!it.hasNext());
}

unittest
{
    // iteratorIsEmptyForEmptySources
    auto sources = new MutablePropertySources;
    auto it = sources.iterator();
    assert(!it.hasNext());
}

unittest
{
    // streamContainsPropertySource
    auto sources = new MutablePropertySources;
    sources.addLast(new MockPropertySource("test"));
    assert(sources.stream() !is null);
    assert(sources.stream().count() == 1);
    assert(sources.stream().anyMatch((PropertySource source) => "test" == source.getName()));
    assert(!sources.stream().anyMatch((PropertySource source) => "bogus" == source.getName()));
}

unittest
{
    // streamIsEmptyForEmptySources
    auto sources = new MutablePropertySources;
    assert(sources.stream() !is null);
    assert(sources.stream().count() == 0);
}

// SystemEnvironmentPropertySourceTests

unittest
{
    // none
    auto ps = new SystemEnvironmentPropertySource("sysEnv", new HashMap!(string, Any)());
    assert(!ps.containsProperty("a.key"));
    assert(ps.getProperty("a.key").isNull);
}

unittest
{
    // normalWithoutPeriod
    auto envMap = new HashMap!(string, Any)();
    PropertySource ps = new SystemEnvironmentPropertySource("sysEnv", envMap);
    envMap.put("akey", Any.of("avalue"));
    assert(ps.containsProperty("akey"));
    assert(stringProperty(ps, "akey") == "avalue");
}

unittest
{
    // normalWithPeriod
    auto envMap = new HashMap!(string, Any)();
    PropertySource ps = new SystemEnvironmentPropertySource("sysEnv", envMap);
    envMap.put("a.key", Any.of("a.value"));
    assert(ps.containsProperty("a.key"));
    assert(stringProperty(ps, "a.key") == "a.value");
}

unittest
{
    // withUnderscore
    auto envMap = new HashMap!(string, Any)();
    PropertySource ps = new SystemEnvironmentPropertySource("sysEnv", envMap);
    envMap.put("a_key", Any.of("a_value"));
    assert(ps.containsProperty("a_key"));
    assert(ps.containsProperty("a.key"));
    assert(stringProperty(ps, "a_key") == "a_value");
    assert(stringProperty(ps, "a.key") == "a_value");
}

unittest
{
    // withBothPeriodAndUnderscore
    auto envMap = new HashMap!(string, Any)();
    PropertySource ps = new SystemEnvironmentPropertySource("sysEnv", envMap);
    envMap.put("a_key", Any.of("a_value"));
    envMap.put("a.key", Any.of("a.value"));
    assert(stringProperty(ps, "a_key") == "a_value");
    assert(stringProperty(ps, "a.key") == "a.value");
}

unittest
{
    // withUppercase
    auto envMap = new HashMap!(string, Any)();
    PropertySource ps = new SystemEnvironmentPropertySource("sysEnv", envMap);
    envMap.put("A_KEY", Any.of("a_value"));
    envMap.put("A_LONG_KEY", Any.of("a_long_value"));
    envMap.put("A_DOT.KEY", Any.of("a_dot_value"));
    envMap.put("A_HYPHEN-KEY", Any.of("a_hyphen_value"));
    const expected = [
        "A_KEY": "a_value", "A.KEY": "a_value", "A-KEY": "a_value", "a_key": "a_value",
        "a.key": "a_value", "a-key": "a_value", "A_LONG_KEY": "a_long_value",
        "A.LONG.KEY": "a_long_value", "A-LONG-KEY": "a_long_value", "A.LONG-KEY": "a_long_value",
        "A-LONG.KEY": "a_long_value", "A_long_KEY": "a_long_value", "A.long.KEY": "a_long_value",
        "A-long-KEY": "a_long_value", "A.long-KEY": "a_long_value", "A-long.KEY": "a_long_value",
        "A_DOT.KEY": "a_dot_value", "A-DOT.KEY": "a_dot_value", "A_dot.KEY": "a_dot_value",
        "A-dot.KEY": "a_dot_value", "A_HYPHEN-KEY": "a_hyphen_value", "A.HYPHEN-KEY": "a_hyphen_value",
        "A_hyphen-KEY": "a_hyphen_value", "A.hyphen-KEY": "a_hyphen_value"
    ];
    foreach (name, value; expected)
    {
        assert(ps.containsProperty(name), name);
        assert(stringProperty(ps, name) == value, name);
    }
}
