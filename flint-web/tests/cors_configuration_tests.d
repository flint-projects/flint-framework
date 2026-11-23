/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/cors/CorsConfigurationTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. Lists are D arrays
(R10), so AssertJ's `isNull` is `is null` and `containsExactly` is array equality; `@Nullable` Boolean and Long are
`Nullable!T` (R5). All 20 ported cases run; none is gated.
+/
module flint.web.cors_configuration_tests;

import flint.http : HttpMethod;
import flint.java.lang : IllegalArgumentException;
import flint.web.cors : CorsConfiguration;
import std.typecons : Nullable;

@safe:

private bool throws(E : Throwable)(scope void delegate() @safe action)
{
    try
        action();
    catch (E)
        return true;
    return false;
}

private HttpMethod[] check(CorsConfiguration config, HttpMethod method)
{
    return config.checkHttpMethod(Nullable!HttpMethod(method));
}

@("CorsConfigurationTests.combineWithNull")
unittest
{
    auto config = new CorsConfiguration();
    config.setAllowedOrigins(["*"]);
    config.combine(null);
    assert(config.getAllowedOrigins() == ["*"]);
    assert(config.getAllowedOriginPatterns() is null);
}

@("CorsConfigurationTests.checkOriginNotAllowed")
unittest
{
    auto config = new CorsConfiguration();
    assert(config.checkOrigin(null) is null);
    assert(config.checkOrigin("https://domain.com") is null);

    config.addAllowedOrigin("*");
    assert(config.checkOrigin(null) is null);

    config.setAllowedOrigins(["https://domain1.com"]);
    assert(config.checkOrigin("https://domain2.com") is null);

    config.setAllowedOrigins([]);
    assert(config.checkOrigin("https://domain.com") is null);
}

@("CorsConfigurationTests.checkMethodAllowed")
unittest
{
    auto config = new CorsConfiguration();
    assert(check(config, HttpMethod.GET) == [HttpMethod.GET, HttpMethod.HEAD]);

    config.addAllowedMethod("GET");
    assert(check(config, HttpMethod.GET) == [HttpMethod.GET]);

    config.addAllowedMethod("POST");
    assert(check(config, HttpMethod.GET) == [HttpMethod.GET, HttpMethod.POST]);
    assert(check(config, HttpMethod.POST) == [HttpMethod.GET, HttpMethod.POST]);
}

@("CorsConfigurationTests.checkMethodNotAllowed")
unittest
{
    auto config = new CorsConfiguration();
    assert(config.checkHttpMethod(Nullable!HttpMethod.init) is null);
    assert(check(config, HttpMethod.DELETE) is null);

    config.setAllowedMethods([]);
    assert(check(config, HttpMethod.POST) is null);
}

@("CorsConfigurationTests.checkHeadersAllowed")
unittest
{
    auto config = new CorsConfiguration();
    assert(config.checkHeaders([]).length == 0);

    config.addAllowedHeader("header1");
    config.addAllowedHeader("header2");

    assert(config.checkHeaders(["header1"]) == ["header1"]);
    assert(config.checkHeaders(["header1", "header2"]) == ["header1", "header2"]);
    assert(config.checkHeaders(["header1", "header2", "header3"]) == ["header1", "header2"]);
}

@("CorsConfigurationTests.checkHeadersNotAllowed")
unittest
{
    auto config = new CorsConfiguration();
    assert(config.checkHeaders(null) is null);
    assert(config.checkHeaders(["header1"]) is null);

    config.setAllowedHeaders([]);
    assert(config.checkHeaders(["header1"]) is null);

    config.addAllowedHeader("header2");
    config.addAllowedHeader("header3");
    assert(config.checkHeaders(["header1"]) is null);
}

