/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/util/pattern/PathPatternTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; tests of the
`@Nested` classes keep the nested class name in their label. flint.web's `PathPattern` matches path strings, so
`toPathContainer(path)` becomes the path itself, and `SPECIFICITY_COMPARATOR` is `PathPattern.compareSpecificity`.
Cases that need parts of `PathPattern`, `PathPatternParser` and `PathContainer` flint.web has not ported yet wait
behind the versions named beside them.
+/
module flint.web.util.path_pattern_tests;

import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.web.util.pattern : PathMatchInfo, PathPattern, PathPatternParser;

@safe:

private bool throws(E : Throwable)(scope void delegate() @safe action)
{
    try
        action();
    catch (E)
        return true;
    return false;
}

/// The message of the `E` that `action` throws, or `null` when it throws none.
private string thrownMessage(E : Throwable)(scope void delegate() @safe action)
{
    try
        action();
    catch (E e)
        return e.msg;
    return null;
}

/// AssertJ's `containsEntry` on `getUriVariables()`.
private bool containsEntry(I)(I info, string key, string value)
{
    foreach (entry; info.getUriVariables())
        if (entry[0] == key && entry[1] == value)
            return true;
    return false;
}

// MatchingTests

@("PathPatternTests.MatchingTests.basicMatching")
unittest
{
    checkMatches("", "");
    checkMatches("", null);
    checkNoMatch("/abc", "/");
    checkMatches("/", "/");
    checkNoMatch("/", "/a");
    checkMatches("foo/bar/", "foo/bar/");
    checkNoMatch("foo", "foobar");
    checkMatches("/foo/bar", "/foo/bar");
    checkNoMatch("/foo/bar", "/foo/baz");
}

@("PathPatternTests.MatchingTests.literalPathElements")
unittest
{
    checkMatches("foo", "foo");
    checkNoMatch("foo", "bar");
    checkNoMatch("foo", "/foo");
    checkNoMatch("/foo", "foo");
    checkMatches("/f", "/f");
    checkMatches("/foo", "/foo");
    checkNoMatch("/foo", "/food");
    checkNoMatch("/food", "/foo");
    checkMatches("/foo/", "/foo/");
    checkMatches("/foo/bar/woo", "/foo/bar/woo");
    checkMatches("foo/bar/woo", "foo/bar/woo");
}

// Segments that mix literal text with `?`, `*` or `{name}` (Spring's SingleCharWildcardedPathElement and
// RegexPathElement) are not ported; the parser rejects them.
version (FlintPathPatternPartialSegments)
{
    @("PathPatternTests.MatchingTests.questionMarks")
    unittest
    {
        checkNoMatch("a", "ab");
        checkMatches("/f?o/bar", "/foo/bar");
        checkNoMatch("/foo/b2r", "/foo/bar");
        checkNoMatch("?", "te");
        checkMatches("?", "a");
        checkMatches("???", "abc");
        checkNoMatch("tes?", "te");
        checkNoMatch("tes?", "tes");
        checkNoMatch("tes?", "testt");
        checkNoMatch("tes?", "tsst");
        checkMatches(".?.a", ".a.a");
        checkNoMatch(".?.a", ".aba");
        checkMatches("/f?o/bar", "/f%20o/bar");
    }
}

// PathPattern.toChainString(), which renders the parsed path elements, is not ported.
version (FlintPathPatternChainString)
{
    @("PathPatternTests.MatchingTests.multipleSeparatorsInPattern")
    unittest
    {
        const pp = parse("a//b//c");
        assert(pp.toChainString() == "Literal(a) Separator(/) Separator(/) Literal(b) Separator(/) Separator(/) "
                ~ "Literal(c)");
        assertMatches(pp, "a//b//c");
        assert(parse("a//**").toChainString() == "Literal(a) Separator(/) WildcardSegments(/**)");
        checkMatches("///abc", "///abc");
        checkNoMatch("///abc", "/abc");
        checkNoMatch("//", "/");
        checkMatches("//", "//");
        checkNoMatch("///abc//d/e", "/abc/d/e");
        checkMatches("///abc//d/e", "///abc//d/e");
        checkNoMatch("///abc//{def}//////xyz", "/abc/foo/xyz");
        checkMatches("///abc//{def}//////xyz", "///abc//p//////xyz");
    }
}

@("PathPatternTests.MatchingTests.multipleSelectorsInPath")
unittest
{
    checkNoMatch("/abc", "////abc");
    checkNoMatch("/", "//");
    checkNoMatch("/abc/def/ghi", "/abc//def///ghi");
    checkNoMatch("/abc", "////abc");
    checkMatches("////abc", "////abc");
    checkNoMatch("/", "//");
    checkNoMatch("/abc//def", "/abc/def");
    checkNoMatch("/abc//def///ghi", "/abc/def/ghi");
    checkMatches("/abc//def///ghi", "/abc//def///ghi");
}

@("PathPatternTests.MatchingTests.multipleSeparatorsInPatternAndPath")
unittest
{
    checkNoMatch("///one///two///three", "//one/////two///////three");
    checkMatches("//one/////two///////three", "//one/////two///////three");
    checkNoMatch("//one//two//three", "/one/////two/three");
    checkMatches("/one/////two/three", "/one/////two/three");
    checkCapture("///{foo}///bar", "///one///bar", "foo", "one");
}

// `**` and `{*name}` followed by more pattern elements (allowed since Spring 7.0) are not ported; the parser
// accepts them only as the last element.
version (FlintPathPatternLeadingCatchAll)
{
    @("PathPatternTests.MatchingTests.captureSegmentsAtStart")
    unittest
    {
        checkMatches("/{*foobar}/resource", "/resource");
        checkNoMatch("/{*foobar}/resource", "/resourceX");
        checkNoMatch("/{*foobar}/resource", "/foobar/resourceX");
        checkMatches("/{*foobar}/resource", "/foobar/resource");
    }
}

@("PathPatternTests.MatchingTests.captureSegmentsAtEnd")
unittest
{
    checkMatches("/resource/{*foobar}", "/resource");
    checkNoMatch("/resource/{*foobar}", "/resourceX");
    checkNoMatch("/resource/{*foobar}", "/resourceX/foobar");
    checkMatches("/resource/{*foobar}", "/resource/foobar");
}

version (FlintPathPatternPartialSegments)
{
    @("PathPatternTests.MatchingTests.wildcards")
    unittest
    {
        checkMatches("/*/bar", "/foo/bar");
        checkNoMatch("/*/bar", "/foo/baz");
        checkNoMatch("/*/bar", "//bar");
        checkNoMatch("/*/bar", "/bar");
        checkMatches("/f*/bar", "/foo/bar");
        checkMatches("a/*", "a/");
        checkMatches("/*", "/");
        checkMatches("/*/bar", "/foo/bar");
        checkNoMatch("/*/bar", "/foo/baz");
        checkNoMatch("/*/bar", "/bar");
        checkMatches("/f*/bar", "/foo/bar");
        checkMatches("/a*b*c*d/bar", "/abcd/bar");
        checkMatches("*a*", "testa");
        checkMatches("a/*", "a/");
        checkNoMatch("a/*", "a//"); // no data for *
        const ppp = new PathPatternParser();
        assert(!ppp.parse("a/*").matches("a//"));
        checkMatches("a/*", "a/a");
    }
}

