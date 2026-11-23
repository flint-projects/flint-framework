// Ported from spring-framework v7.1.0: spring-beans/src/test/java/org/springframework/beans/factory/FactoryBeanTests.java
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
 * spring-beans/src/test/java/org/springframework/beans/factory/FactoryBeanTests.java and its XML fixtures
 * spring-beans/src/test/resources/org/springframework/beans/factory/FactoryBeanTests-{returnsNull,withAutowiring,
 * abstract,circular}.xml.
 */

/++
`FactoryBeanTests`. Each XML `<bean>` is the definition Flint AOT would generate for it: `autowire="byType"`,
`<property ref>` and `<constructor-arg>` become the generated `create`/`initialize` that resolve the dependencies
through the contract's `BeanFactory`, and a FactoryBean's definition lists the types of its object in `objectTypes`
when its `getObjectType()` is known. `default-lazy-init="true"` sets every definition lazy.

`PropertyPlaceholderConfigurer` (deprecated in Spring, not ported) is a `BeanFactoryPostProcessor` bean that adds an
embedded value resolver over its properties, through which the generated `initialize` resolves `${myName}` as it
resolves `@Value`. The `${gammaFactory}`/`${gamma}` factory-bean and factory-method of `gammaFactory` are resolved at
build time: its generated `create` calls `getGamma()` on the `betaFactory` bean, and its type is unknown before it
is created, as Spring's is (the factory bean's object type is unknown), so its record types only `Object`.

A factory's null object is a null bean: Flint's `getBean` returns null where Spring returns its `NullBean`, whose
`toString()` is `"null"`.
+/
module flint.beans.factory_bean_test;

import flint.beans.dlbf_fixtures : createdBy, definitionOf, instantiate, withInitialize;
import flint.beans.factory : BeanFactory, BeanFactoryAware, FactoryBean, FactoryBeanErased, InitializingBean;
import flint.beans.factory.config : BeanFactoryPostProcessor, BeanPostProcessor, ConfigurableListableBeanFactory;
import flint.beans.factory.support : DefaultListableBeanFactory, RootBeanDefinition;
import flint.engine.aot.bean : AotBeanFactory = BeanFactory;
import flint.engine.aot.name : typeNameOf;
import flint.util : Assert, StringValueResolver;

@safe:

/// The core test fixture's `@Component` stereotype.
private struct Component
{
}

private final class NullReturningFactoryBean : FactoryBean!Object
{
    Object getObject()
    {
        return null;
    }

    Object getObjectErased()
    {
        return getObject();
    }

    string getObjectType()
    {
        return null;
    }

    bool isSingleton()
    {
        return true;
    }
}

private final class Alpha : InitializingBean
{
    private Beta beta;

    void setBeta(Beta beta) pure nothrow @nogc
    {
        this.beta = beta;
    }

    Beta getBeta() pure nothrow @nogc
    {
        return beta;
    }

    void afterPropertiesSet()
    {
        Assert.notNull(beta, "'beta' property is required");
    }
}

private final class Beta : InitializingBean
{
    private Gamma gamma;
    private string name;

    void setGamma(Gamma gamma) pure nothrow @nogc
    {
        this.gamma = gamma;
    }

    Gamma getGamma() pure nothrow @nogc
    {
        return gamma;
    }

    void setName(string name) pure nothrow @nogc
    {
        this.name = name;
    }

    string getName() const pure nothrow @nogc
    {
        return name;
    }

    void afterPropertiesSet()
    {
        Assert.notNull(gamma, "'gamma' property is required");
    }
}

private final class Gamma
{
}

@Component
private final class BetaFactoryBean : FactoryBean!Object
{
    private Beta beta;

    this(Alpha) pure nothrow @nogc
    {
    }

    void setBeta(Beta beta) pure nothrow @nogc
    {
        this.beta = beta;
    }

    Object getObject()
    {
        return beta;
    }

    Object getObjectErased()
    {
        return getObject();
    }

    string getObjectType()
    {
        return null;
    }

    bool isSingleton()
    {
        return true;
    }
}

private abstract class AbstractFactoryBean : FactoryBean!Object
{
}

private final class PassThroughFactoryBean(T) : FactoryBean!T, BeanFactoryAware
{
    mixin FactoryBean!T.Defaults;

    private string instanceName;
    private BeanFactory beanFactory;
    private T instance;

    void setInstanceName(string instanceName) pure nothrow @nogc
    {
        this.instanceName = instanceName;
    }

    void setBeanFactory(BeanFactory beanFactory)
    {
        this.beanFactory = beanFactory;
    }

    T getObject()
    {
        if (instance is null)
            instance = beanFactory.getBean!T(instanceName);
        return instance;
    }
}

private final class CountingPostProcessor : BeanPostProcessor
{
    private int[string] count;

    override Object postProcessAfterInitialization(Object bean, string beanName)
    {
        if (cast(FactoryBeanErased) bean !is null)
            return bean;
        count[beanName]++;
        return bean;
    }

