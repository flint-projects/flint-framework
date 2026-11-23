/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/util/pattern/PathPatternParserTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; tests of the
`@Nested` classes keep the nested class name in their label, and the test-instance field `pathPattern` becomes a
local of each test. flint.web's `PathPattern` matches path strings, so `PathContainer.parsePath(path)` becomes the
path itself, `hashCode()` is `toHash()` and `Collections.sort` is a stable sort by `compareTo`. Cases that need
parts of `PathPattern`, `PathPatternParser` and `PatternParseException` flint.web has not ported yet wait behind
the versions named beside them.
+/
module flint.web.util.path_pattern_parser_tests;

import flint.web.util.pattern : PathPattern, PathPatternParser;

@safe:

/// The message of the `E` that `action` throws, or `null` when it throws none.
private string thrownMessage(E : Throwable)(scope void delegate() @safe action)
{
    try
        action();
    catch (E e)
        return e.msg;
    return null;
}

// StructureTests: verify that the parsed pattern matches the text and path elements of the original pattern.

// The parsed element chain (getHeadSection, the PathElement classes, PathElement.next), computePatternString and
// getNormalizedLength are not ported: flint.web keeps one array of segment matchers.
version (FlintPathPatternStructure)
{
    import flint.web.util.pattern : CaptureSegmentsPathElement, CaptureVariablePathElement,
        LiteralPathElement, PathElement, RegexPathElement,
        SeparatorPathElement, SingleCharWildcardedPathElement, WildcardPathElement, WildcardSegmentsPathElement;

    @("PathPatternParserTests.StructureTests.literalPatterns")
    unittest
    {
        checkStructure("/");
        checkStructure("/foo");
        checkStructure("foo");
        checkStructure("foo/");
        checkStructure("/foo/");
        checkStructure("");
    }

    @("PathPatternParserTests.StructureTests.singleCharWildcardPatterns")
    unittest
    {
        auto pathPattern = checkStructure("?");
        assertPathElements!(SingleCharWildcardedPathElement)(pathPattern);
        checkStructure("/?/");
        checkStructure("/?abc?/");
    }

    @("PathPatternParserTests.StructureTests.wildcardSegmentsStartOfPathPatterns")
    unittest
    {
        auto pathPattern = checkStructure("/**/foo");
        assertPathElements!(WildcardSegmentsPathElement, SeparatorPathElement, LiteralPathElement)(pathPattern);
    }

    @("PathPatternParserTests.StructureTests.wildcardSegmentEndOfPathPatterns")
    unittest
    {
        auto pathPattern = checkStructure("/**");
        assertPathElements!(WildcardSegmentsPathElement)(pathPattern);
        pathPattern = checkStructure("/foo/**");
        assertPathElements!(SeparatorPathElement, LiteralPathElement, WildcardSegmentsPathElement)(pathPattern);

    }

    @("PathPatternParserTests.StructureTests.regexpSegmentIsNotWildcardSegment")
    unittest
    {
        auto pathPattern = checkStructure("/**acb");
        assertPathElements!(SeparatorPathElement, RegexPathElement)(pathPattern);

        pathPattern = checkStructure("/a**bc");
        assertPathElements!(SeparatorPathElement, RegexPathElement)(pathPattern);

        pathPattern = checkStructure("/abc**");
        assertPathElements!(SeparatorPathElement, RegexPathElement)(pathPattern);
    }

    @("PathPatternParserTests.StructureTests.partialCapturingPatterns")
    unittest
    {
        auto pathPattern = checkStructure("{foo}abc");
        assertPathElements!(RegexPathElement)(pathPattern);
        checkStructure("abc{foo}");
        checkStructure("/abc{foo}");
        checkStructure("{foo}def/");
        checkStructure("/abc{foo}def/");
        checkStructure("{foo}abc{bar}");
        checkStructure("{foo}abc{bar}/");
        checkStructure("/{foo}abc{bar}/");
    }

    @("PathPatternParserTests.StructureTests.completeCapturingPatterns")
    unittest
    {
        auto pathPattern = checkStructure("{foo}");
        assertPathElements!(CaptureVariablePathElement)(pathPattern);
        checkStructure("/{foo}");
        checkStructure("/{f}/");
        checkStructure("/{foo}/{bar}/{wibble}");
        checkStructure("/{mobile-number}"); // gh-23101
    }

    @("PathPatternParserTests.StructureTests.completeCaptureWithConstraints")
    unittest
    {
        auto pathPattern = checkStructure("{foo:...}");
        assertPathElements!(CaptureVariablePathElement)(pathPattern);
        pathPattern = checkStructure("{foo:[0-9]*}");
        assertPathElements!(CaptureVariablePathElement)(pathPattern);
    }

    @("PathPatternParserTests.StructureTests.captureSegmentsStartOfPathPatterns")
    unittest
    {
        auto pathPattern = checkStructure("/{*foobar}");
        assertPathElements!(CaptureSegmentsPathElement)(pathPattern);
        pathPattern = checkStructure("/{*foobar}/foo");
        assertPathElements!(CaptureSegmentsPathElement, SeparatorPathElement, LiteralPathElement)(pathPattern);
    }

    @("PathPatternParserTests.StructureTests.captureSegmentsEndOfPathPatterns")
    unittest
    {
        auto pathPattern = parse("{*foobar}");
        assert(pathPattern.computePatternString() == "/{*foobar}");
        assertPathElements!(CaptureSegmentsPathElement)(pathPattern);
        pathPattern = checkStructure("/{*foobar}");
        assertPathElements!(CaptureSegmentsPathElement)(pathPattern);
        pathPattern = checkStructure("/foo/{*foobar}");
        assertPathElements!(SeparatorPathElement, LiteralPathElement, CaptureSegmentsPathElement)(pathPattern);
    }

    @("PathPatternParserTests.StructureTests.multipleSeparatorPatterns")
    unittest
    {
        auto pathPattern = checkStructure("///aaa");
        assertPathElements!(SeparatorPathElement, SeparatorPathElement, SeparatorPathElement, LiteralPathElement)(
                pathPattern);
        pathPattern = checkStructure("///aaa////aaa/b");
        assertPathElements!(SeparatorPathElement, SeparatorPathElement, SeparatorPathElement,
                LiteralPathElement, SeparatorPathElement,
                SeparatorPathElement,
                SeparatorPathElement, SeparatorPathElement, LiteralPathElement,
                SeparatorPathElement, LiteralPathElement)(pathPattern);
        pathPattern = checkStructure("/////**");
        assertPathElements!(SeparatorPathElement, SeparatorPathElement, SeparatorPathElement,
                SeparatorPathElement, WildcardSegmentsPathElement)(pathPattern);
    }

    @("PathPatternParserTests.StructureTests.regexPathElementPatterns")
    unittest
    {
        auto pathPattern = checkStructure("/{var:\\\\}");
        assertPathElements!(SeparatorPathElement, CaptureVariablePathElement)(pathPattern);

        pathPattern = checkStructure("/{var:\\/}");
        assertPathElements!(SeparatorPathElement, CaptureVariablePathElement)(pathPattern);

        pathPattern = checkStructure("/{var:a{1,2}}");
        assertPathElements!(SeparatorPathElement, CaptureVariablePathElement)(pathPattern);

        pathPattern = checkStructure("/{var:[^\\/]*}");
        assertPathElements!(SeparatorPathElement, CaptureVariablePathElement)(pathPattern);

        pathPattern = checkStructure("/{var:\\[*}");
        assertPathElements!(SeparatorPathElement, CaptureVariablePathElement)(pathPattern);

        pathPattern = checkStructure("/{var:[\\{]*}");
        assertPathElements!(SeparatorPathElement, CaptureVariablePathElement)(pathPattern);

        pathPattern = checkStructure("/{var:[\\}]*}");
        assertPathElements!(SeparatorPathElement, CaptureVariablePathElement)(pathPattern);

        pathPattern = checkStructure("*");
        assertPathElements!(WildcardPathElement)(pathPattern);
        checkStructure("/*");
        checkStructure("/*/");
        checkStructure("*/");
        checkStructure("/*/");
        pathPattern = checkStructure("/*a*/");
        assertPathElements!(SeparatorPathElement, RegexPathElement, SeparatorPathElement)(pathPattern);
        pathPattern = checkStructure("*/");
        assertPathElements!(WildcardPathElement, SeparatorPathElement)(pathPattern);

        pathPattern = checkStructure("{symbolicName:[\\p{L}\\.]+}-sources-{version:[\\p{N}\\.]+}.jar");
        assertPathElements!(RegexPathElement)(pathPattern);
    }

    private PathPattern checkStructure(string pattern)
    {
        const patternParser = new PathPatternParser();
        auto pp = patternParser.parse(pattern);
        assert(pp.computePatternString() == pattern);
        return pp;
    }

    private void assertPathElements(SectionClasses...)(PathPattern p)
    {
        import std.string : lastIndexOf;

        PathElement head = p.getHeadSection();
        static foreach (SectionClass; SectionClasses)
        {
            if (head is null)
                assert(false, "Ran out of data in parsed pattern. Pattern is: " ~ p.toChainString());
            {
                const name = typeid(head).name;
                assert(name[name.lastIndexOf('.') + 1 .. $] == __traits(identifier, SectionClass),
                        "Not expected section type. Pattern is: " ~ p.toChainString());
            }
            head = head.next;
        }
    }
}

