/++
Type descriptors: Flint AOT's per-type tables (AOT contract section 4.2, ADR-030 section 5).

A `Descriptor` lists what message conversion, validation, binding and the container need to know about a type at
run time: its name and supertypes, its merged annotations, its Java Beans properties with erased accessors, its
constructors, and the methods that carry framework annotations. Generated modules build descriptors and hand them
to the registry; nothing reflects at run time.

`descriptorOf!T` builds the same table at compile time for hand-written code and tests: it merges annotations as
the generator does (section 2.1), lists public fields and `getX`/`isX`/`setX` properties, and records a default
constructor when the type has one. The runtime's own descriptors for scalars and `string` come from it too.
+/
module flint.engine.aot.descriptor;

import flint.engine.aot.any : Any;
import flint.engine.aot.expression : ExpressionSpec;
import flint.engine.aot.name : typeNameOf;

@safe:

/// The shape of a described type.
enum TypeKind
{
    scalar,
    string_,
    enum_,
    array,
    struct_,
    class_,
    interface_,
}

/// An annotation present on an element, with its attributes merged (contract section 2.1).
struct MergedAnnotation
{
    /// The annotation's fully qualified D name.
    string type;
    /// The merged annotation struct literal, boxed.
    Any value;
    /// 0 when declared on the element; n for a meta-annotation n levels up.
    ubyte distance;
    /// Contract 3: 0 for the element itself; n >= 1 for its nth supertype (or overridden method) in Spring's
    /// `TYPE_HIERARCHY` order: the class, its interfaces (recursively), then the superclass and its interfaces.
    ubyte aggregateIndex;
    /// Runtime extension: Spring's `AnnotationConfigurationException` message for a misconfigured `@AliasFor`
    /// (set only by `descriptorOf`'s merger; the generator reports FLINT-E1103 instead). Null when well formed.
    string error;
}

/// A constructor or method parameter.
struct ParameterDescriptor
{
    /// The parameter name.
    string name;
    /// The fully qualified D type, as written by the compiler.
    string type;
    /// The parameter's merged annotations.
    MergedAnnotation[] annotations;
}

/// A JSON, binding or validation property.
struct PropertyDescriptor
{
    /// The Java Beans name: the field name, or `getX`/`isX`/`setX` without the prefix, decapitalized.
    string name;
    /// The property type's fully qualified D name.
    string type;
    /// From the field, getter and setter, merged.
    MergedAnnotation[] annotations;
    /// Read the property from an `Any` holding an instance; null when write-only.
    Any function(ref Any self) @safe get;
    /// Write the property; null when read-only.
    void function(ref Any self, Any value) @safe set;
}

/// A constructor callable with erased arguments.
struct ConstructorDescriptor
{
    /// Parameters in declaration order.
    ParameterDescriptor[] parameters;
    /// The constructor's merged annotations.
    MergedAnnotation[] annotations;
    /// Create an instance from arguments in parameter order.
    Any function(scope Any[] arguments) @safe invoke;
    /// Contract 2: whether this is a record-style canonical (field-wise) constructor.
    bool canonical;
}

/// A method the framework dispatches to or advises.
struct MethodDescriptor
{
    /// The method name.
    string name;
    /// The fully qualified return type.
    string returnType;
    /// Parameters in declaration order.
    ParameterDescriptor[] parameters;
    /// Method-level annotations, merged with class-level advice.
    MergedAnnotation[] annotations;
    /// The position in the declaring descriptor's `methods`.
    uint index;
    /// The compiled SpEL attributes of `annotations` (contract 3); empty for older generated code.
    ExpressionSpec[] expressions;

    /// The compiled expression of `attribute` on `annotation` (a fully qualified name), or null.
    const(ExpressionSpec)* expression(scope const(char)[] annotation, scope const(char)[] attribute) const return
    {
        foreach (ref spec; expressions)
            if (spec.annotation == annotation && spec.attribute == attribute)
                return &spec;
        return null;
    }
}

/// Flint AOT's table for one type.
final class Descriptor
{
    /// The fully qualified D name.
    string name;
    /// The shape of the type.
    TypeKind kind;
    /// Classes and interfaces, nearest first.
    string[] supertypes;
    /// The type's merged annotations (contract section 2.1).
    MergedAnnotation[] annotations;
    /// JSON, binding and validation properties.
    PropertyDescriptor[] properties;
    /// The preferred constructor first (`@JsonCreator`, the single one, or the default one).
    ConstructorDescriptor[] constructors;
    /// Only advised, mapped or listener methods.
    MethodDescriptor[] methods;
    /// A default instance; null when there is none.
    Any function() @safe create;
    /// For enums, in declaration order.
    string[] enumConstants;
    /// Runtime extension: for integral enums, the value of each of `enumConstants`, for `Any.ofEnum`.
    long[] enumValues;
    /// Runtime extension: the element type of an array, `Optional!T`, `List!T` or `Set!T`; a map's value type.
    string elementType;
    /// Runtime extension: the key type of a map.
    string keyType;
    /// Contract 2: the enum constant at `ordinal` (declaration order); null for non-enums.
    Any function(long ordinal) @safe enumValue;
    /// Erased builders (null when the type is not of that shape): arrays, `List!T` and `Set!T`.
    size_t function(ref Any value) @safe length;
    /// ditto
    Any function(ref Any value, size_t index) @safe element;
    /// ditto
    Any function(Any[] elements) @safe fromElements;
    /// Erased builders for maps (`V[K]`, `Map!(K, V)`): keys and values in iteration order, and construction.
    Any[]function(ref Any value) @safe toKeys;
    /// ditto
    Any[]function(ref Any value) @safe toValues;
    /// ditto
    Any function(Any[] keys, Any[] values) @safe fromEntries;
    /// Erased builders for `Optional!T` and `Nullable!T`: the value, or `Any.init` when empty; and back.
    Any function(ref Any value) @safe unwrap;
    /// ditto
    Any function(Any value) @safe wrap;