version (FlintPathPatternLeadingCatchAll)
{
    @("PathPatternTests.MatchingTests.wildcardSegmentsStart")
    unittest
    {
        checkMatches("/**/resource", "/resource");
        checkNoMatch("/**/resource", "/Xresource");
        checkNoMatch("/**/resource", "/foobar/resourceX");
        checkMatches("/**/resource", "/foobar/resource");

        checkMatches("/**/resource/test", "/foo/bar/resource/test");
        checkNoMatch("/**/resource/test", "/foo/bar/resource/t");
    }
}

@("PathPatternTests.MatchingTests.wildcardSegmentsEnd")
unittest
{
    checkMatches("/resource/**", "/resource");
    checkNoMatch("/resource/**", "/resourceX");
    checkNoMatch("/resource/**", "/resourceX/foobar");
    checkMatches("/resource/**", "/resource/foobar");
}

version (FlintPathPatternLeadingCatchAll)
{
    @("PathPatternTests.MatchingTests.wildcardSegmentsThenNonLiteral")
    unittest
    {
        checkMatches("/**/*.js", "/script.js");
        checkMatches("/**/*.js", "/js/script.js");
        checkMatches("/**/*.js", "/files/js/script.js");
        checkMatches("/**/{type}/*.js", "/files/js/script.js");

        checkNoMatch("/**/*.js", "/files/style.css");
    }
}

version (FlintPathPatternPartialSegments)
{
    @("PathPatternTests.MatchingTests.antPathMatcherTests")
    unittest
    {
        // test exact matching
        checkMatches("test", "test");
        checkMatches("/test", "/test");
        checkMatches("https://example.org", "https://example.org");
        checkNoMatch("/test.jpg", "test.jpg");
        checkNoMatch("test", "/test");
        checkNoMatch("/test", "test");

        // test matching with ?'s
        checkMatches("t?st", "test");
        checkMatches("??st", "test");
        checkMatches("tes?", "test");
        checkMatches("te??", "test");
        checkMatches("?es?", "test");
        checkNoMatch("tes?", "tes");
        checkNoMatch("tes?", "testt");
        checkNoMatch("tes?", "tsst");

        // test matching with *'s
        checkMatches("*", "test");
        checkMatches("test*", "test");
        checkMatches("test*", "testTest");
        checkMatches("test/*", "test/Test");
        checkMatches("test/*", "test/t");
        checkMatches("test/*", "test/");
        checkMatches("*test*", "AnothertestTest");
        checkMatches("*test", "Anothertest");
        checkMatches("*.*", "test.");
        checkMatches("*.*", "test.test");
        checkMatches("*.*", "test.test.test");
        checkMatches("test*aaa", "testblaaaa");
        checkNoMatch("test*", "tst");
        checkNoMatch("test*", "tsttest");
        checkMatches("test*", "test"); // trailing slash is optional
        checkNoMatch("test*", "test/t");
        checkNoMatch("test/*", "test");
        checkNoMatch("*test*", "tsttst");
        checkNoMatch("*test", "tsttst");
        checkNoMatch("*.*", "tsttst");
        checkNoMatch("test*aaa", "test");
        checkNoMatch("test*aaa", "testblaaab");

        // test matching with ?'s and /'s
        checkMatches("/?", "/a");
        checkMatches("/?/a", "/a/a");
        checkMatches("/a/?", "/a/b");
        checkMatches("/??/a", "/aa/a");
        checkMatches("/a/??", "/a/bb");
        checkMatches("/?", "/a");

        checkMatches("/**", "");
        checkMatches("/books/**", "/books");
        checkMatches("/**", "/testing/testing");
        checkMatches("/*/**", "/testing/testing");
        checkMatches("/bla*bla/test", "/blaXXXbla/test");
        checkMatches("/*bla/test", "/XXXbla/test");
        checkNoMatch("/bla*bla/test", "/blaXXXbl/test");
        checkNoMatch("/*bla/test", "XXXblab/test");
        checkNoMatch("/*bla/test", "XXXbl/test");
        checkNoMatch("/????", "/bala/bla");
        checkMatches("/foo/bar/**", "/foo/bar/");
        checkMatches("/{bla}.html", "/testing.html");
        checkCapture("/{bla}.*", "/testing.html", "bla", "testing");
    }
}

// VariableCaptureTests

// `{name:regex}` captures (Spring's constrained CaptureVariablePathElement) are not ported; the parser rejects
// them.
version (FlintPathPatternRegexCaptures)
{
    @("PathPatternTests.VariableCaptureTests.constrainedMatches")
    unittest
    {
        checkCapture("{foo:[0-9]*}", "123", "foo", "123");
        checkNoMatch("{foo:[0-9]*}", "abc");
        checkNoMatch("/{foo:[0-9]*}", "abc");
        checkCapture("/*/{foo:....}/**", "/foo/barg/foo", "foo", "barg");
        checkCapture("/*/{foo:....}/**", "/foo/barg/abc/def/ghi", "foo", "barg");
        checkNoMatch("{foo:....}", "99");
        checkMatches("{foo:..}", "99");
        checkCapture("/{abc:\\{\\}}", "/{}", "abc", "{}");
        checkCapture("/{abc:\\[\\]}", "/[]", "abc", "[]");
        checkCapture("/{abc:\\\\\\\\}", "/\\\\"); // this is fun...
    }
}

version (FlintPathPatternLeadingCatchAll)
{
    @("PathPatternTests.VariableCaptureTests.captureSegmentsAtStart")
    unittest
    {
        checkCapture("/{*foobar}/resource", "/foobar/resource", "foobar", "/foobar");
        checkCapture("/{*something}/customer", "/99/customer", "something", "/99");
        checkCapture("/{*something}/customer", "/aa/bb/cc/customer", "something", "/aa/bb/cc");
        checkCapture("/{*something}/customer", "/customer", "something", "");
        checkCapture("/{*something}/customer", "//////99/customer", "something", "//////99");
    }
}

@("PathPatternTests.VariableCaptureTests.captureSegmentsAtEnd")
unittest
{
    checkCapture("/resource/{*foobar}", "/resource/foobar", "foobar", "/foobar");
    checkCapture("/customer/{*something}", "/customer/99", "something", "/99");
    checkCapture("/customer/{*something}", "/customer/aa/bb/cc", "something", "/aa/bb/cc");
    checkCapture("/customer/{*something}", "/customer/", "something", "/");
    checkCapture("/customer/////{*something}", "/customer/////", "something", "/");
    checkCapture("/customer/////{*something}", "/customer//////", "something", "//");
    checkCapture("/customer//////{*something}", "/customer//////99", "something", "/99");
    checkCapture("/customer//////{*something}", "/customer//////99", "something", "/99");
    checkCapture("/customer/{*something}", "/customer", "something", "");
    checkCapture("/{*something}", "", "something", "");
    checkCapture("/customer/{*something}", "/customer//////99", "something", "//////99");
}

version (FlintPathPatternRegexCaptures)
{
    @("PathPatternTests.VariableCaptureTests.encodingAndBoundVariablesCapturePathElement")
    unittest
    {
        checkCapture("{var}", "f%20o", "var", "f o");
        checkCapture("{var1}/{var2}", "f%20o/f%7Co", "var1", "f o", "var2", "f|o");
        checkCapture("{var1}/{var2}", "f%20o/f%7co", "var1", "f o", "var2", "f|o"); // lower case encoding
        checkCapture("{var:foo}", "foo", "var", "foo");
        checkCapture("{var:f o}", "f%20o", "var", "f o"); // constraint is expressed in non encoded form
        checkCapture("{var:f.o}", "f%20o", "var", "f o");
        checkCapture("{var:f\\|o}", "f%7co", "var", "f|o");
        checkCapture("{var:.*}", "x\ny", "var", "x\ny");
    }
}