// ParsingErrorTests

// PatternParseException.PatternMessage, getMessageType, getInserts and toDetailedString are not ported; the
// parser reports a position and a message text only.
version (FlintPathPatternMessages)
{
    import flint.web.util.pattern : PatternParseException;

    private alias PatternMessage = PatternParseException.PatternMessage;

    @("PathPatternParserTests.ParsingErrorTests.captureSegmentsIllegalSyntax")
    unittest
    {
        checkError("/{*foobar}abc", 1, PatternMessage.CAPTURE_ALL_IS_STANDALONE_CONSTRUCT);
        checkError("/{*f%obar}", 4, PatternMessage.ILLEGAL_CHARACTER_IN_CAPTURE_DESCRIPTOR);
        checkError("/{*foobar}abc", 1, PatternMessage.CAPTURE_ALL_IS_STANDALONE_CONSTRUCT);
        checkError("/{f*oobar}", 3, PatternMessage.ILLEGAL_CHARACTER_IN_CAPTURE_DESCRIPTOR);
        checkError("/{*foobar:.*}/abc", 9, PatternMessage.ILLEGAL_CHARACTER_IN_CAPTURE_DESCRIPTOR);
        checkError("/{abc}{*foobar}", 1, PatternMessage.CAPTURE_ALL_IS_STANDALONE_CONSTRUCT);
        checkError("/{abc}{*foobar}{foo}", 1, PatternMessage.CAPTURE_ALL_IS_STANDALONE_CONSTRUCT);
        checkError("/{*foo}/foo/{*bar}", 18, PatternMessage.CANNOT_HAVE_MANY_MULTISEGMENT_PATHELEMENTS);
        checkError("{foo:}", 5, PatternMessage.MISSING_REGEX_CONSTRAINT);
        checkError("{foo}_{foo}", 0, PatternMessage.ILLEGAL_DOUBLE_CAPTURE, "foo");
        checkError("/{bar}/{bar}", 7, PatternMessage.ILLEGAL_DOUBLE_CAPTURE, "bar");
        checkError("/{bar}/{bar}_{foo}", 7, PatternMessage.ILLEGAL_DOUBLE_CAPTURE, "bar");
    }

    @("PathPatternParserTests.ParsingErrorTests.regexpSegmentsIllegalSyntax")
    unittest
    {
        checkError("/{var:[^/]*}", 8, PatternMessage.MISSING_CLOSE_CAPTURE);
        checkError("/{var:abc", 8, PatternMessage.MISSING_CLOSE_CAPTURE);
        // Do not check the expected position due a change in RegEx parsing in JDK 13.
        // See https://github.com/spring-projects/spring-framework/issues/23669
        checkError("/{var:a{{1,2}}}", PatternMessage.REGEX_PATTERN_SYNTAX_EXCEPTION);
    }

    @("PathPatternParserTests.ParsingErrorTests.illegalCapturePatterns")
    unittest
    {
        checkError("{abc/", 4, PatternMessage.MISSING_CLOSE_CAPTURE);
        checkError("{abc:}/", 5, PatternMessage.MISSING_REGEX_CONSTRAINT);
        checkError("{", 1, PatternMessage.MISSING_CLOSE_CAPTURE);
        checkError("{abc", 4, PatternMessage.MISSING_CLOSE_CAPTURE);
        checkError("{/}", 1, PatternMessage.MISSING_CLOSE_CAPTURE);
        checkError("/{", 2, PatternMessage.MISSING_CLOSE_CAPTURE);
        checkError("}", 0, PatternMessage.MISSING_OPEN_CAPTURE);
        checkError("/}", 1, PatternMessage.MISSING_OPEN_CAPTURE);
        checkError("def}", 3, PatternMessage.MISSING_OPEN_CAPTURE);
        checkError("/{/}", 2, PatternMessage.MISSING_CLOSE_CAPTURE);
        checkError("/{{/}", 2, PatternMessage.ILLEGAL_NESTED_CAPTURE);
        checkError("/{abc{/}", 5, PatternMessage.ILLEGAL_NESTED_CAPTURE);
        checkError("/{0abc}/abc", 2, PatternMessage.ILLEGAL_CHARACTER_AT_START_OF_CAPTURE_DESCRIPTOR);
        checkError("/{a?bc}/abc", 3, PatternMessage.ILLEGAL_CHARACTER_IN_CAPTURE_DESCRIPTOR);
        checkError("/{abc}_{abc}", 1, PatternMessage.ILLEGAL_DOUBLE_CAPTURE);
        checkError("/foobar/{abc}_{abc}", 8, PatternMessage.ILLEGAL_DOUBLE_CAPTURE);
        checkError("/foobar/{abc:..}_{abc:..}", 8, PatternMessage.ILLEGAL_DOUBLE_CAPTURE);
    }
}

