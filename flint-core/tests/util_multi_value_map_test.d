// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.util.MultiValueMapTests` (v7.1.0): one `unittest` per Java test method,
each starting with a `// <JavaTestName>` comment. The `@ParameterizedMultiValueMapTest` methods run against every
map of Java's `mapsUnderTest()`. No test is skipped.
+/
module flint.util.multi_value_map_test;

import flint.java.lang : UnsupportedOperationException;
import flint.java.util : Arrays, HashMap, LinkedHashMap, List, Map;
import flint.util : CollectionUtils, LinkedMultiValueMap, MultiValueMap;
import flint.util.test_support : expectThrows;

@safe:

/// Java's `mapsUnderTest()`: a fresh instance of each map per call.
private MultiValueMap!(string, string)[] mapsUnderTest()
{
    return [
        new LinkedMultiValueMap!(string, string)(),
        new LinkedMultiValueMap!(string, string)(new HashMap!(string, List!string)()),
        new LinkedMultiValueMap!(string, string)(new LinkedHashMap!(string, List!string)()),
        new LinkedMultiValueMap!(string, string)(Map!(string, List!string).of("existingkey",
                List!string.of("existingvalue1", "existingvalue2"))),
        CollectionUtils.toMultiValueMap(new HashMap!(string, List!string)()),
    ];
}

// add
unittest
{
    foreach (map; mapsUnderTest())
    {
        const initialSize = map.size();
        map.add("key", "value1");
        map.add("key", "value2");
        assert(map.size() == initialSize + 1);
        assert(map.get("key").toArray() == ["value1", "value2"]);
    }
}

// addIfAbsentWhenAbsent
unittest
{
    foreach (map; mapsUnderTest())
    {
        map.addIfAbsent("key", "value1");
        assert(map.get("key").toArray() == ["value1"]);
    }
}

// addIfAbsentWhenPresent
unittest
{
    foreach (map; mapsUnderTest())
    {
        map.add("key", "value1");
        map.addIfAbsent("key", "value2");
        assert(map.get("key").toArray() == ["value1"]);
    }
}

// set
unittest
{
    foreach (map; mapsUnderTest())
    {
        map.set("key", "value1");
        map.set("key", "value2");
        assert(map.get("key").toArray() == ["value2"]);
    }
}

// addAll
unittest
{
    foreach (map; mapsUnderTest())
    {
        const initialSize = map.size();
        map.add("key", "value1");
        map.addAll("key", Arrays.asList("value2", "value3"));
        assert(map.size() == initialSize + 1);
        assert(map.get("key").toArray() == ["value1", "value2", "value3"]);
    }
}

// addAllWithEmptyList
unittest
{
    foreach (map; mapsUnderTest())
    {
        const initialSize = map.size();
        map.addAll("key", List!string.of());
        assert(map.size() == initialSize + 1);
        assert(map.get("key").isEmpty());
        assert(map.getFirst("key") is null);
    }
}

// getFirst
unittest
{
    foreach (map; mapsUnderTest())
    {
        map.put("key", List!string.of("value1", "value2"));
        assert(map.getFirst("key") == "value1");
        assert(map.getFirst("other") is null);
    }
}

// toSingleValueMap
unittest
{
    foreach (map; mapsUnderTest())
    {
        const initialSize = map.size();
        map.put("key", List!string.of("value1", "value2"));
        auto singleValueMap = map.toSingleValueMap();
        assert(singleValueMap.size() == initialSize + 1);
        assert(singleValueMap.get("key") == "value1");
    }
}

// toSingleValueMapWithEmptyList
unittest
{
    foreach (map; mapsUnderTest())
    {
        const initialSize = map.size();
        map.put("key", List!string.of());
        auto singleValueMap = map.toSingleValueMap();
        assert(singleValueMap.size() == initialSize);
        assert(singleValueMap.get("key") is null);
    }
}

// equalsOnExistingValues
unittest
{
    foreach (map; mapsUnderTest())
    {
        map.clear();
        map.set("key1", "value1");
        assert(map.equals(cast(Object) map));
    }
}

// equalsOnEmpty
unittest
{
    foreach (map; mapsUnderTest())
    {
        map.clear();
        map.set("key1", "value1");
        MultiValueMap!(string, string) map1 = new LinkedMultiValueMap!(string, string)();
        map1.set("key1", "value1");
        assert(map1.equals(cast(Object) map));
        assert(map.equals(cast(Object) map1));
        auto map2 = Map!(string, List!string).of("key1", List!string.of("value1"));
        assert(map2.equals(cast(Object) map));
        assert(map.equals(cast(Object) map2));
    }
}

private List!string exampleListOfValues()
{
    return List!string.of("value1", "value2");
}

private Map!(string, string) exampleHashMap()
{
    return Map!(string, string).of("key2", "key2.value1");
}

private MultiValueMap!(string, string) exampleMultiValueMap()
{
    auto map = new LinkedMultiValueMap!(string, string)();
    map.put("key1", Arrays.asList("key1.value1", "key1.value2"));
    return map;
}

// canNotChangeAnUnmodifiableMultiValueMap
unittest
{
    MultiValueMap!(string, string) map = new LinkedMultiValueMap!(string, string)();
    auto unmodifiableMap = CollectionUtils.unmodifiableMultiValueMap(map);
    expectThrows!UnsupportedOperationException(() { unmodifiableMap.add("key", "value"); });
    expectThrows!UnsupportedOperationException(() { unmodifiableMap.addIfAbsent("key", "value"); });
    expectThrows!UnsupportedOperationException(() {
        unmodifiableMap.addAll("key", exampleListOfValues());
    });
    expectThrows!UnsupportedOperationException(() { unmodifiableMap.addAll(exampleMultiValueMap()); });
    expectThrows!UnsupportedOperationException(() { unmodifiableMap.set("key", "value"); });
    expectThrows!UnsupportedOperationException(() { unmodifiableMap.setAll(exampleHashMap()); });
    expectThrows!UnsupportedOperationException(() {
        unmodifiableMap.put("key", exampleListOfValues());
    });
    expectThrows!UnsupportedOperationException(() {
        unmodifiableMap.putIfAbsent("key", exampleListOfValues());
    });
    expectThrows!UnsupportedOperationException(() { unmodifiableMap.putAll(exampleMultiValueMap()); });
    expectThrows!UnsupportedOperationException(() { unmodifiableMap.remove("key1"); });
}

// Flint: the unmodifiable view reads through and protects its lists; fromMultiValue adapts a map.
unittest
{
    auto map = new LinkedMultiValueMap!(string, string)();
    map.add("k", "v");
    auto view = CollectionUtils.unmodifiableMultiValueMap!(string, string)(map);
    assert(CollectionUtils.unmodifiableMultiValueMap(view) is view);
    assert(view.getFirst("k") == "v");
    assert(view.size() == 1 && view.containsKey("k") && view.equals(cast(Object) map));
    expectThrows!UnsupportedOperationException(() { view.get("k").add("w"); });
    expectThrows!UnsupportedOperationException(() { view.entrySet().toArray()[0].setValue(null); });
    map.add("k", "w");
    assert(view.get("k").size() == 2);
    auto adapted = MultiValueMap!(string, string).fromMultiValue(new HashMap!(string, List!string)());
    adapted.add("a", "b");
    assert(adapted.toSingleValueMap().get("a") == "b");
}
