// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/context/annotation/AnnotationConfigApplicationContextTests.java
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
 * spring-context/src/test/java/org/springframework/context/annotation/AnnotationConfigApplicationContextTests.java.
 */

/++
`AnnotationConfigApplicationContextTests`. `new AnnotationConfigApplicationContext(Config.class)` and
`register(Config.class)` load the registry Flint AOT generates for the configuration classes: one definition per
class and per `@Bean` method, the `X__FlintConfiguration` subclass that routes inter-bean calls to the container
(contract section 5.3), and a descriptor carrying the merged annotations. A Java `String` bean is a `Name` here.
Bean names follow the generator's rule for module-level D classes (`config`), where Java's nested test classes are
named `annotationConfigApplicationContextTests.Config`.

Skipped Java tests (36 in the class):
- scanAndRefresh, scanAndRefreshWithFullyQualifiedBeanNames: runtime classpath scanning (Flint AOT scans at build
  time).
- registerAndRefreshWithFullyQualifiedBeanNames, registerAndRefreshWithOverlappingFullyQualifiedBeanNames:
  `setBeanNameGenerator` (names are decided at build time).
- individualBeanWithSpecifiedConstructorArguments, individualNamedBeanWithSpecifiedConstructorArguments,
  individualBeanWithMixedConstructorArguments, individualNamedBeanWithMixedConstructorArguments: explicit constructor
  arguments resolved by reflection.
- individualBeanWithFactoryBeanSupplier, individualBeanWithFactoryBeanSupplierAndTargetType,
  individualBeanWithFactoryBeanTypeAsTargetType, individualBeanWithUnresolvedFactoryBeanTypeAsTargetType,
  individualBeanWithFactoryBeanObjectTypeAsTargetType, individualBeanWithFactoryBeanObjectTypeAsTargetTypeAndLazy:
  FactoryBean (not supported in Phase 1).
- refreshForAotProcessingWithConfiguration, refreshForAotCanInstantiateBeanWithAutowiredApplicationContext,
  refreshForAotCanInstantiateBeanWithFieldAutowiredApplicationContext, refreshForAotRegisterHintsForCglibProxy,
  refreshForAotRegisterHintsForTargetOfCglibProxy, refreshForAotRegisterDoesNotConsiderLambdaBeanAsCglibProxy:
  `refreshForAotProcessing` and `RuntimeHints`.
+/
module flint.context.annotation_config_context_test;

import flint.beans.factory : NoSuchBeanDefinitionException, NoUniqueBeanDefinitionException;
import flint.beans.factory.config : BeanDefinition, BeanPostProcessor;
import flint.context : ApplicationContext, ApplicationContextAware;
import flint.context.annotation : AnnotationConfigApplicationContext, Configuration;
import flint.engine.aot.bean : AotBeanDefinition = BeanDefinition, BeanFactory;
import flint.engine.aot.descriptor : descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.engine.aot.registry : AotRegistry;
import std.exception : assertThrown, collectException;
import std.string : indexOf;

@safe:

private final class TestBean
{
    string name;
}

/// Java's `String` bean.
private final class Name
{
    string value;

    this(string value) pure nothrow @nogc
    {
        this.value = value;
    }
}

@Configuration
private class Config
{
    TestBean testBean()
    {
        auto testBean = new TestBean;
        testBean.name = "foo";
        return testBean;
    }
}

@Configuration("customConfigBeanName")
private class ConfigWithCustomName
{
    TestBean testBean()
    {
        return new TestBean;
    }
}

@Configuration
private class TwoTestBeanConfig
{
    TestBean tb1()
    {
        return new TestBean;
    }

    TestBean tb2()
    {
        return new TestBean;
    }
}

@Configuration
private class NameConfig
{
    Name name()
    {
        return new Name("foo");
    }

    /// `@Bean(autowireCandidate = false)`
    Name prefixName()
    {
        return new Name("bar" ~ name().value);
    }
}

@Configuration
private class AutowiredConfig
{
    Name autowiredName; // @Autowired

