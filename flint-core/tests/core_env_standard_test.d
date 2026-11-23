/*
 * Copyright 2002-present the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by the Flint authors: ported from spring-framework v7.1.0,
 * spring-core/src/test/java/org/springframework/core/env/StandardEnvironmentTests.java.
 *
 * JVM system properties do not exist in D: `getSystemProperties()` is each environment's own, initially empty,
 * mutable map (the "systemProperties" source), and tests that set a JVM system property put the key there instead.
 * The `spring.` keys are `flint.` keys (ADR-030).
 *
 * Skipped Java tests:
 * - setActiveProfiles_withNullProfileArray, setDefaultProfiles_withNullProfileArray: a null `String[]` is an empty
 *   D variadic call, which validly clears the profiles.
 * - suppressGetenvAccessThroughSpringFlag: SpringProperties.setFlag; Flint has no SpringProperties.
 * Adapted: suppressGetenvAccessThroughSpringProperty sets FLINT_GETENV_IGNORE, Flint's process-wide equivalent of the
 * SpringProperties flag; getSystemProperties checks the environment's own map and source (no non-String keys);
 * getSystemEnvironment checks that a variable set in the process is visible (D returns a snapshot, not the same
 * instance as `System.getenv()`).
 */
module flint.core.env_standard_test;

import flint.core.env : AbstractEnvironment, ConfigurableEnvironment, MapPropertySource,
    MutablePropertySources, Profiles, PropertySource, StandardEnvironment, SystemEnvironmentPropertySource;
import flint.core.testfixture : MockPropertySource;
import flint.engine.aot.any : Any;
import flint.java.lang : IllegalArgumentException;
import flint.util : PlaceholderResolutionException;
import std.exception : collectException;

@safe:

private enum ACTIVE_PROFILES_PROPERTY_NAME = AbstractEnvironment.ACTIVE_PROFILES_PROPERTY_NAME;
private enum DEFAULT_PROFILES_PROPERTY_NAME = AbstractEnvironment.DEFAULT_PROFILES_PROPERTY_NAME;
private enum RESERVED_DEFAULT_PROFILE_NAME = AbstractEnvironment.RESERVED_DEFAULT_PROFILE_NAME;

private void assertInvalid(void delegate() @safe action, string message = null)
{
    const e = collectException!IllegalArgumentException(action());
    assert(e !is null);
    assert(message is null || e.msg == message, e.msg);
}

/// Run `action` with the environment variable `name` set to `value`, restoring its previous state afterwards.
private void withEnvironmentVariable(string name, string value, void delegate() @safe action)
{
    import std.process : environment;

    const previous = environment.get(name, null);
    environment[name] = value;
    scope (exit)
    {
        if (previous is null)
            environment.remove(name);
        else
            environment[name] = previous;
    }
    action();
}

unittest
{
    // merge
    ConfigurableEnvironment child = new StandardEnvironment;
    child.setActiveProfiles("c1", "c2");
    child.getPropertySources().addLast(new MockPropertySource("childMock").withProperty("childKey",
            "childVal").withProperty("bothKey", "childBothVal"));
    ConfigurableEnvironment parent = new StandardEnvironment;
    parent.setActiveProfiles("p1", "p2");
    parent.getPropertySources().addLast(new MockPropertySource("parentMock")
            .withProperty("parentKey", "parentVal").withProperty("bothKey", "parentBothVal"));
    assert(child.getProperty("childKey") == "childVal");
    assert(child.getProperty("parentKey") is null);
    assert(child.getProperty("bothKey") == "childBothVal");
    assert(parent.getProperty("childKey") is null);
    assert(parent.getProperty("parentKey") == "parentVal");
    assert(parent.getProperty("bothKey") == "parentBothVal");
    assert(child.getActiveProfiles() == ["c1", "c2"]);
    assert(parent.getActiveProfiles() == ["p1", "p2"]);
    child.merge(parent);
    assert(child.getProperty("childKey") == "childVal");
    assert(child.getProperty("parentKey") == "parentVal");
    assert(child.getProperty("bothKey") == "childBothVal");
    assert(parent.getProperty("childKey") is null);
    assert(parent.getProperty("parentKey") == "parentVal");
    assert(parent.getProperty("bothKey") == "parentBothVal");
    assert(child.getActiveProfiles() == ["c1", "c2", "p1", "p2"]);
    assert(parent.getActiveProfiles() == ["p1", "p2"]);
}

