/++
`org.springframework.test.util`: assertion helpers and JSON path evaluation for test matchers.

Ported from spring-projects/spring-framework v7.1.0, spring-test/src/main/java/org/springframework/test/util/
(AssertionErrors.java, JsonPathExpectationsHelper.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: failures throw `flint.java.lang.AssertionError`, a D `Exception` (rulebook R8).
JSON path evaluation is an interim subset of Jayway JsonPath (`$`, `.name`, `['name']`, `[n]`, `[*]`, `.*`,
`..name`) over the JSON tree, until the JsonPath port is settled with the third-party-apis session
(docs/spring/phase1/web-mvc.md, open question 2).
+/
module flint.test.util;

import flint.java.lang : AssertionError;
import std.json : JSONType, JSONValue, parseJSON, JSONException;

@safe:

/// `AssertionErrors`.
struct AssertionErrors
{
    /// Fails with `message`.
    static void fail(string message)
    {
        throw new AssertionError(message);
    }

    /// Fails with `message` and Spring's `expected:<...> but was:<...>` suffix.
    static void fail(string message, string expected, string actual)
    {
        throw new AssertionError(message ~ " expected:<" ~ expected ~ "> but was:<" ~ actual ~ ">");
    }

    /// Fails unless `condition`.
    static void assertTrue(string message, bool condition)
    {
        if (!condition)
            fail(message);
    }

    /// Fails if `condition`.
    static void assertFalse(string message, bool condition)
    {
        if (condition)
            fail(message);
    }

    /// Fails if `object` is not null.
    static void assertNull(string message, bool isNull)
    {
        if (!isNull)
            fail(message);
    }

    /// Fails if `object` is null.
    static void assertNotNull(string message, bool isNull)
    {
        if (isNull)
            fail(message);
    }

    /// Fails unless `expected == actual`.
    static void assertEquals(T, U)(string message, T expected, U actual)
    {
        if (!(expected == actual))
            fail(message, text(expected), text(actual));
    }

    /// Fails if `expected == actual`.
    static void assertNotEquals(T, U)(string message, T expected, U actual)
    {
        if (expected == actual)
            fail(message ~ " was not expected to be:<" ~ text(actual) ~ ">");
    }

    private static string text(T)(T value)
    {
        import std.conv : to;

        static if (is(T == typeof(null)))
            return "null";
        else static if (is(T : const(char)[]))
            return value is null ? "null" : value.idup;
        else static if (is(T == struct) && __traits(hasMember, T, "toString"))
            return value.toString();
        else static if (is(T == class))
            return value is null ? "null" : typeid(value).name;
        else
            return value.to!string;
    }
}

/// `JsonPathExpectationsHelper`: evaluates a JSON path against content and asserts on the result.
struct JsonPathExpectationsHelper
{
    private string expression;

    /// For `expression` (Java's `String.format`-style arguments are applied by the caller).
    this(string expression) pure nothrow @nogc
    {
        this.expression = expression;
    }

    /// The expression.
    string getExpression() const pure nothrow @nogc
    {
        return expression;
    }

    /// Asserts the value at the path equals `expectedValue`, converting the JSON value to `T`.
    void assertValue(T)(string content, T expectedValue)
    {
        bool definite;
        auto matches = evaluate(content, definite);
        JSONValue actual;
        if (!definite)
        {
            static if (!is(T == E[], E) || is(T : const(char)[]))
            {
                if (matches.length == 0)
                    AssertionErrors.fail("No matching value at JSON path \"" ~ expression ~ "\"");
                if (matches.length != 1)
                    AssertionErrors.fail("Got a list of values " ~ listText(
                            matches) ~ " instead of the expected single value " ~ AssertionErrors.text(expectedValue));
                actual = matches[0];
            }
            else
                actual = JSONValue(matches);
        }
        else
        {
            if (matches.length == 0)
                AssertionErrors.fail("No value at JSON path \"" ~ expression ~ "\"");
            actual = matches[0];
        }
        T converted;
        if (!convert(actual, converted))
            AssertionErrors.fail("At JSON path \"" ~ expression ~ "\", value <" ~ actual.toString()
                    ~ "> of type <" ~ jsonTypeName(actual) ~ "> cannot be converted to type <" ~ T.stringof ~ ">");
        AssertionErrors.assertEquals("JSON path \"" ~ expression ~ "\"", expectedValue, converted);
    }

    /// Asserts a non-null value exists at the path.
    void exists(string content)
    {
        bool definite;
        auto matches = evaluate(content, definite);
        const found = definite ? matches.length != 0 && matches[0].type != JSONType.null_ : matches.length != 0;
        AssertionErrors.assertTrue("No value at JSON path \"" ~ expression ~ "\"", found);
    }

    /// Asserts no value exists at the path.
    void doesNotExist(string content)
    {
        bool definite;
        auto matches = evaluate(content, definite);
        if (definite)
            AssertionErrors.assertTrue("Expected no value at JSON path \"" ~ expression ~ "\" but found: " ~ (
                    matches.length != 0 ? matches[0].toString() : ""), matches.length == 0);
        else
            AssertionErrors.assertTrue("Expected no value at JSON path \"" ~ expression ~ "\" but found: " ~ listText(
                    matches), matches.length == 0);
    }

    /// Asserts the value at the path is an array.
    void assertValueIsArray(string content)
    {
        assertType(content, JSONType.array, "an array");
    }

    /// Asserts the value at the path is a map.
    void assertValueIsMap(string content)
    {
        assertType(content, JSONType.object, "a map");
    }

    /// Asserts the value at the path is a string.
    void assertValueIsString(string content)
    {
        assertType(content, JSONType.string, "a string");
    }

    /// Asserts the value at the path is a boolean.
    void assertValueIsBoolean(string content)
    {
        bool definite;
        auto value = definiteValue(content);
        AssertionErrors.assertTrue(
                "Expected a boolean at JSON path \"" ~ expression ~ "\" but found: " ~ value.toString(),
                value.type == JSONType.true_ || value.type == JSONType.false_);
    }

    /// Asserts the value at the path is a number.
    void assertValueIsNumber(string content)
    {
        auto value = definiteValue(content);
        // dfmt off
        AssertionErrors.assertTrue("Expected a number at JSON path \"" ~ expression ~ "\" but found: "
                ~ value.toString(),
        // dfmt on
        value.type == JSONType.integer || value.type == JSONType.uinteger || value.type == JSONType.float_);
    }

    /// Asserts the value at the path is empty (an empty string, array or object, or null).
    void assertValueIsEmpty(string content)
    {
        auto value = definiteValue(content);
        AssertionErrors.assertTrue(
                "Expected an empty value at JSON path \"" ~ expression ~ "\" but found: " ~ value.toString(),
                isEmpty(value));
    }

    /// Asserts the value at the path is not empty.
    void assertValueIsNotEmpty(string content)
    {
        auto value = definiteValue(content);
        AssertionErrors.assertTrue(
                "Expected a non-empty value at JSON path \"" ~ expression ~ "\" but found: " ~ value.toString(),
                !isEmpty(value));
    }

    private void assertType(string content, JSONType type, string description)
    {
        auto value = definiteValue(content);
        AssertionErrors.assertTrue(
                "Expected " ~ description ~ " at JSON path \"" ~ expression ~ "\" but found: " ~ value.toString(),
                value.type == type);
    }

    private JSONValue definiteValue(string content)
    {
        bool definite;
        auto matches = evaluate(content, definite);
        if (matches.length == 0)
            AssertionErrors.fail("No value at JSON path \"" ~ expression ~ "\"");
        return definite ? matches[0] : JSONValue(matches);
    }

    private static bool isEmpty(JSONValue value)
    {
        switch (value.type)
        {
        case JSONType.null_:
            return true;
        case JSONType.string:
            return value.str.length == 0;
        case JSONType.array:
            return value.arrayNoRef.length == 0;
        case JSONType.object:
            return value.objectNoRef.length == 0;
        default:
            return false;
        }
    }

    /// Every value the path selects; `definite` is false for wildcards and deep scans.
    JSONValue[] evaluate(string content, out bool definite)
    {
        JSONValue root;
        try
            root = parseJSON(content);
        catch (JSONException ex)
            AssertionErrors.fail("Failed to parse JSON request content: " ~ ex.msg);
        definite = true;
        JSONValue[] current = [root];
        size_t i;
        const path = expression;
        if (path.length == 0 || path[0] != '$')
            AssertionErrors.fail("Invalid JSON path: " ~ path);
        i = 1;
        while (i < path.length)
        {
            if (path[i] == '.' && i + 1 < path.length && path[i + 1] == '.')
            {
                definite = false;
                i += 2;
                const name = readName(path, i);
                JSONValue[] next;
                foreach (value; current)
                    deepScan(value, name, next);
                current = next;
            }
            else if (path[i] == '.')
            {
                i++;
                if (i < path.length && path[i] == '*')
                {
                    definite = false;
                    i++;
                    current = children(current);
                    continue;
                }
                const name = readName(path, i);
                current = member(current, name);
            }
            else if (path[i] == '[')
            {
                const close = indexOf(path, ']', i);
                if (close < 0)
                    AssertionErrors.fail("Invalid JSON path: " ~ path);
                auto inside = path[i + 1 .. close];
                i = close + 1;
                if (inside == "*")
                {
                    definite = false;
                    current = children(current);
                }
                else if (inside.length >= 2 && (inside[0] == '\'' || inside[0] == '"'))
                    current = member(current, inside[1 .. $ - 1]);
                else
                {
                    import std.conv : to;

                    long index;
                    try
                        index = inside.to!long;
                    catch (Exception)
                        AssertionErrors.fail("Unsupported JSON path element [" ~ inside ~ "] in " ~ path);
                    current = element(current, index);
                }
            }
            else
                AssertionErrors.fail("Invalid JSON path: " ~ path);
        }
        return current;
    }

    private static string readName(string path, ref size_t i) pure
    {
        const start = i;
        while (i < path.length && path[i] != '.' && path[i] != '[')
            i++;
        return path[start .. i];
    }

    private static ptrdiff_t indexOf(string text, char c, size_t from) pure nothrow @nogc
    {
        foreach (j; from .. text.length)
            if (text[j] == c)
                return j;
        return -1;
    }

    private static JSONValue[] member(JSONValue[] values, string name)
    {
        JSONValue[] result;
        foreach (value; values)
            if (value.type == JSONType.object)
                if (auto found = name in value.objectNoRef)
                    result ~= *found;
        return result;
    }

    private static JSONValue[] element(JSONValue[] values, long index)
    {
        JSONValue[] result;
        foreach (value; values)
            if (value.type == JSONType.array)
            {
                auto array = value.arrayNoRef;
                const i = index < 0 ? cast(long) array.length + index : index;
                if (i >= 0 && i < array.length)
                    result ~= array[cast(size_t) i];
            }
        return result;
    }

    private static JSONValue[] children(JSONValue[] values)
    {
        JSONValue[] result;
        foreach (value; values)
        {
            if (value.type == JSONType.array)
                result ~= value.arrayNoRef;
            else if (value.type == JSONType.object)
                foreach (key, child; value.objectNoRef)
                    result ~= child;
        }
        return result;
    }

    private static void deepScan(JSONValue value, string name, ref JSONValue[] result)
    {
        if (value.type == JSONType.object)
        {
            if (auto found = name in value.objectNoRef)
                result ~= *found;
            foreach (key, child; value.objectNoRef)
                deepScan(child, name, result);
        }
        else if (value.type == JSONType.array)
            foreach (child; value.arrayNoRef)
                deepScan(child, name, result);
    }

    private static string listText(JSONValue[] values)
    {
        string text = "[";
        foreach (i, v; values)
            text ~= (i == 0 ? "" : ",") ~ v.toString();
        return text ~ "]";
    }

    private static string jsonTypeName(JSONValue value)
    {
        switch (value.type)
        {
        case JSONType.string:
            return "java.lang.String";
        case JSONType.integer, JSONType.uinteger:
            return "java.lang.Integer";
        case JSONType.float_:
            return "java.lang.Double";
        case JSONType.true_, JSONType.false_:
            return "java.lang.Boolean";
        case JSONType.array:
            return "net.minidev.json.JSONArray";
        case JSONType.object:
            return "java.util.LinkedHashMap";
        default:
            return "null";
        }
    }

    private static bool convert(T)(JSONValue value, out T result)
    {
        static if (is(T : const(char)[]))
        {
            if (value.type == JSONType.null_)
                return true;
            if (value.type != JSONType.string)
                return false;
            result = value.str;
            return true;
        }
        else static if (is(T == bool))
        {
            if (value.type != JSONType.true_ && value.type != JSONType.false_)
                return false;
            result = value.type == JSONType.true_;
            return true;
        }
        else static if (__traits(isIntegral, T))
        {
            if (value.type == JSONType.integer)
                result = cast(T) value.integer;
            else if (value.type == JSONType.uinteger)
                result = cast(T) value.uinteger;
            else
                return false;
            return true;
        }
        else static if (__traits(isFloating, T))
        {
            if (value.type == JSONType.float_)
                result = cast(T) value.floating;
            else if (value.type == JSONType.integer)
                result = cast(T) value.integer;
            else if (value.type == JSONType.uinteger)
                result = cast(T) value.uinteger;
            else
                return false;
            return true;
        }
        else static if (is(T == E[], E))
        {
            if (value.type != JSONType.array)
                return false;
            foreach (child; value.arrayNoRef)
            {
                E element;
                if (!convert(child, element))
                    return false;
                result ~= element;
            }
            return true;
        }
        else static if (is(T == typeof(null)))
            return value.type == JSONType.null_;
        else
            return false;
    }
}
