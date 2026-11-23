// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.util.AntPathMatcherTests` (v7.1.0): one `unittest` per Java test method,
each starting with a `// <JavaTestName>` comment. `{name:regex}` variables run on flint.util's backtracking matcher
(no `std.regex`); every upstream regular expression is supported. No test is skipped.

Adapted: `stringMatcherCache` is read through its package-visible field; patternComparatorSort checks both orders
instead of `Collections.shuffle`.
+/
module flint.util.ant_path_matcher_test;

import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.java.util : ArrayList, LinkedHashMap, Map;
import flint.util : AntPathMatcher;
import flint.util.test_support : contains, expectThrows;
import std.conv : to;

@safe:

private void checkMatch(AntPathMatcher pathMatcher)
{
    // test exact matching
    assert(pathMatcher.match("test", "test"));
    assert(pathMatcher.match("/test", "/test"));
    // SPR-14141
    assert(pathMatcher.match("https://example.org", "https://example.org"));
    assert(!pathMatcher.match("/test.jpg", "test.jpg"));
    assert(!pathMatcher.match("test", "/test"));
    assert(!pathMatcher.match("/test", "test"));
    // test matching with ?'s
    assert(pathMatcher.match("t?st", "test"));
    assert(pathMatcher.match("??st", "test"));
    assert(pathMatcher.match("tes?", "test"));
    assert(pathMatcher.match("te??", "test"));
    assert(pathMatcher.match("?es?", "test"));
    assert(!pathMatcher.match("tes?", "tes"));
    assert(!pathMatcher.match("tes?", "testt"));
    assert(!pathMatcher.match("tes?", "tsst"));
    // test matching with *'s
    assert(pathMatcher.match("*", "test"));
    assert(pathMatcher.match("test*", "test"));
    assert(pathMatcher.match("test*", "testTest"));
    assert(pathMatcher.match("test/*", "test/Test"));
    assert(pathMatcher.match("test/*", "test/t"));
    assert(pathMatcher.match("test/*", "test/"));
    assert(pathMatcher.match("*test*", "AnothertestTest"));
    assert(pathMatcher.match("*test", "Anothertest"));
    assert(pathMatcher.match("*.*", "test."));
    assert(pathMatcher.match("*.*", "test.test"));
    assert(pathMatcher.match("*.*", "test.test.test"));
    assert(pathMatcher.match("test*aaa", "testblaaaa"));
    assert(!pathMatcher.match("test*", "tst"));
    assert(!pathMatcher.match("test*", "tsttest"));
    assert(!pathMatcher.match("test*", "test/"));
    assert(!pathMatcher.match("test*", "test/t"));
    assert(!pathMatcher.match("test/*", "test"));
    assert(!pathMatcher.match("*test*", "tsttst"));
    assert(!pathMatcher.match("*test", "tsttst"));
    assert(!pathMatcher.match("*.*", "tsttst"));
    assert(!pathMatcher.match("test*aaa", "test"));
    assert(!pathMatcher.match("test*aaa", "testblaaab"));
    // test matching with ?'s and /'s
    assert(pathMatcher.match("/?", "/a"));
    assert(pathMatcher.match("/?/a", "/a/a"));
    assert(pathMatcher.match("/a/?", "/a/b"));
    assert(pathMatcher.match("/??/a", "/aa/a"));
    assert(pathMatcher.match("/a/??", "/a/bb"));
    assert(pathMatcher.match("/?", "/a"));
    // test matching with **'s
    assert(pathMatcher.match("/**", "/testing/testing"));
    assert(pathMatcher.match("/*/**", "/testing/testing"));
    assert(pathMatcher.match("/**/*", "/testing/testing"));
    assert(pathMatcher.match("/bla/**/bla", "/bla/testing/testing/bla"));
    assert(pathMatcher.match("/bla/**/bla", "/bla/testing/testing/bla/bla"));
    assert(pathMatcher.match("/**/test", "/bla/bla/test"));
    assert(pathMatcher.match("/bla/**/**/bla", "/bla/bla/bla/bla/bla/bla"));
    assert(pathMatcher.match("/bla*bla/test", "/blaXXXbla/test"));
    assert(pathMatcher.match("/*bla/test", "/XXXbla/test"));
    assert(!pathMatcher.match("/bla*bla/test", "/blaXXXbl/test"));
    assert(!pathMatcher.match("/*bla/test", "XXXblab/test"));
    assert(!pathMatcher.match("/*bla/test", "XXXbl/test"));
    assert(!pathMatcher.match("/????", "/bala/bla"));
    assert(!pathMatcher.match("/**/*bla", "/bla/bla/bla/bbb"));
    assert(pathMatcher.match("/*bla*/**/bla/**", "/XXXblaXXXX/testing/testing/bla/testing/testing/"));
    assert(pathMatcher.match("/*bla*/**/bla/*", "/XXXblaXXXX/testing/testing/bla/testing"));
    assert(pathMatcher.match("/*bla*/**/bla/**", "/XXXblaXXXX/testing/testing/bla/testing/testing"));
    assert(pathMatcher.match("/*bla*/**/bla/**", "/XXXblaXXXX/testing/testing/bla/testing/testing.jpg"));
    assert(pathMatcher.match("*bla*/**/bla/**", "XXXblaXXXX/testing/testing/bla/testing/testing/"));
    assert(pathMatcher.match("*bla*/**/bla/*", "XXXblaXXXX/testing/testing/bla/testing"));
    assert(pathMatcher.match("*bla*/**/bla/**", "XXXblaXXXX/testing/testing/bla/testing/testing"));
    assert(!pathMatcher.match("*bla*/**/bla/*", "XXXblaXXXX/testing/testing/bla/testing/testing"));
    assert(!pathMatcher.match("/x/x/**/bla", "/x/x/x/"));
    assert(pathMatcher.match("/foo/bar/**", "/foo/bar"));
    assert(pathMatcher.match("", ""));
    assert(pathMatcher.match("/{bla}.*", "/testing.html"));
    assert(pathMatcher.match("/{bla}", "//x\ny"));
    assert(pathMatcher.match("/{var:.*}", "/x\ny"));
}

