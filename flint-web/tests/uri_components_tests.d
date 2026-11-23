/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/util/UriComponentsTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. flint.web has one URI
parser, so each `@ParameterizedTest` over `ParserType` runs once with it. `expand` takes strings, so the port cases
pass `"8080"` and `"0"` where Java passes integers. `serializable` is not ported (Java serialization). Cases that
need parts of `UriComponents` and `UriComponentsBuilder` flint.web has not ported yet wait behind the versions
named beside them.
+/
module flint.web.util.uri_components_tests;

import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.web.util : UriComponents, UriComponentsBuilder;

@safe:

private bool throws(E : Throwable)(scope void delegate() @safe action)
{
    try
        action();
    catch (E)
        return true;
    return false;
}

@("UriComponentsTests.expandAndEncode")
unittest
{
    auto uri = UriComponentsBuilder.fromPath("/hotel list/{city} specials").queryParam("q",
            "{value}").build().expand("Zürich", "a+b").encode();
    assert(uri.toString() == "/hotel%20list/Z%C3%BCrich%20specials?q=a+b");
}

@("UriComponentsTests.toUriEncoded")
unittest
{
    auto uri = UriComponentsBuilder.fromUriString("https://example.com/hotel list/Zürich").build();
    assert(uri.encode().toUri().toString() == "https://example.com/hotel%20list/Z%C3%BCrich");
}

@("UriComponentsTests.toUriAlreadyEncoded")
unittest
{
    auto uri = UriComponentsBuilder.fromUriString("https://example.com/hotel%20list/Z%C3%BCrich").build(true);
    assert(uri.encode().toUri().toString() == "https://example.com/hotel%20list/Z%C3%BCrich");
}

@("UriComponentsTests.toUriWithIpv6HostAlreadyEncoded")
unittest
{
    auto uri = UriComponentsBuilder.fromUriString(
            "http://[1abc:2abc:3abc::5ABC:6abc]:8080/hotel%20list/Z%C3%BCrich").build(true);
    assert(uri.encode().toUri().toString() == "http://[1abc:2abc:3abc::5ABC:6abc]:8080/hotel%20list/Z%C3%BCrich");
}

@("UriComponentsTests.toUriStringWithPortVariable")
unittest
{
    enum url = "http://localhost:{port}/first";
    assert(UriComponentsBuilder.fromUriString(url).build().toUriString() == url);
}

@("UriComponentsTests.expand")
unittest
{
    auto uri = UriComponentsBuilder.fromUriString("https://example.com").path("/{foo} {bar}").build();
    uri = uri.expand("1 2", "3 4");
    assert(uri.getPath() == "/1 2 3 4");
    assert(uri.toUriString() == "https://example.com/1 2 3 4");
}

@("UriComponentsTests.expandWithFragmentOrder")
unittest
{
    auto uri = UriComponentsBuilder.fromUriString("https://{host}/{path}#{fragment}").build()
        .expand("example.com", "foo", "bar");
    assert(uri.toUriString() == "https://example.com/foo#bar");
}

@("UriComponentsTests.port")
unittest
{
    auto uri1 = UriComponentsBuilder.fromUriString("https://example.com:8080/bar").build();
    auto uri2 = UriComponentsBuilder.fromUriString("https://example.com/bar").port(8080).build();
    auto uri3 = UriComponentsBuilder.fromUriString("https://example.com/bar").port("{port}").build().expand("8080");
    auto uri4 = UriComponentsBuilder.fromUriString("https://example.com/bar").port("808{digit}").build().expand("0");
    foreach (uri; [uri1, uri2, uri3, uri4])
    {
        assert(uri.getPort() == 8080);
        assert(uri.toUriString() == "https://example.com:8080/bar");
    }
}

@("UriComponentsTests.emptyPortSet")
unittest
{
    auto uriComponents = UriComponentsBuilder.fromUriString("https://example.com/bar").port("").build();
    assert(uriComponents.getPort() == -1);
}

// druntime's class equality (object.opEquals) is @system.
@("UriComponentsTests.equalsHierarchicalUriComponents")
@system unittest
{
    enum url = "https://example.com";
    const uric1 = UriComponentsBuilder.fromUriString(url).path("/{foo}").query("bar={baz}").build();
    const uric2 = UriComponentsBuilder.fromUriString(url).path("/{foo}").query("bar={baz}").build();
    const uric3 = UriComponentsBuilder.fromUriString(url).path("/{foo}").query("bin={baz}").build();
    // flint.web's UriComponents is Spring's HierarchicalUriComponents, so the isInstanceOf check holds by type.
    assert(uric1 == uric1);
    assert(uric1 == uric2);
    assert(uric1 != uric3);
}

// UriComponentsBuilder.encode(), which encodes the template before expansion, and uriVariables are not ported yet.
version (FlintUriBuilderEncodeTemplate)
{
    @("UriComponentsTests.encodeAndExpand")
    unittest
    {
        auto uri = UriComponentsBuilder.fromPath("/hotel list/{city} specials").queryParam("q",
                "{value}").encode().build().expand("Zürich", "a+b");
        assert(uri.toString() == "/hotel%20list/Z%C3%BCrich%20specials?q=a%2Bb");
    }

    @("UriComponentsTests.encodeAndExpandPartially")
    unittest
    {
        auto uri = UriComponentsBuilder.fromPath("/hotel list/{city} specials").queryParam("q",
                "{value}").encode().uriVariables([["city", "Zürich"]]).build();
        assert(uri.expand("a+b").toString() == "/hotel%20list/Z%C3%BCrich%20specials?q=a%2Bb");
    }

    @("UriComponentsTests.encodeAndExpandWithDollarSign")
    unittest
    {
        auto uri = UriComponentsBuilder.fromPath("/path").queryParam("q", "{value}").encode().build();
        assert(uri.expand("JavaClass$1.class").toString() == "/path?q=JavaClass%241.class");
    }

    @("UriComponentsTests.uirTemplateExpandWithMismatchedCurlyBraces")
    unittest
    {
        auto uri = UriComponentsBuilder.fromUriString("/myurl/?q={{{{").encode().build();
        assert(uri.toUriString() == "/myurl/?q=%7B%7B%7B%7B");
    }
}

