/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/accept/HeaderContentNegotiationStrategyTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` returns, and lists are D arrays (R10). The test lives with flint.mock.web's
`MockHttpServletRequest` in flint:framework-test, which depends on flint:web.
+/
module flint.web.header_content_negotiation_strategy_tests;

import flint.http : MediaType;
import flint.mock.web : MockHttpServletRequest;
import flint.web : HttpMediaTypeNotAcceptableException;
import flint.web.accept : HeaderContentNegotiationStrategy;
import flint.web.context.request : NativeWebRequest, ServletWebRequest;
import std.algorithm.iteration : map;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.array : array, replicate;
import std.conv : to;

@safe:

private struct Fixture
{
    HeaderContentNegotiationStrategy strategy;
    MockHttpServletRequest servletRequest;
    NativeWebRequest webRequest;
}

private Fixture setup()
{
    Fixture f;
    f.strategy = new HeaderContentNegotiationStrategy();
    f.servletRequest = new MockHttpServletRequest();
    f.webRequest = new ServletWebRequest(f.servletRequest);
    return f;
}

/// The exception `action` throws, or `null`.
private E thrown(E : Exception)(scope void delegate() @safe action)
{
    try
        action();
    catch (E ex)
        return ex;
    return null;
}

private string[] strings(MediaType[] mediaTypes)
{
    return mediaTypes.map!(m => m.to!string).array;
}

@("HeaderContentNegotiationStrategyTests.resolveMediaTypes")
unittest
{
    auto f = setup();
    f.servletRequest.addHeader("Accept", "text/plain; q=0.5, text/html, text/x-dvi; q=0.8, text/x-c");
    auto mediaTypes = f.strategy.resolveMediaTypes(f.webRequest);

    assert(strings(mediaTypes) == ["text/html", "text/x-c", "text/x-dvi;q=0.8", "text/plain;q=0.5"]);
}

@("HeaderContentNegotiationStrategyTests.resolveMediaTypesFromMultipleHeaderValues")
unittest
{
    auto f = setup();
    f.servletRequest.addHeader("Accept", "text/plain; q=0.5, text/html");
    f.servletRequest.addHeader("Accept", "text/x-dvi; q=0.8, text/x-c");
    auto mediaTypes = f.strategy.resolveMediaTypes(f.webRequest);

    assert(strings(mediaTypes) == ["text/html", "text/x-c", "text/x-dvi;q=0.8", "text/plain;q=0.5"]);
}

@("HeaderContentNegotiationStrategyTests.resolveMediaTypesWithMaxElements")
unittest
{
    auto f = setup();
    const acceptHeaderValue = "text/plain, text/html,".replicate(25);
    f.servletRequest.addHeader("Accept", acceptHeaderValue);
    auto mediaTypes = f.strategy.resolveMediaTypes(f.webRequest);

    assert(mediaTypes.length == 50);
    string[] distinct;
    foreach (s; strings(mediaTypes))
        if (!distinct.canFind(s))
            distinct ~= s;
    assert(distinct == ["text/plain", "text/html"]);
}

@("HeaderContentNegotiationStrategyTests.resolveMediaTypesWithTooManyElements")
unittest
{
    auto f = setup();
    const acceptHeaderValue = "text/plain,".replicate(51);
    f.servletRequest.addHeader("Accept", acceptHeaderValue);
    auto ex = thrown!HttpMediaTypeNotAcceptableException({
        f.strategy.resolveMediaTypes(f.webRequest);
    });
    assert(ex !is null);
    assert(ex.getMessage().startsWith("Could not parse 'Accept' header"));
    assert(ex.getMessage().endsWith("Too many elements"));
}

@("HeaderContentNegotiationStrategyTests.resolveMediaTypesParseError")
unittest
{
    auto f = setup();
    f.servletRequest.addHeader("Accept", "textplain; q=0.5");
    auto ex = thrown!HttpMediaTypeNotAcceptableException({
        f.strategy.resolveMediaTypes(f.webRequest);
    });
    assert(ex !is null);
    assert(ex.getMessage().startsWith("Could not parse 'Accept' header"));
    assert(ex.getMessage().canFind("Invalid mime type"));
}