    /// A descriptor with no members yet, as generated code builds one.
    this(string name, TypeKind kind) pure nothrow
    {
        this.name = name;
        this.kind = kind;
    }

    /// The annotation of type `type` nearest to the element, declared on the type itself (aggregate 0, Spring's
    /// `INHERITED_ANNOTATIONS` without `@Inherited`), or null. Hot: no allocation.
    const(MergedAnnotation)* annotation(string type) const nothrow @nogc
    {
        const(MergedAnnotation)* best;
        foreach (ref a; annotations)
            if (a.aggregateIndex == 0 && a.type == type && (best is null || a.distance < best.distance))
                best = &a;
        return best;
    }

    /// The property named `propertyName`, or null.
    const(PropertyDescriptor)* property(scope const(char)[] propertyName) const nothrow @nogc
    {
        foreach (ref p; properties)
            if (p.name == propertyName)
                return &p;
        return null;
    }

    /// Whether this type is `type` or has it among its supertypes.
    bool isAssignableTo(scope const(char)[] type) const nothrow @nogc
    {
        if (name == type)
            return true;
        foreach (s; supertypes)
            if (s == type)
                return true;
        return false;
    }

    /// The simple name: `Owner` for `petclinic.model.Owner`.
    string simpleName() const pure nothrow @nogc
    {
        import flint.engine.aot.name : simpleTypeName;

        // Most names have no template arguments: the part after the last dot.
        foreach_reverse (i, c; name)
        {
            if (c == '!' || c == '(' || c == ')')
                return simpleTypeName(name);
            if (c == '.')
            {
                foreach (d; name[0 .. i])
                    if (d == '!' || d == '(')
                        return simpleTypeName(name);
                return name[i + 1 .. $];
            }
        }
        return name;
    }
}

/// The nearest annotation of `type` in a merged list, across every aggregate, or null. As Spring's `TYPE_HIERARCHY`
/// search: the first aggregate holding one wins (`MergedAnnotationFinder` stops there), then the lowest distance.
const(MergedAnnotation)* findAnnotation(return scope const(MergedAnnotation)[] annotations, string type) nothrow @nogc
{
    const(MergedAnnotation)* best;
    foreach (ref a; annotations)
        if (a.type == type && (best is null || a.aggregateIndex < best.aggregateIndex
                || (a.aggregateIndex == best.aggregateIndex && a.distance < best.distance)))
            best = &a;
    return best;
}

/// Descriptors by name, with the runtime's own descriptors for scalars and `string`.
final class DescriptorTable
{
    private Descriptor[string] byName;

    /// Add or replace a descriptor.
    void add(Descriptor descriptor) pure nothrow
    {
        byName[descriptor.name] = descriptor;
    }

    /// The descriptor named `name`, or null.
    inout(Descriptor) find(scope const(char)[] name) inout nothrow
    {
        if (auto found = name in byName)
            return *found;
        return null;
    }

    /// How many descriptors the table holds.
    size_t length() const pure nothrow @nogc
    {
        return byName.length;
    }

    /// A table holding the built-in scalar and string descriptors.
    static DescriptorTable withBuiltins()
    {
        import std.meta : AliasSeq;

        auto table = new DescriptorTable;
        static foreach (T; AliasSeq!(bool, byte, ubyte, short, ushort, int, uint, long, ulong,
                float, double, char, wchar, dchar, string))
            table.add(descriptorOf!T);
        return table;
    }
}

// ---------------------------------------------------------------------------------------------------------
// The compile-time builder.

/// A new descriptor for `T`, built from its declaration (for hand-written code and tests).
Descriptor descriptorOf(T)()
{
    alias U = typeof(cast() T.init);
    auto d = new Descriptor(typeNameOf!U, kindOf!U);
    static if (is(U == class) || is(U == interface))
    {
        static foreach (S; Supertypes!U)
            d.supertypes ~= typeNameOf!S;
    }
    static if (is(U == enum))
    {
        // Resolved once, outside the loop: an `is(U B == enum)` per member would declare `B` once per member.
        static if (is(U B == enum))
            enum integral = __traits(isIntegral, B);
        static foreach (member; __traits(allMembers, U))
        {
            d.enumConstants ~= member;
            static if (integral)
                d.enumValues ~= cast(long) __traits(getMember, U, member);
        }
    }
    else static if (is(U == E[], E) && !is(U : const(char)[]))
        d.elementType = typeNameOf!E;
    else static if (is(U == V[K], V, K))
    {
        d.elementType = typeNameOf!V;
        d.keyType = typeNameOf!K;
    }
    static if (__traits(compiles, U.__flintElementType.init))
        d.elementType = typeNameOf!(U.__flintElementType);
    static if (isStdNullable!U)
        d.elementType = typeNameOf!(typeof(U.init.get()));
    static if (__traits(compiles, U.__flintKeyType.init))
        d.keyType = typeNameOf!(U.__flintKeyType);
    addBuilders!U(d);
    static if (is(U == struct) || is(U == class) || is(U == interface) || is(U == enum))
    {
        d.annotations = mergedAnnotations!(__traits(getAttributes, U))((is(U == interface)
                ? "interface " : "class ") ~ typeNameOf!U);
        static if (is(U == class) || is(U == interface))
            d.annotations ~= supertypeAnnotations!U();
    }
    static if ((is(U == struct) || is(U == class)) && !__traits(compiles, U.__flintOpaque))
    {
        d.properties = propertiesOf!U();
        static if (is(U == struct) || __traits(compiles, ()@safe => new U()))
        {
            d.create = &createDefault!U;
            d.constructors ~= ConstructorDescriptor(null, null, &invokeDefault!U);
        }
    }
    return d;
}

// ---------------------------------------------------------------------------------------------------------------
// Erased builders. Collections outside this package opt in through static hooks:
// `__flintElements(ref T) -> E[]`, `__flintFromElements(E[]) -> T` (lists and sets),
// `__flintEntries(ref T, out K[], out V[])`, `__flintFromEntries(K[], V[]) -> T` (maps),
// `__flintUnwrap(ref T) -> E[]` (empty or one element), `__flintWrap(E, bool present) -> T` (optionals).