@("CorsConfigurationTests.checkOriginAllowed")
unittest
{
    // "*" matches
    auto config = new CorsConfiguration();
    config.addAllowedOrigin("*");
    assert(config.checkOrigin("https://domain.com") == "*");

    // "*" does not match together with allowCredentials
    config.setAllowCredentials(true);
    assert(throws!IllegalArgumentException(() { config.checkOrigin("https://domain.com"); }));

    // comma-delimited origins list
    config.setAllowedOrigins(["https://a1.com,https://a2.com"]);
    assert(config.checkOrigin("https://a1.com") == "https://a1.com");
    assert(config.checkOrigin("https://a2.com/") == "https://a2.com/");

    // comma-delimited origins list with space
    config.setAllowedOrigins(["https://a1.com, https://a2.com"]);
    assert(config.checkOrigin("https://a1.com") == "https://a1.com");
    assert(config.checkOrigin("https://a2.com/") == "https://a2.com/");

    // specific origin matches Origin header with or without trailing "/"
    config.setAllowedOrigins(["https://domain.com"]);
    assert(config.checkOrigin("https://domain.com") == "https://domain.com");
    assert(config.checkOrigin("https://domain.com/") == "https://domain.com/");

    // specific origin with trailing "/" matches Origin header with or without trailing "/"
    config.setAllowedOrigins(["https://domain.com/"]);
    assert(config.checkOrigin("https://domain.com") == "https://domain.com");
    assert(config.checkOrigin("https://domain.com/") == "https://domain.com/");

    config.setAllowCredentials(false);
    assert(config.checkOrigin("https://domain.com") == "https://domain.com");
}

@("CorsConfigurationTests.changePermitDefaultValues")
unittest
{
    auto config = new CorsConfiguration().applyPermitDefaultValues();
    config.addAllowedOrigin("https://domain.com");
    config.addAllowedHeader("header1");
    config.addAllowedMethod("PATCH");

    assert(config.getAllowedOrigins() == ["*", "https://domain.com"]);
    assert(config.getAllowedHeaders() == ["*", "header1"]);
    assert(config.getAllowedMethods() == ["GET", "HEAD", "POST", "PATCH"]);
}

@("CorsConfigurationTests.combineWithDefaultPermitValues")
unittest
{
    auto config = new CorsConfiguration().applyPermitDefaultValues();
    auto other = new CorsConfiguration();
    other.addAllowedOrigin("https://domain.com");
    other.addAllowedHeader("header1");
    other.addAllowedMethod(HttpMethod.PUT.name());

    auto combinedConfig = config.combine(other);
    assert(combinedConfig !is null);
    assert(combinedConfig.getAllowedOrigins() == ["https://domain.com"]);
    assert(combinedConfig.getAllowedHeaders() == ["header1"]);
    assert(combinedConfig.getAllowedMethods() == [HttpMethod.PUT.name()]);
    assert(combinedConfig.getExposedHeaders().length == 0);

    combinedConfig = other.combine(config);
    assert(combinedConfig !is null);
    assert(combinedConfig.getAllowedOrigins() == ["https://domain.com"]);
    assert(combinedConfig.getAllowedHeaders() == ["header1"]);
    assert(combinedConfig.getAllowedMethods() == [HttpMethod.PUT.name()]);
    assert(combinedConfig.getExposedHeaders().length == 0);

    static immutable defaults = [
        HttpMethod.GET.name(), HttpMethod.HEAD.name(), HttpMethod.POST.name()
    ];
    combinedConfig = config.combine(new CorsConfiguration());
    assert(config.getAllowedOrigins() == ["*"]);
    assert(config.getAllowedHeaders() == ["*"]);
    assert(combinedConfig !is null);
    assert(combinedConfig.getAllowedMethods() == defaults);
    assert(combinedConfig.getExposedHeaders().length == 0);

    combinedConfig = new CorsConfiguration().combine(config);
    assert(config.getAllowedOrigins() == ["*"]);
    assert(config.getAllowedHeaders() == ["*"]);
    assert(combinedConfig !is null);
    assert(combinedConfig.getAllowedMethods() == defaults);
    assert(combinedConfig.getExposedHeaders().length == 0);
}

