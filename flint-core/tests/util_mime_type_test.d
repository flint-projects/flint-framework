// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.util.MimeTypeTests` (v7.1.0), including its nested
`InvalidMimeTypeTests`, `QuotePairsTests` and `SpecificityTests`: one `unittest` per Java test method, each
starting with a `// <JavaTestName>` comment.

Skipped Java tests (1), with reasons:
- serialize: Java serialization (`SerializationTestUtils`), excluded from the port (jvm-platform).

Adapted: `MimeType` is a struct, so AssertJ's `isSameAs` compares values; Java's `singletonMap(name, value)`
parameters are a one-element `MimeTypeParameter[]`; a nullable `Charset` is a pointer (R5); `List<MimeType>` is a
`MimeType[]`, and D cannot tell the null list `parseMimeTypes(null)` returns from an empty one.
+/
module flint.util.mime_type_test;

import flint.java.lang : IllegalArgumentException;
import flint.java.nio.charset : StandardCharsets;
import flint.util : InvalidMimeTypeException, MimeType, MimeTypeParameter, MimeTypeUtils;
import flint.util.test_support : contains, expectThrows;

@safe:

/// `e`'s message ends with `suffix` (AssertJ's `withMessageEndingWith`).
private bool messageEndsWith(const Throwable e, string suffix)
{
    return e.msg.length >= suffix.length && e.msg[$ - suffix.length .. $] == suffix;
}

/// Java's `Collections.shuffle` with a seeded generator (deterministic).
private void shuffle(T)(T[] values, ref uint seed)
{
    for (size_t i = values.length; i > 1; i--)
    {
        seed = seed * 1_103_515_245 + 12_345;
        const j = (seed >> 16) % i;
        auto tmp = values[i - 1];
        values[i - 1] = values[j];
        values[j] = tmp;
    }
}

/// `testWithQuotedParameters` of QuotePairsTests: the joined types parse back to each one.
private void testWithQuotedParameters(string[] mimeTypes...)
{
    string s;
    foreach (i, mimeType; mimeTypes)
        s ~= (i == 0 ? "" : ",") ~ mimeType;
    const actual = MimeTypeUtils.parseMimeTypes(s);

    assert(actual.length == mimeTypes.length, s);
    foreach (i, mimeType; mimeTypes)
        assert(actual[i].toString() == mimeType, actual[i].toString());
}

// ---------------------------------------------------------------------------------------------------------------
// InvalidMimeTypeTests

// parseMimeTypeNull
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeType.valueOf(null); });
}

// valueOfSlashInSubtype
unittest
{
    expectThrows!IllegalArgumentException(() { MimeType("text", "/"); });
}

// valueOfNoSubtype
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeType.valueOf("audio"); });
}

// valueOfNoSubtypeOnlySlash
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeType.valueOf("audio/"); });
}

// valueOfIllegalType
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeType.valueOf("audio(/basic"); });
}

// valueOfIllegalSubtype
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeType.valueOf("audio/basic)"); });
}

// valueOfIllegalCharset
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeType.valueOf("text/html; charset=foo-bar"); });
}

// parseMimeTypeNoSubtype
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType("audio"); });
}

// parseMimeTypeNoSubtypeSlash
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType("audio/"); });
}

// parseMimeTypeTypeRange
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType("*/json"); });
}

// parseMimeTypeRejectsSecondCommaSeparatedType
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType("text/plain,text/html"); });
}

// parseMimeTypeRejectsLeadingComma
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType(",text/plain"); });
}

// parseMimeTypeRejectsParameterWithoutSemicolon
unittest
{
    foreach (value; [
        "text/plain charset=ISO-8859-1", "text/html q=0.1", "application/json\tcharset=UTF-16",
        "text/plain;a=b charset=UTF-16", "text/plain;a=\"b\"charset=UTF-16"
    ])
        expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType(value); });
}

// parseMimeTypeIllegalType
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType("audio(/basic"); });
}

// parseMimeTypeIllegalSubtype
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType("audio/basic)"); });
}

// parseMimeTypeMissingTypeAndSubtype
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType("     ;a=b"); });
}

// parseMimeTypeEmptyParameterAttribute
unittest
{
    foreach (value; ["audio/*;=value", "audio/*; =value"])
    {
        const e = expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType(value); });
        assert(messageEndsWith(e, "missing parameter name before '='"), e.msg);
    }
}

