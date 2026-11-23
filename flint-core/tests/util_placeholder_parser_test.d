// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.util.PlaceholderParserTests` (v7.1.0), with its nested
`OnlyPlaceholderTests`, `DefaultValueTests`, `EscapedTests` and `ExceptionTests`: one `unittest` per Java test
method, each starting with a `// <NestedClass>.<JavaTestName>` comment. Parameterized tests run their rows in one
block; Mockito's resolver mock is a recording resolver that checks the exact sequence of lookups. No test is
skipped.
+/
module flint.util.placeholder_parser_test;

import flint.java.util : Map;
import flint.util : PlaceholderParser, PlaceholderResolutionException, PropertyPlaceholderHelper;
import flint.util.test_support : expectThrows;

@safe:

/// Mockito's `mock(PlaceholderResolver)` with `given(...).willReturn(...)` and `inOrder(...).verify(...)`.
private final class RecordingResolver : PropertyPlaceholderHelper.PlaceholderResolver
{
    private string[string] values;
    string[] calls;

    this(string[] pairs...)
    {
        assert(pairs.length % 2 == 0, "size must be even, it is a set of key=value pairs");
        for (size_t i = 0; i < pairs.length; i += 2)
            values[pairs[i]] = pairs[i + 1];
    }

    string resolvePlaceholder(string placeholderName)
    {
        calls ~= placeholderName;
        auto value = placeholderName in values;
        return value is null ? null : *value;
    }

    void verifyPlaceholderResolutions(string[] expected...)
    {
        assert(calls == expected);
    }
}

/// `properties::get` over alternating keys and values.
private string delegate(string) @safe properties(string[] pairs...)
{
    string[string] values;
    for (size_t i = 0; i < pairs.length; i += 2)
        values[pairs[i]] = pairs[i + 1];
    return (string key) {
        auto value = key in values;
        return value is null ? null : *value;
    };
}

private void assertReplaced(PlaceholderParser parser, string delegate(string) @safe resolver, string[2][] rows)
{
    foreach (row; rows)
    {
        const actual = parser.replacePlaceholders(row[0], resolver);
        assert(actual == row[1], row[0] ~ " -> " ~ actual ~ ", expected " ~ row[1]);
    }
}

private PlaceholderParser onlyPlaceholderParser()
{
    return new PlaceholderParser("${", "}", null, null, true);
}

private PlaceholderParser defaultValueParser()
{
    return new PlaceholderParser("${", "}", ":", null, true);
}

private PlaceholderParser escapedParser()
{
    return new PlaceholderParser("${", "}", ":", '\\', true);
}

// OnlyPlaceholderTests.placeholderIsReplaced
unittest
{
    auto resolver = properties("firstName", "John", "nested0", "first", "nested1", "Name");
    assertReplaced(onlyPlaceholderParser(), resolver, [
        ["${firstName}", "John"], ["$${firstName}", "$John"], ["}${firstName}", "}John"],
        ["${firstName}$", "John$"], ["${firstName}}", "John}"],
        ["${firstName} ${firstName}", "John John"], ["First name: ${firstName}",
            "First name: John"], ["${firstName} is the first name",
            "John is the first name"], ["${first${nested1}}", "John"],
        ["${${nested0}${nested1}}", "John"],
    ]);
}

// OnlyPlaceholderTests.nestedPlaceholdersAreReplaced
unittest
{
    auto resolver = properties("p1", "v1", "p2", "v2", "p3", "${p1}:${p2}", "p4", "${p3}", "p5",
            "${p1}:${p2}:${bogus}");
    assertReplaced(onlyPlaceholderParser(), resolver, [
        ["${p1}:${p2}", "v1:v2"], ["${p3}", "v1:v2"], ["${p4}", "v1:v2"], [
            "${p5}", "v1:v2:${bogus}"
        ], ["${p0${p0}}", "${p0${p0}}"],
    ]);
}

