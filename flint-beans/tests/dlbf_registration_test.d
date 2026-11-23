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
 * (registration, aliases, overriding, singletons and prototypes, references).
 */

/++
`DefaultListableBeanFactoryTests`, part 1: registration. A Java test that registers `new RootBeanDefinition(X.class)`
uses the record Flint AOT emits for `X`; property references (`RuntimeBeanReference`, autowiring markers) become the
generated `initialize` function that resolves them through the contract's `BeanFactory`.

The 190 Java tests are split over `dlbf_registration_test`, `dlbf_resolution_test` and `dlbf_lifecycle_test`; the
skipped ones are listed in `dlbf_lifecycle_test`.
+/
module flint.beans.dlbf_registration_test;

import flint.beans : BeansException;
import flint.beans.dlbf_fixtures : containsCause, definitionOf, ITestBean, KnowsIfInstantiated,
    NestedTestBean, TestBean, testBeanDefinition, withInitialize;
import flint.beans.factory : BeanCreationException, BeanCurrentlyInCreationException;
import flint.beans.factory.config : BeanDefinition;
import flint.beans.factory.support : BeanDefinitionOverrideException, DefaultListableBeanFactory;
import flint.engine.aot.bean : AotBeanFactory = BeanFactory;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : IllegalStateException, valueOf;
import flint.util : StringValueResolver;
import std.exception : assertThrown, collectException;

@safe:

private void spouseRod(Object bean, AotBeanFactory factory)
{
    (cast(TestBean) bean).setSpouse(cast(ITestBean) factory.getBean("rod"));
}

private void spouseKerry(Object bean, AotBeanFactory factory)
{
    (cast(TestBean) bean).setSpouse(cast(ITestBean) factory.getBean("kerry"));
}

private void spouseSelf(Object bean, AotBeanFactory factory)
{
    (cast(TestBean) bean).setSpouse(cast(ITestBean) factory.getBean("self"));
}

private void spouseSingletonObject(Object bean, AotBeanFactory factory)
{
    (cast(TestBean) bean).setSpouse(cast(ITestBean) factory.getBean("singletonObject"));
}

private void doctorByName(Object bean, AotBeanFactory factory)
{
    (cast(TestBean) bean).setDoctor(factory.getBean("doc"));
}

private void doctorByType(Object bean, AotBeanFactory factory)
{
    (cast(TestBean) bean).setDoctor(factory.getBeanOfType(typeNameOf!NestedTestBean));
}

private final class DependenciesBean
{
    TestBean spouse;
}

private void spouseByType(Object bean, AotBeanFactory factory)
{
    (cast(DependenciesBean) bean).spouse = cast(TestBean) factory.getBeanOfType(typeNameOf!TestBean);
}

unittest
{
    // unreferencedSingletonWasInstantiated
    auto lbf = new DefaultListableBeanFactory;
    KnowsIfInstantiated.clearInstantiationRecord();
    assert(!KnowsIfInstantiated.wasInstantiated(), "singleton not instantiated");
    lbf.registerBeanDefinition("x1", definitionOf!KnowsIfInstantiated());
    lbf.preInstantiateSingletons();
    assert(KnowsIfInstantiated.wasInstantiated(), "singleton was instantiated");
}

unittest
{
    // lazyInitialization
    auto lbf = new DefaultListableBeanFactory;
    KnowsIfInstantiated.clearInstantiationRecord();
    auto definition = definitionOf!KnowsIfInstantiated();
    definition.setLazyInit(true);
    lbf.registerBeanDefinition("x1", definition);
    assert(!KnowsIfInstantiated.wasInstantiated(), "singleton not instantiated");
    lbf.preInstantiateSingletons();
    assert(!KnowsIfInstantiated.wasInstantiated(), "singleton not instantiated");
    lbf.getBean("x1");
    assert(KnowsIfInstantiated.wasInstantiated(), "singleton was instantiated");
}

unittest
{
    // empty
    auto lbf = new DefaultListableBeanFactory;
    assert(lbf.getBeanDefinitionNames().length == 0, "No beans defined after no arg constructor");
    assert(lbf.getBeanDefinitionCount() == 0, "No beans defined after no arg constructor");
}

unittest
{
    // prototype
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("kerry", testBeanDefinition());
    auto kerry1 = lbf.getBean("kerry");
    assert(kerry1 !is null && kerry1 is lbf.getBean("kerry"), "Singletons equal");

    auto prototype = testBeanDefinition();
    prototype.setScope(BeanDefinition.SCOPE_PROTOTYPE);
    lbf.registerBeanDefinition("kerry", prototype);
    kerry1 = lbf.getBean("kerry");
    assert(kerry1 !is null && kerry1 !is lbf.getBean("kerry"), "Prototypes NOT equal");

    auto singleton = testBeanDefinition();
    singleton.setScope("singleton");
    lbf.registerBeanDefinition("kerry", singleton);
    kerry1 = lbf.getBean("kerry");
    assert(kerry1 !is null && kerry1 is lbf.getBean("kerry"), "Specified singletons equal");
}