@("PathPatternTests.VariableCaptureTests.encodingAndBoundVariablesCaptureTheRestPathElement")
unittest
{
    checkCapture("/{*var}", "/f%20o", "var", "/f o");
    checkCapture("{var1}/{*var2}", "f%20o/f%7Co", "var1", "f o", "var2", "/f|o");
    checkCapture("/{*var}", "/foo", "var", "/foo");
    checkCapture("/{*var}", "/f%20o", "var", "/f o");
    checkCapture("/{*var}", "/f%20o", "var", "/f o");
    checkCapture("/{*var}", "/f%7co", "var", "/f|o");
}

version (FlintPathPatternPartialSegments)
{
    @("PathPatternTests.VariableCaptureTests.encodingAndBoundVariablesRegexPathElement")
    unittest
    {
        checkCapture("/{var1:f o}_ _{var2}", "/f%20o_%20_f%7co", "var1", "f o", "var2", "f|o");
        checkCapture("/{var1}_{var2}", "/f%20o_foo", "var1", "f o", "var2", "foo");
        checkCapture("/{var1}_ _{var2}", "/f%20o_%20_f%7co", "var1", "f o", "var2", "f|o");
        checkCapture("/{var1}_ _{var2:f\\|o}", "/f%20o_%20_f%7co", "var1", "f o", "var2", "f|o");
        checkCapture("/{var1:f o}_ _{var2:f\\|o}", "/f%20o_%20_f%7co", "var1", "f o", "var2", "f|o");
        checkCapture("/{var1:f o}_ _{var2:f\\|o}", "/f%20o_%20_f%7co", "var1", "f o", "var2", "f|o");
        checkCapture("/{var1}_{var2}", "/f\noo_foo", "var1", "f\noo", "var2", "foo");
    }
}

// PathPatternTests

// The public PathContainer (org.springframework.http.server: elements(), value(), Options) is not ported; the
// matcher's internal one keeps only decoded segment values.
version (FlintPathPatternPathContainer)
{
    import flint.http.server : PathContainer;

    private PathContainer toPathContainer(string path)
    {
        if (path is null)
            return null;
        return PathContainer.parsePath(path);
    }

    private string elementsToString(E)(E[] elements)
    {
        string s;
        foreach (element; elements)
            s ~= "[" ~ element.value() ~ "]";
        return s;
    }

    @("PathPatternTests.pathContainer")
    unittest
    {
        assert(elementsToString(toPathContainer("/abc/def").elements()) == "[/][abc][/][def]");
        assert(elementsToString(toPathContainer("abc/def").elements()) == "[abc][/][def]");
        assert(elementsToString(toPathContainer("abc/def/").elements()) == "[abc][/][def][/]");
        assert(elementsToString(toPathContainer("abc//def//").elements()) == "[abc][/][/][def][/][/]");
        assert(elementsToString(toPathContainer("/").elements()) == "[/]");
        assert(elementsToString(toPathContainer("///").elements()) == "[/][/][/]");
    }
}

version (FlintPathPatternPartialSegments)
{
    @("PathPatternTests.hasPatternSyntax")
    unittest
    {
        const parser = new PathPatternParser();
        assert(parser.parse("/foo/*").hasPatternSyntax());
        assert(parser.parse("/foo/**").hasPatternSyntax());
        assert(parser.parse("/foo/{*elem}").hasPatternSyntax());
        assert(parser.parse("/f?o").hasPatternSyntax());
        assert(parser.parse("/f*").hasPatternSyntax());
        assert(parser.parse("/foo/{bar}/baz").hasPatternSyntax());
        assert(!parser.parse("/foo/bar").hasPatternSyntax());
    }
}

// PathPattern.matchStartOfPath and PathRemainingMatchInfo (SPR-15336, SPR-15149) are not ported.
version (FlintPathPatternMatchStartOfPath)
{
    private auto getPathRemaining(string pattern, string path)
    {
        return parse(pattern).matchStartOfPath(path);
    }

    private auto getPathRemaining(const PathPattern pattern, string path)
    {
        return pattern.matchStartOfPath(path);
    }

    @("PathPatternTests.pathRemainderBasicCases")  // SPR-15336
    unittest
    {
        // Cover all PathElement kinds
        assert(getPathRemaining("/foo", "/foo/bar").getPathRemaining().value() == "/bar");
        assert(getPathRemaining("/foo", "/foo/").getPathRemaining().value() == "/");
        assert(getPathRemaining("/foo*", "/foo/bar").getPathRemaining().value() == "/bar");
        assert(getPathRemaining("/*", "/foo/bar").getPathRemaining().value() == "/bar");
        assert(getPathRemaining("/{foo}", "/foo/bar").getPathRemaining().value() == "/bar");
        assert(getPathRemaining("/foo", "/bar/baz") is null);
        assert(getPathRemaining("/**", "/foo/bar").getPathRemaining().value().length == 0);
        assert(getPathRemaining("/{*bar}", "/foo/bar").getPathRemaining().value().length == 0);
        assert(getPathRemaining("/a?b/d?e", "/aab/dde/bar").getPathRemaining().value() == "/bar");
        assert(getPathRemaining("/{abc}abc", "/xyzabc/bar").getPathRemaining().value() == "/bar");
        assert(getPathRemaining("/*y*", "/xyzxyz/bar").getPathRemaining().value() == "/bar");
        assert(getPathRemaining("/", "/").getPathRemaining().value().length == 0);
        assert(getPathRemaining("/", "/a").getPathRemaining().value() == "a");
        assert(getPathRemaining("/", "/a/").getPathRemaining().value() == "a/");
        assert(getPathRemaining("/a{abc}", "/a/bar").getPathRemaining().value() == "/bar");
        assert(getPathRemaining("/foo//", "/foo///bar").getPathRemaining().value() == "/bar");
    }

    @("PathPatternTests.pathRemainingCornerCases")  // SPR-15336
    unittest
    {
        // No match when the literal path element is a longer form of the segment in the pattern
        assert(parse("/foo").matchStartOfPath("/footastic/bar") is null);
        assert(parse("/f?o").matchStartOfPath("/footastic/bar") is null);
        assert(parse("/f*o*p").matchStartOfPath("/flooptastic/bar") is null);
        assert(parse("/{abc}abc").matchStartOfPath("/xyzabcbar/bar") is null);

        // With a /** on the end have to check if there is any more data post
        // 'the match' it starts with a separator
        assert(parse("/resource/**").matchStartOfPath("/resourceX") is null);
        assert(parse("/resource/**").matchStartOfPath("/resource").getPathRemaining().value().length == 0);

        assert(parse("/**/resource").matchStartOfPath("/test/resource").getPathRemaining().value().length == 0);
        assert(parse("/**/resource").matchStartOfPath("/test/resource/other").getPathRemaining().value() == "/other");

        // Similar to above for the capture-the-rest variant
        assert(parse("/resource/{*foo}").matchStartOfPath("/resourceX") is null);
        assert(parse("/resource/{*foo}").matchStartOfPath("/resource").getPathRemaining().value().length == 0);

        auto pri = parse("/aaa/{bbb}/c?d/e*f/*/g").matchStartOfPath("/aaa/b/ccd/ef/x/g/i");
        assert(pri !is null);
        assert(pri.getPathRemaining().value() == "/i");
        assert(containsEntry(pri, "bbb", "b"));

        pri = parse("/aaa/{bbb}/c?d/e*f/*/g/").matchStartOfPath("/aaa/b/ccd/ef/x/g/i");
        assert(pri !is null);
        assert(pri.getPathRemaining().value() == "i");
        assert(containsEntry(pri, "bbb", "b"));

        pri = parse("/{aaa}_{bbb}/e*f/{x}/g").matchStartOfPath("/aa_bb/ef/x/g/i");
        assert(pri !is null);
        assert(pri.getPathRemaining().value() == "/i");
        assert(containsEntry(pri, "aaa", "aa"));
        assert(containsEntry(pri, "bbb", "bb"));
        assert(containsEntry(pri, "x", "x"));

        assert(parse("/a/b").matchStartOfPath("") is null);
        assert(parse("").matchStartOfPath("/a/b").getPathRemaining().value() == "/a/b");
        assert(parse("").matchStartOfPath("").getPathRemaining().value().length == 0);
    }

    @("PathPatternTests.pathRemainingEnhancements")  // SPR-15149
    unittest
    {
        PathPattern pp;
        // It would be nice to partially match a path and get any bound variables in one step
        pp = parse("/{this}/{one}/{here}");
        auto pri = getPathRemaining(pp, "/foo/bar/goo/boo");
        assert(pri.getPathRemaining().value() == "/boo");
        assert(pri.getPathMatched().value() == "/foo/bar/goo");
        assert(containsEntry(pri, "this", "foo"));
        assert(containsEntry(pri, "one", "bar"));
        assert(containsEntry(pri, "here", "goo"));

        pp = parse("/aaa/{foo}");
        pri = getPathRemaining(pp, "/aaa/bbb");
        assert(pri.getPathRemaining().value().length == 0);
        assert(pri.getPathMatched().value() == "/aaa/bbb");
        assert(containsEntry(pri, "foo", "bbb"));

        pp = parse("/aaa/bbb");
        pri = getPathRemaining(pp, "/aaa/bbb");
        assert(pri.getPathRemaining().value().length == 0);
        assert(pri.getPathMatched().value() == "/aaa/bbb");
        assert(pri.getUriVariables().length == 0);

        pp = parse("/*/{foo}/b*");
        pri = getPathRemaining(pp, "/foo");
        assert(pri is null);
        pri = getPathRemaining(pp, "/abc/def/bhi");
        assert(pri.getPathRemaining().value().length == 0);
        assert(containsEntry(pri, "foo", "def"));

        pri = getPathRemaining(pp, "/abc/def/bhi/jkl");
        assert(pri.getPathRemaining().value() == "/jkl");
        assert(containsEntry(pri, "foo", "def"));
    }
}