private void addBuilders(U)(Descriptor d)
{
    static if (is(U == enum))
        d.enumValue = &enumAt!U;
    else static if (is(U == E[], E) && !is(U : const(char)[]))
    {
        d.length = &arrayLength!U;
        d.element = &arrayElement!U;
        d.fromElements = &arrayFrom!U;
    }
    else static if (is(U == V[K], V, K))
    {
        d.toKeys = &aaKeys!U;
        d.toValues = &aaValues!U;
        d.fromEntries = &aaFrom!U;
    }
    else static if (__traits(compiles, U.__flintElements) && __traits(compiles, U.__flintFromElements))
    {
        d.length = &hookLength!U;
        d.element = &hookElement!U;
        d.fromElements = &hookFrom!U;
    }
    else static if (__traits(compiles, U.__flintEntries) && __traits(compiles, U.__flintFromEntries))
    {
        d.toKeys = &hookKeys!U;
        d.toValues = &hookValues!U;
        d.fromEntries = &hookFromEntries!U;
    }
    else static if (__traits(compiles, U.__flintUnwrap) && __traits(compiles, U.__flintWrap))
    {
        d.unwrap = &hookUnwrap!U;
        d.wrap = &hookWrap!U;
    }
    else static if (isStdNullable!U)
    {
        d.unwrap = &nullableUnwrap!U;
        d.wrap = &nullableWrap!U;
    }
}

// `std.typecons.Nullable!T`, rulebook R5's nullable value (Java's boxed `Integer`, a `String` that may be null),
// recognized by name so this module does not import std.typecons.
private enum isStdNullable(U) = typeNameOf!U.length > 22 && typeNameOf!U[0 .. 22]
    == "std.typecons.Nullable!" && __traits(compiles, U.init.isNull) && __traits(compiles, U.init.get());

private Any nullableUnwrap(T)(ref Any value) @safe
{
    auto self = value.get!T;
    return self.isNull ? Any.init : Any.of(self.get());
}

private Any nullableWrap(T)(Any value) @safe
{
    alias E = typeof(T.init.get());
    return value.isNull ? Any.of(T.init) : Any.of(T(value.get!E));
}

private Any enumAt(E)(long ordinal) @safe
{
    static immutable E[] members = enumMembers!E();
    if (ordinal < 0 || ordinal >= members.length)
        return Any.init;
    return Any.of(members[cast(size_t) ordinal]);
}

private E[] enumMembers(E)()
{
    E[] result;
    static foreach (member; __traits(allMembers, E))
        result ~= __traits(getMember, E, member);
    return result;
}

private size_t arrayLength(T)(ref Any value) @safe
{
    return value.get!T.length;
}

private Any arrayElement(T)(ref Any value, size_t index) @safe
{
    return Any.of(value.get!T[index]);
}

private Any arrayFrom(T : E[], E)(Any[] elements) @safe
{
    E[] result;
    result.reserve(elements.length);
    foreach (element; elements)
        result ~= element.get!E;
    return Any.of(result);
}

private Any[] aaKeys(T : V[K], V, K)(ref Any value) @safe
{
    Any[] result;
    foreach (key; value.get!T.byKey)
        result ~= Any.of(key);
    return result;
}

private Any[] aaValues(T : V[K], V, K)(ref Any value) @safe
{
    Any[] result;
    foreach (key; value.get!T.byKey)
        result ~= Any.of(value.get!T[key]);
    return result;
}

private Any aaFrom(T : V[K], V, K)(Any[] keys, Any[] values) @safe
{
    T result;
    foreach (i, key; keys)
        result[key.get!K] = values[i].get!V;
    return Any.of(result);
}

private size_t hookLength(T)(ref Any value) @safe
{
    auto self = value.get!T;
    return T.__flintElements(self).length;
}

private Any hookElement(T)(ref Any value, size_t index) @safe
{
    auto self = value.get!T;
    return Any.of(T.__flintElements(self)[index]);
}

private Any hookFrom(T)(Any[] elements) @safe
{
    alias E = T.__flintElementType;
    E[] items;
    foreach (element; elements)
        items ~= element.get!E;
    return Any.of(T.__flintFromElements(items));
}

private Any[] hookKeys(T)(ref Any value) @safe
{
    auto self = value.get!T;
    T.__flintKeyType[] keys;
    T.__flintElementType[] values;
    T.__flintEntries(self, keys, values);
    Any[] result;
    foreach (key; keys)
        result ~= Any.of(key);
    return result;
}

private Any[] hookValues(T)(ref Any value) @safe
{
    auto self = value.get!T;
    T.__flintKeyType[] keys;
    T.__flintElementType[] values;
    T.__flintEntries(self, keys, values);
    Any[] result;
    foreach (v; values)
        result ~= Any.of(v);
    return result;
}

private Any hookFromEntries(T)(Any[] keys, Any[] values) @safe
{
    T.__flintKeyType[] k;
    T.__flintElementType[] v;
    foreach (i, key; keys)
    {
        k ~= key.get!(T.__flintKeyType);
        v ~= values[i].get!(T.__flintElementType);
    }
    return Any.of(T.__flintFromEntries(k, v));
}

private Any hookUnwrap(T)(ref Any value) @safe
{
    auto self = value.get!T;
    auto inner = T.__flintUnwrap(self);
    return inner.length ? Any.of(inner[0]) : Any.init;
}

private Any hookWrap(T)(Any value) @safe
{
    alias E = T.__flintElementType;
    if (value.isNull)
        return Any.of(T.__flintWrap(E.init, false));
    return Any.of(T.__flintWrap(value.get!E, true));
}

private TypeKind kindOf(T)()
{
    static if (is(T == enum))
        return TypeKind.enum_;
    else static if (is(T : const(char)[]) && is(T == E[], E))
        return TypeKind.string_;
    else static if (__traits(isArithmetic, T) || is(T == bool))
        return TypeKind.scalar;
    else static if (is(T == E[], E) || is(T == V[K], V, K))
        return TypeKind.array;
    else static if (is(T == class))
        return TypeKind.class_;
    else static if (is(T == interface))
        return TypeKind.interface_;
    else
        return TypeKind.struct_;
}