unittest
{
    // prototypeCircleLeadsToException
    auto lbf = new DefaultListableBeanFactory;
    auto kerry = withInitialize(testBeanDefinition(), &spouseRod);
    kerry.setScope(BeanDefinition.SCOPE_PROTOTYPE);
    auto rod = withInitialize(testBeanDefinition(), &spouseKerry);
    rod.setScope(BeanDefinition.SCOPE_PROTOTYPE);
    lbf.registerBeanDefinition("kerry", kerry);
    lbf.registerBeanDefinition("rod", rod);
    auto e = collectException!BeanCreationException(lbf.getBean("kerry"));
    assert(e !is null && containsCause!BeanCurrentlyInCreationException(e));
}

unittest
{
    // unresolvedReference
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("kerry", withInitialize(testBeanDefinition(), &spouseRod));
    assertThrown!BeansException(lbf.getBean("kerry"), "unresolved reference");
}

unittest
{
    // selfReference
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("self", withInitialize(testBeanDefinition(), &spouseSelf));
    auto self = cast(TestBean) lbf.getBean("self");
    assert(self.getSpouse() is self);
}

unittest
{
    // referenceByName
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("self", withInitialize(testBeanDefinition(), &doctorByName));
    lbf.registerBeanDefinition("doc", definitionOf!NestedTestBean());
    auto self = cast(TestBean) lbf.getBean("self");
    assert(self.getDoctor() is lbf.getBean("doc"));
}

unittest
{
    // referenceByType
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("self", withInitialize(testBeanDefinition(), &doctorByType));
    lbf.registerBeanDefinition("doc", definitionOf!NestedTestBean());
    auto self = cast(TestBean) lbf.getBean("self");
    assert(self.getDoctor() is lbf.getBean("doc"));
}

unittest
{
    // referenceByAutowire
    // An autowired property is a by-type lookup in the generated initializer.
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("self", withInitialize(testBeanDefinition(), &doctorByType));
    lbf.registerBeanDefinition("doc", definitionOf!NestedTestBean());
    auto self = cast(TestBean) lbf.getBean("self");
    assert(self.getDoctor() is lbf.getBean("doc"));
}

unittest
{
    // aliasCircle
    auto lbf = new DefaultListableBeanFactory;
    lbf.setAllowBeanDefinitionOverriding(true);
    lbf.registerAlias("test", "test2");
    lbf.registerAlias("test2", "test3");
    assertThrown!IllegalStateException(lbf.registerAlias("test3", "test2"));
    assertThrown!IllegalStateException(lbf.registerAlias("test3", "test"));
    lbf.registerAlias("test", "test3");
}

unittest
{
    // aliasChaining
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("test", definitionOf!NestedTestBean());
    lbf.registerAlias("test", "testAlias");
    lbf.registerAlias("testAlias", "testAlias2");
    lbf.registerAlias("testAlias2", "testAlias3");
    const bean = lbf.getBean("test");
    assert(lbf.getBean("testAlias") is bean);
    assert(lbf.getBean("testAlias2") is bean);
    assert(lbf.getBean("testAlias3") is bean);
}

unittest
{
    // beanDefinitionOverriding
    auto lbf = new DefaultListableBeanFactory;
    lbf.setAllowBeanDefinitionOverriding(true);
    lbf.registerBeanDefinition("test", testBeanDefinition());
    // Override "test" bean definition.
    lbf.registerBeanDefinition("test", definitionOf!NestedTestBean());
    // Temporary "test2" alias for nonexistent bean.
    lbf.registerAlias("otherTest", "test2");
    // Reassign "test2" alias to "test".
    lbf.registerAlias("test", "test2");
    // Assign "testX" alias to "test" as well.
    lbf.registerAlias("test", "testX");
    // Register new "testX" bean definition which also removes the "testX" alias for "test".
    lbf.registerBeanDefinition("testX", testBeanDefinition());

    assert(cast(NestedTestBean) lbf.getBean("test") !is null);
    assert(cast(NestedTestBean) lbf.getBean("test2") !is null);
    assert(cast(TestBean) lbf.getBean("testX") !is null);
}

unittest
{
    // beanDefinitionOverridingNotAllowed
    auto lbf = new DefaultListableBeanFactory;
    lbf.setAllowBeanDefinitionOverriding(false);
    auto oldDef = testBeanDefinition();
    auto newDef = definitionOf!NestedTestBean();
    lbf.registerBeanDefinition("test", oldDef);
    lbf.registerAlias("test", "testX");

    auto e = collectException!BeanDefinitionOverrideException(lbf.registerBeanDefinition("test", newDef));
    assert(e !is null && e.getBeanName() == "test");
    assert(e.getBeanDefinition() is newDef && e.getExistingDefinition() is oldDef);

    e = collectException!BeanDefinitionOverrideException(lbf.registerBeanDefinition("testX", newDef));
    assert(e !is null && e.getBeanName() == "testX");
    assert(e.getBeanDefinition() is newDef && e.getExistingDefinition() is oldDef);
}

