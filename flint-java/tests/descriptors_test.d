/// Flint tests: the erased collection descriptors describe List, Set and Map as descriptorOf does, without instances.
module flint.java.descriptors_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : TypeKind, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.java.util : ArrayList, HashSet, LinkedHashMap, List, Map, Set;
import flint.java.util.descriptors : buildElements, buildEntries, isListLike, isMapLike,
    rawListDescriptor, rawMapDescriptor, rawSetDescriptor;

@safe:

private Any newList()
{
    return Any.of(cast(List!string) new ArrayList!string());
}

private Any newSet()
{
    return Any.of(cast(Set!int) new HashSet!int());
}

private Any newMap()
{
    return Any.of(cast(Map!(string, int)) new LinkedHashMap!(string, int)());
}

@("rawListDescriptor round-trips a List: build, length, elements, names")
unittest
{
    const d = rawListDescriptor(typeNameOf!(List!string), "string", &newList);
    const typed = descriptorOf!(List!string)();
    assert(d.name == typed.name && d.elementType == typed.elementType && d.kind == TypeKind.class_);
    assert(isListLike(d) && !isMapLike(d) && isListLike(typed));
    auto list = buildElements(d, [Any.of("a"), Any.of("b"), Any.of("c")]);
    assert(d.length(list) == 3);
    assert(d.element(list, 0).get!string() == "a" && d.element(list, 2).get!string() == "c");
    assert(list.get!(List!string)().get(1) == "b");
    // Without create, an existing list is cleared and refilled in place.
    const inPlace = rawListDescriptor(typeNameOf!(List!string), "string");
    auto existing = newList();
    existing.get!(List!string)().add("old");
    auto refilled = buildElements(inPlace, [Any.of("new")], existing);
    assert(refilled.asObject() is existing.asObject() && inPlace.length(refilled) == 1);
    assert(buildElements(inPlace, [Any.of("x")]).isNull());
    Any none;
    assert(d.length(none) == 0);
}

@("rawSetDescriptor round-trips a Set")
unittest
{
    const d = rawSetDescriptor(typeNameOf!(Set!int), "int", &newSet);
    auto set = buildElements(d, [Any.of(1), Any.of(2), Any.of(2)]);
    assert(d.length(set) == 2 && set.get!(Set!int)().contains(2));
}

@("rawMapDescriptor round-trips a Map: build, keys and values in order, filled in place without create")
unittest
{
    const d = rawMapDescriptor(typeNameOf!(Map!(string, int)), "string", "int", &newMap);
    const typed = descriptorOf!(Map!(string, int))();
    assert(d.name == typed.name && d.keyType == typed.keyType && d.elementType == typed.elementType);
    assert(isMapLike(d) && !isListLike(d) && isMapLike(typed));
    auto map = buildEntries(d, [Any.of("one"), Any.of("two")], [Any.of(1), Any.of(2)]);
    auto keys = d.toKeys(map), values = d.toValues(map);
    assert(keys.length == 2 && keys[0].get!string() == "one" && keys[1].get!string() == "two");
    assert(values[0].get!int() == 1 && values[1].get!int() == 2);
    const inPlace = rawMapDescriptor(typeNameOf!(Map!(string, int)), "string", "int");
    auto existing = newMap();
    buildEntries(inPlace, [Any.of("k")], [Any.of(7)], existing);
    assert(existing.get!(Map!(string, int))().get("k") == 7);
}

@("a descriptor of the wrong container kind fails with ClassCastException")
unittest
{
    import flint.java.lang : ClassCastException;
    import std.exception : assertThrown;

    const d = rawMapDescriptor(typeNameOf!(Map!(string, int)), "string", "int");
    auto list = newList();
    assertThrown!ClassCastException(d.toKeys(list));
}