// parseMimeTypeEmptyParameterValue
unittest
{
    foreach (value; ["audio/*;attr=", "audio/*;attr= ", "audio/*;attr=;a=b"])
    {
        const e = expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType(value); });
        assert(messageEndsWith(e, "missing value for parameter 'attr'"), e.msg);
    }
}

// parseMimeTypeParameterWithoutValue
unittest
{
    foreach (value; ["text/plain;charset", "text/plain;charset "])
    {
        const e = expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType(value); });
        assert(messageEndsWith(e, "missing value for parameter 'charset'"), e.msg);
    }
    foreach (value; ["text/plain;a;b=c", "text/plain; a ;b=c"])
    {
        const e = expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType(value); });
        assert(messageEndsWith(e, "missing value for parameter 'a'"), e.msg);
    }
}

// parseMimeTypeIllegalParameterAttribute
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType("audio/*;attr<=value"); });
}

// parseMimeTypeIllegalParameterValue
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType("audio/*;attr=v>alue"); });
}

// parseMimeTypeIllegalCharset
unittest
{
    expectThrows!InvalidMimeTypeException(() {
        MimeTypeUtils.parseMimeType("text/html; charset=foo-bar");
    });
}

// valueOfDuplicateParameter
unittest
{
    const e = expectThrows!InvalidMimeTypeException(() {
        MimeType.valueOf("text/plain;dupe=\"1\";dupe=\"2\"");
    });
    assert(e.msg.contains("Invalid mime type \"text/plain;dupe=\"1\";dupe=\"2\"\": duplicate parameter 'dupe=\"2\"'"),
            e.msg);
}

// valueOfDuplicateParameterWithDifferentCase
unittest
{
    const e = expectThrows!InvalidMimeTypeException(() {
        MimeType.valueOf("text/plain;dupe=\"1\";DUPE=\"2\"");
    });
    assert(e.msg.contains("Invalid mime type \"text/plain;dupe=\"1\";DUPE=\"2\"\": duplicate parameter 'DUPE=\"2\"'"),
            e.msg);
}

// ---------------------------------------------------------------------------------------------------------------
// QuotePairsTests

// parseQuotedCharset
unittest
{
    const mimeType = MimeType.valueOf("application/xml;charset=\"utf-8\"");
    assert(mimeType.getType() == "application", "Invalid type");
    assert(mimeType.getSubtype() == "xml", "Invalid subtype");
    assert(mimeType.getCharset() !is null && *mimeType.getCharset() == StandardCharsets.UTF_8, "Invalid charset");
}

// parseQuotedParameterValue
unittest
{
    const mimeType = MimeType.valueOf(
            "application/xop+xml;charset=utf-8;type=\"application/soap+xml;action=\\\"https://x.y.z\\\"\"");
    assert(mimeType.getType() == "application", "Invalid type");
    assert(mimeType.getSubtype() == "xop+xml", "Invalid subtype");
    assert(mimeType.getCharset() !is null && *mimeType.getCharset() == StandardCharsets.UTF_8, "Invalid charset");
    assert(mimeType.getParameter("type") == "\"application/soap+xml;action=\\\"https://x.y.z\\\"\"");
}

// parseParameterWithQuotedPair
unittest
{
    const mimeType = MimeType.valueOf("text/plain;twelve=\"1\\\"2\"");
    assert(mimeType.getType() == "text", "Invalid type");
    assert(mimeType.getSubtype() == "plain", "Invalid subtype");
    assert(mimeType.getParameter("twelve") == "\"1\\\"2\"");
}

// parseMimeTypeQuotedParameterValue
unittest
{
    const mimeType = MimeTypeUtils.parseMimeType("audio/*;attr=\"v>alue\"");
    assert(mimeType.getParameter("attr") == "\"v>alue\"");
}

// parseMimeTypeSingleQuotedParameterValue
unittest
{
    const mimeType = MimeTypeUtils.parseMimeType("audio/*;attr='v>alue'");
    assert(mimeType.getParameter("attr") == "'v>alue'");
}

// parseMimeTypeWithSpacesAroundEqualsAndQuotedValue
unittest
{
    const mimeType = MimeTypeUtils.parseMimeType("text/plain; foo = \" bar \" ");
    assert(mimeType.getParameter("foo") == "\" bar \"");
}