// match
unittest
{
    checkMatch(new AntPathMatcher());
}

// matchWithNullPath
unittest
{
    auto pathMatcher = new AntPathMatcher();
    assert(!pathMatcher.match("/test", null));
    assert(!pathMatcher.match("/", null));
    assert(!pathMatcher.match(null, null));
}

// matchWithTrimTokensEnabled
unittest
{
    auto pathMatcher = new AntPathMatcher();
    pathMatcher.setTrimTokens(true);
    assert(pathMatcher.match("/foo/bar", "/foo /bar"));
}

// matchStart
unittest
{
    auto pathMatcher = new AntPathMatcher();
    // test exact matching
    assert(pathMatcher.matchStart("test", "test"));
    assert(pathMatcher.matchStart("/test", "/test"));
    assert(!pathMatcher.matchStart("/test.jpg", "test.jpg"));
    assert(!pathMatcher.matchStart("test", "/test"));
    assert(!pathMatcher.matchStart("/test", "test"));
    // test matching with ?'s
    assert(pathMatcher.matchStart("t?st", "test"));
    assert(pathMatcher.matchStart("??st", "test"));
    assert(pathMatcher.matchStart("tes?", "test"));
    assert(pathMatcher.matchStart("te??", "test"));
    assert(pathMatcher.matchStart("?es?", "test"));
    assert(!pathMatcher.matchStart("tes?", "tes"));
    assert(!pathMatcher.matchStart("tes?", "testt"));
    assert(!pathMatcher.matchStart("tes?", "tsst"));
    // test matching with *'s
    assert(pathMatcher.matchStart("*", "test"));
    assert(pathMatcher.matchStart("test*", "test"));
    assert(pathMatcher.matchStart("test*", "testTest"));
    assert(pathMatcher.matchStart("test/*", "test/Test"));
    assert(pathMatcher.matchStart("test/*", "test/t"));
    assert(pathMatcher.matchStart("test/*", "test/"));
    assert(pathMatcher.matchStart("*test*", "AnothertestTest"));
    assert(pathMatcher.matchStart("*test", "Anothertest"));
    assert(pathMatcher.matchStart("*.*", "test."));
    assert(pathMatcher.matchStart("*.*", "test.test"));
    assert(pathMatcher.matchStart("*.*", "test.test.test"));
    assert(pathMatcher.matchStart("test*aaa", "testblaaaa"));
    assert(!pathMatcher.matchStart("test*", "tst"));
    assert(!pathMatcher.matchStart("test*", "test/"));
    assert(!pathMatcher.matchStart("test*", "tsttest"));
    assert(!pathMatcher.matchStart("test*", "test/"));
    assert(!pathMatcher.matchStart("test*", "test/t"));
    assert(pathMatcher.matchStart("test/*", "test"));
    assert(pathMatcher.matchStart("test/t*.txt", "test"));
    assert(!pathMatcher.matchStart("*test*", "tsttst"));
    assert(!pathMatcher.matchStart("*test", "tsttst"));
    assert(!pathMatcher.matchStart("*.*", "tsttst"));
    assert(!pathMatcher.matchStart("test*aaa", "test"));
    assert(!pathMatcher.matchStart("test*aaa", "testblaaab"));
    // test matching with ?'s and /'s
    assert(pathMatcher.matchStart("/?", "/a"));
    assert(pathMatcher.matchStart("/?/a", "/a/a"));
    assert(pathMatcher.matchStart("/a/?", "/a/b"));
    assert(pathMatcher.matchStart("/??/a", "/aa/a"));
    assert(pathMatcher.matchStart("/a/??", "/a/bb"));
    assert(pathMatcher.matchStart("/?", "/a"));
    // test matching with **'s
    assert(pathMatcher.matchStart("/**", "/testing/testing"));
    assert(pathMatcher.matchStart("/*/**", "/testing/testing"));
    assert(pathMatcher.matchStart("/**/*", "/testing/testing"));
    assert(pathMatcher.matchStart("test*/**", "test/"));
    assert(pathMatcher.matchStart("test*/**", "test/t"));
    assert(pathMatcher.matchStart("/bla/**/bla", "/bla/testing/testing/bla"));
    assert(pathMatcher.matchStart("/bla/**/bla", "/bla/testing/testing/bla/bla"));
    assert(pathMatcher.matchStart("/**/test", "/bla/bla/test"));
    assert(pathMatcher.matchStart("/bla/**/**/bla", "/bla/bla/bla/bla/bla/bla"));
    assert(pathMatcher.matchStart("/bla*bla/test", "/blaXXXbla/test"));
    assert(pathMatcher.matchStart("/*bla/test", "/XXXbla/test"));
    assert(!pathMatcher.matchStart("/bla*bla/test", "/blaXXXbl/test"));
    assert(!pathMatcher.matchStart("/*bla/test", "XXXblab/test"));
    assert(!pathMatcher.matchStart("/*bla/test", "XXXbl/test"));
    assert(!pathMatcher.matchStart("/????", "/bala/bla"));
    assert(pathMatcher.matchStart("/**/*bla", "/bla/bla/bla/bbb"));
    assert(pathMatcher.matchStart("/*bla*/**/bla/**", "/XXXblaXXXX/testing/testing/bla/testing/testing/"));
    assert(pathMatcher.matchStart("/*bla*/**/bla/*", "/XXXblaXXXX/testing/testing/bla/testing"));
    assert(pathMatcher.matchStart("/*bla*/**/bla/**", "/XXXblaXXXX/testing/testing/bla/testing/testing"));
    assert(pathMatcher.matchStart("/*bla*/**/bla/**", "/XXXblaXXXX/testing/testing/bla/testing/testing.jpg"));
    assert(pathMatcher.matchStart("*bla*/**/bla/**", "XXXblaXXXX/testing/testing/bla/testing/testing/"));
    assert(pathMatcher.matchStart("*bla*/**/bla/*", "XXXblaXXXX/testing/testing/bla/testing"));
    assert(pathMatcher.matchStart("*bla*/**/bla/**", "XXXblaXXXX/testing/testing/bla/testing/testing"));
    assert(pathMatcher.matchStart("*bla*/**/bla/*", "XXXblaXXXX/testing/testing/bla/testing/testing"));
    assert(pathMatcher.matchStart("/x/x/**/bla", "/x/x/x/"));
    assert(pathMatcher.matchStart("", ""));
}