unittest
{
    // beanDefinitionOverridingWithAlias
    auto lbf = new DefaultListableBeanFactory;
    lbf.setAllowBeanDefinitionOverriding(true);
    lbf.registerBeanDefinition("test", testBeanDefinition());
    lbf.registerAlias("test", "testAlias");
    lbf.registerBeanDefinition("test", definitionOf!NestedTestBean());
    lbf.registerAlias("test", "testAlias");
    assert(cast(NestedTestBean) lbf.getBean("test") !is null);
    assert(cast(NestedTestBean) lbf.getBean("testAlias") !is null);
}

unittest
{
    // beanDefinitionRemoval
    auto lbf = new DefaultListableBeanFactory;
    lbf.setAllowBeanDefinitionOverriding(false);
    lbf.registerBeanDefinition("test", testBeanDefinition());
    lbf.registerAlias("test", "test2");
    lbf.preInstantiateSingletons();
    assert(cast(TestBean) lbf.getBean("test") !is null);
    assert(cast(TestBean) lbf.getBean("test2") !is null);
    lbf.removeBeanDefinition("test");
    lbf.removeAlias("test2");
    lbf.registerBeanDefinition("test", definitionOf!NestedTestBean());
    lbf.registerAlias("test", "test2");
    assert(cast(NestedTestBean) lbf.getBean("test") !is null);
    assert(cast(NestedTestBean) lbf.getBean("test2") !is null);
}

unittest
{
    // concurrentBeanDefinitionRemoval
    // gh-23542. A factory belongs to one fiber in Flint: the removals run in sequence.
    enum max = 200;
    auto lbf = new DefaultListableBeanFactory;
    lbf.setAllowBeanDefinitionOverriding(false);
    foreach (i; 0 .. max)
        lbf.registerBeanDefinition("test" ~ valueOf(i), testBeanDefinition());
    lbf.preInstantiateSingletons();
    foreach (i; 0 .. max)
        lbf.removeBeanDefinition("test" ~ valueOf(i));
    assert(lbf.getBeanDefinitionCount() == 0 && lbf.getSingletonCount() == 0);
}

unittest
{
    // registerExistingSingletonWithReference
    // (getBeansOfType(null) and getBeanNamesIterator have no Flint counterpart.)
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("test", withInitialize(testBeanDefinition(), &spouseSingletonObject));
    auto singletonObject = new TestBean;
    lbf.registerSingleton("singletonObject", singletonObject);

    assert(lbf.isSingleton("singletonObject"));
    assert(lbf.getTypeName("singletonObject") == typeNameOf!TestBean);
    auto test = cast(TestBean) lbf.getBean("test");
    assert(lbf.getBean("singletonObject") is singletonObject);
    assert(test.getSpouse() is singletonObject);

    auto beansOfType = lbf.getBeansOfType!TestBean(false, true);
    assert(beansOfType.size() == 2);
    assert(beansOfType.containsValue(test) && beansOfType.containsValue(singletonObject));

    assert(lbf.containsSingleton("test") && lbf.containsSingleton("singletonObject"));
    assert(lbf.containsBeanDefinition("test") && !lbf.containsBeanDefinition("singletonObject"));
}

unittest
{
    // registerExistingSingletonWithNameOverriding
    // The overridden definition is a plain bean here (Java uses a PropertiesFactoryBean).
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("test", withInitialize(testBeanDefinition(), &spouseSingletonObject));
    lbf.registerBeanDefinition("singletonObject", definitionOf!NestedTestBean());
    auto singletonObject = new TestBean;
    lbf.registerSingleton("singletonObject", singletonObject);
    lbf.preInstantiateSingletons();

    assert(lbf.isSingleton("singletonObject"));
    assert(lbf.getTypeName("singletonObject") == typeNameOf!TestBean);
    auto test = cast(TestBean) lbf.getBean("test");
    assert(lbf.getBean("singletonObject") is singletonObject);
    assert(test.getSpouse() is singletonObject);

    auto beansOfType = lbf.getBeansOfType!TestBean(false, true);
    assert(beansOfType.size() == 2);
    assert(beansOfType.containsValue(test) && beansOfType.containsValue(singletonObject));

    assert(lbf.containsSingleton("test") && lbf.containsSingleton("singletonObject"));
    assert(lbf.containsBeanDefinition("test") && lbf.containsBeanDefinition("singletonObject"));
}