    TestBean testBean()
    {
        auto testBean = new TestBean;
        testBean.name = autowiredName.value;
        return testBean;
    }
}

// ---- what Flint AOT generates for the configuration classes

/// NameConfig's proxyBeanMethods subclass: `name()` returns the container's singleton.
private final class NameConfig__FlintConfiguration : NameConfig
{
    private BeanFactory factory;

    this(BeanFactory factory) pure nothrow @nogc
    {
        this.factory = factory;
    }

    override Name name()
    {
        return cast(Name) factory.getBean("name");
    }

    Name superName()
    {
        return super.name();
    }
}

private Object create(T)(BeanFactory)
{
    return new T;
}

private Object createNameConfig(BeanFactory factory)
{
    return new NameConfig__FlintConfiguration(factory);
}

private Object createConfigTestBean(BeanFactory factory)
{
    return (cast(Config) factory.getBean("config")).testBean();
}

private Object createCustomTestBean(BeanFactory factory)
{
    return (cast(ConfigWithCustomName) factory.getBean("customConfigBeanName")).testBean();
}

private Object createTb1(BeanFactory factory)
{
    return (cast(TwoTestBeanConfig) factory.getBean("twoTestBeanConfig")).tb1();
}

private Object createTb2(BeanFactory factory)
{
    return (cast(TwoTestBeanConfig) factory.getBean("twoTestBeanConfig")).tb2();
}

private Object createName(BeanFactory factory)
{
    return (cast(NameConfig__FlintConfiguration) factory.getBean("nameConfig")).superName();
}

private Object createPrefixName(BeanFactory factory)
{
    return (cast(NameConfig) factory.getBean("nameConfig")).prefixName();
}

private void initializeAutowiredConfig(Object bean, BeanFactory factory)
{
    (cast(AutowiredConfig) bean).autowiredName = cast(Name) factory.getBeanOfType(typeNameOf!Name);
}

private Object createAutowiredTestBean(BeanFactory factory)
{
    return (cast(AutowiredConfig) factory.getBean("autowiredConfig")).testBean();
}

private AotBeanDefinition record(T)(string name, Object function(BeanFactory) @safe create)
{
    AotBeanDefinition definition;
    definition.name = name;
    definition.type = typeNameOf!T;
    definition.types = [typeNameOf!T];
    definition.create = create;
    return definition;
}

private void configuration(T)(scope AotRegistry registry, string name, Object function(BeanFactory) @safe create)
{
    registry.descriptor(descriptorOf!T());
    registry.bean(record!T(name, create));
}

private void populateConfig(scope AotRegistry registry)
{
    registry.begin(1, 1);
    configuration!Config(registry, "config", &create!Config);
    registry.bean(record!TestBean("testBean", &createConfigTestBean));
    registry.end();
}

private void populateConfigWithCustomName(scope AotRegistry registry)
{
    registry.begin(1, 1);
    configuration!ConfigWithCustomName(registry, "customConfigBeanName", &create!ConfigWithCustomName);
    registry.bean(record!TestBean("testBean", &createCustomTestBean));
    registry.end();
}

private void populateTwoTestBeanConfig(scope AotRegistry registry)
{
    registry.begin(1, 1);
    configuration!TwoTestBeanConfig(registry, "twoTestBeanConfig", &create!TwoTestBeanConfig);
    registry.bean(record!TestBean("tb1", &createTb1));
    registry.bean(record!TestBean("tb2", &createTb2));
    registry.end();
}

private void nameConfigBeans(scope AotRegistry registry)
{
    configuration!NameConfig(registry, "nameConfig", &createNameConfig);
    registry.bean(record!Name("name", &createName));
    registry.bean(record!Name("prefixName", &createPrefixName));
}

private void populateNameConfig(scope AotRegistry registry)
{
    registry.begin(1, 1);
    nameConfigBeans(registry);
    registry.end();
}

private void populateAutowiredConfig(scope AotRegistry registry)
{
    registry.begin(1, 1);
    auto config = record!AutowiredConfig("autowiredConfig", &create!AutowiredConfig);
    config.initialize = &initializeAutowiredConfig;
    registry.descriptor(descriptorOf!AutowiredConfig());
    registry.bean(config);
    nameConfigBeans(registry); // @Import(NameConfig.class)
    registry.bean(record!TestBean("testBean", &createAutowiredTestBean));
    registry.end();
}