// uniqueDeliminator
unittest
{
    auto pathMatcher = new AntPathMatcher();
    pathMatcher.setPathSeparator(".");
    // test exact matching
    assert(pathMatcher.match("test", "test"));
    assert(pathMatcher.match(".test", ".test"));
    assert(!pathMatcher.match(".test/jpg", "test/jpg"));
    assert(!pathMatcher.match("test", ".test"));
    assert(!pathMatcher.match(".test", "test"));
    // test matching with ?'s
    assert(pathMatcher.match("t?st", "test"));
    assert(pathMatcher.match("??st", "test"));
    assert(pathMatcher.match("tes?", "test"));
    assert(pathMatcher.match("te??", "test"));
    assert(pathMatcher.match("?es?", "test"));
    assert(!pathMatcher.match("tes?", "tes"));
    assert(!pathMatcher.match("tes?", "testt"));
    assert(!pathMatcher.match("tes?", "tsst"));
    // test matching with *'s
    assert(pathMatcher.match("*", "test"));
    assert(pathMatcher.match("test*", "test"));
    assert(pathMatcher.match("test*", "testTest"));
    assert(pathMatcher.match("*test*", "AnothertestTest"));
    assert(pathMatcher.match("*test", "Anothertest"));
    assert(pathMatcher.match("*/*", "test/"));
    assert(pathMatcher.match("*/*", "test/test"));
    assert(pathMatcher.match("*/*", "test/test/test"));
    assert(pathMatcher.match("test*aaa", "testblaaaa"));
    assert(!pathMatcher.match("test*", "tst"));
    assert(!pathMatcher.match("test*", "tsttest"));
    assert(!pathMatcher.match("*test*", "tsttst"));
    assert(!pathMatcher.match("*test", "tsttst"));
    assert(!pathMatcher.match("*/*", "tsttst"));
    assert(!pathMatcher.match("test*aaa", "test"));
    assert(!pathMatcher.match("test*aaa", "testblaaab"));
    // test matching with ?'s and .'s
    assert(pathMatcher.match(".?", ".a"));
    assert(pathMatcher.match(".?.a", ".a.a"));
    assert(pathMatcher.match(".a.?", ".a.b"));
    assert(pathMatcher.match(".??.a", ".aa.a"));
    assert(pathMatcher.match(".a.??", ".a.bb"));
    assert(pathMatcher.match(".?", ".a"));
    // test matching with **'s
    assert(pathMatcher.match(".**", ".testing.testing"));
    assert(pathMatcher.match(".*.**", ".testing.testing"));
    assert(pathMatcher.match(".**.*", ".testing.testing"));
    assert(pathMatcher.match(".bla.**.bla", ".bla.testing.testing.bla"));
    assert(pathMatcher.match(".bla.**.bla", ".bla.testing.testing.bla.bla"));
    assert(pathMatcher.match(".**.test", ".bla.bla.test"));
    assert(pathMatcher.match(".bla.**.**.bla", ".bla.bla.bla.bla.bla.bla"));
    assert(pathMatcher.match(".bla*bla.test", ".blaXXXbla.test"));
    assert(pathMatcher.match(".*bla.test", ".XXXbla.test"));
    assert(!pathMatcher.match(".bla*bla.test", ".blaXXXbl.test"));
    assert(!pathMatcher.match(".*bla.test", "XXXblab.test"));
    assert(!pathMatcher.match(".*bla.test", "XXXbl.test"));
}