// parseMimeTypeIllegalQuotedParameterValue
unittest
{
    expectThrows!InvalidMimeTypeException(() { MimeTypeUtils.parseMimeType("audio/*;attr=\""); });
}

// parseMimeTypeWrappedInQuotes
unittest
{
    const e = expectThrows!InvalidMimeTypeException(() {
        MimeTypeUtils.parseMimeType("\"application/xml\"");
    });
    assert(e.msg.contains("Invalid token character '\"'"), e.msg);
}

// parseMimeTypesWithQuotedParameters
unittest
{
    testWithQuotedParameters("foo/bar;param=\",\"");
    testWithQuotedParameters("foo/bar;param=\"s,a,\"");
    testWithQuotedParameters("foo/bar;param=\"s,\"", "text/x-c");
    testWithQuotedParameters("foo/bar;param=\"a\\\"b,c\"");
    testWithQuotedParameters("foo/bar;param=\"\\\\\"");
    testWithQuotedParameters("foo/bar;param=\"\\,\\\"");
}

// ---------------------------------------------------------------------------------------------------------------
// SpecificityTests

// includes
unittest
{
    const textPlain = MimeTypeUtils.TEXT_PLAIN;
    assert(textPlain.includes(textPlain), "Equal types is not inclusive");
    const allText = MimeType("text");

    assert(allText.includes(textPlain), "All subtypes is not inclusive");
    assert(!textPlain.includes(allText), "All subtypes is inclusive");

    assert(MimeTypeUtils.ALL.includes(textPlain), "All types is not inclusive");
    assert(!textPlain.includes(MimeTypeUtils.ALL), "All types is inclusive");

    assert(MimeTypeUtils.ALL.includes(textPlain), "All types is not inclusive");
    assert(!textPlain.includes(MimeTypeUtils.ALL), "All types is inclusive");

    const applicationSoapXml = MimeType("application", "soap+xml");
    const applicationWildcardXml = MimeType("application", "*+xml");
    const suffixXml = MimeType("application", "x.y+z+xml"); // SPR-15795

    assert(applicationSoapXml.includes(applicationSoapXml));
    assert(applicationWildcardXml.includes(applicationWildcardXml));
    assert(applicationWildcardXml.includes(suffixXml));

    assert(applicationWildcardXml.includes(applicationSoapXml));
    assert(!applicationSoapXml.includes(applicationWildcardXml));
    assert(!suffixXml.includes(applicationWildcardXml));

    assert(!applicationWildcardXml.includes(MimeTypeUtils.APPLICATION_JSON));
}

// isCompatible
unittest
{
    const textPlain = MimeTypeUtils.TEXT_PLAIN;
    assert(textPlain.isCompatibleWith(textPlain), "Equal types is not compatible");
    const allText = MimeType("text");

    assert(allText.isCompatibleWith(textPlain), "All subtypes is not compatible");
    assert(textPlain.isCompatibleWith(allText), "All subtypes is not compatible");

    assert(MimeTypeUtils.ALL.isCompatibleWith(textPlain), "All types is not compatible");
    assert(textPlain.isCompatibleWith(MimeTypeUtils.ALL), "All types is not compatible");

    assert(MimeTypeUtils.ALL.isCompatibleWith(textPlain), "All types is not compatible");
    assert(textPlain.isCompatibleWith(MimeTypeUtils.ALL), "All types is compatible");

    const applicationSoapXml = MimeType("application", "soap+xml");
    const applicationWildcardXml = MimeType("application", "*+xml");
    const suffixXml = MimeType("application", "x.y+z+xml"); // SPR-15795

    assert(applicationSoapXml.isCompatibleWith(applicationSoapXml));
    assert(applicationWildcardXml.isCompatibleWith(applicationWildcardXml));
    assert(applicationWildcardXml.isCompatibleWith(suffixXml));

    assert(applicationWildcardXml.isCompatibleWith(applicationSoapXml));
    assert(applicationSoapXml.isCompatibleWith(applicationWildcardXml));
    assert(suffixXml.isCompatibleWith(applicationWildcardXml));

    assert(!applicationWildcardXml.isCompatibleWith(MimeTypeUtils.APPLICATION_JSON));
}

