module flint.style.ffi.unicode;

import core.stdc.stdlib : free;

@safe:

private extern (C) @system nothrow @nogc
{
    uint flint_scalar_properties(uint scalar);
    int flint_grapheme_break(uint previous, uint current, int* state);
    const(char)* flint_unicode_version();
    ptrdiff_t utf8proc_map(const(ubyte)* text, ptrdiff_t length, ubyte** destination, uint options);
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

// SAFETY: utf8proc receives the checked borrowed range synchronously. The provider owns the
// returned malloc-compatible buffer until its contents are copied and the buffer is freed.
@trusted package(flint.style) bool caseFold(scope const(char)[] text, out string folded)
{
    if (text.length == 0)
        return true;
    if (text.length > ptrdiff_t.max)
        return false;
    ubyte* output;
    enum stableComposeFold = (1U << 1) | (1U << 3) | (1U << 10);
    const size = utf8proc_map(cast(const(ubyte)*) text.ptr, cast(ptrdiff_t) text.length, &output, stableComposeFold);
    scope (exit)
        free(output);
    if (size < 0 || output is null)
        return false;
    folded = (cast(const(char)*) output)[0 .. size].idup;
    return true;
}
