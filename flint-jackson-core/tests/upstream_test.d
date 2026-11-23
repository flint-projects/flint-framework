/*
 * Ported from Jackson (jackson-core) 3.1.8 tests, https://github.com/FasterXML/jackson-core,
 * tag jackson-core-3.1.8, src/test/java/tools/jackson/core/unittest/:
 * read/ParserScopeMatchingTest, read/NumberParsingTest, read/NumberOverflowTest,
 * read/ArrayParsingTest, read/SimpleParserTest, read/ParserSequenceTest,
 * json/TestRootValues, write/GeneratorBasicTest, json/JsonWriteContextTest.
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D. Jackson runs each case over
 * byte streams, readers and DataInput; Flint has one byte-buffer parser, so each
 * case runs once. BigInteger and BigDecimal assertions wait for flint.java.math.
 */
module upstream_test;

import flint.jackson.core : JacksonException, JsonGenerator, JsonParser, JsonToken, ObjectWriteContext;
import flint.jackson.core.exc : InputCoercionException, StreamReadException, StreamWriteException;
import flint.jackson.core.json : JsonFactory;
import flint.jackson.core.util : ByteArrayBuilder;

@safe:

private JsonParser createParser(string doc)
{
    return JsonFactory.builder().build().createParser(doc);
}

// JacksonCoreTestBase.verifyException: a case-insensitive substring match.
private void verifyException(Exception e, string expected)
{
    import std.uni : toLower;
    import std.string : indexOf;

    assert(e.msg.toLower().indexOf(expected.toLower()) >= 0, "expected '" ~ expected ~ "' in: " ~ e.msg);
}

private void expectFailure(E : Exception = StreamReadException)(scope void delegate() @safe action, string expected)
{
    try
    {
        action();
        assert(false, "expected an exception containing: " ~ expected);
    }
    catch (E e)
        verifyException(e, expected);
}

// ParserScopeMatchingTest

@("ParserScopeMatchingTest.unclosedArray")
unittest
{
    auto p = createParser("[ 1, 2 ");
    assert(p.nextToken() == JsonToken.START_ARRAY);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    assert(p.getIntValue() == 2);
    expectFailure(() { p.nextToken(); }, "expected close marker for ARRAY");
}

@("ParserScopeMatchingTest.unclosedObject")
unittest
{
    auto p = createParser(`{ "key" : 3  `);
    assert(p.nextToken() == JsonToken.START_OBJECT);
    assert(p.nextToken() == JsonToken.PROPERTY_NAME);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    expectFailure(() { p.nextToken(); }, "expected close marker for OBJECT");
}

@("ParserScopeMatchingTest.eofInName")
unittest
{
    auto p = createParser(`{ "abcd`);
    assert(p.nextToken() == JsonToken.START_OBJECT);
    expectFailure(() { p.nextToken(); }, "Unexpected end-of-input");
}

@("ParserScopeMatchingTest.weirdToken")
unittest
{
    auto p = createParser("[ nil ]");
    assert(p.nextToken() == JsonToken.START_ARRAY);
    expectFailure(() { p.nextToken(); }, "Unrecognized token");
}

@("ParserScopeMatchingTest.mismatchArrayToObject")
unittest
{
    auto p = createParser("[ 1, 2 }");
    assert(p.nextToken() == JsonToken.START_ARRAY);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    expectFailure(() { p.nextToken(); }, "Unexpected close marker '}': expected ']'");
}

@("ParserScopeMatchingTest.mismatchObjectToArray")
unittest
{
    auto p = createParser("{ ]");
    assert(p.nextToken() == JsonToken.START_OBJECT);
    expectFailure(() { p.nextToken(); }, "Unexpected close marker ']': expected '}'");
}

@("ParserScopeMatchingTest.misssingColon")
unittest
{
    auto p = createParser(`{ "a" "b" }`);
    assert(p.nextToken() == JsonToken.START_OBJECT);
    expectFailure(() { p.nextToken(); p.nextToken(); }, "was expecting a colon");
}