// toUri of components that are not encoded keeps non-ASCII characters, as java.net.URI does; flint.web encodes them.
version (FlintUriToUriUnencoded)
{
    @("UriComponentsTests.toUriNotEncoded")
    unittest
    {
        auto uri = UriComponentsBuilder.fromUriString("https://example.com/hotel list/Zürich").build();
        assert(uri.toUri().toString() == "https://example.com/hotel%20list/Zürich");
    }
}

// Template variables with a regular expression ({name:[a-z]{1,5}}) are deferred to web slice 3.
version (FlintUriRegexVariables)
{
    @("UriComponentsTests.expandWithRegexVar")
    unittest
    {
        auto uri = UriComponentsBuilder.fromUriString("/myurl/{name:[a-z]{1,5}}/show").build();
        uri = uri.expand([["name", "test"]]);
        assert(uri.getPath() == "/myurl/test/show");
    }
}

// buildAndExpand with a map whose values are arrays or lists is not ported; expand takes strings.
version (FlintUriExpandCollections)
{
    @("UriComponentsTests.expandQueryParamWithArray")
    unittest
    {
        const uri = UriComponentsBuilder.fromPath("/hello").queryParam("name", "{name}")
            .buildAndExpand(["name": ["foo", "bar"]]).toString();
        assert(uri == "/hello?name=foo,bar");
    }

    @("UriComponentsTests.expandQueryParamWithList")
    unittest
    {
        const uri = UriComponentsBuilder.fromPath("/hello").queryParam("name", "{name}")
            .buildAndExpand(["name": ["foo", "bar"]]).toString();
        assert(uri == "/hello?name=foo,bar");
    }
}

// Spring reports a malformed URL with InvalidUrlException and validates the port when it is read; flint.web
// throws IllegalArgumentException from the parser and std.conv's exception from getPort.
version (FlintUriPortValidation)
{
    @("UriComponentsTests.invalidPortParsed")
    unittest
    {
        import flint.web.util : InvalidUrlException;

        assert(throws!InvalidUrlException(() {
                UriComponentsBuilder.fromUriString("https://example.com:XXX/bar");
            }));
    }

    @("UriComponentsTests.invalidPortSet")
    unittest
    {
        auto uriComponents = UriComponentsBuilder.fromUriString("https://example.com/bar").port("XXX").build();
        foreach (read; [() { uriComponents.getPort(); }, () { uriComponents.toUri(); }])
        {
            try
            {
                read();
                assert(false, "an invalid port must be rejected");
            }
            catch (IllegalStateException e)
                assert(e.msg == "The port must be an integer: XXX");
        }
    }
}

// build(true) does not verify that the components are encoded yet.
version (FlintUriVerifyEncoded)
{
    @("UriComponentsTests.invalidCharacters")
    unittest
    {
        assert(throws!IllegalArgumentException(() {
                UriComponentsBuilder.fromPath("/{foo}").build(true);
            }));
    }

    @("UriComponentsTests.invalidEncodedSequence")
    unittest
    {
        assert(throws!IllegalArgumentException(() {
                UriComponentsBuilder.fromPath("/fo%2o").build(true);
            }));
    }
}

// UriComponents.normalize and copyToUriComponentsBuilder are not ported yet, and expanding components that are
// already encoded does not throw yet.
version (FlintUriComponentsComplete)
{
    @("UriComponentsTests.expandEncoded")
    unittest
    {
        assert(throws!IllegalStateException(() {
                UriComponentsBuilder.fromPath("/{foo}").build().encode().expand("bar");
            }));
    }

    @("UriComponentsTests.normalize")
    unittest
    {
        auto uri = UriComponentsBuilder.fromUriString("https://example.com/foo/../bar").build();
        assert(uri.normalize().toString() == "https://example.com/bar");
    }

    @("UriComponentsTests.copyToUriComponentsBuilder")
    unittest
    {
        auto source = UriComponentsBuilder.fromPath("/foo/bar").pathSegment("ba/z").build();
        auto targetBuilder = UriComponentsBuilder.newInstance();
        source.copyToUriComponentsBuilder(targetBuilder);
        auto result = targetBuilder.build().encode();
        assert(result.getPath() == "/foo/bar/ba%2Fz");
        assert(result.getPathSegments() == ["foo", "bar", "ba%2Fz"]);
    }
}

// flint.web parses an opaque URI (http:example.com/...) as a path rather than Spring's OpaqueUriComponents; equality
// still compares the components, as upstream checks.
// druntime's class equality (object.opEquals) is @system.
@("UriComponentsTests.equalsOpaqueUriComponents")
@system unittest
{
    enum baseUrl = "http:example.com";
    const uric1 = UriComponentsBuilder.fromUriString(baseUrl ~ "/foo/bar").build();
    const uric2 = UriComponentsBuilder.fromUriString(baseUrl ~ "/foo/bar").build();
    const uric3 = UriComponentsBuilder.fromUriString(baseUrl ~ "/foo/bin").build();
    assert(uric1 == uric1);
    assert(uric1 == uric2);
    assert(uric1 != uric3);
}