/// Base classes (nearest first, without `Object`) then interfaces, transitively, without duplicates.
private template Supertypes(T)
{
    import std.meta : AliasSeq, NoDuplicates;

    static if (is(T S == super))
        alias Supertypes = NoDuplicates!(SupertypesOf!S);
    else
        alias Supertypes = AliasSeq!();
}

private template SupertypesOf(Bases...)
{
    import std.meta : AliasSeq;

    static if (Bases.length == 0)
        alias SupertypesOf = AliasSeq!();
    else static if (is(Bases[0] == Object))
        alias SupertypesOf = SupertypesOf!(Bases[1 .. $]);
    else
        alias SupertypesOf = AliasSeq!(Bases[0], Supertypes!(Bases[0]), SupertypesOf!(Bases[1 .. $]));
}

private Any createDefault(T)() @safe
{
    static if (is(T == class))
        return Any.of(new T());
    else
        return Any.of(T.init);
}

private Any invokeDefault(T)(scope Any[]) @safe
{
    return createDefault!T();
}

// ---------------------------------------------------------------------------------------------------------
// Annotations: Spring's MergedAnnotations, computed by the builder as the generator does.

/// UDA structs as instances: a bare `@Component` is `Component.init`.
private template UdaInstances(Attributes...)
{
    import std.meta : AliasSeq;

    static if (Attributes.length == 0)
        alias UdaInstances = AliasSeq!();
    else static if (is(Attributes[0] == struct))
        alias UdaInstances = AliasSeq!(Attributes[0].init, UdaInstances!(Attributes[1 .. $]));
    else static if (is(typeof(Attributes[0]) == struct))
        alias UdaInstances = AliasSeq!(Attributes[0], UdaInstances!(Attributes[1 .. $]));
    else
        alias UdaInstances = UdaInstances!(Attributes[1 .. $]);
}

private enum aliasForName = "flint.core.annotation.AliasFor";

/// `@AliasFor` configures merging; it is not itself a merged annotation.
private enum isAnnotation(U) = is(U == struct) && typeNameOf!U != aliasForName;

/++
The merged annotation list for the UDAs `attributes` of one element, as flint-aot's generator merges (contract
section 2.1, `merge.d`), so dub tests and generated tables agree:

- breadth first: the nearest declaration of a type wins, and among equals the first declared;
- an explicit `@AliasFor(annotation: ...)` maps its attribute even at its default, may target a meta-meta-annotation,
  and the nearest declaring annotation wins (a set alias over one at its default among equals);
- a single value aliasing an array attribute becomes a one-element array;
- intra-annotation mirrors and implicit aliases (attributes aliasing the same meta-annotation attribute) agree: the
  set one wins;
- a misconfigured `@AliasFor`, or a mirror pair given two values, sets `error` on every entry (with Spring's
  `AnnotationConfigurationException` message), where the generator reports FLINT-E1103.
`source` names the element in error messages, as Java's `toString` does (`class app.Owner`).
+/
MergedAnnotation[] mergedAnnotations(attributes...)(string source = null)
{
    MergeState state;
    state.source = source.length ? source : "an unknown element";
    static foreach (instance; UdaInstances!attributes)
    {
        static if (isAnnotation!(typeof(instance)))
            enqueue(state, instance, 0, null);
    }
    for (size_t next = 0; next < state.queue.length; next++)
    {
        auto current = state.queue[next];
        if (state.has(current.type))
            continue;
        state.result ~= MergedAnnotation(current.type, current.value, current.distance);
        if (current.distance < 8)
            current.expand(state, current.overrides, current.distance);
    }
    foreach (ref alias_; state.aliases)
        if (!state.has(alias_.type))
            state.fail("@AliasFor declaration on " ~ describe(alias_.fromAttribute,
                    alias_.fromAnnotation) ~ " declares an alias for " ~ describe(alias_.attribute,
                    alias_.type) ~ " which is not meta-present.");
    if (state.error.length)
        foreach (ref merged; state.result)
            merged.error = state.error;
    return state.result;
}

/// The merged annotations of `U`'s supertypes, one aggregate each, in Spring's `TYPE_HIERARCHY` order
/// (`AnnotationsScanner.processClassHierarchy`): its interfaces (recursively), then its superclass and that one's.
private MergedAnnotation[] supertypeAnnotations(U)()
{
    Hierarchy hierarchy;
    hierarchy.addSupertypes!U();
    return hierarchy.result;
}

private struct Hierarchy
{
    MergedAnnotation[] result;
    ubyte aggregate;

    void addSupertypes(U)()
    {
        static if (is(U S == super))
        {
            static foreach (B; S)
            {
                static if (is(B == interface))
                    add!B();
            }
            static foreach (B; S)
            {
                static if (is(B == class) && !is(B == Object))
                    add!B();
            }
        }
    }

    private void add(B)()
    {
        if (aggregate == ubyte.max)
            return;
        aggregate++;
        foreach (merged; mergedAnnotations!(__traits(getAttributes, B))())
        {
            merged.aggregateIndex = aggregate;
            result ~= merged;
        }
        addSupertypes!B();
    }
}

/// Keep the nearest declaration of `type` in a list being merged (one entry per type).
private void addAnnotation(ref MergedAnnotation[] result, string type, Any value, ubyte distance)
{
    foreach (ref existing; result)
        if (existing.type == type)
            return; // the nearest declaration wins; at equal distance, the first declared
    result ~= MergedAnnotation(type, value, distance);
}

/// One attribute's explicit `@AliasFor(annotation: ...)`, carried to every annotation further up the path.
private struct Override
{
    string type;
    string attribute;
    Any value;
    /// Whether the aliasing attribute differs from its default.
    bool set;
    /// Distance of the declaring annotation: the nearest one wins.
    ubyte distance;
    string fromAnnotation;
    string fromAttribute;
}