// NumberParsingTest

@("NumberParsingTest.simpleInt")
unittest
{
    foreach (expected; [1234, -999, 0, 1, -2, 123_456_789])
    {
        import std.conv : to;

        auto p = createParser("[ " ~ expected.to!string ~ " ]");
        assert(p.nextToken() == JsonToken.START_ARRAY);
        assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
        assert(p.getNumberType() == JsonParser.NumberType.INT);
        assert(p.getIntValue() == expected && p.getLongValue() == expected);
        assert(p.getDoubleValue() == expected && p.getString() == expected.to!string);
        assert(p.nextToken() == JsonToken.END_ARRAY);
        assert(p.nextToken() == JsonToken.NOT_AVAILABLE);
    }
}

@("NumberParsingTest.intRange")
unittest
{
    auto p = createParser("[ 2147483647,-2147483648 ]");
    assert(p.nextToken() == JsonToken.START_ARRAY);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    assert(p.getNumberType() == JsonParser.NumberType.INT && p.getIntValue() == int.max);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    assert(p.getNumberType() == JsonParser.NumberType.INT && p.getIntValue() == int.min);
}

@("NumberParsingTest.simpleLong")
unittest
{
    auto p = createParser("[ 12345678907 ]");
    assert(p.nextToken() == JsonToken.START_ARRAY);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    assert(p.getNumberType() == JsonParser.NumberType.LONG);
    assert(p.getLongValue() == 12_345_678_907L);
    expectFailure!InputCoercionException(() { p.getIntValue(); }, "out of range of `int`");
}

@("NumberParsingTest.longRange")
unittest
{
    auto p = createParser("[ 9223372036854775807,-9223372036854775808 ]");
    assert(p.nextToken() == JsonToken.START_ARRAY);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    assert(p.getNumberType() == JsonParser.NumberType.LONG && p.getLongValue() == long.max);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    assert(p.getNumberType() == JsonParser.NumberType.LONG && p.getLongValue() == long.min);
}

@("NumberParsingTest.bigNumbers: 520 digits are a BIG_INTEGER, text kept")
unittest
{
    char[520] digits = '1';
    auto p = createParser(digits.idup ~ " ");
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    assert(p.getNumberType() == JsonParser.NumberType.BIG_INTEGER);
    assert(p.getString() == digits);
}

@("NumberParsingTest.simpleDouble")
unittest
{
    import std.conv : to;

    foreach (text; [
        "1234.00", "2.1101567E-16", "1.0e5", "0.0", "1.0", "-1.0", "-0.5", "-12.9", "-999.0",
        "2.5e+5", "9e4", "-12e-3", "0.25"
    ])
    {
        auto p = createParser("[" ~ text ~ "] ");
        assert(p.nextToken() == JsonToken.START_ARRAY);
        assert(p.nextToken() == JsonToken.VALUE_NUMBER_FLOAT);
        assert(p.getString() == text);
        assert(p.getDoubleValue() == text.to!double);
        assert(p.nextToken() == JsonToken.END_ARRAY);
        assert(p.nextToken() == JsonToken.NOT_AVAILABLE);

        p = createParser(text ~ " ");
        assert(p.nextToken() == JsonToken.VALUE_NUMBER_FLOAT && p.getString() == text);
        assert(p.nextToken() == JsonToken.NOT_AVAILABLE);
    }
}

@("NumberParsingTest.invalidNumbers: leading zeroes and missing digits")
unittest
{
    auto p = createParser("[ 01 ]");
    assert(p.nextToken() == JsonToken.START_ARRAY);
    expectFailure(() { p.nextToken(); }, "Leading zeroes not allowed");
    p = createParser("[ -x ]");
    assert(p.nextToken() == JsonToken.START_ARRAY);
    expectFailure(() { p.nextToken(); }, "Invalid numeric value");
}

// NumberOverflowTest