unittest
{
    // propertySourceOrder
    ConfigurableEnvironment env = new StandardEnvironment;
    auto sources = env.getPropertySources();
    alias names = StandardEnvironment;
    assert(sources.precedenceOf(PropertySource.named(names.SYSTEM_PROPERTIES_PROPERTY_SOURCE_NAME)) == 0);
    assert(sources.precedenceOf(PropertySource.named(names.SYSTEM_ENVIRONMENT_PROPERTY_SOURCE_NAME)) == 1);
    assert(sources.size() == 2);
}

unittest
{
    // propertySourceTypes
    ConfigurableEnvironment env = new StandardEnvironment;
    auto sources = env.getPropertySources();
    assert(cast(SystemEnvironmentPropertySource) sources.get(
            StandardEnvironment.SYSTEM_ENVIRONMENT_PROPERTY_SOURCE_NAME) !is null);
}

unittest
{
    // activeProfilesIsEmptyByDefault
    assert((new StandardEnvironment).getActiveProfiles().length == 0);
}

unittest
{
    // defaultProfilesContainsDefaultProfileByDefault
    assert((new StandardEnvironment).getDefaultProfiles() == ["default"]);
}

unittest
{
    // setActiveProfiles
    auto environment = new StandardEnvironment;
    environment.setActiveProfiles("local", "embedded");
    assert(environment.getActiveProfiles() == ["local", "embedded"]);
}

unittest
{
    // setActiveProfiles_withNullProfile
    auto environment = new StandardEnvironment;
    string nullProfile = null;
    assertInvalid(() => environment.setActiveProfiles(nullProfile), "Invalid profile [null]: must contain text");
}

unittest
{
    // setActiveProfiles_withEmptyProfile
    auto environment = new StandardEnvironment;
    assertInvalid(() => environment.setActiveProfiles(""), "Invalid profile []: must contain text");
}

unittest
{
    // setActiveProfiles_withNotOperator
    auto environment = new StandardEnvironment;
    assertInvalid(() => environment.setActiveProfiles("p1", "!p2"),
            "Invalid profile [!p2]: must not begin with ! operator");
}

unittest
{
    // setDefaultProfiles_withNullProfile
    auto environment = new StandardEnvironment;
    string nullProfile = null;
    assertInvalid(() => environment.setDefaultProfiles(nullProfile), "Invalid profile [null]: must contain text");
}

unittest
{
    // setDefaultProfiles_withEmptyProfile
    auto environment = new StandardEnvironment;
    assertInvalid(() => environment.setDefaultProfiles(""));
}

unittest
{
    // setDefaultProfiles_withNotOperator
    auto environment = new StandardEnvironment;
    assertInvalid(() => environment.setDefaultProfiles("d1", "!d2"));
}

unittest
{
    // addActiveProfile
    auto environment = new StandardEnvironment;
    assert(environment.getActiveProfiles().length == 0);
    environment.setActiveProfiles("local", "embedded");
    assert(environment.getActiveProfiles() == ["local", "embedded"]);
    environment.addActiveProfile("p1");
    assert(environment.getActiveProfiles() == ["local", "embedded", "p1"]);
    environment.addActiveProfile("p2");
    environment.addActiveProfile("p3");
    assert(environment.getActiveProfiles() == ["local", "embedded", "p1", "p2", "p3"]);
}

unittest
{
    // addActiveProfile_whenActiveProfilesPropertyIsAlreadySet
    ConfigurableEnvironment env = new StandardEnvironment;
    assert(env.getProperty(ACTIVE_PROFILES_PROPERTY_NAME) is null);
    env.getPropertySources().addFirst(new MockPropertySource().withProperty(ACTIVE_PROFILES_PROPERTY_NAME, "p1"));
    assert(env.getProperty(ACTIVE_PROFILES_PROPERTY_NAME) == "p1");
    env.addActiveProfile("p2");
    assert(env.getActiveProfiles() == ["p1", "p2"]);
}

unittest
{
    // reservedDefaultProfile
    auto environment = new StandardEnvironment;
    assert(environment.getDefaultProfiles() == [RESERVED_DEFAULT_PROFILE_NAME]);
    environment.getSystemProperties().put(DEFAULT_PROFILES_PROPERTY_NAME, Any.of("d0"));
    assert(environment.getDefaultProfiles() == ["d0"]);
    environment.setDefaultProfiles("d1", "d2");
    assert(environment.getDefaultProfiles() == ["d1", "d2"]);
}

