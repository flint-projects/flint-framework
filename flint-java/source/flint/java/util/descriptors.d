/++
Erased Flint AOT descriptors for `flint.java.util` collections and maps (owner decision 2670d5be: generated code is
non-templated). `descriptorOf!(Map!(K, V))` instantiates the whole collection hierarchy per (K, V), about 130 KB of
code in every generated module that registers one; these builders describe the same types with non-template thunks
that work through the `RawCollection` and `RawMap` views every collection already offers, so registering one costs
no instance at all.

A descriptor built here has no `fromElements` or `fromEntries`: readers fill a container through `create()` (when the
generated plan supplies one) and `addAny`/`putAny`, or fill an existing one in place. `buildElements` and
`buildEntries` do that for readers that hold the elements first; `isListLike` and `isMapLike` recognize either kind
of descriptor.
+/
module flint.java.util.descriptors;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, TypeKind;
import flint.java.util : RawCollection, RawMap;

@safe:

/// The descriptor of a `List`, `ArrayList` or `Collection` type named `typeName` (its canonical `typeNameOf` name)
/// whose elements are `elementType`. `create`, when given, makes an empty instance of the concrete type.
Descriptor rawListDescriptor(string typeName, string elementType, Any function() @safe create = null)
{
    auto d = new Descriptor(typeName, TypeKind.class_);
    d.elementType = elementType;
    d.length = &collectionLength;
    d.element = &collectionElement;
    d.create = create;
    return d;
}

/// The descriptor of a `Set`, `HashSet` or `LinkedHashSet` type; as `rawListDescriptor`.
Descriptor rawSetDescriptor(string typeName, string elementType, Any function() @safe create = null)
{
    return rawListDescriptor(typeName, elementType, create);
}

/// The descriptor of a `Map`, `HashMap`, `LinkedHashMap` or `TreeMap` type named `typeName` with keys of `keyType`
/// and values of `valueType`. `create`, when given, makes an empty instance of the concrete type.
Descriptor rawMapDescriptor(string typeName, string keyType, string valueType, Any function() @safe create = null)
{
    auto d = new Descriptor(typeName, TypeKind.class_);
    d.keyType = keyType;
    d.elementType = valueType;
    d.toKeys = &mapKeys;
    d.toValues = &mapValues;
    d.create = create;
    return d;
}

/// Whether `d` describes a sequence: a D array, or a collection described either way.
bool isListLike(const Descriptor d) pure nothrow @nogc
{
    return d.fromElements !is null || (d.length !is null && d.element !is null);
}

/// Whether `d` describes a map: an associative array, or a map described either way.
bool isMapLike(const Descriptor d) pure nothrow @nogc
{
    return d.fromEntries !is null || (d.toKeys !is null && d.toValues !is null);
}

/// A container of `d`'s type holding `elements`: `fromElements`, else `create()` filled with `addAny`, else
/// `existing` cleared and refilled. `Any.init` when none of these is available.
Any buildElements(const Descriptor d, Any[] elements, Any existing = Any.init)
{
    if (d.fromElements !is null)
        return d.fromElements(elements);
    auto target = d.create !is null ? d.create() : existing;
    auto collection = cast(RawCollection) target.asObject();
    if (collection is null)
        return Any.init;
    collection.clear();
    foreach (element; elements)
        collection.addAny(element);
    return target;
}

/// A map of `d`'s type holding the entries: `fromEntries`, else `create()` filled with `putAny`, else `existing`
/// with the entries put into it. `Any.init` when none of these is available.
Any buildEntries(const Descriptor d, Any[] keys, Any[] values, Any existing = Any.init)
{
    if (d.fromEntries !is null)
        return d.fromEntries(keys, values);
    auto target = d.create !is null ? d.create() : existing;
    auto map = cast(RawMap) target.asObject();
    if (map is null)
        return Any.init;
    foreach (i, key; keys)
        map.putAny(key, values[i]);
    return target;
}

private RawCollection collectionOf(ref Any value)
{
    import flint.java.lang : ClassCastException;

    auto collection = cast(RawCollection) value.asObject();
    if (collection is null && !value.isNull())
        throw new ClassCastException(value.typeName() ~ " is not a flint.java.util collection");
    return collection;
}

private RawMap mapOf(ref Any value)
{
    import flint.java.lang : ClassCastException;

    auto map = cast(RawMap) value.asObject();
    if (map is null && !value.isNull())
        throw new ClassCastException(value.typeName() ~ " is not a flint.java.util map");
    return map;
}

private size_t collectionLength(ref Any value)
{
    auto collection = collectionOf(value);
    return collection is null ? 0 : collection.size();
}

private Any collectionElement(ref Any value, size_t index)
{
    return collectionOf(value).toAnyArray()[index];
}

private Any[] mapKeys(ref Any value)
{
    auto map = mapOf(value);
    return map is null ? null : map.keysAsAny();
}

private Any[] mapValues(ref Any value)
{
    auto map = mapOf(value);
    if (map is null)
        return null;
    Any[] values;
    foreach (key; map.keysAsAny())
        values ~= map.getAny(key);
    return values;
}
