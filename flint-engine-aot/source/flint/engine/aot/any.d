/++
`Any`: the erased value behind `Object`-typed APIs (AOT contract section 4.1).

An `Any` holds a value and its type's canonical name (`flint.engine.aot.name`). Class and interface references
are stored as references; booleans, integers, characters, integral enums and floating-point values inline in a
64-bit slot; strings inline as a slice; anything else (structs, other enums, arrays, maps) in a GC `Box`. It never
uses `std.variant`, and every access is `@safe`: the reference slots never overlap the bit slot.

`get!T` returns by `ref` for boxed structs, so generated code and binders can update a boxed struct in place, and
by value for class, interface, scalar, string, array and map `T`, where a reference would alias a cast, reinterpret
inline bits, or point at a null array that has no box.
+/
module flint.engine.aot.any;

import flint.engine.aot.name : typeNameOf;

@safe:

/// Thrown by `Any.get` when the value does not have the requested type (Java's `ClassCastException` role).
class AnyTypeException : Exception
{
    /// The requested and the held type names.
    string requested, held;

    /// Record the requested and held type names.
    this(string requested, string held, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        this.requested = requested;
        this.held = held;
        super("Any holds " ~ (held.length ? held : "nothing") ~ ", not " ~ requested, file, line);
    }
}

/// A GC box holding a value type inside an `Any`.
final class Box(T)
{
    /// The boxed value.
    T value;

    /// Box a copy of `value`.
    this(T value) pure nothrow
    {
        this.value = value;
    }

    override bool opEquals(Object other) const
    {
        auto that = cast(const Box!T) other;
        static if (__traits(compiles, (const T a, const T b) => a == b))
            return that !is null && that.value == value;
        else
            return that is this;
    }

    override size_t toHash() const nothrow
    {
        static if (__traits(compiles, ()nothrow{ const T v; return hashOf(v); }))
            return hashOf(value);
        else
            return 0;
    }
}

private enum Slot : ubyte
{
    empty,
    reference,
    box,
    integral,
    unsigned,
    floating,
    boolean,
    character,
    text,
    enumeration,
}

/// How `Any` stores and converts values of a type.
private enum Category
{
    any,
    reference,
    text,
    enumeration,
    boolean,
    character,
    integral,
    floating,
    collection,
    boxed,
}

/// A mutable or const character array other than `string`: copied into a `string`.
private enum isCharArray(T) = is(T : const(char)[]) && is(T == E[], E) && !is(T == enum)
    && !is(typeof(cast() T.init) == string);

private template bitSlot(U)
{
    static if (categoryOf!U == Category.enumeration)
        enum bitSlot = Slot.enumeration;
    else static if (is(U == bool))
        enum bitSlot = Slot.boolean;
    else static if (categoryOf!U == Category.character)
        enum bitSlot = Slot.character;
    else static if (is(U == ulong) || is(U == uint) || is(U == ushort) || is(U == ubyte))
        enum bitSlot = Slot.unsigned;
    else
        enum bitSlot = Slot.integral;
}

private template categoryOf(U)
{
    static if (is(U == Any))
        enum categoryOf = Category.any;
    else static if (is(U == class) || is(U == interface))
        enum categoryOf = Category.reference;
    else static if (is(U == string))
        enum categoryOf = Category.text;
    else static if (is(U == enum) && is(U B == enum) && __traits(isIntegral, B))
        enum categoryOf = Category.enumeration;
    else static if (is(U == enum))
        enum categoryOf = Category.boxed;
    else static if (is(U == bool))
        enum categoryOf = Category.boolean;
    else static if (is(U == char) || is(U == wchar) || is(U == dchar))
        enum categoryOf = Category.character;
    else static if (__traits(isIntegral, U))
        enum categoryOf = Category.integral;
    else static if (__traits(isFloating, U))
        enum categoryOf = Category.floating;
    else static if (is(U == E[], E) || is(U == V[K], V, K))
        enum categoryOf = Category.collection;
    else
        enum categoryOf = Category.boxed;
}

/// An erased value: a type name and the value.
struct Any
{
    private string typeName_;
    private Object object_;
    private union
    {
        long long_;
        double double_;
    }

    private string string_;
    private Slot slot_;

