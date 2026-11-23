/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/engine/messageinterpolation/InterpolationHelperTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: each TestNG data provider's rows run in one D unittest, labelled with the method's
parameter types where two methods share a name. Java's `null` String is D's null `string`, which is also the empty
one: `unescapeMessageParameter(null)` and `resolveToString(null)` cannot throw a NullPointerException, so
testUnescapeNullThrows and testResolveToStringNullThrows are not ported. Flint allocates the result of both
escapes and has no public `isEscapeableChar` or `resolveToString` (array attributes are rendered when a constraint
is read): those tests are gated.
+/
module flint.hibernate.validator.interpolation_helper_test;

import flint.hibernate.validator.messageinterpolation : escapeMessageParameter, unescapeMessageParameter;

@safe:

// The "escape" data provider: input and its escaped form.
private static immutable string[2][] escape = [
    [null, null], ["", ""], ["test", "test"], ["hello world 123!", "hello world 123!"],
    // each special character on its own
    ["{", `\{`], ["}", `\}`], ["$", `\$`], [`\`, `\\`],
    // combinations
    ["{}", `\{\}`], ["${}", `\$\{\}`], ["a{b}c$d", `a\{b\}c\$d`], ["{{{{$$$$", `\{\{\{\{\$\$\$\$`],
    // pre-existing backslashes
    [`\{`, `\\\{`], // \ {  ->  \\ \{
    [`a\b`, `a\\b`], // a \ b -> a \\ b
    [`\n`, `\\n`], // backslash + 'n' (not a newline)
    // specials at the edges of the string
    ["{value}", `\{value\}`], [`${a} {b} \ c`, `\$\{a\} \{b\} \\ c`],
    // unicode around specials
    ["héllo {wörld}", `héllo \{wörld\}`],
];

// The "unescape" data provider: input and its unescaped form.
private static immutable string[2][] unescape = [
    ["", ""],
    // bare specials without a backslash are left alone
    ["{ } $ plain", "{ } $ plain"],
    // single escapes
    [`\{`, "{"], [`\}`, "}"], [`\$`, "$"], [`\\`, `\`],
    // mixed content
    [`a\{b\}c\$d\\e`, `a{b}c$d\e`], [`\$\{\}`, "${}"],
    // backslash followed by a non-special character is kept as-is
    [`\n`, `\n`], // backslash + 'n' (not a newline)
    [`\t`, `\t`], [`a \ b`, `a \ b`],
    // trailing lone backslash is preserved
    [`abc\`, `abc\`],
];

@("InterpolationHelperTest.testEscapeMessageParameter")
unittest
{
    assert(escapeMessageParameter(null) is null);
    assert(escapeMessageParameter("test") == "test");
    assert(escapeMessageParameter("{}") == `\{\}`);
    assert(escapeMessageParameter(`${\}`) == `\$\{\\\}`);
}

@("InterpolationHelperTest.testEscapeMessageParameter(String, String)")
unittest
{
    foreach (row; escape)
        assert(escapeMessageParameter(row[0]) == row[1], row[0]);
}

// Gap: Flint's escapeMessageParameter always allocates its result.
version (FlintInterpolationHelperApi)
{
    @("InterpolationHelperTest.testEscapeReturnsSameInstanceWhenNothingToEscape")
    unittest
    {
        const plain = "no special characters here";
        assert(escapeMessageParameter(plain) is plain);
        assert(escapeMessageParameter("").length == 0);
    }
}

@("InterpolationHelperTest.testUnescapeMessageParameter")
unittest
{
    foreach (row; unescape)
        assert(unescapeMessageParameter(row[0]) == row[1], row[0]);
}

// Gap: Flint's unescapeMessageParameter always allocates its result.
version (FlintInterpolationHelperApi)
{
    @("InterpolationHelperTest.testUnescapeReturnsSameInstanceWhenNoBackslash")
    unittest
    {
        const message = "{ } $ no backslashes";
        assert(unescapeMessageParameter(message) is message);
    }
}

@("InterpolationHelperTest.testUnescapeIsInverseOfEscape")
unittest
{
    foreach (row; escape)
    {
        if (row[0] is null)
            continue;
        assert(unescapeMessageParameter(row[1]) == row[0], row[1]);
    }
}

@("InterpolationHelperTest.testUnescapeIsNotIdempotent")
unittest
{
    // chars: \ \ {  =>  first pass yields \ {, second pass yields {
    // documents that unescaping must be applied exactly once at the end of interpolation
    const input = `\\{`;
    assert(unescapeMessageParameter(input) == `\{`);
    assert(unescapeMessageParameter(unescapeMessageParameter(input)) == "{");
}

// Gap: Flint has no public isEscapeableChar or resolveToString.
version (FlintInterpolationHelperApi)
{
    @("InterpolationHelperTest.testIsEscapeableChar")
    unittest
    {
        foreach (c; "{}$\\")
            assert(isEscapeableChar(c));
        foreach (dchar c; "az0_-. \t\néé€")
            assert(!isEscapeableChar(c));
    }

    @("InterpolationHelperTest.testResolveToString")
    unittest
    {
        assert(resolveToString("plain") == "plain");
        assert(resolveToString(42) == "42");
        assert(resolveToString(true) == "true");
        // primitive arrays: populated and empty
        assert(resolveToString([true, false]) == "[true, false]");
        assert(resolveToString(['a', 'b']) == "[a, b]");
        assert(resolveToString(cast(byte[])[1, -2]) == "[1, -2]");
        assert(resolveToString(cast(short[])[1, 2]) == "[1, 2]");
        assert(resolveToString([1, 2, 3]) == "[1, 2, 3]");
        assert(resolveToString([1L, 2L]) == "[1, 2]");
        assert(resolveToString([1.5f]) == "[1.5]");
        assert(resolveToString([0.1, -2.0]) == "[0.1, -2.0]");
        assert(resolveToString(cast(bool[])[]) == "[]");
        assert(resolveToString(cast(int[])[]) == "[]");
        // object arrays, incl. null elements and empty
        assert(resolveToString(["a", "b"]) == "[a, b]");
        assert(resolveToString([Nullable!int(1), Nullable!int.init]) == "[1, null]");
        assert(resolveToString(cast(Object[])[]) == "[]");
    }

    @("InterpolationHelperTest.testResolveToStringNestedStringArray")
    unittest
    {
        assert(resolveToString([["a", "b"], ["c"]]) == "[[a, b], [c]]");
    }

    @("InterpolationHelperTest.testResolveToStringNestedPrimitiveArray")
    unittest
    {
        assert(resolveToString([[1, 2], [3]]) == "[[1, 2], [3]]");
    }
}
