/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/http/MediaTypeTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts.
Excluded: withConversionService (spring-core's DefaultConversionService, framework-core, not yet ported);
serialize (Java serialization, ADR-030 exclusion `jvm-platform`).
+/
module flint.http.media_type_tests;

import flint.http : InvalidMediaTypeException, MediaType;
import flint.java.lang : IllegalArgumentException;
import flint.java.nio.charset : StandardCharsets;
import flint.util : MimeTypeParameter, MimeTypeUtils;

@safe:

private void assertThrows(E)(scope void delegate() @safe action, string file = __FILE__, size_t line = __LINE__)
{
    bool thrown;
    try
        action();
    catch (E)
        thrown = true;
    assert(thrown, "expected " ~ E.stringof);
}

private void shuffle(T)(T[] values, ref uint seed)
{
    for (size_t i = values.length; i > 1; i--)
    {
        seed = seed * 1_103_515_245 + 12_345;
        const j = (seed >> 16) % i;
        const tmp = values[i - 1];
        values[i - 1] = values[j];
        values[j] = tmp;
    }
}

@("MediaTypeTests.toStringOutput")
unittest
{
    MediaType mediaType = MediaType("text", "plain", 0.7);
    assert(mediaType.toString() == "text/plain;q=0.7", "Invalid toString() returned");
}

@("MediaTypeTests.slashInType")
unittest
{
    assertThrows!IllegalArgumentException(() { MediaType("text/plain"); });
}

@("MediaTypeTests.slashInSubtype")
unittest
{
    assertThrows!IllegalArgumentException(() { MediaType("text", "/"); });
}

@("MediaTypeTests.getDefaultQualityValue")
unittest
{
    assert(MediaType("text", "plain").getQualityValue() == 1.0, "Invalid quality value");
}

@("MediaTypeTests.parseMediaType")
unittest
{
    MediaType mediaType = MediaType.parseMediaType("audio/*; q=0.2");
    assert(mediaType.getType() == "audio", "Invalid type");
    assert(mediaType.getSubtype() == "*", "Invalid subtype");
    assert(mediaType.getQualityValue() == 0.2, "Invalid quality factor");
}

@("MediaTypeTests.parseMediaType rejects malformed input")
unittest
{
    // parseMediaTypeNoSubtype, NoSubtypeSlash, TypeRange, IllegalType, IllegalSubtype,
    // EmptyParameterAttribute, EmptyParameterValue, IllegalParameterAttribute, IllegalParameterValue,
    // IllegalQualityFactor, IllegalQualityFactorWithUpperCaseParameterName, IllegalCharset
    foreach (input; [
        "audio", "audio/", "*/json", "audio(/basic", "audio/basic)", "audio/*;=value",
        "audio/*;attr=", "audio/*;attr<=value",
        "audio/*;attr=v>alue", "audio/basic;q=1.1", "audio/basic;Q=1.1", "text/html; charset=foo-bar"
    ])
        assertThrows!InvalidMediaTypeException(() { MediaType.parseMediaType(input); });
}

@("MediaTypeTests.parseURLConnectionMediaType")
unittest
{
    MediaType mediaType = MediaType.parseMediaType("*; q=.2");
    assert(mediaType.getType() == "*", "Invalid type");
    assert(mediaType.getSubtype() == "*", "Invalid subtype");
    assert(mediaType.getQualityValue() == 0.2, "Invalid quality factor");
}

@("MediaTypeTests.parseMediaTypes")
unittest
{
    const mediaTypes = MediaType.parseMediaTypes("text/plain; q=0.5, text/html, text/x-dvi; q=0.8, text/x-c");
    assert(mediaTypes.length == 4, "Invalid amount of media types");
    assert(MediaType.parseMediaTypes("").length == 0, "Invalid amount of media types");
}

@("MediaTypeTests.parseMediaTypesWithTrailingComma")
unittest
{
    assert(MediaType.parseMediaTypes("text/plain, text/html, ").length == 2, "Incorrect number of media types");
}

@("MediaTypeTests.compareTo")
unittest
{
    import std.algorithm.sorting : sort;

    MediaType audioBasic = MediaType("audio", "basic");
    MediaType audio = MediaType("audio");
    const MediaType audioWave = MediaType("audio", "wave");
    MediaType audioBasicLevel = MediaType("audio", "basic", [MimeTypeParameter("level", "1")]);
    const MediaType audioBasic07 = MediaType("audio", "basic", 0.7);

    assert(audioBasic.compareTo(audioBasic) == 0, "Invalid comparison result");
    assert(audio.compareTo(audio) == 0, "Invalid comparison result");
    assert(audioBasicLevel.compareTo(audioBasicLevel) == 0, "Invalid comparison result");
    assert(audioBasicLevel.compareTo(audio) > 0, "Invalid comparison result");

    MediaType[] expected = [audio, audioBasic, audioBasicLevel, audioBasic07, audioWave];
    MediaType[] result = expected.dup;
    uint seed = 42;
    foreach (i; 0 .. 10)
    {
        shuffle(result, seed);
        sort!((a, b) => a.compareTo(b) < 0)(result);
        foreach (j; 0 .. result.length)
            assert(result[j] == expected[j], "Invalid media type");
    }
}

@("MediaTypeTests.compareToConsistentWithEquals")
unittest
{
    MediaType m1 = MediaType.parseMediaType("text/html; q=0.7; charset=iso-8859-1");
    MediaType m2 = MediaType.parseMediaType("text/html; charset=iso-8859-1; q=0.7");
    assert(m2 == m1, "Media types not equal");
    assert(m1.compareTo(m2) == 0 && m2.compareTo(m1) == 0, "compareTo() not consistent with equals");

    m1 = MediaType.parseMediaType("text/html; q=0.7; charset=iso-8859-1");
    m2 = MediaType.parseMediaType("text/html; Q=0.7; charset=iso-8859-1");
    assert(m2 == m1, "Media types not equal");
    assert(m1.compareTo(m2) == 0 && m2.compareTo(m1) == 0, "compareTo() not consistent with equals");
}

@("MediaTypeTests.compareToCaseSensitivity")
unittest
{
    MediaType m1 = MediaType("audio", "basic");
    MediaType m2 = MediaType("Audio", "Basic");
    assert(m1.compareTo(m2) == 0 && m2.compareTo(m1) == 0);

    m1 = MediaType("audio", "basic", [MimeTypeParameter("foo", "bar")]);
    m2 = MediaType("audio", "basic", [MimeTypeParameter("Foo", "bar")]);
    assert(m1.compareTo(m2) == 0 && m2.compareTo(m1) == 0);

    m1 = MediaType("audio", "basic", [MimeTypeParameter("foo", "bar")]);
    m2 = MediaType("audio", "basic", [MimeTypeParameter("foo", "Bar")]);
    assert(m1.compareTo(m2) != 0 && m2.compareTo(m1) != 0);
}

@("MediaTypeTests.isMoreSpecific")
unittest
{
    MediaType audio = MediaType("audio");
    MediaType audioBasic = MediaType("audio", "basic");
    MediaType audioBasic07 = MediaType("audio", "basic", 0.7);
    MediaType audioBasic03 = MediaType("audio", "basic", 0.3);

    assert(audioBasic.isMoreSpecific(audio));
    assert(!audio.isMoreSpecific(audioBasic));
    assert(audio.isMoreSpecific(audioBasic07));
    assert(!audioBasic07.isMoreSpecific(audio));
    assert(audioBasic07.isMoreSpecific(audioBasic03));
    assert(!audioBasic03.isMoreSpecific(audioBasic07));
    assert(!audioBasic.isMoreSpecific(MediaType.TEXT_HTML));
}

@("MediaTypeTests.isLessSpecific")
unittest
{
    MediaType audio = MediaType("audio");
    MediaType audioBasic = MediaType("audio", "basic");
    MediaType audioBasic07 = MediaType("audio", "basic", 0.7);
    MediaType audioBasic03 = MediaType("audio", "basic", 0.3);

    assert(!audioBasic.isLessSpecific(audio));
    assert(audio.isLessSpecific(audioBasic));
    assert(!audio.isLessSpecific(audioBasic07));
    assert(audioBasic07.isLessSpecific(audio));
    assert(!audioBasic07.isLessSpecific(audioBasic03));
    assert(audioBasic03.isLessSpecific(audioBasic07));
    assert(!audioBasic.isLessSpecific(MediaType.TEXT_HTML));
}

@("MediaTypeTests.isConcrete")
unittest
{
    assert(MediaType.TEXT_PLAIN.isConcrete(), "text/plain not concrete");
    assert(!MediaType.ALL.isConcrete(), "*/* concrete");
    assert(!MediaType("text", "*").isConcrete(), "text/* concrete");
}

@("MediaTypeTests.removeQualityValue")
unittest
{
    assert(MediaType.parseMediaType("audio/basic;q=0.8").removeQualityValue() == MediaType.parseMediaType(
            "audio/basic"));
}

@("MediaTypeTests.removeQualityValueWithUpperCaseParameterName")
unittest
{
    assert(MediaType.parseMediaType("audio/basic;Q=0.8").removeQualityValue() == MediaType.parseMediaType(
            "audio/basic"));
}

@("MediaTypeTests.sortBySpecificity")
unittest
{
    const MediaType audioBasic = MediaType("audio", "basic");
    const MediaType audio = MediaType("audio");
    const MediaType audio03 = MediaType("audio", "*", 0.3);
    const MediaType audio07 = MediaType("audio", "*", 0.7);
    const MediaType audioBasicLevel = MediaType("audio", "basic", [MimeTypeParameter("level", "1")]);
    const MediaType all = MediaType.ALL;

    const MediaType[] expected = [audioBasicLevel, audioBasic, audio, all, audio07, audio03];
    MediaType[] result = expected.dup;
    uint seed = 7;
    foreach (i; 0 .. 10)
    {
        shuffle(result, seed);
        MimeTypeUtils.sortBySpecificity(result);
        assert(result == expected);
    }
}

@("MediaType constants, charset and R14 non-ASCII rejection")
unittest
{
    assert(MediaType.APPLICATION_JSON.toString() == MediaType.APPLICATION_JSON_VALUE);
    assert(MediaType.APPLICATION_PROBLEM_JSON.toString() == "application/problem+json");
    auto utf8 = MediaType("text", "plain", StandardCharsets.UTF_8);
    assert(utf8.toString() == "text/plain;charset=UTF-8");
    assert(*utf8.getCharset() == StandardCharsets.UTF_8);
    assert(MediaType.parseMediaType("text/plain;charset=utf-8") == utf8);
    assertThrows!InvalidMediaTypeException(() { MediaType.parseMediaType("text/plaïn"); });
    assert(MediaType.APPLICATION_JSON.includes(MediaType.parseMediaType("application/json;charset=UTF-8")));
    assert(MediaType.parseMediaType("application/*+json").includes(MediaType.APPLICATION_PROBLEM_JSON));
}