// OnlyPlaceholderTests.parseWithSinglePlaceholder
unittest
{
    auto resolver = new RecordingResolver("firstName", "John");
    assert(onlyPlaceholderParser().replacePlaceholders("${firstName}", resolver) == "John");
    resolver.verifyPlaceholderResolutions("firstName");
}

// OnlyPlaceholderTests.parseWithPlaceholderAndPrefixText
unittest
{
    auto resolver = new RecordingResolver("firstName", "John");
    assert(onlyPlaceholderParser().replacePlaceholders("This is ${firstName}", resolver) == "This is John");
    resolver.verifyPlaceholderResolutions("firstName");
}

// OnlyPlaceholderTests.parseWithMultiplePlaceholdersAndText
unittest
{
    auto resolver = new RecordingResolver("firstName", "John", "lastName", "Smith");
    assert(onlyPlaceholderParser().replacePlaceholders("User: ${firstName} - ${lastName}.",
            resolver) == "User: John - Smith.");
    resolver.verifyPlaceholderResolutions("firstName", "lastName");
}

// OnlyPlaceholderTests.parseWithNestedPlaceholderInKey
unittest
{
    auto resolver = new RecordingResolver("nested", "Name", "firstName", "John");
    assert(onlyPlaceholderParser().replacePlaceholders("${first${nested}}", resolver) == "John");
    resolver.verifyPlaceholderResolutions("nested", "firstName");
}

// OnlyPlaceholderTests.parseWithMultipleNestedPlaceholdersInKey
unittest
{
    auto resolver = new RecordingResolver("nested0", "first", "nested1", "Name", "firstName", "John");
    assert(onlyPlaceholderParser().replacePlaceholders("${${nested0}${nested1}}", resolver) == "John");
    resolver.verifyPlaceholderResolutions("nested0", "nested1", "firstName");
}

// OnlyPlaceholderTests.placeholderValueContainingSeparatorIsHandledAsIs
unittest
{
    auto resolver = new RecordingResolver("my:test", "value");
    assert(onlyPlaceholderParser().replacePlaceholders("${my:test}", resolver) == "value");
    resolver.verifyPlaceholderResolutions("my:test");
}

// OnlyPlaceholderTests.placeholdersWithoutEscapeCharAreNotEscaped
unittest
{
    auto parser = onlyPlaceholderParser();
    auto resolver = new RecordingResolver("p1", "v1", "p2", "v2", "p3", "v3", "p4", "v4");
    assert(parser.replacePlaceholders("\\${p1}", resolver) == "\\v1");
    assert(parser.replacePlaceholders("\\\\${p2}", resolver) == "\\\\v2");
    assert(parser.replacePlaceholders("\\${p3}\\", resolver) == "\\v3\\");
    assert(parser.replacePlaceholders("a\\${p4}\\z", resolver) == "a\\v4\\z");
    resolver.verifyPlaceholderResolutions("p1", "p2", "p3", "p4");
}

// OnlyPlaceholderTests.textWithInvalidPlaceholderSyntaxIsMerged
unittest
{
    const text = "test${of${with${and${";
    assert(onlyPlaceholderParser().replacePlaceholders(text, delegate string(string) {
            assert(false, "the resolver must not be called");
        }) == text);
}

// DefaultValueTests.placeholderIsReplaced
unittest
{
    auto resolver = properties("firstName", "John", "nested0", "first", "nested1", "Name");
    assertReplaced(defaultValueParser(), resolver, [
        ["${invalid:John}", "John"], ["${first${invalid:Name}}", "John"],
        ["${invalid:${firstName}}", "John"], ["${invalid:${${nested0}${nested1}}}", "John"],
        ["${invalid:$${firstName}}", "$John"], ["${invalid: }${firstName}", " John"],
        ["${invalid:}", ""], ["${:}", ""],
    ]);
}

