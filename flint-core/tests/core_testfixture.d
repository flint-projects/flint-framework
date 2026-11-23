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
 * spring-core/src/testFixtures/java/org/springframework/core/testfixture/env/MockPropertySource.java. Spring's
 * fixture extends PropertiesPropertySource over java.util.Properties; this one is a MapPropertySource over a
 * LinkedHashMap, since Flint has no java.util.Properties.
 */

/++
Test fixtures shared by the `flint:core` tests: Spring's `MockPropertySource`.
+/
module flint.core.testfixture;

import flint.core.env : MapPropertySource;
import flint.engine.aot.any : Any;
import flint.java.util : LinkedHashMap, Map;

@safe:

/++
A simple `PropertySource` for testing: properties are set with `setProperty` or the fluent `withProperty`. Its
name defaults to `mockProperties`.
+/
class MockPropertySource : MapPropertySource
{
    /// The name given to a `MockPropertySource` created without one.
    enum MOCK_PROPERTIES_PROPERTY_SOURCE_NAME = "mockProperties";

    /// An empty source named `mockProperties`.
    this()
    {
        this(MOCK_PROPERTIES_PROPERTY_SOURCE_NAME);
    }

    /// An empty source named `name`.
    this(string name)
    {
        this(name, new LinkedHashMap!(string, Any)());
    }

    /// A source named `mockProperties` over `properties`.
    this(Map!(string, Any) properties)
    {
        this(MOCK_PROPERTIES_PROPERTY_SOURCE_NAME, properties);
    }

    /// A source named `name` over `properties`.
    this(string name, Map!(string, Any) properties)
    {
        super(name, properties);
    }

    /// Set `name` to `value`.
    void setProperty(string name, Any value)
    {
        map.put(name, value);
    }

    /// Set `name` to `value` and return this source.
    MockPropertySource withProperty(T)(string name, T value)
    {
        setProperty(name, Any.of(value));
        return this;
    }
}