/// A queued annotation: its merged value, and the explicit aliases of every annotation on its path.
private struct Pending
{
    string type;
    Any value;
    ubyte distance;
    Override[] overrides;
    void function(ref MergeState, Override[], ubyte) @safe expand;
}

private struct MergeState
{
    MergedAnnotation[] result;
    Pending[] queue;
    string[] validated;
    Override[] aliases;
    string error;
    string source;

    bool has(string type) const pure nothrow @nogc
    {
        foreach (ref merged; result)
            if (merged.type == type)
                return true;
        return false;
    }

    /// Record the first configuration error, as Spring throws on the first.
    void fail(string message) pure nothrow @nogc
    {
        if (error.length == 0)
            error = message;
    }
}

private enum isAliasFor(U) = typeNameOf!U == aliasForName;

/// Spring's `AttributeMethods.describe`.
private string describe(string attribute, string annotation) pure nothrow
{
    return "attribute '" ~ attribute ~ "' in annotation [" ~ annotation ~ "]";
}

private void enqueue(A)(ref MergeState state, A declared, ubyte distance, Override[] inherited)
{
    validate!A(state);
    auto merged = mirrored(declared, state);
    state.queue ~= Pending(typeNameOf!A, Any.of(merged), distance,
            inherited ~ explicitAliases(merged, distance), &expand!A);
}

/// Queue `A`'s meta-annotations, with the attributes the annotations below override through `@AliasFor`.
private void expand(A)(ref MergeState state, Override[] overrides, ubyte distance)
{
    static foreach (meta; UdaInstances!(__traits(getAttributes, A)))
    {
        static if (isAnnotation!(typeof(meta)) && !is(typeof(meta) == A))
            enqueue(state, overridden(meta, overrides, state), cast(ubyte)(distance + 1), overrides);
    }
}

/// The attribute an `@AliasFor` names: `attribute`, else `value`, else the aliasing field's own name.
private string aliasTarget(F)(F alias_, string fieldName)
{
    if (alias_.attribute.length)
        return alias_.attribute;
    if (alias_.value.length)
        return alias_.value;
    return fieldName;
}

/// Whether an `@AliasFor` aliases an attribute of the annotation `self` declares it on.
private bool isLocal(F)(F alias_, string self)
{
    return alias_.annotation.name.length == 0 || alias_.annotation.name == self;
}

/// The explicit aliases `instance`'s attributes declare to its meta-annotations' attributes.
private Override[] explicitAliases(A)(A instance, ubyte distance)
{
    Override[] result;
    static foreach (i; 0 .. A.tupleof.length)
    {
        static foreach (alias_; UdaInstances!(__traits(getAttributes, A.tupleof[i])))
        {
            static if (isAliasFor!(typeof(alias_)))
            {
                if (!isLocal(alias_, typeNameOf!A))
                    result ~= Override(alias_.annotation.name, aliasTarget(alias_,
                            __traits(identifier, A.tupleof[i])), Any.of(instance.tupleof[i]),
                            instance.tupleof[i] != A.init.tupleof[i], distance, typeNameOf!A,
                            __traits(identifier, A.tupleof[i]));
            }
        }
    }
    return result;
}

/// Among the nearest annotation's aliases of `type.attribute`, a set one, else the first; null when none.
private Override* chosen(return Override[] overrides, string type, string attribute) pure nothrow @nogc
{
    Override* pick;
    foreach (ref item; overrides)
    {
        if (item.type != type || item.attribute != attribute)
            continue;
        if (pick is null || item.distance < pick.distance || (item.distance == pick.distance && item.set && !pick.set))
            pick = &item;
    }
    return pick;
}

/// The meta-annotation `meta` with the attributes the annotations below it alias.
private M overridden(M)(M meta, Override[] overrides, ref MergeState state)
{
    M result = meta;
    static foreach (j; 0 .. M.tupleof.length)
    {
        {
            enum name = __traits(identifier, M.tupleof[j]);
            if (auto pick = chosen(overrides, typeNameOf!M, name))
            {
                if (!assign(result.tupleof[j], pick.value))
                    state.fail("Misconfigured aliases: " ~ describe(pick.fromAttribute,
                            pick.fromAnnotation) ~ " and " ~ describe(name,
                            typeNameOf!M) ~ " must declare the same return type.");
                else if (result.tupleof[j] != M.init.tupleof[j])
                    setPartner!j(result); // the set member of a mirror pair replaces its partner too
            }
        }
    }
    foreach (ref item; overrides)
        if (item.type == typeNameOf!M && !hasField!M(item.attribute))
            state.fail(capitalized(describe(item.fromAttribute,
                    item.fromAnnotation)) ~ " is declared as an @AliasFor nonexistent " ~ describe(item.attribute,
                    typeNameOf!M) ~ ".");
    return result;
}

private string capitalized(string text) pure nothrow
{
    return text.length && text[0] >= 'a' && text[0] <= 'z' ? cast(char)(text[0] - 32) ~ text[1 .. $] : text;
}

private bool hasField(M)(string name)
{
    static foreach (j; 0 .. M.tupleof.length)
        if (__traits(identifier, M.tupleof[j]) == name)
            return true;
    return false;
}

/// Write an aliased value into `field`: the same type, or one element of an array attribute.
private bool assign(F)(ref F field, ref Any value)
{
    static if (is(F == E[], E) && !is(F == string))
    {
        if (value.holds!F)
        {
            field = value.get!F;
            return true;
        }
        if (value.holds!E)
        {
            static if (is(immutable(E) == immutable(string)))
                field = value.get!E.length ? [value.get!E] : null; // an empty single value is an empty array
            else
                field = [value.get!E];
            return true;
        }
        return false;
    }
    else
    {
        if (!value.holds!F)
            return false;
        field = value.get!F;
        return true;
    }
}