// compareTo
unittest
{
    import std.algorithm.sorting : sort;

    const audioBasic = MimeType("audio", "basic");
    const audio = MimeType("audio");
    const audioWave = MimeType("audio", "wave");
    const audioBasicLevel = MimeType("audio", "basic", [MimeTypeParameter("level", "1")]);

    // equal
    assert(audioBasic.compareTo(audioBasic) == 0, "Invalid comparison result");
    assert(audio.compareTo(audio) == 0, "Invalid comparison result");
    assert(audioBasicLevel.compareTo(audioBasicLevel) == 0, "Invalid comparison result");

    assert(audioBasicLevel.compareTo(audio) > 0, "Invalid comparison result");

    const MimeType[] expected = [audio, audioBasic, audioBasicLevel, audioWave];
    MimeType[] result = expected.dup;
    uint seed = 42;

    // shuffle & sort 10 times
    foreach (i; 0 .. 10)
    {
        shuffle(result, seed);
        sort(result);

        foreach (j; 0 .. result.length)
            assert(result[j] == expected[j], "Invalid media type at " ~ result[j].toString());
    }
}

// compareToCaseSensitivity
unittest
{
    auto m1 = MimeType("audio", "basic");
    auto m2 = MimeType("Audio", "Basic");
    assert(m1.compareTo(m2) == 0, "Invalid comparison result");
    assert(m2.compareTo(m1) == 0, "Invalid comparison result");

    m1 = MimeType("audio", "basic", [MimeTypeParameter("foo", "bar")]);
    m2 = MimeType("audio", "basic", [MimeTypeParameter("Foo", "bar")]);
    assert(m1.compareTo(m2) == 0, "Invalid comparison result");
    assert(m2.compareTo(m1) == 0, "Invalid comparison result");

    m1 = MimeType("audio", "basic", [MimeTypeParameter("foo", "bar")]);
    m2 = MimeType("audio", "basic", [MimeTypeParameter("foo", "Bar")]);
    assert(m1.compareTo(m2) != 0, "Invalid comparison result");
    assert(m2.compareTo(m1) != 0, "Invalid comparison result");
}

// isMoreSpecific
unittest
{
    const audioBasic = MimeType("audio", "basic");
    const audio = MimeType("audio");
    const audioWave = MimeType("audio", "wave");
    const audioBasicLevel = MimeType("audio", "basic", [MimeTypeParameter("level", "1")]);

    assert(!audioBasic.isMoreSpecific(audioBasicLevel));
    assert(audioBasicLevel.isMoreSpecific(audioBasic));

    assert(audio.isMoreSpecific(MimeTypeUtils.ALL));
    assert(!MimeTypeUtils.ALL.isMoreSpecific(audio));

    assert(audioBasicLevel.isMoreSpecific(audioBasic));
    assert(!audioBasic.isMoreSpecific(audioBasicLevel));

    assert(!audioBasic.isMoreSpecific(MimeTypeUtils.TEXT_HTML));
    assert(!audioBasic.isMoreSpecific(audioWave));
    assert(!audioBasicLevel.isMoreSpecific(MimeTypeUtils.TEXT_HTML));
}

// isLessSpecific
unittest
{
    const audioBasic = MimeType("audio", "basic");
    const audio = MimeType("audio");
    const audioWave = MimeType("audio", "wave");
    const audioBasicLevel = MimeType("audio", "basic", [MimeTypeParameter("level", "1")]);

    assert(audioBasic.isLessSpecific(audioBasicLevel));
    assert(!audioBasicLevel.isLessSpecific(audioBasic));

    assert(!audio.isLessSpecific(MimeTypeUtils.ALL));
    assert(MimeTypeUtils.ALL.isLessSpecific(audio));

    assert(!audioBasicLevel.isLessSpecific(audioBasic));
    assert(audioBasic.isLessSpecific(audioBasicLevel));

    assert(!audioBasic.isLessSpecific(MimeTypeUtils.TEXT_HTML));
    assert(!audioBasic.isLessSpecific(audioWave));
    assert(!audioBasicLevel.isLessSpecific(MimeTypeUtils.TEXT_HTML));
}

// sortBySpecificity
unittest
{
    const audioBasic = MimeType("audio", "basic");
    const audio = MimeType("audio");
    const audioWave = MimeType("audio", "wave");
    const audioBasicLevel = MimeType("audio", "basic", [MimeTypeParameter("level", "1")]);
    const all = MimeTypeUtils.ALL;

    MimeType[] mimeTypes = [all, audio, audioWave, audioBasic, audioBasicLevel];

    MimeTypeUtils.sortBySpecificity(mimeTypes);

    assert(mimeTypes == [audioWave, audioBasicLevel, audioBasic, audio, all], MimeTypeUtils.toString(mimeTypes));
}