unittest
{
    // registerExistingSingletonWithAutowire
    // DependenciesBean's autowired spouse is a by-type lookup in its generated initializer.
    auto lbf = new DefaultListableBeanFactory;
    auto dependencies = withInitialize(definitionOf!DependenciesBean(), &spouseByType);
    lbf.registerBeanDefinition("test", dependencies);
    auto singletonObject = new TestBean;
    lbf.registerSingleton("singletonObject", singletonObject);

    assert(lbf.containsBean("singletonObject"));
    assert(lbf.isSingleton("singletonObject"));
    assert(lbf.getTypeName("singletonObject") == typeNameOf!TestBean);
    assert(lbf.getAliases("singletonObject").length == 0);
    auto test = cast(DependenciesBean) lbf.getBean("test");
    assert(lbf.getBean("singletonObject") is singletonObject);
    assert(test.spouse is singletonObject);
}

unittest
{
    // registerExistingSingletonWithAlreadyBound
    auto lbf = new DefaultListableBeanFactory;
    auto singletonObject = new TestBean;
    lbf.registerSingleton("singletonObject", singletonObject);
    assertThrown!IllegalStateException(lbf.registerSingleton("singletonObject", singletonObject));
}

unittest
{
    // reregisterBeanDefinition
    auto lbf = new DefaultListableBeanFactory;
    lbf.setAllowBeanDefinitionOverriding(true);
    auto bd1 = testBeanDefinition();
    bd1.setScope(BeanDefinition.SCOPE_PROTOTYPE);
    lbf.registerBeanDefinition("testBean", bd1);
    assert(lbf.getBeanDefinition("testBean").getScope() == BeanDefinition.SCOPE_PROTOTYPE);
    assert(cast(TestBean) lbf.getBean("testBean") !is null);

    auto bd2 = definitionOf!NestedTestBean();
    bd2.setScope(BeanDefinition.SCOPE_SINGLETON);
    lbf.registerBeanDefinition("testBean", bd2);
    assert(lbf.getBeanDefinition("testBean").getScope() == BeanDefinition.SCOPE_SINGLETON);
    assert(cast(NestedTestBean) lbf.getBean("testBean") !is null);
}

unittest
{
    // containsBeanReturnsTrueEvenForAbstractBeanDefinition
    auto lbf = new DefaultListableBeanFactory;
    auto definition = testBeanDefinition();
    definition.setAbstract(true);
    lbf.registerBeanDefinition("abs", definition);
    assert(lbf.containsBean("abs"));
    assert(!lbf.containsBean("bogus"));
}

private final class RecordingResolver : StringValueResolver
{
    string[] calls;
    private string from, to;

    this(string from, string to) pure nothrow @nogc
    {
        this.from = from;
        this.to = to;
    }

    string resolveStringValue(string strVal)
    {
        calls ~= strVal is null ? "<null>" : strVal;
        return strVal == from ? to : strVal;
    }
}

unittest
{
    // resolveEmbeddedValue
    auto lbf = new DefaultListableBeanFactory;
    auto r1 = new RecordingResolver("A", "B");
    auto r2 = new RecordingResolver("B", null);
    auto r3 = new RecordingResolver(null, null);
    lbf.addEmbeddedValueResolver(r1);
    lbf.addEmbeddedValueResolver(r2);
    lbf.addEmbeddedValueResolver(r3);
    lbf.resolveEmbeddedValue("A");
    assert(r1.calls == ["A"]);
    assert(r2.calls == ["B"]);
    assert(r3.calls.length == 0);
}

unittest
{
    // scopingBeanToUnregisteredScopeResultsInAnException
    auto lbf = new DefaultListableBeanFactory;
    auto definition = testBeanDefinition();
    definition.setScope("he put himself so low could hardly look me in the face");
    lbf.registerBeanDefinition("testBean", definition);
    assertThrown!IllegalStateException(lbf.getBean("testBean"));
}

unittest
{
    // lazyInitFlag
    // Flint's definitions have no "unset" laziness: an unset flag reads false.
    auto factory = new DefaultListableBeanFactory;
    auto bd1 = testBeanDefinition();
    bd1.setLazyInit(true);
    factory.registerBeanDefinition("tb1", bd1);
    auto bd2 = testBeanDefinition();
    bd2.setLazyInit(false);
    factory.registerBeanDefinition("tb2", bd2);
    factory.registerBeanDefinition("tb3", testBeanDefinition());

    assert(factory.getBeanDefinition("tb1").isLazyInit());
    assert(!factory.getBeanDefinition("tb2").isLazyInit());
    assert(!factory.getBeanDefinition("tb3").isLazyInit());

    factory.preInstantiateSingletons();
    assert(!factory.containsSingleton("tb1"));
    assert(factory.containsSingleton("tb2"));
    assert(factory.containsSingleton("tb3"));
}