@("CorsConfigurationTests.setNullValues")
unittest
{
    auto config = new CorsConfiguration();
    config.setAllowedOrigins(null);
    assert(config.getAllowedOrigins() is null);
    config.setAllowedOriginPatterns(null);
    assert(config.getAllowedOriginPatterns() is null);
    config.setAllowedHeaders(null);
    assert(config.getAllowedHeaders() is null);
    config.setAllowedMethods(null);
    assert(config.getAllowedMethods() is null);
    config.setExposedHeaders(null);
    assert(config.getExposedHeaders() is null);
    config.setAllowCredentials(Nullable!bool.init);
    assert(config.getAllowCredentials().isNull);
    config.setAllowPrivateNetwork(Nullable!bool.init);
    assert(config.getAllowPrivateNetwork().isNull);
    config.setMaxAge(Nullable!long.init);
    assert(config.getMaxAge().isNull);
}

@("CorsConfigurationTests.setValues")
unittest
{
    auto config = new CorsConfiguration();
    config.addAllowedOrigin("*");
    config.addAllowedOriginPattern("http://*.example.com");
    config.addAllowedHeader("*");
    config.addAllowedMethod("*");
    config.addExposedHeader("*");
    config.setAllowCredentials(true);
    config.setAllowPrivateNetwork(true);
    config.setMaxAge(123L);

    assert(config.getAllowedOrigins() == ["*"]);
    assert(config.getAllowedOriginPatterns() == ["http://*.example.com"]);
    assert(config.getAllowedHeaders() == ["*"]);
    assert(config.getAllowedMethods() == ["*"]);
    assert(config.getExposedHeaders() == ["*"]);
    assert(config.getAllowCredentials().get);
    assert(config.getAllowPrivateNetwork().get);
    assert(config.getMaxAge().get == 123);
}

@("CorsConfigurationTests.combineWithNullProperties")
unittest
{
    auto config = new CorsConfiguration();
    config.addAllowedOrigin("*");
    config.setAllowedOriginPatterns(["http://*.example.com"]);
    config.addAllowedHeader("header1");
    config.addExposedHeader("header3");
    config.addAllowedMethod(HttpMethod.GET.name());
    config.setMaxAge(123L);
    config.setAllowCredentials(true);
    config.setAllowPrivateNetwork(true);

    auto other = new CorsConfiguration();
    config = config.combine(other);

    assert(config !is null);
    assert(config.getAllowedOrigins() == ["*"]);
    assert(config.getAllowedOriginPatterns() == ["http://*.example.com"]);
    assert(config.getAllowedHeaders() == ["header1"]);
    assert(config.getExposedHeaders() == ["header3"]);
    assert(config.getAllowedMethods() == [HttpMethod.GET.name()]);
    assert(config.getMaxAge().get == 123);
    assert(config.getAllowCredentials().get);
    assert(config.getAllowPrivateNetwork().get);
}

@("CorsConfigurationTests.combinePatternWithDefaultPermitValues")
unittest
{
    auto config = new CorsConfiguration().applyPermitDefaultValues();
    auto other = new CorsConfiguration();
    other.addAllowedOriginPattern("http://*.com");

    auto combinedConfig = other.combine(config);
    assert(combinedConfig !is null);
    assert(combinedConfig.getAllowedOrigins() is null);
    assert(combinedConfig.getAllowedOriginPatterns() == ["http://*.com"]);

    combinedConfig = config.combine(other);
    assert(combinedConfig !is null);
    assert(combinedConfig.getAllowedOrigins() is null);
    assert(combinedConfig.getAllowedOriginPatterns() == ["http://*.com"]);
}

