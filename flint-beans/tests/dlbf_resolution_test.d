// Ported from spring-framework v7.1.0: spring-beans/src/test/java/org/springframework/beans/factory/DefaultListableBeanFactoryTests.java
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
 * spring-beans/src/test/java/org/springframework/beans/factory/DefaultListableBeanFactoryTests.java
 * (lookup by type: primary, fallback, default candidates, autowire candidates, parents, depends-on).
 */

/++
`DefaultListableBeanFactoryTests`, part 2: resolution by type. Java's `getBean(Class, Object... args)` has no
counterpart (generated factories take no explicit constructor arguments), so the `getBeanByTypeInstance*` tests keep
their argument-free assertions and give the constructor argument through the generated factory.
+/
module flint.beans.dlbf_resolution_test;

import flint.beans.dlbf_fixtures : ConstructorDependency, createdBy, TestBean, testBeanDefinition;
import flint.beans.factory : BeanCreationException, NoSuchBeanDefinitionException, NoUniqueBeanDefinitionException;
import flint.beans.factory.config : BeanDefinition;
import flint.beans.factory.support : DefaultListableBeanFactory, RootBeanDefinition;
import flint.engine.aot.bean : AotBeanFactory = BeanFactory;
import flint.java.lang : IllegalArgumentException;
import std.exception : assertThrown, collectException;
import std.string : endsWith, indexOf;

@safe:

private Object create99(AotBeanFactory)
{
    return new ConstructorDependency(99);
}

private Object create43(AotBeanFactory)
{
    return new ConstructorDependency(43);
}

private Object create21(AotBeanFactory)
{
    return new ConstructorDependency(21);
}

/// Java's `createConstructorDependencyBeanDefinition(age)`: a prototype built with that spouse age.
private RootBeanDefinition constructorDependency(Object function(AotBeanFactory) @safe create)
{
    auto definition = createdBy!ConstructorDependency(create);
    definition.setScope(BeanDefinition.SCOPE_PROTOTYPE);
    return definition;
}

private string[] beanNamesOf(ConstructorDependency[] beans)
{
    string[] names;
    foreach (bean; beans)
        names ~= bean.beanName;
    return names;
}

unittest
{
    // getBeanByTypeWithNoneFound
    auto lbf = new DefaultListableBeanFactory;
    assertThrown!NoSuchBeanDefinitionException(lbf.getBean!TestBean());
}

unittest
{
    // getBeanByTypeWithLateRegistration
    auto lbf = new DefaultListableBeanFactory;
    assertThrown!NoSuchBeanDefinitionException(lbf.getBean!TestBean());
    lbf.registerBeanDefinition("bd1", testBeanDefinition());
    assert(lbf.getBean!TestBean().getBeanName() == "bd1");
}

unittest
{
    // getBeanByTypeWithLateRegistrationAgainstFrozen
    auto lbf = new DefaultListableBeanFactory;
    lbf.freezeConfiguration();
    assertThrown!NoSuchBeanDefinitionException(lbf.getBean!TestBean());
    lbf.registerBeanDefinition("bd1", testBeanDefinition());
    assert(lbf.getBean!TestBean().getBeanName() == "bd1");
}

unittest
{
    // getBeanByTypeDefinedInParent
    auto parent = new DefaultListableBeanFactory;
    parent.registerBeanDefinition("bd1", testBeanDefinition());
    auto lbf = new DefaultListableBeanFactory;
    lbf.setParentBeanFactory(parent);
    assert(lbf.getBean!TestBean().getBeanName() == "bd1");
}

unittest
{
    // getBeanByTypeWithAmbiguity
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("bd1", testBeanDefinition());
    lbf.registerBeanDefinition("bd2", testBeanDefinition());
    assertThrown!NoUniqueBeanDefinitionException(lbf.getBean!TestBean());
}

unittest
{
    // getBeanByTypeWithPrimary
    auto lbf = new DefaultListableBeanFactory;
    auto bd1 = testBeanDefinition();
    bd1.setLazyInit(true);
    auto bd2 = testBeanDefinition();
    bd2.setPrimary(true);
    lbf.registerBeanDefinition("bd1", bd1);
    lbf.registerBeanDefinition("bd2", bd2);
    lbf.registerSingleton("bd3", new TestBean);
    assert(lbf.getBean!TestBean().getBeanName() == "bd2");
    assert(!lbf.containsSingleton("bd1"));
}

unittest
{
    // getBeanByTypeWithUniqueNonFallbackDefinition
    auto lbf = new DefaultListableBeanFactory;
    auto bd1 = testBeanDefinition();
    bd1.setLazyInit(true);
    bd1.setFallback(true);
    auto bd2 = testBeanDefinition();
    bd2.setFallback(true);
    lbf.registerBeanDefinition("bd1", bd1);
    lbf.registerBeanDefinition("bd2", bd2);
    lbf.registerBeanDefinition("bd3", testBeanDefinition());
    assert(lbf.getBean!TestBean().getBeanName() == "bd3");
    assert(!lbf.containsSingleton("bd1"));
}