unittest
{
    // NEEDS-UTIL: circular placeholder detection and Spring's "Circular placeholder reference" message
    // defaultProfileWithCircularPlaceholder
    version (none)
    {
        import std.string : indexOf;

        auto environment = new StandardEnvironment;
        environment.getSystemProperties().put(DEFAULT_PROFILES_PROPERTY_NAME, Any.of("${flint.profiles.default}"));
        auto e = collectException!PlaceholderResolutionException(environment.getDefaultProfiles());
        assert(e !is null && e.msg.indexOf("Circular placeholder reference 'flint.profiles.default'") >= 0);
    }
}

unittest
{
    // getDefaultProfiles
    auto environment = new StandardEnvironment;
    assert(environment.getDefaultProfiles() == [RESERVED_DEFAULT_PROFILE_NAME]);
    environment.getPropertySources().addFirst(new MockPropertySource()
            .withProperty(DEFAULT_PROFILES_PROPERTY_NAME, "pd1"));
    assert(environment.getDefaultProfiles() == ["pd1"]);
}

unittest
{
    // setDefaultProfiles
    auto environment = new StandardEnvironment;
    environment.setDefaultProfiles();
    assert(environment.getDefaultProfiles().length == 0);
    environment.setDefaultProfiles("pd1");
    assert(environment.getDefaultProfiles() == ["pd1"]);
    environment.setDefaultProfiles("pd2", "pd3");
    assert(environment.getDefaultProfiles() == ["pd2", "pd3"]);
}

unittest
{
    // environmentSubclass_withCustomProfileValidation
    ConfigurableEnvironment env = new class AbstractEnvironment
    {
        protected override void validateProfile(string profile)
        {
            import std.string : indexOf;

            super.validateProfile(profile);
            if (profile.indexOf('-') >= 0)
            {
                const message = "Invalid profile [" ~ profile ~ "]: must not contain dash character";
                throw new IllegalArgumentException(message);
            }
        }
    };
    env.addActiveProfile("validProfile"); // succeeds
    assertInvalid(() => env.addActiveProfile("invalid-profile"),
            "Invalid profile [invalid-profile]: must not contain dash character");
}

unittest
{
    // suppressGetenvAccessThroughSystemProperty
    auto environment = new StandardEnvironment;
    environment.getSystemProperties().put("flint.getenv.ignore", Any.of("true"));
    assert(environment.getSystemEnvironment().isEmpty());
}

unittest
{
    // suppressGetenvAccessThroughSpringProperty
    withEnvironmentVariable("FLINT_GETENV_IGNORE", "true", () {
        assert((new StandardEnvironment).getSystemEnvironment().isEmpty());
    });
}

unittest
{
    // getSystemProperties
    enum ALLOWED_PROPERTY_NAME = "theanswer";
    enum ALLOWED_PROPERTY_VALUE = "42";
    enum DISALLOWED_PROPERTY_NAME = "verboten";
    enum DISALLOWED_PROPERTY_VALUE = "secret";
    auto environment = new StandardEnvironment;
    environment.getSystemProperties().put(ALLOWED_PROPERTY_NAME, Any.of(ALLOWED_PROPERTY_VALUE));
    environment.getSystemProperties().put(DISALLOWED_PROPERTY_NAME, Any.of(DISALLOWED_PROPERTY_VALUE));
    auto systemProperties = environment.getSystemProperties();
    assert(systemProperties !is null);
    assert(systemProperties is environment.getSystemProperties());
    assert(systemProperties.get(ALLOWED_PROPERTY_NAME).get!string == ALLOWED_PROPERTY_VALUE);
    assert(systemProperties.get(DISALLOWED_PROPERTY_NAME).get!string == DISALLOWED_PROPERTY_VALUE);
    auto systemPropertySource = cast(MapPropertySource) environment.getPropertySources()
        .get(StandardEnvironment.SYSTEM_PROPERTIES_PROPERTY_SOURCE_NAME);
    assert(systemPropertySource.getPropertyNames() == [
        ALLOWED_PROPERTY_NAME, DISALLOWED_PROPERTY_NAME
    ]);
    assert(environment.getProperty(ALLOWED_PROPERTY_NAME) == ALLOWED_PROPERTY_VALUE);
}