/// Give the intra-annotation alias partner of field `j` the same value.
private void setPartner(size_t j, M)(ref M result)
{
    static foreach (alias_; UdaInstances!(__traits(getAttributes, M.tupleof[j])))
    {
        static if (isAliasFor!(typeof(alias_)))
        {
            if (isLocal(alias_, typeNameOf!M))
            {
                const partner = aliasTarget(alias_, __traits(identifier, M.tupleof[j]));
                static foreach (k; 0 .. M.tupleof.length)
                {
                    static if (k != j && is(typeof(M.tupleof[k]) == typeof(M.tupleof[j])))
                    {
                        if (__traits(identifier, M.tupleof[k]) == partner)
                            result.tupleof[k] = result.tupleof[j];
                    }
                }
            }
        }
    }
}

private string notPresent(string where, string attribute) pure nothrow
{
    return "@AliasFor declaration on " ~ where ~ " declares an alias for '" ~ attribute ~ "' which is not present.";
}

/// Whether field `j` of `A` is `attribute` (an intra-annotation alias, `target` empty), or, for an explicit alias
/// of `target.attribute`, declares one to the same attribute (implicit aliases).
private bool linked(A, size_t j)(string target, string attribute)
{
    if (target.length == 0)
        return __traits(identifier, A.tupleof[j]) == attribute;
    bool result;
    static foreach (alias_; UdaInstances!(__traits(getAttributes, A.tupleof[j])))
    {
        static if (isAliasFor!(typeof(alias_)))
        {
            if (!isLocal(alias_, typeNameOf!A) && alias_.annotation.name == target)
            {
                const other = aliasTarget(alias_, __traits(identifier, A.tupleof[j]));
                result = other == attribute || aliasedInMeta!A(target, attribute, other, 0);
            }
        }
    }
    return result;
}

/// Whether attributes `first` and `second` of `A`'s direct meta-annotation `target` are aliases of each other, so
/// attributes aliasing them are implicit aliases too (Spring's `MirrorSets` follow alias chains).
private bool aliasedInMeta(A)(string target, string first, string second, uint depth)
{
    if (depth > 8)
        return false;
    static foreach (meta; UdaInstances!(__traits(getAttributes, A)))
    {
        static if (isAnnotation!(typeof(meta)) && !is(typeof(meta) == A))
        {
            if (typeNameOf!(typeof(meta)) == target)
                return aliasedIn!(typeof(meta))(first, second, depth);
        }
    }
    return false;
}

/// Whether attributes `first` and `second` of `M` are a mirror pair, or alias the same attribute (or a mirror pair)
/// of one of `M`'s meta-annotations.
private bool aliasedIn(M)(string first, string second, uint depth)
{
    if (first == second)
        return true;
    string firstTarget, firstAttribute, secondTarget, secondAttribute;
    static foreach (k; 0 .. M.tupleof.length)
    {
        static foreach (alias_; UdaInstances!(__traits(getAttributes, M.tupleof[k])))
        {
            static if (isAliasFor!(typeof(alias_)))
            {
                {
                    enum name = __traits(identifier, M.tupleof[k]);
                    const local = isLocal(alias_, typeNameOf!M);
                    const attribute = aliasTarget(alias_, name);
                    if (local && ((name == first && attribute == second) || (name == second && attribute == first)))
                        return true;
                    if (!local && name == first)
                    {
                        firstTarget = alias_.annotation.name;
                        firstAttribute = attribute;
                    }
                    if (!local && name == second)
                    {
                        secondTarget = alias_.annotation.name;
                        secondAttribute = attribute;
                    }
                }
            }
        }
    }
    return firstTarget.length && firstTarget == secondTarget && aliasedInMeta!M(firstTarget,
            firstAttribute, secondAttribute, depth + 1);
}

/// `instance` with its aliased attributes agreeing: the set one of each mirror pair or implicit alias set wins.
private A mirrored(A)(A instance, ref MergeState state)
{
    static foreach (i; 0 .. A.tupleof.length)
    {
        static foreach (alias_; UdaInstances!(__traits(getAttributes, A.tupleof[i])))
        {
            static if (isAliasFor!(typeof(alias_)))
            {
                {
                    const local = isLocal(alias_, typeNameOf!A);
                    const target = local ? null : alias_.annotation.name;
                    const attribute = aliasTarget(alias_, __traits(identifier, A.tupleof[i]));
                    static foreach (j; 0 .. A.tupleof.length)
                    {
                        static if (i != j && is(typeof(A.tupleof[i]) == typeof(A.tupleof[j])))
                        {
                            if (linked!(A, j)(target, attribute))
                                mirror!(i, j)(instance, state);
                        }
                    }
                }
            }
        }
    }
    return instance;
}

private void mirror(size_t i, size_t j, A)(ref A instance, ref MergeState state)
{
    const mineSet = instance.tupleof[i] != A.init.tupleof[i];
    const theirsSet = instance.tupleof[j] != A.init.tupleof[j];
    enum mine = __traits(identifier, A.tupleof[i]);
    enum theirs = __traits(identifier, A.tupleof[j]);
    if (mineSet && theirsSet && instance.tupleof[i] != instance.tupleof[j])
    {
        // Spring's MirrorSet resolves attributes in name order.
        static if (mine < theirs)
            state.fail("Different @AliasFor mirror values for annotation [" ~ typeNameOf!A
                    ~ "] declared on " ~ state.source ~ "; attribute '" ~ mine ~ "' and its alias '"
                    ~ theirs ~ "' are declared with values of [" ~ javaString(
                        instance.tupleof[i]) ~ "] and [" ~ javaString(instance.tupleof[j]) ~ "].");
    }
    else if (mineSet && !theirsSet)
        instance.tupleof[j] = instance.tupleof[i];
    else if (theirsSet && !mineSet)
        instance.tupleof[i] = instance.tupleof[j];
}

/// Spring's `ObjectUtils.nullSafeToString` for attribute values in messages: arrays as `{a, b}`.
private string javaString(T)(T value)
{
    import flint.engine.aot.text : decimal;

    static if (is(T : const(char)[]))
        return value.idup;
    else static if (is(T == E[], E))
    {
        string text = "{";
        foreach (k, element; value)
            text ~= (k ? ", " : "") ~ javaString(element);
        return text ~ "}";
    }
    else static if (is(T == bool))
        return value ? "true" : "false";
    else static if (__traits(isIntegral, T) && !is(T == enum))
        return decimal(cast(long) value);
    else
        return typeNameOf!T;
}

