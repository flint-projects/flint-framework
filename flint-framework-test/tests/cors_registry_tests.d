/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/config/annotation/CorsRegistryTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the `@BeforeEach`
field becomes the registry that `setup` returns. flint.web.servlet's `CorsRegistry` hands
`WebMvcConfigurationSupport` a `UrlBasedCorsConfigurationSource` (`null` when nothing is mapped) instead of the
`getCorsConfigurations()` map, so `noMapping` checks for no source and the other cases look each mapping's
configuration up through the source with a flint.mock.web `MockHttpServletRequest` for the mapped path. The test
lives with flint.mock.web in flint:framework-test. Cases that need `CorsRegistration.allowPrivateNetwork` or
`combine` wait behind a version gate.
+/
module flint.web.cors_registry_tests;

// flint.web first: importing flint.web.method.support (directly or through flint.web.servlet.config.annotation)
// before it trips a forward-reference error on LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.mock.web : MockHttpServletRequest;
import flint.web.cors : CorsConfiguration;
import flint.web.servlet.config.annotation : CorsRegistry;

@safe:

private CorsRegistry setup()
{
    return new CorsRegistry();
}

/// `getCorsConfigurations().get(path)`: the configuration the registry's source holds for `path`.
private CorsConfiguration configurationFor(CorsRegistry registry, string path)
{
    auto source = registry.getCorsConfigurationSource();
    assert(source !is null);
    return source.getCorsConfiguration(new MockHttpServletRequest("GET", path));
}

@("CorsRegistryTests.noMapping")
unittest
{
    auto registry = setup();
    assert(registry.getCorsConfigurationSource() is null);
}

@("CorsRegistryTests.multipleMappings")
unittest
{
    auto registry = setup();
    registry.addMapping("/foo");
    registry.addMapping("/bar");
    const foo = configurationFor(registry, "/foo");
    const bar = configurationFor(registry, "/bar");
    assert(foo !is null);
    assert(bar !is null);
    assert(foo !is bar);
}

// flint.web.servlet's CorsRegistration has no allowPrivateNetwork or combine, and CorsConfiguration no
// getAllowPrivateNetwork.
version (FlintCorsRegistrationComplete)
{
    @("CorsRegistryTests.customizedMapping")
    unittest
    {
        auto registry = setup();
        registry.addMapping("/foo").allowedOrigins("https://domain2.com", "https://domain2.com")
            .allowedMethods("DELETE").allowCredentials(true).allowPrivateNetwork(true)
            .allowedHeaders("header1", "header2").exposedHeaders("header3", "header4").maxAge(3600);
        const config = configurationFor(registry, "/foo");
        assert(config.getAllowedOrigins() == ["https://domain2.com", "https://domain2.com"]);
        assert(config.getAllowedMethods() == ["DELETE"]);
        assert(config.getAllowedHeaders() == ["header1", "header2"]);
        assert(config.getExposedHeaders() == ["header3", "header4"]);
        assert(config.getAllowCredentials().get);
        assert(config.getAllowPrivateNetwork().get);
        assert(config.getMaxAge().get == 3600);
    }
}

@("CorsRegistryTests.allowCredentials")
unittest
{
    auto registry = setup();
    registry.addMapping("/foo").allowCredentials(true);
    const config = configurationFor(registry, "/foo");
    assert(config.getAllowedOrigins() == ["*"], "Globally origins=\"*\" and allowCredentials=true should be possible");
}

version (FlintCorsRegistrationComplete)
{
    @("CorsRegistryTests.combine")
    unittest
    {
        auto registry = setup();
        auto otherConfig = new CorsConfiguration();
        otherConfig.addAllowedOrigin("http://localhost:3000");
        otherConfig.addAllowedMethod("*");
        otherConfig.applyPermitDefaultValues();

        registry.addMapping("/api/**").combine(otherConfig);

        const config = configurationFor(registry, "/api/**");
        assert(config.getAllowedOrigins() == ["http://localhost:3000"]);
        assert(config.getAllowedMethods() == ["*"]);
        assert(config.getAllowedHeaders() == ["*"]);
        assert(config.getExposedHeaders().length == 0);
        assert(config.getAllowCredentials().isNull);
        assert(config.getAllowPrivateNetwork().isNull);
        assert(config.getMaxAge().get == 1800);
    }
}
