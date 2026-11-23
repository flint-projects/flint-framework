// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.util.PatternMatchUtilsTests` (v7.1.0): one `unittest` per Java test
method, each starting with a `// <JavaTestName>` comment. No test is skipped.
+/
module flint.util.pattern_match_utils_test;

import flint.util : PatternMatchUtils;

@safe:

private void assertMatches(string pattern, string str)
{
    assert(PatternMatchUtils.simpleMatch(pattern, str), pattern ~ " / " ~ str);
    assert(PatternMatchUtils.simpleMatchIgnoreCase(pattern, str), pattern ~ " / " ~ str);
}

private void assertDoesNotMatch(string pattern, string str)
{
    assert(!PatternMatchUtils.simpleMatch(pattern, str), pattern ~ " / " ~ str);
    assert(!PatternMatchUtils.simpleMatchIgnoreCase(pattern, str), pattern ~ " / " ~ str);
}

private void testMixedCaseMatch(string pattern, string str)
{
    assert(!PatternMatchUtils.simpleMatch(pattern, str), pattern ~ " / " ~ str);
    assert(PatternMatchUtils.simpleMatchIgnoreCase(pattern, str), pattern ~ " / " ~ str);
}

private void assertMatches(string[] patterns, string str)
{
    assert(PatternMatchUtils.simpleMatch(patterns, str));
    assert(PatternMatchUtils.simpleMatchIgnoreCase(patterns, str));
}

private void assertDoesNotMatch(string[] patterns, string str)
{
    assert(!PatternMatchUtils.simpleMatch(patterns, str));
    assert(!PatternMatchUtils.simpleMatchIgnoreCase(patterns, str));
}

// nullAndEmptyValues
unittest
{
    assertDoesNotMatch(cast(string) null, null);
    assertDoesNotMatch(cast(string) null, "");
    assertDoesNotMatch("123", null);
    assertDoesNotMatch(cast(string[]) null, null);
    assertDoesNotMatch(cast(string[]) null, "");
    string[] none = [];
    assertDoesNotMatch(none, null);
}

// trivial
unittest
{
    assertMatches("", "");
    assertMatches("123", "123");
    assertMatches("*", "123");
    assertMatches([""], "");
    assertMatches(["123"], "123");
    assertMatches(["*"], "123");
    assertMatches([null, ""], "");
    assertMatches([null, "123"], "123");
    assertMatches([null, "*"], "123");
    testMixedCaseMatch("abC", "Abc");
}

// startsWith
unittest
{
    assertMatches("get*", "getMe");
    assertDoesNotMatch("get*", "setMe");
    testMixedCaseMatch("geT*", "GetMe");
}

// endsWith
unittest
{
    assertMatches("*Test", "getMeTest");
    assertDoesNotMatch("*Test", "setMe");
    testMixedCaseMatch("*TeSt", "getMeTesT");
}

// between
unittest
{
    assertDoesNotMatch("*stuff*", "getMeTest");
    assertMatches("*stuff*", "getstuffTest");
    assertMatches("*stuff*", "stuffTest");
    assertMatches("*stuff*", "getstuff");
    assertMatches("*stuff*", "stuff");
    testMixedCaseMatch("*stuff*", "getStuffTest");
    testMixedCaseMatch("*stuff*", "StuffTest");
    testMixedCaseMatch("*stuff*", "getStuff");
    testMixedCaseMatch("*stuff*", "Stuff");
}

// startsEnds
unittest
{
    assertMatches("on*Event", "onMyEvent");
    assertMatches("on*Event", "onEvent");
    assertDoesNotMatch("3*3", "3");
    assertMatches("3*3", "33");
    testMixedCaseMatch("on*Event", "OnMyEvenT");
    testMixedCaseMatch("on*Event", "OnEvenT");
}

// startsEndsBetween
unittest
{
    assertMatches("12*45*78", "12345678");
    assertDoesNotMatch("12*45*78", "123456789");
    assertDoesNotMatch("12*45*78", "012345678");
    assertMatches("12*45*78", "124578");
    assertMatches("12*45*78", "1245457878");
    assertDoesNotMatch("3*3*3", "33");
    assertMatches("3*3*3", "333");
}

// ridiculous
unittest
{
    assertMatches("*1*2*3*", "0011002001010030020201030");
    assertDoesNotMatch("1*2*3*4", "10300204");
    assertDoesNotMatch("1*2*3*3", "10300203");
    assertMatches("*1*2*3*", "123");
    assertDoesNotMatch("*1*2*3*", "132");
}

// patternVariants
unittest
{
    assertDoesNotMatch("*a", "*");
    assertMatches("*a", "a");
    assertDoesNotMatch("*a", "b");
    assertMatches("*a", "aa");
    assertMatches("*a", "ba");
    assertDoesNotMatch("*a", "ab");
    assertDoesNotMatch("**a", "*");
    assertMatches("**a", "a");
    assertDoesNotMatch("**a", "b");
    assertMatches("**a", "aa");
    assertMatches("**a", "ba");
    assertDoesNotMatch("**a", "ab");
}

// Flint (R14): patterns and strings with non-ASCII characters.
unittest
{
    assertMatches("*日本*", "こんにちは日本です");
    assertMatches("日*語", "日本語");
    assertDoesNotMatch("日*語", "日本");
    assertMatches("*😀", "smile 😀");
    assertMatches("é*é", "éé");
    assertDoesNotMatch("é*é", "é");
    testMixedCaseMatch("ÉCOLE*", "école normale");
    testMixedCaseMatch("*Straße", "die STRAßE");
    testMixedCaseMatch("a*ÄÖ*z", "AxäöyZ");
    // The Kelvin sign (3 bytes) matches 'k' (1 byte) ignoring case: offsets follow the matched text.
    testMixedCaseMatch("K*x", "kax");
}
