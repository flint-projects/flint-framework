/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/util/UriUtilsTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. flint.web's
UriUtils always uses UTF-8, so the `Charset` argument (UTF-8 in every upstream case) is dropped.
+/
module flint.web.util.uri_utils_tests;

import flint.java.lang : IllegalArgumentException;
import flint.web.util : UriUtils;

@safe:

@("UriUtilsTests.encodePath")
unittest
{
    assert(UriUtils.encodePath("/foo/bar") == "/foo/bar");
    assert(UriUtils.encodePath("/foo bar") == "/foo%20bar");
    assert(UriUtils.encodePath("/Zürich") == "/Z%C3%BCrich");
}

@("UriUtilsTests.encodePathSegment")
unittest
{
    assert(UriUtils.encodePathSegment("foobar") == "foobar");
    assert(UriUtils.encodePathSegment("/foo/bar") == "%2Ffoo%2Fbar");
}

@("UriUtilsTests.encodeQuery")
unittest
{
    assert(UriUtils.encodeQuery("foobar") == "foobar");
    assert(UriUtils.encodeQuery("foo bar") == "foo%20bar");
    assert(UriUtils.encodeQuery("foobar/+") == "foobar/+");
    assert(UriUtils.encodeQuery("Tōkyō") == "T%C5%8Dky%C5%8D");
}

@("UriUtilsTests.encodeQueryParam")
unittest
{
    assert(UriUtils.encodeQueryParam("foobar") == "foobar");
    assert(UriUtils.encodeQueryParam("foo bar") == "foo%20bar");
    assert(UriUtils.encodeQueryParam("foo&bar") == "foo%26bar");
}

@("UriUtilsTests.encodeFragment")
unittest
{
    assert(UriUtils.encodeFragment("foobar") == "foobar");
    assert(UriUtils.encodeFragment("foo bar") == "foo%20bar");
    assert(UriUtils.encodeFragment("foobar/") == "foobar/");
}

@("UriUtilsTests.encode")
unittest
{
    assert(UriUtils.encode("foo") == "foo");
    assert(UriUtils.encode("https://example.com/foo bar") == "https%3A%2F%2Fexample.com%2Ffoo%20bar");
}

@("UriUtilsTests.decode")
unittest
{
    assert(UriUtils.decode("") == "");
    assert(UriUtils.decode("foobar") == "foobar");
    assert(UriUtils.decode("foo%20bar") == "foo bar");
    assert(UriUtils.decode("foo%2bbar") == "foo+bar");
    assert(UriUtils.decode("T%C5%8Dky%C5%8D") == "Tōkyō");
    assert(UriUtils.decode("/Z%C3%BCrich") == "/Zürich");
    assert(UriUtils.decode("Tōkyō") == "Tōkyō");
    assert(UriUtils.decode("%20’") == " ’");
    assert(UriUtils.decode("śpřìńġ") == "śpřìńġ");
    assert(UriUtils.decode("%20śpřìńġ") == " śpřìńġ");
}

@("UriUtilsTests.decodeInvalidSequence")
unittest
{
    foreach (invalid; ["foo%2", "foo%", "%", "%zz"])
    {
        bool threw;
        try
            UriUtils.decode(invalid);
        catch (IllegalArgumentException)
            threw = true;
        assert(threw, invalid);
    }
}

// encodeScheme, encodeUserInfo, encodeHost, encodePort and extractFileExtension are not ported to flint.web's
// UriUtils yet. Their upstream cases compile once they are (version FlintUriUtilsComplete).
version (FlintUriUtilsComplete)
{
    @("UriUtilsTests.encodeScheme")
    unittest
    {
        assert(UriUtils.encodeScheme("foobar+-.") == "foobar+-.");
        assert(UriUtils.encodeScheme("foo bar") == "foo%20bar");
    }

    @("UriUtilsTests.encodeUserInfo")
    unittest
    {
        assert(UriUtils.encodeUserInfo("foobar:") == "foobar:");
        assert(UriUtils.encodeUserInfo("foo bar") == "foo%20bar");
    }

    @("UriUtilsTests.encodeHost")
    unittest
    {
        assert(UriUtils.encodeHost("foobar") == "foobar");
        assert(UriUtils.encodeHost("foo bar") == "foo%20bar");
    }

    @("UriUtilsTests.encodePort")
    unittest
    {
        assert(UriUtils.encodePort("80") == "80");
    }

    @("UriUtilsTests.extractFileExtension")
    unittest
    {
        static immutable paths = [
            "index.html", "/index.html", "/products/view.html", "/products/view.html#/a",
            "/products/view.html#/path/a", "/products/view.html#/path/a.do",
            "/products/view.html#aaa?bbb", "/products/view.html#aaa.xml?bbb",
            "/products/view.html?param=a", "/products/view.html?param=/path/a",
            "/products/view.html?param=/path/a.do", "/products/view.html?param=/path/a#/path/a",
            "/products/view.html?param=/path/a.do#/path/a.do",
            "/products;q=11/view.html?param=/path/a.do",
            "/products;q=11/view.html;r=22?param=/path/a.do",
            "/products;q=11/view.html;r=22;s=33?param=/path/a.do", "/products/.html"
        ];
        foreach (path; paths)
            assert(UriUtils.extractFileExtension(path) == "html", path);
    }
}
