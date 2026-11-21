module flint.wasm_bridge.sys.borrow;

@safe:
nothrow:
@nogc:

package(flint.wasm_bridge) alias BatchVisitor = void delegate(scope const(ubyte)[]) @safe nothrow @nogc;

private struct Visit
{
    const(ubyte)* start;
    const(Visit)* previous;
}

version (WebAssembly)
    private __gshared const(Visit)* current;
else
    private const(Visit)* current;

// SAFETY: The caller keeps storage alive. Stack entries exist only during synchronous visits on this thread.
package(flint.wasm_bridge) bool borrowed(scope const(ubyte)[] storage) @trusted nothrow @nogc
{
    for (auto visit = current; visit !is null; visit = visit.previous)
        if (visit.start is storage.ptr)
            return true;
    return false;
}

// SAFETY: The scoped visitor cannot retain the slice. The current entry points to this stack frame until
// the visitor returns and scope(exit) restores the previous thread-local entry. WASM ABI v1 is single-threaded.
package(flint.wasm_bridge) @trusted nothrow @nogc void withBatch(scope const(ubyte)[] bytes, scope BatchVisitor read)
{
    const visit = Visit(bytes.ptr, current);
    current = &visit;
    scope (exit)
        current = visit.previous;
    read(bytes);
}

package(flint.wasm_bridge) void invalidMove()
{
    version (WebAssembly)
    {
        import ldc.intrinsics : llvm_trap;

        llvm_trap();
    }
    else
    {
        import core.stdc.stdlib : abort;

        abort();
    }
}
