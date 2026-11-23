module flint.util.test_support;

@safe:

/// Run `action` and return the `E` it throws; fail when it throws nothing (AssertJ's `isThrownBy`).
E expectThrows(E : Throwable)(scope void delegate() @safe action, string file = __FILE__, size_t line = __LINE__)
{
    import std.conv : to;

    try
        action();
    catch (E e)
        return e;
    assert(false, "expected " ~ E.stringof ~ " at " ~ file ~ ":" ~ line.to!string);
}

/// Whether `text` contains `part`.
bool contains(scope const(char)[] text, scope const(char)[] part) pure nothrow @nogc
{
    for (size_t i = 0; i + part.length <= text.length; i++)
        if (text[i .. i + part.length] == part)
            return true;
    return false;
}
