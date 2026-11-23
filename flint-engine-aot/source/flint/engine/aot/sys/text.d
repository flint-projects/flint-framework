/++
The C library's number conversions behind `flint.engine.aot.text`: `snprintf` for `%g` and `strtod`.
Private to `flint:engine-aot`; applications never import it.
+/
module flint.engine.aot.sys.text;

@safe:

// Declared pure, as druntime declares its C math: they touch only errno, and Flint never calls setlocale, so the
// "C" locale they read never changes. std.conv's own conversions are pure, and these replace them.
private extern (C) int snprintf(char* buffer, size_t size, scope const char* format, ...) pure nothrow @nogc @system;
private extern (C) double strtod(scope const char* text, char** end) pure nothrow @nogc @system;
private extern (C) float strtof(scope const char* text, char** end) pure nothrow @nogc @system;

/++
`value` printed with C's `%g` into `buffer`; the number of characters written, or 0 if `buffer` is too small.

snprintf writes at most `buffer.length` bytes including the terminating NUL into `buffer`, which the caller owns
for the call only; the format is a literal with one double conversion, matching the one vararg passed.
+/
// SAFETY: bounded by buffer.length, NUL included; literal format with exactly one double argument.
@trusted size_t formatG(double value, scope char[] buffer) pure nothrow @nogc
{
    if (buffer.length == 0)
        return 0;
    const written = snprintf(&buffer[0], buffer.length, "%g", value);
    return written > 0 && written < buffer.length ? cast(size_t) written : 0;
}

/++
`value` printed with C's `%.*e` and `precision` digits after the point into `buffer`; the number of characters
written, or 0 if `buffer` is too small or `precision` is outside [0, 40].

As `formatG`: snprintf writes at most `buffer.length` bytes including the NUL into `buffer`; the format is a literal
with one int and one double conversion, matching the two varargs passed.
+/
// SAFETY: bounded by buffer.length, NUL included; literal format with exactly an int and a double argument.
@trusted size_t formatE(double value, int precision, scope char[] buffer) pure nothrow @nogc
{
    if (buffer.length == 0 || precision < 0 || precision > 40)
        return 0;
    const written = snprintf(&buffer[0], buffer.length, "%.*e", precision, value);
    return written > 0 && written < buffer.length ? cast(size_t) written : 0;
}

/++
The float C's `strtof` reads from `text`, which must end in a NUL the caller added; `consumed` as for `readDouble`.

As `readDouble`: strtof only reads up to the NUL the precondition guarantees, and only `end`'s distance from the
start is returned.
+/
// SAFETY: text is NUL-terminated (checked); strtof reads within it and end stays inside it.
@trusted float readFloat(scope const(char)[] text, out size_t consumed) pure nothrow @nogc
{
    if (text.length == 0 || text[$ - 1] != '\0')
        return float.nan;
    char* end;
    const value = strtof(&text[0], &end);
    consumed = cast(size_t)(end - &text[0]);
    return value;
}

/++
The double C's `strtod` reads from `text`, which must end in a NUL the caller added; `consumed` is the number of
characters strtod used, so a caller can require that it read everything before the NUL.

strtod only reads up to the NUL the precondition guarantees; `end` points into `text`, and only its distance from
the start is returned.
+/
// SAFETY: text is NUL-terminated (checked); strtod reads within it and end stays inside it.
@trusted double readDouble(scope const(char)[] text, out size_t consumed) pure nothrow @nogc
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

unittest
{
    char[48] buffer;
    assert(buffer[0 .. formatE(1.5, 3, buffer[])] == "1.500e+00");
    // Negative: no room, too little room, or a precision outside the bounded range writes nothing.
    assert(formatE(1.5, 3, buffer[0 .. 0]) == 0 && formatE(1.5, 3, buffer[0 .. 4]) == 0);
    assert(formatE(1.5, -1, buffer[]) == 0 && formatE(1.5, 41, buffer[]) == 0);
}

unittest
{
    import std.math : isNaN;

    size_t consumed;
    assert(readFloat("0.1\0", consumed) == 0.1f && consumed == 3);
    // Negative: text without its NUL is refused before strtof sees it.
    assert(readFloat("0.1", consumed).isNaN && consumed == 0);
}
