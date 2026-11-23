/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/cors/UrlBasedCorsConfigurationSourceTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; each
`@PathPatternsParameterizedTest` is one unittest that loops over the named request factories. flint.web has no
`ServletRequestPathUtils` or `UrlPathHelper` and its source resolves the lookup path from the request itself, so
both factories only build the request. The test lives with flint.mock.web's `MockHttpServletRequest` in
flint:framework-test, which depends on flint:web. Cases that need `getCorsConfigurations` or
`setAllowInitLookupPath` wait behind version gates.
+/
module flint.web.url_based_cors_configuration_source_tests;

import flint.mock.web : MockHttpServletRequest;
import flint.web.cors : CorsConfiguration, UrlBasedCorsConfigurationSource;

@safe:

private alias RequestFactory = MockHttpServletRequest delegate(string requestUri) @safe;

private struct NamedFactory
{
    string name;
    RequestFactory factory;
}

private NamedFactory[] pathPatternsArguments()
{
    // Spring also calls ServletRequestPathUtils.parseAndCache or UrlPathHelper.getLookupPathForRequest here.
    return [
        NamedFactory("ServletRequestPathUtils", (requestUri) => new MockHttpServletRequest("GET", requestUri)),
        NamedFactory("UrlPathHelper", (requestUri) => new MockHttpServletRequest("GET", requestUri)),
    ];
}

@("UrlBasedCorsConfigurationSourceTests.empty")
unittest
{
    foreach (named; pathPatternsArguments())
    {
        auto source = new UrlBasedCorsConfigurationSource();
        assert(source.getCorsConfiguration(named.factory("/bar/test.html")) is null, named.name);
    }
}

// Class `==` (AssertJ's `isEqualTo`) goes through Object.opEquals, which is @system.
@("UrlBasedCorsConfigurationSourceTests.registerAndMatch")
@system unittest
{
    foreach (named; pathPatternsArguments())
    {
        auto source = new UrlBasedCorsConfigurationSource();
        auto config = new CorsConfiguration();
        source.registerCorsConfiguration("/bar/**", config);

        auto request = named.factory("/foo/test.html");
        assert(source.getCorsConfiguration(request) is null, named.name);

        request = named.factory("/bar/test.html");
        assert(source.getCorsConfiguration(request) == config, named.name);
    }
}

// flint.web's UrlBasedCorsConfigurationSource does not expose its configurations map (getCorsConfigurations).
version (FlintCorsSourceConfigurationsMap)
{
    import flint.java.lang : UnsupportedOperationException;

    @("UrlBasedCorsConfigurationSourceTests.unmodifiableConfigurationsMap")
    unittest
    {
        auto source = new UrlBasedCorsConfigurationSource();
        bool thrown;
        try
            source.getCorsConfigurations()["/**"] = new CorsConfiguration();
        catch (UnsupportedOperationException)
            thrown = true;
        assert(thrown);
    }
}

// flint.web's UrlBasedCorsConfigurationSource always resolves the lookup path (no setAllowInitLookupPath).
version (FlintCorsAllowInitLookupPath)
{
    import flint.java.lang : IllegalArgumentException;

    @("UrlBasedCorsConfigurationSourceTests.allowInitLookupPath")
    unittest
    {
        auto source = new UrlBasedCorsConfigurationSource();
        auto config = new CorsConfiguration();
        source.registerCorsConfiguration("/**", config);

        auto request = new MockHttpServletRequest("GET", "/foo");
        assert(source.getCorsConfiguration(request) is config, "The path should be resolved lazily by default");

        source.setAllowInitLookupPath(false);
        bool thrown;
        try
            source.getCorsConfiguration(request);
        catch (IllegalArgumentException)
            thrown = true;
        assert(thrown);
    }
}
