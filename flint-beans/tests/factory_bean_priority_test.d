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
 * spring-beans/src/test/java/org/springframework/beans/factory/DefaultListableBeanFactoryTests.java.
 */

/++
`DefaultListableBeanFactoryTests`' `FactoryBean` and `@Priority` tests. A definition of a `FactoryBean!T` carries
the types of its object in `objectTypes`, as Flint AOT emits it, so the factory knows the object type before it
creates the factory. `setDependencyComparator(AnnotationAwareOrderComparator.INSTANCE)` becomes a comparator over the classes'
descriptors.

Ported: getBeanNamesForTypeBeforeFactoryBeanCreation, getBeanNamesForTypeAfterFactoryBeanCreation,
getBeanNamesForTypeWithPrototypeScopedFactoryBean, getTypeForAbstractFactoryBean, getBeanByTypeWithPriority,
getBeanByTypeWithMultipleHighestPriorityCandidates, getBeanByTypeWithMultipleNonHighestPriorityCandidates,
getBeanByTypeWithPriorityAndNullInstance, getBeanByTypePrimaryHasPrecedenceOverPriority. The `autowire()` and
`mapInjectionWithPriority` variants need reflective autowiring and stay skipped (see dlbf_lifecycle_test).
+/
module flint.beans.factory_bean_priority_test;

import flint.beans.dlbf_fixtures : createdBy, definitionOf, ITestBean, TestBean, testBeanDefinition;
import flint.beans.factory : BeanIsNotAFactoryException, FactoryBean, FactoryBeanErased,
    NoUniqueBeanDefinitionException;
import flint.beans.factory.support : DefaultListableBeanFactory, RootBeanDefinition;
import flint.core.annotation.types : AnnotationAwareOrderComparator;
import flint.engine.aot.bean : AotBeanFactory = BeanFactory;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.jakarta.annotation : Priority;
import flint.java.lang : Runnable;
import std.exception : collectException;

@safe:

private interface Callable
{
    Object call();
}

private final class Widget
{
}

/// A FactoryBean that is also a `Runnable` and a `Callable`, whose object is never asked for here.
private final class FactoryBeanThatShouldntBeCalled : FactoryBean!Widget, Runnable, Callable
{
    mixin FactoryBean!Widget.Defaults;

    Widget getObject()
    {
        assert(false, "getObject must not be called");
    }

    void run()
    {
        assert(false);
    }

    Object call()
    {
        assert(false);
    }
}

/// A definition of the FactoryBean `F` whose objects are injectable as `objectTypes`: what Flint AOT emits.
private RootBeanDefinition factoryOf(F)(string[] objectTypes, string[] types = null)
{
    auto record = definitionOf!F(typeNameOf!FactoryBeanErased ~ types).getAotDefinition();
    record.objectTypes = objectTypes;
    return new RootBeanDefinition(record);
}

private RootBeanDefinition factoryDefinition()
{
    return factoryOf!FactoryBeanThatShouldntBeCalled([typeNameOf!Widget], [
        typeNameOf!Runnable, typeNameOf!Callable
    ]);
}

private void assertBeanNamesForType(DefaultListableBeanFactory lbf, string type, string[] expected...)
{
    auto actual = lbf.getBeanNamesForTypeErased(type, false, false);
    string shown;
    foreach (name; actual)
        shown ~= name ~ " ";
    assert(actual == expected, type ~ ": " ~ shown);
}