// PathPatternParser.setCaseSensitive is not ported; matching is always case-sensitive.
version (FlintPathPatternCaseSensitivity)
{
    @("PathPatternTests.caseSensitivity")
    unittest
    {
        auto pp = new PathPatternParser();
        pp.setCaseSensitive(false);
        auto p = pp.parse("abc");
        assertMatches(p, "AbC");
        assertNoMatch(p, "def");
        p = pp.parse("fOo");
        assertMatches(p, "FoO");
        p = pp.parse("/fOo/bAr");
        assertMatches(p, "/FoO/BaR");

        pp = new PathPatternParser();
        pp.setCaseSensitive(true);
        p = pp.parse("abc");
        assertNoMatch(p, "AbC");
        p = pp.parse("fOo");
        assertNoMatch(p, "FoO");
        p = pp.parse("/fOo/bAr");
        assertNoMatch(p, "/FoO/BaR");
        p = pp.parse("/fOO/bAr");
        assertMatches(p, "/fOO/bAr");

        pp = new PathPatternParser();
        pp.setCaseSensitive(false);
        p = pp.parse("{foo:[A-Z]*}");
        assertMatches(p, "abc");
        assertMatches(p, "ABC");

        pp = new PathPatternParser();
        pp.setCaseSensitive(true);
        p = pp.parse("{foo:[A-Z]*}");
        assertNoMatch(p, "abc");
        assertMatches(p, "ABC");

        pp = new PathPatternParser();
        pp.setCaseSensitive(false);
        p = pp.parse("ab?");
        assertMatches(p, "AbC");
        p = pp.parse("fO?");
        assertMatches(p, "FoO");
        p = pp.parse("/fO?/bA?");
        assertMatches(p, "/FoO/BaR");
        assertNoMatch(p, "/bAr/fOo");

        pp = new PathPatternParser();
        pp.setCaseSensitive(true);
        p = pp.parse("ab?");
        assertNoMatch(p, "AbC");
        p = pp.parse("fO?");
        assertNoMatch(p, "FoO");
        p = pp.parse("/fO?/bA?");
        assertNoMatch(p, "/FoO/BaR");
        p = pp.parse("/fO?/bA?");
        assertMatches(p, "/fOO/bAr");

        pp = new PathPatternParser();
        pp.setCaseSensitive(false);
        p = pp.parse("{abc:[A-Z]*}_{def:[A-Z]*}");
        assertMatches(p, "abc_abc");
        assertMatches(p, "ABC_aBc");

        pp = new PathPatternParser();
        pp.setCaseSensitive(true);
        p = pp.parse("{abc:[A-Z]*}_{def:[A-Z]*}");
        assertNoMatch(p, "abc_abc");
        assertMatches(p, "ABC_ABC");

        pp = new PathPatternParser();
        pp.setCaseSensitive(false);
        p = pp.parse("*?a?*");
        assertMatches(p, "bab");
        assertMatches(p, "bAb");

        pp = new PathPatternParser();
        pp.setCaseSensitive(true);
        p = pp.parse("*?A?*");
        assertNoMatch(p, "bab");
        assertMatches(p, "bAb");
    }
}

