/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/RequestMappingInfoTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; each
`@PathPatternsParameterizedTest` is one unittest that loops over the named builders of `pathPatternsArguments()`,
whose `AntPathMatcher` variant waits behind the `PathMatcher` gate. flint.web.servlet's `RequestMappingInfo` is
built from an AOT mapping row's condition strings rather than through `RequestMappingInfo.Builder`, so a test-side
`Builder` (`paths(...)` ... `build()`) collects the same values and calls that constructor; flint.web has no
`RequestMethod` enum, so its constants are a test-side string enum. `PathPatternsTestUtils.initRequest` only builds
the request, as the port resolves the lookup path from the request itself, and `Collections.shuffle` plus
`List.sort` is `randomShuffle` plus a stable `sort`. The test lives with flint.mock.web's `MockHttpServletRequest`
in flint:framework-test. Cases that need unported features, or where the port gives a different result, wait
behind version gates.
+/
module flint.web.request_mapping_info_tests;

import flint.http : HttpHeaders;
import flint.mock.web : MockHttpServletRequest;
import flint.web.servlet.mvc.method : RequestMappingInfo;

@safe:

/// `RequestMethod`.
private enum RequestMethod : string
{
    GET = "GET",
    HEAD = "HEAD",
    POST = "POST",
    OPTIONS = "OPTIONS",
}

private alias GET = RequestMethod.GET;
private alias HEAD = RequestMethod.HEAD;

/// `RequestMappingInfo.Builder`: each call replaces that condition's values, as Spring's builder does.
private final class Builder
{
    private string[] paths_;
    private string[] methods_;
    private string[] params_;
    private string[] headers_;
    private string[] consumes_;
    private string[] produces_;
    private string mappingName_;

    Builder paths(string[] paths...)
    {
        paths_ = paths.dup;
        return this;
    }

    Builder methods(RequestMethod[] methods...)
    {
        methods_ = null;
        foreach (m; methods)
            methods_ ~= m;
        return this;
    }

    Builder params(string[] params...)
    {
        params_ = params.dup;
        return this;
    }

    Builder headers(string[] headers...)
    {
        headers_ = headers.dup;
        return this;
    }

    Builder consumes(string[] consumes...)
    {
        consumes_ = consumes.dup;
        return this;
    }

    Builder produces(string[] produces...)
    {
        produces_ = produces.dup;
        return this;
    }

    Builder mappingName(string name)
    {
        mappingName_ = name;
        return this;
    }

    RequestMappingInfo build()
    {
        return new RequestMappingInfo(paths_, methods_, params_, headers_, consumes_, produces_, mappingName_);
    }
}

/// `RequestMappingInfo.paths(String...)`.
private Builder paths(string[] paths...)
{
    return new Builder().paths(paths);
}

private struct NamedBuilder
{
    string name;
    Builder builder;
}

private NamedBuilder[] pathPatternsArguments()
{
    NamedBuilder[] result = [NamedBuilder("PathPatternParser", paths())];
    // flint.web.servlet's RequestMappingInfo matches parsed PathPatterns only (no BuilderConfiguration.setPathMatcher).
    version (FlintPathMatcher)
    {
        import flint.util : AntPathMatcher;

        auto config = new RequestMappingInfo.BuilderConfiguration();
        config.setPathMatcher(new AntPathMatcher());
        result ~= NamedBuilder("AntPathMatcher", paths().options(config));
    }
    return result;
}

/// `PathPatternsTestUtils.initRequest`: Spring also caches the parsed `RequestPath` or the lookup path.
private MockHttpServletRequest initRequest(string method, string requestUri, bool /+ parsedPatterns +/ )
{
    return new MockHttpServletRequest(method, requestUri);
}

/// `Collections.shuffle(list); list.sort(comparator)`.
private RequestMappingInfo[] shuffleAndSort(RequestMappingInfo[] list, MockHttpServletRequest request)
{
    import std.algorithm.sorting : sort;
    import std.algorithm.mutation : SwapStrategy;
    import std.random : randomShuffle;

    auto result = list.dup;
    randomShuffle(result);
    result.sort!((info, otherInfo) => info.compareTo(otherInfo, request) < 0, SwapStrategy.stable);
    return result;
}