unittest
{
    // getBeanNamesForTypeBeforeFactoryBeanCreation, getBeanNamesForTypeAfterFactoryBeanCreation
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("factoryBean", factoryDefinition());
    assert(!lbf.containsSingleton("factoryBean"));
    foreach (created; [false, true])
    {
        if (created)
        {
            assert(cast(FactoryBeanThatShouldntBeCalled) lbf.getBean("&factoryBean") !is null);
            assert(lbf.containsSingleton("factoryBean"));
        }
        assertBeanNamesForType(lbf, typeNameOf!Runnable, "&factoryBean");
        assertBeanNamesForType(lbf, typeNameOf!Callable, "&factoryBean");
        assertBeanNamesForType(lbf, typeNameOf!FactoryBeanErased, "&factoryBean");
        assertBeanNamesForType(lbf, typeNameOf!Widget, "factoryBean");
        assert(lbf.isFactoryBean("factoryBean") && lbf.containsBean("&factoryBean"));
        assert(lbf.getTypeName("factoryBean") == typeNameOf!Widget);
        assert(lbf.getTypeName("&factoryBean") == typeNameOf!FactoryBeanThatShouldntBeCalled);
    }
}

unittest
{
    // getBeanNamesForTypeWithPrototypeScopedFactoryBean
    auto lbf = new DefaultListableBeanFactory;
    auto definition = factoryDefinition();
    definition.setScope("prototype");
    lbf.registerBeanDefinition("factoryBean", definition);
    assertBeanNamesForType(lbf, typeNameOf!Runnable);
    assertBeanNamesForType(lbf, typeNameOf!Callable);
    assertBeanNamesForType(lbf, typeNameOf!FactoryBeanErased);
    assert(!lbf.containsSingleton("factoryBean"));
}

unittest
{
    // getTypeForAbstractFactoryBean
    auto lbf = new DefaultListableBeanFactory;
    auto definition = factoryDefinition();
    definition.setAbstract(true);
    lbf.registerBeanDefinition("factoryBean", definition);
    assert(lbf.getTypeName("factoryBean") is null);
}

// ---- Flint: FactoryBean objects (singleton caching, prototypes, dereference, post-processing)

private final class CountingFactory : FactoryBean!TestBean
{
    mixin FactoryBean!TestBean.Defaults;

    int calls;
    bool singleton = true;

    TestBean getObject()
    {
        calls++;
        return new TestBean("made");
    }

    override bool isSingleton()
    {
        return singleton;
    }
}

private RootBeanDefinition countingDefinition()
{
    return factoryOf!CountingFactory([typeNameOf!TestBean, typeNameOf!ITestBean]);
}

unittest
{
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("tb", countingDefinition());
    lbf.registerBeanDefinition("plain", testBeanDefinition());
    lbf.preInstantiateSingletons();
    auto factory = cast(CountingFactory) lbf.getBean("&tb");
    assert(factory !is null && factory.calls == 0); // preInstantiateSingletons creates the factory, not its object
    auto made = lbf.getBean!TestBean("tb");
    assert(made.getName() == "made" && lbf.getBean("tb") is made && factory.calls == 1);
    assert(lbf.isTypeMatchErased("tb", typeNameOf!TestBean) && lbf.isTypeMatchErased("tb", typeNameOf!ITestBean));
    assert(lbf.isSingleton("tb") && lbf.isSingleton("&tb"));
    assert(collectException!BeanIsNotAFactoryException(lbf.getBean("&plain")) !is null);
    lbf.destroySingletons();
    assert(!lbf.containsSingleton("tb"));
}

unittest
{
    // A prototype object: a new one on each lookup.
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("tb", countingDefinition());
    auto factory = cast(CountingFactory) lbf.getBean("&tb");
    factory.singleton = false;
    assert(lbf.getBean("tb") !is lbf.getBean("tb") && factory.calls == 2 && !lbf.isSingleton("tb"));
}

// ---- @Priority

@Priority(5) private class HighPriorityTestBean : TestBean
{
}

@Priority(500) private class LowPriorityTestBean : TestBean
{
}

private final class NullTestBeanFactoryBean : FactoryBean!TestBean
{
    mixin FactoryBean!TestBean.Defaults;

    TestBean getObject()
    {
        return null;
    }
}

private interface PriorityService
{
}

@Priority(1) private final class PriorityService1 : PriorityService
{
}

