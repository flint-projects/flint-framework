module flint.engine.reactor.sys.locals;

@safe:

/// Words a `T` occupies in fiber-local storage, after the one-word stamp of its cell.
package(flint.engine.reactor) enum size_t localWords(T) = (T.sizeof + (void*).sizeof - 1) / (void*).sizeof;

/// Values that a cell copies bit for bit and may abandon without running code: class and interface
/// references, and plain data without postblits, copy constructors or destructors.
private enum bool storableKind(T) = is(T == class) || is(T == interface) || __traits(isPOD, T);

/// ditto
package(flint.engine.reactor) enum bool localStorable(T) = storableKind!T && T.alignof <= (void*).alignof && T
        .sizeof > 0;

/// The stamp of a cell: the task generation that last wrote it, or zero while unset.
// SAFETY: Reads the bounds-checked first word of a cell as an integer; no pointer is formed or retained.
@trusted package(flint.engine.reactor) size_t cellStamp(scope const(void*)[] cell) nothrow @nogc
{
    assert(cell.length != 0);
    return cast(size_t) cell[0];
}

/// Copy `value` into the words after the stamp, then record `stamp`. The cell lies in GC-scanned word
/// storage, so references inside `value` stay visible; `value` is not scope, so it borrows no stack or arena.
// SAFETY: The length check bounds the copy; localStorable excludes types whose copies need code to run.
@trusted package(flint.engine.reactor) void storeCell(T)(scope void*[] cell, size_t stamp, T value) nothrow @nogc
        if (localStorable!T)
{
    assert(cell.length >= 1 + localWords!T);
    auto target = cast(ubyte*)&cell[1];
    auto source = cast(const(ubyte)*)&value;
    target[0 .. T.sizeof] = source[0 .. T.sizeof];
    cell[0] = cast(void*) stamp;
}

/// Copy out the value a matching `storeCell!T` wrote. A FiberLocal!T binds its offset to a single T.
// SAFETY: The caller matched the stamp, so these bounds-checked words hold the T that storeCell!T wrote
// under it; cells another task left behind fail that check and are never read.
@trusted package(flint.engine.reactor) T loadCell(T)(scope const(void*)[] cell) nothrow @nogc
        if (localStorable!T)
{
    assert(cell.length >= 1 + localWords!T);
    T value = void;
    auto target = cast(ubyte*)&value;
    auto source = cast(const(ubyte)*)&cell[1];
    target[0 .. T.sizeof] = source[0 .. T.sizeof];
    return value;
}