unittest
{
    // getBeanByTypeWithPrimaryAndUniqueNonFallbackDefinition
    auto lbf = new DefaultListableBeanFactory;
    auto bd1 = testBeanDefinition();
    bd1.setLazyInit(true);
    bd1.setFallback(true);
    auto bd2 = testBeanDefinition();
    bd2.setPrimary(true);
    bd2.setFallback(true);
    lbf.registerBeanDefinition("bd1", bd1);
    lbf.registerBeanDefinition("bd2", bd2);
    lbf.registerBeanDefinition("bd3", testBeanDefinition());
    assert(lbf.getBean!TestBean().getBeanName() == "bd2");
    assert(!lbf.containsSingleton("bd1"));
}

unittest
{
    // getBeanByTypeWithUniqueNonFallbackAndUniqueNonDefaultDefinition
    auto lbf = new DefaultListableBeanFactory;
    auto bd1 = testBeanDefinition();
    bd1.setLazyInit(true);
    bd1.setFallback(true);
    auto bd2 = testBeanDefinition();
    bd2.setFallback(true);
    bd2.setDefaultCandidate(false);
    auto bd3 = testBeanDefinition();
    bd3.setDefaultCandidate(false);
    lbf.registerBeanDefinition("bd1", bd1);
    lbf.registerBeanDefinition("bd2", bd2);
    lbf.registerBeanDefinition("bd3", bd3);
    assert(lbf.getBean!TestBean().getBeanName() == "bd3");
    assert(!lbf.containsSingleton("bd1"));
}

unittest
{
    // getBeanByTypeWithUniqueNonDefaultDefinition
    auto lbf = new DefaultListableBeanFactory;
    auto bd1 = testBeanDefinition();
    bd1.setDefaultCandidate(false);
    bd1.setLazyInit(true);
    lbf.registerBeanDefinition("bd1", bd1);
    lbf.registerBeanDefinition("bd2", testBeanDefinition());
    assert(lbf.getBean!TestBean().getBeanName() == "bd2");
    assert(!lbf.containsSingleton("bd1"));
}

unittest
{
    // getBeanByTypeWithUniqueNonDefaultSingleton
    auto lbf = new DefaultListableBeanFactory;
    auto bd1 = testBeanDefinition();
    bd1.setDefaultCandidate(false);
    bd1.setLazyInit(true);
    lbf.registerBeanDefinition("bd1", bd1);
    lbf.registerSingleton("bd2", new TestBean);
    assert(lbf.getBean!TestBean().getBeanName() is null);
    assert(!lbf.containsSingleton("bd1"));
}

unittest
{
    // getBeanByTypeWithMultiplePrimary
    auto lbf = new DefaultListableBeanFactory;
    auto bd1 = testBeanDefinition();
    bd1.setPrimary(true);
    auto bd2 = testBeanDefinition();
    bd2.setPrimary(true);
    lbf.registerBeanDefinition("bd1", bd1);
    lbf.registerBeanDefinition("bd2", bd2);
    auto e = collectException!NoUniqueBeanDefinitionException(lbf.getBean!TestBean());
    assert(e !is null && e.getMessage().endsWith("more than one 'primary' bean found among candidates: [bd1, bd2]"));
}

unittest
{
    // getBeanByTypeFiltersOutNonAutowireCandidates
    auto lbf = new DefaultListableBeanFactory;
    auto na1 = testBeanDefinition();
    na1.setAutowireCandidate(false);
    lbf.registerBeanDefinition("bd1", testBeanDefinition());
    lbf.registerBeanDefinition("na1", na1);
    const actual = lbf.getBean!TestBean(); // na1 was filtered
    assert(actual is lbf.getBean!TestBean("bd1"));
    lbf.registerBeanDefinition("bd2", testBeanDefinition());
    assertThrown!NoSuchBeanDefinitionException(lbf.getBean!TestBean());
}

unittest
{
    // getBeanByTypeWithNullRequiredType
    // A Class token is a template argument (deviation D-4): the null type reaches the erased primitive.
    auto lbf = new DefaultListableBeanFactory;
    assertThrown!IllegalArgumentException(lbf.getBeanErased(null, null, null));
}

unittest
{
    // getBeanByTypeInstanceWithNoneFound
    auto lbf = new DefaultListableBeanFactory;
    assertThrown!NoSuchBeanDefinitionException(lbf.getBean!ConstructorDependency());
    auto provider = lbf.getBeanProvider!ConstructorDependency();
    assertThrown!NoSuchBeanDefinitionException(provider.getObject());
    assert(provider.getIfAvailable() is null);
    assert(provider.getIfUnique() is null);
}

unittest
{
    // getBeanByTypeInstanceDefinedInParent
    auto parent = new DefaultListableBeanFactory;
    parent.registerBeanDefinition("bd1", constructorDependency(&create99));
    auto lbf = new DefaultListableBeanFactory;
    lbf.setParentBeanFactory(parent);

    auto bean = lbf.getBean!ConstructorDependency();
    assert(bean.beanName == "bd1" && bean.spouseAge == 99);
    auto provider = lbf.getBeanProvider!ConstructorDependency();
    bean = provider.getObject();
    assert(bean.beanName == "bd1" && bean.spouseAge == 99);
    bean = provider.getIfAvailable();
    assert(bean.beanName == "bd1" && bean.spouseAge == 99);
    bean = provider.getIfUnique();
    assert(bean.beanName == "bd1" && bean.spouseAge == 99);
}

