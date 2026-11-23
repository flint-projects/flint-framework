// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/context/support/BeanFactoryPostProcessorTests.java
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
 * spring-context/src/test/java/org/springframework/context/support/BeanFactoryPostProcessorTests.java.
 */

/++
`BeanFactoryPostProcessorTests`. `StaticApplicationContext` is a `GenericApplicationContext` here, and its
`registerSingleton(name, X.class)` is `registerBean!X(name)`. `new RootBeanDefinition(X.class)` is the record Flint
AOT emits for `X`: its class, the types it can be injected as, and `new X()`.

Skipped Java tests (9 in the class):
- multipleDefinedBeanFactoryPostProcessors: `PropertyPlaceholderConfigurer` (deprecated for removal, not ported) and
  `MutablePropertyValues` on a programmatic definition; Flint resolves placeholders in generated code.
- beanFactoryPostProcessorWithInnerBeanAsApplicationListener: an inner `RootBeanDefinition` as a property value;
  Flint AOT has no inner bean definitions.
+/
module flint.context.bean_factory_post_processor_test;

import flint.beans.factory.config : BeanFactoryPostProcessor, ConfigurableListableBeanFactory;
import flint.beans.factory.support : DefaultListableBeanFactory, RootBeanDefinition;
import flint.context : ApplicationEvent, ApplicationListener;
import flint.context.event : ContextRefreshedEvent;
import flint.context.support : GenericApplicationContext;
import flint.engine.aot.bean : AotBeanDefinition = BeanDefinition, AotBeanFactory = BeanFactory;
import flint.engine.aot.name : typeNameOf;
import flint.util : Assert;

@safe:

private final class TestBean
{
}

private class TestBeanFactoryPostProcessor : BeanFactoryPostProcessor
{
    string initValue;
    bool wasCalled;

    void setInitValue(string initValue) pure nothrow @nogc
    {
        this.initValue = initValue;
    }

    void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory)
    {
        wasCalled = true;
    }
}

private final class ListeningBeanFactoryPostProcessor : ApplicationListener!ApplicationEvent, BeanFactoryPostProcessor
{
    ApplicationEvent received;

    void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory)
    {
    }

    override void onApplicationEvent(ApplicationEvent event)
    {
        Assert.state(received is null, "Just one ContextRefreshedEvent expected");
        received = event;
    }
}

private Object instantiate(T)(AotBeanFactory)
{
    return new T();
}

/// `new RootBeanDefinition(T.class)`: injectable as `T` and as `types`, created with `new T()`.
private RootBeanDefinition definitionOf(T)(string[] types...)
{
    AotBeanDefinition record;
    record.type = typeNameOf!T;
    record.types = typeNameOf!T ~ types;
    record.create = &instantiate!T;
    return new RootBeanDefinition(record);
}

unittest
{
    // registeredBeanFactoryPostProcessor
    auto ac = new GenericApplicationContext;
    ac.registerBean!TestBean("tb1");
    ac.registerBean!TestBean("tb2");
    auto bfpp = new TestBeanFactoryPostProcessor;
    ac.addBeanFactoryPostProcessor(bfpp);
    assert(!bfpp.wasCalled);
    ac.refresh();
    assert(bfpp.wasCalled);
    ac.close();
}

unittest
{
    // definedBeanFactoryPostProcessor
    auto ac = new GenericApplicationContext;
    ac.registerBean!TestBean("tb1");
    ac.registerBean!TestBean("tb2");
    ac.registerBean!TestBeanFactoryPostProcessor("bfpp");
    ac.refresh();
    auto bfpp = cast(TestBeanFactoryPostProcessor) ac.getBean("bfpp");
    assert(bfpp.wasCalled);
    ac.close();
}

unittest
{
    // beanFactoryPostProcessorNotExecutedByBeanFactory
    auto bf = new DefaultListableBeanFactory;
    bf.registerBeanDefinition("tb1", definitionOf!TestBean());
    bf.registerBeanDefinition("tb2", definitionOf!TestBean());
    bf.registerBeanDefinition("bfpp", definitionOf!TestBeanFactoryPostProcessor(typeNameOf!BeanFactoryPostProcessor));
    auto bfpp = cast(TestBeanFactoryPostProcessor) bf.getBean("bfpp");
    assert(!bfpp.wasCalled);
}