    /// Wrap a copy of `value`, recording `T`'s canonical name.
    static Any of(T)(T value)
    {
        static if (is(T == Any))
            return value;
        else static if (isCharArray!T)
            return of!string(value.idup);
        else
        {
            alias U = typeof(cast() value);
            enum category = categoryOf!U;
            Any result;
            result.typeName_ = typeNameOf!U;
            static if (category == Category.reference)
            {
                static assert(is(T == U), "Any.of: a const or immutable class reference would lose its qualifier");
                result.object_ = cast(Object) value;
                result.slot_ = Slot.reference;
            }
            else static if (category == Category.text)
            {
                result.string_ = value;
                result.slot_ = Slot.text;
            }
            else static if (category == Category.floating)
            {
                result.double_ = cast(double) value;
                result.slot_ = Slot.floating;
            }
            else static if (category == Category.collection)
            {
                // A null array or map is null, as Java's null collection reference is.
                if (value !is null)
                    result.object_ = new Box!U(value);
                result.slot_ = Slot.box;
            }
            else static if (category == Category.boxed)
            {
                result.object_ = new Box!U(value);
                result.slot_ = Slot.box;
            }
            else
            {
                result.long_ = cast(long) value;
                result.slot_ = bitSlot!U;
            }
            return result;
        }
    }

    /// Wrap an object whose static type is known only by name (a bean instance created by a generated factory).
    static Any ofObject(Object value, string typeName) pure nothrow @nogc
    {
        Any result;
        result.typeName_ = typeName;
        result.object_ = value;
        result.slot_ = Slot.reference;
        return result;
    }

    /++
    An integral enum value known only by its type's canonical name, as an erased converter builds one from
    `Descriptor.enumValues`; `get!E` succeeds for that enum.
    +/
    static Any ofEnum(string typeName, long value) pure nothrow @nogc
    {
        Any result;
        result.typeName_ = typeName;
        result.long_ = value;
        result.slot_ = Slot.enumeration;
        return result;
    }

    /// The bits of an integral enum value (with `typeName`, the erased form `ofEnum` takes); 0 otherwise.
    long enumBits() const pure nothrow @nogc
    {
        return slot_ == Slot.enumeration ? long_ : 0;
    }

    /// Whether this holds an integral enum value.
    bool isEnum() const pure nothrow @nogc
    {
        return slot_ == Slot.enumeration;
    }

    /// Whether this is `Any.init`, a null class reference or a null array.
    bool isNull() const pure nothrow @nogc
    {
        final switch (slot_)
        {
        case Slot.empty:
            return true;
        case Slot.reference:
            return object_ is null;
        case Slot.box:
            return object_ is null;
        case Slot.text:
            return string_ is null;
        case Slot.integral, Slot.unsigned, Slot.floating, Slot.boolean, Slot.character, Slot.enumeration:
            return false;
        }
    }

    /// The fully qualified D name of the held value's type; empty for `Any.init`.
    string typeName() const pure nothrow @nogc
    {
        return typeName_;
    }

    /// The held class reference; null for every other kind of value.
    inout(Object) asObject() inout pure nothrow @nogc
    {
        return slot_ == Slot.reference ? object_ : null;
    }

    /// Whether `get!T` would succeed.
    bool holds(T)() const
    {
        alias U = typeof(cast() T.init);
        enum category = categoryOf!U;
        static if (category == Category.any)
            return true;
        else static if (category == Category.reference)
            return holdsReference!U();
        else static if (category == Category.boxed || category == Category.collection)
            return holdsBoxed!U();
        else
            return holdsScalar!U();
    }

    private bool holdsReference(U)() const
    {
        if (slot_ == Slot.empty)
            return true;
        return slot_ == Slot.reference && (object_ is null || (cast(const U) object_) !is null);
    }

    private bool holdsScalar(U)() const
    {
        enum category = categoryOf!U;
        static if (category == Category.text)
            return slot_ == Slot.text || slot_ == Slot.empty;
        else static if (category == Category.enumeration)
            return slot_ == Slot.enumeration && typeName_ == typeNameOf!U;
        else static if (category == Category.boolean)
            return slot_ == Slot.boolean;
        else static if (category == Category.character)
            return slot_ == Slot.character && long_ >= U.min && long_ <= U.max;
        else static if (category == Category.integral)
            return (slot_ == Slot.integral || slot_ == Slot.unsigned) && fits!U();
        else
            return slot_ == Slot.floating || slot_ == Slot.integral || slot_ == Slot.unsigned;
    }

    private bool holdsBoxed(U)() const
    {
        if (categoryOf!U == Category.collection && slot_ == Slot.empty)
            return true;
        if (slot_ != Slot.box || typeName_ != typeNameOf!U)
            return false;
        return (cast(const Box!U) object_) !is null || (categoryOf!U == Category.collection && object_ is null);
    }

    /++
    The held value as `T`: the exact type, a base class or interface of a held class, or a `const` view.
    Integral values convert to another integral type when they fit, and to floating point. Throws
    `AnyTypeException` otherwise. Returns by `ref` into the box for boxed structs.
    +/
    auto ref get(T)() inout return
    {
        alias U = typeof(cast() T.init);
        enum category = categoryOf!U;
        static if (category == Category.any)
            return this;
        else static if (category == Category.boxed)
            return boxed!U();
        else static if (category == Category.reference || category == Category.collection)
            return reference!T();
        else
            return scalar!U();
    }