// bubbleSort
unittest
{
    int[] list = [10, 9, 8, 7, 6, 5, 4, 3, 2, 1];
    MimeTypeUtils.bubbleSort!((i1, i2) => i1 > i2)(list);
    assert(list == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
}

// wildcardSubtypeCompatibleWithSuffix
unittest
{
    const applicationStar = MimeType("application", "*");
    const applicationVndJson = MimeType("application", "vnd.something+json");
    assert(applicationStar.isCompatibleWith(applicationVndJson));
}

// ---------------------------------------------------------------------------------------------------------------
// MimeTypeTests

// parseCharset
unittest
{
    const mimeType = MimeType.valueOf("text/html; charset=iso-8859-1");
    assert(mimeType.getType() == "text", "Invalid type");
    assert(mimeType.getSubtype() == "html", "Invalid subtype");
    assert(mimeType.getCharset() !is null && *mimeType.getCharset() == StandardCharsets.ISO_8859_1, "Invalid charset");
}

// withConversionService
version (FlintObjectToObjectConverter) // no ObjectToObjectConverter: String to MimeType via static valueOf(String)
{
    unittest
    {
        import flint.core.convert : ConversionService;
        import flint.core.convert.support : DefaultConversionService;

        ConversionService conversionService = new DefaultConversionService;
        assert(conversionService.canConvert!(string, MimeType)());
        const mimeType = MimeType.valueOf("application/xml");
        assert(conversionService.convert!MimeType("application/xml") == mimeType);
    }
}

// toStringOutput
unittest
{
    const mimeType = MimeType("text", "plain");
    const result = mimeType.toString();
    assert(result == "text/plain", "Invalid toString() returned");
}

// parseWildcardSubtype
unittest
{
    const mimeType = MimeTypeUtils.parseMimeType("audio/*");
    assert(mimeType.getType() == "audio", "Invalid type");
    assert(mimeType.getSubtype() == "*", "Invalid subtype");
}

// parseBareWildcardShorthand
unittest
{
    const mimeType = MimeTypeUtils.parseMimeType("*");
    assert(mimeType.getType() == "*", "Invalid type");
    assert(mimeType.getSubtype() == "*", "Invalid subtype");
}

// parseBareWildcardShorthandWithParameter
unittest
{
    // java.net.HttpURLConnection returns a "*; q=.2" Accept header
    const mimeType = MimeTypeUtils.parseMimeType("*; q=.2");
    assert(mimeType.getType() == "*", "Invalid type");
    assert(mimeType.getSubtype() == "*", "Invalid subtype");
    assert(mimeType.getParameter("q") == ".2");
}

// parseMimeTypeWithSpacesAroundEquals
unittest
{
    const mimeType = MimeTypeUtils.parseMimeType("multipart/x-mixed-replace;boundary = --myboundary");
    assert(mimeType.getParameter("boundary") == "--myboundary");
}

// parseMimeTypeWithWhitespaceAroundSemicolon
unittest
{
    auto mimeType = MimeTypeUtils.parseMimeType("text/plain ; charset=UTF-8");
    assert(mimeType.getCharset() !is null && *mimeType.getCharset() == StandardCharsets.UTF_8);
    mimeType = MimeTypeUtils.parseMimeType("text/plain;charset=UTF-8 ");
    assert(mimeType.getCharset() !is null && *mimeType.getCharset() == StandardCharsets.UTF_8);
    mimeType = MimeTypeUtils.parseMimeType("text/plain ;a=b ; c=d");
    assert(mimeType.getParameter("a") == "b");
    assert(mimeType.getParameter("c") == "d");
    mimeType = MimeTypeUtils.parseMimeType("text/plain;a=\"b\" ;c=d");
    assert(mimeType.getParameter("a") == "\"b\"");
    assert(mimeType.getParameter("c") == "d");
}

// parseMimeTypes
unittest
{
    const s = "text/plain, text/html, text/x-dvi, text/x-c";
    auto mimeTypes = MimeTypeUtils.parseMimeTypes(s);
    assert(mimeTypes.length == 4, "Invalid amount of mime types");

    mimeTypes = MimeTypeUtils.parseMimeTypes(null);
    assert(mimeTypes.length == 0, "Invalid amount of mime types");
}

// parseMimeTypesWithTrailingComma
unittest
{
    const mimeTypes = MimeTypeUtils.parseMimeTypes("text/plain, text/html,");
    assert(mimeTypes.length == 2, "Incorrect number of mime types");
}

// parseSubtypeSuffix
unittest
{
    auto type = MimeType("application", "vdn.something+json");
    assert(type.getSubtypeSuffix() == "json");
    type = MimeType("application", "vdn.something");
    assert(type.getSubtypeSuffix() is null);
    type = MimeType("application", "vdn.something+");
    assert(type.getSubtypeSuffix() !is null && type.getSubtypeSuffix().length == 0);
    type = MimeType("application", "vdn.some+thing+json");
    assert(type.getSubtypeSuffix() == "json");
}

// equalsIsCaseInsensitiveForCharsets
unittest
{
    const m1 = MimeType("text", "plain", [MimeTypeParameter("charset", "UTF-8")]);
    const m2 = MimeType("text", "plain", [MimeTypeParameter("charset", "utf-8")]);
    assert(m2 == m1);
    assert(m1 == m2);
    assert(m1.compareTo(m2) == 0);
    assert(m2.compareTo(m1) == 0);
}

// equalsIsCaseInsensitiveForParameterNames
unittest
{
    const m1 = MimeType("text", "plain", [MimeTypeParameter("Spring", "framework")]);
    const m2 = MimeType("text", "plain", [MimeTypeParameter("spring", "framework")]);
    assert(m1 == m2);
    assert(m2 == m1);
    assert(m1.hashCode() == m2.hashCode());
    assert(m1.compareTo(m2) == 0);
    assert(m2.compareTo(m1) == 0);
}

// equalsIsCaseInsensitiveForCharsetParameterName
unittest
{
    const m1 = MimeType("text", "plain", [MimeTypeParameter("Charset", "UTF-8")]);
    const m2 = MimeType("text", "plain", [MimeTypeParameter("charset", "utf-8")]);
    assert(m1 == m2);
    assert(m2 == m1);
    assert(m1.hashCode() == m2.hashCode());
    assert(m1.compareTo(m2) == 0);
    assert(m2.compareTo(m1) == 0);
}

// equalsIgnoresParameterValueQuoting
unittest
{
    const m1 = MimeTypeUtils.parseMimeType("text/plain; spring=\"framework\"");
    const m2 = MimeTypeUtils.parseMimeType("text/plain; spring=framework");
    assert(m1 == m2);
    assert(m2 == m1);
    assert(m1.hashCode() == m2.hashCode());
    assert(m1.compareTo(m2) == 0);
    assert(m2.compareTo(m1) == 0);
}

unittest
{
    // Flint: tokenizeList sizes its result in one allocation; the tokens are as Spring's tokenize gives them.
    assert(MimeTypeUtils.tokenizeList("") is null && MimeTypeUtils.tokenizeList(" , ,") is null);
    assert(MimeTypeUtils.tokenizeList("text/plain") == ["text/plain"]);
    assert(MimeTypeUtils.tokenizeList(" text/plain , text/html,") == ["text/plain", "text/html"]);
    assert(MimeTypeUtils.tokenizeList(`text/plain;a="x,y", text/html;b="\",", */*`) == [
        `text/plain;a="x,y"`, `text/html;b="\","`, "*/*"
    ]);
    // toString renders in one allocation: type, subtype, then parameters in insertion order.
    const text = "text/plain;charset=UTF-8;q=0.7";
    assert(MimeTypeUtils.parseMimeType(text).toString() == text);
    assert(MimeTypeUtils.parseMimeType("TEXT/Plain").toString() == "text/plain");
}

unittest
{
    // Flint: toString is free where Spring's cached toStringValue would be: a compile-time constant keeps its
    // text, and a canonical parse returns its own input.
    static immutable constant = MimeType.literal("application", "json");
    assert(constant.toString() == "application/json");
    const input = "application/json";
    assert(MimeTypeUtils.parseMimeType(input).toString() is input);
    assert(MimeTypeUtils.parseMimeType("Application/JSON").toString() == "application/json");
    assert(MimeTypeUtils.parseMimeType(" application/json").toString() == "application/json");
    const withCharset = MimeType(MimeTypeUtils.parseMimeType(input), StandardCharsets.UTF_8);
    assert(withCharset.toString() == "application/json;charset=UTF-8");
}