// flint.web.servlet's RequestMappingInfo exposes no condition objects (getXxxCondition, getPatternValues) and has no
// combine, mutate or BuilderConfiguration.
version (FlintRequestMappingInfoConditions)
{
    @("RequestMappingInfoTests.createEmpty")
    unittest
    {
        foreach (named; pathPatternsArguments())
        {
            auto infoBuilder = named.builder;

            // gh-22543
            auto info = infoBuilder.build();
            assert(info.getPatternValues() == [""], named.name);
            assert(info.getMethodsCondition().getMethods().length == 0, named.name);
            assert(info.getParamsCondition() !is null, named.name);
            assert(info.getHeadersCondition() !is null, named.name);
            assert(info.getConsumesCondition().isEmpty(), named.name);
            assert(info.getProducesCondition().isEmpty(), named.name);
            assert(info.getCustomCondition() is null, named.name);

            auto anotherInfo = infoBuilder.build();
            assert(info.getActivePatternsCondition() is anotherInfo.getActivePatternsCondition(), named.name);
            assert(info.getPatternsCondition() is anotherInfo.getPatternsCondition(), named.name);
            assert(info.getMethodsCondition() is anotherInfo.getMethodsCondition(), named.name);
            assert(info.getParamsCondition() is anotherInfo.getParamsCondition(), named.name);
            assert(info.getHeadersCondition() is anotherInfo.getHeadersCondition(), named.name);
            assert(info.getConsumesCondition() is anotherInfo.getConsumesCondition(), named.name);
            assert(info.getProducesCondition() is anotherInfo.getProducesCondition(), named.name);
            assert(info.getCustomCondition() is anotherInfo.getCustomCondition(), named.name);

            auto result = info.combine(anotherInfo);
            assert(result.getPatternValues() == ["", "/"], named.name);
            assert(info.getMethodsCondition() is result.getMethodsCondition(), named.name);
            assert(info.getParamsCondition() is result.getParamsCondition(), named.name);
            assert(info.getHeadersCondition() is result.getHeadersCondition(), named.name);
            assert(info.getConsumesCondition() is result.getConsumesCondition(), named.name);
            assert(info.getProducesCondition() is result.getProducesCondition(), named.name);
            assert(info.getCustomCondition() is result.getCustomCondition(), named.name);
        }
    }

    @("RequestMappingInfoTests.pathPatternByDefault")
    unittest
    {
        // gh-31662
        auto info = paths().build();
        assert(info.getPathPatternsCondition() !is null);
        assert(info.getPatternsCondition() is null);
    }
}

// Needs getPathPatternsCondition; the `/foo*` patterns also need partial path segments (the parser rejects them),
// and the comparison an opEquals.
version (FlintRequestMappingInfoConditions)
{
    // Class `==` (AssertJ's `isEqualTo`) goes through Object.opEquals, which is @system.
    @("RequestMappingInfoTests.matchPatternsCondition")
    @system unittest
    {
        foreach (named; pathPatternsArguments())
        {
            auto builder = named.builder;
            const useParsedPatterns = builder.build().getPathPatternsCondition() !is null;
            auto request = initRequest("GET", "/foo", useParsedPatterns);

            auto info = builder.paths("/foo*", "/bar").build();
            auto expected = builder.paths("/foo*").build();

            assert(info.getMatchingCondition(request) == expected, named.name);

            info = builder.paths("/**", "/foo*", "/foo").build();
            expected = builder.paths("/foo", "/foo*", "/**").build();

            assert(info.getMatchingCondition(request) == expected, named.name);
        }
    }
}

@("RequestMappingInfoTests.matchParamsCondition")
unittest
{
    auto request = initRequest("GET", "/foo", true);
    request.setParameter("foo", "bar");

    auto info = paths("/foo").params("foo=bar").build();
    auto match = info.getMatchingCondition(request);

    assert(match !is null);

    info = paths("/foo").params("foo!=bar").build();
    match = info.getMatchingCondition(request);

    assert(match is null);
}

