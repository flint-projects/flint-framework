/++
Spring's Objenesis for generated proxies: allocate a class instance without running a constructor.
Private to `flint:engine-aot`; applications never import it.
+/
module flint.engine.aot.sys.allocate;

@safe:

// druntime's allocator behind `new C`: GC memory sized and initialized from the class initializer, with the
// finalizer and no-scan attributes the class needs. It runs no constructor.
private extern (C) Object _d_newclass(const TypeInfo_Class type) nothrow @system;

/++
A new instance of `type` whose fields hold their initial values and whose constructor did not run; null for an
abstract class, a COM class or an `extern(C++)` class.

_d_newclass copies `type.initializer` into a fresh GC block of exactly that length, so every field holds its
declared initial value and the vtable pointer is set; nothing aliases the block. Abstract classes are refused (no
complete vtable), as are COM classes (malloc'd, reference counted) and C++ classes (no ClassInfo for the GC).
+/
// SAFETY: fresh GC block sized and initialized from the class initializer; refused flags exclude incomplete classes.
@trusted Object allocateUninitialized(const TypeInfo_Class type) nothrow
{
    enum refused = TypeInfo_Class.ClassFlags.isAbstract | TypeInfo_Class.ClassFlags.isCOMclass
        | TypeInfo_Class.ClassFlags.isCPPclass;
    if (type is null || (type.m_flags & refused) != 0)
        return null;
    return _d_newclass(type);
}

unittest
{
    static class Counted
    {
        int value = 7;
        string label = "initial";
        static int constructed;

        this()
        {
            constructed++;
            value = 99;
        }
    }

    static abstract class Shape
    {
        abstract int sides();
    }

    auto instance = cast(Counted) allocateUninitialized(typeid(Counted));
    assert(instance !is null && instance.value == 7 && instance.label == "initial");
    assert(Counted.constructed == 0);
    assert(typeid(instance) is typeid(Counted));
    assert(allocateUninitialized(typeid(Shape)) is null);
    assert(allocateUninitialized(null) is null);
}
