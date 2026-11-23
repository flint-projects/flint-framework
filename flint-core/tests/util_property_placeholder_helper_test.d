// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.util.PropertyPlaceholderHelperTests` (v7.1.0), with its nested
`DefaultValueTests`: one `unittest` per Java test method, each starting with a `// <JavaTestName>` comment.
`java.util.Properties` is adapted to `Map!(string, string)` (R10). No test is skipped.
+/
module flint.util.property_placeholder_helper_test;

import flint.java.util : LinkedHashMap, Map;
import flint.util : PlaceholderResolutionException, PropertyPlaceholderHelper;
import flint.util.test_support : expectThrows;

@safe:

private Map!(string, string) props(string[] pairs...)
{
    auto result = new LinkedHashMap!(string, string)();
    for (size_t i = 0; i < pairs.length; i += 2)
        result.put(pairs[i], pairs[i + 1]);
    return result;
}

private PropertyPlaceholderHelper helper()
{
    return new PropertyPlaceholderHelper("${", "}");
}

private final class RecordingResolver : PropertyPlaceholderHelper.PlaceholderResolver
{
    private string[string] values;
    string[] calls;

    this(string[] pairs...)
    {
        for (size_t i = 0; i < pairs.length; i += 2)
            values[pairs[i]] = pairs[i + 1];
    }

    string resolvePlaceholder(string placeholderName)
    {
        calls ~= placeholderName;
        auto value = placeholderName in values;
        return value is null ? null : *value;
    }
}

// withProperties
unittest
{
    assert(helper().replacePlaceholders("foo=${foo}", props("foo", "bar")) == "foo=bar");
}

// withMultipleProperties
unittest
{
    auto properties = props("foo", "bar", "bar", "baz");
    assert(helper().replacePlaceholders("foo=${foo},bar=${bar}", properties) == "foo=bar,bar=baz");
}

// recurseInProperty
unittest
{
    assert(helper().replacePlaceholders("foo=${bar}", props("bar", "${baz}", "baz", "bar")) == "foo=bar");
}

// recurseInPlaceholder
unittest
{
    assert(helper().replacePlaceholders("foo=${b${inner}}", props("bar", "bar", "inner", "ar")) == "foo=bar");
    auto properties = props("top", "${child}+${child}", "child", "${${differentiator}.grandchild}",
            "differentiator", "first", "first.grandchild", "actualValue");
    assert(helper().replacePlaceholders("${top}", properties) == "actualValue+actualValue");
}

// withResolver
unittest
{
    PropertyPlaceholderHelper.PlaceholderResolver resolver = new RecordingResolver("foo", "bar");
    assert(helper().replacePlaceholders("foo=${foo}", resolver) == "foo=bar");
}

// unresolvedPlaceholderIsIgnored
unittest
{
    assert(helper().replacePlaceholders("foo=${foo},bar=${bar}", props("foo", "bar")) == "foo=bar,bar=${bar}");
}

// unresolvedPlaceholderAsError
unittest
{
    auto strict = new PropertyPlaceholderHelper("${", "}", null, null, false);
    expectThrows!PlaceholderResolutionException(() {
        strict.replacePlaceholders("foo=${foo},bar=${bar}", props("foo", "bar"));
    });
}

private PropertyPlaceholderHelper defaultValueHelper()
{
    return new PropertyPlaceholderHelper("${", "}", ":", null, true);
}

// DefaultValueTests.defaultValueIsApplied
unittest
{
    auto properties = props("one", "1", "two", "2");
    const string[2][] rows = [
        ["${invalid:test}", "test"], ["${invalid:${one}}", "1"], ["${invalid:${one}${two}}", "12"],
        ["${invalid:${one}:${two}}", "1:2"], ["${invalid:${also_invalid:test}}", "test"],
        ["${invalid:${also_invalid:${one}}}", "1"],
    ];
    foreach (row; rows)
        assert(defaultValueHelper().replacePlaceholders(row[0], properties) == row[1], row[0]);
}

// DefaultValueTests.defaultValueIsNotEvaluatedEarly
unittest
{
    auto resolver = new RecordingResolver("one", "1");
    assert(defaultValueHelper().replacePlaceholders("This is ${one:or${two}}", resolver) == "This is 1");
    assert(resolver.calls == ["one"], "two must never be resolved");
}

// DefaultValueTests.placeholdersWithExactMatchAreConsidered
unittest
{
    auto properties = props("prefix://my-service", "example-service", "px", "prefix", "p1", "${prefix://my-service}");
    assert(defaultValueHelper().replacePlaceholders("${prefix://my-service}", properties) == "example-service");
    assert(defaultValueHelper().replacePlaceholders("${p1}", properties) == "example-service");
}

// Flint: the call shape flint.core.env uses, a delegate resolver (R9), and argument checks.
unittest
{
    import flint.java.lang : IllegalArgumentException;

    const string[string] environment = ["user.name": "olaf", "home": "/home/${user.name}"];
    string delegate(string) @safe resolver = (string key) {
        auto value = key in environment;
        return value is null ? null : *value;
    };
    auto envHelper = new PropertyPlaceholderHelper("${", "}", ":", '\\', true);
    assert(envHelper.replacePlaceholders("${home}/x \\${home} ${missing:none} ${gone}",
            resolver) == "/home/olaf/x ${home} none ${gone}");
    auto strict = new PropertyPlaceholderHelper("${", "}", ":", '\\', false);
    auto e = expectThrows!PlaceholderResolutionException(() {
        strict.replacePlaceholders("${gone}", resolver);
    });
    assert(e.getMessage() == "Could not resolve placeholder 'gone' in value \"${gone}\"");
    expectThrows!IllegalArgumentException(() { strict.replacePlaceholders(null, resolver); });
    expectThrows!IllegalArgumentException(() { new PropertyPlaceholderHelper(null, "}"); });
    expectThrows!IllegalArgumentException(() {
        helper().replacePlaceholders("x", cast(Map!(string, string)) null);
    });
}