@("NumberOverflowTest.simpleLongOverflow")
unittest
{
    foreach (doc; ["-9223372036854775809 ", "9223372036854775808 "])
    {
        auto p = createParser(doc);
        p.nextToken();
        assert(p.getNumberType() == JsonParser.NumberType.BIG_INTEGER);
        expectFailure!InputCoercionException(() { p.getLongValue(); }, "out of range of `long`");
        expectFailure!InputCoercionException(() { p.getIntValue(); }, "out of range of `int`");
    }
}

// SimpleParserTest

@("SimpleParserTest.simpleValidity and keyword parsing")
unittest
{
    auto p = createParser(`{ "a" : true, "b" : false, "c" : null, "d" : "x" }`);
    assert(p.nextToken() == JsonToken.START_OBJECT);
    assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.currentName() == "a" && p.getString() == "a");
    assert(p.nextToken() == JsonToken.VALUE_TRUE && p.getBooleanValue() && p.currentName() == "a");
    assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.currentName() == "b");
    assert(p.nextToken() == JsonToken.VALUE_FALSE && !p.getBooleanValue());
    assert(p.nextToken() == JsonToken.PROPERTY_NAME);
    assert(p.nextToken() == JsonToken.VALUE_NULL && p.getString() == "null");
    assert(p.nextToken() == JsonToken.PROPERTY_NAME);
    assert(p.nextToken() == JsonToken.VALUE_STRING && p.getString() == "x");
    assert(p.nextToken() == JsonToken.END_OBJECT);
    assert(p.nextToken() == JsonToken.NOT_AVAILABLE);
}

@("SimpleParserTest.keywordsAsWords: trailing letters are an unrecognized token")
unittest
{
    foreach (doc; ["[ truex ]", "[ nullx ]", "[ falsey ]"])
    {
        auto p = createParser(doc);
        assert(p.nextToken() == JsonToken.START_ARRAY);
        expectFailure(() { p.nextToken(); }, "Unrecognized token");
    }
}

@("SimpleParserTest.skipping: skipChildren leaves the parser on the matching close")
unittest
{
    auto p = createParser(`[ 1, true, [ ], { "a" : 3 }, null, { "b" : [ { } ] }, 4 ]`);
    assert(p.nextToken() == JsonToken.START_ARRAY);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    p.skipChildren();
    assert(p.currentToken() == JsonToken.VALUE_NUMBER_INT);
    assert(p.nextToken() == JsonToken.VALUE_TRUE);
    assert(p.nextToken() == JsonToken.START_ARRAY);
    p.skipChildren();
    assert(p.currentToken() == JsonToken.END_ARRAY);
    assert(p.nextToken() == JsonToken.START_OBJECT);
    p.skipChildren();
    assert(p.currentToken() == JsonToken.END_OBJECT);
    assert(p.nextToken() == JsonToken.VALUE_NULL);
    assert(p.nextToken() == JsonToken.START_OBJECT);
    p.skipChildren();
    assert(p.currentToken() == JsonToken.END_OBJECT);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT && p.getIntValue() == 4);
    assert(p.nextToken() == JsonToken.END_ARRAY);
}

@("SimpleParserTest.stringEscapes: escapes and non-ASCII decode, names too")
unittest
{
    auto p = createParser(`{ "naïve" : "tab\t\"quote\" 😀 \/" }`);
    assert(p.nextToken() == JsonToken.START_OBJECT);
    assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.currentName() == "naïve");
    assert(p.nextToken() == JsonToken.VALUE_STRING);
    assert(p.getString() == "tab\t\"quote\" \U0001F600 /");
}

@("SimpleParserTest.invalidControlChars: raw control characters are rejected in strings")
unittest
{
    auto p = createParser("[ \"a\x01b\" ]");
    assert(p.nextToken() == JsonToken.START_ARRAY);
    expectFailure(() { p.nextToken(); }, "Illegal character");
}