// `{name:regex}` captures are not ported; the parser rejects them.
version (FlintPathPatternRegexCaptures)
{
    @("PathPatternParserTests.ParsingErrorTests.captureGroupInRegexpNotAllowed")
    unittest
    {
        import flint.java.lang : IllegalArgumentException;

        const pp = parse("/{abc:foo(bar)}");
        enum message = "No capture groups allowed in the constraint regex: foo(bar)";
        assert(thrownMessage!IllegalArgumentException(() { pp.matchAndExtract("/foo"); }) == message);
        assert(thrownMessage!IllegalArgumentException(() { pp.matchAndExtract("/foobar"); }) == message);
    }
}

version (FlintPathPatternMessages)
{
    @("PathPatternParserTests.ParsingErrorTests.badPatterns")
    unittest
    {
        //checkError("/{foo}{bar}/",6,PatternMessage.CANNOT_HAVE_ADJACENT_CAPTURES);
        checkError("/{?}/", 2, PatternMessage.ILLEGAL_CHARACTER_AT_START_OF_CAPTURE_DESCRIPTOR, "?");
        checkError("/{a?b}/", 3, PatternMessage.ILLEGAL_CHARACTER_IN_CAPTURE_DESCRIPTOR, "?");
        checkError("/{%%$}", 2, PatternMessage.ILLEGAL_CHARACTER_AT_START_OF_CAPTURE_DESCRIPTOR, "%");
        checkError("/{ }", 2, PatternMessage.ILLEGAL_CHARACTER_AT_START_OF_CAPTURE_DESCRIPTOR, " ");
        checkError("/{%:[0-9]*}", 2, PatternMessage.ILLEGAL_CHARACTER_AT_START_OF_CAPTURE_DESCRIPTOR, "%");
    }

    @("PathPatternParserTests.ParsingErrorTests.captureTheRestWithinPatternNotSupported")
    unittest
    {
        const parser = new PathPatternParser();
        Exception thrown;
        try
            parser.parse("/resources/**/details");
        catch (Exception e)
            thrown = e;
        const ex = cast(PatternParseException) thrown;
        assert(ex !is null);
        assert(ex.getMessageType() == PatternMessage.INVALID_LOCATION_FOR_MULTISEGMENT_PATHELEMENT);
    }

    /// Delegates to `checkError(string, int, PatternMessage, string[]...)`, passing `-1` as the `expectedPos`.
    private void checkError(string pattern, PatternMessage expectedMessage, string[] expectedInserts...)
    {
        checkError(pattern, -1, expectedMessage, expectedInserts);
    }

    /// `expectedPos`: the expected position, or `-1` if the position should not be checked.
    private void checkError(string pattern, int expectedPos, PatternMessage expectedMessage,
            string[] expectedInserts...)
    {
        PatternParseException ex;
        try
            parse(pattern);
        catch (PatternParseException e)
            ex = e;
        assert(ex !is null, "Expected PatternParseException for " ~ pattern);
        if (expectedPos >= 0)
        {
            assert(ex.getPosition() == cast(size_t) expectedPos, ex.toDetailedString());
        }
        assert(ex.getMessageType() == expectedMessage, ex.toDetailedString());
        if (expectedInserts.length != 0)
        {
            assert(ex.getInserts() == expectedInserts);
        }
    }
}