// PathPattern.extractPathWithinPattern (SPR-15259) is not ported.
version (FlintPathPatternExtractWithin)
{
    private void checkExtractPathWithinPattern(string pattern, string path, string expected)
    {
        const ppp = new PathPatternParser();
        const pp = ppp.parse(pattern);
        const s = pp.extractPathWithinPattern(path).value();
        assert(s == expected);
    }

    @("PathPatternTests.extractPathWithinPatternWildards")  // SPR-15259
    unittest
    {
        checkExtractPathWithinPattern("/**", "//", "");
        checkExtractPathWithinPattern("/**", "/", "");
        checkExtractPathWithinPattern("/**", "", "");
        checkExtractPathWithinPattern("/**", "/foobar", "foobar");
    }

    @("PathPatternTests.extractPathWithinPattern")
    unittest
    {
        checkExtractPathWithinPattern("/welcome*/", "/welcome/", "welcome");
        checkExtractPathWithinPattern("/docs/commit.html", "/docs/commit.html", "");
        checkExtractPathWithinPattern("/docs/*", "/docs/cvs/commit", "cvs/commit");
        checkExtractPathWithinPattern("/docs/cvs/*.html", "/docs/cvs/commit.html", "commit.html");
        checkExtractPathWithinPattern("/docs/cvs/file.*.html", "/docs/cvs/file.sha.html", "file.sha.html");
        checkExtractPathWithinPattern("/docs/**", "/docs/cvs/commit", "cvs/commit");
        checkExtractPathWithinPattern("/doo/{*foobar}", "/doo/customer.html", "customer.html");
        checkExtractPathWithinPattern("/doo/{*foobar}", "/doo/daa/customer.html", "daa/customer.html");
        checkExtractPathWithinPattern("/*.html", "/commit.html", "commit.html");
        checkExtractPathWithinPattern("/docs/*/*/*/*", "/docs/cvs/other/commit.html", "cvs/other/commit.html");
        checkExtractPathWithinPattern("/d?cs/**", "/docs/cvs/commit", "docs/cvs/commit");
        checkExtractPathWithinPattern("/*/**", "/docs/cvs/commit///", "docs/cvs/commit");
        checkExtractPathWithinPattern("/*/**", "/docs/cvs/commit/", "docs/cvs/commit");
        checkExtractPathWithinPattern("/aaa/bbb/**", "/aaa///", "");
        checkExtractPathWithinPattern("/aaa/bbb/**", "/aaa//", "");
        checkExtractPathWithinPattern("/aaa/bbb/**", "/aaa/", "");
        checkExtractPathWithinPattern("/docs/**", "/docs/cvs/commit///", "cvs/commit");
        checkExtractPathWithinPattern("/docs/**", "/docs/cvs/commit/", "cvs/commit");
        checkExtractPathWithinPattern("/docs/c?s/*.html", "/docs/cvs/commit.html", "cvs/commit.html");
        checkExtractPathWithinPattern("/d?cs/*/*.html", "/docs/cvs/commit.html", "docs/cvs/commit.html");
        checkExtractPathWithinPattern("/a/b/c*d*/*.html", "/a/b/cod/foo.html", "cod/foo.html");
        checkExtractPathWithinPattern("a/{foo}/b/{bar}", "a/c/b/d", "c/b/d");
        checkExtractPathWithinPattern("a/{foo}_{bar}/d/e", "a/b_c/d/e", "b_c/d/e");
        checkExtractPathWithinPattern("aaa//*///ccc///ddd", "aaa//bbb///ccc///ddd", "bbb/ccc/ddd");
        checkExtractPathWithinPattern("aaa//*///ccc///ddd", "aaa//bbb//ccc/ddd", "bbb/ccc/ddd");
        checkExtractPathWithinPattern("aaa/c*/ddd/", "aaa/ccc///ddd///", "ccc/ddd");
        checkExtractPathWithinPattern("", "", "");
        checkExtractPathWithinPattern("/", "", "");
        checkExtractPathWithinPattern("", "/", "");
        checkExtractPathWithinPattern("//", "", "");
        checkExtractPathWithinPattern("", "//", "");
        checkExtractPathWithinPattern("//", "//", "");
        checkExtractPathWithinPattern("//", "/", "");
        checkExtractPathWithinPattern("/", "//", "");
    }
}

version (FlintPathPatternPathContainer)
{
    @("PathPatternTests.extractPathWithinPatternCustomSeparator")
    unittest
    {
        auto ppp = new PathPatternParser();
        ppp.setPathOptions(PathContainer.Options.create('.', true));
        const pp = ppp.parse("test.**");
        auto pathContainer = PathContainer.parsePath("test.projects..spring-framework",
                PathContainer.Options.create('.', true));
        auto result = pp.extractPathWithinPattern(pathContainer);
        assert(result.value() == "projects.spring-framework");
        assert(result.elements().length == 3);
    }
}

version (FlintPathPatternPartialSegments)
{
    @("PathPatternTests.extractUriTemplateVariables")  // SPR-15264
    unittest
    {
        import flint.util : AntPathMatcher;

        PathPattern pp;
        pp = new PathPatternParser().parse("/{foo}");
        assertMatches(pp, "/abc");
        assertNoMatch(pp, "/");
        assertNoMatch(pp, "//");
        checkCapture("/{foo}", "/abc", "foo", "abc");

        pp = new PathPatternParser().parse("/{foo}/{bar}");
        assertMatches(pp, "/abc/def");
        assertNoMatch(pp, "/def");
        assertNoMatch(pp, "/");
        assertNoMatch(pp, "//def");
        assertNoMatch(pp, "//");

        pp = parse("/{foo}/boo");
        assertMatches(pp, "/abc/boo");
        assertMatches(pp, "/a/boo");
        assertNoMatch(pp, "/boo");
        assertNoMatch(pp, "//boo");

        pp = parse("/{foo}*");
        assertMatches(pp, "/abc");
        assertNoMatch(pp, "/");

        checkCapture("/{word:[a-z]*}", "/abc", "word", "abc");
        pp = parse("/{word:[a-z]*}");
        assertNoMatch(pp, "/1");
        assertMatches(pp, "/a");
        assertNoMatch(pp, "/");

        // Two captures mean we use a RegexPathElement
        pp = new PathPatternParser().parse("/{foo}{bar}");
        assertMatches(pp, "/abcdef");
        assertNoMatch(pp, "/");
        assertNoMatch(pp, "//");
        checkCapture("/{foo:[a-z][a-z]}{bar:[a-z]}", "/abc", "foo", "ab", "bar", "c");

        // Only patterns not capturing variables cannot match against just /
        const ppp = new PathPatternParser();
        pp = ppp.parse("/****");
        assertMatches(pp, "/abcdef");
        assertMatches(pp, "/");
        assertMatches(pp, "/");
        assertMatches(pp, "//");

        // Confirming AntPathMatcher behavior:
        assert(!new AntPathMatcher().match("/{foo}", "/"));
        assert(new AntPathMatcher().match("/{foo}", "/a"));
        assert(new AntPathMatcher().match("/{foo}{bar}", "/a"));
        assert(!new AntPathMatcher().match("/{foo}*", "/"));
        assert(new AntPathMatcher().match("/*", "/"));
        assert(!new AntPathMatcher().match("/*{foo}", "/"));
        auto vars = new AntPathMatcher().extractUriTemplateVariables("/{foo}{bar}", "/a");
        assert(vars.get("foo") == "a");
        assert(vars.get("bar").length == 0);

        assertMatches(parse("{hotel}"), "1");
        assertMatches(parse("/hotels/{hotel}"), "/hotels/1");
        checkCapture("/hotels/{hotel}", "/hotels/1", "hotel", "1");
        checkCapture("/h?tels/{hotel}", "/hotels/1", "hotel", "1");
        checkCapture("/hotels/{hotel}/bookings/{booking}", "/hotels/1/bookings/2", "hotel", "1", "booking", "2");
        checkCapture("/*/hotels/*/{hotel}", "/foo/hotels/bar/1", "hotel", "1");
        checkCapture("/{page}.html", "/42.html", "page", "42");
        checkNoMatch("/{var}", "/");
        checkCapture("/{page}.*", "/42.html", "page", "42");
        checkCapture("/A-{B}-C", "/A-b-C", "B", "b");
        checkCapture("/{name}.{extension}", "/test.html", "name", "test", "extension", "html");

        assert(checkCapture("/{one}/", "//") is null);
        assert(checkCapture("", "/abc") is null);

        assert(checkCapture("", "").getUriVariables().length == 0);
        checkCapture("{id}", "99", "id", "99");
        checkCapture("/customer/{customerId}", "/customer/78", "customerId", "78");
        checkCapture("/customer/{customerId}/banana", "/customer/42/banana", "customerId", "42");
        checkCapture("{id}/{id2}", "99/98", "id", "99", "id2", "98");
        checkCapture("/foo/{bar}/boo/{baz}", "/foo/plum/boo/apple", "bar", "plum", "baz", "apple");
        checkCapture("/{bla}.*", "/testing.html", "bla", "testing");
        const extracted = checkCapture("/abc", "/abc");
        assert(extracted.getUriVariables().length == 0);
        checkCapture("/{bla}/foo", "/a/foo");
    }
}

