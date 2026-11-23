// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
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
 * spring-core/src/test/java/org/springframework/core/AttributeAccessorSupportTests.java.
 *
 * Skipped Java tests: none. Attribute values are `Any` (rulebook "Erased types"); computeAttribute is declared on
 * AttributeAccessorSupport (Java's AttributeAccessor default method), so the accessor is typed as the support class.
 */
module flint.core.attribute_test;

import flint.core : AttributeAccessor, AttributeAccessorSupport;
import flint.engine.aot.any : Any;
import flint.java.lang : valueOf;

@safe:

private enum NAME = "name";
private enum VALUE = "value";

private class SimpleAttributeAccessorSupport : AttributeAccessorSupport
{
}

unittest
{
    // setAndGet
    AttributeAccessor attributeAccessor = new SimpleAttributeAccessorSupport;
    attributeAccessor.setAttribute(NAME, Any.of(VALUE));
    assert(attributeAccessor.getAttribute(NAME).get!string == VALUE);
}

unittest
{
    // setAndHas
    AttributeAccessor attributeAccessor = new SimpleAttributeAccessorSupport;
    assert(!attributeAccessor.hasAttribute(NAME));
    attributeAccessor.setAttribute(NAME, Any.of(VALUE));
    assert(attributeAccessor.hasAttribute(NAME));
}

unittest
{
    // computeAttribute
    AttributeAccessorSupport attributeAccessor = new SimpleAttributeAccessorSupport;
    int atomicInteger;
    Any computeFunction(string)
    {
        return Any.of("computed-" ~ valueOf(++atomicInteger));
    }

    assert(!attributeAccessor.hasAttribute(NAME));
    attributeAccessor.computeAttribute(NAME, &computeFunction);
    assert(attributeAccessor.getAttribute(NAME).get!string == "computed-1");
    attributeAccessor.computeAttribute(NAME, &computeFunction);
    assert(attributeAccessor.getAttribute(NAME).get!string == "computed-1");
    attributeAccessor.removeAttribute(NAME);
    assert(!attributeAccessor.hasAttribute(NAME));
    attributeAccessor.computeAttribute(NAME, &computeFunction);
    assert(attributeAccessor.getAttribute(NAME).get!string == "computed-2");
}

unittest
{
    // remove
    AttributeAccessor attributeAccessor = new SimpleAttributeAccessorSupport;
    assert(!attributeAccessor.hasAttribute(NAME));
    attributeAccessor.setAttribute(NAME, Any.of(VALUE));
    assert(attributeAccessor.removeAttribute(NAME).get!string == VALUE);
    assert(!attributeAccessor.hasAttribute(NAME));
}

unittest
{
    // attributeNames
    AttributeAccessor attributeAccessor = new SimpleAttributeAccessorSupport;
    attributeAccessor.setAttribute(NAME, Any.of(VALUE));
    attributeAccessor.setAttribute("abc", Any.of("123"));
    auto names = attributeAccessor.attributeNames();
    foreach (expected; ["abc", NAME])
    {
        bool found;
        foreach (name; names)
            found |= name == expected;
        assert(found, expected);
    }
}