// PathPatternParserTests

// PathPattern.toChainString(), which renders the parsed path elements, is not ported.
version (FlintPathPatternChainString)
{
    @("PathPatternParserTests.toStringTests")
    unittest
    {
        assert(parse("/{*foobar}").toChainString() == "CaptureSegments(/{*foobar})");
        assert(parse("{foobar}").toChainString() == "CaptureVariable({foobar})");
        assert(parse("abc").toChainString() == "Literal(abc)");
        assert(parse("{a}_*_{b}").toChainString() == "Regex({a}_*_{b})");
        assert(parse("/").toChainString() == "Separator(/)");
        assert(parse("?a?b?c").toChainString() == "SingleCharWildcarded(?a?b?c)");
        assert(parse("*").toChainString() == "Wildcard(*)");
        assert(parse("/**").toChainString() == "WildcardSegments(/**)");
    }
}

// PathPatternParser.setCaseSensitive is not ported; matching is always case-sensitive.
version (FlintPathPatternCaseSensitivity)
{
    // Class equality through `==` on a const reference is @system in druntime.
    @("PathPatternParserTests.equalsAndHashcode")
    @system unittest
    {
        auto caseInsensitiveParser = new PathPatternParser();
        caseInsensitiveParser.setCaseSensitive(false);
        const caseSensitiveParser = new PathPatternParser();
        PathPattern pp1 = caseInsensitiveParser.parse("/abc");
        PathPattern pp2 = caseInsensitiveParser.parse("/abc");
        const pp3 = caseInsensitiveParser.parse("/def");
        assert(pp2 == pp1);
        assert(pp2.toHash() == pp1.toHash());
        assert(pp3 != pp1);

        pp1 = caseInsensitiveParser.parse("/abc");
        pp2 = caseSensitiveParser.parse("/abc");
        assert(pp1 != pp2);
        assert(pp2.toHash() != pp1.toHash());
    }
}

