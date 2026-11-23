// Ported from spring-framework v7.1.0: spring-core/src/main/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/*
 * Copyright 2002-present the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by the Flint authors: ported from spring-framework v7.1.0, spring-core/src/main/java/org/springframework/util.
 */

/++
`org.springframework.util`: miscellaneous utility classes.

Phase 1 ports `Assert`, `StringUtils`, `ObjectUtils`, `CollectionUtils`, `PatternMatchUtils`, `NumberUtils`,
`MultiValueMap` with `MultiValueMapAdapter` and `LinkedMultiValueMap`, `StringValueResolver`, `PathMatcher` with
`AntPathMatcher`, and `PropertyPlaceholderHelper` with its `PlaceholderParser` and `PlaceholderResolutionException`.

$(UL
    $(LI Strings (rulebook R14): D strings are UTF-8, Java strings UTF-16. Every routine here walks code points, so
        non-ASCII input is never split inside a character. Where an index or a length crosses the API
        (`StringUtils.substringMatch`, `StringUtils.truncate`) it is in UTF-16 code units, as in Java; internal
        offsets are UTF-8 bytes (deviation D-14).)
    $(LI `Class<T>` parameters are template parameters (R4): `Assert.isInstanceOf!T(obj)`,
        `NumberUtils.parseNumber!int(text)`, `CollectionUtils.findValueOfType!T(collection)`.)
    $(LI `Object`-typed parameters are templates over the argument type; arrays are D arrays, and an empty but
        non-null array is distinct from a null one, as in Java.)
    $(LI `AntPathMatcher` matches `{name:regex}` variables with a small backtracking engine (no `std.regex` in core):
        literals, `.`, classes with ranges, `\d \w \s \p{L} \p{N} \p{Lu} \p{Ll}` and their negations, groups,
        alternation and greedy or lazy quantifiers. Other regular-expression syntax raises
        `IllegalArgumentException` when the pattern is compiled.)
)
+/
module flint.util;

import flint.engine.aot.any : Any;
import flint.engine.aot.objects : objectEquals, objectToString;
import flint.java.lang : IllegalArgumentException, IllegalStateException, IndexOutOfBoundsException,
    NumberFormatException, RuntimeException, UnsupportedOperationException, javaHashCode, valueOf;
import flint.java.nio.charset : Charset, UnsupportedCharsetException;
import flint.java.util : ArrayList, Arrays, Collection, Collections, Comparator, HashMap, HashSet,
    Iterator, LinkedHashMap, LinkedHashSet, List, Map, MapEntry, Optional, RawCollection, RawMap, Set, stableSort;
import flint.java.util.function_ : Supplier;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Text helpers (rulebook R14)

/// Java's `Character.isWhitespace` for a code point.
private bool isJavaWhitespace(dchar c) pure nothrow @nogc
{
    switch (c)
    {
    case '\t', '\n', '\v', '\f', '\r', 0x1C, 0x1D, 0x1E, 0x1F, ' ', 0x1680, 0x2028, 0x2029,
            0x205F, 0x3000:
            return true;
    default:
        return c >= 0x2000 && c <= 0x200A && c != 0x2007;
    }
}

/// Decode the code point at `index` and advance past it; malformed UTF-8 decodes as U+FFFD.
private dchar decodeAt(scope const(char)[] s, ref size_t index) pure nothrow @nogc
{
    import flint.engine.aot.text : decodeUtf8;

    return decodeUtf8(s, index);
}

/// Advance `index` past the code point at `index`.
private void skipCodePoint(scope const(char)[] s, ref size_t index) pure nothrow @nogc
{
    cast(void) decodeAt(s, index);
}

/// The byte length of the code point that ends at `index`.
private size_t strideBefore(scope const(char)[] s, size_t index) pure nothrow @nogc
{
    size_t width = 1;
    while (width < index && width < 4 && (s[index - width] & 0xC0) == 0x80)
        width++;
    return width;
}

/// The code point that ends at byte `index` (`index > 0`).
private dchar codePointBefore(scope const(char)[] s, size_t index) pure nothrow @nogc
{
    size_t start = index - strideBefore(s, index);
    return decodeAt(s, start);
}

/// The length of `s` in UTF-16 code units, Java's `String.length()`.
private size_t utf16Length(scope const(char)[] s) pure nothrow @nogc
{
    size_t units;
    foreach (b; s)
        if ((b & 0xC0) != 0x80)
            units += b >= 0xF0 ? 2 : 1;
    return units;
}

/// The byte offset of UTF-16 index `index` in `s`, or -1 when it is past the end or inside a surrogate pair.
private ptrdiff_t utf16ToByteOffset(scope const(char)[] s, size_t index) pure nothrow @nogc
{
    size_t units, i;
    while (i < s.length && units < index)
    {
        const c = decodeAt(s, i);
        units += c >= 0x10000 ? 2 : 1;
    }
    return units == index ? cast(ptrdiff_t) i : -1;
}

/// The number of code points in `s`.
private size_t codePointCount(scope const(char)[] s) pure nothrow @nogc
{
    size_t count;
    foreach (b; s)
        if ((b & 0xC0) != 0x80)
            count++;
    return count;
}

/// Java's `regionMatches(true, ...)` comparison of two characters.
private bool charsEqualIgnoreCase(dchar a, dchar b) pure nothrow @nogc
{
    import std.uni : toLower, toUpper;

    if (a == b)
        return true;
    const ua = toUpper(a);
    const ub = toUpper(b);
    return ua == ub || toLower(ua) == toLower(ub);
}

/// The end offset in `s` when `other` matches at byte `start` ignoring case, else -1.
private ptrdiff_t matchIgnoreCaseAt(scope const(char)[] s, size_t start, scope const(char)[] other) pure nothrow @nogc
{
    size_t i = start;
    size_t j;
    while (j < other.length)
    {
        if (i >= s.length)
            return -1;
        if (!charsEqualIgnoreCase(decodeAt(s, i), decodeAt(other, j)))
            return -1;
    }
    return cast(ptrdiff_t) i;
}

/// Java's `String.equalsIgnoreCase`. ASCII text (media types, header names) is compared byte by byte; only
/// non-ASCII text takes the decoding path, whose case folding can match strings of different byte lengths.
private bool equalsIgnoreCase(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    if (a == b)
        return true;
    if (a.length == b.length)
    {
        bool ascii = true;
        foreach (i, x; a)
        {
            const y = b[i];
            if ((x | y) >= 0x80)
            {
                ascii = false;
                break;
            }
            if (x != y && asciiLower(x) != asciiLower(y))
                return false; // both ASCII here, and every earlier byte was ASCII: the characters differ
        }
        if (ascii)
            return true;
    }
    else if (isAscii(a) && isAscii(b))
        return false;
    return matchIgnoreCaseAt(a, 0, b) == a.length;
}

private char asciiLower(char c) pure nothrow @nogc
{
    return c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
}

private bool isAscii(scope const(char)[] s) pure nothrow @nogc
{
    foreach (c; s)
        if (c >= 0x80)
            return false;
    return true;
}

unittest
{
    assert(equalsIgnoreCase("application/JSON", "Application/json") && !equalsIgnoreCase("text/html", "text/htm"));
    assert(!equalsIgnoreCase("a-b", "a_b") && !equalsIgnoreCase("ab", "abc") && equalsIgnoreCase("", ""));
    assert(equalsIgnoreCase("ſ", "s") && equalsIgnoreCase("ÉTÉ", "été") && !equalsIgnoreCase("é", "e")); // Unicode path
}

/// Whether `s` starts with `prefix`.
private bool hasPrefix(scope const(char)[] s, scope const(char)[] prefix) pure nothrow @nogc
{
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}

/// Whether `s` ends with `suffix`.
private bool hasSuffix(scope const(char)[] s, scope const(char)[] suffix) pure nothrow @nogc
{
    return s.length >= suffix.length && s[$ - suffix.length .. $] == suffix;
}

/// Whether `sub` occurs in `s` at byte `index`.
private bool substringMatchAt(scope const(char)[] s, size_t index, scope const(char)[] sub) pure nothrow @nogc
{
    return index <= s.length && sub.length <= s.length - index && s[index .. index + sub.length] == sub;
}

/// The byte index of `sub` in `s` at or after `from`, or -1 (Java's `indexOf(String, int)`).
private ptrdiff_t indexOfFrom(scope const(char)[] s, scope const(char)[] sub, size_t from) pure nothrow @nogc
{
    if (from > s.length)
        return -1;
    for (size_t i = from; i + sub.length <= s.length; i++)
        if (s[i .. i + sub.length] == sub)
            return cast(ptrdiff_t) i;
    return -1;
}

/// The byte index of `sub` in `s`, or -1.
private ptrdiff_t indexOfString(scope const(char)[] s, scope const(char)[] sub) pure nothrow @nogc
{
    return indexOfFrom(s, sub, 0);
}

/// The byte index of the ASCII character `c` in `s`, or -1.
private ptrdiff_t indexOfChar(scope const(char)[] s, char c) pure nothrow @nogc
{
    foreach (i, b; s)
        if (b == c)
            return cast(ptrdiff_t) i;
    return -1;
}

/// The byte index of the last ASCII character `c` in `s`, or -1.
private ptrdiff_t lastIndexOfChar(scope const(char)[] s, char c) pure nothrow @nogc
{
    for (size_t i = s.length; i > 0; i--)
        if (s[i - 1] == c)
            return cast(ptrdiff_t)(i - 1);
    return -1;
}

/// The byte index of the last occurrence of code point `c` in `s`, or -1.
private ptrdiff_t lastIndexOfCodePoint(scope const(char)[] s, dchar c) pure nothrow @nogc
{
    ptrdiff_t found = -1;
    size_t i;
    while (i < s.length)
    {
        const start = i;
        if (decodeAt(s, i) == c)
            found = cast(ptrdiff_t) start;
    }
    return found;
}

/// Whether code point `c` occurs in `s`.
private bool containsCodePoint(scope const(char)[] s, dchar c) pure nothrow @nogc
{
    size_t i;
    while (i < s.length)
        if (decodeAt(s, i) == c)
            return true;
    return false;
}

/// The UTF-8 encoding of `c`.
private string encodeCodePoint(dchar c) pure nothrow
{
    import flint.engine.aot.text : utf8;

    const text = utf8(c);
    return text is null ? "\uFFFD" : text; // as std.utf's replacement encode
}

/// Java's `String.trim()`: strip characters up to U+0020 at both ends.
private string javaTrim(string s) pure nothrow @nogc
{
    size_t start;
    size_t end = s.length;
    while (start < end && s[start] <= ' ')
        start++;
    while (end > start && s[end - 1] <= ' ')
        end--;
    return s[start .. end];
}

/// Java's `String.compareTo` order (UTF-16 code units) for sorting.
private int compareUtf16(string a, string b) pure nothrow @nogc
{
    size_t i, j;
    while (i < a.length && j < b.length)
    {
        const ca = decodeAt(a, i);
        const cb = decodeAt(b, j);
        if (ca != cb)
            return firstUtf16Unit(ca) != firstUtf16Unit(cb) ? (firstUtf16Unit(ca) < firstUtf16Unit(cb) ? -1 : 1) : (
                    ca < cb ? -1 : 1);
    }
    if (i < a.length)
        return 1;
    return j < b.length ? -1 : 0;
}

/// The first UTF-16 code unit of `c`.
private uint firstUtf16Unit(dchar c) pure nothrow @nogc
{
    return c >= 0x10000 ? 0xD800 + ((c - 0x10000) >> 10) : c;
}

/// Lower-case hexadecimal of `value`, without leading zeros (Java's `Integer.toHexString`).
private string hexString(uint value) pure nothrow
{
    enum digits = "0123456789abcdef";
    if (value == 0)
        return "0";
    char[8] buffer;
    size_t position = buffer.length;
    while (value)
    {
        buffer[--position] = digits[value & 0xF];
        value >>= 4;
    }
    return buffer[position .. $].idup;
}

/// Java's `Double.toString` (and `Float.toString` when `single`): the shortest decimal that round-trips, in plain
/// notation for magnitudes in [1e-3, 1e7) and computerized scientific notation otherwise.
private string javaFloatingText(double value, bool single)
{
    import flint.engine.aot.text : scientific, tryParseDouble, tryParseFloat;

    if (value != value)
        return "NaN";
    if (value == double.infinity)
        return "Infinity";
    if (value == -double.infinity)
        return "-Infinity";
    if (value == 0)
        return 1 / value < 0 ? "-0.0" : "0.0";
    string text;
    foreach (precision; 0 .. single ? 9 : 17)
    {
        text = scientific(value, precision);
        if (single ? tryParseFloat(text).value == cast(float) value : tryParseDouble(text).value == value)
            break;
    }
    return javaFloatingLayout(text);
}

/// Lay out `d.ddde+XX` as Java's `Double.toString` does.
private string javaFloatingLayout(string scientific)
{
    import flint.engine.aot.text : decimal, tryParseInt;

    const negative = scientific[0] == '-';
    const 
    body = negative ? scientific[1 .. $] : scientific;
    const e = indexOfChar(body, 'e');
    const exponent = cast(int) tryParseInt(body[e + 1 .. $]).value;
    string digits;
    foreach (c; body[0 .. e])
        if (c != '.')
            digits ~= c;
    while (digits.length > 1 && digits[$ - 1] == '0')
        digits = digits[0 .. $ - 1];
    return (negative ? "-" : "") ~ (exponent >= -3 && exponent < 7 ? plainLayout(digits,
            exponent) : digits[0 .. 1] ~ "." ~ (digits.length > 1 ? digits[1 .. $] : "0") ~ "E" ~ decimal(
            cast(long) exponent));
}

/// `digits` with the decimal point after `exponent + 1` digits.
private string plainLayout(string digits, int exponent) pure nothrow
{
    if (exponent < 0)
    {
        string zeros;
        foreach (_; 0 .. -exponent - 1)
            zeros ~= '0';
        return "0." ~ zeros ~ digits;
    }
    string whole = digits;
    while (whole.length < exponent + 1)
        whole ~= '0';
    const fraction = whole[exponent + 1 .. $];
    return whole[0 .. exponent + 1] ~ "." ~ (fraction.length ? fraction : "0");
}

/// `T`'s Java class name for messages: Java's boxed name for scalars and strings, else the D name.
private template javaTypeName(T)
{
    import std.traits : Unqual;

    alias U = Unqual!T;
    static if (is(U == byte))
        enum javaTypeName = "java.lang.Byte";
    else static if (is(U == short))
        enum javaTypeName = "java.lang.Short";
    else static if (is(U == int))
        enum javaTypeName = "java.lang.Integer";
    else static if (is(U == long))
        enum javaTypeName = "java.lang.Long";
    else static if (is(U == float))
        enum javaTypeName = "java.lang.Float";
    else static if (is(U == double))
        enum javaTypeName = "java.lang.Double";
    else static if (is(U == bool))
        enum javaTypeName = "java.lang.Boolean";
    else static if (is(U == char) || is(U == wchar) || is(U == dchar))
        enum javaTypeName = "java.lang.Character";
    else static if (is(U == string))
        enum javaTypeName = "java.lang.String";
    else static if (__traits(compiles, __traits(fullyQualifiedName, U)))
        enum javaTypeName = __traits(fullyQualifiedName, U);
    else
        enum javaTypeName = U.stringof;
}

/// Java's `Class.toString()` for `T`: `interface` or `class`, then the name.
private template javaClassText(T)
{
    static if (is(T == interface))
        enum javaClassText = "interface " ~ javaTypeName!T;
    else
        enum javaClassText = "class " ~ javaTypeName!T;
}

/// Whether `T` is Java's `String`: an immutable or const character slice.
private enum isJavaString(T) = is(T == string) || is(T == const(char)[]);

/// Whether `T` is an array in Java's sense: a D array that is not a string.
private enum isJavaArray(T) = is(T == E[], E) && !isJavaString!T && !is(T == typeof(null));

/// Whether `T` is a `flint.java.util.Optional`.
private enum isOptional(T) = is(T == Optional!U, U);

/// Whether a value of `T` can be null.
private enum isNullable(T) = is(T == typeof(null)) || is(T == class) || is(T == interface)
    || is(T == E[], E) || is(T == U*, U) || is(T == delegate) || is(T == function) || is(T == V[K], V, K);

/// Whether `value` is null (always false for value types).
private bool isNullValue(T)(T value)
{
    static if (is(T == typeof(null)))
        return true;
    else static if (isNullable!T)
        return value is null;
    else
        return false;
}

/// The runtime class name of `obj` for messages: `"null"`, the dynamic class, or `javaTypeName`.
private string runtimeClassName(T)(T obj)
{
    static if (is(T == typeof(null)))
        return "null";
    else static if (is(T == class) || is(T == interface))
        return obj is null ? "null" : typeid(cast(Object) obj).name;
    else
        return isNullValue(obj) ? "null" : javaTypeName!T;
}

// ---------------------------------------------------------------------------------------------------------------
// Assert

/++
Assertion utility class that assists in validating arguments: `IllegalArgumentException` for arguments,
`IllegalStateException` for `state`. Each check takes its message as a string, as a `string delegate() @safe`
(R9) or as a `Supplier!string`; a null supplier gives a null message.
+/
abstract class Assert
{
    /// Assert a boolean expression, throwing `IllegalStateException` with `message` if it is false.
    static void state(bool expression, string message)
    {
        if (!expression)
            throw new IllegalStateException(message);
    }

    /// ditto
    static void state(bool expression, string delegate() @safe messageSupplier)
    {
        if (!expression)
            throw new IllegalStateException(nullSafeGet(messageSupplier));
    }

    /// ditto
    static void state(bool expression, Supplier!string messageSupplier)
    {
        if (!expression)
            throw new IllegalStateException(nullSafeGet(messageSupplier));
    }

    /// Assert a boolean expression, throwing `IllegalArgumentException` with `message` if it is false.
    static void isTrue(bool expression, string message)
    {
        if (!expression)
            throw new IllegalArgumentException(message);
    }