// DefaultValueTests.nestedPlaceholdersAreReplaced
unittest
{
    auto resolver = properties("p1", "v1", "p2", "v2", "p3", "${p1}:${p2}", "p4", "${p3}", "p5",
            "${p1}:${p2}:${bogus}", "p6", "${p1}:${p2}:${bogus:def}");
    assertReplaced(defaultValueParser(), resolver, [
        ["${p6}", "v1:v2:def"], ["${p6:not-used}", "v1:v2:def"], ["${p6:${invalid}}", "v1:v2:def"],
        ["${invalid:${p1}:${p2}}", "v1:v2"], ["${invalid:${p3}}", "v1:v2"],
        ["${invalid:${p4}}", "v1:v2"], ["${invalid:${p5}}", "v1:v2:${bogus}"],
        ["${invalid:${p6}}", "v1:v2:def"],
    ]);
}

// DefaultValueTests.placeholdersWithExactMatchAreConsidered
unittest
{
    auto resolver = properties("prefix://my-service", "example-service", "px", "prefix", "p1",
            "${prefix://my-service}");
    assertReplaced(defaultValueParser(), resolver, [
        ["${prefix://my-service}", "example-service"], ["${p1}", "example-service"],
    ]);
}

// DefaultValueTests.parseWithKeyEqualsToText
unittest
{
    auto resolver = new RecordingResolver("firstName", "Steve");
    assert(defaultValueParser().replacePlaceholders("${firstName}", resolver) == "Steve");
    resolver.verifyPlaceholderResolutions("firstName");
}

// DefaultValueTests.parseWithHardcodedFallback
unittest
{
    auto resolver = new RecordingResolver();
    assert(defaultValueParser().replacePlaceholders("${firstName:Steve}", resolver) == "Steve");
    resolver.verifyPlaceholderResolutions("firstName:Steve", "firstName");
}

// DefaultValueTests.parseWithNestedPlaceholderInKeyUsingFallback
unittest
{
    auto resolver = new RecordingResolver("firstName", "John");
    assert(defaultValueParser().replacePlaceholders("${first${invalid:Name}}", resolver) == "John");
    resolver.verifyPlaceholderResolutions("invalid:Name", "invalid", "firstName");
}

// DefaultValueTests.parseWithFallbackUsingPlaceholder
unittest
{
    auto resolver = new RecordingResolver("firstName", "John");
    assert(defaultValueParser().replacePlaceholders("${invalid:${firstName}}", resolver) == "John");
    resolver.verifyPlaceholderResolutions("invalid", "firstName");
}

// EscapedTests.escapedPlaceholderIsNotReplaced
unittest
{
    auto resolver = properties("firstName", "John", "${test}", "John", "p1", "v1", "p2", "\\${p1:default}",
            "p3", "${p2}", "p4", "adc${p0:\\${p1}}", "p5", "adc${\\${p0}:${p1}}", "p6",
            "adc${p0:def\\${p1}}", "p7", "adc\\${");
    assertReplaced(escapedParser(), resolver, [
        ["\\${firstName}", "${firstName}"], [
            "First name: \\${firstName}", "First name: ${firstName}"
        ], ["$\\${firstName}", "$${firstName}"], ["\\}${firstName}", "\\}John"],
        ["${\\${test}}", "John"], ["${p2}", "${p1:default}"], ["${p3}", "${p1:default}"],
        ["${p4}", "adc${p1}"], ["${p5}", "adcv1"], ["${p6}", "adcdef${p1}"], ["${p7}",
            "adc\\${"],
        // Double backslash
        ["DOMAIN\\\\${user.name}", "DOMAIN\\${user.name}"],
        // Triple backslash
        ["triple\\\\\\${backslash}", "triple\\\\${backslash}"],
        // Multiple escaped placeholders
        ["start\\${prop1}middle\\${prop2}end", "start${prop1}middle${prop2}end"],
    ]);
}

// EscapedTests.escapedSeparatorIsNotReplaced
unittest
{
    auto resolver = properties("first:Name", "John");
    assertReplaced(escapedParser(), resolver, [
        ["${first\\:Name}", "John"], ["${last\\:Name}", "${last:Name}"],
    ]);
}

