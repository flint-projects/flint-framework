// Ported from spring-framework v7.1.0: spring-beans/src/test/java/org/springframework/beans/factory/support/DefaultSingletonBeanRegistryTests.java
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
 * spring-beans/src/test/java/org/springframework/beans/factory/support/DefaultSingletonBeanRegistryTests.java.
 */

/++
`DefaultSingletonBeanRegistryTests`. Flint folds Spring's `DefaultSingletonBeanRegistry` into
`DefaultListableBeanFactory`, which these tests use as the registry.

Not ported: the `singletons` assertions on `addSingletonCallback` and `getSingleton(name, ObjectFactory)`, which
Flint's registry does not have (singletons are created from definitions).
+/
module flint.beans.singleton_registry_test;

import flint.beans.dlbf_fixtures : DerivedTestBean, TestBean;
import flint.beans.factory.support : DefaultListableBeanFactory;

@safe:

/// Exposes Spring's protected `isDependent` to the test, as the Java test's same-package access does.
private final class Registry : DefaultListableBeanFactory
{
    bool dependent(string beanName, string dependentBeanName)
    {
        return isDependent(beanName, dependentBeanName);
    }
}

unittest
{
    // singletons
    auto beanRegistry = new DefaultListableBeanFactory;
    auto tb = new TestBean;
    beanRegistry.registerSingleton("tb", tb);
    assert(beanRegistry.getSingleton("tb") is tb);
    auto tb2 = new TestBean;
    beanRegistry.registerSingleton("tb2", tb2);
    assert(beanRegistry.getSingleton("tb2") is tb2);
    auto tb3 = new TestBean;
    beanRegistry.registerSingleton("tb3", tb3);
    assert(beanRegistry.getSingleton("tb3") is tb3);

    assert(beanRegistry.getSingletonCount() == 3);
    assert(beanRegistry.getSingletonNames() == ["tb", "tb2", "tb3"]);

    beanRegistry.destroySingletons();
    assert(beanRegistry.getSingletonCount() == 0);
    assert(beanRegistry.getSingletonNames().length == 0);
}

unittest
{
    // disposableBean
    auto beanRegistry = new DefaultListableBeanFactory;
    auto tb = new DerivedTestBean;
    beanRegistry.registerSingleton("tb", tb);
    beanRegistry.registerDisposableBean("tb", tb);
    assert(beanRegistry.getSingleton("tb") is tb);

    assert(beanRegistry.getSingleton("tb") is tb);
    assert(beanRegistry.getSingletonCount() == 1);
    assert(beanRegistry.getSingletonNames() == ["tb"]);
    assert(!tb.wasDestroyed());

    beanRegistry.destroySingletons();
    assert(beanRegistry.getSingletonCount() == 0);
    assert(beanRegistry.getSingletonNames().length == 0);
    assert(tb.wasDestroyed());
}

unittest
{
    // dependentRegistration
    auto beanRegistry = new Registry;
    beanRegistry.registerDependentBean("a", "b");
    beanRegistry.registerDependentBean("b", "c");
    beanRegistry.registerDependentBean("c", "b");
    assert(beanRegistry.dependent("a", "b"));
    assert(beanRegistry.dependent("b", "c"));
    assert(beanRegistry.dependent("c", "b"));
    assert(beanRegistry.dependent("a", "c"));
    assert(!beanRegistry.dependent("c", "a"));
    assert(!beanRegistry.dependent("b", "a"));
    assert(!beanRegistry.dependent("a", "a"));
    assert(beanRegistry.dependent("b", "b"));
    assert(beanRegistry.dependent("c", "c"));
}