    /// ditto
    static void isTrue(bool expression, string delegate() @safe messageSupplier)
    {
        if (!expression)
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// ditto
    static void isTrue(bool expression, Supplier!string messageSupplier)
    {
        if (!expression)
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// Assert that `object` is null.
    static void isNull(T)(T object, string message)
    {
        if (!isNullValue(object))
            throw new IllegalArgumentException(message);
    }

    /// ditto
    static void isNull(T)(T object, string delegate() @safe messageSupplier)
    {
        if (!isNullValue(object))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// ditto
    static void isNull(T)(T object, Supplier!string messageSupplier)
    {
        if (!isNullValue(object))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// Assert that `object` is not null.
    static void notNull(T)(T object, string message)
    {
        if (isNullValue(object))
            throw new IllegalArgumentException(message);
    }

    /// ditto
    static void notNull(T)(T object, string delegate() @safe messageSupplier)
    {
        if (isNullValue(object))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// ditto
    static void notNull(T)(T object, Supplier!string messageSupplier)
    {
        if (isNullValue(object))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// Assert that `text` is not empty; it may be whitespace only.
    static void hasLength(string text, string message)
    {
        if (!StringUtils.hasLength(text))
            throw new IllegalArgumentException(message);
    }

    /// ditto
    static void hasLength(string text, string delegate() @safe messageSupplier)
    {
        if (!StringUtils.hasLength(text))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// ditto
    static void hasLength(string text, Supplier!string messageSupplier)
    {
        if (!StringUtils.hasLength(text))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// Assert that `text` contains a non-whitespace character.
    static void hasText(string text, string message)
    {
        if (!StringUtils.hasText(text))
            throw new IllegalArgumentException(message);
    }

    /// ditto
    static void hasText(string text, string delegate() @safe messageSupplier)
    {
        if (!StringUtils.hasText(text))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// ditto
    static void hasText(string text, Supplier!string messageSupplier)
    {
        if (!StringUtils.hasText(text))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// Assert that `textToSearch` does not contain `substring`.
    static void doesNotContain(string textToSearch, string substring, string message)
    {
        if (contains(textToSearch, substring))
            throw new IllegalArgumentException(message);
    }

    /// ditto
    static void doesNotContain(string textToSearch, string substring, string delegate() @safe messageSupplier)
    {
        if (contains(textToSearch, substring))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// ditto
    static void doesNotContain(string textToSearch, string substring, Supplier!string messageSupplier)
    {
        if (contains(textToSearch, substring))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// Assert that `array` contains elements: it is neither null nor empty.
    static void notEmpty(T)(T[] array, string message)
    {
        if (array.length == 0)
            throw new IllegalArgumentException(message);
    }

    /// ditto
    static void notEmpty(T)(T[] array, string delegate() @safe messageSupplier)
    {
        if (array.length == 0)
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// ditto
    static void notEmpty(T)(T[] array, Supplier!string messageSupplier)
    {
        if (array.length == 0)
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// Assert that `array` contains no null elements; a null or empty array passes.
    static void noNullElements(T)(T[] array, string message)
    {
        if (hasNullElement(array))
            throw new IllegalArgumentException(message);
    }

    /// ditto
    static void noNullElements(T)(T[] array, string delegate() @safe messageSupplier)
    {
        if (hasNullElement(array))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// ditto
    static void noNullElements(T)(T[] array, Supplier!string messageSupplier)
    {
        if (hasNullElement(array))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// Assert that `collection` contains elements: it is neither null nor empty.
    static void notEmpty(T)(Collection!T collection, string message)
    {
        if (CollectionUtils.isEmpty(collection))
            throw new IllegalArgumentException(message);
    }

    /// ditto
    static void notEmpty(T)(Collection!T collection, string delegate() @safe messageSupplier)
    {
        if (CollectionUtils.isEmpty(collection))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// ditto
    static void notEmpty(T)(Collection!T collection, Supplier!string messageSupplier)
    {
        if (CollectionUtils.isEmpty(collection))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// Assert that `collection` contains no null elements; a null or empty collection passes.
    static void noNullElements(T)(Collection!T collection, string message)
    {
        if (collection !is null && hasNullElement(collection.toArray()))
            throw new IllegalArgumentException(message);
    }

    /// ditto
    static void noNullElements(T)(Collection!T collection, string delegate() @safe messageSupplier)
    {
        if (collection !is null && hasNullElement(collection.toArray()))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// ditto
    static void noNullElements(T)(Collection!T collection, Supplier!string messageSupplier)
    {
        if (collection !is null && hasNullElement(collection.toArray()))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// Assert that `map` contains entries: it is neither null nor empty.
    static void notEmpty(K, V)(Map!(K, V) map, string message)
    {
        if (CollectionUtils.isEmpty(map))
            throw new IllegalArgumentException(message);
    }

    /// ditto
    static void notEmpty(K, V)(Map!(K, V) map, string delegate() @safe messageSupplier)
    {
        if (CollectionUtils.isEmpty(map))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /// ditto
    static void notEmpty(K, V)(Map!(K, V) map, Supplier!string messageSupplier)
    {
        if (CollectionUtils.isEmpty(map))
            throw new IllegalArgumentException(nullSafeGet(messageSupplier));
    }

    /++
    Assert that `obj` is an instance of `T` (R4: Java's `Class<?> type` parameter). A message ending in `:`, `;`,
    `,` or `.` is followed by the default message; any other message is followed by the offending class name.
    +/
    static void isInstanceOf(T, O)(O obj, string message)
    {
        if (!instanceOf!T(obj))
            instanceCheckFailed(javaClassText!T, runtimeClassName(obj), message);
    }

    /// ditto
    static void isInstanceOf(T, O)(O obj, string delegate() @safe messageSupplier)
    {
        if (!instanceOf!T(obj))
            instanceCheckFailed(javaClassText!T, runtimeClassName(obj), nullSafeGet(messageSupplier));
    }

    /// ditto
    static void isInstanceOf(T, O)(O obj, Supplier!string messageSupplier)
    {
        if (!instanceOf!T(obj))
            instanceCheckFailed(javaClassText!T, runtimeClassName(obj), nullSafeGet(messageSupplier));
    }

    /// ditto
    static void isInstanceOf(T, O)(O obj)
    {
        isInstanceOf!T(obj, "");
    }

    /// Assert that `Sub` is assignable to `Super` (R4: Java's two `Class` parameters).
    static void isAssignable(Super, Sub)(string message)
    {
        static if (!is(Sub : Super))
            assignableCheckFailed(javaClassText!Super, javaClassText!Sub, message);
    }

    /// ditto
    static void isAssignable(Super, Sub)(string delegate() @safe messageSupplier)
    {
        static if (!is(Sub : Super))
            assignableCheckFailed(javaClassText!Super, javaClassText!Sub, nullSafeGet(messageSupplier));
    }

    /// ditto
    static void isAssignable(Super, Sub)(Supplier!string messageSupplier)
    {
        static if (!is(Sub : Super))
            assignableCheckFailed(javaClassText!Super, javaClassText!Sub, nullSafeGet(messageSupplier));
    }

    /// ditto
    static void isAssignable(Super, Sub)()
    {
        isAssignable!(Super, Sub)("");
    }

    private static bool contains(string textToSearch, string substring)
    {
        return StringUtils.hasLength(textToSearch) && StringUtils.hasLength(substring)
            && indexOfString(textToSearch, substring) >= 0;
    }

    private static bool hasNullElement(T)(T[] array)
    {
        foreach (element; array)
            if (isNullValue(element))
                return true;
        return false;
    }

    private static bool instanceOf(T, O)(O obj)
    {
        static if ((is(T == class) || is(T == interface)) && (is(O == class) || is(O == interface)))
            return cast(T) obj !is null;
        else static if (is(O == typeof(null)))
            return false;
        else static if (is(O : T))
            return !isNullValue(obj);
        else
            return false;
    }

    private static void instanceCheckFailed(string type, string className, string msg)
    {
        string result = "";
        bool defaultMessage = true;
        if (StringUtils.hasLength(msg))
        {
            if (endsWithSeparator(msg))
                result = msg ~ " ";
            else
            {
                result = messageWithTypeName(msg, className);
                defaultMessage = false;
            }
        }
        if (defaultMessage)
            result = result ~ "Object of class [" ~ className ~ "] must be an instance of " ~ type;
        throw new IllegalArgumentException(result);
    }

    private static void assignableCheckFailed(string superType, string subType, string msg)
    {
        string result = "";
        bool defaultMessage = true;
        if (StringUtils.hasLength(msg))
        {
            if (endsWithSeparator(msg))
                result = msg ~ " ";
            else
            {
                result = messageWithTypeName(msg, subType);
                defaultMessage = false;
            }
        }
        if (defaultMessage)
            result = result ~ subType ~ " is not assignable to " ~ superType;
        throw new IllegalArgumentException(result);
    }

    private static bool endsWithSeparator(string msg)
    {
        return hasSuffix(msg, ":") || hasSuffix(msg, ";") || hasSuffix(msg, ",") || hasSuffix(msg, ".");
    }

    private static string messageWithTypeName(string msg, string typeName)
    {
        return msg ~ (hasSuffix(msg, " ") ? "" : ": ") ~ typeName;
    }

    private static string nullSafeGet(string delegate() @safe messageSupplier)
    {
        return messageSupplier is null ? null : messageSupplier();
    }

    private static string nullSafeGet(Supplier!string messageSupplier)
    {
        return messageSupplier is null ? null : messageSupplier.get();
    }
}

// ---------------------------------------------------------------------------------------------------------------
// StringUtils

/++
Miscellaneous string utility methods. Characters are code points (R14); the `char` parameters of Spring's
signatures are `dchar`. `delete` is `delete_`, because `delete` is a D keyword.
+/
abstract class StringUtils
{
    private enum FOLDER_SEPARATOR = "/";
    private enum WINDOWS_FOLDER_SEPARATOR = "\\";
    private enum DOUBLE_BACKSLASHES = "\\\\";
    private enum TOP_PATH = "..";
    private enum CURRENT_PATH = ".";
    private enum DEFAULT_TRUNCATION_THRESHOLD = 100;
    private enum TRUNCATION_SUFFIX = " (truncated)...";

    // -----------------------------------------------------------------------------------------------------------
    // General convenience methods for working with Strings

    /++
    Whether `str` is null or the empty string. For non-string objects, whether it is null.

    Deprecated: as of Spring 5.3, in favor of `hasLength` and `hasText` (or `ObjectUtils.isEmpty`).
    +/
    deprecated("as of 5.3, in favor of hasLength and hasText (or ObjectUtils.isEmpty)") static bool isEmpty(T)(T str)
    {
        static if (is(T : const(char)[]))
            return str.length == 0;
        else
            return isNullValue(str);
    }

    /// Whether `str` is neither null nor empty; whitespace counts as content.
    static bool hasLength(scope const(char)[] str) pure nothrow @nogc
    {
        return str.length != 0;
    }

    /// Whether `str` contains a character that is not whitespace (Java's `Character.isWhitespace`).
    static bool hasText(scope const(char)[] str) pure nothrow @nogc
    {
        size_t i;
        while (i < str.length)
            if (!isJavaWhitespace(decodeAt(str, i)))
                return true;
        return false;
    }

    /// Whether `str` contains any whitespace character.
    static bool containsWhitespace(scope const(char)[] str) pure nothrow @nogc
    {
        size_t i;
        while (i < str.length)
            if (isJavaWhitespace(decodeAt(str, i)))
                return true;
        return false;
    }

    /// `str` without leading and trailing whitespace. Deprecated since Spring 6.0 in favor of `String.strip()`.
    deprecated("as of 6.0, in favor of strip") static string trimWhitespace(string str)
    {
        return trimTrailing(trimLeading(str));
    }

    /// `str` without any whitespace: leading, trailing, and in between characters.
    static string trimAllWhitespace(string str) pure nothrow
    {
        if (!hasLength(str))
            return str;
        char[] result;
        size_t i;
        while (i < str.length)
        {
            const start = i;
            if (!isJavaWhitespace(decodeAt(str, i)))
                result ~= str[start .. i];
        }
        return result.idup;
    }

    /// `str` without leading whitespace. Deprecated since Spring 6.0 in favor of `String.stripLeading()`.
    deprecated("as of 6.0, in favor of stripLeading") static string trimLeadingWhitespace(string str)
    {
        return trimLeading(str);
    }

    /// `str` without trailing whitespace. Deprecated since Spring 6.0 in favor of `String.stripTrailing()`.
    deprecated("as of 6.0, in favor of stripTrailing") static string trimTrailingWhitespace(string str)
    {
        return trimTrailing(str);
    }

    /// `str` without every leading occurrence of `leadingCharacter`.
    static string trimLeadingCharacter(string str, dchar leadingCharacter) pure nothrow @nogc
    {
        size_t begin;
        while (begin < str.length)
        {
            size_t next = begin;
            if (decodeAt(str, next) != leadingCharacter)
                break;
            begin = next;
        }
        return str[begin .. $];
    }

    /// `str` without every trailing occurrence of `trailingCharacter`.
    static string trimTrailingCharacter(string str, dchar trailingCharacter) pure nothrow @nogc
    {
        size_t end = str.length;
        while (end > 0 && codePointBefore(str, end) == trailingCharacter)
            end -= strideBefore(str, end);
        return str[0 .. end];
    }

    /// Whether `str` is exactly the single character `singleCharacter`.
    static bool matchesCharacter(scope const(char)[] str, dchar singleCharacter) pure nothrow @nogc
    {
        if (str.length == 0)
            return false;
        size_t i;
        return decodeAt(str, i) == singleCharacter && i == str.length;
    }

    /// Whether `str` starts with `prefix`, ignoring upper and lower case. False when either is null.
    static bool startsWithIgnoreCase(scope const(char)[] str, scope const(char)[] prefix) pure nothrow @nogc
    {
        return str !is null && prefix !is null && matchIgnoreCaseAt(str, 0, prefix) >= 0;
    }

    /// Whether `str` ends with `suffix`, ignoring upper and lower case. False when either is null.
    static bool endsWithIgnoreCase(scope const(char)[] str, scope const(char)[] suffix) pure nothrow @nogc
    {
        if (str is null || suffix is null)
            return false;
        size_t i = str.length;
        size_t j = suffix.length;
        while (j > 0)
        {
            if (i == 0)
                return false;
            const wi = strideBefore(str, i);
            const wj = strideBefore(suffix, j);
            if (!charsEqualIgnoreCase(codePointBefore(str, i), codePointBefore(suffix, j)))
                return false;
            i -= wi;
            j -= wj;
        }
        return true;
    }

    /++
    Whether `substring` occurs in `str` at `index`. The index is in UTF-16 code units, as in Java (R14); an index
    inside a surrogate pair or past the end never matches.
    +/
    static bool substringMatch(scope const(char)[] str, int index, scope const(char)[] substring) pure nothrow @nogc
    {
        if (index < 0)
            return false;
        const offset = utf16ToByteOffset(str, index);
        return offset >= 0 && substringMatchAt(str, offset, substring);
    }

    /// The number of non-overlapping occurrences of `sub` in `str`; 0 when either is null or empty.
    static int countOccurrencesOf(scope const(char)[] str, scope const(char)[] sub) pure nothrow @nogc
    {
        if (!hasLength(str) || !hasLength(sub))
            return 0;
        int count;
        size_t pos;
        ptrdiff_t idx;
        while ((idx = indexOfFrom(str, sub, pos)) != -1)
        {
            ++count;
            pos = idx + sub.length;
        }
        return count;
    }

    /// `inString` with every occurrence of `oldPattern` replaced by `newPattern`; `inString` itself when nothing
    /// matches or `newPattern` is null.
    static string replace(string inString, string oldPattern, string newPattern) pure nothrow
    {
        if (!hasLength(inString) || !hasLength(oldPattern) || newPattern is null)
            return inString;
        ptrdiff_t index = indexOfString(inString, oldPattern);
        if (index == -1)
            return inString;
        string result;
        size_t pos;
        while (index >= 0)
        {
            result ~= inString[pos .. index];
            result ~= newPattern;
            pos = index + oldPattern.length;
            index = indexOfFrom(inString, oldPattern, pos);
        }
        return result ~ inString[pos .. $];
    }

    /// `inString` without any occurrence of `pattern` (Java's `delete`; renamed because `delete` is a D keyword).
    static string delete_(string inString, string pattern) pure nothrow
    {
        return replace(inString, pattern, "");
    }

    /// `inString` without any of the characters in `charsToDelete`.
    static string deleteAny(string inString, scope const(char)[] charsToDelete) pure nothrow
    {
        if (!hasLength(inString) || !hasLength(charsToDelete))
            return inString;
        char[] result;
        size_t i;
        bool deleted;
        while (i < inString.length)
        {
            const start = i;
            if (containsCodePoint(charsToDelete, decodeAt(inString, i)))
                deleted = true;
            else
                result ~= inString[start .. i];
        }
        return deleted ? result.idup : inString;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Convenience methods for working with formatted Strings

    /// `str` in single quotes, or null for null.
    static string quote(string str) pure nothrow
    {
        return str is null ? null : "'" ~ str ~ "'";
    }

    /// `quote(obj)` for a string; any other object unchanged.
    static auto quoteIfString(T)(T obj)
    {
        static if (isJavaString!T)
            return quote(obj);
        else
            return obj;
    }

    /// The text after the last `.` of `qualifiedName`.
    static string unqualify(string qualifiedName) pure nothrow @nogc
    {
        return unqualify(qualifiedName, '.');
    }

    /// The text after the last `separator` of `qualifiedName`.
    static string unqualify(string qualifiedName, dchar separator) pure nothrow @nogc
    {
        import flint.engine.aot.text : utf8Length;

        const index = lastIndexOfCodePoint(qualifiedName, separator);
        return index < 0 ? qualifiedName : qualifiedName[index + utf8Length(separator) .. $];
    }

    /// `str` with its first character in upper case (`std.uni.toUpper`).
    static string capitalize(string str)
    {
        return changeFirstCharacterCase(str, true);
    }

    /// `str` with its first character in lower case (`std.uni.toLower`).
    static string uncapitalize(string str)
    {
        return changeFirstCharacterCase(str, false);
    }

    /// `uncapitalize`, except that a name starting with two upper-case characters is kept (JavaBeans rules).
    static string uncapitalizeAsProperty(string str)
    {
        import std.uni : isUpper;

        if (!hasLength(str))
            return str;
        size_t i;
        const first = decodeAt(str, i);
        if (i < str.length && isUpper(first) && isUpper(decodeAt(str, i)))
            return str;
        return changeFirstCharacterCase(str, false);
    }

    private static string changeFirstCharacterCase(string str, bool upper)
    {
        import std.uni : toLower, toUpper;

        if (!hasLength(str))
            return str;
        size_t i;
        const baseChar = decodeAt(str, i);
        const updatedChar = upper ? toUpper(baseChar) : toLower(baseChar);
        if (baseChar == updatedChar)
            return str;
        return encodeCodePoint(updatedChar) ~ str[i .. $];
    }

    /// The file name of `path` (after the last `/`), or null for null.
    static string getFilename(string path) pure nothrow @nogc
    {
        if (path is null)
            return null;
        const separatorIndex = lastIndexOfChar(path, '/');
        return separatorIndex != -1 ? path[separatorIndex + 1 .. $] : path;
    }

    /// The extension of `path` (after the last `.` of the file name), or null when there is none.
    static string getFilenameExtension(string path) pure nothrow @nogc
    {
        if (path is null)
            return null;
        const extIndex = lastIndexOfChar(path, '.');
        if (extIndex == -1)
            return null;
        if (lastIndexOfChar(path, '/') > extIndex)
            return null;
        return path[extIndex + 1 .. $];
    }

    /// `path` without its file name extension.
    static string stripFilenameExtension(string path) pure nothrow @nogc
    {
        const extIndex = lastIndexOfChar(path, '.');
        if (extIndex == -1)
            return path;
        if (lastIndexOfChar(path, '/') > extIndex)
            return path;
        return path[0 .. extIndex];
    }

    /// `relativePath` applied to `path`, assuming standard Java folder separation (`/`).
    static string applyRelativePath(string path, string relativePath) pure nothrow
    {
        const separatorIndex = lastIndexOfChar(path, '/');
        if (separatorIndex == -1)
            return relativePath;
        string newPath = path[0 .. separatorIndex];
        if (!hasPrefix(relativePath, FOLDER_SEPARATOR))
            newPath ~= '/';
        return newPath ~ relativePath;
    }

    /++
    Normalize `path` by suppressing sequences like `path/..` and inner simple dots, and by replacing Windows
    separators with `/`. The result is suitable for path comparison, not for security checks.
    +/
    static string cleanPath(string path) pure nothrow
    {
        if (!hasLength(path))
            return path;
        string normalizedPath = path;
        if (indexOfChar(path, '\\') != -1)
        {
            normalizedPath = replace(path, DOUBLE_BACKSLASHES, FOLDER_SEPARATOR);
            normalizedPath = replace(normalizedPath, WINDOWS_FOLDER_SEPARATOR, FOLDER_SEPARATOR);
        }
        string pathToUse = normalizedPath;
        if (indexOfChar(pathToUse, '.') == -1)
            return pathToUse;
        const prefixIndex = indexOfChar(pathToUse, ':');
        string prefix = "";
        if (prefixIndex != -1)
        {
            prefix = pathToUse[0 .. prefixIndex + 1];
            if (indexOfChar(prefix, '/') != -1)
                prefix = "";
            else
                pathToUse = pathToUse[prefixIndex + 1 .. $];
        }
        if (hasPrefix(pathToUse, FOLDER_SEPARATOR))
        {
            prefix = prefix ~ FOLDER_SEPARATOR;
            pathToUse = pathToUse[1 .. $];
        }
        const pathArray = delimitedListToStringArray(pathToUse, FOLDER_SEPARATOR);
        const collapsed = collapseElements(pathArray);
        if (pathArray.length == collapsed.elements.length)
            return normalizedPath;
        string[] pathElements = collapsed.elements.dup;
        foreach (_; 0 .. collapsed.tops)
            pathElements = TOP_PATH ~ pathElements;
        if (pathElements.length == 1 && pathElements[0].length == 0 && !hasSuffix(prefix, FOLDER_SEPARATOR))
            pathElements = CURRENT_PATH ~ pathElements;
        string joined;
        foreach (i, element; pathElements)
            joined ~= (i ? FOLDER_SEPARATOR : "") ~ element;
        return prefix.length == 0 ? joined : prefix ~ joined;
    }

    private static struct CollapsedPath
    {
        string[] elements;
        int tops;
    }

    /// Drop `.` elements and resolve `..` against preceding elements, counting the unresolved `..` elements.
    private static CollapsedPath collapseElements(const(string)[] pathArray) pure nothrow
    {
        string[] reversed;
        int tops;
        for (size_t i = pathArray.length; i > 0; i--)
        {
            const element = pathArray[i - 1];
            if (element == CURRENT_PATH)
                continue;
            if (element == TOP_PATH)
                tops++;
            else if (tops > 0)
                tops--;
            else
                reversed ~= element;
        }
        string[] result;
        for (size_t i = reversed.length; i > 0; i--)
            result ~= reversed[i - 1];
        return CollapsedPath(result, tops);
    }

    /// Whether two paths are equal after `cleanPath`.
    static bool pathEquals(string path1, string path2) pure nothrow
    {
        return cleanPath(path1) == cleanPath(path2);
    }

    /++
    Decode the URI-encoded `source` as UTF-8 (adapted: Spring's `Charset` parameter is fixed to UTF-8). `%xy`
    sequences decode to bytes; malformed UTF-8 decodes to U+FFFD as Java's `new String(bytes, UTF_8)` does.
    Throws `IllegalArgumentException` for an invalid or incomplete escape.
    +/
    static string uriDecode(string source)
    {
        const firstPercentIndex = indexOfChar(source, '%');
        if (source.length == 0 || firstPercentIndex < 0)
            return source;
        string output = source[0 .. firstPercentIndex];
        size_t i = firstPercentIndex;
        while (i < source.length)
        {
            if (source[i] != '%')
            {
                output ~= source[i];
                i++;
                continue;
            }
            ubyte[] bytes;
            while (i + 2 < source.length && source[i] == '%')
            {
                const high = hexDigit(source[i + 1]);
                const low = hexDigit(source[i + 2]);
                if (high < 0 || low < 0)
                    throw new IllegalArgumentException("Invalid encoded sequence \"" ~ source[i .. $] ~ "\"");
                bytes ~= cast(ubyte)(high * 16 + low);
                i += 3;
            }
            if (i < source.length && source[i] == '%')
                throw new IllegalArgumentException("Incomplete trailing escape (%) pattern");
            output ~= decodeUtf8Bytes(bytes);
        }
        return output;
    }

    private static int hexDigit(char c) pure nothrow @nogc
    {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return -1;
    }

    private static string decodeUtf8Bytes(const(ubyte)[] bytes) pure nothrow
    {
        const text = cast(const(char)[]) bytes;
        char[] result;
        size_t i;
        while (i < text.length)
        {
            const start = i;
            const c = decodeAt(text, i);
            if (c == 0xFFFD && text[start .. i] != "�")
                result ~= "�";
            else
                result ~= text[start .. i];
        }
        return result.idup;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Convenience methods for working with String arrays

    /// The elements of `collection` as an array; empty for null or an empty collection.
    static string[] toStringArray(Collection!string collection)
    {
        return CollectionUtils.isEmpty(collection) ? null : collection.toArray();
    }

    /// `array` with `str` appended, as a new array.
    static string[] addStringToArray(string[] array, string str) pure nothrow
    {
        return array ~ str;
    }

    /// `array1` followed by `array2`; either one when the other is null or empty.
    static string[] concatenateStringArrays(string[] array1, string[] array2) pure nothrow
    {
        if (array1.length == 0)
            return array2;
        if (array2.length == 0)
            return array1;
        return array1 ~ array2;
    }

    /// Sort `array` in place in Java's `String` order (UTF-16 code units) and return it.
    static string[] sortStringArray(string[] array)
    {
        if (array.length == 0)
            return array;
        stableSort(array, (string a, string b) => compareUtf16(a, b));
        return array;
    }

    /// A copy of `array` with each element `trim`med (characters up to U+0020); null elements stay null.
    static string[] trimArrayElements(string[] array) pure nothrow
    {
        if (array.length == 0)
            return array;
        auto result = new string[array.length];
        foreach (i, element; array)
            result[i] = element is null ? null : javaTrim(element);
        return result;
    }

    /// `array` without duplicates, keeping the first occurrence of each (insertion order).
    static string[] removeDuplicateStrings(string[] array) pure nothrow
    {
        if (array.length == 0)
            return array;
        bool[string] seen;
        string[] result;
        foreach (element; array)
        {
            if (element in seen)
                continue;
            seen[element] = true;
            result ~= element;
        }
        return result;
    }

    /// `toSplit` split at the first occurrence of `delimiter` into two elements, or null when the delimiter does
    /// not occur or either argument is empty.
    static string[] split(string toSplit, scope const(char)[] delimiter) pure nothrow
    {
        if (!hasLength(toSplit) || !hasLength(delimiter))
            return null;
        const offset = indexOfString(toSplit, delimiter);
        if (offset < 0)
            return null;
        return [toSplit[0 .. offset], toSplit[offset + delimiter.length .. $]];
    }

    /++
    Split each element of `array` at the first `delimiter` into a key and a value, both trimmed. Adapted (R10):
    Spring returns `java.util.Properties`; Flint returns an insertion-ordered `Map!(string, string)`. Null for
    a null or empty array.
    +/
    static Map!(string, string) splitArrayElementsIntoProperties(string[] array, string delimiter)
    {
        return splitArrayElementsIntoProperties(array, delimiter, null);
    }

    /// ditto, deleting `charsToDelete` from each element first.
    static Map!(string, string) splitArrayElementsIntoProperties(string[] array, string delimiter, string charsToDelete)
    {
        if (array.length == 0)
            return null;
        auto result = new LinkedHashMap!(string, string)();
        foreach (element; array)
        {
            const cleaned = charsToDelete !is null ? deleteAny(element, charsToDelete) : element;
            const pair = split(cleaned, delimiter);
            if (pair is null)
                continue;
            result.put(javaTrim(pair[0]), javaTrim(pair[1]));
        }
        return result;
    }

    /// `str` tokenized at any of the characters in `delimiters`, trimming tokens and dropping empty ones
    /// (Java's `StringTokenizer`); empty for null.
    static string[] tokenizeToStringArray(string str, scope const(char)[] delimiters) pure nothrow
    {
        return tokenizeToStringArray(str, delimiters, true, true);
    }

    /// ditto, choosing whether to trim tokens and whether to drop empty ones.
    static string[] tokenizeToStringArray(string str, scope const(char)[] delimiters, bool trimTokens,
            bool ignoreEmptyTokens) pure nothrow
    {
        string[] tokens;
        size_t i;
        size_t start;
        bool inToken;
        while (i < str.length)
        {
            const position = i;
            const isDelimiter = containsCodePoint(delimiters, decodeAt(str, i));
            if (isDelimiter && inToken)
                appendToken(tokens, str[start .. position], trimTokens, ignoreEmptyTokens);
            else if (!isDelimiter && !inToken)
                start = position;
            inToken = !isDelimiter;
        }
        if (inToken)
            appendToken(tokens, str[start .. $], trimTokens, ignoreEmptyTokens);
        return tokens;
    }

    private static void appendToken(ref string[] tokens, string token, bool trim, bool ignoreEmpty) pure nothrow
    {
        const value = trim ? javaTrim(token) : token;
        if (!ignoreEmpty || value.length != 0)
            tokens ~= value;
    }

    /++
    `str` split at each occurrence of `delimiter` (a whole string, unlike `tokenizeToStringArray`). A null
    delimiter gives `[str]`; an empty delimiter splits into single characters (code points). Empty for null.
    +/
    static string[] delimitedListToStringArray(string str, string delimiter) pure nothrow
    {
        return delimitedListToStringArray(str, delimiter, null);
    }

    /// ditto, deleting `charsToDelete` from each element.
    static string[] delimitedListToStringArray(string str, string delimiter, string charsToDelete) pure nothrow
    {
        if (str is null)
            return [];
        if (delimiter is null)
            return [str];
        string[] result;
        if (delimiter.length == 0)
        {
            size_t i;
            while (i < str.length)
            {
                const start = i;
                skipCodePoint(str, i);
                result ~= deleteAny(str[start .. i], charsToDelete);
            }
            return result;
        }
        size_t pos;
        ptrdiff_t delPos;
        while ((delPos = indexOfFrom(str, delimiter, pos)) != -1)
        {
            result ~= deleteAny(str[pos .. delPos], charsToDelete);
            pos = delPos + delimiter.length;
        }
        if (str.length != 0 && pos <= str.length)
            result ~= deleteAny(str[pos .. $], charsToDelete);
        return result;
    }

    /// `str` split at commas; empty for null.
    static string[] commaDelimitedListToStringArray(string str) pure nothrow
    {
        return delimitedListToStringArray(str, ",");
    }

    /// `str` split at commas into an insertion-ordered set without duplicates.
    static Set!string commaDelimitedListToSet(string str)
    {
        return new LinkedHashSet!string(commaDelimitedListToStringArray(str));
    }

    /// The elements of `coll` (`String.valueOf` each) separated by `delim`, each wrapped in `prefix` and `suffix`.
    static string collectionToDelimitedString(T)(Collection!T coll, string delim, string prefix, string suffix)
    {
        if (CollectionUtils.isEmpty(coll))
            return "";
        string result;
        foreach (i, element; coll.toArray())
            result ~= (i ? delim : "") ~ prefix ~ valueOf(element) ~ suffix;
        return result;
    }

    /// ditto, without prefix and suffix.
    static string collectionToDelimitedString(T)(Collection!T coll, string delim)
    {
        return collectionToDelimitedString(coll, delim, "", "");
    }

    /// ditto, separated by commas.
    static string collectionToCommaDelimitedString(T)(Collection!T coll)
    {
        return collectionToDelimitedString(coll, ",");
    }

    /// The elements of `arr` (`String.valueOf` each) separated by `delim`; "" for a null or empty array.
    static string arrayToDelimitedString(T)(T[] arr, string delim)
    {
        if (arr.length == 0)
            return "";
        if (arr.length == 1)
            return ObjectUtils.nullSafeToString(arr[0]);
        string result;
        foreach (i, element; arr)
            result ~= (i ? delim : "") ~ valueOf(element);
        return result;
    }

    /// ditto, separated by commas.
    static string arrayToCommaDelimitedString(T)(T[] arr)
    {
        return arrayToDelimitedString(arr, ",");
    }

    /// `charSequence` truncated to 100 UTF-16 code units followed by `" (truncated)..."` when it is longer.
    static string truncate(string charSequence)
    {
        return truncate(charSequence, DEFAULT_TRUNCATION_THRESHOLD);
    }

    /++
    `charSequence` truncated to `threshold` UTF-16 code units (R14: Java's unit) followed by
    `" (truncated)..."` when it is longer. A surrogate pair is never split: the cut moves before it.
    +/
    static string truncate(string charSequence, int threshold)
    {
        Assert.isTrue(threshold > 0, () => "Truncation threshold must be a positive number: " ~ valueOf(threshold));
        if (utf16Length(charSequence) <= threshold)
            return charSequence;
        size_t units;
        size_t i;
        while (i < charSequence.length)
        {
            size_t next = i;
            const width = decodeAt(charSequence, next) >= 0x10000 ? 2 : 1;
            if (units + width > threshold)
                break;
            units += width;
            i = next;
        }
        return charSequence[0 .. i] ~ TRUNCATION_SUFFIX;
    }

    private static string trimLeading(string str) pure nothrow @nogc
    {
        size_t begin;
        while (begin < str.length)
        {
            size_t next = begin;
            if (!isJavaWhitespace(decodeAt(str, next)))
                break;
            begin = next;
        }
        return str[begin .. $];
    }

    private static string trimTrailing(string str) pure nothrow @nogc
    {
        size_t end = str.length;
        while (end > 0 && isJavaWhitespace(codePointBefore(str, end)))
            end -= strideBefore(str, end);
        return str[0 .. end];
    }
}

// ---------------------------------------------------------------------------------------------------------------
// ObjectUtils

/++
Miscellaneous object utility methods. Spring's `Object` parameters are templates over the argument type; arrays
are D arrays (a `string` is Java's `String`, other character arrays are Java's `char[]`), and Java's boxed scalars
are D scalars.
+/
abstract class ObjectUtils
{
    private enum NULL_STRING = "null";
    private enum ARRAY_START = "{";
    private enum ARRAY_END = "}";
    private enum EMPTY_ARRAY = "{}";
    private enum ARRAY_ELEMENT_SEPARATOR = ", ";
    private enum NON_EMPTY_ARRAY = "{...}";
    private enum COLLECTION = "[...]";
    private enum MAP = "{...}";

    /// Whether `ex` is a checked exception: neither a `RuntimeException` nor an `Error`.
    static bool isCheckedException(Throwable ex)
    {
        return cast(RuntimeException) ex is null && cast(Error) ex is null;
    }

    /// Whether `ex` is compatible with a `throws` clause declaring `DeclaredExceptions` (R4).
    static bool isCompatibleWithThrowsClause(DeclaredExceptions...)(Throwable ex)
    {
        if (!isCheckedException(ex))
            return true;
        foreach (Declared; DeclaredExceptions)
            if (cast(Declared) ex !is null)
                return true;
        return false;
    }

    /// Whether `obj` is a non-null array (a string is not an array).
    static bool isArray(T)(T obj)
    {
        static if (isJavaArray!T)
            return obj !is null;
        else
            return false;
    }

    /// Whether `array` is null or empty.
    static bool isEmpty(T)(T[] array)
    {
        return array.length == 0;
    }

    /++
    Whether `obj` is empty: null, an empty `Optional`, an empty string, array, associative array, `Collection` or
    `Map`. Any other object is not empty.
    +/
    static bool isEmpty(T)(T obj) if (!is(T == E[], E) || is(T == typeof(null)))
    {
        static if (is(T == typeof(null)))
            return true;
        else static if (isOptional!T)
            return obj.isEmpty();
        else static if (is(T == V[K], V, K))
            return obj.length == 0;
        else static if (is(T == class) || is(T == interface))
            return isEmptyObject(cast(Object) obj);
        else
            return isNullValue(obj);
    }

    private static bool isEmptyObject(Object obj)
    {
        if (obj is null)
            return true;
        if (auto collection = cast(RawCollection) obj)
            return collection.size() == 0;
        if (auto map = cast(RawMap) obj)
            return map.size() == 0;
        return false;
    }

    /// The value of an `Optional`, or `T.init` when it is empty; any other object unchanged. Throws
    /// `IllegalArgumentException` for a nested `Optional`.
    static auto unwrapOptional(T)(T obj)
    {
        static if (is(T == Optional!U, U))
        {
            auto result = obj.orElse(U.init);
            Assert.isTrue(!isOptional!U, "Multi-level Optional usage not supported");
            return result;
        }
        else
            return obj;
    }

    /// Whether `array` contains `element` (`nullSafeEquals`); false for a null array.
    static bool containsElement(T, E)(T[] array, E element)
    {
        foreach (arrayElement; array)
            if (nullSafeEquals(arrayElement, element))
                return true;
        return false;
    }

    /// Whether `enumValues` has a constant named `constant`, ignoring case.
    static bool containsConstant(E)(E[] enumValues, string constant) if (is(E == enum))
    {
        return containsConstant(enumValues, constant, false);
    }

    /// Whether `enumValues` has a constant named `constant`, optionally case-sensitively.
    static bool containsConstant(E)(E[] enumValues, string constant, bool caseSensitive)
            if (is(E == enum))
    {
        import flint.engine.aot.text : enumName;

        foreach (candidate; enumValues)
        {
            const name = enumName(candidate);
            if (caseSensitive ? name == constant : equalsIgnoreCase(name, constant))
                return true;
        }
        return false;
    }

    /// The constant of `enumValues` named `constant`, ignoring case. Throws `IllegalArgumentException` when none.
    static E caseInsensitiveValueOf(E)(E[] enumValues, string constant) if (is(E == enum))
    {
        import flint.engine.aot.text : enumName;

        foreach (candidate; enumValues)
            if (equalsIgnoreCase(enumName(candidate), constant))
                return candidate;
        throw new IllegalArgumentException(
                "Constant [" ~ constant ~ "] does not exist in enum type " ~ __traits(fullyQualifiedName, E));
    }

    /// A new array of `array`'s elements followed by `obj`.
    static A[] addObjectToArray(A, O)(A[] array, O obj) if (is(O : A))
    {
        return addObjectToArray(array, obj, cast(int) array.length);
    }

    /// A new array of `array`'s elements with `obj` inserted at `position`. Throws `IndexOutOfBoundsException`
    /// when `position` is outside `[0, array.length]`.
    static A[] addObjectToArray(A, O)(A[] array, O obj, int position) if (is(O : A))
    {
        if (position < 0 || position > array.length)
            throw new IndexOutOfBoundsException(position);
        auto newArray = new A[array.length + 1];
        newArray[0 .. position] = array[0 .. position];
        newArray[position] = obj;
        newArray[position + 1 .. $] = array[position .. $];
        return newArray;
    }

    /++
    Whether `o1` and `o2` are equal: both null, `equals` for objects, element-wise for arrays (Java's
    `Arrays.equals`), `==` for values of the same type. Values of unrelated types are never equal.
    +/
    static bool nullSafeEquals(A, B)(A o1, B o2)
    {
        import std.traits : Unqual;

        static if (is(A == typeof(null)) || is(B == typeof(null)))
            return isNullValue(o1) && isNullValue(o2);
        else static if ((is(A == class) || is(A == interface)) && (is(B == class) || is(B == interface)))
            return objectEquals(cast(Object) o1, cast(Object) o2);
        else static if (isJavaString!A && isJavaString!B)
            return o1 is null ? o2 is null : o2 !is null && o1 == o2;
        else static if (isJavaArray!A && isJavaArray!B)
            return arrayEquals(o1, o2);
        else static if (is(Unqual!A == Unqual!B) && !isNullable!A)
            return o1 == o2;
        else
            return false;
    }

    private static bool arrayEquals(A, B)(A o1, B o2)
    {
        if (o1 is null || o2 is null)
            return o1 is null && o2 is null;
        if (o1.length != o2.length)
            return false;
        foreach (i, element; o1)
            if (!nullSafeEquals(element, o2[i]))
                return false;
        return true;
    }

    /// Java's `Objects.hash` over `elements` with `nullSafeHashCode`; a single array argument is the element
    /// array (Java's varargs), and a null array hashes to 0.
    static int nullSafeHash(Args...)(Args elements)
    {
        static if (Args.length == 1 && isJavaArray!(Args[0]))
        {
            if (elements[0] is null)
                return 0;
            int result = 1;
            foreach (element; elements[0])
                result = 31 * result + nullSafeHashCode(element);
            return result;
        }
        else
        {
            int result = 1;
            foreach (element; elements)
                result = 31 * result + nullSafeHashCode(element);
            return result;
        }
    }

    /++
    The hash code of `obj`, or 0 for null. Arrays hash by content as Java's `Arrays.hashCode` does (adapted: one
    template covers Spring's deprecated per-array-type overloads); strings use `String.hashCode`.
    +/
    static int nullSafeHashCode(T)(T obj)
    {
        static if (is(T == typeof(null)))
            return 0;
        else static if (isJavaArray!T)
            return obj is null ? 0 : arrayHashCode(obj);
        else static if (is(T == float))
            return floatBits(obj);
        else
            return javaHashCode(obj);
    }

    private static int arrayHashCode(E)(E[] array)
    {
        static if (is(immutable E == immutable char))
            return utf16Hash(1, array);
        else
        {
            int result = 1;
            foreach (element; array)
                result = 31 * result + nullSafeHashCode(element);
            return result;
        }
    }

    private static int utf16Hash(int seed, scope const(char)[] text) pure nothrow @nogc
    {
        int h = seed;
        size_t i;
        while (i < text.length)
        {
            const c = decodeAt(text, i);
            if (c >= 0x10000)
            {
                h = 31 * h + cast(int)(0xD800 + ((c - 0x10000) >> 10));
                h = 31 * h + cast(int)(0xDC00 + ((c - 0x10000) & 0x3FF));
            }
            else
                h = 31 * h + cast(int) c;
        }
        return h;
    }

    private static int floatBits(float value) pure nothrow @nogc
    {
        if (value != value)
            return 0x7fc00000;
        union Bits
        {
            float f;
            int i;
        }

        Bits bits;
        bits.f = value;
        return bits.i;
    }

    /// The class name and identity hash code of `obj` (`name@hex`), or "" for null.
    static string identityToString(Object obj)
    {
        if (obj is null)
            return "";
        return typeid(obj).name ~ "@" ~ getIdentityHexString(obj);
    }

    /// The identity hash code of `obj` in hexadecimal: its address folded to 32 bits (D's GC does not move
    /// objects).
    static string getIdentityHexString(Object obj)
    {
        const address = cast(size_t) cast(void*) obj;
        static if (size_t.sizeof > 4)
            return hexString(cast(uint)(address ^ (address >> 32)));
        else
            return hexString(cast(uint) address);
    }

    /// `nullSafeToString(obj)`, but "" for null.
    static string getDisplayString(T)(T obj)
    {
        if (isNullValue(obj))
            return "";
        return nullSafeToString(obj);
    }

    /// The class name of `obj`, or `"null"`.
    static string nullSafeClassName(T)(T obj)
    {
        return runtimeClassName(obj);
    }

    /++
    A string representation of `obj`: `"null"` for null, the string itself, `{a, b}` for arrays (byte arrays in
    hexadecimal, character arrays quoted), and `toString()` otherwise. A null `toString()` gives "".
    +/
    static string nullSafeToString(T)(T obj)
    {
        static if (is(T == typeof(null)))
            return NULL_STRING;
        else static if (isJavaString!T)
            return obj is null ? NULL_STRING : obj;
        else static if (isJavaArray!T)
            return arrayToString(obj);
        else static if (is(T == class) || is(T == interface))
        {
            if (obj is null)
                return NULL_STRING;
            const str = objectToString(cast(Object) obj);
            return str is null ? "" : str;
        }
        else
            return scalarText(obj);
    }

    private static string arrayToString(E)(E[] array)
    {
        import std.traits : Unqual;

        if (array is null)
            return NULL_STRING;
        if (array.length == 0)
            return EMPTY_ARRAY;
        static if (is(Unqual!E == byte) || is(Unqual!E == ubyte))
        {
            enum digits = "0123456789abcdef";
            string hex;
            foreach (b; array)
                hex ~= [digits[(cast(ubyte) b) >> 4], digits[b & 0xF]];
            return ARRAY_START ~ hex ~ ARRAY_END;
        }
        else static if (is(Unqual!E == char) || is(Unqual!E == wchar) || is(Unqual!E == dchar))
        {
            string result;
            void add(dchar c)
            {
                result ~= (result.length ? ARRAY_ELEMENT_SEPARATOR : "") ~ "'" ~ encodeCodePoint(c) ~ "'";
            }

            static if (is(Unqual!E == char))
            {
                for (size_t i; i < array.length;)
                    add(decodeAt(array, i)); // byDchar's replacement decode, without std.utf
            }
            else
            {
                import std.utf : byDchar;

                foreach (c; array.byDchar)
                    add(c);
            }
            return ARRAY_START ~ result ~ ARRAY_END;
        }
        else
        {
            string result;
            foreach (i, element; array)
                result ~= (i ? ARRAY_ELEMENT_SEPARATOR : "") ~ elementText(element);
            return ARRAY_START ~ result ~ ARRAY_END;
        }
    }

    private static string elementText(T)(T element)
    {
        static if (is(T == float) || is(T == double) || is(T == bool) || is(T == enum))
            return scalarText(element);
        else
            return valueOf(element);
    }

    private static string scalarText(T)(T value)
    {
        import flint.engine.aot.text : enumName;

        static if (is(T == float))
            return javaFloatingText(value, true);
        else static if (is(T == double) || is(T == real))
            return javaFloatingText(value, false);
        else static if (is(T == enum))
            return enumName(value);
        else
            return valueOf(value);
    }

    /++
    A concise, truncated representation of `obj` for logging: `"null"`, `Optional[...]` or `Optional.empty`,
    `{}` or `{...}` for arrays, `[...]` for collections, `{...}` for maps, the text of strings and simple values
    (scalars, enums) truncated to 100 characters, and `type@hex` for any other object.
    +/
    static string nullSafeConciseToString(T)(T obj)
    {
        static if (is(T == typeof(null)))
            return NULL_STRING;
        else static if (isOptional!T)
            return obj.isEmpty() ? "Optional.empty" : "Optional[" ~ nullSafeConciseToString(obj.get()) ~ "]";
        else static if (isJavaString!T)
            return obj is null ? NULL_STRING : StringUtils.truncate(obj);
        else static if (isJavaArray!T)
            return obj is null ? NULL_STRING : (obj.length == 0 ? EMPTY_ARRAY : NON_EMPTY_ARRAY);
        else static if (is(T == class) || is(T == interface))
            return conciseObjectText(cast(Object) obj);
        else static if (__traits(isScalar, T) || is(T == enum))
            return StringUtils.truncate(scalarText(obj));
        else
            return __traits(fullyQualifiedName, T) ~ "@" ~ hexString(cast(uint) hashOf(obj));
    }

    private static string conciseObjectText(Object obj)
    {
        if (obj is null)
            return NULL_STRING;
        if (cast(RawCollection) obj !is null)
            return COLLECTION;
        if (cast(RawMap) obj !is null)
            return MAP;
        return typeid(obj).name ~ "@" ~ getIdentityHexString(obj);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// CollectionUtils

/// Miscellaneous collection utility methods.
abstract class CollectionUtils
{
    /// Whether `collection` is null or empty.
    static bool isEmpty(T)(Collection!T collection)
    {
        return collection is null || collection.isEmpty();
    }

    /// Whether `map` is null or empty.
    static bool isEmpty(K, V)(Map!(K, V) map)
    {
        return map is null || map.isEmpty();
    }

    /// A new `HashMap` sized for `expectedSize` entries (the size is a hint; Flint maps grow as needed).
    static HashMap!(K, V) newHashMap(K, V)(int expectedSize)
    {
        Assert.isTrue(expectedSize >= 0, "Expected size must not be negative");
        return new HashMap!(K, V)();
    }

    /// A new `LinkedHashMap` sized for `expectedSize` entries.
    static LinkedHashMap!(K, V) newLinkedHashMap(K, V)(int expectedSize)
    {
        Assert.isTrue(expectedSize >= 0, "Expected size must not be negative");
        return new LinkedHashMap!(K, V)();
    }

    /// A new `HashSet` sized for `expectedSize` elements.
    static HashSet!E newHashSet(E)(int expectedSize)
    {
        Assert.isTrue(expectedSize >= 0, "Expected size must not be negative");
        return new HashSet!E();
    }

    /// A new `LinkedHashSet` sized for `expectedSize` elements.
    static LinkedHashSet!E newLinkedHashSet(E)(int expectedSize)
    {
        Assert.isTrue(expectedSize >= 0, "Expected size must not be negative");
        return new LinkedHashSet!E();
    }

    /// `source` as a fixed-size list (Java's `Arrays.asList`).
    static List!T arrayToList(T)(T[] source)
    {
        return Arrays.asList(source);
    }

    /// Append the elements of `array` to `collection`.
    static void mergeArrayIntoCollection(E)(E[] array, Collection!E collection)
    {
        foreach (element; array)
            collection.add(element);
    }

    /// Whether `iterator` yields `element` (`ObjectUtils.nullSafeEquals`); false for a null iterator.
    static bool contains(T, E)(Iterator!T iterator, E element)
    {
        if (iterator !is null)
            while (iterator.hasNext())
                if (ObjectUtils.nullSafeEquals(iterator.next(), element))
                    return true;
        return false;
    }

    /// Whether `collection` contains the instance `element` itself (identity, not equality).
    static bool containsInstance(T, E)(Collection!T collection, E element)
    {
        if (collection !is null)
            foreach (candidate; collection.toArray())
                if (sameInstance(candidate, element))
                    return true;
        return false;
    }

    /// Whether any element of `candidates` is contained in `source`.
    static bool containsAny(T)(Collection!T source, Collection!T candidates)
    {
        return findFirstMatchIndex(source, candidates) >= 0;
    }

    /// The first element of `candidates` contained in `source`, or `T.init` (null) when there is none.
    static T findFirstMatch(T)(Collection!T source, Collection!T candidates)
    {
        const index = findFirstMatchIndex(source, candidates);
        return index < 0 ? T.init : candidates.toArray()[index];
    }

    private static ptrdiff_t findFirstMatchIndex(T)(Collection!T source, Collection!T candidates)
    {
        if (isEmpty(source) || isEmpty(candidates))
            return -1;
        foreach (i, candidate; candidates.toArray())
            if (source.contains(candidate))
                return cast(ptrdiff_t) i;
        return -1;
    }

    /++
    The single element of `collection` that is a `T` (R4: Spring's `Class<T>` parameter), or `T.init` when there
    is none or more than one. For class types the test is a dynamic cast; for other types, `E` converting to `T`.
    +/
    static T findValueOfType(T, E)(Collection!E collection)
    {
        if (isEmpty(collection))
            return T.init;
        T value = T.init;
        bool found;
        foreach (element; collection.toArray())
        {
            T candidate;
            if (!asType(element, candidate))
                continue;
            if (found && !isNullValue(value))
                return T.init;
            value = candidate;
            found = true;
        }
        return value;
    }

    private static bool asType(T, E)(E element, out T result)
    {
        static if ((is(T == class) || is(T == interface)) && (is(E == class) || is(E == interface)))
        {
            result = cast(T) element;
            return result !is null;
        }
        else static if (is(E : T))
        {
            result = element;
            return true;
        }
        else
            return false;
    }

    /// Whether `collection` contains only one distinct instance (identity), possibly several times.
    static bool hasUniqueObject(T)(Collection!T collection)
    {
        if (isEmpty(collection))
            return false;
        auto elements = collection.toArray();
        foreach (element; elements[1 .. $])
            if (!sameInstance(element, elements[0]))
                return false;
        return true;
    }

    /// The first element of `set` in iteration order, or `T.init` for a null or empty set.
    static T firstElement(T)(Set!T set)
    {
        if (isEmpty(set))
            return T.init;
        return set.iterator().next();
    }

    /// The first element of `list`, or `T.init` for a null or empty list.
    static T firstElement(T)(List!T list)
    {
        if (isEmpty(list))
            return T.init;
        return list.get(0);
    }

    /// The last element of `set` in iteration order, or `T.init` for a null or empty set.
    static T lastElement(T)(Set!T set)
    {
        if (isEmpty(set))
            return T.init;
        auto elements = set.toArray();
        return elements[$ - 1];
    }

    /// The last element of `list`, or `T.init` for a null or empty list.
    static T lastElement(T)(List!T list)
    {
        if (isEmpty(list))
            return T.init;
        return list.get(list.size() - 1);
    }

    /// A `MultiValueMap` view of `targetMap`: changes to either show in the other.
    static MultiValueMap!(K, V) toMultiValueMap(K, V)(Map!(K, List!V) targetMap)
    {
        return new MultiValueMapAdapter!(K, V)(targetMap);
    }

    /// An unmodifiable view of `targetMap`; its lists are unmodifiable too.
    static MultiValueMap!(K, V) unmodifiableMultiValueMap(K, V)(MultiValueMap!(K, V) targetMap)
    {
        Assert.notNull(targetMap, "'targetMap' must not be null");
        if (cast(UnmodifiableMultiValueMap!(K, V)) targetMap !is null)
            return targetMap;
        return new UnmodifiableMultiValueMap!(K, V)(targetMap);
    }

    private static bool sameInstance(A, B)(A a, B b)
    {
        static if (is(B == typeof(null)))
            return isNullValue(a);
        else static if (is(typeof(a is b)))
            return a is b;
        else
            return false;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// MultiValueMap

/++
A `Map` from keys to lists of values. `addIfAbsent` is a default method in Java; implementors mix in
`MultiValueMap!(K, V).Defaults` (rulebook R3).
+/
interface MultiValueMap(K, V) : Map!(K, List!V)
{
    /// The first value for `key`, or `V.init` (null) when there is none.
    V getFirst(K key);

    /// Add `value` to the values of `key`.
    void add(K key, V value);

    /// Add all `values` to the values of `key`.
    void addAll(K key, List!V values);

    /// Add all values of `values`.
    void addAll(MultiValueMap!(K, V) values);

    /// `add(key, value)` only when `key` is not yet present.
    void addIfAbsent(K key, V value);

    /// Set `value` as the only value of `key`.
    void set(K key, V value);

    /// Set each entry of `values` as the only value of its key.
    void setAll(Map!(K, V) values);

    /// The first value of each key, as a new map; keys without values are left out.
    Map!(K, V) toSingleValueMap();

    /// Java's default methods, for implementors to mix in (R3).
    mixin template Defaults()
    {
        /// `add(key, value)` only when `key` is not yet present.
        void addIfAbsent(K key, V value)
        {
            if (!containsKey(key))
                add(key, value);
        }
    }

    /// A `MultiValueMap` view of `map`.
    static MultiValueMap!(K, V) fromMultiValue(Map!(K, List!V) map)
    {
        Assert.notNull(map, "Map must not be null");
        return new MultiValueMapAdapter!(K, V)(map);
    }
}

/// Adapts a `Map!(K, List!V)` to the `MultiValueMap` contract; changes write through to the target map.
class MultiValueMapAdapter(K, V) : MultiValueMap!(K, V)
{
    private Map!(K, List!V) targetMap;

    mixin MultiValueMap!(K, V).Defaults;

    /// An adapter over `targetMap`.
    this(Map!(K, List!V) targetMap)
    {
        Assert.notNull(targetMap, "'targetMap' must not be null");
        this.targetMap = targetMap;
    }

    /// The first value for `key`, or `V.init`.
    V getFirst(K key)
    {
        auto values = targetMap.get(key);
        return !CollectionUtils.isEmpty(values) ? values.get(0) : V.init;
    }

    /// Add `value` to the values of `key`.
    void add(K key, V value)
    {
        auto values = targetMap.computeIfAbsent(key, &newValueList);
        values.add(value);
    }

    /// Add all `values` to the values of `key`.
    void addAll(K key, List!V values)
    {
        auto currentValues = targetMap.computeIfAbsent(key, &newValueList);
        currentValues.addAll(values);
    }

    private List!V newValueList(K)
    {
        return new ArrayList!V();
    }

    /// Add all values of `values`.
    void addAll(MultiValueMap!(K, V) values)
    {
        values.forEach((K key, List!V list) { addAll(key, list); });
    }

    /// Set `value` as the only value of `key`.
    void set(K key, V value)
    {
        auto values = new ArrayList!V();
        values.add(value);
        targetMap.put(key, values);
    }

    /// Set each entry of `values` as the only value of its key.
    void setAll(Map!(K, V) values)
    {
        values.forEach((K key, V value) { set(key, value); });
    }

    /// The first value of each key, as a new insertion-ordered map.
    Map!(K, V) toSingleValueMap()
    {
        auto singleValueMap = new LinkedHashMap!(K, V)();
        targetMap.forEach((K key, List!V values) {
            if (!CollectionUtils.isEmpty(values))
                singleValueMap.put(key, values.get(0));
        });
        return singleValueMap;
    }

    /// The number of keys.
    int size()
    {
        return targetMap.size();
    }

    /// Whether there are no keys.
    bool isEmpty()
    {
        return targetMap.isEmpty();
    }

    /// Whether `key` is present.
    bool containsKey(K key)
    {
        return targetMap.containsKey(key);
    }

    /// Whether some key maps to `value`.
    bool containsValue(List!V value)
    {
        return targetMap.containsValue(value);
    }

    /// The values of `key`, or null.
    List!V get(K key)
    {
        return targetMap.get(key);
    }

    /// The values of `key`, or `defaultValue`.
    List!V getOrDefault(K key, List!V defaultValue)
    {
        return targetMap.getOrDefault(key, defaultValue);
    }

    /// Map `key` to `value`; the previous values.
    List!V put(K key, List!V value)
    {
        return targetMap.put(key, value);
    }

    /// Map `key` to `value` unless it is present; the existing values.
    List!V putIfAbsent(K key, List!V value)
    {
        return targetMap.putIfAbsent(key, value);
    }

    /// Remove `key`; the previous values.
    List!V remove(K key)
    {
        return targetMap.remove(key);
    }

    /// Copy every entry of `map`.
    void putAll(Map!(K, List!V) map)
    {
        targetMap.putAll(map);
    }

    /// Remove every entry.
    void clear()
    {
        targetMap.clear();
    }

    /// The keys.
    Set!K keySet()
    {
        return targetMap.keySet();
    }

    /// The value lists.
    Collection!(List!V) values()
    {
        return targetMap.values();
    }

    /// The entries.
    Set!(MapEntry!(K, List!V)) entrySet()
    {
        return targetMap.entrySet();
    }

    /// Call `action` for each key and its values.
    void forEach(void delegate(K, List!V) @safe action)
    {
        targetMap.forEach(action);
    }

    /// The values of `key`, computed and stored with `mappingFunction` when absent.
    List!V computeIfAbsent(K key, List!V delegate(K) @safe mappingFunction)
    {
        return targetMap.computeIfAbsent(key, mappingFunction);
    }

    /// Store `value`, or `remapping(old, value)` when `key` is present.
    List!V merge(K key, List!V value, List!V delegate(List!V, List!V) @safe remapping)
    {
        return targetMap.merge(key, value, remapping);
    }

    /// The keys, erased.
    Any[] keysAsAny()
    {
        return targetMap.keysAsAny();
    }

    /// The values of an erased key.
    Any getAny(Any key)
    {
        return targetMap.getAny(key);
    }

    /// Map an erased key to erased values.
    void putAny(Any key, Any value)
    {
        targetMap.putAny(key, value);
    }

    /// The key type's name.
    string keyTypeName()
    {
        return targetMap.keyTypeName();
    }

    /// The value type's name.
    string valueTypeName()
    {
        return targetMap.valueTypeName();
    }

    /// Java's `equals`: the same mappings as `other`.
    bool equals(Object other)
    {
        return this is other || targetMap.equals(other);
    }

    /// Java's `hashCode`.
    int hashCode()
    {
        return targetMap.hashCode();
    }

    /// `==` calls `equals`.
    override bool opEquals(Object other)
    {
        return equals(other);
    }

    /// Associative arrays call `hashCode`.
    override size_t toHash() @safe nothrow
    {
        try
            return cast(uint) hashCode();
        catch (Exception)
            return 0;
    }

    /// `{k1=[v1, v2], k2=[v3]}`.
    override string toString()
    {
        return targetMap.toString();
    }
}

/// A `MultiValueMap` over a `LinkedHashMap`: keys iterate in insertion order.
class LinkedMultiValueMap(K, V) : MultiValueMapAdapter!(K, V)
{
    /// An empty map.
    this()
    {
        super(new LinkedHashMap!(K, List!V)());
    }

    /// An empty map sized for `expectedSize` keys.
    this(int expectedSize)
    {
        super(CollectionUtils.newLinkedHashMap!(K, List!V)(expectedSize));
    }

    /// A shallow copy of `otherMap`: the value lists are shared.
    this(Map!(K, List!V) otherMap)
    {
        super(new LinkedHashMap!(K, List!V)(otherMap));
    }

    /// A deep copy: each value list is copied.
    LinkedMultiValueMap!(K, V) deepCopy()
    {
        auto copy = new LinkedMultiValueMap!(K, V)(size());
        forEach((K key, List!V values) { copy.put(key, new ArrayList!V(values)); });
        return copy;
    }

    /// A shallow copy (Java's `clone`).
    LinkedMultiValueMap!(K, V) clone()
    {
        return new LinkedMultiValueMap!(K, V)(this);
    }
}

/// An unmodifiable view of a `MultiValueMap`: every mutator throws `UnsupportedOperationException`.
private final class UnmodifiableMultiValueMap(K, V) : MultiValueMap!(K, V)
{
    private MultiValueMap!(K, V) delegate_;

    this(MultiValueMap!(K, V) delegate_)
    {
        Assert.notNull(delegate_, "Delegate must not be null");
        this.delegate_ = delegate_;
    }

    V getFirst(K key)
    {
        return delegate_.getFirst(key);
    }

    void add(K, V)
    {
        throw new UnsupportedOperationException();
    }

    void addAll(K, List!V)
    {
        throw new UnsupportedOperationException();
    }

    void addAll(MultiValueMap!(K, V))
    {
        throw new UnsupportedOperationException();
    }

    void addIfAbsent(K, V)
    {
        throw new UnsupportedOperationException();
    }

    void set(K, V)
    {
        throw new UnsupportedOperationException();
    }

    void setAll(Map!(K, V))
    {
        throw new UnsupportedOperationException();
    }

    Map!(K, V) toSingleValueMap()
    {
        return Collections.unmodifiableMap(delegate_.toSingleValueMap());
    }

    int size()
    {
        return delegate_.size();
    }

    bool isEmpty()
    {
        return delegate_.isEmpty();
    }

    bool containsKey(K key)
    {
        return delegate_.containsKey(key);
    }

    bool containsValue(List!V value)
    {
        return delegate_.containsValue(value);
    }

    List!V get(K key)
    {
        auto result = delegate_.get(key);
        return result is null ? null : Collections.unmodifiableList(result);
    }

    List!V getOrDefault(K key, List!V defaultValue)
    {
        auto result = delegate_.getOrDefault(key, defaultValue);
        return result is null || result is defaultValue ? result : Collections.unmodifiableList(result);
    }

    List!V put(K, List!V)
    {
        throw new UnsupportedOperationException();
    }

    List!V putIfAbsent(K, List!V)
    {
        throw new UnsupportedOperationException();
    }

    List!V remove(K)
    {
        throw new UnsupportedOperationException();
    }

    void putAll(Map!(K, List!V))
    {
        throw new UnsupportedOperationException();
    }

    void clear()
    {
        throw new UnsupportedOperationException();
    }

    Set!K keySet()
    {
        return Collections.unmodifiableSet(delegate_.keySet());
    }

    Collection!(List!V) values()
    {
        auto result = new ArrayList!(List!V)();
        foreach (list; delegate_.values().toArray())
            result.add(list is null ? null : Collections.unmodifiableList(list));
        return Collections.unmodifiableList!(List!V)(result);
    }

    Set!(MapEntry!(K, List!V)) entrySet()
    {
        auto result = new LinkedHashSet!(MapEntry!(K, List!V))();
        delegate_.forEach((K key, List!V list) {
            result.add(new MapEntry!(K, List!V)(key, list is null ? null : Collections.unmodifiableList(list), this));
        });
        return Collections.unmodifiableSet!(MapEntry!(K, List!V))(result);
    }

    void forEach(void delegate(K, List!V) @safe action)
    {
        delegate_.forEach((K key, List!V list) {
            action(key, list is null ? null : Collections.unmodifiableList(list));
        });
    }

    List!V computeIfAbsent(K, List!V delegate(K) @safe)
    {
        throw new UnsupportedOperationException();
    }

    List!V merge(K, List!V, List!V delegate(List!V, List!V) @safe)
    {
        throw new UnsupportedOperationException();
    }

    Any[] keysAsAny()
    {
        return delegate_.keysAsAny();
    }

    Any getAny(Any key)
    {
        return delegate_.getAny(key);
    }

    void putAny(Any, Any)
    {
        throw new UnsupportedOperationException();
    }

    string keyTypeName()
    {
        return delegate_.keyTypeName();
    }

    string valueTypeName()
    {
        return delegate_.valueTypeName();
    }

    bool equals(Object other)
    {
        return this is other || delegate_.equals(other);
    }

    int hashCode()
    {
        return delegate_.hashCode();
    }

    override bool opEquals(Object other)
    {
        return equals(other);
    }

    override size_t toHash() @safe nothrow
    {
        try
            return cast(uint) hashCode();
        catch (Exception)
            return 0;
    }

    override string toString()
    {
        return delegate_.toString();
    }
}

// ---------------------------------------------------------------------------------------------------------------
// PatternMatchUtils

/// Utility methods for simple pattern matching, in particular for Spring's typical `xxx*`, `*xxx`, `*xxx*` and
/// `xxx*yyy` styles (with an arbitrary number of pattern parts).
abstract class PatternMatchUtils
{
    /// Whether `str` matches `pattern`, where `*` matches any run of characters. False when either is null.
    static bool simpleMatch(string pattern, string str)
    {
        return simpleMatch(pattern, str, false);
    }

    /// ditto, ignoring case.
    static bool simpleMatchIgnoreCase(string pattern, string str)
    {
        return simpleMatch(pattern, str, true);
    }

    /// Whether `str` matches any of `patterns`.
    static bool simpleMatch(const(string)[] patterns, string str)
    {
        foreach (pattern; patterns)
            if (simpleMatch(pattern, str, false))
                return true;
        return false;
    }

    /// ditto, ignoring case.
    static bool simpleMatchIgnoreCase(const(string)[] patterns, string str)
    {
        foreach (pattern; patterns)
            if (simpleMatch(pattern, str, true))
                return true;
        return false;
    }

    private static bool simpleMatch(string pattern, string str, bool ignoreCase)
    {
        if (pattern is null || str is null)
            return false;
        const firstIndex = indexOfChar(pattern, '*');
        if (firstIndex == -1)
            return ignoreCase ? equalsIgnoreCase(pattern, str) : pattern == str;
        if (firstIndex == 0)
            return matchLeadingStar(pattern, str, ignoreCase);
        const prefixLength = prefixMatchLength(pattern[0 .. firstIndex], str, ignoreCase);
        return prefixLength >= 0 && simpleMatch(pattern[firstIndex .. $], str[prefixLength .. $], ignoreCase);
    }

    private static bool matchLeadingStar(string pattern, string str, bool ignoreCase)
    {
        if (pattern.length == 1)
            return true;
        const nextIndex = indexOfFrom(pattern, "*", 1);
        if (nextIndex == -1)
        {
            const part = pattern[1 .. $];
            return ignoreCase ? StringUtils.endsWithIgnoreCase(str, part) : hasSuffix(str, part);
        }
        const part = pattern[1 .. nextIndex];
        if (part.length == 0)
            return simpleMatch(pattern[nextIndex .. $], str, ignoreCase);
        size_t from;
        while (from <= str.length)
        {
            ptrdiff_t matchEnd;
            const partIndex = indexOf(str, part, from, ignoreCase, matchEnd);
            if (partIndex == -1)
                return false;
            if (simpleMatch(pattern[nextIndex .. $], str[matchEnd .. $], ignoreCase))
                return true;
            size_t next = partIndex;
            skipCodePoint(str, next);
            from = next;
        }
        return false;
    }

    /// The byte length in `str` of a prefix matching `prefix` character for character, or -1.
    private static ptrdiff_t prefixMatchLength(string prefix, string str, bool ignoreCase)
    {
        if (ignoreCase)
            return matchIgnoreCaseAt(str, 0, prefix);
        return hasPrefix(str, prefix) ? cast(ptrdiff_t) prefix.length : -1;
    }

    private static ptrdiff_t indexOf(string str, string otherStr, size_t startIndex,
            bool ignoreCase, out ptrdiff_t matchEnd)
    {
        if (!ignoreCase)
        {
            const index = indexOfFrom(str, otherStr, startIndex);
            matchEnd = index < 0 ? -1 : index + otherStr.length;
            return index;
        }
        size_t i = startIndex;
        while (i < str.length)
        {
            matchEnd = matchIgnoreCaseAt(str, i, otherStr);
            if (matchEnd >= 0)
                return cast(ptrdiff_t) i;
            skipCodePoint(str, i);
        }
        return -1;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// NumberUtils

/// Whether `T` is one of Java's standard primitive number types: `byte`, `short`, `int`, `long`, `float`, `double`.
private enum isStandardNumber(T) = is(T == byte) || is(T == short) || is(T == int) || is(T == long)
    || is(T == float) || is(T == double);

/++
Miscellaneous utility methods for number conversion and parsing. The `Class<T>` parameters are template parameters
(R4); the target types are D's `byte`, `short`, `int`, `long`, `float` and `double` (`BigInteger`, `BigDecimal`
and `NumberFormat` are not ported).
+/
abstract class NumberUtils
{
    /++
    Convert `number` to `T`, raising `IllegalArgumentException` with Spring's message ("...: overflow") when the
    value does not fit. Floating-point values convert to integral types by truncation, and NaN or infinite values
    overflow.
    +/
    static T convertNumberToTargetClass(T, N)(N number)
            if (isStandardNumber!T && __traits(isArithmetic, N))
    {
        import std.traits : Unqual;

        static if (is(Unqual!N == T))
            return number;
        else static if (__traits(isIntegral, T))
        {
            const value = checkedLongValue!T(number);
            static if (!is(T == long))
                if (value < T.min || value > T.max)
                    raiseOverflowException!T(number);
            return cast(T) value;
        }
        else
            return cast(T) number;
    }

    private static long checkedLongValue(T, N)(N number)
    {
        static if (__traits(isFloating, N))
        {
            // Also rejecting NaN and infinite values.
            if (!(number >= -0x1p63 && number < 0x1p63))
                raiseOverflowException!T(number);
            return cast(long) number;
        }
        else static if (is(N == ulong))
        {
            if (number > long.max)
                raiseOverflowException!T(number);
            return cast(long) number;
        }
        else
            return number;
    }

    private static void raiseOverflowException(T, N)(N number)
    {
        throw new IllegalArgumentException("Could not convert number [" ~ numberText(
                number) ~ "] of type [" ~ javaTypeName!N ~ "] to target class [" ~ javaTypeName!T ~ "]: overflow");
    }

    private static string numberText(N)(N number)
    {
        static if (is(N == float))
            return javaFloatingText(number, true);
        else static if (__traits(isFloating, N))
            return javaFloatingText(number, false);
        else
            return valueOf(number);
    }

    /++
    Parse `text` into a `T` after removing all whitespace. Integral types use Java's `decode` for hexadecimal text
    (`0x`, `0X` or `#` after an optional sign) and `valueOf` otherwise, so a leading `0` stays decimal; digits are
    ASCII. Floating-point types accept Java's `Float.valueOf`/`Double.valueOf` syntax. Throws
    `NumberFormatException` (an `IllegalArgumentException`) with Java's messages.
    +/
    static T parseNumber(T)(string text) if (isStandardNumber!T)
    {
        Assert.notNull(text, "Text must not be null");
        const trimmed = StringUtils.trimAllWhitespace(text);
        static if (__traits(isFloating, T))
            return parseFloating!T(trimmed);
        else static if (is(T == long))
            return isHexNumber(trimmed) ? decode(trimmed, long.min, long.max) : parseJava(trimmed,
                    10, long.min, long.max);
        else static if (is(T == int))
            return cast(int)(isHexNumber(trimmed) ? decode(trimmed, int.min,
                    int.max) : parseJava(trimmed, 10, int.min, int.max));
        else
            return cast(T) parseSmall(trimmed, T.min, T.max);
    }

    /// Java's `Byte.valueOf`/`Short.valueOf` and `Byte.decode`/`Short.decode`.
    private static long parseSmall(string trimmed, long min, long max)
    {
        import flint.engine.aot.text : decimal;

        if (isHexNumber(trimmed))
        {
            const value = decode(trimmed, int.min, int.max);
            if (value < min || value > max)
                throw new NumberFormatException("Value " ~ decimal(value) ~ " out of range from input " ~ trimmed);
            return value;
        }
        const value = parseJava(trimmed, 10, int.min, int.max);
        if (value < min || value > max)
            throw new NumberFormatException("Value out of range. Value:\"" ~ trimmed ~ "\" Radix:10");
        return value;
    }

    private static bool isHexNumber(string value) pure nothrow @nogc
    {
        const index = hasPrefix(value, "-") || hasPrefix(value, "+") ? 1 : 0;
        const rest = value[index .. $];
        return hasPrefix(rest, "0x") || hasPrefix(rest, "0X") || hasPrefix(rest, "#");
    }

    /// Java's `Integer.decode`/`Long.decode` within `[min, max]`.
    private static long decode(string nm, long min, long max)
    {
        if (nm.length == 0)
            throw new NumberFormatException("Zero length string");
        int radix = 10;
        size_t index;
        const negative = nm[0] == '-';
        if (nm[0] == '-' || nm[0] == '+')
            index++;
        const rest = nm[index .. $];
        if (hasPrefix(rest, "0x") || hasPrefix(rest, "0X"))
        {
            index += 2;
            radix = 16;
        }
        else if (hasPrefix(rest, "#"))
        {
            index++;
            radix = 16;
        }
        else if (hasPrefix(rest, "0") && nm.length > 1 + index)
        {
            index++;
            radix = 8;
        }
        if (hasPrefix(nm[index .. $], "-") || hasPrefix(nm[index .. $], "+"))
            throw new NumberFormatException("Sign character in wrong position");
        return parseJava(negative ? "-" ~ nm[index .. $] : nm[index .. $], radix, min, max);
    }

    /// Java's `Integer.parseInt`/`Long.parseLong` within `[min, max]`.
    private static long parseJava(string s, int radix, long min, long max)
    {
        import flint.engine.aot.text : decimal;

        const failure = "For input string: \"" ~ s ~ "\"" ~ (radix == 10 ? "" : " under radix " ~ decimal(
                cast(long) radix));
        if (s.length == 0)
            throw new NumberFormatException(failure);
        size_t i;
        const negative = s[0] == '-';
        if (s[0] == '-' || s[0] == '+')
            i = 1;
        if (i == s.length)
            throw new NumberFormatException(failure);
        // Accumulate negatively so that the minimum parses, as Java does.
        long result;
        const limit = negative ? min : -max;
        for (; i < s.length; i++)
        {
            const digit = digitValue(s[i]);
            if (digit < 0 || digit >= radix || result < limit / radix || result * radix < limit + digit)
                throw new NumberFormatException(failure);
            result = result * radix - digit;
        }
        return negative ? result : -result;
    }

    private static int digitValue(char c) pure nothrow @nogc
    {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'z')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'Z')
            return c - 'A' + 10;
        return -1;
    }

    /// Java's `Float.valueOf`/`Double.valueOf`.
    private static T parseFloating(T)(string s)
    {
        import flint.engine.aot.text : tryParseDouble, tryParseFloat;

        if (s.length == 0)
            throw new NumberFormatException("empty String");
        T special;
        if (parseSpecialFloating(s, special))
            return special;
        string body = s;
        if (hasSuffix(body, "f") || hasSuffix(body, "F") || hasSuffix(body, "d") || hasSuffix(body, "D"))
            body = body[0 .. $ - 1];
        const unsigned = hasPrefix(body, "-") || hasPrefix(body, "+") ? body[1 .. $] : body;
        if (!isJavaFloatingSyntax(unsigned))
            throw NumberFormatException.forInputString(s);
        static if (is(T == float))
            const parsed = tryParseFloat(body);
        else
            const parsed = tryParseDouble(body);
        if (!parsed.ok)
            throw NumberFormatException.forInputString(s);
        return parsed.value;
    }

    /// Java's `NaN` and `Infinity`, with an optional sign and no type suffix.
    private static bool parseSpecialFloating(T)(string s, out T result) pure nothrow @nogc
    {
        const unsigned = hasPrefix(s, "-") || hasPrefix(s, "+") ? s[1 .. $] : s;
        if (unsigned == "NaN")
            result = T.nan;
        else if (unsigned == "Infinity")
            result = s[0] == '-' ? -T.infinity : T.infinity;
        else
            return false;
        return true;
    }

    /// Whether `s` (without sign and suffix) is a decimal or hexadecimal floating-point literal.
    private static bool isJavaFloatingSyntax(string s) pure nothrow @nogc
    {
        if (hasPrefix(s, "0x") || hasPrefix(s, "0X"))
            return hexFloatingSyntax(s[2 .. $]);
        size_t i;
        const whole = skipDigits(s, i);
        size_t fraction;
        if (i < s.length && s[i] == '.')
        {
            i++;
            fraction = skipDigits(s, i);
        }
        if (whole + fraction == 0)
            return false;
        if (i < s.length && (s[i] == 'e' || s[i] == 'E'))
        {
            i++;
            if (i < s.length && (s[i] == '+' || s[i] == '-'))
                i++;
            if (skipDigits(s, i) == 0)
                return false;
        }
        return i == s.length;
    }

    private static bool hexFloatingSyntax(string s) pure nothrow @nogc
    {
        size_t i;
        size_t digits;
        while (i < s.length && (isHexDigit(s[i]) || s[i] == '.'))
        {
            if (s[i] != '.')
                digits++;
            i++;
        }
        if (digits == 0 || i == s.length || (s[i] != 'p' && s[i] != 'P'))
            return false;
        i++;
        if (i < s.length && (s[i] == '+' || s[i] == '-'))
            i++;
        return skipDigits(s, i) > 0 && i == s.length;
    }

    private static bool isHexDigit(char c) pure nothrow @nogc
    {
        const digit = digitValue(c);
        return digit >= 0 && digit < 16;
    }

    private static size_t skipDigits(string s, ref size_t i) pure nothrow @nogc
    {
        const start = i;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
            i++;
        return i - start;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// StringValueResolver

/// Simple strategy interface for resolving a string value, used by bean factories for placeholders.
interface StringValueResolver
{
    /// Resolve `strVal`: a placeholder or SpEL expression, for example. Null to skip the value.
    string resolveStringValue(string strVal);
}

// ---------------------------------------------------------------------------------------------------------------
// Placeholders

/++
Thrown when the resolution of placeholders failed: an unresolvable placeholder or a circular reference. The message
names the failing placeholder, then the chain of values being resolved, innermost first.
+/
class PlaceholderResolutionException : IllegalArgumentException
{
    private string reason;
    private string placeholder;
    private string[] values;

    /// An exception for `placeholder` while resolving `value` (null when there is no value yet).
    package this(string reason, string placeholder, string value)
    {
        this(reason, placeholder, value is null ? null : [value], 0);
    }

    private this(string reason, string placeholder, string[] values, int)
    {
        super(buildMessage(reason, values));
        this.reason = reason;
        this.placeholder = placeholder;
        this.values = values;
    }

    private static string buildMessage(string reason, string[] values)
    {
        string message = reason;
        if (values.length)
        {
            string chain;
            foreach (i, value; values)
                chain ~= (i ? " <-- " : "") ~ "\"" ~ value ~ "\"";
            message ~= " in value " ~ chain;
        }
        return message;
    }

    /// A copy with `value` appended to the chain of values.
    package PlaceholderResolutionException withValue(string value)
    {
        return new PlaceholderResolutionException(reason, placeholder, values ~ value, 0);
    }

    /// The placeholder that failed to resolve.
    string getPlaceholder()
    {
        return placeholder;
    }

    /// The chain of values that contained the placeholder, innermost first.
    List!string getValues()
    {
        return Collections.unmodifiableList!string(new ArrayList!string(values));
    }
}

/++
Utility for working with strings that have placeholder values, such as `${name}`. Values for substitution come from
a `PlaceholderResolver`, a `string delegate(string) @safe` (R9) or a map (adapted R10: Spring's `Properties`).

Placeholders may nest (`${first${nested}}`), have a default after the value separator (`${name:default}`), and be
escaped with the escape character (`\${name}`). A resolver returns null for an unknown placeholder; an empty
string is a value.
+/
class PropertyPlaceholderHelper
{
    private PlaceholderParser parser;

    /// A helper with `placeholderPrefix` and `placeholderSuffix`, no separator and no escape character, that
    /// ignores unresolvable placeholders.
    this(string placeholderPrefix, string placeholderSuffix)
    {
        this(placeholderPrefix, placeholderSuffix, null, null, true);
    }

    /// A helper with a value separator (null for none) and an escape character.
    this(string placeholderPrefix, string placeholderSuffix, string valueSeparator,
            dchar escapeCharacter, bool ignoreUnresolvablePlaceholders)
    {
        Assert.notNull(placeholderPrefix, "'placeholderPrefix' must not be null");
        Assert.notNull(placeholderSuffix, "'placeholderSuffix' must not be null");
        parser = new PlaceholderParser(placeholderPrefix, placeholderSuffix, valueSeparator,
                escapeCharacter, ignoreUnresolvablePlaceholders);
    }

    /// A helper with a value separator (null for none) and no escape character (Java's null `Character`).
    this(string placeholderPrefix, string placeholderSuffix, string valueSeparator, typeof(null),
            bool ignoreUnresolvablePlaceholders)
    {
        Assert.notNull(placeholderPrefix, "'placeholderPrefix' must not be null");
        Assert.notNull(placeholderSuffix, "'placeholderSuffix' must not be null");
        parser = new PlaceholderParser(placeholderPrefix, placeholderSuffix, valueSeparator, null,
                ignoreUnresolvablePlaceholders);
    }

    /// Replace all placeholders in `value` with the values of `properties` (adapted R10: Spring's `Properties`).
    string replacePlaceholders(string value, Map!(string, string) properties)
    {
        Assert.notNull(properties, "'properties' must not be null");
        return replacePlaceholders(value, (string name) => properties.get(name));
    }

    /// Replace all placeholders in `value` with the values `placeholderResolver` returns.
    string replacePlaceholders(string value, PlaceholderResolver placeholderResolver)
    {
        Assert.notNull(placeholderResolver, "'placeholderResolver' must not be null");
        return replacePlaceholders(value, &placeholderResolver.resolvePlaceholder);
    }

    /// ditto, with a delegate (R9).
    string replacePlaceholders(string value, string delegate(string) @safe placeholderResolver)
    {
        Assert.notNull(value, "'value' must not be null");
        return parser.replacePlaceholders(value, placeholderResolver);
    }

    /// Strategy interface used to resolve replacement values for placeholders contained in strings.
    interface PlaceholderResolver
    {
        /// The replacement value for `placeholderName`, or null when no replacement is to be made.
        string resolvePlaceholder(string placeholderName);
    }
}

/++
Parses values that may contain placeholders (package-private in Spring). Indices are UTF-8 byte offsets; the
escape character is a code point and is removed by its encoded length (R14).
+/
package final class PlaceholderParser
{
    private string prefix;
    private string suffix;
    private string simplePrefix;
    private string separator;
    private bool ignoreUnresolvablePlaceholders;
    private bool hasEscape;
    private dchar escape;

    /// A parser with an escape character.
    package this(string prefix, string suffix, string separator, dchar escape, bool ignoreUnresolvablePlaceholders)
    {
        this(prefix, suffix, separator, null, ignoreUnresolvablePlaceholders);
        this.hasEscape = true;
        this.escape = escape;
    }

    /// A parser without an escape character.
    package this(string prefix, string suffix, string separator, typeof(null), bool ignoreUnresolvablePlaceholders)
    {
        this.prefix = prefix;
        this.suffix = suffix;
        const simplePrefixForSuffix = wellKnownSimplePrefix(suffix);
        simplePrefix = simplePrefixForSuffix !is null && hasSuffix(prefix, simplePrefixForSuffix)
            ? simplePrefixForSuffix : prefix;
        this.separator = separator;
        this.ignoreUnresolvablePlaceholders = ignoreUnresolvablePlaceholders;
    }

    private static string wellKnownSimplePrefix(string suffix) pure nothrow @nogc
    {
        switch (suffix)
        {
        case "}":
            return "{";
        case "]":
            return "[";
        case ")":
            return "(";
        default:
            return null;
        }
    }

    /// Replace the placeholders in `value` using `placeholderResolver`.
    package string replacePlaceholders(string value, PropertyPlaceholderHelper.PlaceholderResolver placeholderResolver)
    {
        return replacePlaceholders(value, &placeholderResolver.resolvePlaceholder);
    }

    /// ditto, with a delegate.
    package string replacePlaceholders(string value, string delegate(string) @safe placeholderResolver)
    {
        auto parts = parse(value, false);
        if (parts is null)
            return value;
        auto context = new PartResolutionContext(placeholderResolver, prefix, suffix,
                ignoreUnresolvablePlaceholders, (string candidate) => parse(candidate, false));
        return resolveParsedValue(value, parts, context);
    }

    private Part[] parse(string value, bool inPlaceholder)
    {
        ptrdiff_t startIndex = indexOfString(value, prefix);
        if (startIndex == -1)
            return null;
        Part[] parts;
        size_t position;
        while (startIndex != -1)
        {
            const endIndex = nextValidEndPrefix(value, startIndex);
            if (endIndex == -1)
            {
                // Not a valid placeholder: consume the prefix and continue.
                addText(value, position, startIndex + prefix.length, parts);
                position = startIndex + prefix.length;
                startIndex = indexOfFrom(value, prefix, position);
            }
            else if (isEscaped(value, startIndex))
            {
                // Escaped: accumulate the prefix without the escape character.
                addText(value, position, startIndex - escapeLength(), parts);
                addText(value, startIndex, startIndex + prefix.length, parts);
                position = startIndex + prefix.length;
                startIndex = indexOfFrom(value, prefix, position);
            }
            else
            {
                addText(value, position, startIndex, parts);
                const placeholder = value[startIndex + prefix.length .. endIndex];
                auto placeholderParts = parse(placeholder, true);
                if (placeholderParts is null)
                    parts ~= createSimplePlaceholderPart(placeholder);
                else
                    parts ~= placeholderParts;
                startIndex = indexOfFrom(value, prefix, endIndex + suffix.length);
                position = endIndex + suffix.length;
            }
        }
        addText(value, position, value.length, parts);
        return inPlaceholder ? [createNestedPlaceholderPart(value, parts)] : parts;
    }

    private Part createSimplePlaceholderPart(string text)
    {
        string fallback;
        const key = parseSection(text, fallback);
        return new SimplePlaceholderPart(text, key, fallback);
    }

    private Part createNestedPlaceholderPart(string text, Part[] parts)
    {
        if (separator is null)
            return new NestedPlaceholderPart(text, parts, null);
        Part[] keyParts;
        foreach (i, part; parts)
        {
            auto textPart = cast(TextPart) part;
            if (textPart is null)
            {
                keyParts ~= part;
                continue;
            }
            string fallback;
            keyParts ~= new TextPart(parseSection(textPart.text, fallback));
            if (fallback !is null)
            {
                Part[] defaultParts = [new TextPart(fallback)];
                defaultParts ~= parts[i + 1 .. $];
                return new NestedPlaceholderPart(text, keyParts, defaultParts);
            }
        }
        return new NestedPlaceholderPart(text, keyParts, null);
    }

    /// The key of `value`, with the text after the first unescaped separator in `fallback` (null when none).
    private string parseSection(string value, out string fallback)
    {
        fallback = null;
        if (separator is null || indexOfString(value, separator) < 0)
            return value;
        size_t position;
        ptrdiff_t index = indexOfString(value, separator);
        string buffer;
        while (index != -1)
        {
            if (isEscaped(value, index))
            {
                // Accumulate, without the escape character.
                buffer ~= value[position .. index - escapeLength()];
                buffer ~= value[index .. index + separator.length];
                position = index + separator.length;
                index = indexOfFrom(value, separator, position);
            }
            else
            {
                buffer ~= value[position .. index];
                fallback = value[index + separator.length .. $];
                return buffer;
            }
        }
        return buffer ~ value[position .. $];
    }

    private ptrdiff_t nextValidEndPrefix(string value, size_t startIndex)
    {
        size_t index = startIndex + prefix.length;
        int withinNestedPlaceholder;
        while (index < value.length)
        {
            if (substringMatchAt(value, index, suffix))
            {
                if (withinNestedPlaceholder == 0)
                    return cast(ptrdiff_t) index;
                withinNestedPlaceholder--;
                index += suffix.length;
            }
            else if (substringMatchAt(value, index, simplePrefix))
            {
                withinNestedPlaceholder++;
                index += simplePrefix.length;
            }
            else
                index++;
        }
        return -1;
    }

    private bool isEscaped(string value, size_t index)
    {
        return hasEscape && index > 0 && codePointBefore(value, index) == escape;
    }

    private size_t escapeLength()
    {
        import flint.engine.aot.text : utf8Length;

        return utf8Length(escape);
    }

    private static void addText(string value, size_t start, size_t end, ref Part[] parts)
    {
        if (start >= end)
            return;
        const text = value[start .. end];
        if (parts.length)
            if (auto textPart = cast(TextPart) parts[$ - 1])
            {
                parts[$ - 1] = new TextPart(textPart.text ~ text);
                return;
            }
        parts ~= new TextPart(text);
    }
}

/// Resolve `parts` of `text`, adding `text` to the chain of a `PlaceholderResolutionException`.
private string resolveParsedValue(string text, Part[] parts, PartResolutionContext context)
{
    try
        return resolveAll(parts, context);
    catch (PlaceholderResolutionException ex)
        throw ex.withValue(text);
}

private string resolveAll(Part[] parts, PartResolutionContext context)
{
    string result;
    foreach (part; parts)
        result ~= part.resolve(context);
    return result;
}

private final class PartResolutionContext
{
    private string prefix;
    private string suffix;
    private bool ignoreUnresolvablePlaceholders;
    private Part[]delegate(string) @safe parser;
    private string delegate(string) @safe resolver;
    private bool[string] visitedPlaceholders;

    this(string delegate(string) @safe resolver, string prefix, string suffix,
            bool ignoreUnresolvablePlaceholders, Part[]delegate(string) @safe parser)
    {
        this.prefix = prefix;
        this.suffix = suffix;
        this.ignoreUnresolvablePlaceholders = ignoreUnresolvablePlaceholders;
        this.parser = parser;
        this.resolver = resolver;
    }

    string resolvePlaceholder(string placeholderName)
    {
        return resolver(placeholderName);
    }

    string handleUnresolvablePlaceholder(string key, string text)
    {
        if (ignoreUnresolvablePlaceholders)
            return toPlaceholderText(key);
        const originalValue = key != text ? toPlaceholderText(text) : null;
        throw new PlaceholderResolutionException("Could not resolve placeholder '" ~ key ~ "'", key, originalValue);
    }

    private string toPlaceholderText(string text)
    {
        return prefix ~ text ~ suffix;
    }

    Part[] parse(string text)
    {
        return parser(text);
    }

    void flagPlaceholderAsVisited(string placeholder)
    {
        if (placeholder in visitedPlaceholders)
            throw new PlaceholderResolutionException("Circular placeholder reference '" ~ placeholder ~ "'",
                    placeholder, null);
        visitedPlaceholders[placeholder] = true;
    }

    void removePlaceholder(string placeholder)
    {
        visitedPlaceholders.remove(placeholder);
    }
}

private abstract class Part
{
    string text;

    this(string text)
    {
        this.text = text;
    }

    abstract string resolve(PartResolutionContext context);

    /// The value of `key`, with placeholders in it resolved recursively; null when `key` is unknown.
    protected final string resolveRecursively(PartResolutionContext context, string key)
    {
        const resolvedValue = context.resolvePlaceholder(key);
        if (resolvedValue is null)
            return null;
        auto nestedParts = context.parse(resolvedValue);
        if (nestedParts is null)
            return resolvedValue;
        context.flagPlaceholderAsVisited(key);
        const value = resolveParsedValue(resolvedValue, nestedParts, context);
        context.removePlaceholder(key);
        return value;
    }
}

private final class TextPart : Part
{
    this(string text)
    {
        super(text);
    }

    override string resolve(PartResolutionContext)
    {
        return text;
    }
}

private final class SimplePlaceholderPart : Part
{
    private string key;
    private string fallback;

    this(string text, string key, string fallback)
    {
        super(text);
        this.key = key;
        this.fallback = fallback;
    }

    override string resolve(PartResolutionContext context)
    {
        const value = resolveKey(context);
        if (value !is null)
            return value;
        if (fallback !is null)
            return fallback;
        return context.handleUnresolvablePlaceholder(key, text);
    }

    private string resolveKey(PartResolutionContext context)
    {
        if (text != key)
        {
            const value = resolveRecursively(context, text);
            if (value !is null)
                return value;
        }
        return resolveRecursively(context, key);
    }
}

private final class NestedPlaceholderPart : Part
{
    private Part[] keyParts;
    private Part[] defaultParts;

    this(string text, Part[] keyParts, Part[] defaultParts)
    {
        super(text);
        this.keyParts = keyParts;
        this.defaultParts = defaultParts;
    }

    override string resolve(PartResolutionContext context)
    {
        const resolvedKey = resolveAll(keyParts, context);
        const value = resolveRecursively(context, resolvedKey);
        if (value !is null)
            return value;
        if (defaultParts !is null)
            return resolveAll(defaultParts, context);
        return context.handleUnresolvablePlaceholder(resolvedKey, text);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// A small backtracking regular-expression engine for AntPathMatcher (no std.regex in core)

private enum RegexKind : ubyte
{
    literal,
    any,
    set,
    group,
    lineStart,
    lineEnd
}

private enum uint UNBOUNDED = uint.max;

/// The most character reads one match may make, as Spring's `MaxAttemptsCharSequence` allows.
private enum MAX_ATTEMPTS = 1_000_000;

private struct RegexRange
{
    dchar lo;
    dchar hi;
}

/// A named class such as `\d` or `\p{L}`; `negated` for `\D` or `\P{L}`.
private struct RegexNamed
{
    char code;
    bool negated;
}

private final class RegexNode
{
    RegexKind kind;
    dchar ch;
    RegexRange[] ranges;
    RegexNamed[] named;
    bool negated;
    RegexNode[][] alternatives;
    int capture = -1;
    uint min = 1;
    uint max = 1;
    bool reluctant;

    this(RegexKind kind)
    {
        this.kind = kind;
    }
}

/// A compiled pattern: alternatives of node sequences and its number of capturing groups.
private final class TinyRegex
{
    RegexNode[][] alternatives;
    int groupCount;
    bool caseInsensitive;
    string source;

    this(RegexNode[][] alternatives, int groupCount, bool caseInsensitive, string source)
    {
        this.alternatives = alternatives;
        this.groupCount = groupCount;
        this.caseInsensitive = caseInsensitive;
        this.source = source;
    }
}

private TinyRegex compileRegex(string source)
{
    auto parser = RegexParser(source);
    auto alternatives = parser.parseAlternatives();
    if (parser.pos != source.length)
        parser.unsupported();
    return new TinyRegex(alternatives, parser.groupCount, false, source);
}

private struct RegexParser
{
    string text;
    size_t pos;
    int groupCount;

    void unsupported()
    {
        import flint.engine.aot.text : decimal;

        throw new IllegalArgumentException("Unsupported regular expression syntax at index " ~ decimal(
                cast(ulong) pos) ~ " of \"" ~ text ~ "\"");
    }

    RegexNode[][] parseAlternatives()
    {
        RegexNode[][] result = [parseSequence()];
        while (pos < text.length && text[pos] == '|')
        {
            pos++;
            result ~= parseSequence();
        }
        return result;
    }

    RegexNode[] parseSequence()
    {
        RegexNode[] nodes;
        while (pos < text.length && text[pos] != '|' && text[pos] != ')')
        {
            auto node = parseAtom();
            parseQuantifier(node);
            nodes ~= node;
        }
        return nodes;
    }

    RegexNode parseAtom()
    {
        const c = decodeAt(text, pos);
        switch (c)
        {
        case '(':
            return parseGroup();
        case '[':
            return parseSet();
        case '.':
            return new RegexNode(RegexKind.any);
        case '^':
            return new RegexNode(RegexKind.lineStart);
        case '$':
            return new RegexNode(RegexKind.lineEnd);
        case '\\':
            return parseEscape(false);
        case '*', '+', '?', '{':
            pos--;
            unsupported();
            assert(0);
        default:
            return literal(c);
        }
    }

    static RegexNode literal(dchar c)
    {
        auto node = new RegexNode(RegexKind.literal);
        node.ch = c;
        return node;
    }

    RegexNode parseGroup()
    {
        auto node = new RegexNode(RegexKind.group);
        if (hasPrefix(text[pos .. $], "?:"))
            pos += 2;
        else if (hasPrefix(text[pos .. $], "?"))
            unsupported();
        else
            node.capture = ++groupCount;
        node.alternatives = parseAlternatives();
        if (pos >= text.length || text[pos] != ')')
            unsupported();
        pos++;
        return node;
    }

    void parseQuantifier(RegexNode node)
    {
        if (pos >= text.length)
            return;
        switch (text[pos])
        {
        case '*':
            node.min = 0;
            node.max = UNBOUNDED;
            pos++;
            break;
        case '+':
            node.min = 1;
            node.max = UNBOUNDED;
            pos++;
            break;
        case '?':
            node.min = 0;
            node.max = 1;
            pos++;
            break;
        case '{':
            parseRepetition(node);
            break;
        default:
            return;
        }
        if (pos < text.length && text[pos] == '?')
        {
            node.reluctant = true;
            pos++;
        }
        else if (pos < text.length && text[pos] == '+')
            unsupported();
    }

    void parseRepetition(RegexNode node)
    {
        pos++;
        size_t start = pos;
        node.min = parseCount(start);
        node.max = node.min;
        if (pos < text.length && text[pos] == ',')
        {
            pos++;
            start = pos;
            node.max = pos < text.length && text[pos] == '}' ? UNBOUNDED : parseCount(start);
        }
        if (pos >= text.length || text[pos] != '}' || node.max < node.min)
            unsupported();
        pos++;
    }

    uint parseCount(size_t start)
    {
        uint value;
        while (pos < text.length && text[pos] >= '0' && text[pos] <= '9' && pos - start < 9)
            value = value * 10 + (text[pos++] - '0');
        if (pos == start)
            unsupported();
        return value;
    }

    RegexNode parseEscape(bool inSet)
    {
        if (pos >= text.length)
            unsupported();
        const c = decodeAt(text, pos);
        switch (c)
        {
        case 'd', 'w', 's':
            return namedSet(cast(char) c, false);
        case 'D', 'W', 'S':
            return namedSet(cast(char)(c + ('a' - 'A')), true);
        case 'p', 'P':
            return namedSet(parsePropertyName(), c == 'P');
        default:
            return literal(escapedCharacter(c, inSet));
        }
    }

    /// The character a `\c` escape stands for; outside a class, other ASCII letters and digits are unsupported.
    dchar escapedCharacter(dchar c, bool inSet)
    {
        switch (c)
        {
        case 't':
            return '\t';
        case 'n':
            return '\n';
        case 'r':
            return '\r';
        case 'f':
            return '\f';
        case 'e':
            return '\x1B';
        default:
            if ((isAsciiLetter(c) || isAsciiDigit(c)) && !inSet)
                unsupported();
            return c;
        }
    }

    private static immutable string[] propertyNames = [
        "L", "IsL", "IsLetter", "Lu", "IsLu", "Ll", "IsLl", "N", "IsN", "Nd", "IsNd", "Alpha",
        "Upper", "Lower", "Digit", "Alnum"
    ];
    private static immutable char[] propertyCodes = "LLLUUllNNNNaAzdn";

    char parsePropertyName()
    {
        string name;
        if (pos < text.length && text[pos] == '{')
        {
            const close = indexOfFrom(text, "}", pos);
            if (close < 0)
                unsupported();
            name = text[pos + 1 .. close];
            pos = close + 1;
        }
        else if (pos < text.length)
        {
            name = text[pos .. pos + 1];
            pos++;
        }
        foreach (i, candidate; propertyNames)
            if (candidate == name)
                return propertyCodes[i];
        unsupported();
        assert(0);
    }

    static RegexNode namedSet(char code, bool negated)
    {
        auto node = new RegexNode(RegexKind.set);
        node.named = [RegexNamed(code, negated)];
        return node;
    }

    RegexNode parseSet()
    {
        auto node = new RegexNode(RegexKind.set);
        if (pos < text.length && text[pos] == '^')
        {
            node.negated = true;
            pos++;
        }
        bool first = true;
        while (pos < text.length && (text[pos] != ']' || first))
        {
            first = false;
            if (text[pos] == '[' || hasPrefix(text[pos .. $], "&&"))
                unsupported();
            parseSetItem(node);
        }
        if (pos >= text.length)
            unsupported();
        pos++;
        return node;
    }

    void parseSetItem(RegexNode node)
    {
        dchar lo;
        if (text[pos] == '\\')
        {
            pos++;
            auto escaped = parseEscape(true);
            if (escaped.kind == RegexKind.set)
            {
                node.named ~= escaped.named;
                return;
            }
            lo = escaped.ch;
        }
        else
            lo = decodeAt(text, pos);
        dchar hi = lo;
        if (pos + 1 < text.length && text[pos] == '-' && text[pos + 1] != ']')
        {
            pos++;
            if (text[pos] == '\\')
            {
                pos++;
                hi = parseEscape(true).ch;
            }
            else
                hi = decodeAt(text, pos);
            if (hi < lo)
                unsupported();
        }
        node.ranges ~= RegexRange(lo, hi);
    }
}

private bool isAsciiDigit(dchar c) pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

private bool isAsciiUpper(dchar c) pure nothrow @nogc
{
    return c >= 'A' && c <= 'Z';
}

private bool isAsciiLower(dchar c) pure nothrow @nogc
{
    return c >= 'a' && c <= 'z';
}

private bool isAsciiLetter(dchar c) pure nothrow @nogc
{
    return isAsciiUpper(c) || isAsciiLower(c);
}

/// Java's `\s` without `UNICODE_CHARACTER_CLASS`: `[ \t\n\x0B\f\r]`.
private bool isRegexSpace(dchar c) pure nothrow @nogc
{
    return c == ' ' || (c >= '\t' && c <= '\r');
}

private bool namedClassContains(RegexNamed named, dchar c)
{
    return namedClassTest(named.code, c) != named.negated;
}

private bool namedClassTest(char code, dchar c)
{
    import std.uni : isAlpha, isLower, isNumber, isUpper;

    switch (code)
    {
    case 'L':
        return isAlpha(c);
    case 'U':
        return isUpper(c);
    case 'l':
        return isLower(c);
    case 'N':
        return isNumber(c);
    default:
        return asciiClassTest(code, c);
    }
}

private bool asciiClassTest(char code, dchar c)
{
    switch (code)
    {
    case 'd':
        return isAsciiDigit(c);
    case 'w':
        return isAsciiLetter(c) || isAsciiDigit(c) || c == '_';
    case 's':
        return isRegexSpace(c);
    case 'a':
        return isAsciiLetter(c);
    case 'A':
        return isAsciiUpper(c);
    case 'z':
        return isAsciiLower(c);
    default:
        return isAsciiLetter(c) || isAsciiDigit(c);
    }
}

private bool setContains(const RegexNode node, dchar c)
{
    bool found;
    foreach (range; node.ranges)
        if (c >= range.lo && c <= range.hi)
            found = true;
    foreach (named; node.named)
        if (namedClassContains(named, c))
            found = true;
    return found != node.negated;
}

private dchar asciiLower(dchar c) pure nothrow @nogc
{
    return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;
}

private dchar asciiUpper(dchar c) pure nothrow @nogc
{
    return c >= 'a' && c <= 'z' ? c - ('a' - 'A') : c;
}

/// One matching attempt over `input`: capture positions and the character-read budget.
private final class RegexRun
{
    private string input;
    private bool caseInsensitive;
    private size_t[] starts;
    private size_t[] ends;
    private bool[] matched;
    private uint steps;
    private size_t matchEnd;

    this(string input, int groupCount, bool caseInsensitive)
    {
        this.input = input;
        this.caseInsensitive = caseInsensitive;
        starts = new size_t[groupCount];
        ends = new size_t[groupCount];
        matched = new bool[groupCount];
    }

    /// Whether `regex` matches all of the input.
    bool matches(TinyRegex regex)
    {
        return alternatives(regex.alternatives, 0, (size_t end) => end == input.length);
    }

    /// The start of the first match of `regex` at or after byte `from`, or -1; `matchEnd` holds its end.
    ptrdiff_t find(TinyRegex regex, size_t from)
    {
        size_t start = from;
        while (start <= input.length)
        {
            if (alternatives(regex.alternatives, start, (size_t end) { matchEnd = end; return true; }))
                return cast(ptrdiff_t) start;
            if (start == input.length)
                break;
            skipCodePoint(input, start);
        }
        return -1;
    }

    /// The text of group `group` (1-based), or null when it did not participate.
    string group(int group)
    {
        return matched[group - 1] ? input[starts[group - 1] .. ends[group - 1]] : null;
    }

    private void tick()
    {
        if (steps++ >= MAX_ATTEMPTS)
            throw new IllegalStateException("Too many character access attempts encountered during pattern matching");
    }

    private bool alternatives(const(RegexNode[])[] alts, size_t pos, scope bool delegate(size_t) @safe cont)
    {
        foreach (alt; alts)
            if (sequence(alt, 0, pos, cont))
                return true;
        return false;
    }

    private bool sequence(const(RegexNode)[] nodes, size_t index, size_t pos, scope bool delegate(size_t) @safe cont)
    {
        if (index == nodes.length)
            return cont(pos);
        return repeat(nodes[index], pos, (size_t next) => sequence(nodes, index + 1, next, cont));
    }

    private bool repeat(const RegexNode node, size_t pos, scope bool delegate(size_t) @safe cont)
    {
        final switch (node.kind)
        {
        case RegexKind.group:
            return repeatGroup(node, 0, pos, cont);
        case RegexKind.lineStart:
            return (pos == 0 || node.min == 0) && cont(pos);
        case RegexKind.lineEnd:
            return (pos == input.length || node.min == 0) && cont(pos);
        case RegexKind.literal:
        case RegexKind.any:
        case RegexKind.set:
            return node.reluctant
                ? repeatCharLazy(node, pos, cont) : repeatCharGreedy(node, pos, cont);
        }
    }

    /// The position after one character at `pos` that `node` accepts, or `size_t.max`.
    private size_t step(const RegexNode node, size_t pos)
    {
        if (pos >= input.length)
            return size_t.max;
        tick();
        size_t next = pos;
        const c = decodeAt(input, next);
        return accepts(node, c) ? next : size_t.max;
    }

    private bool accepts(const RegexNode node, dchar c)
    {
        if (node.kind == RegexKind.any)
            return true;
        if (node.kind == RegexKind.literal)
            return c == node.ch || (caseInsensitive && asciiLower(c) == asciiLower(node.ch));
        if (setContains(node, c))
            return true;
        return caseInsensitive && (setContains(node, asciiLower(c)) || setContains(node, asciiUpper(c)));
    }

    private bool repeatCharGreedy(const RegexNode node, size_t pos, scope bool delegate(size_t) @safe cont)
    {
        uint count;
        size_t p = pos;
        while (count < node.max)
        {
            const next = step(node, p);
            if (next == size_t.max)
                break;
            p = next;
            count++;
        }
        while (count >= node.min)
        {
            if (cont(p))
                return true;
            if (count == node.min)
                return false;
            p -= strideBefore(input, p);
            count--;
        }
        return false;
    }

    private bool repeatCharLazy(const RegexNode node, size_t pos, scope bool delegate(size_t) @safe cont)
    {
        uint count;
        size_t p = pos;
        while (true)
        {
            if (count >= node.min && cont(p))
                return true;
            if (count >= node.max)
                return false;
            const next = step(node, p);
            if (next == size_t.max)
                return false;
            p = next;
            count++;
        }
    }

    private bool repeatGroup(const RegexNode node, uint count, size_t pos, scope bool delegate(size_t) @safe cont)
    {
        if (node.reluctant)
        {
            if (count >= node.min && cont(pos))
                return true;
            return count < node.max && groupOnce(node, pos, (size_t next) => (next != pos
                    || count < node.min) && repeatGroup(node, count + 1, next, cont));
        }
        if (count < node.max && groupOnce(node, pos, (size_t next) => (next != pos || count < node.min)
                && repeatGroup(node, count + 1, next, cont)))
            return true;
        return count >= node.min && cont(pos);
    }

    private bool groupOnce(const RegexNode node, size_t pos, scope bool delegate(size_t) @safe cont)
    {
        if (node.capture < 0)
            return alternatives(node.alternatives, pos, cont);
        const g = node.capture - 1;
        return alternatives(node.alternatives, pos, (size_t next) {
            const oldStart = starts[g];
            const oldEnd = ends[g];
            const oldMatched = matched[g];
            starts[g] = pos;
            ends[g] = next;
            matched[g] = true;
            if (cont(next))
                return true;
            starts[g] = oldStart;
            ends[g] = oldEnd;
            matched[g] = oldMatched;
            return false;
        });
    }
}

// ---------------------------------------------------------------------------------------------------------------
// PathMatcher, AntPathMatcher

/// Strategy interface for string-based path matching, implemented by `AntPathMatcher`.
interface PathMatcher
{
    /// Whether `path` is a pattern that `match` can use, rather than an actual path.
    bool isPattern(string path);

    /// Whether `path` matches `pattern` in full.
    bool match(string pattern, string path);

    /// Whether `pattern` matches at least the start of `path`.
    bool matchStart(string pattern, string path);

    /// The part of `path` that the wildcard parts of `pattern` match.
    string extractPathWithinPattern(string pattern, string path);

    /// The URI template variables of `pattern` (`{name}`) and their values in `path`.
    Map!(string, string) extractUriTemplateVariables(string pattern, string path);

    /// A comparator that sorts patterns by specificity for `path`: more specific first.
    Comparator!string getPatternComparator(string path);

    /// `pattern1` and `pattern2` combined into a new pattern.
    string combine(string pattern1, string pattern2);
}

/++
`PathMatcher` for Ant-style path patterns: `?` matches one character, `*` zero or more characters within a path
segment, `**` zero or more directories, and `{name:[a-z]+}` matches the regular expression `[a-z]+` as a path
variable named `name` (see the module documentation for the supported regular-expression syntax).

The pattern caches are per instance and not synchronized: share an instance across threads only after
configuring it with `setCachePatterns(false)`, or give each thread its own.
+/
class AntPathMatcher : PathMatcher
{
    /// The default path separator: `/`.
    enum string DEFAULT_PATH_SEPARATOR = "/";

    private enum CACHE_TURNOFF_THRESHOLD = 65_536;

    private string pathSeparator;
    private PathSeparatorPatternCache pathSeparatorPatternCache;
    private bool caseSensitive = true;
    private bool trimTokens = false;
    // Java's nullable Boolean: -1 unset (adaptive), 0 false, 1 true.
    private int cachePatterns = -1;
    private string[][string] tokenizedPatternCache;
    package AntPathStringMatcher[string] stringMatcherCache;

    /// A matcher with the default path separator `/`.
    this()
    {
        pathSeparator = DEFAULT_PATH_SEPARATOR;
        pathSeparatorPatternCache = PathSeparatorPatternCache(DEFAULT_PATH_SEPARATOR);
    }

    /// A matcher with `pathSeparator`.
    this(string pathSeparator)
    {
        Assert.notNull(pathSeparator, "'pathSeparator' must not be null");
        this.pathSeparator = pathSeparator;
        pathSeparatorPatternCache = PathSeparatorPatternCache(pathSeparator);
    }

    /// Set the path separator; null restores the default `/`.
    void setPathSeparator(string pathSeparator)
    {
        this.pathSeparator = pathSeparator !is null ? pathSeparator : DEFAULT_PATH_SEPARATOR;
        pathSeparatorPatternCache = PathSeparatorPatternCache(this.pathSeparator);
    }

    /// Whether matching is case-sensitive (the default).
    void setCaseSensitive(bool caseSensitive)
    {
        this.caseSensitive = caseSensitive;
    }

    /// Whether to trim tokenized paths and patterns (off by default).
    void setTrimTokens(bool trimTokens)
    {
        this.trimTokens = trimTokens;
    }

    /++
    Whether to cache parsed patterns. By default the cache is on, and turns itself off when more than 65536
    patterns arrive, assuming patterns are then not recurring; `true` keeps it on, `false` turns it off.
    +/
    void setCachePatterns(bool cachePatterns)
    {
        this.cachePatterns = cachePatterns ? 1 : 0;
    }

    private void deactivatePatternCache()
    {
        cachePatterns = 0;
        tokenizedPatternCache = null;
        stringMatcherCache = null;
    }

    /// Whether `path` contains `*`, `?` or a `{...}` variable. False for null.
    bool isPattern(string path)
    {
        if (path is null)
            return false;
        bool uriVar;
        foreach (c; path)
        {
            if (c == '*' || c == '?')
                return true;
            if (c == '{')
                uriVar = true;
            else if (c == '}' && uriVar)
                return true;
        }
        return false;
    }

    /// Whether `path` matches `pattern` in full. False for a null path.
    bool match(string pattern, string path)
    {
        return doMatch(pattern, path, true, null);
    }

    /// Whether `pattern` matches at least the start of `path`.
    bool matchStart(string pattern, string path)
    {
        return doMatch(pattern, path, false, null);
    }

    /// Match `path` against `pattern`, in full or only its start, recording URI template variables when
    /// `uriTemplateVariables` is not null.
    protected bool doMatch(string pattern, string path, bool fullMatch, Map!(string, string) uriTemplateVariables)
    {
        if (path is null || hasPrefix(path, pathSeparator) != hasPrefix(pattern, pathSeparator))
            return false;
        auto pattDirs = tokenizePattern(pattern);
        if (fullMatch && caseSensitive && !isPotentialMatch(path, pattDirs))
            return false;
        auto pathDirs = tokenizePath(path);
        const pattCount = cast(int) pattDirs.length;
        const pathCount = cast(int) pathDirs.length;
        auto state = MatchState(pattDirs, pathDirs, 0, pattCount - 1, 0, pathCount - 1);
        if (!matchFromStart(state, uriTemplateVariables))
            return false;
        if (state.pathStart > state.pathEnd)
            return pathExhausted(state, pattern, path, fullMatch);
        if (state.pattStart > state.pattEnd)
            return false;
        if (!fullMatch && pattDirs[state.pattStart] == "**")
            return true;
        return matchFromEnd(state, pattern, path, uriTemplateVariables);
    }

    /// Match all elements up to the first `**`.
    private bool matchFromStart(ref MatchState state, Map!(string, string) uriTemplateVariables)
    {
        while (state.pattStart <= state.pattEnd && state.pathStart <= state.pathEnd)
        {
            const pattDir = state.pattDirs[state.pattStart];
            if (pattDir == "**")
                break;
            if (!matchStrings(pattDir, state.pathDirs[state.pathStart], uriTemplateVariables))
                return false;
            state.pattStart++;
            state.pathStart++;
        }
        return true;
    }

    private static struct MatchState
    {
        string[] pattDirs;
        string[] pathDirs;
        int pattStart;
        int pattEnd;
        int pathStart;
        int pathEnd;

        bool onlyDoubleWildcardsLeft() const
        {
            foreach (i; pattStart .. pattEnd + 1)
                if (pattDirs[i] != "**")
                    return false;
            return true;
        }
    }

    /// The path is exhausted: match only when the rest of the pattern is `*` or `**`s.
    private bool pathExhausted(ref MatchState state, string pattern, string path, bool fullMatch)
    {
        if (state.pattStart > state.pattEnd)
            return hasSuffix(pattern, pathSeparator) == hasSuffix(path, pathSeparator);
        if (!fullMatch)
            return true;
        const lastIsStar = state.pattStart == state.pattEnd && state.pattDirs[state.pattStart] == "*";
        if (lastIsStar && hasSuffix(path, pathSeparator))
            return true;
        return state.onlyDoubleWildcardsLeft();
    }

    /// Match from the end up to the last `**`, then the segments between `**`s.
    private bool matchFromEnd(ref MatchState state, string pattern, string path, Map!(string,
            string) uriTemplateVariables)
    {
        while (state.pattStart <= state.pattEnd && state.pathStart <= state.pathEnd)
        {
            const pattDir = state.pattDirs[state.pattEnd];
            if (pattDir == "**")
                break;
            if (!matchStrings(pattDir, state.pathDirs[state.pathEnd], uriTemplateVariables))
                return false;
            if (state.pattEnd + 1 == state.pattDirs.length && hasSuffix(pattern,
                    pathSeparator) != hasSuffix(path, pathSeparator))
                return false;
            state.pattEnd--;
            state.pathEnd--;
        }
        if (state.pathStart > state.pathEnd)
            return state.onlyDoubleWildcardsLeft();
        while (state.pattStart != state.pattEnd && state.pathStart <= state.pathEnd)
            if (!matchBetweenDoubleWildcards(state, uriTemplateVariables))
                return false;
        return state.onlyDoubleWildcardsLeft();
    }

    private bool matchBetweenDoubleWildcards(ref MatchState state, Map!(string, string) uriTemplateVariables)
    {
        int patIdxTmp = -1;
        foreach (i; state.pattStart + 1 .. state.pattEnd + 1)
            if (state.pattDirs[i] == "**")
            {
                patIdxTmp = i;
                break;
            }
        if (patIdxTmp == state.pattStart + 1)
        {
            // '**/**' situation, so skip one.
            state.pattStart++;
            return true;
        }
        // Find the pattern between pattStart and patIdxTmp in the path between pathStart and pathEnd.
        const patLength = patIdxTmp - state.pattStart - 1;
        const strLength = state.pathEnd - state.pathStart + 1;
        int foundIdx = -1;
        for (int i = 0; i <= strLength - patLength && foundIdx == -1; i++)
        {
            bool all = true;
            for (int j = 0; j < patLength && all; j++)
                all = matchStrings(state.pattDirs[state.pattStart + j + 1],
                        state.pathDirs[state.pathStart + i + j], uriTemplateVariables);
            if (all)
                foundIdx = state.pathStart + i;
        }
        if (foundIdx == -1)
            return false;
        state.pattStart = patIdxTmp;
        state.pathStart = foundIdx + patLength;
        return true;
    }

    private bool isPotentialMatch(string path, string[] pattDirs)
    {
        if (trimTokens)
            return true;
        size_t pos;
        foreach (pattDir; pattDirs)
        {
            pos += skipSeparator(path, pos, pathSeparator);
            size_t skippedBytes;
            const skipped = skipSegment(path, pos, pattDir, skippedBytes);
            if (skipped < codePointCount(pattDir))
                return skipped > 0 || (pattDir.length > 0 && isWildcardChar(pattDir[0]));
            pos += skippedBytes;
        }
        return true;
    }

    /// The number of characters of `prefix` that match `path` from `pos` up to the first wildcard (0 when the
    /// path ends first); `skippedBytes` receives their length in `path`.
    private static size_t skipSegment(string path, size_t pos, string prefix, out size_t skippedBytes)
    {
        size_t skipped;
        size_t i;
        while (i < prefix.length)
        {
            const c = decodeAt(prefix, i);
            if (isWildcardChar(c))
                return skipped;
            size_t currPos = pos + skippedBytes;
            if (currPos >= path.length)
            {
                skippedBytes = 0;
                return 0;
            }
            if (c == decodeAt(path, currPos))
            {
                skipped++;
                skippedBytes = currPos - pos;
            }
        }
        return skipped;
    }

    private static size_t skipSeparator(string path, size_t pos, string separator)
    {
        size_t skipped;
        while (separator.length && substringMatchAt(path, pos + skipped, separator))
            skipped += separator.length;
        return skipped;
    }

    private static bool isWildcardChar(dchar c)
    {
        return c == '*' || c == '?' || c == '{';
    }

    /// Tokenize `pattern` into segments, using the pattern cache.
    protected string[] tokenizePattern(string pattern)
    {
        string[] tokenized;
        bool cached;
        if (cachePatterns != 0)
            if (auto entry = pattern in tokenizedPatternCache)
            {
                tokenized = *entry;
                cached = true;
            }
        if (cached)
            return tokenized;
        tokenized = tokenizePath(pattern);
        if (cachePatterns == -1 && tokenizedPatternCache.length >= CACHE_TURNOFF_THRESHOLD)
        {
            // Too many different patterns: they are unlikely to recur, so turn the cache off.
            deactivatePatternCache();
            return tokenized;
        }
        if (cachePatterns != 0)
            tokenizedPatternCache[pattern] = tokenized;
        return tokenized;
    }

    /// Tokenize `path` into segments at the path separator.
    protected string[] tokenizePath(string path)
    {
        return StringUtils.tokenizeToStringArray(path, pathSeparator, trimTokens, true);
    }

    private bool matchStrings(string pattern, string str, Map!(string, string) uriTemplateVariables)
    {
        return getStringMatcher(pattern).matchStrings(str, uriTemplateVariables);
    }

    /// The `AntPathStringMatcher` for one pattern segment, using the matcher cache.
    protected AntPathStringMatcher getStringMatcher(string pattern)
    {
        if (cachePatterns != 0)
            if (auto entry = pattern in stringMatcherCache)
                return *entry;
        auto matcher = new AntPathStringMatcher(pattern, pathSeparator, caseSensitive);
        if (cachePatterns == -1 && stringMatcherCache.length >= CACHE_TURNOFF_THRESHOLD)
        {
            // Too many different patterns: they are unlikely to recur, so turn the cache off.
            deactivatePatternCache();
            return matcher;
        }
        if (cachePatterns != 0)
            stringMatcherCache[pattern] = matcher;
        return matcher;
    }

    /++
    The part of `path` matched by the wildcard parts of `pattern`: `/docs/cvs/commit.html` within `/docs/cvs/*.html`
    is `commit.html`, and within `/docs/**` it is `cvs/commit.html`.
    +/
    string extractPathWithinPattern(string pattern, string path)
    {
        const patternParts = StringUtils.tokenizeToStringArray(pattern, pathSeparator, trimTokens, true);
        const pathParts = StringUtils.tokenizeToStringArray(path, pathSeparator, trimTokens, true);
        string builder;
        bool pathStarted;
        for (size_t segment = 0; segment < patternParts.length; segment++)
        {
            const patternPart = patternParts[segment];
            if (indexOfChar(patternPart, '*') > -1 || indexOfChar(patternPart, '?') > -1)
                for (; segment < pathParts.length; segment++)
                {
                    if (pathStarted || (segment == 0 && !hasPrefix(pattern, pathSeparator)))
                        builder ~= pathSeparator;
                    builder ~= pathParts[segment];
                    pathStarted = true;
                }
        }
        return builder;
    }

    /// The URI template variables of `pattern` and their values in `path`, in pattern order. Throws
    /// `IllegalStateException` when `path` does not match.
    Map!(string, string) extractUriTemplateVariables(string pattern, string path)
    {
        auto variables = new LinkedHashMap!(string, string)();
        if (!doMatch(pattern, path, true, variables))
            throw new IllegalStateException("Pattern \"" ~ pattern ~ "\" is not a match for \"" ~ path ~ "\"");
        return variables;
    }

    /++
    Combine two patterns: `/hotels` and `/bookings` give `/hotels/bookings`, `/hotels/*` and `/bookings` give
    `/hotels/bookings`, `/*.html` and `/hotel` give `/hotel.html`. Throws `IllegalArgumentException` when two file
    extensions conflict.
    +/
    string combine(string pattern1, string pattern2)
    {
        if (!StringUtils.hasText(pattern1))
            return StringUtils.hasText(pattern2) ? pattern2 : "";
        if (!StringUtils.hasText(pattern2))
            return pattern1;
        const pattern1ContainsUriVar = indexOfChar(pattern1, '{') != -1;
        if (pattern1 != pattern2 && !pattern1ContainsUriVar && match(pattern1, pattern2))
            return pattern2;
        if (hasSuffix(pattern1, pathSeparatorPatternCache.endsOnWildCard))
            return concat(dropWildcard(pattern1), pattern2);
        if (hasSuffix(pattern1, pathSeparatorPatternCache.endsOnDoubleWildCard))
            return concat(pattern1, pattern2);
        const starDotPos1 = indexOfString(pattern1, "*.");
        if (pattern1ContainsUriVar || starDotPos1 == -1 || pathSeparator == ".")
            return concat(pattern1, pattern2);
        return combineExtensions(pattern1, pattern2, starDotPos1);
    }

    /// `pattern` without its trailing `*` and the last character of the separator before it, as Java drops two
    /// UTF-16 units.
    private static string dropWildcard(string pattern)
    {
        const withoutStar = pattern[0 .. $ - 1];
        return withoutStar[0 .. $ - strideBefore(withoutStar, withoutStar.length)];
    }

    private static string combineExtensions(string pattern1, string pattern2, size_t starDotPos1)
    {
        const ext1 = pattern1[starDotPos1 + 1 .. $];
        const dotPos2 = indexOfChar(pattern2, '.');
        const file2 = dotPos2 == -1 ? pattern2 : pattern2[0 .. dotPos2];
        const ext2 = dotPos2 == -1 ? "" : pattern2[dotPos2 .. $];
        const ext1All = ext1 == ".*" || ext1.length == 0;
        const ext2All = ext2 == ".*" || ext2.length == 0;
        if (!ext1All && !ext2All)
            throw new IllegalArgumentException("Cannot combine patterns: " ~ pattern1 ~ " vs " ~ pattern2);
        return file2 ~ (ext1All ? ext2 : ext1);
    }

    private string concat(string path1, string path2)
    {
        const path1EndsWithSeparator = hasSuffix(path1, pathSeparator);
        const path2StartsWithSeparator = hasPrefix(path2, pathSeparator);
        if (path1EndsWithSeparator && path2StartsWithSeparator)
            return path1 ~ path2[1 .. $];
        if (path1EndsWithSeparator || path2StartsWithSeparator)
            return path1 ~ path2;
        return path1 ~ pathSeparator ~ path2;
    }

    /// A comparator ordering patterns by specificity for `path` (see `AntPatternComparator`).
    Comparator!string getPatternComparator(string path)
    {
        return new AntPatternComparator(path, pathSeparator);
    }

    /++
    Tests whether a string matches a pattern segment, where `*` and `?` are wildcards and `{name}` or
    `{name:regex}` are URI template variables. The pattern is compiled once, when the matcher is created.
    +/
    protected static class AntPathStringMatcher
    {
        private enum DEFAULT_VARIABLE_PATTERN = "((?s).*)";

        private string rawPattern;
        private bool caseSensitive;
        private bool exactMatch;
        private TinyRegex pattern;
        private string[] variableNames;

        /// A matcher for `pattern`; `pathSeparator` characters never occur in a `{...}` variable.
        protected this(string pattern, string pathSeparator, bool caseSensitive)
        {
            rawPattern = pattern;
            this.caseSensitive = caseSensitive;
            auto glob = compileRegex(globPattern(pathSeparator));
            auto run = new RegexRun(pattern, glob.groupCount, false);
            RegexNode[] nodes;
            string source;
            int groups;
            size_t end;
            ptrdiff_t start;
            while ((start = run.find(glob, end)) >= 0)
            {
                appendQuoted(nodes, source, pattern[end .. start]);
                appendGlob(nodes, source, groups, pattern[start .. run.matchEnd], run.group(1));
                end = run.matchEnd;
            }
            if (end == 0)
            {
                // No glob pattern was found: this is an exact string match.
                exactMatch = true;
                return;
            }
            appendQuoted(nodes, source, pattern[end .. $]);
            this.pattern = new TinyRegex([nodes], groups, !caseSensitive, source);
        }

        private static string globPattern(string pathSeparator)
        {
            return "\\?|\\*|\\{((?:\\{[^" ~ pathSeparator ~ "]+?\\}|[^" ~ pathSeparator ~ "{}]|\\\\[{}])+?)\\}";
        }

        private static void appendQuoted(ref RegexNode[] nodes, ref string source, string text)
        {
            if (text.length == 0)
                return;
            size_t i;
            while (i < text.length)
                nodes ~= RegexParser.literal(decodeAt(text, i));
            source ~= "\\Q" ~ text ~ "\\E";
        }

        private void appendGlob(ref RegexNode[] nodes, ref string source, ref int groups, string match, string name)
        {
            if (match == "?" || match == "*")
            {
                auto any = new RegexNode(RegexKind.any);
                if (match == "*")
                {
                    any.min = 0;
                    any.max = UNBOUNDED;
                }
                nodes ~= any;
                source ~= match == "?" ? "." : ".*";
                return;
            }
            auto group = new RegexNode(RegexKind.group);
            group.capture = ++groups;
            const colonIdx = indexOfChar(match, ':');
            if (colonIdx == -1)
            {
                auto any = new RegexNode(RegexKind.any);
                any.min = 0;
                any.max = UNBOUNDED;
                group.alternatives = [[any]];
                source ~= DEFAULT_VARIABLE_PATTERN;
                variableNames ~= name;
            }
            else
            {
                const variablePattern = match[colonIdx + 1 .. $ - 1];
                auto parser = RegexParser(variablePattern, 0, groups);
                group.alternatives = parser.parseAlternatives();
                if (parser.pos != variablePattern.length)
                    parser.unsupported();
                groups = parser.groupCount;
                source ~= "(" ~ variablePattern ~ ")";
                variableNames ~= match[1 .. colonIdx];
            }
            nodes ~= group;
        }

        /// Whether `str` matches the pattern, recording URI template variables when `uriTemplateVariables` is not
        /// null.
        bool matchStrings(string str, Map!(string, string) uriTemplateVariables)
        {
            if (exactMatch)
                return caseSensitive ? rawPattern == str : equalsIgnoreCase(rawPattern, str);
            auto run = new RegexRun(str, pattern.groupCount, pattern.caseInsensitive);
            if (!run.matches(pattern))
                return false;
            if (uriTemplateVariables is null)
                return true;
            if (variableNames.length != pattern.groupCount)
                throw new IllegalArgumentException("The number of capturing groups in the pattern segment "
                        ~ pattern.source ~ " does not match the number of URI template variables it defines, "
                        ~ "which can occur if capturing groups are used in a URI template regex. "
                        ~ "Use non-capturing groups instead.");
            foreach (i, name; variableNames)
            {
                if (hasPrefix(name, "*"))
                    throw new IllegalArgumentException("Capturing patterns (" ~ name ~ ") are not "
                            ~ "supported by the AntPathMatcher. Use the PathPatternParser instead.");
                uriTemplateVariables.put(name, run.group(cast(int) i + 1));
            }
            return true;
        }
    }

    /++
    The default comparator of `getPatternComparator`: for a path, a pattern equal to it sorts first, then
    patterns with fewer URI variables and wildcards, longer patterns, and catch-all patterns last. Lengths are in
    UTF-16 code units, as in Java (R14); null patterns are least specific.
    +/
    protected static class AntPatternComparator : Comparator!string
    {
        private string path;
        private string pathSeparator;

        /// A comparator for `path` with the default separator.
        this(string path)
        {
            this(path, DEFAULT_PATH_SEPARATOR);
        }

        /// A comparator for `path` with `pathSeparator`.
        this(string path, string pathSeparator)
        {
            this.path = path;
            this.pathSeparator = pathSeparator;
        }

        /// Negative when `pattern1` is more specific than `pattern2`, positive when less, 0 when equal.
        int compare(string pattern1, string pattern2)
        {
            auto info1 = PatternInfo(pattern1, pathSeparator);
            auto info2 = PatternInfo(pattern2, pathSeparator);
            if (info1.isLeastSpecific() || info2.isLeastSpecific())
                return either(info1.isLeastSpecific(), info2.isLeastSpecific(), 1);
            const pattern1EqualsPath = pattern1 == path;
            const pattern2EqualsPath = pattern2 == path;
            if (pattern1EqualsPath || pattern2EqualsPath)
                return either(pattern1EqualsPath, pattern2EqualsPath, -1);
            return comparePrefixes(info1, info2);
        }

        /// 0 when `first` and `second` agree, else `whenOnlyFirst` or its negation.
        private static int either(bool first, bool second, int whenOnlyFirst)
        {
            if (first == second)
                return 0;
            return first ? whenOnlyFirst : -whenOnlyFirst;
        }

        private static int comparePrefixes(ref PatternInfo info1, ref PatternInfo info2)
        {
            if (info1.isPrefixPattern() && info2.isPrefixPattern())
                return info2.getLength() - info1.getLength();
            if (info1.isPrefixPattern() && info2.getDoubleWildcards() == 0)
                return 1;
            if (info2.isPrefixPattern() && info1.getDoubleWildcards() == 0)
                return -1;
            return compareCounts(info1, info2);
        }

        private static int compareCounts(ref PatternInfo info1, ref PatternInfo info2)
        {
            if (info1.getTotalCount() != info2.getTotalCount())
                return info1.getTotalCount() - info2.getTotalCount();
            if (info1.getLength() != info2.getLength())
                return info2.getLength() - info1.getLength();
            if (info1.getSingleWildcards() != info2.getSingleWildcards())
                return info1.getSingleWildcards() < info2.getSingleWildcards() ? -1 : 1;
            if (info1.getUriVars() != info2.getUriVars())
                return info1.getUriVars() < info2.getUriVars() ? -1 : 1;
            return 0;
        }

        /// Value class that holds information about a pattern: its wildcard and variable counts and length.
        private static struct PatternInfo
        {
            private string pattern;
            private int uriVars;
            private int singleWildcards;
            private int doubleWildcards;
            private bool catchAllPattern;
            private bool prefixPattern;
            private int length = -1;

            this(string pattern, string pathSeparator)
            {
                this.pattern = pattern;
                if (pattern !is null)
                {
                    initCounters();
                    catchAllPattern = pattern == pathSeparator ~ "**";
                    prefixPattern = !catchAllPattern && hasSuffix(pattern, pathSeparator ~ "**");
                }
                if (uriVars == 0)
                    length = pattern !is null ? cast(int) utf16Length(pattern) : 0;
            }

            private void initCounters()
            {
                size_t pos;
                while (pos < pattern.length)
                {
                    if (pattern[pos] == '{')
                        uriVars++;
                    else if (pattern[pos] == '*')
                    {
                        if (pos + 1 < pattern.length && pattern[pos + 1] == '*')
                        {
                            doubleWildcards++;
                            pos++;
                        }
                        else if (pos > 0 && pattern[pos - 1 .. $] != ".*")
                            singleWildcards++;
                    }
                    pos++;
                }
            }

            int getUriVars() const
            {
                return uriVars;
            }

            int getSingleWildcards() const
            {
                return singleWildcards;
            }

            int getDoubleWildcards() const
            {
                return doubleWildcards;
            }

            bool isLeastSpecific() const
            {
                return pattern is null || catchAllPattern;
            }

            bool isPrefixPattern() const
            {
                return prefixPattern;
            }

            int getTotalCount() const
            {
                return uriVars + singleWildcards + 2 * doubleWildcards;
            }

            int getLength()
            {
                if (length == -1)
                    length = pattern !is null ? cast(int) utf16Length(replaceVariables(pattern)) : 0;
                return length;
            }

            /// `pattern` with each `{...}` variable (no `/` inside) replaced by `#`.
            private static string replaceVariables(string pattern)
            {
                string result;
                size_t i;
                while (i < pattern.length)
                {
                    const end = variableEnd(pattern, i);
                    if (end > 0)
                    {
                        result ~= '#';
                        i = end;
                    }
                    else
                        result ~= pattern[i++];
                }
                return result;
            }

            /// The end of a `\{[^/]+?\}` match at `i`, or 0.
            private static size_t variableEnd(string pattern, size_t i)
            {
                if (pattern[i] != '{' || i + 1 >= pattern.length || pattern[i + 1] == '/')
                    return 0;
                for (size_t j = i + 2; j < pattern.length && pattern[j] != '/'; j++)
                    if (pattern[j] == '}')
                        return j + 1;
                return 0;
            }
        }
    }

    private static struct PathSeparatorPatternCache
    {
        string endsOnWildCard;
        string endsOnDoubleWildCard;

        this(string pathSeparator)
        {
            endsOnWildCard = pathSeparator ~ "*";
            endsOnDoubleWildCard = pathSeparator ~ "**";
        }
    }
}

// ---------------------------------------------------------------------------------------------------------
// MimeType, MimeTypeUtils and InvalidMimeTypeException
//
// Ported from spring-projects/spring-framework v7.1.0, spring-core/src/main/java/org/springframework/util/
// (MimeType.java, MimeTypeUtils.java, InvalidMimeTypeException.java). Copyright 2002-present the original author or
// authors. Licensed under the Apache License, Version 2.0. Modified by the Flint authors: translated to D under the
// rulebook. `MimeType` is a struct (ADR-030 section 5); its parameter map is an insertion-ordered, case-insensitive
// view (`MimeTypeParameters`, R10). Moved here from the web stack's interim package by web-http.

/// One `name=value` parameter of a MIME type, as given (values keep their quotes).
struct MimeTypeParameter
{
    string key; ///
    string value; ///
}

/++
A read-only, insertion-ordered map of MIME type parameters whose keys compare ignoring ASCII case, as
Spring's `LinkedCaseInsensitiveMap` (R10: stands in for `Map<String, String>` until `flint.java.util.Map`).
+/
struct MimeTypeParameters
{
    private const(MimeTypeParameter)[] entries;

    /// Number of parameters.
    int size() const pure nothrow @nogc
    {
        return cast(int) entries.length;
    }

    /// Whether there are none.
    bool isEmpty() const pure nothrow @nogc
    {
        return entries.length == 0;
    }

    /// The value for `key`, ignoring case, or `null`.
    string get(scope const(char)[] key) const pure nothrow @nogc
    {
        foreach (ref entry; entries)
            if (equalsIgnoreCase(entry.key, key))
                return entry.value;
        return null;
    }

    /// Whether `key` is present, ignoring case.
    bool containsKey(scope const(char)[] key) const pure nothrow @nogc
    {
        foreach (ref entry; entries)
            if (equalsIgnoreCase(entry.key, key))
                return true;
        return false;
    }

    /// The keys in insertion order.
    string[] keySet() const pure nothrow
    {
        auto keys = new string[entries.length];
        foreach (i, ref entry; entries)
            keys[i] = entry.key;
        return keys;
    }

    /// The parameters in insertion order.
    const(MimeTypeParameter)[] entrySet() const pure nothrow @nogc
    {
        return entries;
    }

    /// `foreach (key, value; parameters)`.
    int opApply(scope int delegate(string, string) pure @safe dg) const pure
    {
        foreach (ref entry; entries)
            if (auto result = dg(entry.key, entry.value))
                return result;
        return 0;
    }

    /// ditto
    int opApply(scope int delegate(string, string) @safe dg) const
    {
        foreach (ref entry; entries)
            if (auto result = dg(entry.key, entry.value))
                return result;
        return 0;
    }
}

/++
A MIME type (RFC 2046), with type, subtype and parameters.

Constructors check every token and parameter as Spring's do and throw `IllegalArgumentException` (or, from
`valueOf`, `InvalidMimeTypeException`).
+/
struct MimeType
{
    package(flint) enum string WILDCARD_TYPE = "*";
    private enum string PARAM_CHARSET = "charset";

    private string mimeType;
    private string mimeSubtype;
    private const(MimeTypeParameter)[] parameterList;
    private Charset resolvedCharset;
    /// Spring's cached `toStringValue`, set only where it costs nothing: at compile time for constants, and as a
    /// slice of the input when a parse is already canonical (`application/json`). Null otherwise.
    private string text;

    /// `type/*`.
    this(string type) pure
    {
        this(type, WILDCARD_TYPE);
    }

    /// `type/subtype` with no parameters.
    this(string type, string subtype) pure
    {
        this(type, subtype, cast(const(MimeTypeParameter)[]) null);
    }

    /// `type/subtype;charset=<charset>`.
    this(string type, string subtype, Charset charset) pure
    {
        this(type, subtype, [MimeTypeParameter(PARAM_CHARSET, charset.name())]);
    }

    /// `type/subtype` with `parameters`, checked and stored in order.
    this(string type, string subtype, scope const(MimeTypeParameter)[] parameters) pure
    {
        hasLength(type, "'type' must not be empty");
        hasLength(subtype, "'subtype' must not be empty");
        checkToken(type);
        checkToken(subtype);
        mimeType = toLowerAscii(type);
        mimeSubtype = toLowerAscii(subtype);
        parameterList = createParametersMap(parameters);
        resolveCharset();
    }

    /// A copy of `other` with its charset parameter set to `charset`.
    this(MimeType other, Charset charset) pure
    {
        mimeType = other.mimeType;
        mimeSubtype = other.mimeSubtype;
        auto map = other.parameterList.dup;
        put(map, MimeTypeParameter(PARAM_CHARSET, charset.name()));
        parameterList = map;
        resolvedCharset = charset;
    }

    /// A copy of `other`'s type and subtype with `parameters`.
    this(MimeType other, scope const(MimeTypeParameter)[] parameters) pure
    {
        mimeType = other.mimeType;
        mimeSubtype = other.mimeSubtype;
        parameterList = createParametersMap(parameters);
        resolveCharset();
    }

    private void resolveCharset() pure
    {
        const charset = parameters().get(PARAM_CHARSET);
        if (charset !is null)
            resolvedCharset = Charset.forName(unquote(charset));
    }

    private static void checkToken(scope const(char)[] token) pure
    {
        foreach (ch; token)
        {
            if (!isTokenChar(ch))
                throw new IllegalArgumentException("Invalid token character '" ~ ch ~ "' in token \"" ~ token.idup
                        ~ "\"");
        }
    }

    private const(MimeTypeParameter)[] createParametersMap(scope const(MimeTypeParameter)[] parameters) pure
    {
        if (parameters.length == 0)
            return null;
        MimeTypeParameter[] map;
        foreach (ref parameter; parameters)
        {
            checkParameters(parameter.key, parameter.value);
            put(map, parameter);
        }
        return map;
    }

    /// Spring's protected `checkParameters`: a non-empty token name and a token or quoted-string value.
    package(flint) static void checkParameters(string parameter, string value) pure
    {
        hasLength(parameter, "'parameter' must not be empty");
        hasLength(value, "'value' must not be empty");
        checkToken(parameter);
        if (!isQuotedString(value))
            checkToken(value);
    }

    private static bool isQuotedString(scope const(char)[] s) pure nothrow @nogc
    {
        if (s.length < 2)
            return false;
        return (s[0] == '"' && s[$ - 1] == '"') || (s[0] == '\'' && s[$ - 1] == '\'');
    }

    /// Spring's protected `unquote`: strips matching quotes and backslash escapes.
    package(flint) static string unquote(string s) pure nothrow
    {
        if (!isQuotedString(s))
            return s;
        string inner = s[1 .. $ - 1];
        bool escaped;
        foreach (c; inner)
            if (c == '\\')
                escaped = true;
        if (!escaped)
            return inner;
        char[] sb;
        for (size_t i = 0; i < inner.length; i++)
        {
            char c = inner[i];
            if (c == '\\' && i + 1 < inner.length)
            {
                i++;
                c = inner[i];
            }
            sb ~= c;
        }
        return sb.idup;
    }

    /// Whether the primary type is the wildcard `*`.
    bool isWildcardType() const pure nothrow @nogc
    {
        return getType() == WILDCARD_TYPE;
    }

    /// Whether the subtype is `*` or a suffixed wildcard such as `*+xml`.
    bool isWildcardSubtype() const pure nothrow @nogc
    {
        const subtype = getSubtype();
        return subtype == WILDCARD_TYPE || (subtype.length >= 2 && subtype[0 .. 2] == "*+");
    }

    /// Whether neither the type nor the subtype is a wildcard.
    bool isConcrete() const pure nothrow @nogc
    {
        return !isWildcardType() && !isWildcardSubtype();
    }

    /// The primary type, lowercase.
    string getType() const pure nothrow @nogc
    {
        return mimeType;
    }

    /// The subtype, lowercase.
    string getSubtype() const pure nothrow @nogc
    {
        return mimeSubtype;
    }

    /// The subtype suffix after the last `+` (RFC 6839), or `null`.
    string getSubtypeSuffix() const pure nothrow @nogc
    {
        const index = lastIndexOf(mimeSubtype, '+');
        if (index >= 0 && mimeSubtype.length > index)
            return mimeSubtype[index + 1 .. $];
        return null;
    }

    /// The charset parameter, or `null` (R5: a nullable value becomes a pointer).
    // dfmt off
    const(Charset)* getCharset() const pure nothrow @nogc return
    // dfmt on
    {
        return resolvedCharset == Charset.init ? null : &resolvedCharset;
    }

    /// The value of parameter `name`, ignoring case, or `null`.
    string getParameter(scope const(char)[] name) const pure nothrow @nogc
    {
        return parameters().get(name);
    }

    /// All parameters, read-only.
    MimeTypeParameters getParameters() const pure nothrow @nogc
    {
        return parameters();
    }

    private MimeTypeParameters parameters() const pure nothrow @nogc
    {
        return MimeTypeParameters(parameterList);
    }

    /++
    Whether this MIME type includes `other`: `text/*` includes `text/plain` and `text/html`;
    `application/*+xml` includes `application/soap+xml`. Not symmetric.
    +/
    bool includes(const MimeType other) const pure nothrow @nogc
    {
        if (other == MimeType.init)
            return false;
        if (isWildcardType())
            return true;
        else if (getType() == other.getType())
        {
            if (getSubtype() == other.getSubtype())
                return true;
            if (isWildcardSubtype())
            {
                const thisPlusIdx = lastIndexOf(getSubtype(), '+');
                if (thisPlusIdx == -1)
                    return true;
                else
                {
                    const otherPlusIdx = lastIndexOf(other.getSubtype(), '+');
                    if (otherPlusIdx != -1)
                    {
                        const thisSubtypeNoSuffix = getSubtype()[0 .. thisPlusIdx];
                        const thisSubtypeSuffix = getSubtype()[thisPlusIdx + 1 .. $];
                        const otherSubtypeSuffix = other.getSubtype()[otherPlusIdx + 1 .. $];
                        if (thisSubtypeSuffix == otherSubtypeSuffix && thisSubtypeNoSuffix == WILDCARD_TYPE)
                            return true;
                    }
                }
            }
        }
        return false;
    }

    /// Whether this MIME type is compatible with `other`. Symmetric.
    bool isCompatibleWith(const MimeType other) const pure nothrow @nogc
    {
        if (other == MimeType.init)
            return false;
        if (isWildcardType() || other.isWildcardType())
            return true;
        else if (getType() == other.getType())
        {
            if (getSubtype() == other.getSubtype())
                return true;
            if (isWildcardSubtype() || other.isWildcardSubtype())
                return wildcardSubtypeCompatible(other);
        }
        return false;
    }

    /// `isCompatibleWith` for equal types when either subtype is a wildcard (`*` or `*+suffix`).
    private bool wildcardSubtypeCompatible(const MimeType other) const pure nothrow @nogc
    {
        const thisSuffix = getSubtypeSuffix();
        const otherSuffix = other.getSubtypeSuffix();
        if (getSubtype() == WILDCARD_TYPE || other.getSubtype() == WILDCARD_TYPE)
            return true;
        else if (isWildcardSubtype() && thisSuffix !is null)
            return thisSuffix == other.getSubtype() || (otherSuffix !is null && thisSuffix == otherSuffix);
        else if (other.isWildcardSubtype() && otherSuffix !is null)
            return getSubtype() == otherSuffix || (thisSuffix !is null && otherSuffix == thisSuffix);
        return false;
    }

    /// Whether type and subtype equal `other`'s, ignoring parameters.
    bool equalsTypeAndSubtype(const MimeType other) const pure nothrow @nogc
    {
        if (other == MimeType.init)
            return false;
        return equalsIgnoreCase(mimeType, other.mimeType) && equalsIgnoreCase(mimeSubtype, other.mimeSubtype);
    }

    /// Whether some element of `mimeTypes` has this type and subtype.
    bool isPresentIn(scope const(MimeType)[] mimeTypes) const pure nothrow @nogc
    {
        foreach (ref candidate; mimeTypes)
            if (candidate.equalsTypeAndSubtype(this))
                return true;
        return false;
    }

    /// Java's `equals`: type and subtype ignoring case, and equal parameters (charsets compared as charsets).
    bool equals(const MimeType other) const pure nothrow @nogc
    {
        return equalsIgnoreCase(mimeType, other.mimeType) && equalsIgnoreCase(mimeSubtype,
                other.mimeSubtype) && parametersAreEqual(other);
    }

    bool opEquals(const MimeType other) const pure nothrow @nogc
    {
        return equals(other);
    }

    private bool parametersAreEqual(const MimeType other) const pure nothrow @nogc
    {
        if (parameterList.length != other.parameterList.length)
            return false;
        foreach (ref entry; parameterList)
        {
            if (!other.parameters().containsKey(entry.key))
                return false;
            if (equalsIgnoreCase(PARAM_CHARSET, entry.key))
            {
                if (resolvedCharset != other.resolvedCharset)
                    return false;
            }
            else if (!unquotedEquals(entry.value, other.parameters().get(entry.key)))
                return false;
        }
        return true;
    }

    private static bool unquotedEquals(string a, string b) pure nothrow @nogc
    {
        const x = isQuotedString(a) ? a[1 .. $ - 1] : a;
        const y = isQuotedString(b) ? b[1 .. $ - 1] : b;
        return x == y;
    }

    /// Java's `hashCode`.
    int hashCode() const pure nothrow
    {
        int result = javaHash(mimeType);
        result = 31 * result + javaHash(mimeSubtype);
        result = 31 * result + parametersHashCode();
        return result;
    }

    size_t toHash() const pure nothrow
    {
        return cast(size_t) cast(uint) hashCode();
    }

    private int parametersHashCode() const pure nothrow
    {
        int result = 0;
        foreach (ref entry; parameterList)
        {
            const valueHash = equalsIgnoreCase(PARAM_CHARSET, entry.key) ? (resolvedCharset == Charset.init
                    ? 0 : javaHash(resolvedCharset.name())) : javaHash(unquote(entry.value));
            result += javaHash(toLowerAscii(entry.key)) ^ valueHash;
        }
        return result;
    }

    /// `type/subtype;key=value...`, parameters in insertion order.
    string toString() const pure nothrow
    {
        if (text !is null)
            return text;
        return rendered(mimeType, mimeSubtype, parameterList); // one allocation, unique, so immutable
    }

    private static char[] rendered(string type, string subtype, scope const(MimeTypeParameter)[] params) pure nothrow
    {
        size_t length = type.length + 1 + subtype.length;
        foreach (ref entry; params)
            length += 2 + entry.key.length + entry.value.length;
        auto result = new char[](length);
        size_t at;
        void put(scope const(char)[] text) pure nothrow @nogc
        {
            result[at .. at + text.length] = text;
            at += text.length;
        }

        put(type);
        put("/");
        put(subtype);
        foreach (ref entry; params)
        {
            put(";");
            put(entry.key);
            put("=");
            put(entry.value);
        }
        return result;
    }

    /// Spring's protected `appendTo(StringBuilder)`.
    package(flint) void appendTo(ref char[] builder) const pure nothrow
    {
        builder ~= mimeType;
        builder ~= '/';
        builder ~= mimeSubtype;
        foreach (ref entry; parameterList)
        {
            builder ~= ';';
            builder ~= entry.key;
            builder ~= '=';
            builder ~= entry.value;
        }
    }

    /// Java's `compareTo`: type, subtype, parameter count, then parameters sorted by name.
    int compareTo(const MimeType other) const pure nothrow
    {
        int comp = compareIgnoreCase(getType(), other.getType());
        if (comp != 0)
            return comp;
        comp = compareIgnoreCase(getSubtype(), other.getSubtype());
        if (comp != 0)
            return comp;
        comp = getParameters().size() - other.getParameters().size();
        if (comp != 0)
            return comp;
        auto thisAttributes = sortedKeys(getParameters().keySet());
        auto otherAttributes = sortedKeys(other.getParameters().keySet());
        foreach (i, thisAttribute; thisAttributes)
        {
            comp = compareParameter(other, thisAttribute, otherAttributes[i]);
            if (comp != 0)
                return comp;
        }
        return 0;
    }

    /// `compareTo` for the parameters at one position: names, then values (charsets compared as charsets).
    private int compareParameter(const MimeType other, string thisAttribute, string otherAttribute) const pure nothrow
    {
        const comp = compareIgnoreCase(thisAttribute, otherAttribute);
        if (comp != 0)
            return comp;
        if (equalsIgnoreCase(PARAM_CHARSET, thisAttribute))
        {
            const thisCharset = getCharset();
            const otherCharset = other.getCharset();
            if (thisCharset is null || otherCharset is null)
                return thisCharset is otherCharset ? 0 : thisCharset is null ? -1 : 1;
            return thisCharset.compareTo(*otherCharset);
        }
        const thisValue = getParameters().get(thisAttribute);
        string otherValue = other.getParameters().get(otherAttribute);
        if (otherValue is null)
            otherValue = "";
        return compareOrdinal(unquote(thisValue), unquote(otherValue));
    }

    int opCmp(const MimeType other) const pure nothrow
    {
        return compareTo(other);
    }

    /// Whether this type is more specific than `other` (wildcards, then parameter count).
    bool isMoreSpecific(const MimeType other) const pure nothrow @nogc
    {
        const thisWildcard = isWildcardType();
        const otherWildcard = other.isWildcardType();
        if (thisWildcard && !otherWildcard) // */* > audio/*
            return false;
        else if (!thisWildcard && otherWildcard) // audio/* < */*
            return true;
        else
        {
            const thisWildcardSubtype = isWildcardSubtype();
            const otherWildcardSubtype = other.isWildcardSubtype();
            if (thisWildcardSubtype && !otherWildcardSubtype) // audio/* > audio/basic
                return false;
            else if (!thisWildcardSubtype && otherWildcardSubtype) // audio/basic < audio/*
                return true;
            else if (getType() == other.getType() && getSubtype() == other.getSubtype())
                return getParameters().size() > other.getParameters().size();
            else
                return false;
        }
    }

    /// Whether this type is less specific than `other`.
    bool isLessSpecific(const MimeType other) const pure nothrow @nogc
    {
        return other.isMoreSpecific(this);
    }

    /// A constant whose type and subtype are already valid lowercase tokens (CTFE-friendly).
    package(flint) static MimeType literal(string type, string subtype) pure nothrow @nogc
    {
        MimeType result;
        result.mimeType = type;
        result.mimeSubtype = subtype;
        if (__ctfe)
            result.text = type ~ "/" ~ subtype;
        return result;
    }

    /// Parses `value`, as `MimeTypeUtils.parseMimeType`.
    static MimeType valueOf(string value) pure
    {
        return MimeTypeUtils.parseMimeType(value);
    }
}

/// `org.springframework.util.InvalidMimeTypeException`.
class InvalidMimeTypeException : IllegalArgumentException
{
    private string invalidMimeType;

    ///
    this(string mimeType, string message, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message is null
                ? "Invalid mime type \"" ~ mimeType ~ "\"" : "Invalid mime type \"" ~ mimeType ~ "\": " ~ message,
                null, file, line);
        invalidMimeType = mimeType;
    }

    /// The offending MIME type.
    string getMimeType() const pure nothrow @nogc
    {
        return invalidMimeType;
    }
}

/// `org.springframework.util.MimeTypeUtils`: constants and parsing.
struct MimeTypeUtils
{
    static immutable MimeType ALL = MimeType.literal("*", "*"); ///
    enum string ALL_VALUE = "*/*"; ///
    static immutable MimeType APPLICATION_GRAPHQL = MimeType.literal("application", "graphql+json"); ///
    enum string APPLICATION_GRAPHQL_VALUE = "application/graphql+json"; ///
    static immutable MimeType APPLICATION_JSON = MimeType.literal("application", "json"); ///
    enum string APPLICATION_JSON_VALUE = "application/json"; ///
    static immutable MimeType APPLICATION_OCTET_STREAM = MimeType.literal("application", "octet-stream"); ///
    enum string APPLICATION_OCTET_STREAM_VALUE = "application/octet-stream"; ///
    static immutable MimeType APPLICATION_XML = MimeType.literal("application", "xml"); ///
    enum string APPLICATION_XML_VALUE = "application/xml"; ///
    static immutable MimeType IMAGE_GIF = MimeType.literal("image", "gif"); ///
    enum string IMAGE_GIF_VALUE = "image/gif"; ///
    static immutable MimeType IMAGE_JPEG = MimeType.literal("image", "jpeg"); ///
    enum string IMAGE_JPEG_VALUE = "image/jpeg"; ///
    static immutable MimeType IMAGE_PNG = MimeType.literal("image", "png"); ///
    enum string IMAGE_PNG_VALUE = "image/png"; ///
    static immutable MimeType TEXT_HTML = MimeType.literal("text", "html"); ///
    enum string TEXT_HTML_VALUE = "text/html"; ///
    static immutable MimeType TEXT_PLAIN = MimeType.literal("text", "plain"); ///
    enum string TEXT_PLAIN_VALUE = "text/plain"; ///
    static immutable MimeType TEXT_XML = MimeType.literal("text", "xml"); ///
    enum string TEXT_XML_VALUE = "text/xml"; ///

    /++
    Parses one MIME type.
    Throws: `InvalidMimeTypeException` when it cannot be parsed.
    +/
    static MimeType parseMimeType(string mimeType) pure
    {
        if (mimeType.length == 0)
            throw new InvalidMimeTypeException(mimeType, "'mimeType' must not be empty");
        return MimeTypeParser(mimeType).parse();
    }

    /// Parses a comma-separated list of MIME types.
    static MimeType[] parseMimeTypes(string mimeTypes) pure
    {
        // One allocation: count the tokens, then parse each into its slot (Accept headers, every request).
        const count = countMimeTypes(mimeTypes);
        if (count == 0)
            return null;
        auto result = new MimeType[count];
        size_t i;
        string token;
        for (size_t at; nextToken(mimeTypes, at, token);)
            result[i++] = parseMimeType(token);
        return result;
    }

    /// How many MIME types the comma-separated list `mimeTypes` holds (its non-blank tokens), for callers that
    /// size their own result before `eachMimeType`.
    package(flint) static size_t countMimeTypes(string mimeTypes) pure nothrow @nogc
    {
        size_t count;
        string token;
        for (size_t at; nextToken(mimeTypes, at, token);)
            count++;
        return count;
    }

    /// Parse each MIME type of the comma-separated list `mimeTypes`, in order, into `sink`, allocating nothing
    /// unless a type has parameters. Throws `InvalidMimeTypeException` as `parseMimeType` does.
    package(flint) static void eachMimeType(string mimeTypes, scope void delegate(MimeType) pure @safe sink) pure
    {
        string token;
        for (size_t at; nextToken(mimeTypes, at, token);)
            sink(parseMimeType(token));
    }

    /// Splits a comma-separated list, honouring quoted strings.
    deprecated("since 7.1.0, for removal") static string[] tokenize(string mimeTypes) pure nothrow
    {
        return tokenizeList(mimeTypes);
    }

    package(flint) static string[] tokenizeList(string mimeTypes) pure nothrow
    {
        // Two passes, so the result is allocated once at its size (this runs on every request's Accept header).
        size_t count;
        string token;
        for (size_t at; nextToken(mimeTypes, at, token);)
            count++;
        if (count == 0)
            return null;
        auto tokens = new string[](count);
        size_t i;
        for (size_t at; nextToken(mimeTypes, at, token);)
            tokens[i++] = token;
        return tokens;
    }

    /// The next non-empty trimmed token of a comma-separated list from `at`, honouring quotes and escapes; false at
    /// the end.
    private static bool nextToken(string list, ref size_t at, out string token) pure nothrow @nogc
    {
        while (at < list.length)
        {
            bool inQuotes;
            size_t i = at;
            while (i < list.length && (inQuotes || list[i] != ','))
            {
                if (list[i] == '"')
                    inQuotes = !inQuotes;
                else if (list[i] == '\\')
                    i++;
                i++;
            }
            const end = i < list.length ? i : list.length;
            token = javaTrim(list[at .. end]);
            at = end + 1;
            if (token.length != 0)
                return true;
        }
        return false;
    }

    /// Joins with `", "`.
    static string toString(scope const(MimeType)[] mimeTypes) pure nothrow
    {
        char[] builder;
        foreach (i, ref mimeType; mimeTypes)
        {
            mimeType.appendTo(builder);
            if (i + 1 < mimeTypes.length)
                builder ~= ", ";
        }
        return builder.idup;
    }

    /++
    Sorts by specificity with Spring's stable bubble sort.
    Throws: `InvalidMimeTypeException` for more than 50 elements.
    +/
    static void sortBySpecificity(T)(T[] mimeTypes)
    {
        if (mimeTypes.length > 50)
        {
            string joined;
            foreach (i, ref mimeType; mimeTypes)
                joined ~= (i == 0 ? "" : ", ") ~ mimeType.toString();
            throw new InvalidMimeTypeException(joined, "Too many elements");
        }
        bubbleSort!((ref a, ref b) => a.isLessSpecific(b))(mimeTypes);
    }

    package(flint) static void bubbleSort(alias swap, T)(T[] list)
    {
        const len = list.length;
        for (size_t i = 0; i < len; i++)
        {
            for (size_t j = 1; j < len - i; j++)
            {
                if (swap(list[j - 1], list[j]))
                {
                    auto prev = list[j - 1];
                    list[j - 1] = list[j];
                    list[j] = prev;
                }
            }
        }
    }
}

private struct MimeTypeParser
{
    private enum State : ubyte
    {
        INITIAL,
        TYPE,
        SUBTYPE,
        PARAM_SEPARATOR,
        WHITESPACE,
        PARAM_NAME,
        PARAM_NAME_END,
        PARAM_VALUE_START,
        PARAM_VALUE_TOKEN,
        PARAM_VALUE_QUOTED,
        PARAM_VALUE_ESCAPED
    }

    string input;
    size_t index;
    size_t mark;
    string type = "";
    string subtype = "";
    MimeTypeParameter[] parameters;
    string paramName;
    MimeType parsed;
    bool hasParsed;

    this(string input) pure nothrow @nogc
    {
        this.input = input;
    }

    MimeType parse() pure
    {
        State state = State.INITIAL;
        for (; index < input.length; index++)
            state = process(state, input[index]);
        onEof(state);
        if (!hasParsed)
            throw new InvalidMimeTypeException(input, "'mimeType' must not be empty");
        return parsed;
    }

    private State process(State state, char c) pure
    {
        final switch (state)
        {
        case State.INITIAL:
            return initial(state, c);
        case State.TYPE:
            return inType(state, c);
        case State.SUBTYPE:
            return inSubtype(state, c);
        case State.PARAM_SEPARATOR:
            return afterParameter(state, c);
        case State.WHITESPACE:
        case State.PARAM_NAME:
        case State.PARAM_NAME_END:
        case State.PARAM_VALUE_START:
        case State.PARAM_VALUE_TOKEN:
        case State.PARAM_VALUE_QUOTED:
        case State.PARAM_VALUE_ESCAPED:
            return processParameter(state, c);
        }
    }

    /// `process` for the states inside a parameter.
    private State processParameter(State state, char c) pure
    {
        switch (state)
        {
        case State.WHITESPACE:
            return beforeParameterName(state, c);
        case State.PARAM_NAME:
            return inParameterName(state, c);
        case State.PARAM_NAME_END:
            return afterParameterName(state, c);
        case State.PARAM_VALUE_START:
            return beforeParameterValue(state, c);
        case State.PARAM_VALUE_TOKEN:
            return inTokenValue(state, c);
        case State.PARAM_VALUE_QUOTED:
            return inQuotedValue(state, c);
        default:
            assert(state == State.PARAM_VALUE_ESCAPED);
            return State.PARAM_VALUE_QUOTED;
        }
    }

    private State initial(State state, char c) pure
    {
        if (c == ' ' || c == '\t')
            return state;
        mark = index;
        return State.TYPE;
    }

    private State inType(State state, char c) pure
    {
        if (c == '/')
        {
            type = input[mark .. index];
            if (type.length == 0)
                throw new InvalidMimeTypeException(input, "'type' must not be empty");
            mark = index + 1;
            return State.SUBTYPE;
        }
        if (c == ';' || c == ' ' || c == '\t')
        {
            resolveBareType(input[mark .. index]);
            return c == ';' ? State.WHITESPACE : State.PARAM_SEPARATOR;
        }
        return state;
    }

    private State inSubtype(State state, char c) pure
    {
        if (c == ';' || c == ' ' || c == '\t')
        {
            subtype = input[mark .. index];
            return c == ';' ? State.WHITESPACE : State.PARAM_SEPARATOR;
        }
        return state;
    }

    private State afterParameter(State state, char c) pure
    {
        if (c == ' ' || c == '\t')
            return state;
        if (c == ';')
            return State.WHITESPACE;
        throw new InvalidMimeTypeException(input, "Unexpected character '" ~ c ~ "', expected ';'");
    }

    private State beforeParameterName(State state, char c) pure
    {
        if (c == ' ' || c == '\t' || c == ';')
            return state;
        if (c == '=')
            throw new InvalidMimeTypeException(input, "missing parameter name before '='");
        mark = index;
        return State.PARAM_NAME;
    }

    private State inParameterName(State state, char c) pure
    {
        if (c == '=')
        {
            paramName = input[mark .. index];
            return State.PARAM_VALUE_START;
        }
        if (c == ' ' || c == '\t')
        {
            paramName = input[mark .. index];
            return State.PARAM_NAME_END;
        }
        if (c == ';')
        {
            paramName = input[mark .. index];
            throw missingParameterValue();
        }
        return state;
    }

    private State afterParameterName(State state, char c) pure
    {
        if (c == ' ' || c == '\t')
            return state;
        if (c == '=')
            return State.PARAM_VALUE_START;
        if (c == ';')
            throw missingParameterValue();
        throw new InvalidMimeTypeException(input, "Unexpected character '" ~ c ~ "' after parameter name");
    }

    private State beforeParameterValue(State state, char c) pure
    {
        if (c == ' ' || c == '\t')
            return state;
        if (c == ';')
            throw missingParameterValue();
        mark = index;
        return c == '"' ? State.PARAM_VALUE_QUOTED : State.PARAM_VALUE_TOKEN;
    }

    private State inTokenValue(State state, char c) pure
    {
        if (c == ';' || c == ' ' || c == '\t')
        {
            extractParameter(input[mark .. index]);
            return c == ';' ? State.WHITESPACE : State.PARAM_SEPARATOR;
        }
        return state;
    }

    private State inQuotedValue(State state, char c) pure
    {
        if (c == '"')
        {
            extractParameter(input[mark .. index + 1]);
            return State.PARAM_SEPARATOR;
        }
        if (c == '\\')
            return State.PARAM_VALUE_ESCAPED;
        return state;
    }

    private void onEof(State state) pure
    {
        final switch (state)
        {
        case State.INITIAL:
            break;
        case State.TYPE:
            resolveBareType(input[mark .. $]);
            emitMimeType();
            break;
        case State.SUBTYPE:
            subtype = input[mark .. $];
            emitMimeType();
            break;
        case State.PARAM_SEPARATOR:
            emitMimeType();
            break;
        case State.WHITESPACE:
            if (type.length != 0)
                emitMimeType();
            break;
        case State.PARAM_NAME:
            paramName = input[mark .. $];
            throw missingParameterValue();
        case State.PARAM_NAME_END:
        case State.PARAM_VALUE_START:
            throw missingParameterValue();
        case State.PARAM_VALUE_TOKEN:
        case State.PARAM_VALUE_QUOTED:
        case State.PARAM_VALUE_ESCAPED:
            extractParameter(input[mark .. $]);
            emitMimeType();
            break;
        }
    }

    private void resolveBareType(string candidate) pure
    {
        if (candidate != MimeType.WILDCARD_TYPE)
            throw new InvalidMimeTypeException(input, "does not contain '/'");
        type = MimeType.WILDCARD_TYPE;
        subtype = MimeType.WILDCARD_TYPE;
    }

    private void extractParameter(string value) pure
    {
        if (javaTrim(paramName).length == 0)
            throw new IllegalArgumentException("'paramName' must not be empty");
        foreach (ref existing; parameters)
            if (equalsIgnoreCase(existing.key, paramName))
                throw new InvalidMimeTypeException(input, "duplicate parameter '" ~ paramName ~ "=" ~ value ~ "'");
        parameters ~= MimeTypeParameter(paramName, value);
    }

    /// Whether the input is exactly `type/subtype`, so it can be the parsed type's text.
    private bool isCanonical(string parsedType, string parsedSubtype) const pure nothrow @nogc
    {
        const t = parsedType.length;
        return input.length == t + 1 + parsedSubtype.length && input[0 .. t] == parsedType
            && input[t] == '/' && input[t + 1 .. $] == parsedSubtype;
    }

    private InvalidMimeTypeException missingParameterValue() pure
    {
        return new InvalidMimeTypeException(input, "missing value for parameter '" ~ paramName ~ "'");
    }

    private void emitMimeType() pure
    {
        if (type == MimeType.WILDCARD_TYPE && subtype != MimeType.WILDCARD_TYPE)
            throw new InvalidMimeTypeException(input, "wildcard type is legal only in '*/*' (all mime types)");
        try
        {
            parsed = MimeType(type, subtype, parameters);
            if (parameters.length == 0 && isCanonical(parsed.mimeType, parsed.mimeSubtype))
                parsed.text = input;
        }
        catch (UnsupportedCharsetException ex)
            throw new InvalidMimeTypeException(input, "unsupported charset '" ~ ex.getCharsetName() ~ "'");
        catch (IllegalArgumentException ex)
            throw new InvalidMimeTypeException(input, ex.getMessage());
        hasParsed = true;
    }
}

// ---------------------------------------------------------------------------------------------------------
// Text helpers (Java String semantics on ASCII; R14).

private bool isTokenChar(char ch) pure nothrow @nogc
{
    if (ch <= 31 || ch >= 127)
        return false;
    foreach (separator; "()<>@,;:\\\"/[]?={} \t")
        if (ch == separator)
            return false;
    return true;
}

private void hasLength(scope const(char)[] text, string message) pure
{
    if (text.length == 0)
        throw new IllegalArgumentException(message);
}

private void put(ref MimeTypeParameter[] map, MimeTypeParameter entry) pure nothrow
{
    foreach (i, ref existing; map)
    {
        if (equalsIgnoreCase(existing.key, entry.key))
        {
            // LinkedCaseInsensitiveMap.put drops the old key and appends the new one.
            map = map[0 .. i] ~ map[i + 1 .. $] ~ entry;
            return;
        }
    }
    map ~= entry;
}

package(flint) string toLowerAscii(string text) pure nothrow
{
    foreach (i, c; text)
    {
        if (c >= 'A' && c <= 'Z')
        {
            auto result = text.dup;
            foreach (ref d; result[i .. $])
                if (d >= 'A' && d <= 'Z')
                    d = cast(char)(d + 32);
            return result.idup;
        }
    }
    return text;
}

package(flint) int compareIgnoreCase(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    const n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n)
    {
        const x = lowerChar(a[i]), y = lowerChar(b[i]);
        if (x != y)
            return x - y;
    }
    return cast(int) a.length - cast(int) b.length;
}

private int compareOrdinal(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    const n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n)
        if (a[i] != b[i])
            return a[i] - b[i];
    return cast(int) a.length - cast(int) b.length;
}

private char lowerChar(char c) pure nothrow @nogc
{
    return c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
}

private ptrdiff_t lastIndexOf(scope const(char)[] text, char c) pure nothrow @nogc
{
    for (ptrdiff_t i = cast(ptrdiff_t) text.length - 1; i >= 0; i--)
        if (text[i] == c)
            return i;
    return -1;
}

private string[] sortedKeys(string[] keys) pure nothrow
{
    // Insertion sort by String.CASE_INSENSITIVE_ORDER; parameter lists are short.
    for (size_t i = 1; i < keys.length; i++)
    {
        auto key = keys[i];
        size_t j = i;
        while (j > 0 && compareIgnoreCase(keys[j - 1], key) > 0)
        {
            keys[j] = keys[j - 1];
            j--;
        }
        keys[j] = key;
    }
    return keys;
}

private int javaHash(scope const(char)[] text) pure nothrow @nogc
{
    int hash;
    foreach (c; text)
        hash = 31 * hash + c; // ASCII tokens; MIME tokens are ASCII by construction
    return hash;
}