@("SimpleParserTest.currentName at START_OBJECT names the enclosing property")
unittest
{
    auto p = createParser(`{ "owner" : { "id" : 1 }, "pets" : [ 2 ] }`);
    assert(p.nextToken() == JsonToken.START_OBJECT && p.currentName() is null);
    assert(p.nextToken() == JsonToken.PROPERTY_NAME);
    assert(p.nextToken() == JsonToken.START_OBJECT && p.currentName() == "owner");
    assert(p.nextToken() == JsonToken.PROPERTY_NAME && p.currentName() == "id");
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT && p.currentName() == "id");
    assert(p.nextToken() == JsonToken.END_OBJECT);
    assert(p.nextToken() == JsonToken.PROPERTY_NAME);
    assert(p.nextToken() == JsonToken.START_ARRAY && p.currentName() == "pets");
    assert(p.streamReadContext().pathAsPointer() == "/pets");
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT && p.streamReadContext().pathAsPointer() == "/pets/0");
}

// ArrayParsingTest

@("ArrayParsingTest.validEmpty and missing values")
unittest
{
    auto p = createParser("[   \n  ]");
    assert(p.nextToken() == JsonToken.START_ARRAY);
    assert(p.nextToken() == JsonToken.END_ARRAY);
    assert(p.nextToken() == JsonToken.NOT_AVAILABLE);

    p = createParser("[ 1, ]");
    assert(p.nextToken() == JsonToken.START_ARRAY);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    expectFailure(() { p.nextToken(); }, "expected a value");

    p = createParser("[ 1 2 ]");
    assert(p.nextToken() == JsonToken.START_ARRAY);
    assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
    expectFailure(() { p.nextToken(); }, "was expecting comma to separate Array entries");
}

// TestRootValues and ParserSequenceTest

@("TestRootValues.simpleNumbers: root values separated by any whitespace")
unittest
{
    auto p = createParser("1 2\t3\r4\n5\r\n6\r\n   7");
    foreach (i; 1 .. 8)
    {
        assert(p.nextToken() == JsonToken.VALUE_NUMBER_INT);
        assert(p.getIntValue() == i);
    }
    assert(p.nextToken() == JsonToken.NOT_AVAILABLE);
}

@("TestRootValues.brokeanNumber: a root number must end at a separator")
unittest
{
    auto p = createParser("12x");
    expectFailure(() { p.nextToken(); }, "Expected space separating root-level values");
}

@("ParserSequenceTest: mixed root values in sequence")
unittest
{
    auto p = createParser(`{ "a" : 1 } [ 2 ] "three" true`);
    assert(p.nextToken() == JsonToken.START_OBJECT);
    p.skipChildren();
    assert(p.nextToken() == JsonToken.START_ARRAY);
    p.skipChildren();
    assert(p.nextToken() == JsonToken.VALUE_STRING && p.getString() == "three");
    assert(p.nextToken() == JsonToken.VALUE_TRUE);
    assert(p.nextToken() == JsonToken.NOT_AVAILABLE);
}

@("value conversions: getValueAsXxx follow ParserMinimalBase")
unittest
{
    auto p = createParser(`[ "17", "abc", 3.75, true, null, " 4 " ]`);
    p.nextToken();
    p.nextToken();
    assert(p.getValueAsInt() == 17 && p.getValueAsLong() == 17 && p.getValueAsDouble() == 17.0);
    p.nextToken();
    assert(p.getValueAsInt(-1) == -1 && p.getValueAsString() == "abc");
    p.nextToken();
    assert(p.getValueAsInt() == 3 && p.getValueAsString() == "3.75");
    p.nextToken();
    assert(p.getValueAsInt() == 1 && p.getValueAsBoolean() && p.getValueAsString() == "true");
    p.nextToken();
    assert(p.getValueAsInt() == 0 && p.getValueAsString() is null && p.getValueAsString("d") == "d");
    p.nextToken();
    assert(p.getValueAsInt() == 4);
}

