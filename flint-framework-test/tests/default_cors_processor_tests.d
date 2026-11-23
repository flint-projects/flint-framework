/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/cors/DefaultCorsProcessorTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the `@BeforeEach`
fields become a `Fixture` that `setup` returns. The test lives with flint.mock.web's `MockHttpServletRequest` and
`MockHttpServletResponse` in flint:framework-test, which depends on flint:web. Every case runs.
+/
module flint.web.default_cors_processor_tests;

import flint.http : HttpHeaders, HttpMethod;
import flint.jakarta.servlet.http : HttpServletResponse;
import flint.java.lang : IllegalArgumentException;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.cors : CorsConfiguration, DefaultCorsProcessor;
import std.algorithm.searching : canFind, count;

@safe:

private struct Fixture
{
    MockHttpServletRequest request;
    MockHttpServletResponse response;
    DefaultCorsProcessor processor;
    CorsConfiguration conf;
}

private Fixture setup()
{
    Fixture f;
    f.request = new MockHttpServletRequest();
    f.request.setRequestURI("/test.html");
    f.request.setServerName("domain1.example");
    f.conf = new CorsConfiguration();
    f.response = new MockHttpServletResponse();
    f.response.setStatus(HttpServletResponse.SC_OK);
    f.processor = new DefaultCorsProcessor();
    return f;
}

private bool throws(E : Throwable)(scope void delegate() @safe action)
{
    try
        action();
    catch (E)
        return true;
    return false;
}

/// AssertJ's `contains`: every expected value is present.
private bool containsAll(const(string)[] values, const(string)[] expected...)
{
    foreach (e; expected)
        if (!values.canFind(e))
            return false;
    return true;
}

/// AssertJ's `containsOnlyOnce`: every expected value is present exactly once.
private bool containsOnlyOnce(const(string)[] values, const(string)[] expected...)
{
    foreach (e; expected)
        if (values.count(e) != 1)
            return false;
    return true;
}

@("DefaultCorsProcessorTests.requestWithoutOriginHeader")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.GET.name());

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.sameOriginRequest")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.GET.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "http://domain1.example");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.actualRequestWithOriginHeader")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.GET.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_FORBIDDEN);
}

@("DefaultCorsProcessorTests.actualRequestWithOriginHeaderAndNullConfig")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.GET.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");

    f.processor.processRequest(null, f.request, f.response);
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.actualRequestWithOriginHeaderAndAllowedOrigin")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.GET.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.conf.addAllowedOrigin("*");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN) == "*");
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_MAX_AGE));
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_EXPOSE_HEADERS));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.actualRequestCredentials")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.GET.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.conf.addAllowedOrigin("https://domain1.com");
    f.conf.addAllowedOrigin("https://domain2.com");
    f.conf.addAllowedOrigin("http://domain3.example");
    f.conf.setAllowCredentials(true);

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN) == "https://domain2.com");
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_CREDENTIALS));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_CREDENTIALS) == "true");
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.actualRequestCaseInsensitiveOriginMatch")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.GET.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.conf.addAllowedOrigin("https://DOMAIN2.com");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
}

@("DefaultCorsProcessorTests.actualRequestTrailingSlashOriginMatch")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.GET.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com/");
    f.conf.addAllowedOrigin("https://domain2.com");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
}

@("DefaultCorsProcessorTests.actualRequestMalformedOriginRejected")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.GET.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "http://*@:;");
    f.conf.addAllowedOrigin("https://domain2.com");

    const result = f.processor.processRequest(f.conf, f.request, f.response);
    assert(!result);
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_FORBIDDEN);
}

@("DefaultCorsProcessorTests.actualRequestExposedHeaders")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.GET.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.conf.addExposedHeader("header1");
    f.conf.addExposedHeader("header2");
    f.conf.addAllowedOrigin("https://domain2.com");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN) == "https://domain2.com");
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_EXPOSE_HEADERS));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_EXPOSE_HEADERS).canFind("header1"));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_EXPOSE_HEADERS).canFind("header2"));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preflightRequestWrongAllowedMethod")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "DELETE");
    f.conf.addAllowedOrigin("*");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_FORBIDDEN);
}

@("DefaultCorsProcessorTests.preflightRequestTestWithOriginButWithoutOtherHeaders")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_FORBIDDEN);
}

@("DefaultCorsProcessorTests.preflightRequestWithoutRequestMethod")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS, "Header1");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_FORBIDDEN);
}

@("DefaultCorsProcessorTests.preflightRequestWithRequestAndMethodHeaderButNoConfig")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS, "Header1");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_FORBIDDEN);
}

