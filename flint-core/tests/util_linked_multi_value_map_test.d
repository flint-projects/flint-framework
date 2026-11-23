// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.util.LinkedMultiValueMapTests` (v7.1.0): one `unittest` per Java test
method, each starting with a `// <JavaTestName>` comment. No test is skipped.
+/
module flint.util.linked_multi_value_map_test;

import flint.java.util : ArrayList, Arrays, Collections, HashMap, List, Map;
import flint.util : LinkedMultiValueMap, MultiValueMap;

@safe:

private LinkedMultiValueMap!(string, string) newMap()
{
    return new LinkedMultiValueMap!(string, string)();
}

// add
unittest
{
    auto map = newMap();
    map.add("key", "value1");
    map.add("key", "value2");
    assert(map.size() == 1);
    assert(map.get("key").toArray() == ["value1", "value2"]);
}

// addIfAbsentWhenAbsent
unittest
{
    auto map = newMap();
    map.addIfAbsent("key", "value1");
    assert(map.get("key").toArray() == ["value1"]);
}

// addIfAbsentWhenPresent
unittest
{
    auto map = newMap();
    map.add("key", "value1");
    map.addIfAbsent("key", "value2");
    assert(map.get("key").toArray() == ["value1"]);
}

// set
unittest
{
    auto map = newMap();
    map.set("key", "value1");
    map.set("key", "value2");
    assert(map.get("key").toArray() == ["value2"]);
}

// addAll
unittest
{
    auto map = newMap();
    map.add("key", "value1");
    map.addAll("key", Arrays.asList("value2", "value3"));
    assert(map.size() == 1);
    assert(map.get("key").toArray() == ["value1", "value2", "value3"]);
}

// addAllWithEmptyList
unittest
{
    auto map = newMap();
    map.addAll("key", Collections.emptyList!string());
    assert(map.size() == 1);
    assert(map.get("key").isEmpty());
    assert(map.getFirst("key") is null);
}

// getFirst
unittest
{
    auto map = newMap();
    auto values = new ArrayList!string(2);
    values.add("value1");
    values.add("value2");
    map.put("key", values);
    assert(map.getFirst("key") == "value1");
    assert(map.getFirst("other") is null);
}

// getFirstWithEmptyList
unittest
{
    auto map = newMap();
    map.put("key", Collections.emptyList!string());
    assert(map.getFirst("key") is null);
    assert(map.getFirst("other") is null);
}

// toSingleValueMap
unittest
{
    auto map = newMap();
    auto values = new ArrayList!string(2);
    values.add("value1");
    values.add("value2");
    map.put("key", values);
    auto singleValueMap = map.toSingleValueMap();
    assert(singleValueMap.size() == 1);
    assert(singleValueMap.get("key") == "value1");
}

// toSingleValueMapWithEmptyList
unittest
{
    auto map = newMap();
    map.put("key", Collections.emptyList!string());
    auto singleValueMap = map.toSingleValueMap();
    assert(singleValueMap.isEmpty());
    assert(singleValueMap.get("key") is null);
}

// equals
unittest
{
    auto map = newMap();
    map.set("key1", "value1");
    assert(map.equals(cast(Object) map));
    MultiValueMap!(string, string) o1 = new LinkedMultiValueMap!(string, string)();
    o1.set("key1", "value1");
    assert(o1.equals(cast(Object) map));
    assert(map.equals(cast(Object) o1));
    Map!(string, List!string) o2 = new HashMap!(string, List!string)();
    o2.put("key1", Collections.singletonList("value1"));
    assert(o2.equals(cast(Object) map));
    assert(map.equals(cast(Object) o2));
}

// Flint: deepCopy and clone, toString, and non-ASCII keys.
unittest
{
    auto map = newMap();
    map.add("日本", "語");
    map.add("日本", "😀");
    auto shallow = map.clone();
    auto deep = map.deepCopy();
    map.get("日本").add("x");
    assert(shallow.get("日本").size() == 3);
    assert(deep.get("日本").size() == 2);
    assert(deep.toString() == "{日本=[語, 😀]}");
    auto same = newMap();
    same.addAll("日本", Arrays.asList("語", "😀"));
    assert(deep.hashCode() == same.hashCode() && deep.equals(same));
}