// extractPathWithinPattern
unittest
{
    auto pathMatcher = new AntPathMatcher();
    assert(pathMatcher.extractPathWithinPattern("/docs/commit.html", "/docs/commit.html") == "");
    assert(pathMatcher.extractPathWithinPattern("/docs/*", "/docs/cvs/commit") == "cvs/commit");
    assert(pathMatcher.extractPathWithinPattern("/docs/cvs/*.html", "/docs/cvs/commit.html") == "commit.html");
    assert(pathMatcher.extractPathWithinPattern("/docs/**", "/docs/cvs/commit") == "cvs/commit");
    assert(pathMatcher.extractPathWithinPattern("/docs/**/*.html", "/docs/cvs/commit.html") == "cvs/commit.html");
    assert(pathMatcher.extractPathWithinPattern("/docs/**/*.html", "/docs/commit.html") == "commit.html");
    assert(pathMatcher.extractPathWithinPattern("/*.html", "/commit.html") == "commit.html");
    assert(pathMatcher.extractPathWithinPattern("/*.html", "/docs/commit.html") == "docs/commit.html");
    assert(pathMatcher.extractPathWithinPattern("*.html", "/commit.html") == "/commit.html");
    assert(pathMatcher.extractPathWithinPattern("*.html", "/docs/commit.html") == "/docs/commit.html");
    assert(pathMatcher.extractPathWithinPattern("**/*.*", "/docs/commit.html") == "/docs/commit.html");
    assert(pathMatcher.extractPathWithinPattern("*", "/docs/commit.html") == "/docs/commit.html");
    // SPR-10515
    assert(pathMatcher.extractPathWithinPattern("**/commit.html",
            "/docs/cvs/other/commit.html") == "/docs/cvs/other/commit.html");
    assert(pathMatcher.extractPathWithinPattern("/docs/**/commit.html",
            "/docs/cvs/other/commit.html") == "cvs/other/commit.html");
    assert(pathMatcher.extractPathWithinPattern("/docs/**/**/**/**",
            "/docs/cvs/other/commit.html") == "cvs/other/commit.html");
    assert(pathMatcher.extractPathWithinPattern("/d?cs/*", "/docs/cvs/commit") == "docs/cvs/commit");
    assert(pathMatcher.extractPathWithinPattern("/docs/c?s/*.html", "/docs/cvs/commit.html") == "cvs/commit.html");
    assert(pathMatcher.extractPathWithinPattern("/d?cs/**", "/docs/cvs/commit") == "docs/cvs/commit");
    assert(pathMatcher.extractPathWithinPattern("/d?cs/**/*.html", "/docs/cvs/commit.html") == "docs/cvs/commit.html");
}

// extractUriTemplateVariables
unittest
{
    auto pathMatcher = new AntPathMatcher();
    auto result = pathMatcher.extractUriTemplateVariables("/hotels/{hotel}", "/hotels/1");
    assert(result.equals(cast(Object) Map!(string, string).of("hotel", "1")));
    result = pathMatcher.extractUriTemplateVariables("/h?tels/{hotel}", "/hotels/1");
    assert(result.equals(cast(Object) Map!(string, string).of("hotel", "1")));
    result = pathMatcher.extractUriTemplateVariables("/hotels/{hotel}/bookings/{booking}", "/hotels/1/bookings/2");
    auto expected = new LinkedHashMap!(string, string)();
    expected.put("hotel", "1");
    expected.put("booking", "2");
    assert(result.equals(expected));
    assert(result.toString() == "{hotel=1, booking=2}");
    result = pathMatcher.extractUriTemplateVariables("/**/hotels/**/{hotel}", "/foo/hotels/bar/1");
    assert(result.equals(cast(Object) Map!(string, string).of("hotel", "1")));
    result = pathMatcher.extractUriTemplateVariables("/{page}.html", "/42.html");
    assert(result.equals(cast(Object) Map!(string, string).of("page", "42")));
    result = pathMatcher.extractUriTemplateVariables("/{page}.*", "/42.html");
    assert(result.equals(cast(Object) Map!(string, string).of("page", "42")));
    result = pathMatcher.extractUriTemplateVariables("/A-{B}-C", "/A-b-C");
    assert(result.equals(cast(Object) Map!(string, string).of("B", "b")));
    result = pathMatcher.extractUriTemplateVariables("/{name}.{extension}", "/test.html");
    expected = new LinkedHashMap!(string, string)();
    expected.put("name", "test");
    expected.put("extension", "html");
    assert(result.equals(expected));
}