/// Spring's `AnnotationTypeMapping` checks of `A`'s `@AliasFor` declarations, once per type.
private void validate(A)(ref MergeState state)
{
    foreach (name; state.validated)
        if (name == typeNameOf!A)
            return;
    state.validated ~= typeNameOf!A;
    static foreach (i; fieldsByName!A)
    {
        static foreach (alias_; UdaInstances!(__traits(getAttributes, A.tupleof[i])))
        {
            static if (isAliasFor!(typeof(alias_)))
            {
                validateAlias!(A, i)(alias_, state);
                if (!isLocal(alias_, typeNameOf!A))
                    validateImplicit!(A, i)(alias_.annotation.name, aliasTarget(alias_,
                            __traits(identifier, A.tupleof[i])), state);
            }
        }
    }
}

/// Implicit aliases of field `i` (aliasing `target.attribute`) must declare its default.
private void validateImplicit(A, size_t i)(string target, string attribute, ref MergeState state)
{
    static foreach (j; fieldsByName!A)
    {
        static if (i != j && is(typeof(A.tupleof[i]) == typeof(A.tupleof[j])))
        {
            if (linked!(A, j)(target, attribute) && A.init.tupleof[i] != A.init.tupleof[j])
                return state.fail("Misconfigured aliases: " ~ describe(__traits(identifier,
                        A.tupleof[i]), typeNameOf!A) ~ " and " ~ describe(__traits(identifier,
                        A.tupleof[j]), typeNameOf!A) ~ " must declare the same default value.");
        }
    }
}

private void validateAlias(A, size_t i, F)(F alias_, ref MergeState state)
{
    enum field = __traits(identifier, A.tupleof[i]);
    const where = describe(field, typeNameOf!A);
    if (alias_.attribute.length && alias_.value.length)
        return state.fail("In @AliasFor declared on " ~ where ~ ", attribute 'attribute' and its alias 'value' "
                ~ "are present with values of '" ~ alias_.attribute ~ "' and '" ~ alias_.value
                ~ "', but only one is permitted.");
    const attribute = aliasTarget(alias_, field);
    if (!isLocal(alias_, typeNameOf!A))
        state.aliases ~= Override(alias_.annotation.name, attribute, Any.init, false, 0, typeNameOf!A, field);
    else
        validateLocalAlias!(A, i)(attribute, state);
}

/// An intra-annotation alias of field `i` names an attribute that exists, is not itself, aliases it back, and has its
/// type and default.
private void validateLocalAlias(A, size_t i)(string attribute, ref MergeState state)
{
    enum field = __traits(identifier, A.tupleof[i]);
    const where = describe(field, typeNameOf!A);
    if (attribute == field)
        return state.fail("@AliasFor declaration on " ~ where ~ " points to itself. Specify 'annotation' to point "
                ~ "to a same-named attribute on a meta-annotation.");
    if (!hasField!A(attribute))
        return state.fail(notPresent(where, attribute));
    static foreach (j; 0 .. A.tupleof.length)
    {
        static if (i != j)
        {
            if (__traits(identifier, A.tupleof[j]) == attribute)
            {
                const mirror = localAlias!(A, j)();
                const partner = describe(attribute, typeNameOf!A);
                if (mirror.length && !hasField!A(mirror))
                    return state.fail(notPresent(partner, mirror));
                if (mirror.length && mirror != field)
                    return state.fail(capitalized(
                            partner) ~ " must be declared as an @AliasFor " ~ where ~ ", not " ~ describe(mirror,
                            typeNameOf!A) ~ ".");
                static if (!is(typeof(A.tupleof[i]) == typeof(A.tupleof[j])))
                    return state.fail("Misconfigured aliases: " ~ where ~ " and " ~ describe(attribute,
                            typeNameOf!A) ~ " must declare the same return type.");
                else
                {
                    if (A.init.tupleof[i] != A.init.tupleof[j])
                        return state.fail("Misconfigured aliases: " ~ where ~ " and " ~ describe(attribute,
                                typeNameOf!A) ~ " must declare the same default value.");
                }
            }
        }
    }
}

/// `A`'s field indexes in name order, the order of Spring's `AttributeMethods`.
private enum size_t[] fieldsByName(A) = () {
    size_t[] order;
    foreach (i, name; fieldNames!A)
    {
        size_t at = order.length;
        while (at > 0 && fieldNames!A[order[at - 1]] > name)
            at--;
        order = order[0 .. at] ~ i ~ order[at .. $];
    }
    return order;
}();

private template fieldNames(A)
{
    import std.meta : staticMap;

    private enum nameOf(alias field) = __traits(identifier, field);
    enum string[] fieldNames = [staticMap!(nameOf, A.tupleof)];
}

/// The attribute field `j` of `A` names in an intra-annotation `@AliasFor`, or null when it declares none.
private string localAlias(A, size_t j)()
{
    string result;
    static foreach (alias_; UdaInstances!(__traits(getAttributes, A.tupleof[j])))
    {
        static if (isAliasFor!(typeof(alias_)))
        {
            if (isLocal(alias_, typeNameOf!A))
                result = aliasTarget(alias_, __traits(identifier, A.tupleof[j]));
        }
    }
    return result;
}

// ---------------------------------------------------------------------------------------------------------
// Properties: public fields, then Java Beans accessors, merged by name.

