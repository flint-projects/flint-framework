/++
Java's `Object` methods for references whose static type is only `Object`: `equals`, `hashCode`, `toString`.

druntime declares `Object.opEquals`, `toHash` and `toString` without attributes, so `@safe` code cannot call
them through an `Object` reference, although the base implementations are safe and every override in a Flint or
application module is compiled under module-scope `@safe:` (the structural gate and `flint check` require it).
These three wrappers are the only bridge; the API layer (`flint.java.util` collections, `Objects.equals`,
`String.valueOf`) calls them instead of `==` and `toString` on arbitrary class types. Private to
`flint:engine-aot`'s callers through `flint.engine.aot.objects`.
+/
module flint.engine.aot.sys.objects;

@safe:

/// Java's `a.equals(b)` with `Objects.equals`' null handling, symmetric across classes.
@trusted bool objectEquals(Object a, Object b) // SAFETY: druntime's base is identity; overrides compile @safe.
{
    if (a is b)
        return true;
    if (a is null || b is null)
        return false;
    return a.opEquals(b) && (typeid(a) is typeid(b) || b.opEquals(a));
}

/// Java's `o.hashCode()`, 0 for null.
@trusted size_t objectToHash(Object o) nothrow  // SAFETY: druntime's base hashes the address; overrides compile @safe.
{
    return o is null ? 0 : o.toHash();
}

/// Java's `String.valueOf(o)`: `"null"` for null, else `o.toString()`.
@trusted string objectToString(Object o) // SAFETY: druntime's base returns the class name; overrides compile @safe.
{
    return o is null ? "null" : o.toString();
}

unittest
{
    static final class Named
    {
        string name;

        this(string name)
        {
            this.name = name;
        }

        override bool opEquals(const Object other) const
        {
            auto that = cast(const Named) other;
            return that !is null && that.name == name;
        }

        override size_t toHash() const nothrow
        {
            return name.length;
        }

        override string toString() const
        {
            return "Named(" ~ name ~ ")";
        }
    }

    Object x = new Named("x"), same = new Named("x"), other = new Named("y"), plain = new Object;
    assert(objectEquals(x, same) && !objectEquals(x, other));
    assert(objectEquals(null, null) && !objectEquals(x, null) && !objectEquals(null, x));
    assert(objectEquals(plain, plain) && !objectEquals(plain, new Object));
    assert(objectToHash(x) == 1 && objectToHash(null) == 0);
    assert(objectToString(x) == "Named(x)" && objectToString(null) == "null");
    assert(objectToString(plain) == "object.Object");
}