// extractUriTemplateVariablesFromDotSeparatedPath
unittest
{
    auto dotSeparatedPathMatcher = new AntPathMatcher(".");
    auto result = dotSeparatedPathMatcher.extractUriTemplateVariables("price.stock.{tickerSymbol}", "price.stock.aaa");
    assert(result.equals(cast(Object) Map!(string, string).of("tickerSymbol", "aaa")));
    result = dotSeparatedPathMatcher.extractUriTemplateVariables("price.stock.{ticker/symbol}", "price.stock.aaa");
    assert(result.equals(cast(Object) Map!(string, string).of("ticker/symbol", "aaa")));
    result = dotSeparatedPathMatcher.extractUriTemplateVariables("notification.**.{operation}",
            "notification.foo.update");
    assert(result.equals(cast(Object) Map!(string, string).of("operation", "update")));
    result = dotSeparatedPathMatcher.extractUriTemplateVariables("news.sports.feed/{type}", "news.sports.feed/xml");
    assert(result.equals(cast(Object) Map!(string, string).of("type", "xml")));
    result = dotSeparatedPathMatcher.extractUriTemplateVariables("news.sports.{operation}/*", "news.sports.feed/xml");
    assert(result.equals(cast(Object) Map!(string, string).of("operation", "feed")));
}

// extractUriTemplateVariablesRegex
unittest
{
    auto pathMatcher = new AntPathMatcher();
    auto result = pathMatcher.extractUriTemplateVariables(
            "{symbolicName:[\\w\\.]+}-{version:[\\w\\.]+}.jar", "com.example-1.0.0.jar");
    assert(result.get("symbolicName") == "com.example");
    assert(result.get("version") == "1.0.0");
    result = pathMatcher.extractUriTemplateVariables(
            "{symbolicName:[\\w\\.]+}-sources-{version:[\\w\\.]+}.jar", "com.example-sources-1.0.0.jar");
    assert(result.get("symbolicName") == "com.example");
    assert(result.get("version") == "1.0.0");
}

// extractUriTemplateVarsRegexQualifiers
unittest
{
    auto pathMatcher = new AntPathMatcher();
    auto result = pathMatcher.extractUriTemplateVariables(
            "{symbolicName:[\\p{L}\\.]+}-sources-{version:[\\p{N}\\.]+}.jar", "com.example-sources-1.0.0.jar");
    assert(result.get("symbolicName") == "com.example");
    assert(result.get("version") == "1.0.0");
    result = pathMatcher.extractUriTemplateVariables(
            "{symbolicName:[\\w\\.]+}-sources-{version:[\\d\\.]+}-{year:\\d{4}}{month:\\d{2}}{day:\\d{2}}.jar",
            "com.example-sources-1.0.0-20100220.jar");
    assert(result.get("symbolicName") == "com.example");
    assert(result.get("version") == "1.0.0");
    assert(result.get("year") == "2010");
    assert(result.get("month") == "02");
    assert(result.get("day") == "20");
    result = pathMatcher.extractUriTemplateVariables(
            "{symbolicName:[\\p{L}\\.]+}-sources-{version:[\\p{N}\\.\\{\\}]+}.jar",
            "com.example-sources-1.0.0.{12}.jar");
    assert(result.get("symbolicName") == "com.example");
    assert(result.get("version") == "1.0.0.{12}");
}

// extractUriTemplateVarsRegexCapturingGroups
unittest
{
    auto pathMatcher = new AntPathMatcher();
    auto e = expectThrows!IllegalArgumentException(() {
        pathMatcher.extractUriTemplateVariables("/web/{id:foo(bar)?}", "/web/foobar");
    });
    assert(e.getMessage().contains("The number of capturing groups in the pattern"));
}

// combine
unittest
{
    auto pathMatcher = new AntPathMatcher();
    assert(pathMatcher.combine(null, null) == "");
    assert(pathMatcher.combine("/hotels", null) == "/hotels");
    assert(pathMatcher.combine(null, "/hotels") == "/hotels");
    assert(pathMatcher.combine("/hotels/*", "booking") == "/hotels/booking");
    assert(pathMatcher.combine("/hotels/*", "/booking") == "/hotels/booking");
    assert(pathMatcher.combine("/hotels/**", "booking") == "/hotels/**/booking");
    assert(pathMatcher.combine("/hotels/**", "/booking") == "/hotels/**/booking");
    assert(pathMatcher.combine("/hotels", "/booking") == "/hotels/booking");
    assert(pathMatcher.combine("/hotels", "booking") == "/hotels/booking");
    assert(pathMatcher.combine("/hotels/", "booking") == "/hotels/booking");
    assert(pathMatcher.combine("/hotels/*", "{hotel}") == "/hotels/{hotel}");
    assert(pathMatcher.combine("/hotels/**", "{hotel}") == "/hotels/**/{hotel}");
    assert(pathMatcher.combine("/hotels", "{hotel}") == "/hotels/{hotel}");
    assert(pathMatcher.combine("/hotels", "{hotel}.*") == "/hotels/{hotel}.*");
    assert(pathMatcher.combine("/hotels/*/booking", "{booking}") == "/hotels/*/booking/{booking}");
    assert(pathMatcher.combine("/*.html", "/hotel.html") == "/hotel.html");
    assert(pathMatcher.combine("/*.html", "/hotel") == "/hotel.html");
    assert(pathMatcher.combine("/*.html", "/hotel.*") == "/hotel.html");
    assert(pathMatcher.combine("/**", "/*.html") == "/*.html");
    assert(pathMatcher.combine("/*", "/*.html") == "/*.html");
    assert(pathMatcher.combine("/*.*", "/*.html") == "/*.html");
    // SPR-8858
    assert(pathMatcher.combine("/{foo}", "/bar") == "/{foo}/bar");
    // SPR-7970
    assert(pathMatcher.combine("/user", "/user") == "/user/user");
    // SPR-10062
    assert(pathMatcher.combine("/{foo:.*[^0-9].*}", "/edit/") == "/{foo:.*[^0-9].*}/edit/");
    // SPR-10554
    assert(pathMatcher.combine("/1.0", "/foo/test") == "/1.0/foo/test");
    // SPR-12975
    assert(pathMatcher.combine("/", "/hotel") == "/hotel");
    // SPR-12975
    assert(pathMatcher.combine("/hotel/", "/booking") == "/hotel/booking");
}

