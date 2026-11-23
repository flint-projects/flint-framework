// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.util.CollectionUtilsTests` (v7.1.0): one `unittest` per Java test
method, each starting with a `// <JavaTestName>` comment.

Skipped Java tests (9), with reasons:
- mergePropertiesIntoMap: `java.util.Properties` (excluded).
- containsWithEnumeration, toArray: `java.util.Enumeration` is not part of flint:java (excluded).
- findCommonElementType, findCommonElementTypeWithEmptyCollection, findCommonElementTypeWithDifferentElementType:
  they return `Class` objects (runtime-reflection).
- firstElementWithSortedSet, lastElementWithSortedSet: `SortedSet`/`TreeSet` are not part of flint:java.
- compositeMap: `CompositeMap` is not ported in Phase 1 (deferred).

Adapted: lastElementWithSet expects the last inserted element, because flint:java's `HashSet` iterates in
insertion order (deviation D-16; Java's hash order puts 3 last). findValueOfTypeWithNullType (Java's null `Class`)
asks for the element type itself.
+/
module flint.util.collection_utils_test;

import flint.java.lang : JavaObject, stringHashCode;
import flint.java.util : ArrayList, Arrays, HashMap, HashSet, List, Map, Set;
import flint.util : CollectionUtils, MultiValueMap;

@safe:

private final class Instance
{
    mixin JavaObject;

    private string name;

    this(string name)
    {
        this.name = name;
    }

    bool equals(Object rhs)
    {
        auto instance = cast(Instance) rhs;
        return instance !is null && name == instance.name;
    }

    int hashCode()
    {
        return stringHashCode(name);
    }
}

// isEmpty
unittest
{
    assert(CollectionUtils.isEmpty(cast(Set!Object) null));
    assert(CollectionUtils.isEmpty(cast(Map!(string, string)) null));
    assert(CollectionUtils.isEmpty(new HashMap!(string, string)()));
    assert(CollectionUtils.isEmpty(new HashSet!Object()));
    auto list = new ArrayList!Object();
    list.add(new Object);
    assert(!CollectionUtils.isEmpty(list));
    auto map = new HashMap!(string, string)();
    map.put("foo", "bar");
    assert(!CollectionUtils.isEmpty(map));
}

// mergeArrayIntoCollection
unittest
{
    string[] arr = ["value1", "value2"];
    auto list = new ArrayList!string();
    list.add("value3");
    CollectionUtils.mergeArrayIntoCollection(arr, list);
    assert(list.toArray() == ["value3", "value1", "value2"]);
}

// mergePrimitiveArrayIntoCollection
unittest
{
    int[] arr = [1, 2];
    auto list = new ArrayList!int();
    list.add(3);
    CollectionUtils.mergeArrayIntoCollection(arr, list);
    assert(list.toArray() == [3, 1, 2]);
}

// containsWithIterator
unittest
{
    import flint.java.util : Iterator;

    assert(!CollectionUtils.contains(cast(Iterator!string) null, "myElement"));
    assert(!CollectionUtils.contains(List!string.of().iterator(), "myElement"));
    auto list = Arrays.asList("myElement", null);
    assert(CollectionUtils.contains(list.iterator(), "myElement"));
    assert(CollectionUtils.contains(list.iterator(), null));
}

// containsAny
unittest
{
    auto source = new ArrayList!string();
    source.add("abc");
    source.add("def");
    source.add("ghi");
    auto candidates = new ArrayList!string();
    candidates.add("xyz");
    candidates.add("def");
    candidates.add("abc");
    assert(CollectionUtils.containsAny(source, candidates));
    candidates.remove("def");
    assert(CollectionUtils.containsAny(source, candidates));
    candidates.remove("abc");
    assert(!CollectionUtils.containsAny(source, candidates));
    source.add(null);
    assert(!CollectionUtils.containsAny(source, candidates));
    candidates.add(null);
    assert(CollectionUtils.containsAny(source, candidates));
}

// containsInstanceWithNullCollection
unittest
{
    assert(!CollectionUtils.containsInstance(cast(List!Instance) null, new Instance("x")));
}

// containsInstanceWithInstancesThatAreEqualButDistinct
unittest
{
    auto list = List!Instance.of(new Instance("fiona"));
    assert(!CollectionUtils.containsInstance(list, new Instance("fiona")));
}

// containsInstanceWithSameInstance
unittest
{
    auto fiona = new Instance("fiona");
    auto apple = new Instance("apple");
    auto list = List!Instance.of(fiona, apple);
    assert(CollectionUtils.containsInstance(list, fiona));
}

// containsInstanceWithNullInstance
unittest
{
    auto fiona = new Instance("fiona");
    auto list = List!Instance.of(fiona);
    assert(!CollectionUtils.containsInstance(list, null));
    list = Arrays.asList(fiona, null);
    assert(CollectionUtils.containsInstance(list, null));
}