unittest
{
    // getSystemEnvironment
    withEnvironmentVariable("FLINT_CORE_TEST_VARIABLE", "present", () {
        auto systemEnvironment = (new StandardEnvironment).getSystemEnvironment();
        assert(systemEnvironment !is null);
        assert(systemEnvironment.get("FLINT_CORE_TEST_VARIABLE").get!string == "present");
    });
}

// GetActiveProfiles

unittest
{
    // systemPropertiesEmpty
    auto environment = new StandardEnvironment;
    assert(environment.getActiveProfiles().length == 0);
    environment.getSystemProperties().put(ACTIVE_PROFILES_PROPERTY_NAME, Any.of(""));
    assert(environment.getActiveProfiles().length == 0);
}

unittest
{
    // fromSystemProperties
    auto environment = new StandardEnvironment;
    environment.getSystemProperties().put(ACTIVE_PROFILES_PROPERTY_NAME, Any.of("foo"));
    assert(environment.getActiveProfiles() == ["foo"]);
}

unittest
{
    // fromSystemProperties_withMultipleProfiles
    auto environment = new StandardEnvironment;
    environment.getSystemProperties().put(ACTIVE_PROFILES_PROPERTY_NAME, Any.of("foo,bar"));
    assert(environment.getActiveProfiles() == ["foo", "bar"]);
}

unittest
{
    // fromSystemProperties_withMultipleProfiles_withWhitespace
    auto environment = new StandardEnvironment;
    environment.getSystemProperties().put(ACTIVE_PROFILES_PROPERTY_NAME, Any.of(" bar , baz ")); // notice whitespace
    assert(environment.getActiveProfiles() == ["bar", "baz"]);
}

// AcceptsProfilesTests (Environment.acceptsProfiles(String...), deprecated since Spring 5.1)

unittest
{
    // withEmptyArgumentList
    auto environment = new StandardEnvironment;
    assertInvalid(() { environment.acceptsProfiles(); }, "Must specify at least one profile");
}

unittest
{
    // withNullArgumentList
    auto environment = new StandardEnvironment;
    string[] none = null;
    assertInvalid(() { environment.acceptsProfiles(none); });
}

unittest
{
    // withNullArgument
    auto environment = new StandardEnvironment;
    string nullProfile = null;
    assertInvalid(() { environment.acceptsProfiles(nullProfile); });
}

unittest
{
    // withEmptyArgument
    auto environment = new StandardEnvironment;
    assertInvalid(() { environment.acceptsProfiles(""); });
}

unittest
{
    // activeProfileSetProgrammatically
    auto environment = new StandardEnvironment;
    assert(!environment.acceptsProfiles("p1", "p2"));
    environment.setActiveProfiles("p1");
    assert(environment.acceptsProfiles("p1", "p2"));
    environment.setActiveProfiles("p2");
    assert(environment.acceptsProfiles("p1", "p2"));
    environment.setActiveProfiles("p1", "p2");
    assert(environment.acceptsProfiles("p1", "p2"));
}

unittest
{
    // activeProfileSetViaProperty
    auto environment = new StandardEnvironment;
    assert(!environment.acceptsProfiles("p1"));
    environment.getPropertySources().addFirst(new MockPropertySource()
            .withProperty(ACTIVE_PROFILES_PROPERTY_NAME, "p1"));
    assert(environment.acceptsProfiles("p1"));
}

unittest
{
    // defaultProfile
    auto environment = new StandardEnvironment;
    assert(!environment.acceptsProfiles("pd"));
    environment.setDefaultProfiles("pd");
    assert(environment.acceptsProfiles("pd"));
    environment.setActiveProfiles("p1");
    assert(!environment.acceptsProfiles("pd"));
    assert(environment.acceptsProfiles("p1"));
}

unittest
{
    // withNotOperator
    auto environment = new StandardEnvironment;
    assert(!environment.acceptsProfiles("p1"));
    assert(environment.acceptsProfiles("!p1"));
    environment.addActiveProfile("p1");
    assert(environment.acceptsProfiles("p1"));
    assert(!environment.acceptsProfiles("!p1"));
}

unittest
{
    // withInvalidNotOperator
    auto environment = new StandardEnvironment;
    assertInvalid(() { environment.acceptsProfiles("p1", "!"); });
}