// combineWithTwoFileExtensionPatterns
unittest
{
    auto pathMatcher = new AntPathMatcher();
    expectThrows!IllegalArgumentException(() { pathMatcher.combine("/*.html", "/*.txt"); });
}

// patternComparator
unittest
{
    auto pathMatcher = new AntPathMatcher();
    auto comparator = pathMatcher.getPatternComparator("/hotels/new");
    assert(comparator.compare(null, null) == 0);
    assert(comparator.compare(null, "/hotels/new") == 1);
    assert(comparator.compare("/hotels/new", null) == -1);
    assert(comparator.compare("/hotels/new", "/hotels/new") == 0);
    assert(comparator.compare("/hotels/new", "/hotels/*") == -1);
    assert(comparator.compare("/hotels/*", "/hotels/new") == 1);
    assert(comparator.compare("/hotels/*", "/hotels/*") == 0);
    assert(comparator.compare("/hotels/new", "/hotels/{hotel}") == -1);
    assert(comparator.compare("/hotels/{hotel}", "/hotels/new") == 1);
    assert(comparator.compare("/hotels/{hotel}", "/hotels/{hotel}") == 0);
    assert(comparator.compare("/hotels/{hotel}/booking", "/hotels/{hotel}/bookings/{booking}") == -1);
    assert(comparator.compare("/hotels/{hotel}/bookings/{booking}", "/hotels/{hotel}/booking") == 1);
    // SPR-10550
    assert(comparator.compare("/hotels/{hotel}/bookings/{booking}/customers/{customer}", "/**") == -1);
    assert(comparator.compare("/**", "/hotels/{hotel}/bookings/{booking}/customers/{customer}") == 1);
    assert(comparator.compare("/**", "/**") == 0);
    assert(comparator.compare("/hotels/{hotel}", "/hotels/*") == -1);
    assert(comparator.compare("/hotels/*", "/hotels/{hotel}") == 1);
    assert(comparator.compare("/hotels/*", "/hotels/*/**") == -1);
    assert(comparator.compare("/hotels/*/**", "/hotels/*") == 1);
    assert(comparator.compare("/hotels/new", "/hotels/new.*") == -1);
    assert(comparator.compare("/hotels/{hotel}", "/hotels/{hotel}.*") == 2);
    // SPR-6741
    assert(comparator.compare("/hotels/{hotel}/bookings/{booking}/customers/{customer}", "/hotels/**") == -1);
    assert(comparator.compare("/hotels/**", "/hotels/{hotel}/bookings/{booking}/customers/{customer}") == 1);
    assert(comparator.compare("/hotels/foo/bar/**", "/hotels/{hotel}") == 1);
    assert(comparator.compare("/hotels/{hotel}", "/hotels/foo/bar/**") == -1);
    // gh-23125
    assert(comparator.compare("/hotels/*/bookings/**", "/hotels/**") == -11);
    // SPR-8683
    assert(comparator.compare("/**", "/hotels/{hotel}") == 1);
    // longer is better
    assert(comparator.compare("/hotels", "/hotels2") == 1);
    // SPR-13139
    assert(comparator.compare("*", "*/**") == -1);
    assert(comparator.compare("*/**", "*") == 1);
}

// patternComparatorWithDotSeparator
unittest
{
    auto dotSeparatedPathMatcher = new AntPathMatcher(".");
    auto comparator = dotSeparatedPathMatcher.getPatternComparator("price.stock.spring");
    assert(comparator.compare(null, null) == 0);
    assert(comparator.compare("price.stock.ticker/symbol", "price.stock.ticker/symbol") == 0);
    assert(comparator.compare("price.stock.**", "price.stock.ticker") == 1);
}

