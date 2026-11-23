/++
The C library's number conversions behind `flint.engine.aot.text`: `snprintf` for `%g` and `strtod`.
Private to `flint:engine-aot`; applications never import it.
+/
module flint.engine.aot.sys.text;

@safe:

private extern (C) int snprintf(char* buffer, size_t size, scope const char* format, ...) nothrow @nogc @system;
private extern (C) double strtod(scope const char* text, char** end) nothrow @nogc @system;

/++
`value` printed with C's `%g` into `buffer`; the number of characters written, or 0 if `buffer` is too small.

snprintf writes at most `buffer.length` bytes including the terminating NUL into `buffer`, which the caller owns
for the call only; the format is a literal with one double conversion, matching the one vararg passed.
+/
// SAFETY: bounded by buffer.length, NUL included; literal format with exactly one double argument.
@trusted size_t formatG(double value, scope char[] buffer) nothrow @nogc
{
    if (buffer.length == 0)
        return 0;
    const written = snprintf(&buffer[0], buffer.length, "%g", value);
    return written > 0 && written < buffer.length ? cast(size_t) written : 0;
}

/++
The double C's `strtod` reads from `text`, which must end in a NUL the caller added; `consumed` is the number of
characters strtod used, so a caller can require that it read everything before the NUL.

strtod only reads up to the NUL the precondition guarantees; `end` points into `text`, and only its distance from
the start is returned.
+/
// SAFETY: text is NUL-terminated (checked); strtod reads within it and end stays inside it.
@trusted double readDouble(scope const(char)[] text, out size_t consumed) nothrow @nogc
{
    if (text.length == 0 || text[$ - 1] != '\0')
        return double.nan;
    char* end;
    const value = strtod(&text[0], &end);
    consumed = cast(size_t)(end - &text[0]);
    return value;
}

unittest
{
    char[32] buffer;
    assert(buffer[0 .. formatG(1.5, buffer[])] == "1.5");
    // Negative: no room, or not enough for the text and its NUL, writes nothing usable.
    assert(formatG(1.5, buffer[0 .. 0]) == 0);
    assert(formatG(123_456.0, buffer[0 .. 4]) == 0);
}

unittest
{
    size_t consumed;
    assert(readDouble("2.5\0", consumed) == 2.5 && consumed == 3);
    assert(readDouble("7x\0", consumed) == 7 && consumed == 1);
    // Negative: text without its NUL, or empty, is refused before strtod sees it.
    import std.math : isNaN;

    assert(readDouble("2.5", consumed).isNaN && consumed == 0);
    assert(readDouble("", consumed).isNaN && consumed == 0);
}