@("CorsConfigurationTests.combinePatternWithDefaultPermitValuesAndCustomOrigin")
unittest
{
    auto config = new CorsConfiguration().applyPermitDefaultValues();
    config.setAllowedOrigins(["https://domain.com"]);

    auto other = new CorsConfiguration();
    other.addAllowedOriginPattern("http://*.com");

    auto combinedConfig = other.combine(config);
    assert(combinedConfig !is null);
    assert(combinedConfig.getAllowedOrigins() == ["https://domain.com"]);
    assert(combinedConfig.getAllowedOriginPatterns() == ["http://*.com"]);

    combinedConfig = config.combine(other);
    assert(combinedConfig !is null);
    assert(combinedConfig.getAllowedOrigins() == ["https://domain.com"]);
    assert(combinedConfig.getAllowedOriginPatterns() == ["http://*.com"]);
}

@("CorsConfigurationTests.combineWithAsteriskWildCard")
unittest
{
    auto config = new CorsConfiguration();
    config.addAllowedOrigin("*");
    config.addAllowedHeader("*");
    config.addExposedHeader("*");
    config.addAllowedMethod("*");
    config.addAllowedOriginPattern("*");

    auto other = new CorsConfiguration();
    other.addAllowedOrigin("https://domain.com");
    other.addAllowedOriginPattern("http://*.company.com");
    other.addAllowedHeader("header1");
    other.addExposedHeader("header2");
    other.addAllowedHeader("anotherHeader1");
    other.addExposedHeader("anotherHeader2");
    other.addAllowedMethod(HttpMethod.PUT.name());

    foreach (combinedConfig; [config.combine(other), other.combine(config)])
    {
        assert(combinedConfig !is null);
        assert(combinedConfig.getAllowedOrigins() == ["*"]);
        assert(combinedConfig.getAllowedOriginPatterns() == ["*"]);
        assert(combinedConfig.getAllowedHeaders() == ["*"]);
        assert(combinedConfig.getExposedHeaders() == ["*"]);
        assert(combinedConfig.getAllowedMethods() == ["*"]);
    }
}

@("CorsConfigurationTests.combineWithDuplicatedElements")
unittest
{
    auto config = new CorsConfiguration();
    config.addAllowedOrigin("https://domain1.com");
    config.addAllowedOrigin("https://domain2.com");
    config.addAllowedHeader("header1");
    config.addAllowedHeader("header2");
    config.addExposedHeader("header3");
    config.addExposedHeader("header4");
    config.addAllowedMethod(HttpMethod.GET.name());
    config.addAllowedMethod(HttpMethod.PUT.name());
    config.addAllowedOriginPattern("http://*.domain1.com");
    config.addAllowedOriginPattern("http://*.domain2.com");

    auto other = new CorsConfiguration();
    other.addAllowedOrigin("https://domain1.com");
    other.addAllowedOriginPattern("http://*.domain1.com");
    other.addAllowedHeader("header1");
    other.addExposedHeader("header3");
    other.addAllowedMethod(HttpMethod.GET.name());

    auto combinedConfig = config.combine(other);
    assert(combinedConfig !is null);
    assert(combinedConfig.getAllowedOrigins() == ["https://domain1.com", "https://domain2.com"]);
    assert(combinedConfig.getAllowedHeaders() == ["header1", "header2"]);
    assert(combinedConfig.getExposedHeaders() == ["header3", "header4"]);
    assert(combinedConfig.getAllowedMethods() == [HttpMethod.GET.name(), HttpMethod.PUT.name()]);
    assert(combinedConfig.getAllowedOriginPatterns() == [
        "http://*.domain1.com", "http://*.domain2.com"
    ]);
}