// patternComparatorSort
unittest
{
    auto pathMatcher = new AntPathMatcher();
    auto comparator = pathMatcher.getPatternComparator("/hotels/new");
    auto paths = new ArrayList!string(3);
    void check(string[] input, string[] expected)
    {
        paths.clear();
        foreach (path; input)
            paths.add(path);
        paths.sort(comparator);
        assert(paths.toArray() == expected);
    }

    check([null, "/hotels/new"], ["/hotels/new", null]);
    check(["/hotels/new", null], ["/hotels/new", null]);
    check(["/hotels/*", "/hotels/new"], ["/hotels/new", "/hotels/*"]);
    check(["/hotels/new", "/hotels/*"], ["/hotels/new", "/hotels/*"]);
    check(["/hotels/**", "/hotels/*"], ["/hotels/*", "/hotels/**"]);
    check(["/hotels/*", "/hotels/**"], ["/hotels/*", "/hotels/**"]);
    check(["/hotels/{hotel}", "/hotels/new"], ["/hotels/new", "/hotels/{hotel}"]);
    check(["/hotels/new", "/hotels/{hotel}"], ["/hotels/new", "/hotels/{hotel}"]);
    check(["/hotels/*", "/hotels/{hotel}", "/hotels/new"], [
        "/hotels/new", "/hotels/{hotel}", "/hotels/*"
    ]);
    // Java shuffles these inputs; both orders are checked here.
    check(["/hotels/ne*", "/hotels/n*"], ["/hotels/ne*", "/hotels/n*"]);
    check(["/hotels/n*", "/hotels/ne*"], ["/hotels/ne*", "/hotels/n*"]);
    comparator = pathMatcher.getPatternComparator("/hotels/new.html");
    check(["/hotels/new.*", "/hotels/{hotel}"], ["/hotels/new.*", "/hotels/{hotel}"]);
    check(["/hotels/{hotel}", "/hotels/new.*"], ["/hotels/new.*", "/hotels/{hotel}"]);
    comparator = pathMatcher.getPatternComparator("/web/endUser/action/login.html");
    check(["/**/login.*", "/**/endUser/action/login.*"], [
        "/**/endUser/action/login.*", "/**/login.*"
    ]);
}

// trimTokensOff
unittest
{
    auto pathMatcher = new AntPathMatcher();
    pathMatcher.setTrimTokens(false);
    assert(pathMatcher.match("/group/{groupName}/members", "/group/sales/members"));
    assert(pathMatcher.match("/group/{groupName}/members", "/group/  sales/members"));
    assert(!pathMatcher.match("/group/{groupName}/members", "/Group/  Sales/Members"));
}

// caseInsensitive
unittest
{
    auto pathMatcher = new AntPathMatcher();
    pathMatcher.setCaseSensitive(false);
    assert(pathMatcher.match("/group/{groupName}/members", "/group/sales/members"));
    assert(pathMatcher.match("/group/{groupName}/members", "/Group/Sales/Members"));
    assert(pathMatcher.match("/Group/{groupName}/Members", "/group/Sales/members"));
}

// defaultCacheSetting
unittest
{
    auto pathMatcher = new AntPathMatcher();
    checkMatch(pathMatcher);
    assert(pathMatcher.stringMatcherCache.length > 20);
    foreach (i; 0 .. 65_536)
        pathMatcher.match("test" ~ i.to!string, "test");
    // Cache turned off because it went beyond the threshold
    assert(pathMatcher.stringMatcherCache.length == 0);
}

// cachePatternsSetToTrue
unittest
{
    auto pathMatcher = new AntPathMatcher();
    pathMatcher.setCachePatterns(true);
    checkMatch(pathMatcher);
    assert(pathMatcher.stringMatcherCache.length > 20);
    foreach (i; 0 .. 65_536)
        pathMatcher.match("test" ~ i.to!string, "test" ~ i.to!string);
    // Cache keeps being alive due to the explicit cache setting
    assert(pathMatcher.stringMatcherCache.length > 65_536);
}

// preventCreatingStringMatchersIfPathDoesNotStartsWithPatternPrefix
unittest
{
    auto pathMatcher = new AntPathMatcher();
    pathMatcher.setCachePatterns(true);
    assert(pathMatcher.stringMatcherCache.length == 0);
    pathMatcher.match("test?", "test");
    assert(pathMatcher.stringMatcherCache.length == 1);
    pathMatcher.match("test?", "best");
    pathMatcher.match("test/*", "view/test.jpg");
    pathMatcher.match("test/**/test.jpg", "view/test.jpg");
    pathMatcher.match("test/{name}.jpg", "view/test.jpg");
    assert(pathMatcher.stringMatcherCache.length == 1);
}

// creatingStringMatchersIfPatternPrefixCannotDetermineIfPathMatch
unittest
{
    auto pathMatcher = new AntPathMatcher();
    pathMatcher.setCachePatterns(true);
    assert(pathMatcher.stringMatcherCache.length == 0);
    pathMatcher.match("test", "testian");
    pathMatcher.match("test?", "testFf");
    pathMatcher.match("test/*", "test/dir/name.jpg");
    pathMatcher.match("test/{name}.jpg", "test/lorem.jpg");
    pathMatcher.match("bla/**/test.jpg", "bla/test.jpg");
    pathMatcher.match("**/{name}.jpg", "test/lorem.jpg");
    pathMatcher.match("/**/{name}.jpg", "/test/lorem.jpg");
    pathMatcher.match("/*/dir/{name}.jpg", "/*/dir/lorem.jpg");
    assert(pathMatcher.stringMatcherCache.length == 7);
}

