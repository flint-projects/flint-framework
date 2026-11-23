/++
Flint-specific `flint.core.env` tests: a smoke test of the whole package, and the `spring.` key alias (ADR-030
section 1): every lookup of a `flint.` key that finds nothing retries the same key under `spring.`.
+/
module flint.core.env_test;

import flint.core.env : AbstractEnvironment, MapPropertySource, MutablePropertySources, Profiles,
    PropertySourcesPropertyResolver, SimpleCommandLinePropertySource, StandardEnvironment;
import flint.core.testfixture : MockPropertySource;
import flint.engine.aot.any : Any;
import flint.java.util : HashMap, Map;

@safe:

unittest
{
    // smoke test
    Map!(string, Any) map = new HashMap!(string, Any)();
    map.put("server.port", Any.of("8080"));
    map.put("greeting", Any.of("Hello, ${name:World}"));
    auto sources = new MutablePropertySources;
    sources.addFirst(new MapPropertySource("test", map));
    auto resolver = new PropertySourcesPropertyResolver(sources);
    assert(resolver.getProperty("server.port") == "8080");
    assert(resolver.getProperty!int("server.port") == 8080);
    assert(resolver.getProperty("greeting") == "Hello, World");
    assert(Profiles.of("prod & !cloud").matches((string p) => p == "prod"));
    auto env = new StandardEnvironment;
    env.getPropertySources().addFirst(new SimpleCommandLinePropertySource("--flint.profiles.active=dev,prod"));
    assert(env.getActiveProfiles() == ["dev", "prod"]);
}

unittest
{
    // a flint. key finds a value stored under its spring. alias
    auto sources = new MutablePropertySources;
    sources.addFirst(new MockPropertySource().withProperty("spring.application.name", "petclinic"));
    auto resolver = new PropertySourcesPropertyResolver(sources);
    assert(resolver.containsProperty("flint.application.name"));
    assert(resolver.getProperty("flint.application.name") == "petclinic");
    assert(resolver.getRequiredProperty("flint.application.name") == "petclinic");
    assert(resolver.resolvePlaceholders("${flint.application.name}") == "petclinic");
}

unittest
{
    // the flint. key wins over its spring. alias, whatever the source order
    auto sources = new MutablePropertySources;
    sources.addFirst(new MockPropertySource("springKeys").withProperty("spring.main.banner-mode", "off"));
    sources.addLast(new MockPropertySource("flintKeys").withProperty("flint.main.banner-mode", "console"));
    auto resolver = new PropertySourcesPropertyResolver(sources);
    assert(resolver.getProperty("flint.main.banner-mode") == "console");
    assert(resolver.getProperty("spring.main.banner-mode") == "off");
}

unittest
{
    // only flint. keys have an alias: a spring. key does not fall back to flint., nor does any other key
    auto sources = new MutablePropertySources;
    sources.addFirst(new MockPropertySource().withProperty("flint.datasource.url", "jdbc:h2:mem")
            .withProperty("spring.other", "x"));
    auto resolver = new PropertySourcesPropertyResolver(sources);
    assert(resolver.getProperty("spring.datasource.url") is null);
    assert(resolver.getProperty("other") is null);
    assert(!resolver.containsProperty("spring.datasource.url"));
}

unittest
{
    // converted lookups use the alias too
    auto sources = new MutablePropertySources;
    sources.addFirst(new MockPropertySource().withProperty("spring.server.port", "9090"));
    auto resolver = new PropertySourcesPropertyResolver(sources);
    assert(resolver.getProperty!int("flint.server.port") == 9090);
    assert(resolver.getProperty!int("flint.server.port.missing", 7) == 7);
}

unittest
{
    // spring.profiles.active and spring.profiles.default select profiles through the alias
    auto environment = new StandardEnvironment;
    environment.getPropertySources().addFirst(new MockPropertySource()
            .withProperty("spring.profiles.active", "p1,p2").withProperty("spring.profiles.default", "d1"));
    assert(environment.getActiveProfiles() == ["p1", "p2"]);
    assert(environment.getDefaultProfiles() == ["d1"]);
    assert(AbstractEnvironment.ACTIVE_PROFILES_PROPERTY_NAME == "flint.profiles.active");
    assert(AbstractEnvironment.DEFAULT_PROFILES_PROPERTY_NAME == "flint.profiles.default");
}

unittest
{
    // SPRING_PROFILES_ACTIVE in the process environment selects profiles, through the alias and relaxed names
    import std.process : environment;

    const previous = environment.get("SPRING_PROFILES_ACTIVE", null);
    environment["SPRING_PROFILES_ACTIVE"] = "fromenv";
    scope (exit)
    {
        if (previous is null)
            environment.remove("SPRING_PROFILES_ACTIVE");
        else
            environment["SPRING_PROFILES_ACTIVE"] = previous;
    }
    assert((new StandardEnvironment).getActiveProfiles() == ["fromenv"]);
}

unittest
{
    // spring.getenv.ignore suppresses system environment access through the alias
    auto environment = new StandardEnvironment;
    environment.getSystemProperties().put("spring.getenv.ignore", Any.of("true"));
    assert(environment.getSystemEnvironment().isEmpty());
}
