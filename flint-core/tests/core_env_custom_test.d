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
 * spring-core/src/test/java/org/springframework/core/env/CustomEnvironmentTests.java.
 *
 * Skipped Java tests: none. withCustomPropertyResolver overrides `getPropertyErased`, the virtual primitive behind
 * the `final` `getProperty` overloads (deviation D-22), where Java overrides `getProperty(String)`.
 */
module flint.core.env_custom_test;

import flint.core.convert : TypeDescriptor;
import flint.core.env : AbstractEnvironment, ConfigurableEnvironment, ConfigurablePropertyResolver,
    Environment, MapPropertySource, MutablePropertySources, PropertySources, PropertySourcesPropertyResolver;
import flint.engine.aot.any : Any;
import flint.java.util : LinkedHashMap;

@safe:

private enum DEFAULT_PROFILE = AbstractEnvironment.RESERVED_DEFAULT_PROFILE_NAME;

private class CustomEnvironment : AbstractEnvironment
{
    private string[] reserved;

    this(string[] reserved...)
    {
        // The field is set before the base constructor calls getReservedDefaultProfiles, as Java's anonymous
        // subclass returns a constant.
        this.reserved = reserved.dup;
        super();
    }

    protected override string[] getReservedDefaultProfiles()
    {
        return reserved;
    }
}

private class CustomPropertySourcesPropertyResolver : PropertySourcesPropertyResolver
{
    this(PropertySources propertySources)
    {
        super(propertySources);
    }

    override Any getPropertyErased(string key, const TypeDescriptor targetType)
    {
        auto value = super.getPropertyErased(key, targetType);
        if (targetType.getName() != "string")
            return value;
        return Any.of((value.isNull ? "null" : value.get!string) ~ "-test");
    }
}

unittest
{
    // control
    Environment env = new class AbstractEnvironment
    {
    };
    assert(env.matchesProfiles(DEFAULT_PROFILE));
}

unittest
{
    // withNoReservedDefaultProfile
    Environment env = new CustomEnvironment();
    assert(!env.matchesProfiles(DEFAULT_PROFILE));
}

unittest
{
    // withSingleCustomReservedDefaultProfile
    Environment env = new CustomEnvironment("rd1");
    assert(!env.matchesProfiles(DEFAULT_PROFILE));
    assert(env.matchesProfiles("rd1"));
}

unittest
{
    // withMultiCustomReservedDefaultProfile
    ConfigurableEnvironment env = new CustomEnvironment("rd1", "rd2");
    assert(!env.matchesProfiles(DEFAULT_PROFILE));
    assert(env.matchesProfiles("rd1 | rd2"));
    // finally, issue additional assertions to cover all combinations of calling these methods, however unlikely.
    env.setDefaultProfiles("d1");
    assert(!env.matchesProfiles("rd1 | rd2"));
    assert(env.matchesProfiles("d1"));
    env.setActiveProfiles("a1", "a2");
    assert(!env.matchesProfiles("d1"));
    assert(env.matchesProfiles("a1 | a2"));
    env.setActiveProfiles();
    assert(env.matchesProfiles("d1"));
    assert(!env.matchesProfiles("a1 | a2"));
    env.setDefaultProfiles();
    assert(!env.matchesProfiles(DEFAULT_PROFILE));
    assert(!env.matchesProfiles("rd1 | rd2"));
    assert(!env.matchesProfiles("d1"));
    assert(!env.matchesProfiles("a1 | a2"));
}

unittest
{
    // withNoProfileProperties
    ConfigurableEnvironment env = new class AbstractEnvironment
    {
        protected override string doGetActiveProfilesProperty()
        {
            return null;
        }

        protected override string doGetDefaultProfilesProperty()
        {
            return null;
        }
    };
    auto values = new LinkedHashMap!(string, Any)();
    values.put(AbstractEnvironment.ACTIVE_PROFILES_PROPERTY_NAME, Any.of("a,b,c"));
    values.put(AbstractEnvironment.DEFAULT_PROFILES_PROPERTY_NAME, Any.of("d,e,f"));
    env.getPropertySources().addFirst(new MapPropertySource("test", values));
    assert(env.getActiveProfiles().length == 0);
    assert(env.getDefaultProfiles() == [DEFAULT_PROFILE]);
}

private class CustomMutablePropertySources : MutablePropertySources
{
}

private class EnvironmentOver : AbstractEnvironment
{
    this(MutablePropertySources propertySources)
    {
        super(propertySources);
    }
}

unittest
{
    // withCustomMutablePropertySources
    MutablePropertySources propertySources = new CustomMutablePropertySources();
    ConfigurableEnvironment env = new EnvironmentOver(propertySources);
    assert(cast(CustomMutablePropertySources) env.getPropertySources() !is null);
}

unittest
{
    // withCustomPropertyResolver
    ConfigurableEnvironment env = new class AbstractEnvironment
    {
        protected override ConfigurablePropertyResolver createPropertyResolver(MutablePropertySources propertySources)
        {
            return new CustomPropertySourcesPropertyResolver(propertySources);
        }
    };
    auto values = new LinkedHashMap!(string, Any)();
    values.put("spring", Any.of("framework"));
    env.getPropertySources().addFirst(new MapPropertySource("test", values));
    assert(env.getProperty("spring") == "framework-test");
}