/// The AOT record has no `autowireCandidate`: `@Bean(autowireCandidate = false)` is applied to the definition.
private void excludePrefixName(AnnotationConfigApplicationContext context)
{
    context.getBeanDefinition("prefixName").setAutowireCandidate(false);
}

unittest
{
    // registerAndRefresh
    auto context = new AnnotationConfigApplicationContext;
    context.loadAotRegistry(&populateConfig);
    context.loadAotRegistry(&populateNameConfig);
    excludePrefixName(context);
    context.refresh();

    context.getBean("testBean");
    assert((cast(Name) context.getBean("name")).value == "foo");
    assert((cast(Name) context.getBean("prefixName")).value == "barfoo");
    assert(context.getBeansWithAnnotation!Configuration().size() == 2);
}

unittest
{
    // getBeansWithAnnotation
    // (The Java test also registers a FactoryBean, which Flint does not support.)
    auto context = new AnnotationConfigApplicationContext;
    context.loadAotRegistry(&populateConfig);
    context.loadAotRegistry(&populateNameConfig);
    context.refresh();

    context.getBean("testBean");
    context.getBean("name");
    assert(context.getBeansWithAnnotation!Configuration().size() == 2);
}

unittest
{
    // getBeanByType
    ApplicationContext context = new AnnotationConfigApplicationContext(&populateConfig);
    const testBean = context.getBean!TestBean();
    assert(testBean !is null);
    assert(testBean.name == "foo");
}

private final class Pattern
{
}

unittest
{
    // getBeanByTypeRaisesNoSuchBeanDefinitionException
    ApplicationContext context = new AnnotationConfigApplicationContext(&populateConfig);
    // attempt to retrieve a bean that does not exist
    auto e = collectException!NoSuchBeanDefinitionException(context.getBean!Pattern());
    assert(e !is null && e.msg.indexOf("No qualifying bean of type '" ~ typeNameOf!Pattern ~ "'") >= 0);
}

unittest
{
    // getBeanByTypeAmbiguityRaisesException
    ApplicationContext context = new AnnotationConfigApplicationContext(&populateTwoTestBeanConfig);
    auto e = collectException!NoSuchBeanDefinitionException(context.getBean!TestBean());
    assert(e !is null && cast(NoUniqueBeanDefinitionException) e !is null);
    assert(e.msg.indexOf("No qualifying bean of type '" ~ typeNameOf!TestBean ~ "'") >= 0);
    assert(e.msg.indexOf("tb1") >= 0 && e.msg.indexOf("tb2") >= 0);
}

unittest
{
    // defaultConfigClassBeanNameIsGeneratedProperly
    ApplicationContext context = new AnnotationConfigApplicationContext(&populateConfig);
    // attempt to retrieve the instance by its generated bean name
    auto configObject = cast(Config) context.getBean("config");
    assert(configObject !is null);
}

unittest
{
    // explicitConfigClassBeanNameIsRespected
    ApplicationContext context = new AnnotationConfigApplicationContext(&populateConfigWithCustomName);
    // attempt to retrieve the instance by its specified name
    auto configObject = cast(ConfigWithCustomName) context.getBean("customConfigBeanName");
    assert(configObject !is null);
}

unittest
{
    // autowiringIsEnabledByDefault
    auto context = new AnnotationConfigApplicationContext;
    context.loadAotRegistry(&populateAutowiredConfig);
    excludePrefixName(context);
    context.refresh();
    assert(context.getBean!TestBean().name == "foo");
}

/// The three post-processors of nullReturningBeanPostProcessor.
private final class AppendingPostProcessor : BeanPostProcessor
{
    override Object postProcessBeforeInitialization(Object bean, string)
    {
        if (auto testBean = cast(TestBean) bean)
            testBean.name = testBean.name ~ "-before";
        return bean;
    }