version (FlintPathPatternChainString)
{
    @("PathPatternParserTests.noEncoding")
    unittest
    {
        // Check no encoding of expressions or constraints
        auto pp = parse("/{var:f o}");
        assert(pp.toChainString() == "Separator(/) CaptureVariable({var:f o})");

        pp = parse("/{var:f o}_");
        assert(pp.toChainString() == "Separator(/) Regex({var:f o}_)");

        pp = parse("{foo:f o}_ _{bar:b\\|o}");
        assert(pp.toChainString() == "Regex({foo:f o}_ _{bar:b\\|o})");
    }
}

// Segments that mix literal text with `?`, `*` or `{name}` (Spring's SingleCharWildcardedPathElement and
// RegexPathElement) are not ported; the parser rejects them.
version (FlintPathPatternPartialSegments)
{
    @("PathPatternParserTests.patternPropertyGetCaptureCountTests")
    unittest
    {
        // Test all basic section types
        assert(parse("{foo}").getCapturedVariableCount() == 1);
        assert(parse("foo").getCapturedVariableCount() == 0);
        assert(parse("{*foobar}").getCapturedVariableCount() == 1);
        assert(parse("/{*foobar}").getCapturedVariableCount() == 1);
        assert(parse("/**").getCapturedVariableCount() == 0);
        assert(parse("{abc}asdf").getCapturedVariableCount() == 1);
        assert(parse("{abc}_*").getCapturedVariableCount() == 1);
        assert(parse("{abc}_{def}").getCapturedVariableCount() == 2);
        assert(parse("/").getCapturedVariableCount() == 0);
        assert(parse("a?b").getCapturedVariableCount() == 0);
        assert(parse("*").getCapturedVariableCount() == 0);

        // Test on full templates
        assert(parse("/foo/bar").getCapturedVariableCount() == 0);
        assert(parse("/{foo}").getCapturedVariableCount() == 1);
        assert(parse("/{foo}/{bar}").getCapturedVariableCount() == 2);
        assert(parse("/{foo}/{bar}_{goo}_{wibble}/abc/bar").getCapturedVariableCount() == 4);
    }

    @("PathPatternParserTests.patternPropertyGetWildcardCountTests")
    unittest
    {
        // Test all basic section types
        assert(parse("{foo}").getScore() == computeScore(1, 0));
        assert(parse("foo").getScore() == computeScore(0, 0));
        assert(parse("{*foobar}").getScore() == computeScore(0, 0));
        //		assertEquals(1,parse("/**").getScore());
        assert(parse("{abc}asdf").getScore() == computeScore(1, 0));
        assert(parse("{abc}_*").getScore() == computeScore(1, 1));
        assert(parse("{abc}_{def}").getScore() == computeScore(2, 0));
        assert(parse("/").getScore() == computeScore(0, 0));
        // currently deliberate
        assert(parse("a?b").getScore() == computeScore(0, 0));
        assert(parse("*").getScore() == computeScore(0, 1));

        // Test on full templates
        assert(parse("/foo/bar").getScore() == computeScore(0, 0));
        assert(parse("/{foo}").getScore() == computeScore(1, 0));
        assert(parse("/{foo}/{bar}").getScore() == computeScore(2, 0));
        assert(parse("/{foo}/{bar}_{goo}_{wibble}/abc/bar").getScore() == computeScore(4, 0));
        assert(parse("/{foo}/*/*_*/{bar}_{goo}_{wibble}/abc/bar").getScore() == computeScore(4, 3));
    }
}