@("constraints: nesting deeper than 500 levels fails")
unittest
{
    import flint.jackson.core.exc : StreamConstraintsException;

    char[501] open = '[';
    auto p = createParser(open.idup);
    expectFailure!StreamConstraintsException(() {
        foreach (_; 0 .. 501)
            p.nextToken();
    }, "nesting depth (501) exceeds the maximum allowed (500");
}

@("location: line and column of the problem")
unittest
{
    auto p = createParser("[\n  1,\n  }");
    p.nextToken();
    p.nextToken();
    try
    {
        p.nextToken();
        assert(false);
    }
    catch (StreamReadException e)
    {
        assert(e.getLocation().getLineNr() == 3);
        assert(e.getOriginalMessage().length && e.msg.length > e.getOriginalMessage().length);
    }
}

// GeneratorBasicTest and JsonWriteContextTest

private string written(scope void delegate(JsonGenerator) @safe write)
{
    auto output = new ByteArrayBuilder();
    auto g = JsonFactory.builder().build().createGenerator(ObjectWriteContext.empty(), output);
    write(g);
    g.close();
    return output.toUtf8String();
}

@("GeneratorBasicTest.fieldValueWrites")
unittest
{
    assert(written((g) {
            g.writeStartObject();
            g.writeNumberProperty("short", cast(short) 3);
            g.writeNumberProperty("int", 3);
            g.writeNumberProperty("long", 3L);
            g.writeNumberProperty("double", 0.25);
            g.writeNumberProperty("float", -0.25f);
            g.writeEndObject();
        }) == `{"short":3,"int":3,"long":3,"double":0.25,"float":-0.25}`);
}

@("GeneratorBasicTest.rootIntsWrite")
unittest
{
    assert(written((g) { g.writeNumber(1); g.writeNumber(2); g.writeNumber(-13); }) == "1 2 -13");
}

@("GeneratorBasicTest.booleanWrite and nullWrite at the root and in arrays")
unittest
{
    assert(written((g) { g.writeBoolean(true); }) == "true");
    assert(written((g) {
            g.writeStartArray();
            g.writeNull();
            g.writeBoolean(false);
            g.writeEndArray();
        }) == "[null,false]");
}

@("GeneratorBasicTest.outputContext: names, indexes and nesting")
unittest
{
    written((g) {
        assert(g.streamWriteContext().inRoot());
        g.writeStartObject();
        assert(g.streamWriteContext().inObject());
        g.writeName("a");
        assert(g.streamWriteContext().currentName() == "a");
        g.writeStartArray();
        assert(g.streamWriteContext().inArray());
        g.writeStartObject();
        g.writeName("b");
        auto ctxt = g.streamWriteContext();
        assert(ctxt.currentName() == "b");
        g.writeNumber(123);
        assert(ctxt.currentName() == "b");
        g.writeName("c");
        assert(g.streamWriteContext().currentName() == "c");
        g.writeNumber(5);
        g.writeName("d");
        assert(g.streamWriteContext().currentName() == "d");
        g.writeEndObject();
        g.writeEndArray();
        g.writeEndObject();
        assert(g.streamWriteContext().inRoot());
    });
}

@("JsonWriteContextTest: a name where a value is due, and a value where a name is due, fail")
unittest
{
    expectFailure!StreamWriteException(() {
        written((g) { g.writeStartObject(); g.writeName("a"); g.writeName("b"); });
    }, "Can not write a property name, expecting a value");
    expectFailure!StreamWriteException(() { written((g) { g.writeStartObject(); g.writeNumber(1); }); },
            "expecting a property name");
    expectFailure!StreamWriteException(() { written((g) { g.writeStartArray(); g.writeEndObject(); }); },
            "Current context not an Object");
}

@("GeneratorCloseTest.autoCloseArraysAndObjects: close() ends open structures")
unittest
{
    assert(written((g) {
            g.writeStartArray();
            g.writeStartObject();
            g.writeName("a");
            g.writeNumber(1);
        }) == `[{"a":1}]`);
}