version (FlintPathPatternRegexCaptures)
{
    @("PathPatternTests.extractUriTemplateVariablesRegex")
    unittest
    {
        const pp = new PathPatternParser();
        PathPattern p = null;

        p = pp.parse("{symbolicName:[\\w\\.]+}-{version:[\\w\\.]+}.jar");
        auto result = matchAndExtract(p, "com.example-1.0.0.jar");
        assert(containsEntry(result, "symbolicName", "com.example"));
        assert(containsEntry(result, "version", "1.0.0"));

        p = pp.parse("{symbolicName:[\\w\\.]+}-sources-{version:[\\w\\.]+}.jar");
        result = matchAndExtract(p, "com.example-sources-1.0.0.jar");
        assert(containsEntry(result, "symbolicName", "com.example"));
        assert(containsEntry(result, "version", "1.0.0"));
    }

    @("PathPatternTests.extractUriTemplateVarsRegexQualifiers")
    unittest
    {
        const pp = new PathPatternParser();

        auto p = pp.parse("{symbolicName:[\\p{L}\\.]+}-sources-{version:[\\p{N}\\.]+}.jar");
        auto result = p.matchAndExtract("com.example-sources-1.0.0.jar");
        assert(containsEntry(result, "symbolicName", "com.example"));
        assert(containsEntry(result, "version", "1.0.0"));

        enum dated = "{symbolicName:[\\w\\.]+}-sources-{version:[\\d\\.]+}-"
            ~ "{year:\\d{4}}{month:\\d{2}}{day:\\d{2}}.jar";
        p = pp.parse(dated);
        result = matchAndExtract(p, "com.example-sources-1.0.0-20100220.jar");
        assert(containsEntry(result, "symbolicName", "com.example"));
        assert(containsEntry(result, "version", "1.0.0"));
        assert(containsEntry(result, "year", "2010"));
        assert(containsEntry(result, "month", "02"));
        assert(containsEntry(result, "day", "20"));

        p = pp.parse("{symbolicName:[\\p{L}\\.]+}-sources-{version:[\\p{N}\\.\\{\\}]+}.jar");
        result = matchAndExtract(p, "com.example-sources-1.0.0.{12}.jar");
        assert(containsEntry(result, "symbolicName", "com.example"));
        assert(containsEntry(result, "version", "1.0.0.{12}"));
    }

    @("PathPatternTests.extractUriTemplateVarsRegexCapturingGroups")
    unittest
    {
        import std.algorithm.searching : canFind;

        const ppp = new PathPatternParser();
        const pathPattern = ppp.parse("/web/{id:foo(bar)?}_{goo}");
        const message = thrownMessage!IllegalArgumentException(() {
            matchAndExtract(pathPattern, "/web/foobar_goo");
        });
        assert(message !is null);
        assert(message.canFind("The number of capturing groups in the pattern"));
    }

    @("PathPatternTests.captureVariableRegexWithTooManyCharacterAccessAttempts")
    unittest
    {
        import std.array : replicate;

        const pathPattern = new PathPatternParser().parse("/{x:(?:.*a){12}b}");
        assert(pathPattern.toChainString() == "Separator(/) CaptureVariable({x:(?:.*a){12}b})");
        assert(pathPattern.matches("/" ~ "a".replicate(28) ~ "b"));
        assert(thrownMessage!IllegalStateException(() {
                pathPattern.matches("/" ~ "a".replicate(28) ~ "c");
            }) == "Too many character access attempts encountered during pattern matching");
    }

    @("PathPatternTests.regexWithTooManyCharacterAccessAttempts")
    unittest
    {
        import std.array : replicate;

        const pathPattern = new PathPatternParser().parse("/{x:(?:.*a){12}b}*");
        assert(pathPattern.toChainString() == "Separator(/) Regex({x:(?:.*a){12}b}*)");
        assert(pathPattern.matches("/" ~ "a".replicate(28) ~ "b"));
        assert(thrownMessage!IllegalStateException(() {
                pathPattern.matches("/" ~ "a".replicate(28) ~ "c");
            }) == "Too many character access attempts encountered during pattern matching");
    }
}

@("PathPatternTests.combineEmptyPatternsShouldReturnEmpty")
unittest
{
    auto pathMatcher = new TestPathCombiner();
    assert(pathMatcher.combine("", "").length == 0);
}

@("PathPatternTests.combineWithEmptyPatternShouldReturnPattern")
unittest
{
    auto pathMatcher = new TestPathCombiner();
    assert(pathMatcher.combine("/hotels", "") == "/hotels");
    assert(pathMatcher.combine("", "/hotels") == "/hotels");
}

@("PathPatternTests.combineStaticPatternsShouldConcatenate")
unittest
{
    auto pathMatcher = new TestPathCombiner();
    assert(pathMatcher.combine("/hotels", "/booking") == "/hotels/booking");
    assert(pathMatcher.combine("/hotels", "booking") == "/hotels/booking");
    assert(pathMatcher.combine("/hotels/", "booking") == "/hotels/booking");
    // SPR-10062
    assert(pathMatcher.combine("/1.0", "/foo/test") == "/1.0/foo/test");
    // SPR-10554
    // SPR-12975
    assert(pathMatcher.combine("/", "/hotel") == "/hotel");
    // SPR-12975
    assert(pathMatcher.combine("/hotel/", "/booking") == "/hotel/booking");
    assert(pathMatcher.combine("", "/hotel") == "/hotel");
    assert(pathMatcher.combine("/hotel", "") == "/hotel");
    // SPR-7970
    assert(pathMatcher.combine("/user", "/user") == "/user/user");
}

version (FlintPathPatternPartialSegments)
{
    @("PathPatternTests.combineStaticWithMatchingShouldConcatenate")
    unittest
    {
        auto pathMatcher = new TestPathCombiner();
        assert(pathMatcher.combine("/hotels", "*") == "/hotels/*");
        assert(pathMatcher.combine("/hotels", "{hotel}") == "/hotels/{hotel}");
        assert(pathMatcher.combine("/hotels", "{hotel}.*") == "/hotels/{hotel}.*");
    }

    @("PathPatternTests.combineMatchingWithStaticShouldMergeWhenWildcardMatch")
    unittest
    {
        auto pathMatcher = new TestPathCombiner();
        assert(pathMatcher.combine("/hotels/*", "booking") == "/hotels/booking");
        assert(pathMatcher.combine("/hotels/*", "/booking") == "/hotels/booking");
        assert(pathMatcher.combine("/hotels/**", "/booking/rooms") == "/hotels/booking/rooms");
        assert(pathMatcher.combine("/*.html", "/hotel.html") == "/hotel.html");
        assert(pathMatcher.combine("/*.html", "/hotel") == "/hotel.html");
        // gh-34986
        assert(pathMatcher.combine("/*", "/foo/bar") == "/foo/bar");
        assert(pathMatcher.combine("/*", "foo/bar") == "/foo/bar");
    }
}

version (FlintPathPatternRegexCaptures)
{
    @("PathPatternTests.combineMatchingWithStaticShouldConcatenateWhenNoWildcardMatch")
    unittest
    {
        auto pathMatcher = new TestPathCombiner();
        // SPR-10062
        assert(pathMatcher.combine("/{foo:.*[^0-9].*}", "/edit/") == "/{foo:.*[^0-9].*}/edit/");
        // SPR-8858
        assert(pathMatcher.combine("/{foo}", "/bar") == "/{foo}/bar");
    }
}