// cachePatternsSetToFalse
unittest
{
    auto pathMatcher = new AntPathMatcher();
    pathMatcher.setCachePatterns(false);
    checkMatch(pathMatcher);
    assert(pathMatcher.stringMatcherCache.length == 0);
}

// extensionMappingWithDotPathSeparator
unittest
{
    auto pathMatcher = new AntPathMatcher();
    pathMatcher.setPathSeparator(".");
    assert(pathMatcher.combine("/*.html", "hotel.*") == "/*.html.hotel.*",
            "Extension mapping should be disabled with \".\" as path separator");
}

// isPattern
unittest
{
    auto pathMatcher = new AntPathMatcher();
    assert(pathMatcher.isPattern("/test/*"));
    assert(pathMatcher.isPattern("/test/**/name"));
    assert(pathMatcher.isPattern("/test?"));
    assert(pathMatcher.isPattern("/test/{name}"));
    assert(!pathMatcher.isPattern("/test/name"));
    assert(!pathMatcher.isPattern("/test/foo{bar"));
}

// isPatternWithNullPath
unittest
{
    auto pathMatcher = new AntPathMatcher();
    assert(!pathMatcher.isPattern(null));
}

// consistentMatchWithWildcardsAndTrailingSlash
unittest
{
    auto pathMatcher = new AntPathMatcher();
    assert(pathMatcher.match("/*/foo", "/en/foo"));
    assert(!pathMatcher.match("/*/foo", "/en/foo/"));
    assert(pathMatcher.match("/**/foo", "/en/foo"));
    assert(!pathMatcher.match("/**/foo", "/en/foo/"));
}

// Flint (R14): segments, variables and patterns with non-ASCII characters.
unittest
{
    auto pathMatcher = new AntPathMatcher();
    assert(pathMatcher.match("/日本/*/語", "/日本/東京/語"));
    assert(pathMatcher.match("/caf?/x", "/café/x"), "? matches one character, not one byte");
    assert(!pathMatcher.match("/caf??/x", "/café/x"));
    assert(pathMatcher.match("/😀?", "/😀😀"));
    assert(pathMatcher.match("/**/é*.txt", "/a/b/éa.txt"));
    assert(!pathMatcher.match("/日本/*", "/日本語/x"));
    auto result = pathMatcher.extractUriTemplateVariables("/ville/{nom}/{n:\\p{N}+}", "/ville/Zürich/４２");
    assert(result.get("nom") == "Zürich");
    assert(result.get("n") == "４２");
    result = pathMatcher.extractUriTemplateVariables("/{a:[à-ÿ]+}-{b}", "/éèê-日本");
    assert(result.get("a") == "éèê" && result.get("b") == "日本");
    assert(pathMatcher.extractPathWithinPattern("/文書/*", "/文書/版/1") == "版/1");
    assert(pathMatcher.combine("/ホテル/*", "予約") == "/ホテル/予約");
    pathMatcher.setCaseSensitive(false);
    assert(pathMatcher.match("/ÉCOLE/{x}", "/école/1"), "exact segments compare like equalsIgnoreCase");
    auto comparator = pathMatcher.getPatternComparator("/x");
    // Lengths compare in UTF-16 units: "/日本" (3 units) is shorter than "/abcd" (5 units).
    assert(comparator.compare("/日本", "/abcd") == 2);
    auto separator = new AntPathMatcher("→");
    assert(separator.match("a→*→c", "a→b→c"));
    assert(separator.combine("a→*", "b") == "a→b");
}

// Flint: the regular-expression engine on its own terms.
unittest
{
    auto pathMatcher = new AntPathMatcher();
    auto result = pathMatcher.extractUriTemplateVariables("/{v:(?:ab|cd)+?e*}", "/abcdee");
    assert(result.get("v") == "abcdee");
    result = pathMatcher.extractUriTemplateVariables("/{x:[^-]+}-{y:.{2,3}}", "/abc-de");
    assert(result.get("x") == "abc" && result.get("y") == "de");
    assert(!pathMatcher.match("/{y:.{2,3}}", "/d"));
    assert(pathMatcher.match("/{y:\\w{2,}}", "/dddd"));
    assert(!pathMatcher.match("/{y:\\d+}", "/12a"));
    assert(pathMatcher.match("/{y:\\D+\\s?\\S}", "/ab c"));
    expectThrows!IllegalArgumentException(() { pathMatcher.match("/{y:\\bx}", "/x"); });
    expectThrows!IllegalArgumentException(() { pathMatcher.match("/{y:a++}", "/aa"); });
    expectThrows!IllegalArgumentException(() { pathMatcher.match("/{y:(?<n>a)}", "/a"); });
    expectThrows!IllegalStateException(() {
        pathMatcher.extractUriTemplateVariables("/a/{b}", "/x/y");
    });
    // Catastrophic backtracking hits Spring's character-access budget instead of running away.
    string text = "/";
    foreach (_; 0 .. 30)
        text ~= "a";
    expectThrows!IllegalStateException(() { pathMatcher.match("/{y:(a|aa)+b}", text ~ "c"); });
    pathMatcher.setCaseSensitive(false);
    assert(pathMatcher.match("/{y:[a-c]+}X", "/ABCx"));
}