@("DefaultCorsProcessorTests.preflightRequestValidRequestAndConfig")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS, "Header1");
    f.conf.addAllowedOrigin("*");
    f.conf.addAllowedMethod("GET");
    f.conf.addAllowedMethod("PUT");
    f.conf.addAllowedHeader("header1");
    f.conf.addAllowedHeader("header2");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN) == "*");
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_METHODS));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_METHODS) == "GET,PUT");
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_MAX_AGE));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preflightRequestCredentials")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS, "Header1");
    f.conf.addAllowedOrigin("https://domain1.com");
    f.conf.addAllowedOrigin("https://domain2.com");
    f.conf.addAllowedOrigin("http://domain3.example");
    f.conf.addAllowedHeader("Header1");
    f.conf.setAllowCredentials(true);

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN) == "https://domain2.com");
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_CREDENTIALS));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_CREDENTIALS) == "true");
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preflightRequestAllowedHeaders")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS, "Header1, Header2");
    f.conf.addAllowedHeader("Header1");
    f.conf.addAllowedHeader("Header2");
    f.conf.addAllowedHeader("Header3");
    f.conf.addAllowedOrigin("https://domain2.com");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS).canFind("Header1"));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS).canFind("Header2"));
    assert(!f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS).canFind("Header3"));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preflightRequestAllowsAllHeaders")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS, "Header1, Header2");
    f.conf.addAllowedHeader("*");
    f.conf.addAllowedOrigin("https://domain2.com");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS).canFind("Header1"));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS).canFind("Header2"));
    assert(!f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS).canFind("*"));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preflightRequestWithNullConfig")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.conf.addAllowedOrigin("*");

    f.processor.processRequest(null, f.request, f.response);
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_METHODS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preventDuplicatedVaryHeaders")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.GET.name());
    f.response.addHeader(HttpHeaders.VARY, HttpHeaders.ORIGIN);
    f.response.addHeader(HttpHeaders.VARY, HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD);
    f.response.addHeader(HttpHeaders.VARY, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS);

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(containsOnlyOnce(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
}

@("DefaultCorsProcessorTests.actualRequestCredentialsWithWildcardOrigin")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.GET.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");

    f.conf.addAllowedOrigin("*");
    f.conf.setAllowCredentials(true);
    assert(throws!IllegalArgumentException({
            f.processor.processRequest(f.conf, f.request, f.response);
        }));

    f.conf.setAllowedOrigins(null);
    f.conf.addAllowedOriginPattern("*");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN) == "https://domain2.com");
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_CREDENTIALS));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_CREDENTIALS) == "true");
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preflightRequestCredentialsWithWildcardOrigin")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS, "Header1");
    f.conf.setAllowedOrigins(["https://domain1.com", "*", "http://domain3.example"]);
    f.conf.addAllowedHeader("Header1");
    f.conf.setAllowCredentials(true);

    assert(throws!IllegalArgumentException({
            f.processor.processRequest(f.conf, f.request, f.response);
        }));

    f.conf.setAllowedOrigins(null);
    f.conf.addAllowedOriginPattern("*");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN) == "https://domain2.com");
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preflightRequestPrivateNetworkWithWildcardOrigin")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS, "Header1");
    f.request.addHeader(DefaultCorsProcessor.ACCESS_CONTROL_REQUEST_PRIVATE_NETWORK, "true");
    f.conf.setAllowedOrigins(["https://domain1.com", "*", "http://domain3.example"]);
    f.conf.addAllowedHeader("Header1");
    f.conf.setAllowPrivateNetwork(true);

    assert(throws!IllegalArgumentException({
            f.processor.processRequest(f.conf, f.request, f.response);
        }));

    f.conf.setAllowedOrigins(null);
    f.conf.addAllowedOriginPattern("*");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(f.response.containsHeader(DefaultCorsProcessor.ACCESS_CONTROL_ALLOW_PRIVATE_NETWORK));
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN) == "https://domain2.com");
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preflightRequestWithoutAccessControlRequestPrivateNetwork")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.conf.addAllowedHeader("*");
    f.conf.addAllowedOrigin("https://domain2.com");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(!f.response.containsHeader(DefaultCorsProcessor.ACCESS_CONTROL_ALLOW_PRIVATE_NETWORK));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preflightRequestWithAccessControlRequestPrivateNetworkNotAllowed")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.request.addHeader(DefaultCorsProcessor.ACCESS_CONTROL_REQUEST_PRIVATE_NETWORK, "true");
    f.conf.addAllowedHeader("*");
    f.conf.addAllowedOrigin("https://domain2.com");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(!f.response.containsHeader(DefaultCorsProcessor.ACCESS_CONTROL_ALLOW_PRIVATE_NETWORK));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preflightRequestWithAccessControlRequestPrivateNetworkAllowed")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.request.addHeader(DefaultCorsProcessor.ACCESS_CONTROL_REQUEST_PRIVATE_NETWORK, "true");
    f.conf.addAllowedHeader("*");
    f.conf.addAllowedOrigin("https://domain2.com");
    f.conf.setAllowPrivateNetwork(true);

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(f.response.containsHeader(DefaultCorsProcessor.ACCESS_CONTROL_ALLOW_PRIVATE_NETWORK));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preflightRequestAllOriginsAllowed")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.conf.addAllowedOrigin("*");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}

@("DefaultCorsProcessorTests.preflightRequestMatchedAllowedMethod")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.conf.addAllowedOrigin("*");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
    assert(f.response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_METHODS) == "GET,HEAD");
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
}

@("DefaultCorsProcessorTests.preflightRequestWithEmptyHeaders")
unittest
{
    auto f = setup();
    f.request.setMethod(HttpMethod.OPTIONS.name());
    f.request.addHeader(HttpHeaders.ORIGIN, "https://domain2.com");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    f.request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS, "");
    f.conf.addAllowedHeader("*");
    f.conf.addAllowedOrigin("https://domain2.com");

    f.processor.processRequest(f.conf, f.request, f.response);
    assert(f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN));
    assert(!f.response.containsHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS));
    assert(containsAll(f.response.getHeaders(HttpHeaders.VARY), HttpHeaders.ORIGIN,
            HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS));
    assert(f.response.getStatus() == HttpServletResponse.SC_OK);
}
