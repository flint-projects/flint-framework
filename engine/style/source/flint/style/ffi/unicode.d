module flint.style.ffi.unicode;

@safe:

private extern (C) @system nothrow @nogc
{
    uint flint_scalar_properties(uint scalar);
    int flint_grapheme_break(uint previous, uint current, int* state);
    const(char)* flint_unicode_version();
}

package(flint.style) enum uint widthMask = 3;
package(flint.style) enum uint mark = 4;
package(flint.style) enum uint pictograph = 8;

// SAFETY: The pinned shim reads the property table for a decoded scalar and returns only bit flags.
package(flint.style) uint properties(dchar scalar) @trusted nothrow @nogc
{
    return flint_scalar_properties(scalar);
}

// SAFETY: The provider reads and updates one live per-cluster state word synchronously.
package(flint.style) bool breakBetween(dchar previous, dchar current, ref int state) @trusted nothrow @nogc
{
    return flint_grapheme_break(previous, current, &state) != 0;
}

// SAFETY: utf8proc exposes a linked static NUL-terminated version string. Copy it into D-owned storage.
package(flint.style) string unicodeVersion() @trusted nothrow
{
    const raw = flint_unicode_version();
    size_t length;
    while (raw[length] != '\0')
        ++length;
    return raw[0 .. length].idup;
}