@("RequestMappingInfoTests.matchHeadersCondition")
unittest
{
    auto request = initRequest("GET", "/foo", true);
    request.addHeader("foo", "bar");

    auto info = paths("/foo").headers("foo=bar").build();
    auto match = info.getMatchingCondition(request);

    assert(match !is null);

    info = paths("/foo").headers("foo!=bar").build();
    match = info.getMatchingCondition(request);

    assert(match is null);
}

@("RequestMappingInfoTests.matchConsumesCondition")
unittest
{
    auto request = initRequest("GET", "/foo", true);
    request.setContentType("text/plain");

    auto info = paths("/foo").consumes("text/plain").build();
    auto match = info.getMatchingCondition(request);

    assert(match !is null);

    info = paths("/foo").consumes("application/xml").build();
    match = info.getMatchingCondition(request);

    assert(match is null);
}

@("RequestMappingInfoTests.matchProducesCondition")
unittest
{
    auto request = initRequest("GET", "/foo", true);
    request.addHeader("Accept", "text/plain");

    auto info = paths("/foo").produces("text/plain").build();
    auto match = info.getMatchingCondition(request);

    assert(match !is null);

    info = paths("/foo").produces("application/xml").build();
    match = info.getMatchingCondition(request);

    assert(match is null);
}

@("RequestMappingInfoTests.matchCustomCondition")
unittest
{
    auto request = initRequest("GET", "/foo", true);
    request.setParameter("foo", "bar");

    auto info = paths("/foo").params("foo=bar").build();
    auto match = info.getMatchingCondition(request);

    assert(match !is null);

    info = paths("/foo").params("foo!=bar").params("foo!=bar").build();
    match = info.getMatchingCondition(request);

    assert(match is null);
}

@("RequestMappingInfoTests.compareToWithImplicitVsExplicitHttpMethodDeclaration")
unittest
{
    auto noMethods = paths().build();
    auto oneMethod = paths().methods(GET).build();
    auto oneMethodOneParam = paths().methods(GET).params("foo").build();

    auto request = initRequest("GET", "/", true);

    const list = shuffleAndSort([noMethods, oneMethod, oneMethodOneParam], request);

    assert(list.length == 3);
    assert(list[0] is oneMethodOneParam);
    assert(list[1] is oneMethod);
    assert(list[2] is noMethods);
}

// Behaviour: for a HEAD request the port's compareTo does not compare methods first (Spring prefers an explicit HEAD
// mapping), so the GET mapping with `produces` sorts before the HEAD mapping.
version (FlintRequestMappingInfoHeadPrecedence)
{
    @("RequestMappingInfoTests.compareToWithHttpHeadMapping")
    unittest
    {
        // SPR-14383
        auto request = initRequest("GET", "/", true);
        request.setMethod("HEAD");
        request.addHeader("Accept", "application/json");

        auto noMethods = paths().build();
        auto getMethod = paths().methods(GET).produces("application/json").build();
        auto headMethod = paths().methods(HEAD).build();

        const list = shuffleAndSort([noMethods, getMethod, headMethod], request);

        assert(list.length == 3);
        assert(list[0] is headMethod);
        assert(list[1] is getMethod);
        assert(list[2] is noMethods);
    }
}