version (FlintPathPatternPartialSegments)
{
    @("PathPatternTests.combineMatchingPatternsShouldMergeWhenMatch")
    unittest
    {
        auto pathMatcher = new TestPathCombiner();
        assert(pathMatcher.combine("/hotels/*/booking", "{booking}") == "/hotels/*/booking/{booking}");
        assert(pathMatcher.combine("/hotels/*", "{hotel}") == "/hotels/{hotel}");
        assert(pathMatcher.combine("/*.html", "/hotel.*") == "/hotel.html");
        assert(pathMatcher.combine("/**", "/*.html") == "/*.html");
        assert(pathMatcher.combine("/*", "/*.html") == "/*.html");
        assert(pathMatcher.combine("/*.*", "/*.html") == "/*.html");
    }

    @("PathPatternTests.combineMatchingPatternsShouldFailWhenNoMatch")
    unittest
    {
        auto pathMatcher = new TestPathCombiner();
        pathMatcher.combineFails("/*.html", "/*.txt");
        pathMatcher.combineFails("/a/b/c/*.html", "/d/e/f/hotel.*");
    }
}

@("PathPatternTests.patternComparator")
unittest
{
    const comparator = &PathPattern.compareSpecificity;

    assert(comparator(parse("/hotels/new"), parse("/hotels/new")) == 0);

    assert(comparator(parse("/hotels/new"), parse("/hotels/*")) == -1);
    assert(comparator(parse("/hotels/*"), parse("/hotels/new")) == 1);
    assert(comparator(parse("/hotels/*"), parse("/hotels/*")) == 0);

    assert(comparator(parse("/hotels/new"), parse("/hotels/{hotel}")) == -1);
    assert(comparator(parse("/hotels/{hotel}"), parse("/hotels/new")) == 1);
    assert(comparator(parse("/hotels/{hotel}"), parse("/hotels/{hotel}")) == 0);
    assert(comparator(parse("/hotels/{hotel}/booking"), parse("/hotels/{hotel}/bookings/{booking}")) == -1);
    assert(comparator(parse("/hotels/{hotel}/bookings/{booking}"), parse("/hotels/{hotel}/booking")) == 1);

    assert(comparator(parse("/hotels/{hotel}/bookings/{booking}/customers/{customer}"), parse("/**")) == -1);
    assert(comparator(parse("/**"), parse("/hotels/{hotel}/bookings/{booking}/customers/{customer}")) == 1);
    assert(comparator(parse("/**"), parse("/**")) == 0);

    assert(comparator(parse("/hotels/{hotel}"), parse("/hotels/*")) == -1);
    assert(comparator(parse("/hotels/*"), parse("/hotels/{hotel}")) == 1);

    assert(comparator(parse("/hotels/*"), parse("/hotels/*/**")) == -1);
    assert(comparator(parse("/hotels/*/**"), parse("/hotels/*")) == 1);

    // TODO: shouldn't the wildcard lower the score?
    //		assertEquals(-1,
    //				comparator.compare(parse("/hotels/new"), parse("/hotels/new.*")));

    // SPR-6741
    assert(comparator(parse("/hotels/{hotel}/bookings/{booking}/customers/{customer}"), parse("/hotels/**")) == -1);
    assert(comparator(parse("/hotels/**"), parse("/hotels/{hotel}/bookings/{booking}/customers/{customer}")) == 1);
    assert(comparator(parse("/hotels/foo/bar/**"), parse("/hotels/{hotel}")) == 1);
    assert(comparator(parse("/hotels/{hotel}"), parse("/hotels/foo/bar/**")) == -1);

    // SPR-8683
    assert(comparator(parse("/**"), parse("/hotels/{hotel}")) == 1);

    // longer is better
    assert(comparator(parse("/hotels"), parse("/hotels2")) == 1);

    // SPR-13139
    assert(comparator(parse("*"), parse("*/**")) == -1);
    assert(comparator(parse("*/**"), parse("*")) == 1);
}

version (FlintPathPatternPartialSegments)
{
    @("PathPatternTests.compare_spr15597")
    unittest
    {
        const parser = new PathPatternParser();
        const p1 = parser.parse("/{foo}");
        const p2 = parser.parse("/{foo}.*");
        const r1 = matchAndExtract(p1, "/file.txt");
        const r2 = matchAndExtract(p2, "/file.txt");

        // works fine
        assert(containsEntry(r1, "foo", "file.txt"));
        assert(containsEntry(r2, "foo", "file"));

        // This produces 2 (see comments in https://jira.spring.io/browse/SPR-14544 )
        // Comparator<String> patternComparator = new AntPathMatcher().getPatternComparator("");
        // System.out.println(patternComparator.compare("/{foo}","/{foo}.*"));

        assert(p1.compareTo(p2) > 0);
    }
}

@("PathPatternTests.patternCompareWithNull")
unittest
{
    assert(PathPattern.compareSpecificity(null, null) == 0);
    assert(PathPattern.compareSpecificity(parse("/abc"), null) < 0);
    assert(PathPattern.compareSpecificity(null, parse("/abc")) > 0);
}

version (FlintPathPatternPartialSegments)
{
    @("PathPatternTests.patternComparatorSort")
    unittest
    {
        import std.algorithm.comparison : cmp;
        import std.algorithm.mutation : SwapStrategy;
        import std.algorithm.sorting : sort;
        import std.random : randomShuffle;

        int delegate(const PathPattern, const PathPattern) @safe comparator = (p1, p2) => PathPattern
            .compareSpecificity(p1, p2);
        // List.sort is a stable sort.
        void sortPaths(ref PathPattern[] list)
        {
            list.sort!((a, b) => comparator(a, b) < 0, SwapStrategy.stable);
        }

        PathPattern[] paths;
        const pp = new PathPatternParser();
        paths ~= null;
        paths ~= null;
        sortPaths(paths);
        assert(paths[0] is null);
        assert(paths[1] is null);
        paths = null;

        paths ~= null;
        paths ~= pp.parse("/hotels/new");
        sortPaths(paths);
        assert(paths[0].getPatternString() == "/hotels/new");
        assert(paths[1] is null);
        paths = null;

        paths ~= pp.parse("/hotels/*");
        paths ~= pp.parse("/hotels/new");
        sortPaths(paths);
        assert(paths[0].getPatternString() == "/hotels/new");
        assert(paths[1].getPatternString() == "/hotels/*");
        paths = null;

        paths ~= pp.parse("/hotels/new");
        paths ~= pp.parse("/hotels/*");
        sortPaths(paths);
        assert(paths[0].getPatternString() == "/hotels/new");
        assert(paths[1].getPatternString() == "/hotels/*");
        paths = null;

        paths ~= pp.parse("/hotels/**");
        paths ~= pp.parse("/hotels/*");
        sortPaths(paths);
        assert(paths[0].getPatternString() == "/hotels/*");
        assert(paths[1].getPatternString() == "/hotels/**");
        paths = null;

        paths ~= pp.parse("/hotels/*");
        paths ~= pp.parse("/hotels/**");
        sortPaths(paths);
        assert(paths[0].getPatternString() == "/hotels/*");
        assert(paths[1].getPatternString() == "/hotels/**");
        paths = null;

        paths ~= pp.parse("/hotels/{hotel}");
        paths ~= pp.parse("/hotels/new");
        sortPaths(paths);
        assert(paths[0].getPatternString() == "/hotels/new");
        assert(paths[1].getPatternString() == "/hotels/{hotel}");
        paths = null;

        paths ~= pp.parse("/hotels/new");
        paths ~= pp.parse("/hotels/{hotel}");
        sortPaths(paths);
        assert(paths[0].getPatternString() == "/hotels/new");
        assert(paths[1].getPatternString() == "/hotels/{hotel}");
        paths = null;

        paths ~= pp.parse("/hotels/*");
        paths ~= pp.parse("/hotels/{hotel}");
        paths ~= pp.parse("/hotels/new");
        sortPaths(paths);
        assert(paths[0].getPatternString() == "/hotels/new");
        assert(paths[1].getPatternString() == "/hotels/{hotel}");
        assert(paths[2].getPatternString() == "/hotels/*");
        paths = null;

        paths ~= pp.parse("/hotels/ne*");
        paths ~= pp.parse("/hotels/n*");
        paths.randomShuffle();
        sortPaths(paths);
        assert(paths[0].getPatternString() == "/hotels/ne*");
        assert(paths[1].getPatternString() == "/hotels/n*");
        paths = null;

        // comparator = new PatternComparatorConsideringPath("/hotels/new.html");
        // paths.add(pp.parse("/hotels/new.*"));
        // paths.add(pp.parse("/hotels/{hotel}"));
        // Collections.shuffle(paths);
        // Collections.sort(paths, comparator);
        // assertEquals("/hotels/new.*", paths.get(0).toPatternString());
        // assertEquals("/hotels/{hotel}", paths.get(1).toPatternString());
        // paths.clear();

        comparator = (p1, p2) {
            const index = p1.compareTo(p2);
            return index != 0 ? index : cmp(p1.getPatternString(), p2.getPatternString());
        };
        paths ~= pp.parse("/*/login.*");
        paths ~= pp.parse("/*/endUser/action/login.*");
        sortPaths(paths);
        assert(paths[0].getPatternString() == "/*/endUser/action/login.*");
        assert(paths[1].getPatternString() == "/*/login.*");
        paths = null;
    }
}