unittest
{
    // withProfileExpression
    auto environment = new StandardEnvironment;
    assert(!environment.acceptsProfiles(Profiles.of("p1 & p2")));
    environment.addActiveProfile("p1");
    assert(!environment.acceptsProfiles(Profiles.of("p1 & p2")));
    environment.addActiveProfile("p2");
    assert(environment.acceptsProfiles(Profiles.of("p1 & p2")));
}

// MatchesProfilesTests

unittest
{
    // withEmptyArgumentList
    auto environment = new StandardEnvironment;
    assertInvalid(() { environment.matchesProfiles(); });
}

unittest
{
    // withNullArgumentList
    auto environment = new StandardEnvironment;
    string[] none = null;
    assertInvalid(() { environment.matchesProfiles(none); });
}

unittest
{
    // withNullArgument
    auto environment = new StandardEnvironment;
    string nullProfile = null;
    assertInvalid(() { environment.matchesProfiles(nullProfile); });
    assertInvalid(() { environment.matchesProfiles("p1", nullProfile); });
}

unittest
{
    // withEmptyArgument
    auto environment = new StandardEnvironment;
    assertInvalid(() { environment.matchesProfiles(""); });
    assertInvalid(() { environment.matchesProfiles("p1", ""); });
    assertInvalid(() { environment.matchesProfiles("p1", "      "); });
}

unittest
{
    // withInvalidNotOperator
    auto environment = new StandardEnvironment;
    assertInvalid(() { environment.matchesProfiles("p1", "!"); });
}

unittest
{
    // withInvalidCompoundExpressionGrouping
    auto environment = new StandardEnvironment;
    assertInvalid(() { environment.matchesProfiles("p1 | p2 & p3"); });
    assertInvalid(() { environment.matchesProfiles("p1 & p2 | p3"); });
    assertInvalid(() { environment.matchesProfiles("p1 & (p2 | p3) | p4"); });
}

unittest
{
    // activeProfileSetProgrammatically
    auto environment = new StandardEnvironment;
    assert(!environment.matchesProfiles("p1", "p2"));
    environment.setActiveProfiles("p1");
    assert(environment.matchesProfiles("p1", "p2"));
    environment.setActiveProfiles("p2");
    assert(environment.matchesProfiles("p1", "p2"));
    environment.setActiveProfiles("p1", "p2");
    assert(environment.matchesProfiles("p1", "p2"));
}

unittest
{
    // activeProfileSetViaProperty
    auto environment = new StandardEnvironment;
    assert(!environment.matchesProfiles("p1"));
    environment.getPropertySources().addFirst(new MockPropertySource()
            .withProperty(ACTIVE_PROFILES_PROPERTY_NAME, "p1"));
    assert(environment.matchesProfiles("p1"));
}

unittest
{
    // defaultProfile
    auto environment = new StandardEnvironment;
    assert(!environment.matchesProfiles("pd"));
    environment.setDefaultProfiles("pd");
    assert(environment.matchesProfiles("pd"));
    environment.setActiveProfiles("p1");
    assert(!environment.matchesProfiles("pd"));
    assert(environment.matchesProfiles("p1"));
}

unittest
{
    // withNotOperator
    auto environment = new StandardEnvironment;
    assert(!environment.matchesProfiles("p1"));
    assert(environment.matchesProfiles("!p1"));
    environment.addActiveProfile("p1");
    assert(environment.matchesProfiles("p1"));
    assert(!environment.matchesProfiles("!p1"));
}

unittest
{
    // withProfileExpressions
    auto environment = new StandardEnvironment;
    assert(!environment.matchesProfiles("p1 & p2"));
    environment.addActiveProfile("p1");
    assert(environment.matchesProfiles("p1 | p2"));
    assert(!environment.matchesProfiles("p1 & p2"));
    environment.addActiveProfile("p2");
    assert(environment.matchesProfiles("p1 & p2"));
    assert(environment.matchesProfiles("p1 | p2"));
    assert(environment.matchesProfiles("foo | p1", "p2"));
    assert(environment.matchesProfiles("foo | p2", "p1"));
    assert(environment.matchesProfiles("foo | (p2 & p1)"));
    assert(environment.matchesProfiles("p2 & (foo | p1)"));
    assert(environment.matchesProfiles("foo", "(p2 & p1)"));
}