unittest
{
    // getBeanByTypeInstanceWithAmbiguity
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("bd1", constructorDependency(&create99));
    lbf.registerBeanDefinition("bd2", constructorDependency(&create43));

    assertThrown!NoUniqueBeanDefinitionException(lbf.getBean!ConstructorDependency());
    auto provider = lbf.getBeanProvider!ConstructorDependency();
    assertThrown!NoUniqueBeanDefinitionException(provider.getObject());
    assertThrown!NoUniqueBeanDefinitionException(provider.getIfAvailable());
    assert(provider.getIfUnique() is null);

    assert(beanNamesOf(provider.stream().toArray()) == ["bd1", "bd2"]);
    string[] resolved;
    provider.stream().forEach((ConstructorDependency instance) { resolved ~= instance.beanName; });
    assert(resolved == ["bd1", "bd2"]);
}

unittest
{
    // getBeanByTypeInstanceWithPrimary
    auto lbf = new DefaultListableBeanFactory;
    auto bd2 = constructorDependency(&create43);
    bd2.setPrimary(true);
    lbf.registerBeanDefinition("bd1", constructorDependency(&create99));
    lbf.registerBeanDefinition("bd2", bd2);

    auto bean = lbf.getBean!ConstructorDependency();
    assert(bean.beanName == "bd2" && bean.spouseAge == 43);
    auto provider = lbf.getBeanProvider!ConstructorDependency();
    bean = provider.getObject();
    assert(bean.beanName == "bd2" && bean.spouseAge == 43);
    bean = provider.getIfAvailable();
    assert(bean.beanName == "bd2" && bean.spouseAge == 43);
    bean = provider.getIfUnique();
    assert(bean.beanName == "bd2" && bean.spouseAge == 43);
    assert(beanNamesOf(provider.stream().toArray()) == ["bd1", "bd2"]);
}

unittest
{
    // getBeanByTypeInstanceWithMultiplePrimary
    auto lbf = new DefaultListableBeanFactory;
    auto bd1 = constructorDependency(&create99);
    auto bd2 = constructorDependency(&create43);
    bd1.setPrimary(true);
    bd2.setPrimary(true);
    lbf.registerBeanDefinition("bd1", bd1);
    lbf.registerBeanDefinition("bd2", bd2);
    auto e = collectException!NoUniqueBeanDefinitionException(lbf.getBean!ConstructorDependency());
    assert(e !is null && e.getMessage().endsWith("more than one 'primary' bean found among candidates: [bd1, bd2]"));
}

unittest
{
    // getBeanByTypeInstanceFiltersOutNonAutowireCandidates
    auto lbf = new DefaultListableBeanFactory;
    auto na1 = constructorDependency(&create21);
    na1.setAutowireCandidate(false);
    lbf.registerBeanDefinition("bd1", constructorDependency(&create99));
    lbf.registerBeanDefinition("na1", na1);
    assert(lbf.getBean!ConstructorDependency().beanName == "bd1"); // na1 was filtered
    lbf.registerBeanDefinition("bd2", constructorDependency(&create43));
    assertThrown!NoSuchBeanDefinitionException(lbf.getBean!TestBean());
}

unittest
{
    // dependsOnCycle
    auto lbf = new DefaultListableBeanFactory;
    auto bd1 = testBeanDefinition();
    bd1.setDependsOn("tb2");
    lbf.registerBeanDefinition("tb1", bd1);
    auto bd2 = testBeanDefinition();
    bd2.setDependsOn("tb1");
    lbf.registerBeanDefinition("tb2", bd2);
    auto e = collectException!BeanCreationException(lbf.preInstantiateSingletons());
    assert(e !is null && e.msg.indexOf("Circular") >= 0 && e.msg.indexOf("'tb2'") >= 0 && e.msg.indexOf("'tb1'") >= 0);
}

unittest
{
    // implicitDependsOnCycle
    auto lbf = new DefaultListableBeanFactory;
    auto bd1 = testBeanDefinition();
    bd1.setDependsOn("tb2");
    lbf.registerBeanDefinition("tb1", bd1);
    auto bd2 = testBeanDefinition();
    bd2.setDependsOn("tb3");
    lbf.registerBeanDefinition("tb2", bd2);
    auto bd3 = testBeanDefinition();
    bd3.setDependsOn("tb1");
    lbf.registerBeanDefinition("tb3", bd3);
    auto e = collectException!BeanCreationException(lbf.preInstantiateSingletons());
    assert(e !is null && e.msg.indexOf("Circular") >= 0 && e.msg.indexOf("'tb3'") >= 0 && e.msg.indexOf("'tb1'") >= 0);
}