    private ref inout(U) boxed(U)() inout return
    {
        auto box = slot_ == Slot.box && typeName_ == typeNameOf!U ? cast(inout(Box!U)) object_ : null;
        if (box is null)
            throw mismatch(typeNameOf!U);
        return box.value;
    }

    private inout(T) reference(T)() inout
    {
        alias U = typeof(cast() T.init);
        static if (categoryOf!U == Category.collection)
        {
            if (slot_ == Slot.empty || (slot_ == Slot.box && object_ is null && typeName_ == typeNameOf!U))
                return cast(inout(T)) null;
            return boxed!U();
        }
        else
        {
            if (slot_ == Slot.empty || (slot_ == Slot.reference && object_ is null))
                return cast(inout(T)) null;
            auto result = slot_ == Slot.reference ? cast(inout(T)) object_ : null;
            if (result is null)
                throw mismatch(typeNameOf!U);
            return result;
        }
    }

    private U scalar(U)() const
    {
        if (!holds!U)
            throw mismatch(typeNameOf!U);
        enum category = categoryOf!U;
        static if (category == Category.text)
            return string_;
        else static if (category == Category.boolean)
            return long_ != 0;
        else static if (category == Category.floating)
        {
            if (slot_ == Slot.floating)
                return cast(U) double_;
            return slot_ == Slot.unsigned ? cast(U) cast(ulong) long_ : cast(U) long_;
        }
        else
            return cast(U) long_;
    }

    /// The box of a held value type, or null; used by descriptor accessors to write through.
    inout(Box!T) box(T)() inout pure nothrow @nogc
    {
        return slot_ == Slot.box ? cast(inout(Box!T)) object_ : null;
    }

    /++
    Equal type names and equal values: bits for scalars, contents for strings, identity for references and boxes
    (which keeps `==` `@safe`; compare references by value with `flint.engine.aot.objects.objectEquals`).
    +/
    bool opEquals(const Any other) const pure nothrow @nogc
    {
        if (slot_ != other.slot_ || typeName_ != other.typeName_)
            return false;
        final switch (slot_)
        {
        case Slot.empty:
            return true;
        case Slot.text:
            return string_ == other.string_;
        case Slot.reference, Slot.box:
            return object_ is other.object_;
        case Slot.floating:
            return double_ == other.double_;
        case Slot.integral, Slot.unsigned, Slot.boolean, Slot.character, Slot.enumeration:
            return long_ == other.long_;
        }
    }

    /// A hash consistent with `opEquals`.
    size_t toHash() const nothrow @safe
    {
        if (slot_ == Slot.text)
            return hashOf(string_);
        if (slot_ == Slot.floating)
            return hashOf(double_);
        if (slot_ == Slot.reference || slot_ == Slot.box)
            return hashOf(typeName_);
        return hashOf(long_) ^ hashOf(typeName_);
    }

    /// A short rendering for diagnostics: the value of scalars and strings, the type name otherwise.
    string toString() const
    {
        import flint.engine.aot.text : decimal;

        switch (slot_)
        {
        case Slot.empty:
            return "null";
        case Slot.text:
            return string_;
        case Slot.reference, Slot.box:
            return object_ is null ? "null" : typeName_;
        case Slot.enumeration:
            return typeName_ ~ "(" ~ decimal(long_) ~ ")";
        default:
            return scalarText();
        }
    }

    private string scalarText() const
    {
        import flint.engine.aot.text : decimal, doubleText, utf8;

        switch (slot_)
        {
        case Slot.boolean:
            return long_ != 0 ? "true" : "false";
        case Slot.floating:
            return doubleText(double_);
        case Slot.unsigned:
            return decimal(cast(ulong) long_);
        case Slot.character:
            // An invalid code point renders as U+FFFD; to!string threw a UTFException.
            const text = utf8(cast(dchar) long_);
            return text is null ? "\uFFFD" : text;
        default:
            return decimal(long_);
        }
    }

    private AnyTypeException mismatch(string requested) const pure nothrow
    {
        return new AnyTypeException(requested, typeName_);
    }

    private bool fits(U)() const pure nothrow @nogc
    {
        if (slot_ == Slot.unsigned)
        {
            static if (is(U == ulong))
                return true;
            else
                return long_ >= 0 && cast(ulong) long_ <= U.max;
        }
        static if (is(U == ulong))
            return long_ >= 0;
        else
            return long_ >= U.min && long_ <= U.max;
    }
}