@Priority(2) private final class PriorityService2A : PriorityService
{
}

@Priority(2) private final class PriorityService2B : PriorityService
{
}

@Priority(3) private final class PriorityService3 : PriorityService
{
}

private DefaultListableBeanFactory priorityFactory()
{
    auto table = new DescriptorTable;
    static foreach (T; imported!"std.meta".AliasSeq!(HighPriorityTestBean, LowPriorityTestBean,
            PriorityService1, PriorityService2A, PriorityService2B, PriorityService3))
        table.add(descriptorOf!T);
    auto lbf = new DefaultListableBeanFactory;
    lbf.setDependencyComparator(new AnnotationAwareOrderComparator(table));
    return lbf;
}

private RootBeanDefinition nullFactory()
{
    return factoryOf!NullTestBeanFactoryBean([typeNameOf!TestBean, typeNameOf!ITestBean]);
}

private static immutable serviceTypes = [typeNameOf!PriorityService];

private RootBeanDefinition testBeanOf(T)()
{
    return definitionOf!T([typeNameOf!TestBean, typeNameOf!ITestBean]);
}

unittest
{
    // getBeanByTypeWithPriority
    auto lbf = priorityFactory();
    lbf.registerBeanDefinition("bd1", testBeanOf!HighPriorityTestBean());
    lbf.registerBeanDefinition("bd2", testBeanOf!LowPriorityTestBean());
    lbf.registerBeanDefinition("bd3", nullFactory());
    lbf.preInstantiateSingletons();
    assert(lbf.getBean!TestBean().getBeanName() == "bd1");
}

unittest
{
    // getBeanByTypeWithMultipleHighestPriorityCandidates
    auto lbf = priorityFactory();
    lbf.registerBeanDefinition("bd1", testBeanOf!HighPriorityTestBean());
    lbf.registerBeanDefinition("bd2", testBeanOf!LowPriorityTestBean());
    lbf.registerBeanDefinition("bd3", testBeanOf!HighPriorityTestBean());
    auto e = collectException!NoUniqueBeanDefinitionException(lbf.getBean!TestBean());
    import std.algorithm.searching : canFind;

    assert(e !is null && e.msg.canFind("Multiple beans found with the same highest priority (5) among candidates: "));
}

unittest
{
    // getBeanByTypeWithMultipleNonHighestPriorityCandidates: the declaration order does not matter.
    import std.meta : AliasSeq;

    alias S1 = PriorityService1, S2A = PriorityService2A, S2B = PriorityService2B, S3 = PriorityService3;
    static foreach (order; [
            ["S1", "S2A", "S2B", "S3"], ["S3", "S2B", "S2A", "S1"], ["S2A", "S1", "S2B", "S3"],
            ["S2A", "S3", "S1", "S2B"]
        ])
    {
        {
            auto lbf = priorityFactory();
            static foreach (name; order)
                lbf.registerBeanDefinition(name, definitionOf!(mixin(name))(serviceTypes.dup));
            assert(cast(PriorityService1) lbf.getBean!PriorityService() !is null);
        }
    }
}

unittest
{
    // getBeanByTypeWithPriorityAndNullInstance
    auto lbf = priorityFactory();
    lbf.registerBeanDefinition("bd1", testBeanOf!HighPriorityTestBean());
    lbf.registerBeanDefinition("bd2", nullFactory());
    assert(lbf.getBean!TestBean().getBeanName() == "bd1");
}

unittest
{
    // getBeanByTypePrimaryHasPrecedenceOverPriority
    auto lbf = priorityFactory();
    lbf.registerBeanDefinition("bd1", testBeanOf!HighPriorityTestBean());
    auto bd2 = testBeanDefinition();
    bd2.setPrimary(true);
    lbf.registerBeanDefinition("bd2", bd2);
    assert(lbf.getBean!TestBean().getBeanName() == "bd2");
}