// EscapedTests.escapedSeparatorInNestedPlaceholderIsNotReplaced
unittest
{
    auto resolver = properties("app.environment", "qa", "app.service", "protocol",
            "protocol://host/qa/name", "protocol://example.com/qa/name",
            "service/host/qa/name", "https://example.com/qa/name",
            "service/host/qa/name:value", "https://example.com/qa/name-value");
    assertReplaced(escapedParser(), resolver, [
        ["${protocol\\://host/${app.environment}/name}", "protocol://example.com/qa/name"],
        ["${${app.service}\\://host/${app.environment}/name}", "protocol://example.com/qa/name"],
        ["${service/host/${app.environment}/name:\\value}", "https://example.com/qa/name"],
        ["${service/host/${name\\:value}/}", "${service/host/${name:value}/}"],
    ]);
}

private PlaceholderParser exceptionParser()
{
    return new PlaceholderParser("${", "}", ":", null, false);
}

// ExceptionTests.textWithCircularReference
unittest
{
    auto resolver = properties("pL", "${pR}", "pR", "${pL}");
    auto e = expectThrows!PlaceholderResolutionException(() {
        exceptionParser().replacePlaceholders("${pL}", resolver);
    });
    assert(e.getMessage() == "Circular placeholder reference 'pL' in value \"${pL}\" <-- \"${pR}\" <-- \"${pL}\"");
}

// ExceptionTests.unresolvablePlaceholderIsReported
unittest
{
    auto e = expectThrows!PlaceholderResolutionException(() {
        exceptionParser().replacePlaceholders("X${bogus}Z", delegate string(string) => null);
    });
    assert(e.getMessage() == "Could not resolve placeholder 'bogus' in value \"X${bogus}Z\"");
    assert(e.getCause() is null);
    assert(e.getPlaceholder() == "bogus");
}

// ExceptionTests.unresolvablePlaceholderInNestedPlaceholderIsReportedWithChain
unittest
{
    auto resolver = properties("p1", "v1", "p2", "v2", "p3", "${p1}:${p2}:${bogus}");
    auto e = expectThrows!PlaceholderResolutionException(() {
        exceptionParser().replacePlaceholders("${p3}", resolver);
    });
    assert(e.getMessage() == "Could not resolve placeholder 'bogus' in value \"${p1}:${p2}:${bogus}\" <-- \"${p3}\"");
    assert(e.getCause() is null);
    assert(e.getValues().toArray() == ["${p1}:${p2}:${bogus}", "${p3}"]);
}

// Flint (R14): non-ASCII prefixes, suffixes, separators, escape characters, keys and values.
unittest
{
    auto parser = new PlaceholderParser("«", "»", "→", '¶', false);
    auto resolver = properties("日本", "語", "名前", "«日本»😀", "😀", "smile");
    assertReplaced(parser, resolver, [
        ["«日本»", "語"], ["前«名前»後", "前語😀後"], ["¶«日本»",
            "«日本»"], ["«不明→既定»", "既定"], ["«😀»«😀»", "smilesmile"],
    ]);
    auto e = expectThrows!PlaceholderResolutionException(() {
        parser.replacePlaceholders("«不明»", resolver);
    });
    assert(e.getMessage() == "Could not resolve placeholder '不明' in value \"«不明»\"");
    auto lenient = new PlaceholderParser("«", "»", "→", '¶', true);
    assert(lenient.replacePlaceholders("«不明¶→キー»", resolver) == "«不明→キー»");
    // A multi-byte escape character before a prefix is removed whole.
    auto euro = new PlaceholderParser("${", "}", ":", '€', true);
    assert(euro.replacePlaceholders("€${x}é", properties("x", "1")) == "${x}é");
    // An empty value is a value, unlike null.
    assert(defaultValueParser().replacePlaceholders("[${empty:fallback}]", properties("empty", "")) == "[]");
}