version (FlintPathPatternCaseSensitivity)
{
    @("PathPatternTests.caseInsensitive")  // SPR-13286
    unittest
    {
        auto pp = new PathPatternParser();
        pp.setCaseSensitive(false);
        const p = pp.parse("/group/{groupName}/members");
        assertMatches(p, "/group/sales/members");
        assertMatches(p, "/Group/Sales/Members");
        assertMatches(p, "/group/Sales/members");
    }
}

// Matrix variables (PathMatchInfo.getMatrixVariables) are not ported; the matcher drops them from each segment.
version (FlintPathPatternMatrixVariables)
{
    @("PathPatternTests.parameters")
    unittest
    {
        // CaptureVariablePathElement
        auto result = matchAndExtract("/abc/{var}", "/abc/one;two=three;four=five");
        assert(containsEntry(result, "var", "one"));
        assert(result.getMatrixVariables().get("var").getFirst("two") == "three");
        assert(result.getMatrixVariables().get("var").getFirst("four") == "five");
        // RegexPathElement
        result = matchAndExtract("/abc/{var1}_{var2}", "/abc/123_456;a=b;c=d");
        assert(containsEntry(result, "var1", "123"));
        assert(containsEntry(result, "var2", "456"));
        // vars associated with second variable
        assert(!result.getMatrixVariables().containsKey("var1"));
        assert(!result.getMatrixVariables().containsKey("var1"));
        assert(result.getMatrixVariables().get("var2").getFirst("a") == "b");
        assert(result.getMatrixVariables().get("var2").getFirst("c") == "d");
        // CaptureTheRestPathElement
        result = matchAndExtract("/{*var}", "/abc/123_456;a=b;c=d");
        assert(containsEntry(result, "var", "/abc/123_456"));
        assert(result.getMatrixVariables().get("var").getFirst("a") == "b");
        assert(result.getMatrixVariables().get("var").getFirst("c") == "d");
        result = matchAndExtract("/{*var}", "/abc/123_456;a=b;c=d/789;a=e;f=g");
        assert(containsEntry(result, "var", "/abc/123_456/789"));
        assert(result.getMatrixVariables().get("var").get("a").toString() == "[b, e]");
        assert(result.getMatrixVariables().get("var").getFirst("c") == "d");
        assert(result.getMatrixVariables().get("var").getFirst("f") == "g");

        result = matchAndExtract("/abc/{var}", "/abc/one");
        assert(containsEntry(result, "var", "one"));
        assert(!result.getMatrixVariables().containsKey("var"));

        result = matchAndExtract("", "");
        assert(result !is null);
        result = matchAndExtract("", "/");
        assert(result !is null);
    }
}

version (FlintPathPatternRegexCaptures)
{
    @("PathPatternTests.regexPathElementPatterns")
    unittest
    {
        const pp = new PathPatternParser();

        auto pattern = pp.parse("/{var:\\\\}");
        assertMatches(pattern, "/\\");

        pattern = pp.parse("/{var:\\/}");
        assertNoMatch(pattern, "/aaa");

        pattern = pp.parse("/{var:[^\\/]*}");
        auto result = matchAndExtract(pattern, "/foo");
        assert(result.getUriVariable("var") == "foo");

        pattern = pp.parse("/{var:\\[*}");
        result = matchAndExtract(pattern, "/[[[");
        assert(result.getUriVariable("var") == "[[[");

        pattern = pp.parse("/{var:[\\{]*}");
        result = matchAndExtract(pattern, "/{{{");
        assert(result.getUriVariable("var") == "{{{");

        pattern = pp.parse("/{var:[\\}]*}");
        result = matchAndExtract(pattern, "/}}}");
        assert(result.getUriVariable("var") == "}}}");
    }
}

private void assertMatches(const PathPattern pp, string path)
{
    assert(pp.matches(path));
}

private void assertNoMatch(const PathPattern pp, string path)
{
    assert(!pp.matches(path));
}

private PathMatchInfo* matchAndExtract(string pattern, string path)
{
    return parse(pattern).matchAndExtract(path);
}

private PathPattern parse(string path)
{
    const pp = new PathPatternParser();
    return pp.parse(path);
}

private void checkMatches(string uriTemplate, string path)
{
    const parser = new PathPatternParser();
    const p = parser.parse(uriTemplate);
    assert(p.matches(path));
}

private void checkNoMatch(string uriTemplate, string path)
{
    const p = new PathPatternParser();
    const pattern = p.parse(uriTemplate);
    assert(!pattern.matches(path));
}

private PathMatchInfo* checkCapture(string uriTemplate, string path, string[] keyValues...)
{
    const parser = new PathPatternParser();
    const pattern = parser.parse(uriTemplate);
    auto matchResult = pattern.matchAndExtract(path);
    // Java dereferences the result for each expected variable, failing on a null result.
    assert(matchResult !is null || keyValues.length == 0, "no match for " ~ path);
    for (size_t i = 0; i < keyValues.length; i += 2)
    {
        const value = matchResult.getUriVariable(keyValues[i]);
        assert(value == keyValues[i + 1], "value for " ~ keyValues[i]);
    }
    return matchResult;
}

private PathMatchInfo* matchAndExtract(const PathPattern p, string path)
{
    return p.matchAndExtract(path);
}

private final class TestPathCombiner
{
    PathPatternParser pp;

    this()
    {
        pp = new PathPatternParser();
    }

    string combine(string string1, string string2)
    {
        const pattern1 = pp.parse(string1);
        const pattern2 = pp.parse(string2);
        return pattern1.combine(pattern2).getPatternString();
    }

    void combineFails(string string1, string string2)
    {
        const pattern1 = pp.parse(string1);
        const pattern2 = pp.parse(string2);
        assert(throws!IllegalArgumentException(() { pattern1.combine(pattern2); }));
    }
}
