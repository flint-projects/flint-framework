/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/util/UriComponentsBuilderTests.java (a subset; see the counts in
docs/spring/phase1/web-mvc.md) and UriUtilsTests.java, with R14 checks on non-ASCII input.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts.
+/
module flint.web.uri_components_builder_tests;

import flint.java.lang : IllegalArgumentException;
import flint.web.util : UriComponents, UriComponentsBuilder, UriUtils;

@safe:

@("UriComponentsBuilderTests.plain")
unittest
{
    auto builder = UriComponentsBuilder.newInstance();
    auto result = builder.scheme("https").host("example.com").path("foo").queryParam("bar").fragment("baz").build();
    assert(result.getScheme() == "https");
    assert(result.getHost() == "example.com");
    assert(result.getPath() == "foo");
    assert(result.getQuery() == "bar");
    assert(result.getFragment() == "baz");
    assert(result.toUri().toString() == "https://example.com/foo?bar#baz");
}

@("UriComponentsBuilderTests.multipleFromSameBuilder")
unittest
{
    auto builder = UriComponentsBuilder.newInstance().scheme("https").host("example.com").pathSegment("foo");
    auto result1 = builder.build();
    builder = builder.pathSegment("foo2").queryParam("bar").fragment("baz");
    auto result2 = builder.build();
    assert(result1.getPath() == "/foo");
    assert(result1.toUri().toString() == "https://example.com/foo");
    assert(result2.getPath() == "/foo/foo2");
    assert(result2.toUri().toString() == "https://example.com/foo/foo2?bar#baz");
}

@("UriComponentsBuilderTests.fromUriString")
unittest
{
    auto result = UriComponentsBuilder.fromUriString("https://www.ietf.org/rfc/rfc3986.txt").build();
    assert(result.getScheme() == "https");
    assert(result.getUserInfo() is null);
    assert(result.getHost() == "www.ietf.org");
    assert(result.getPort() == -1);
    assert(result.getPath() == "/rfc/rfc3986.txt");
    assert(result.getPathSegments() == ["rfc", "rfc3986.txt"]);
    assert(result.getQuery() is null);
    assert(result.getFragment() is null);

    result = UriComponentsBuilder.fromUriString(
            "https://arjen:foobar@java.sun.com:80/javase/6/docs/api/java/util/BitSet.html"
            ~ "?foo=bar#and(java.util.BitSet)").build();
    assert(result.getUserInfo() == "arjen:foobar");
    assert(result.getHost() == "java.sun.com");
    assert(result.getPort() == 80);
    assert(result.getPath() == "/javase/6/docs/api/java/util/BitSet.html");
    assert(result.getQuery() == "foo=bar");
    assert(result.getQueryParams() == [["foo", "bar"]]);
    assert(result.getFragment() == "and(java.util.BitSet)");
}

@("UriComponentsBuilderTests.fromUriStringIPv6Host")
unittest
{
    auto result = UriComponentsBuilder.fromUriString("http://[1abc:2abc:3abc::5ABC:6abc]:8080/resource")
        .build().encode();
    assert(result.getHost() == "[1abc:2abc:3abc::5ABC:6abc]");
    assert(result.getPort() == 8080);
}

@("UriComponentsBuilderTests.path and pathSegment joining")
unittest
{
    assert(UriComponentsBuilder.fromPath("/foo/").path("/bar").build().getPath() == "/foo/bar");
    assert(UriComponentsBuilder.fromPath("/foo").path("bar").build().getPath() == "/foo/bar");
    assert(UriComponentsBuilder.newInstance().pathSegment("foo").pathSegment("bar").build().getPath() == "/foo/bar");
    // dfmt off
    assert(UriComponentsBuilder.newInstance().pathSegment("/foo/").pathSegment("/bar/").build().getPath() ==
            "/foo/bar");
    // dfmt on
    assert(UriComponentsBuilder.fromPath("/foo").replacePath("/bar").build().getPath() == "/bar");
}