// Flint has no BeanDefinitionRegistryPostProcessor: AbstractApplicationContext.invokeBeanFactoryPostProcessors runs
// BeanFactoryPostProcessors only.
version (FlintBeanDefinitionRegistryPostProcessor)
{
    import flint.beans.factory.support : BeanDefinitionRegistry, BeanDefinitionRegistryPostProcessor;
    import flint.core : Ordered, PriorityOrdered;

    private final class PrioritizedBeanDefinitionRegistryPostProcessor : BeanDefinitionRegistryPostProcessor, Ordered
    {
        int getOrder()
        {
            return Ordered.HIGHEST_PRECEDENCE;
        }

        void postProcessBeanDefinitionRegistry(BeanDefinitionRegistry registry)
        {
            registry.registerBeanDefinition("bfpp1",
                    definitionOf!TestBeanFactoryPostProcessor(typeNameOf!BeanFactoryPostProcessor));
        }

        void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory)
        {
        }
    }

    private final class TestBeanDefinitionRegistryPostProcessor : BeanDefinitionRegistryPostProcessor
    {
        bool wasCalled;

        void postProcessBeanDefinitionRegistry(BeanDefinitionRegistry registry)
        {
            assert(registry.containsBeanDefinition("bfpp1"));
            registry.registerBeanDefinition("bfpp2",
                    definitionOf!TestBeanFactoryPostProcessor(typeNameOf!BeanFactoryPostProcessor));
        }

        void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory)
        {
            wasCalled = true;
        }
    }

    private class OuterBeanDefinitionRegistryPostProcessor : BeanDefinitionRegistryPostProcessor
    {
        void postProcessBeanDefinitionRegistry(BeanDefinitionRegistry registry)
        {
            registry.registerBeanDefinition("anotherpp", definitionOf!TestBeanDefinitionRegistryPostProcessor(
                    typeNameOf!BeanDefinitionRegistryPostProcessor, typeNameOf!BeanFactoryPostProcessor));
            registry.registerBeanDefinition("ppp", definitionOf!PrioritizedBeanDefinitionRegistryPostProcessor(
                    typeNameOf!BeanDefinitionRegistryPostProcessor,
                    typeNameOf!BeanFactoryPostProcessor, typeNameOf!Ordered));
        }

        void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory)
        {
        }
    }

    private final class PrioritizedOuterBeanDefinitionRegistryPostProcessor : OuterBeanDefinitionRegistryPostProcessor,
        PriorityOrdered
    {
        int getOrder()
        {
            return HIGHEST_PRECEDENCE;
        }
    }

    unittest
    {
        // beanDefinitionRegistryPostProcessor
        auto ac = new GenericApplicationContext;
        ac.registerBean!TestBean("tb1");
        ac.registerBean!TestBean("tb2");
        ac.addBeanFactoryPostProcessor(new PrioritizedBeanDefinitionRegistryPostProcessor);
        auto bdrpp = new TestBeanDefinitionRegistryPostProcessor;
        ac.addBeanFactoryPostProcessor(bdrpp);
        assert(!bdrpp.wasCalled);
        ac.refresh();
        assert(bdrpp.wasCalled);
        assert(ac.getBean!TestBeanFactoryPostProcessor("bfpp1").wasCalled);
        assert(ac.getBean!TestBeanFactoryPostProcessor("bfpp2").wasCalled);
        ac.close();
    }

    unittest
    {
        // beanDefinitionRegistryPostProcessorRegisteringAnother
        auto ac = new GenericApplicationContext;
        ac.registerBean!TestBean("tb1");
        ac.registerBean!TestBean("tb2");
        ac.registerBeanDefinition("bdrpp2", definitionOf!OuterBeanDefinitionRegistryPostProcessor(
                typeNameOf!BeanDefinitionRegistryPostProcessor, typeNameOf!BeanFactoryPostProcessor));
        ac.refresh();
        assert(ac.getBean!TestBeanFactoryPostProcessor("bfpp1").wasCalled);
        assert(ac.getBean!TestBeanFactoryPostProcessor("bfpp2").wasCalled);
        ac.close();
    }

    unittest
    {
        // prioritizedBeanDefinitionRegistryPostProcessorRegisteringAnother
        auto ac = new GenericApplicationContext;
        ac.registerBean!TestBean("tb1");
        ac.registerBean!TestBean("tb2");
        ac.registerBeanDefinition("bdrpp2",
                definitionOf!PrioritizedOuterBeanDefinitionRegistryPostProcessor(
                    typeNameOf!OuterBeanDefinitionRegistryPostProcessor,
                    typeNameOf!BeanDefinitionRegistryPostProcessor,
                    typeNameOf!BeanFactoryPostProcessor, typeNameOf!PriorityOrdered, typeNameOf!Ordered));
        ac.refresh();
        assert(ac.getBean!TestBeanFactoryPostProcessor("bfpp1").wasCalled);
        assert(ac.getBean!TestBeanFactoryPostProcessor("bfpp2").wasCalled);
        ac.close();
    }
}

unittest
{
    // beanFactoryPostProcessorAsApplicationListener
    auto ac = new GenericApplicationContext;
    ac.registerBeanDefinition("bfpp", definitionOf!ListeningBeanFactoryPostProcessor(
            typeNameOf!BeanFactoryPostProcessor, typeNameOf!(ApplicationListener!ApplicationEvent)));
    ac.refresh();
    assert(cast(ContextRefreshedEvent) ac.getBean!ListeningBeanFactoryPostProcessor().received !is null);
    ac.close();
}