    int getCount(string beanName)
    {
        return count.get(beanName, 0);
    }
}

private final class BeanImpl1
{
    private BeanImpl2 impl2;

    BeanImpl2 getImpl2() pure nothrow @nogc
    {
        return impl2;
    }

    void setImpl2(BeanImpl2 impl2) pure nothrow @nogc
    {
        this.impl2 = impl2;
    }
}

private final class BeanImpl2
{
    private BeanImpl1 impl1;

    BeanImpl1 getImpl1() pure nothrow @nogc
    {
        return impl1;
    }

    void setImpl1(BeanImpl1 impl1) pure nothrow @nogc
    {
        this.impl1 = impl1;
    }
}

/// `PropertyPlaceholderConfigurer` with `myName=yourName`: an embedded value resolver over its properties.
private final class PlaceholderConfigurer : BeanFactoryPostProcessor
{
    private static final class Resolver : StringValueResolver
    {
        string resolveStringValue(string strVal)
        {
            return strVal == "${myName}" ? "yourName" : strVal;
        }
    }

    void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory)
    {
        beanFactory.addEmbeddedValueResolver(new Resolver);
    }
}

// ---- what Flint AOT generates for the XML definitions

/// A definition of the FactoryBean `F` created by `create`, whose objects are injectable as `objectTypes`.
private RootBeanDefinition factoryOf(F)(string[] objectTypes, Object function(AotBeanFactory) @safe create)
{
    auto record = createdBy!F(create, [typeNameOf!FactoryBeanErased]).getAotDefinition();
    record.objectTypes = objectTypes;
    return new RootBeanDefinition(record);
}

/// A definition of the FactoryBean `F` created with `new F()`, whose objects are injectable as `objectTypes`.
private RootBeanDefinition factoryOf(F)(string[] objectTypes)
{
    return factoryOf!F(objectTypes, &instantiate!F);
}

private RootBeanDefinition lazy_(RootBeanDefinition rbd)
{
    rbd.setLazyInit(true);
    return rbd;
}

private void autowireBeta(Object bean, AotBeanFactory factory)
{
    auto beta = cast(Beta) bean;
    beta.setGamma(cast(Gamma) factory.getBeanOfType(typeNameOf!Gamma));
    beta.setName(factory.resolveValue("${myName}", "string").get!string);
    beta.afterPropertiesSet();
}

private void autowireAlpha(Object bean, AotBeanFactory factory)
{
    auto alpha = cast(Alpha) bean;
    alpha.setBeta(cast(Beta) factory.getBeanOfType(typeNameOf!Beta));
    alpha.afterPropertiesSet();
}

private Object createBetaFactory(AotBeanFactory factory)
{
    return new BetaFactoryBean(cast(Alpha) factory.getBeanOfType(typeNameOf!Alpha));
}

private void betaFactoryProperties(Object bean, AotBeanFactory factory)
{
    (cast(BetaFactoryBean) bean).setBeta(cast(Beta) factory.getBean("beta"));
}

private Object createGammaFactory(AotBeanFactory factory)
{
    return (cast(Beta) factory.getBean("betaFactory")).getGamma();
}

/// `gammaFactory`: a factory method on `betaFactory`, whose object type is unknown before creation.
private RootBeanDefinition gammaFactoryDefinition()
{
    auto record = createdBy!Gamma(&createGammaFactory).getAotDefinition();
    record.type = typeNameOf!Object;
    record.types = [typeNameOf!Object];
    return new RootBeanDefinition(record);
}

/// FactoryBeanTests-withAutowiring.xml.
private DefaultListableBeanFactory withAutowiringContext()
{
    auto factory = new DefaultListableBeanFactory;
    factory.registerBeanDefinition("beta", lazy_(withInitialize(definitionOf!Beta(), &autowireBeta)));
    factory.registerBeanDefinition("alpha", lazy_(withInitialize(definitionOf!Alpha(), &autowireAlpha)));
    factory.registerBeanDefinition("gamma", lazy_(definitionOf!Gamma()));
    factory.registerBeanDefinition("betaFactory", lazy_(withInitialize(factoryOf!BetaFactoryBean(null,
            &createBetaFactory), &betaFactoryProperties)));
    factory.registerBeanDefinition("gammaFactory", lazy_(gammaFactoryDefinition()));
    factory.registerBeanDefinition("propertyPlaceholderConfigurer",
            lazy_(definitionOf!PlaceholderConfigurer([typeNameOf!BeanFactoryPostProcessor])));
    return factory;
}

/// FactoryBeanTests-abstract.xml: an abstract definition, never instantiated.
private DefaultListableBeanFactory abstractContext()
{
    auto factory = new DefaultListableBeanFactory;
    auto record = definitionOf!Gamma([typeNameOf!FactoryBeanErased]).getAotDefinition();
    record.type = typeNameOf!AbstractFactoryBean;
    record.types = [typeNameOf!AbstractFactoryBean, typeNameOf!FactoryBeanErased];
    record.create = null;
    auto definition = new RootBeanDefinition(record);
    definition.setAbstract(true);
    factory.registerBeanDefinition("abstractFactoryBean", definition);
    return factory;
}