@("CorsConfigurationTests.combine")
unittest
{
    auto config = new CorsConfiguration();
    config.addAllowedOrigin("https://domain1.com");
    config.addAllowedOriginPattern("http://*.domain1.com");
    config.addAllowedHeader("header1");
    config.addExposedHeader("header3");
    config.addAllowedMethod(HttpMethod.GET.name());
    config.setMaxAge(123L);
    config.setAllowCredentials(true);
    config.setAllowPrivateNetwork(true);

    auto other = new CorsConfiguration();
    other.addAllowedOrigin("https://domain2.com");
    other.addAllowedOriginPattern("http://*.domain2.com");
    other.addAllowedHeader("header2");
    other.addExposedHeader("header4");
    other.addAllowedMethod(HttpMethod.PUT.name());
    other.setMaxAge(456L);
    other.setAllowCredentials(false);
    other.setAllowPrivateNetwork(false);

    config = config.combine(other);
    assert(config !is null);
    assert(config.getAllowedOrigins() == ["https://domain1.com", "https://domain2.com"]);
    assert(config.getAllowedHeaders() == ["header1", "header2"]);
    assert(config.getExposedHeaders() == ["header3", "header4"]);
    assert(config.getAllowedMethods() == [HttpMethod.GET.name(), HttpMethod.PUT.name()]);
    assert(config.getMaxAge().get == 456);
    assert(!config.getAllowCredentials().get);
    assert(!config.getAllowPrivateNetwork().get);
    assert(config.getAllowedOriginPatterns() == ["http://*.domain1.com", "http://*.domain2.com"]);
}

@("CorsConfigurationTests.checkOriginPatternAllowed")
unittest
{
    auto config = new CorsConfiguration();
    assert(config.checkOrigin("https://domain.com") is null);

    config.applyPermitDefaultValues();
    assert(config.checkOrigin("https://domain.com") == "*");

    config.setAllowCredentials(true);
    assert(throws!IllegalArgumentException(() { config.checkOrigin("https://domain.com"); }));
    config.addAllowedOriginPattern("https://*.domain.com");
    assert(config.checkOrigin("https://example.domain.com") == "https://example.domain.com");

    config.addAllowedOriginPattern("https://*.port.domain.com:[*]");
    assert(config.checkOrigin("https://example.port.domain.com") == "https://example.port.domain.com");
    assert(config.checkOrigin("https://example.port.domain.com:1234") == "https://example.port.domain.com:1234");

    config.addAllowedOriginPattern("https://*.specific.port.com:[8080,8081]");
    enum specific8080 = "https://example.specific.port.com:8080";
    assert(config.checkOrigin(specific8080) == specific8080);
    enum specific8081 = "https://example.specific.port.com:8081";
    assert(config.checkOrigin(specific8081) == specific8081);
    assert(config.checkOrigin("https://example.specific.port.com:1234") is null);

    config.addAllowedOriginPattern("https://*.a1.com:[8080,8081],https://*.a2.com");
    assert(config.checkOrigin("https://example.a1.com:8080") == "https://example.a1.com:8080");
    assert(config.checkOrigin("https://example.a1.com:8081") == "https://example.a1.com:8081");
    assert(config.checkOrigin("https://example.a1.com:8082") is null);
    assert(config.checkOrigin("https://example.a2.com") == "https://example.a2.com");

    config.setAllowCredentials(false);
    assert(config.checkOrigin("https://example.domain.com") == "https://example.domain.com");
}

@("CorsConfigurationTests.checkOriginPatternNotAllowed")
unittest
{
    auto config = new CorsConfiguration();
    assert(config.checkOrigin(null) is null);
    assert(config.checkOrigin("https://domain.com") is null);

    config.addAllowedOriginPattern("*");
    assert(config.checkOrigin(null) is null);

    config.setAllowedOriginPatterns(["http://*.domain1.com"]);
    assert(config.checkOrigin("https://domain2.com") is null);

    config.setAllowedOriginPatterns([]);
    assert(config.checkOrigin("https://domain.com") is null);

    config.setAllowedOriginPatterns(["https://*.specific.port.com:[8080,8081]"]);
    assert(config.checkOrigin("https://example.specific.port.com:1234") is null);
}

@("CorsConfigurationTests.permitDefaultDoesntSetOriginWhenPatternPresent")
unittest
{
    auto config = new CorsConfiguration();
    config.addAllowedOriginPattern("http://*.com");
    config = config.applyPermitDefaultValues();

    assert(config.getAllowedOrigins() is null);
    assert(config.getAllowedOriginPatterns() == ["http://*.com"]);
}