// flint.web.servlet's RequestMappingInfo has no opEquals or toHash (equality by conditions).
version (FlintRequestMappingInfoEquals)
{
    // Class `==` (AssertJ's `isEqualTo`) goes through Object.opEquals, which is @system.
    @("RequestMappingInfoTests.equalsMethod")
    @system unittest
    {
        foreach (named; pathPatternsArguments())
        {
            auto infoBuilder = named.builder;
            auto info1 = infoBuilder.paths("/foo").methods(GET).params("foo=bar",
                    "customFoo=customBar").headers("foo=bar").consumes("text/plain").produces("text/plain").build();

            auto info2 = infoBuilder.paths("/foo").methods(GET).params("foo=bar",
                    "customFoo=customBar").headers("foo=bar").consumes("text/plain").produces("text/plain").build();

            assert(info2 == info1, named.name);
            assert(info2.toHash() == info1.toHash(), named.name);

            info2 = infoBuilder.paths("/foo", "/NOOOOOO").methods(GET).params("foo=bar",
                    "customFoo=customBar").headers("foo=bar").consumes("text/plain").produces("text/plain").build();

            assert(info1 != info2, named.name);
            assert(info2.toHash() != info1.toHash(), named.name);

            info2 = infoBuilder.paths("/foo").methods(GET, RequestMethod.POST).params("foo=bar",
                    "customFoo=customBar").headers("foo=bar").consumes("text/plain").produces("text/plain").build();

            assert(info1 != info2, named.name);
            assert(info2.toHash() != info1.toHash(), named.name);

            info2 = infoBuilder.paths("/foo").methods(GET).params("/NOOOOOO", "customFoo=customBar")
                .headers("foo=bar").consumes("text/plain").produces("text/plain").build();

            assert(info1 != info2, named.name);
            assert(info2.toHash() != info1.toHash(), named.name);

            info2 = infoBuilder.paths("/foo").methods(GET).params("foo=bar", "customFoo=customBar")
                .headers("/NOOOOOO").consumes("text/plain").produces("text/plain").build();

            assert(info1 != info2, named.name);
            assert(info2.toHash() != info1.toHash(), named.name);

            info2 = infoBuilder.paths("/foo").methods(GET).params("foo=bar", "customFoo=customBar")
                .headers("foo=bar").consumes("text/NOOOOOO").produces("text/plain").build();

            assert(info1 != info2, named.name);
            assert(info2.toHash() != info1.toHash(), named.name);

            info2 = infoBuilder.paths("/foo").methods(GET).params("foo=bar", "customFoo=customBar")
                .headers("foo=bar").consumes("text/plain").produces("text/NOOOOOO").build();

            assert(info1 != info2, named.name);
            assert(info2.toHash() != info1.toHash(), named.name);

            info2 = infoBuilder.paths("/foo").methods(GET).params("foo=bar", "customFoo=NOOOOOO")
                .headers("foo=bar").consumes("text/plain").produces("text/plain").build();

            assert(info1 != info2, named.name);
            assert(info2.toHash() != info1.toHash(), named.name);
        }
    }
}

@("RequestMappingInfoTests.preFlightRequest")
unittest
{
    auto request = initRequest("OPTIONS", "/foo", true);
    request.addHeader(HttpHeaders.ORIGIN, "https://domain.com");
    request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "POST");

    auto info = paths("/foo").methods(RequestMethod.POST).build();
    auto match = info.getMatchingCondition(request);
    assert(match !is null);

    info = paths("/foo").methods(RequestMethod.OPTIONS).build();
    match = info.getMatchingCondition(request);
    assert(match is null, "Pre-flight should match the ACCESS_CONTROL_REQUEST_METHOD");
}

version (FlintRequestMappingInfoConditions)
{
    // Class `==` (AssertJ's `isEqualTo`) goes through Object.opEquals, which is @system.
    @("RequestMappingInfoTests.mutate")
    @system unittest
    {
        import flint.http : MediaType;
        import flint.web.util.pattern : PathPatternParser;

        auto options = new RequestMappingInfo.BuilderConfiguration();
        options.setPatternParser(new PathPatternParser());

        auto info1 = paths("/foo").methods(GET).headers("h1=hv1").params("q1=qv1")
            .consumes("application/json").produces("application/json").mappingName("testMapping")
            .options(options).build();

        auto info2 = info1.mutate().produces("application/hal+json").build();

        assert(info2.getName() == info1.getName());
        assert(info2.getPatternsCondition() is null);
        assert(info2.getPathPatternsCondition() == info1.getPathPatternsCondition());
        assert(info2.getHeadersCondition() == info1.getHeadersCondition());
        assert(info2.getParamsCondition() == info1.getParamsCondition());
        assert(info2.getConsumesCondition() == info1.getConsumesCondition());
        assert(info2.getProducesCondition()
                .getProducibleMediaTypes() == [MediaType.parseMediaType("application/hal+json")]);
    }
}