@("UriComponentsBuilderTests.queryParams and replaceQueryParam")
unittest
{
    auto result = UriComponentsBuilder.newInstance().queryParam("baz", "qux", "42").build();
    assert(result.getQuery() == "baz=qux&baz=42");
    result = UriComponentsBuilder.newInstance().queryParam("baz", "qux").replaceQueryParam("baz", "xuq").build();
    assert(result.getQuery() == "baz=xuq");
    result = UriComponentsBuilder.newInstance().queryParam("baz", "qux").replaceQueryParam("baz").build();
    assert(result.getQuery() is null);
}

@("UriComponentsBuilderTests.buildAndExpand: petclinic's Location header")
unittest
{
    auto uri = UriComponentsBuilder.newInstance().path("/api/owners/{id}").buildAndExpand("11").toUri();
    assert(uri.toString() == "/api/owners/11");
    auto expanded = UriComponentsBuilder.fromUriString(
            "http://example.com/hotels/{hotel}/bookings/{booking}").buildAndExpand("42", "21");
    assert(expanded.toUriString() == "http://example.com/hotels/42/bookings/21");
    bool thrown;
    try
        UriComponentsBuilder.fromPath("/{a}/{b}").buildAndExpand("1");
    catch (IllegalArgumentException)
        thrown = true;
    assert(thrown);
}

@("UriComponentsTests.encode: template literals now, variables at expansion (R14)")
unittest
{
    auto encoded = UriComponentsBuilder.fromPath("/hotel list/{city}").build().encode();
    assert(encoded.getPath() == "/hotel%20list/{city}");
    assert(encoded.expand("New York").getPath() == "/hotel%20list/New%20York");
    // A slash in a variable is encoded in a path (PATH_SEGMENT), as in Spring.
    assert(encoded.expand("a/b").getPath() == "/hotel%20list/a%2Fb");
    // Non-ASCII: UTF-8 bytes, identical to Java's UriUtils.encode(..., UTF_8).
    assert(encoded.expand("Zürich").getPath() == "/hotel%20list/Z%C3%BCrich");
    assert(UriComponentsBuilder.fromPath("/été").toUriString() == "/%C3%A9t%C3%A9");
    assert(UriComponentsBuilder.newInstance().queryParam("q", "a&b=c").toUriString() == "?q=a%26b%3Dc");
}

@("UriUtilsTests.encode and decode")
unittest
{
    assert(UriUtils.encodePathSegment("foobar") == "foobar");
    assert(UriUtils.encodePathSegment("foo bar") == "foo%20bar");
    assert(UriUtils.encodePathSegment("foo/bar") == "foo%2Fbar");
    assert(UriUtils.encodePath("/foo/bar") == "/foo/bar");
    assert(UriUtils.encodePath("/foo bar") == "/foo%20bar");
    assert(UriUtils.encodeQueryParam("foobar") == "foobar");
    assert(UriUtils.encodeQueryParam("foo bar") == "foo%20bar");
    assert(UriUtils.encodeQueryParam("foo&bar") == "foo%26bar");
    assert(UriUtils.encodeFragment("foo bar") == "foo%20bar");
    assert(UriUtils.decode("") == "");
    assert(UriUtils.decode("foobar") == "foobar");
    assert(UriUtils.decode("foo%20bar") == "foo bar");
    assert(UriUtils.decode("foo%2bbar") == "foo+bar");
    assert(UriUtils.decode("T%C5%8Dky%C5%8D") == "Tōkyō");
    assert(UriUtils.decode("/Z%C3%BCrich") == "/Zürich");
    assert(UriUtils.decode("Tōkyō") == "Tōkyō");
    bool thrown;
    try
        UriUtils.decode("foo%2");
    catch (IllegalArgumentException)
        thrown = true;
    assert(thrown);
}