version (FlintPathPatternStructure)
{
    @("PathPatternParserTests.normalizedLengthWhenMultipleSeparator")
    unittest
    {
        auto pathPattern = parse("///aaa");
        assert(pathPattern.getNormalizedLength() == 6);
        pathPattern = parse("///aaa////aaa/b");
        assert(pathPattern.getNormalizedLength() == 15);
        pathPattern = parse("/////**");
        assert(pathPattern.getNormalizedLength() == 5);
    }

    @("PathPatternParserTests.normalizedLengthWhenVariable")
    unittest
    {
        // Test all basic section types
        assert(parse("{foo}").getNormalizedLength() == 1);
        assert(parse("foo").getNormalizedLength() == 3);
        assert(parse("{*foobar}").getNormalizedLength() == 1);
        assert(parse("/{*foobar}").getNormalizedLength() == 1);
        assert(parse("**").getNormalizedLength() == 1);
        assert(parse("/**").getNormalizedLength() == 1);
        assert(parse("{abc}asdf").getNormalizedLength() == 5);
        assert(parse("{abc}_*").getNormalizedLength() == 3);
        assert(parse("{abc}_{def}").getNormalizedLength() == 3);
        assert(parse("/").getNormalizedLength() == 1);
        assert(parse("a?b").getNormalizedLength() == 3);
        assert(parse("*").getNormalizedLength() == 1);

        // Test on full templates
        assert(parse("/foo/bar").getNormalizedLength() == 8);
        assert(parse("/{foo}").getNormalizedLength() == 2);
        assert(parse("/{foo}/{bar}").getNormalizedLength() == 4);
        assert(parse("/{foo}/{bar}_{goo}_{wibble}/abc/bar").getNormalizedLength() == 16);
    }
}