// findFirstMatch
unittest
{
    auto source = new ArrayList!string();
    source.add("abc");
    source.add("def");
    source.add("ghi");
    auto candidates = new ArrayList!string();
    candidates.add("xyz");
    candidates.add("def");
    candidates.add("abc");
    assert(CollectionUtils.findFirstMatch(source, candidates) == "def");
    source.clear();
    source.add(null);
    assert(CollectionUtils.findFirstMatch(source, candidates) is null);
    candidates.add(null);
    assert(CollectionUtils.findFirstMatch(source, candidates) is null);
}

// findValueOfType
unittest
{
    assert(CollectionUtils.findValueOfType!int(List!int.of(1)) == 1);
    assert(CollectionUtils.findValueOfType!int(Set!int.of(2)) == 2);
}

// findValueOfTypeWithNullType
unittest
{
    assert(CollectionUtils.findValueOfType!int(List!int.of(1)) == 1);
}

// findValueOfTypeWithNullCollection
unittest
{
    assert(CollectionUtils.findValueOfType!Object(cast(List!Object) null) is null);
}

// findValueOfTypeWithEmptyCollection
unittest
{
    assert(CollectionUtils.findValueOfType!Object(List!Object.of()) is null);
}

// findValueOfTypeWithMoreThanOneValue
unittest
{
    assert(CollectionUtils.findValueOfType!int(List!int.of(1, 2)) == 0);
    auto mixed = List!Object.of(new Instance("a"), new Object, new Instance("b"));
    assert(CollectionUtils.findValueOfType!Instance(mixed) is null);
    auto single = List!Object.of(new Object, new Instance("a"));
    assert(CollectionUtils.findValueOfType!Instance(single).name == "a");
}

// hasUniqueObject
unittest
{
    auto list = new ArrayList!string();
    list.add("myElement");
    list.add("myOtherElement");
    assert(!CollectionUtils.hasUniqueObject(list));

    list = new ArrayList!string();
    list.add("myElement");
    assert(CollectionUtils.hasUniqueObject(list));

    list = new ArrayList!string();
    list.add("myElement");
    list.add(null);
    assert(!CollectionUtils.hasUniqueObject(list));

    list = new ArrayList!string();
    list.add(null);
    list.add("myElement");
    assert(!CollectionUtils.hasUniqueObject(list));

    list = new ArrayList!string();
    list.add(null);
    list.add(null);
    assert(CollectionUtils.hasUniqueObject(list));

    list = new ArrayList!string();
    list.add(null);
    assert(CollectionUtils.hasUniqueObject(list));

    list = new ArrayList!string();
    assert(!CollectionUtils.hasUniqueObject(list));
}

// firstElementWithSet
unittest
{
    auto set = new HashSet!int();
    set.add(17);
    set.add(3);
    set.add(2);
    set.add(1);
    assert(CollectionUtils.firstElement!int(set) == 17);
}

// firstElementWithList
unittest
{
    auto list = new ArrayList!int();
    list.add(1);
    list.add(2);
    list.add(3);
    assert(CollectionUtils.firstElement!int(list) == 1);
}

// lastElementWithSet
unittest
{
    auto set = new HashSet!int();
    set.add(17);
    set.add(3);
    set.add(2);
    set.add(1);
    assert(CollectionUtils.lastElement!int(set) == 1);
}

// lastElementWithList
unittest
{
    auto list = new ArrayList!int();
    list.add(1);
    list.add(2);
    list.add(3);
    assert(CollectionUtils.lastElement!int(list) == 3);
}

// conversionOfEmptyMap
unittest
{
    MultiValueMap!(string, string) asMultiValueMap = CollectionUtils.toMultiValueMap(new HashMap!(string,
            List!string)());
    assert(asMultiValueMap.isEmpty());
    assert(asMultiValueMap.size() == 0);
}

// conversionOfNonEmptyMap
unittest
{
    auto wrapped = new HashMap!(string, List!string)();
    wrapped.put("key", Arrays.asList("first", "second"));
    auto asMultiValueMap = CollectionUtils.toMultiValueMap!(string, string)(wrapped);
    assert(asMultiValueMap.size() == 1);
    assert(asMultiValueMap.get("key") is wrapped.get("key"));
    assert(asMultiValueMap.equals(wrapped));
}

// changesValueByReference
unittest
{
    auto wrapped = new HashMap!(string, List!string)();
    auto asMultiValueMap = CollectionUtils.toMultiValueMap!(string, string)(wrapped);
    assert(!asMultiValueMap.containsKey("key"));
    wrapped.put("key", new ArrayList!string());
    assert(asMultiValueMap.containsKey("key"));
}

// Flint: the factories and list helpers.
unittest
{
    auto map = CollectionUtils.newHashMap!(string, int)(4);
    map.put("a", 1);
    assert(map.get("a") == 1);
    assert(CollectionUtils.newLinkedHashMap!(string, int)(0).isEmpty());
    assert(CollectionUtils.newHashSet!string(2).add("x"));
    assert(CollectionUtils.newLinkedHashSet!string(2).isEmpty());
    auto list = CollectionUtils.arrayToList(["日本", "x"]);
    assert(list.size() == 2 && list.get(0) == "日本");
    assert(CollectionUtils.firstElement(cast(List!string) null) is null);
    assert(CollectionUtils.lastElement(new ArrayList!string()) is null);
}
