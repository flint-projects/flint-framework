/++
Ported from FasterXML/jackson-databind 3.1.8, src/test/java/tools/jackson/databind/testutil/DatabindTestUtil.java
and JacksonTestUtilBase.java (the helpers the ported upstream tests use).
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: only the helpers the D ports call; `newJsonMapper` and `jsonMapperBuilder` take the
Flint AOT descriptor table of the test's beans, which Jackson finds by reflection; `assertThrows` stands in for
JUnit's, and `verifyException` reads a `DatabindException`'s reference chain as Jackson's `getMessage()` prints it.
+/
module databind_test_util;

import flint.engine.aot.descriptor : DescriptorTable;
import flint.jackson.core : StreamReadFeature;
import flint.jackson.databind : DatabindException, JsonMapper;

@safe:

/// `JacksonTestUtilBase.q`: `str` in double quotes.
string q(string str) pure nothrow
{
    return '"' ~ str ~ '"';
}

/// `JacksonTestUtilBase.a2q`: apostrophes to double quotes.
string a2q(string json) pure nothrow
{
    auto text = json.dup;
    foreach (ref c; text)
        if (c == '\'')
            c = '"';
    return text.idup;
}

/// `DatabindTestUtil.jsonMapperBuilder`, over the descriptors of the test's types (null for the built-ins only).
JsonMapper.Builder jsonMapperBuilder(DescriptorTable descriptors = null)
{
    auto b = JsonMapper.builder().enable(StreamReadFeature.INCLUDE_SOURCE_IN_LOCATION);
    if (descriptors !is null)
        b.descriptors(descriptors);
    return b;
}

/// `DatabindTestUtil.newJsonMapper`.
JsonMapper newJsonMapper(DescriptorTable descriptors = null)
{
    return jsonMapperBuilder(descriptors).build();
}

/// The text Jackson's `getMessage()` holds: the message, its location and its reference chain.
string messageOf(Exception e)
{
    if (auto d = cast(DatabindException) e)
        return d.toString();
    return e.msg;
}

/// `JacksonTestUtilBase.verifyException`: the message contains one of `anyMatches`, ignoring case.
void verifyException(Exception e, string[] anyMatches...)
{
    import std.string : indexOf;
    import std.uni : toLower;

    const text = messageOf(e).toLower();
    foreach (match; anyMatches)
        if (text.indexOf(match.toLower()) >= 0)
            return;
    assert(false, "Expected an exception with one of " ~ joinQuoted(anyMatches) ~ ", got: " ~ messageOf(e));
}

private string joinQuoted(scope const(string)[] items) pure
{
    string text;
    foreach (i, item; items)
        text ~= (i ? ", " : "") ~ "'" ~ item ~ "'";
    return "(" ~ text ~ ")";
}

/// JUnit's `assertThrows`: run `action`, which must throw an `E`, and return what it threw.
E assertThrows(E : Exception)(scope void delegate() @safe action, string label = null)
{
    try
        action();
    catch (E e)
        return e;
    assert(false, "Expected " ~ E.stringof ~ (label.length ? " from " ~ label : "") ~ ", but nothing was thrown");
}