private PropertyDescriptor[] propertiesOf(T)()
{
    PropertyDescriptor[] result;
    static foreach (i, field; T.tupleof)
    {
        static if (__traits(getVisibility, T.tupleof[i]) == "public")
            result ~= PropertyDescriptor(__traits(identifier, T.tupleof[i]),
                    typeNameOf!(typeof(T.tupleof[i])), mergedAnnotations!(__traits(getAttributes,
                        T.tupleof[i]))(), &fieldGet!(T, i), isAssignableField!(T, i) ? &fieldSet!(T, i) : null);
    }
    static foreach (member; __traits(derivedMembers, T))
    {
        static if (isGetter!(T, member))
            addAccessor(result, beanName(member), typeNameOf!(GetterType!(T, member)),
                    mergedAnnotations!(__traits(getAttributes, __traits(getMember, T, member)))(),
                    &getterGet!(T, member), null);
        else static if (isSetter!(T, member))
            addAccessor(result, beanName(member), typeNameOf!(SetterType!(T, member)),
                    mergedAnnotations!(__traits(getAttributes, __traits(getMember, T, member)))(),
                    null, &setterSet!(T, member));
    }
    // Annotations on a private backing field (`@JsonProperty private string name;`) belong to its property.
    static foreach (i, field; T.tupleof)
    {
        static if (__traits(getVisibility, T.tupleof[i]) != "public")
        {
            foreach (ref p; result)
                if (p.name == __traits(identifier, T.tupleof[i]))
                    foreach (a; mergedAnnotations!(__traits(getAttributes, T.tupleof[i]))())
                        addAnnotation(p.annotations, a.type, a.value, a.distance);
        }
    }
    return result;
}

private void addAccessor(ref PropertyDescriptor[] result, string name, string type,
        MergedAnnotation[] annotations, Any function(ref Any) @safe get, void function(ref Any, Any) @safe set)
{
    foreach (ref p; result)
    {
        if (p.name != name)
            continue;
        if (get !is null)
            p.get = get;
        if (set !is null)
            p.set = set;
        foreach (a; annotations)
            addAnnotation(p.annotations, a.type, a.value, a.distance);
        return;
    }
    result ~= PropertyDescriptor(name, type, annotations, get, set);
}

/// `getName` and `isActive` give `name` and `active`; `getURL` stays `URL` (Java Beans' `decapitalize`).
package string beanName(string method) pure
{
    string rest = method.length > 2 && method[0 .. 2] == "is" ? method[2 .. $] : method[3 .. $];
    if (rest.length >= 2 && isUpper(rest[0]) && isUpper(rest[1]))
        return rest;
    return [cast(char)(rest[0] + (isUpper(rest[0]) ? 32 : 0))] ~ rest[1 .. $];
}

private bool isUpper(char c) pure nothrow @nogc
{
    return c >= 'A' && c <= 'Z';
}

private bool accessorName(string member, string prefix) pure nothrow @nogc
{
    return member.length > prefix.length && member[0 .. prefix.length] == prefix && isUpper(member[prefix.length]);
}

private template isPublicMethod(T, string member)
{
    static if (__traits(compiles, __traits(getVisibility, __traits(getMember, T, member))))
        enum isPublicMethod = __traits(getVisibility, __traits(getMember, T, member)) == "public"
            && is(typeof(__traits(getMember,
                    T, member)) == function) && !__traits(isStaticFunction, __traits(getMember, T, member));
    else
        enum isPublicMethod = false;
}

private template isGetter(T, string member)
{
    static if ((accessorName(member, "get") || accessorName(member, "is")) && isPublicMethod!(T,
            member) && __traits(compiles, GetterType!(T, member)))
        enum isGetter = !is(GetterType!(T, member) == void) && (accessorName(member, "get")
                    || is(GetterType!(T, member) == bool));
    else
        enum isGetter = false;
}

private template GetterType(T, string member)
{
    T* instance;
    alias GetterType = typeof(cast() __traits(getMember, *instance, member)());
}

private template isSetter(T, string member)
{
    static if (accessorName(member, "set") && isPublicMethod!(T, member))
        enum isSetter = __traits(compiles, SetterType!(T, member));
    else
        enum isSetter = false;
}

private template SetterType(T, string member)
{
    static if (is(typeof(__traits(getMember, T, member)) P == function) && is(typeof(P.length)))
    {
        import std.traits : Parameters;

        alias Params = Parameters!(__traits(getMember, T, member));
        static assert(Params.length == 1);
        alias SetterType = typeof(cast() Params[0].init);
    }
}

private enum isAssignableField(T, size_t i) = !is(typeof(T.tupleof[i]) == immutable)
    && !is(typeof(T.tupleof[i]) == const) && __traits(compiles, {
        T* t;
        typeof(T.tupleof[i]) v = typeof(T.tupleof[i]).init;
        (*t).tupleof[i] = v;
    });

private Any fieldGet(T, size_t i)(ref Any self) @safe
{
    static if (is(T == class))
    {
        auto instance = self.get!T;
        return instance is null ? Any.init : Any.of(instance.tupleof[i]);
    }
    else
    {
        auto box = self.box!T;
        return box is null ? Any.init : Any.of(box.value.tupleof[i]);
    }
}

private void fieldSet(T, size_t i)(ref Any self, Any value) @safe
{
    alias F = typeof(T.tupleof[i]);
    static if (!isAssignableField!(T, i))
        return;
    else static if (is(T == class))
    {
        auto instance = self.get!T;
        if (instance !is null)
            instance.tupleof[i] = value.get!F;
    }
    else
    {
        auto box = self.box!T;
        if (box !is null)
            box.value.tupleof[i] = value.get!F;
    }
}

private Any getterGet(T, string member)(ref Any self) @safe
{
    static if (is(T == class))
    {
        auto instance = self.get!T;
        return instance is null ? Any.init : Any.of(__traits(getMember, instance, member)());
    }
    else
    {
        auto box = self.box!T;
        return box is null ? Any.init : Any.of(__traits(getMember, box.value, member)());
    }
}

private void setterSet(T, string member)(ref Any self, Any value) @safe
{
    static if (is(T == class))
    {
        if (auto instance = self.get!T)
            __traits(getMember, instance, member)(value.get!(SetterType!(T, member)));
    }
    else
    {
        if (auto box = self.box!T)
            __traits(getMember, box.value, member)(value.get!(SetterType!(T, member)));
    }
}