    override Object postProcessAfterInitialization(Object bean, string)
    {
        if (auto testBean = cast(TestBean) bean)
            testBean.name = testBean.name ~ "-after";
        return bean;
    }
}

private final class NullReturningPostProcessor : BeanPostProcessor
{
    override Object postProcessBeforeInitialization(Object bean, string)
    {
        return cast(TestBean) bean !is null ? null : bean;
    }

    override Object postProcessAfterInitialization(Object bean, string)
    {
        return cast(TestBean) bean !is null ? null : bean;
    }
}

private final class NeverSeesTestBeanPostProcessor : BeanPostProcessor
{
    override Object postProcessBeforeInitialization(Object bean, string)
    {
        assert(cast(TestBean) bean is null);
        return bean;
    }

    override Object postProcessAfterInitialization(Object bean, string)
    {
        assert(cast(TestBean) bean is null);
        return bean;
    }
}

unittest
{
    // nullReturningBeanPostProcessor
    auto context = new AnnotationConfigApplicationContext;
    context.loadAotRegistry(&populateAutowiredConfig);
    excludePrefixName(context);
    // 1st BPP always gets invoked
    context.getBeanFactory().addBeanPostProcessor(new AppendingPostProcessor);
    // 2nd BPP always returns null for a TestBean
    context.getBeanFactory().addBeanPostProcessor(new NullReturningPostProcessor);
    // 3rd BPP never gets invoked with a TestBean
    context.getBeanFactory().addBeanPostProcessor(new NeverSeesTestBeanPostProcessor);
    context.refresh();
    const testBean = context.getBean!TestBean();
    assert(testBean !is null);
    assert(testBean.name == "foo-before-after");
}

// ---- BeanA, BeanB, BeanC

private final class BeanA
{
    BeanB b;
    BeanC c;

    this(BeanB b, BeanC c) pure nothrow @nogc // @Autowired
    {
        this.b = b;
        this.c = c;
    }
}

private final class BeanB
{
    ApplicationContext applicationContext; // @Autowired
}

private final class BeanC
{
}

private Object createBeanA(BeanFactory factory)
{
    return new BeanA(cast(BeanB) factory.getBeanOfType(typeNameOf!BeanB),
            cast(BeanC) factory.getBeanOfType(typeNameOf!BeanC));
}

private void initializeBeanB(Object bean, BeanFactory factory)
{
    (cast(BeanB) bean).applicationContext = cast(ApplicationContext) factory.getBeanOfType(
            typeNameOf!ApplicationContext);
}

private void populateBeans(string a, string b, string c)(scope AotRegistry registry)
{
    registry.begin(1, 1);
    registry.bean(record!BeanA(a, &createBeanA));
    auto beanB = record!BeanB(b, &create!BeanB);
    beanB.initialize = &initializeBeanB;
    registry.bean(beanB);
    registry.bean(record!BeanC(c, &create!BeanC));
    registry.end();
}

unittest
{
    // individualBeans
    auto context = new AnnotationConfigApplicationContext;
    context.loadAotRegistry(&populateBeans!("beanA", "beanB", "beanC"));
    context.refresh();
    assert(context.getBean!BeanA().b is context.getBean!BeanB());
    assert(context.getBean!BeanA().c is context.getBean!BeanC());
    assert(context.getBean!BeanB().applicationContext is context);
}

unittest
{
    // individualNamedBeans
    auto context = new AnnotationConfigApplicationContext;
    context.loadAotRegistry(&populateBeans!("a", "b", "c"));
    context.refresh();
    assert(context.getBean!BeanA("a").b is context.getBean("b"));
    assert(context.getBean!BeanA("a").c is context.getBean("c"));
    assert(context.getBean!BeanB("b").applicationContext is context);
}

/// BeanB's `@Autowired` field, which Spring injects into a supplied instance too: the supplier does it here.
private BeanB autowired(BeanB bean, ApplicationContext context)
{
    bean.applicationContext = context;
    return bean;
}

