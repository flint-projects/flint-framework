module flint.java.format_test;

import flint.java.lang : IllegalArgumentException, String;
import flint.java.util.formatter : IllegalFormatConversionException, MissingFormatArgumentException,
    UnknownFormatConversionException;

@safe:

// Expected values are JDK 21's String.format output for the same calls.

unittest
{
    assert(String.format("Hello, %s!", "World") == "Hello, World!");
    assert(String.format("%s %s", cast(Object) null, true) == "null true");
    assert(String.format("%5s|%-5s|%.2s", "ab", "ab", "abcdef") == "   ab|ab   |ab");
    assert(String.format("%S", "mixed Case") == "MIXED CASE");
    assert(String.format("%d", 42) == "42" && String.format("%d", -42L) == "-42");
    assert(String.format("%,d", 1_234_567) == "1,234,567");
    assert(String.format("%+d % d %(d", 5, 5, -5) == "+5  5 (5)");
    assert(String.format("%08d|%-8d|%8d", -42, 42, 42) == "-0000042|42      |      42");
    assert(String.format("%x %X %o", 255, 255, 8) == "ff FF 10");
    assert(String.format("%x", -1) == "ffffffff" && String.format("%x", -1L) == "ffffffffffffffff");
    assert(String.format("%#x %#o", 255, 8) == "0xff 010");
    assert(String.format("%c%c", 'A', 0x1F600) == "A\U0001F600");
    assert(String.format("%b %b %b %B", true, cast(Object) null, "x", false) == "true false true FALSE");
}

unittest
{
    assert(String.format("%f", 3.14159265) == "3.141593");
    assert(String.format("%.2f", 2.675) == "2.68"); // half up on Double.toString's digits
    assert(String.format("%.0f", 2.5) == "3");
    assert(String.format("%10.3f|%-10.3f|%010.3f", -1.5, 1.5, -1.5) == "    -1.500|1.500     |-00001.500");
    assert(String.format("%,.2f", 1_234_567.891) == "1,234,567.89");
    assert(String.format("%.3f", 9.9999) == "10.000" && String.format("%.2f", 1e-5) == "0.00");
    assert(String.format("%.1f", 1e21) == "1000000000000000000000.0");
    assert(String.format("%s", 1.0) == "1.0" && String.format("%s", 100.0f) == "100.0");
    assert(String.format("%s", 1e21) == "1.0E21");
}

unittest
{
    assert(String.format("%2$s %1$s", "a", "b") == "b a");
    assert(String.format("%s %<s %s", "a", "b") == "a a b");
    assert(String.format("100%% done%n") == "100% done\n");
    assert(String.format("no specifiers") == "no specifiers");
}

unittest
{
    import std.exception : collectException;

    auto missing = collectException!MissingFormatArgumentException(String.format("%s %s", "only"));
    assert(missing !is null && missing.msg == "Format specifier '%s'");
    auto unknown = collectException!UnknownFormatConversionException(String.format("%q", "x"));
    assert(unknown !is null && unknown.msg == "Conversion = 'q'");
    auto illegal = collectException!IllegalFormatConversionException(String.format("%d", "x"));
    assert(illegal !is null && illegal.msg == "d != java.lang.String");
    assert(collectException!IllegalFormatConversionException(String.format("%c", "x")).msg == "c != java.lang.String");
    // Every one is an IllegalArgumentException, as in Java.
    assert(collectException!IllegalArgumentException(String.format("%", "x")) !is null);
}