// The public PathContainer (org.springframework.http.server: Options) and PathPatternParser.setPathOptions are
// not ported; the separator is always '/'.
version (FlintPathPatternPathContainer)
{
    @("PathPatternParserTests.separatorTests")
    unittest
    {
        import flint.http.server : PathContainer;

        auto parser = new PathPatternParser();
        parser.setPathOptions(PathContainer.Options.create('.', false));
        const rawPattern = "first.second.{last}";
        const pattern = parser.parse(rawPattern);
        assert(pattern.computePatternString() == rawPattern);
    }
}

version (FlintPathPatternPartialSegments)
{
    @("PathPatternParserTests.compareTests")
    unittest
    {
        import std.algorithm.mutation : SwapStrategy;
        import std.algorithm.sorting : sort;

        // Collections.sort is a stable sort by the natural order.
        void sortPatterns(PathPattern[] list)
        {
            list.sort!((a, b) => a.compareTo(b) < 0, SwapStrategy.stable);
        }

        PathPattern p1, p2, p3;

        // Based purely on number of captures
        p1 = parse("{a}");
        p2 = parse("{a}/{b}");
        p3 = parse("{a}/{b}/{c}");
        // Based on number of captures
        assert(p1.compareTo(p2) == -1);
        PathPattern[] patterns;
        patterns ~= p2;
        patterns ~= p3;
        patterns ~= p1;
        sortPatterns(patterns);
        assert(patterns[0] == p1);

        // Based purely on length
        p1 = parse("/a/b/c");
        p2 = parse("/a/boo/c/doo");
        p3 = parse("/asdjflaksjdfjasdf");
        assert(p1.compareTo(p2) == 1);
        patterns = null;
        patterns ~= p2;
        patterns ~= p3;
        patterns ~= p1;
        sortPatterns(patterns);
        assert(patterns[0] == p3);

        // Based purely on 'wildness'
        p1 = parse("/*");
        p2 = parse("/*/*");
        p3 = parse("/*/*/*_*");
        assert(p1.compareTo(p2) == -1);
        patterns = null;
        patterns ~= p2;
        patterns ~= p3;
        patterns ~= p1;
        sortPatterns(patterns);
        assert(patterns[0] == p1);

        // Based purely on catchAll
        p1 = parse("{*foobar}");
        p2 = parse("{*goo}");
        assert(p1.compareTo(p2) != 0);

        p1 = parse("/{*foobar}");
        p2 = parse("/abc/{*ww}");
        assert(p1.compareTo(p2) == +1);
        assert(p2.compareTo(p1) == -1);

        p3 = parse("/this/that/theother");
        assert(p1.isCatchAll());
        assert(p2.isCatchAll());
        assert(!p3.isCatchAll());
        patterns = null;
        patterns ~= p2;
        patterns ~= p3;
        patterns ~= p1;
        sortPatterns(patterns);
        assert(patterns[0] == p3);
        assert(patterns[1] == p2);
    }
}

private PathPattern parse(string pattern)
{
    const patternParser = new PathPatternParser();
    return patternParser.parse(pattern);
}

// Mirrors the score computation logic in PathPattern
private int computeScore(int capturedVariableCount, int wildcardCount)
{
    return capturedVariableCount + wildcardCount * 100;
}