private void impl1Name(Object bean, AotBeanFactory)
{
    (cast(PassThroughFactoryBean!BeanImpl1) bean).setInstanceName("beanImpl1");
}

private void impl2Name(Object bean, AotBeanFactory)
{
    (cast(PassThroughFactoryBean!BeanImpl2) bean).setInstanceName("beanImpl2");
}

private void impl2Ref(Object bean, AotBeanFactory factory)
{
    (cast(BeanImpl1) bean).setImpl2(cast(BeanImpl2) factory.getBean("bean2"));
}

private void impl1Ref(Object bean, AotBeanFactory factory)
{
    (cast(BeanImpl2) bean).setImpl1(cast(BeanImpl1) factory.getBean("bean1"));
}

private RootBeanDefinition primary(RootBeanDefinition rbd)
{
    rbd.setPrimary(true);
    return rbd;
}

/// FactoryBeanTests-circular.xml.
private DefaultListableBeanFactory circularContext()
{
    auto factory = new DefaultListableBeanFactory;
    auto bean1 = factoryOf!(PassThroughFactoryBean!BeanImpl1)([typeNameOf!BeanImpl1]);
    factory.registerBeanDefinition("bean1", primary(withInitialize(bean1, &impl1Name)));
    factory.registerBeanDefinition("beanImpl1", withInitialize(definitionOf!BeanImpl1(), &impl2Ref));
    auto bean2 = factoryOf!(PassThroughFactoryBean!BeanImpl2)([typeNameOf!BeanImpl2]);
    factory.registerBeanDefinition("bean2", primary(withInitialize(bean2, &impl2Name)));
    factory.registerBeanDefinition("beanImpl2", withInitialize(definitionOf!BeanImpl2(), &impl1Ref));
    return factory;
}

unittest
{
    // factoryBeanReturnsNull
    auto factory = new DefaultListableBeanFactory;
    factory.registerBeanDefinition("factoryBean",
            definitionOf!NullReturningFactoryBean([typeNameOf!FactoryBeanErased]));

    assert(factory.getBean("factoryBean") is null); // Java: toString() of the NullBean is "null"
}

// A FactoryBean whose object type is unknown (getObjectType() null, not yet created) reports its own class from
// getTypeName instead of null.
version (FlintFactoryBeanUnknownObjectType)
{
    unittest
    {
        // factoryBeansWithAutowiring
        auto factory = withAutowiringContext();

        auto ppc = cast(BeanFactoryPostProcessor) factory.getBean("propertyPlaceholderConfigurer");
        ppc.postProcessBeanFactory(factory);

        assert(factory.getTypeName("betaFactory") is null);

        auto alpha = cast(Alpha) factory.getBean("alpha");
        auto beta = cast(Beta) factory.getBean("beta");
        auto gamma = cast(Gamma) factory.getBean("gamma");
        auto gamma2 = cast(Gamma) factory.getBean("gammaFactory");

        assert(alpha.getBeta() is beta);
        assert(beta.getGamma() is gamma);
        assert(beta.getGamma() is gamma2);
        assert(beta.getName() == "yourName");
    }
}

unittest
{
    // factoryBeansWithIntermediateFactoryBeanAutowiringFailure
    auto factory = withAutowiringContext();

    auto ppc = cast(BeanFactoryPostProcessor) factory.getBean("propertyPlaceholderConfigurer");
    ppc.postProcessBeanFactory(factory);

    auto beta = cast(Beta) factory.getBean("beta");
    auto alpha = cast(Alpha) factory.getBean("alpha");
    auto gamma = cast(Gamma) factory.getBean("gamma");
    assert(alpha.getBeta() is beta);
    assert(beta.getGamma() is gamma);
}

unittest
{
    // abstractFactoryBeanViaAnnotation
    auto factory = abstractContext();
    factory.getBeansWithAnnotation!Component();
}

unittest
{
    // abstractFactoryBeanViaType
    auto factory = abstractContext();
    factory.getBeansOfType!AbstractFactoryBean();
}

// A singleton FactoryBean's object reached again through a circular reference while getObject() runs is
// post-processed twice; Spring keeps the object cached by the inner call and post-processes it once.
version (FlintFactoryBeanCircularPostProcessing)
{
    unittest
    {
        // circularReferenceWithPostProcessor
        auto factory = circularContext();

        auto counter = new CountingPostProcessor;
        factory.addBeanPostProcessor(counter);

        auto impl1 = factory.getBean!BeanImpl1();
        assert(impl1 !is null);
        assert(impl1.getImpl2() !is null);
        assert(impl1.getImpl2() !is null);
        assert(impl1.getImpl2().getImpl1() is impl1);
        assert(counter.getCount("bean1") == 1);
        assert(counter.getCount("bean2") == 1);
    }
}
