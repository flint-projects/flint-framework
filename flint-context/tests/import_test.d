// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/context/annotation/configuration/ImportTests.java
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
 * spring-context/src/test/java/org/springframework/context/annotation/configuration/ImportTests.java and
 * spring-context/src/test/java/org/springframework/context/annotation/componentscan/ordered/{SiblingImportingConfigA,
 * SiblingImportingConfigB,SiblingReversedImportingConfigA,SiblingReversedImportingConfigB}.java.
 */

/++
`ImportTests`. Flint AOT resolves `@Import` at build time (`defineImports` in the `flint` tool's AOT planner): the
configuration classes Java registers are the generator's scanned candidates, named after their class (`appConfig`)
or their `@Configuration` value, and every class they import is defined once, under its fully qualified name, right
after its importer's own `@Bean` methods, followed by its own `@Bean` methods and imports. Java's
`ConfigurationClassPostProcessor` run over a `DefaultListableBeanFactory` is the generated registry loaded into a
context's factory; each `populate` function below is that registry, as the generator emits it today. A Java `String`
bean is a `Name`, and `ImportedBean` (a Java record) a class.

The gated tests keep the registries the generator emits today, which differ from Spring's processing.
+/
module flint.context.import_test;

import flint.beans.factory.support : DefaultListableBeanFactory;
import flint.context.annotation : AnnotationConfigApplicationContext, Configuration, DependsOn, Import;
import flint.core.annotation : classOf;
import flint.engine.aot.bean : AotBeanDefinition = BeanDefinition, BeanFactory;
import flint.engine.aot.name : typeNameOf;
import flint.engine.aot.registry : AotRegistry;

@safe:

private interface ITestBean
{
    string getName();
}

private final class TestBean : ITestBean
{
    private string name;
    private ITestBean spouse;

    this(string name = null) pure nothrow @nogc
    {
        this.name = name;
    }

    this(ITestBean spouse) pure nothrow @nogc
    {
        this.spouse = spouse;
    }

    string getName()
    {
        return name;
    }
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

@Configuration private class OtherConfiguration
{
    ITestBean three()
    {
        return new TestBean;
    }
}

@Configuration @Import([classOf!OtherConfiguration]) private class ConfigurationWithImportAnnotation
{
    ITestBean one()
    {
        return new TestBean;
    }
}

@Configuration @Import([classOf!OtherConfiguration]) private class OtherConfigurationWithImportAnnotation
{
    ITestBean two()
    {
        return new TestBean;
    }
}

@Configuration private class DataSourceConfig
{
    ITestBean dataSourceA()
    {
        return new TestBean;
    }
}

@Configuration @Import([classOf!DataSourceConfig]) private class AppConfig
{
    ITestBean transferService()
    {
        return new TestBean(accountRepository());
    }

    ITestBean accountRepository()
    {
        return new TestBean;
    }
}

@Configuration private class Foo1
{
    ITestBean foo()
    {
        return new TestBean("foo1");
    }
}

@Configuration private class Foo2
{
    ITestBean foo()
    {
        return new TestBean("foo2");
    }
}

@Configuration @Import([classOf!Foo1, classOf!Foo2]) private class WithMultipleArgumentsThatWillCauseDuplication
{
}

@Configuration private class ExternalConfig
{
    ITestBean extBean()
    {
        return new TestBean;
    }
}

@Configuration private class OuterConfig
{
    Name whatev()
    {
        return new Name("whatev");
    }

    @Configuration @Import([classOf!ExternalConfig]) static class InnerConfig
    {
        ITestBean innerBean()
        {
            return new TestBean;
        }
    }
}

private final class InitBean
{
    static bool initialized = false;

    this() nothrow @nogc
    {
        initialized = true;
    }
}

@Configuration @DependsOn([typeNameOf!InitBean]) private class ThirdLevel
{
    this()
    {
        assert(InitBean.initialized);
    }

    ITestBean thirdLevelA()
    {
        return new TestBean;
    }

    ITestBean thirdLevelB()
    {
        return new TestBean;
    }

    ITestBean thirdLevelC()
    {
        return new TestBean;
    }
}

@Configuration @Import([classOf!ThirdLevel, classOf!InitBean]) private class SecondLevel
{
    TestBean n()
    {
        return new TestBean;
    }
}

@Configuration @Import([classOf!SecondLevel]) private class FirstLevel
{
    TestBean m()
    {
        return new TestBean;
    }
}

@Configuration @Import([classOf!ThirdLevel]) private class FirstLevelPlus
{
}

@Configuration private class LeftConfig
{
    ITestBean left()
    {
        return new TestBean;
    }
}

@Configuration private class RightConfig
{
    ITestBean right()
    {
        return new TestBean;
    }
}

@Configuration @Import([classOf!LeftConfig, classOf!RightConfig]) private class WithMultipleArgumentsToImportAnnotation
{
    TestBean m()
    {
        return new TestBean;
    }
}

private class NonConfigAnnotated
{
}

@Configuration @Import([classOf!NonConfigAnnotated]) private class ConfigAnnotated
{
}

@Configuration("config-a") private class A
{
}

@Configuration("config-b") @Import([classOf!A]) private class B
{
}

// ---- what Flint AOT generates

private Object create(T)(BeanFactory)
{
    return new T;
}

/// A `@Bean` method `method` of the configuration bean `configuration` of class `C`.
private Object beanMethod(C, string method)(BeanFactory factory, string configuration)
{
    return cast(Object) __traits(getMember, cast(C) factory.getBean(configuration), method)();
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

/// The configuration class `C`, named `name`.
private void configuration(C)(scope AotRegistry registry, string name)
{
    registry.bean(record!C(name, &create!C));
}

/// The `@Bean` method `method` of `C`, whose bean is named `configuration`; the bean is named after the method.
private void bean(C, string method, string configuration)(scope AotRegistry registry)
{
    alias R = imported!"std.traits".ReturnType!(__traits(getMember, C, method));
    static Object factory(BeanFactory beanFactory)
    {
        return beanMethod!(C, method)(beanFactory, configuration);
    }

    registry.bean(record!R(method, &factory));
}

/// The name Flint AOT gives an imported class.
private enum importedName(T) = typeNameOf!T;

private void otherConfigurationImported(scope AotRegistry registry)
{
    configuration!OtherConfiguration(registry, importedName!OtherConfiguration);
    bean!(OtherConfiguration, "three", importedName!OtherConfiguration)(registry);
}

private void configurationWithImportAnnotation(scope AotRegistry registry, bool importsDefined)
{
    configuration!ConfigurationWithImportAnnotation(registry, "configurationWithImportAnnotation");
    bean!(ConfigurationWithImportAnnotation, "one", "configurationWithImportAnnotation")(registry);
    if (!importsDefined)
        otherConfigurationImported(registry);
}

private void otherConfiguration(scope AotRegistry registry)
{
    configuration!OtherConfiguration(registry, "otherConfiguration");
    bean!(OtherConfiguration, "three", "otherConfiguration")(registry);
}

private void populateConfigurationWithImportAnnotation(scope AotRegistry registry)
{
    registry.begin(1, 1);
    configurationWithImportAnnotation(registry, false);
    registry.end();
}

private void populateDoubleImports(scope AotRegistry registry)
{
    registry.begin(1, 1);
    configurationWithImportAnnotation(registry, false);
    configuration!OtherConfigurationWithImportAnnotation(registry, "otherConfigurationWithImportAnnotation");
    bean!(OtherConfigurationWithImportAnnotation, "two", "otherConfigurationWithImportAnnotation")(registry);
    registry.end(); // OtherConfiguration is already imported
}

private void populateExplicitOverridingBefore(scope AotRegistry registry)
{
    registry.begin(1, 1);
    otherConfiguration(registry);
    configurationWithImportAnnotation(registry, true); // the import of a defined class is skipped
    registry.end();
}

/// The scanned OtherConfiguration is defined again after ConfigurationWithImportAnnotation imported it.
private void populateExplicitOverridingAfter(scope AotRegistry registry)
{
    registry.begin(1, 1);
    configurationWithImportAnnotation(registry, false);
    otherConfiguration(registry);
    registry.end();
}

private void populateAppConfig(scope AotRegistry registry)
{
    registry.begin(1, 1);
    configuration!AppConfig(registry, "appConfig");
    bean!(AppConfig, "transferService", "appConfig")(registry);
    bean!(AppConfig, "accountRepository", "appConfig")(registry);
    configuration!DataSourceConfig(registry, importedName!DataSourceConfig);
    bean!(DataSourceConfig, "dataSourceA", importedName!DataSourceConfig)(registry);
    registry.end();
}

private void firstLevel(scope AotRegistry registry)
{
    configuration!FirstLevel(registry, "firstLevel");
    bean!(FirstLevel, "m", "firstLevel")(registry);
    configuration!SecondLevel(registry, importedName!SecondLevel);
    bean!(SecondLevel, "n", importedName!SecondLevel)(registry);
    auto thirdLevel = record!ThirdLevel(importedName!ThirdLevel, &create!ThirdLevel);
    thirdLevel.dependsOn = [typeNameOf!InitBean];
    registry.bean(thirdLevel);
    bean!(ThirdLevel, "thirdLevelA", importedName!ThirdLevel)(registry);
    bean!(ThirdLevel, "thirdLevelB", importedName!ThirdLevel)(registry);
    bean!(ThirdLevel, "thirdLevelC", importedName!ThirdLevel)(registry);
    configuration!InitBean(registry, importedName!InitBean);
}

private void populateFirstLevel(scope AotRegistry registry)
{
    registry.begin(1, 1);
    firstLevel(registry);
    registry.end();
}

private void populateFirstLevelAndPlus(scope AotRegistry registry)
{
    registry.begin(1, 1);
    firstLevel(registry);
    configuration!FirstLevelPlus(registry, "firstLevelPlus"); // ThirdLevel is already imported
    registry.end();
}

private void populateMultipleArguments(scope AotRegistry registry)
{
    registry.begin(1, 1);
    configuration!WithMultipleArgumentsToImportAnnotation(registry, "withMultipleArgumentsToImportAnnotation");
    bean!(WithMultipleArgumentsToImportAnnotation, "m", "withMultipleArgumentsToImportAnnotation")(registry);
    configuration!LeftConfig(registry, importedName!LeftConfig);
    bean!(LeftConfig, "left", importedName!LeftConfig)(registry);
    configuration!RightConfig(registry, importedName!RightConfig);
    bean!(RightConfig, "right", importedName!RightConfig)(registry);
    registry.end();
}

private void populateDuplication(scope AotRegistry registry)
{
    registry.begin(1, 1);
    configuration!WithMultipleArgumentsThatWillCauseDuplication(registry,
            "withMultipleArgumentsThatWillCauseDuplication");
    configuration!Foo1(registry, importedName!Foo1);
    bean!(Foo1, "foo", importedName!Foo1)(registry);
    configuration!Foo2(registry, importedName!Foo2);
    bean!(Foo2, "foo", importedName!Foo2)(registry);
    registry.end();
}

private void populateInnerConfig(scope AotRegistry registry)
{
    registry.begin(1, 1);
    configuration!(OuterConfig.InnerConfig)(registry, "innerConfig");
    bean!(OuterConfig.InnerConfig, "innerBean", "innerConfig")(registry);
    configuration!ExternalConfig(registry, importedName!ExternalConfig);
    bean!(ExternalConfig, "extBean", importedName!ExternalConfig)(registry);
    registry.end();
}

private void populateConfigAnnotated(scope AotRegistry registry)
{
    registry.begin(1, 1);
    configuration!ConfigAnnotated(registry, "configAnnotated");
    configuration!NonConfigAnnotated(registry, importedName!NonConfigAnnotated);
    registry.end();
}

private void populateB(scope AotRegistry registry)
{
    registry.begin(1, 1);
    configuration!B(registry, "config-b");
    configuration!A(registry, "config-a"); // an imported class keeps its @Configuration value
    registry.end();
}

/// Java's `processConfigurationClasses`: the registry loaded into a factory that disallows overriding.
private DefaultListableBeanFactory processConfigurationClasses(
        void function(scope AotRegistry) @safe populate, bool allowOverriding = false)
{
    auto context = new AnnotationConfigApplicationContext;
    context.setAllowBeanDefinitionOverriding(allowOverriding);
    context.loadAotRegistry(populate);
    return context.getDefaultListableBeanFactory();
}

private void assertBeanDefinitionCount(Classes...)(int expectedCount, void function(scope AotRegistry) @safe populate)
{
    auto beanFactory = processConfigurationClasses(populate);
    assert(beanFactory.getBeanDefinitionCount() == expectedCount);
    beanFactory.preInstantiateSingletons();
    static foreach (C; Classes)
        beanFactory.getBean!C();
}

unittest
{
    // processImportsWithAsm
    const configClasses = 2;
    const beansInClasses = 2;
    auto beanFactory = processConfigurationClasses(&populateConfigurationWithImportAnnotation);
    assert(beanFactory.getBeanDefinitionCount() == configClasses + beansInClasses);
}

unittest
{
    // processImportsWithDoubleImports
    const configClasses = 3;
    const beansInClasses = 3;
    assertBeanDefinitionCount!(ConfigurationWithImportAnnotation, OtherConfigurationWithImportAnnotation)(
            configClasses + beansInClasses, &populateDoubleImports);
}

unittest
{
    // processImportsWithExplicitOverridingBefore
    const configClasses = 2;
    const beansInClasses = 2;
    assertBeanDefinitionCount!(OtherConfiguration, ConfigurationWithImportAnnotation)(
            configClasses + beansInClasses, &populateExplicitOverridingBefore);
}

// A configuration class that is both scanned and imported by a class scanned before it is defined twice (under
// its fully qualified name and its bean name), so its @Bean methods collide: BeanDefinitionOverrideException.
version (FlintImportOfScannedConfiguration)
{
    unittest
    {
        // processImportsWithExplicitOverridingAfter
        const configClasses = 2;
        const beansInClasses = 2;
        assertBeanDefinitionCount!(ConfigurationWithImportAnnotation, OtherConfiguration)(
                configClasses + beansInClasses, &populateExplicitOverridingAfter);
    }
}

unittest
{
    // importAnnotationWithTwoLevelRecursion
    const configClasses = 2;
    const beansInClasses = 3;
    assertBeanDefinitionCount!AppConfig(configClasses + beansInClasses, &populateAppConfig);
}

unittest
{
    // importAnnotationWithThreeLevelRecursion
    const configClasses = 4;
    const beansInClasses = 5;
    assertBeanDefinitionCount!FirstLevel(configClasses + beansInClasses, &populateFirstLevel);
}

unittest
{
    // importAnnotationWithThreeLevelRecursionAndDoubleImport
    const configClasses = 5;
    const beansInClasses = 5;
    assertBeanDefinitionCount!(FirstLevel, FirstLevelPlus)(configClasses + beansInClasses, &populateFirstLevelAndPlus);
}

unittest
{
    // importAnnotationWithMultipleArguments
    const configClasses = 3;
    const beansInClasses = 3;
    assertBeanDefinitionCount!WithMultipleArgumentsToImportAnnotation(configClasses + beansInClasses,
            &populateMultipleArguments);
}

unittest
{
    // importAnnotationWithMultipleArgumentsResultingInOverriddenBeanDefinition
    auto beanFactory = processConfigurationClasses(&populateDuplication, true);
    assert(beanFactory.getBeanDefinitionCount() == 4);
    assert(beanFactory.getBean!ITestBean("foo").getName() == "foo2");
}

unittest
{
    // importAnnotationOnInnerClasses
    const configClasses = 2;
    const beansInClasses = 2;
    assertBeanDefinitionCount!(OuterConfig.InnerConfig)(configClasses + beansInClasses, &populateInnerConfig);
}

unittest
{
    // importNonConfigurationAnnotationClass
    const configClasses = 2;
    const beansInClasses = 0;
    assertBeanDefinitionCount!ConfigAnnotated(configClasses + beansInClasses, &populateConfigAnnotated);
}

unittest
{
    // reproSpr9023
    auto ctx = new AnnotationConfigApplicationContext(&populateB);
    assert(ctx.getBeanNamesForType!B()[0] == "config-b");
    assert(ctx.getBeanNamesForType!A()[0] == "config-a");
    ctx.close();
}

unittest
{
    // processImports
    const configClasses = 2;
    const beansInClasses = 2;
    assertBeanDefinitionCount!ConfigurationWithImportAnnotation(configClasses + beansInClasses,
            &populateConfigurationWithImportAnnotation);
}

// An imported configuration's @Bean methods are registered after its importer's, so they override the importer's
// instead of being overridden by them, and a scanned class imported by an earlier one is defined twice.
version (FlintImportedConfigurationPrecedence)
{
    @Configuration private class SiblingImportingConfigB
    {
        /// `@Bean(name = "a-imports-b")`
        Name bean()
        {
            return new Name("valueFromB");
        }
    }

    @Configuration @Import([classOf!SiblingImportingConfigB]) private class SiblingImportingConfigA
    {
        /// `@Bean(name = "a-imports-b")`
        Name bean()
        {
            return new Name("valueFromA");
        }
    }

    @Configuration private class SiblingReversedImportingConfigA
    {
        /// `@Bean(name = "b-imports-a")`
        Name bean()
        {
            return new Name("valueFromAR");
        }
    }

    @Configuration @Import([classOf!SiblingReversedImportingConfigA]) private class SiblingReversedImportingConfigB
    {
        /// `@Bean(name = "b-imports-a")`
        Name bean()
        {
            return new Name("valueFromBR");
        }
    }

    private void namedBean(C, string name, string configuration)(scope AotRegistry registry)
    {
        static Object factory(BeanFactory beanFactory)
        {
            return beanMethod!(C, "bean")(beanFactory, configuration);
        }

        registry.bean(record!Name(name, &factory));
    }

    /// `ctx.scan("...componentscan.ordered")`: the four classes are scanned, at build time, in name order.
    private void populateOrdered(scope AotRegistry registry)
    {
        alias IA = SiblingImportingConfigA, IB = SiblingImportingConfigB;
        alias RA = SiblingReversedImportingConfigA, RB = SiblingReversedImportingConfigB;
        registry.begin(1, 1);
        configuration!IA(registry, "siblingImportingConfigA");
        namedBean!(IA, "a-imports-b", "siblingImportingConfigA")(registry);
        configuration!IB(registry, importedName!IB);
        namedBean!(IB, "a-imports-b", importedName!IB)(registry);
        configuration!IB(registry, "siblingImportingConfigB");
        namedBean!(IB, "a-imports-b", "siblingImportingConfigB")(registry);
        configuration!RA(registry, "siblingReversedImportingConfigA");
        namedBean!(RA, "b-imports-a", "siblingReversedImportingConfigA")(registry);
        configuration!RB(registry, "siblingReversedImportingConfigB");
        namedBean!(RB, "b-imports-a", "siblingReversedImportingConfigB")(registry);
        registry.end(); // RB's import of the defined RA is skipped
    }

    unittest
    {
        // importedConfigOverridesScanned
        auto ctx = new AnnotationConfigApplicationContext;
        ctx.setAllowBeanDefinitionOverriding(true);
        ctx.loadAotRegistry(&populateOrdered);
        ctx.refresh();

        assert((cast(Name) ctx.getBean("a-imports-b")).value == "valueFromA");
        assert((cast(Name) ctx.getBean("b-imports-a")).value == "valueFromBR");
        assert(ctx.getBeansOfType!SiblingImportingConfigA().size() == 1);
        assert(ctx.getBeansOfType!SiblingImportingConfigB().size() == 1);
    }
}

// Flint AOT reads @Import only from the class's own annotations (and their meta-annotations), not from the
// interfaces it implements (gh-34820): ImportedConfig is never defined.
version (FlintImportOnInterface)
{
    private final class ImportedBean
    {
        string name;

        this(string name) pure nothrow @nogc
        {
            this.name = name;
        }
    }

    @Configuration private class ImportedConfig
    {
        ImportedBean importedBean()
        {
            return new ImportedBean("imported");
        }
    }

    @Configuration private class OverridingImportedConfig
    {
        ImportedBean importedBean()
        {
            return new ImportedBean("from class");
        }
    }

    @Import([classOf!ImportedConfig]) private interface ConfigImportMarker
    {
    }

    @Configuration private class InterfaceBasedConfig : ConfigImportMarker
    {
    }

    @Configuration @Import([classOf!OverridingImportedConfig]) private class OverridingConfig : ConfigImportMarker
    {
    }

    private void populateInterfaceBasedConfig(scope AotRegistry registry)
    {
        registry.begin(1, 1);
        configuration!InterfaceBasedConfig(registry, "interfaceBasedConfig");
        registry.end();
    }

    private void populateOverridingConfig(scope AotRegistry registry)
    {
        registry.begin(1, 1);
        configuration!OverridingConfig(registry, "overridingConfig");
        configuration!OverridingImportedConfig(registry, importedName!OverridingImportedConfig);
        bean!(OverridingImportedConfig, "importedBean", importedName!OverridingImportedConfig)(registry);
        registry.end();
    }

    unittest
    {
        // importAnnotationOnImplementedInterfaceIsRespected
        auto context = new AnnotationConfigApplicationContext(&populateInterfaceBasedConfig);

        assert(context.getBean!ImportedConfig() !is null);
        assert(context.getBean!ImportedBean().name == "imported");

        context.close();
    }

    unittest
    {
        // localImportShouldOverrideInterfaceImport
        auto context = new AnnotationConfigApplicationContext(&populateOverridingConfig);

        assert(context.getBean!ImportedConfig() !is null);
        assert(context.getBean!OverridingImportedConfig() !is null);
        assert(context.getBean!ImportedBean().name == "from class");

        context.close();
    }
}