unittest
{
    // individualBeanWithSupplier
    auto context = new AnnotationConfigApplicationContext;
    context.registerBean!BeanA(() => new BeanA(context.getBean!BeanB(), context.getBean!BeanC()));
    context.registerBean!BeanB(() => autowired(new BeanB, context));
    context.registerBean!BeanC(() => new BeanC);
    context.refresh();

    assert(context.getBeanFactory().containsSingleton("beanA"));
    assert(context.getBean!BeanA().b is context.getBean!BeanB());
    assert(context.getBean!BeanA().c is context.getBean!BeanC());
    assert(context.getBean!BeanB().applicationContext is context);
    auto factory = context.getDefaultListableBeanFactory();
    assert(factory.getDependentBeans("beanB") == ["beanA"]);
    assert(factory.getDependentBeans("beanC") == ["beanA"]);
}

unittest
{
    // individualBeanWithSupplierAndCustomizer
    auto context = new AnnotationConfigApplicationContext;
    context.registerBean!BeanA(() => new BeanA(context.getBean!BeanB(), context.getBean!BeanC()),
            (BeanDefinition definition) { definition.setLazyInit(true); });
    context.registerBean!BeanB(() => autowired(new BeanB, context));
    context.registerBean!BeanC(() => new BeanC);
    context.refresh();

    assert(!context.getBeanFactory().containsSingleton("beanA"));
    assert(context.getBean!BeanA().b is context.getBean!BeanB());
    assert(context.getBean!BeanA().c is context.getBean!BeanC());
    assert(context.getBean!BeanB().applicationContext is context);
}

unittest
{
    // individualNamedBeanWithSupplier
    auto context = new AnnotationConfigApplicationContext;
    context.registerBean!BeanA("a", () => new BeanA(context.getBean!BeanB(), context.getBean!BeanC()));
    context.registerBean!BeanB("b", () => autowired(new BeanB, context));
    context.registerBean!BeanC("c", () => new BeanC);
    context.refresh();

    assert(context.getBeanFactory().containsSingleton("a"));
    assert(context.getBean!BeanA().b is context.getBean!BeanB("b"));
    assert(context.getBean!BeanA("a").c is context.getBean("c"));
    assert(context.getBean!BeanB("b").applicationContext is context);
}

unittest
{
    // individualNamedBeanWithSupplierAndCustomizer
    auto context = new AnnotationConfigApplicationContext;
    context.registerBean!BeanA("a", () => new BeanA(context.getBean!BeanB(),
            context.getBean!BeanC()), (BeanDefinition definition) { definition.setLazyInit(true); });
    context.registerBean!BeanB("b", () => autowired(new BeanB, context));
    context.registerBean!BeanC("c", () => new BeanC);
    context.refresh();

    assert(!context.getBeanFactory().containsSingleton("a"));
    assert(context.getBean!BeanA().b is context.getBean!BeanB("b"));
    assert(context.getBean!BeanA("a").c is context.getBean("c"));
    assert(context.getBean!BeanB("b").applicationContext is context);
}

unittest
{
    // individualBeanWithNullReturningSupplier
    // (resolveNamedBean is getBean(Class) here.)
    auto context = new AnnotationConfigApplicationContext;
    context.registerBean!BeanA("a", () => cast(BeanA) null);
    context.registerBean!BeanB("b", () => new BeanB);
    context.registerBean!BeanC("c", () => new BeanC);
    context.refresh();

    assert(context.getBeanNamesForType!BeanA() == ["a"]);
    assert(context.getBeanNamesForType!BeanB() == ["b"]);
    assert(context.getBeanNamesForType!BeanC() == ["c"]);
    assert(context.getBeansOfType!BeanA().isEmpty());
    auto bs = context.getBeansOfType!BeanB().values().toArray();
    assert(bs.length == 1 && bs[0] is context.getBean!BeanB());
    auto cs = context.getBeansOfType!BeanC().values().toArray();
    assert(cs.length == 1 && cs[0] is context.getBean!BeanC());
    assertThrown!NoSuchBeanDefinitionException(context.getBean!BeanA());
    assert(context.getBean!BeanB() !is null && context.getBean!BeanC() !is null);
}
