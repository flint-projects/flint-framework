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
    /// Runtime extension: the element type of an array, `Optional!T`, `List!T` or `Set!T`; a map's value type.
    string elementType;
    /// Runtime extension: the key type of a map.
    string keyType;

    /// A descriptor with no members yet, as generated code builds one.
    this(string name, TypeKind kind) pure nothrow
    {
        this.name = name;
        this.kind = kind;
    }

    /// The annotation of type `type` nearest to the element, or null. Hot: no allocation.
    const(MergedAnnotation)* annotation(string type) const nothrow @nogc
    {
        return findAnnotation(annotations, type);
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

        return simpleTypeName(name);
    }
}

/// The nearest annotation of `type` in a merged list, or null.
const(MergedAnnotation)* findAnnotation(return scope const(MergedAnnotation)[] annotations, string type) nothrow @nogc
{
    const(MergedAnnotation)* best;
    foreach (ref a; annotations)
        if (a.type == type && (best is null || a.distance < best.distance))
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
        static foreach (member; __traits(allMembers, U))
            d.enumConstants ~= member;
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
    static if (__traits(compiles, U.__flintKeyType.init))
        d.keyType = typeNameOf!(U.__flintKeyType);
    static if (is(U == struct) || is(U == class) || is(U == interface) || is(U == enum))
        d.annotations = mergedAnnotations!(__traits(getAttributes, U))();
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

/// The merged annotation list for the UDAs `attributes` of one element.
MergedAnnotation[] mergedAnnotations(attributes...)()
{
    MergedAnnotation[] result;
    static foreach (instance; UdaInstances!attributes)
    {
        static if (isAnnotation!(typeof(instance)))
            addAnnotation(result, typeNameOf!(typeof(instance)), Any.of(resolveMirrors(instance)), 0);
    }
    static foreach (instance; UdaInstances!attributes)
    {
        static if (isAnnotation!(typeof(instance)))
            appendMeta!(typeof(instance))(result, resolveMirrors(instance), 1);
    }
    return result;
}

private void addAnnotation(ref MergedAnnotation[] result, string type, Any value, ubyte distance)
{
    foreach (ref existing; result)
        if (existing.type == type)
            return; // the nearest declaration wins; at equal distance, the first declared
    result ~= MergedAnnotation(type, value, distance);
}

private void appendMeta(A)(ref MergedAnnotation[] result, A root, ubyte distance)
{
    if (distance > 8)
        return;
    static foreach (meta; UdaInstances!(__traits(getAttributes, A)))
    {
        static if (isAnnotation!(typeof(meta)) && !is(typeof(meta) == A))
        {
            {
                auto merged = resolveMirrors(applyAliases(root, meta));
                const before = result.length;
                addAnnotation(result, typeNameOf!(typeof(meta)), Any.of(merged), distance);
                if (result.length > before)
                    appendMeta!(typeof(meta))(result, merged, cast(ubyte)(distance + 1));
            }
        }
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

/// Copy the attributes of `root` declared `@AliasFor(annotation: classOf!M)` onto meta-annotation `meta`, when
/// they differ from their defaults.
private M applyAliases(A, M)(A root, M meta)
{
    static foreach (i, field; A.tupleof)
    {
        static foreach (alias_; UdaInstances!(__traits(getAttributes, A.tupleof[i])))
        {
            static if (typeNameOf!(typeof(alias_)) == aliasForName)
            {
                {
                    if (alias_.annotation.name == typeNameOf!M && root.tupleof[i] != A.init.tupleof[i])
                    {
                        const target = aliasTarget(alias_, __traits(identifier, A.tupleof[i]));
                        static foreach (j, member; M.tupleof)
                        {
                            static if (__traits(compiles, meta.tupleof[j] = root.tupleof[i]))
                            {
                                if (__traits(identifier, M.tupleof[j]) == target)
                                    meta.tupleof[j] = root.tupleof[i];
                            }
                        }
                    }
                }
            }
        }
    }
    return meta;
}

/// Within one annotation, an attribute set away from its default fills the mirror it aliases.
private A resolveMirrors(A)(A instance)
{
    static foreach (i, field; A.tupleof)
    {
        static foreach (alias_; UdaInstances!(__traits(getAttributes, A.tupleof[i])))
        {
            static if (typeNameOf!(typeof(alias_)) == aliasForName)
            {
                {
                    if ((alias_.annotation.name.length == 0
                            || alias_.annotation.name == typeNameOf!A) && instance.tupleof[i] != A.init.tupleof[i])
                    {
                        const mirror = aliasTarget(alias_, __traits(identifier, A.tupleof[i]));
                        static foreach (j, member; A.tupleof)
                        {
                            static if (i != j && __traits(compiles, instance.tupleof[j] = instance.tupleof[i]))
                            {
                                if (__traits(identifier, A.tupleof[j]) == mirror
                                        && instance.tupleof[j] == A.init.tupleof[j])
                                    instance.tupleof[j] = instance.tupleof[i];
                            }
                        }
                    }
                }
            }
        }
    }
    return instance;
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
