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
 * (autowiring through generated code, circular references, post-processing, init and destroy callbacks).
 */

/++
`DefaultListableBeanFactoryTests`, part 3: autowiring, circular references and lifecycle callbacks.

`lbf.autowire(X.class, mode)` builds an unregistered `X` reflectively; here `X` is registered with the generated
`create`/`initialize` that resolve its dependencies, which is what Flint AOT emits for `@Autowired`. Generated
lookups throw the contract's `NoSuchBeanDefinitionException`/`NoUniqueBeanDefinitionException`, which the factory
wraps in `BeanCreationException`: Spring's `UnsatisfiedDependencyException` (a `BeanCreationException`) needs the
injection point, which generated code does not pass.

Skipped Java tests (of the 190 in the class; the others are in this file, `dlbf_registration_test` and
`dlbf_resolution_test`):
- Properties-format definitions (`PropertiesBeanDefinitionReader`): emptyPropertiesPopulation,
  harmlessIgnorableRubbish, propertiesPopulationWithNullPrefix, propertiesPopulationWithPrefix, simpleReference,
  propertiesWithDotsInKey, beanReferenceWithNewSyntax, canEscapeBeanReferenceSyntax.
- Property values, type conversion and property editors: arrayReferenceByName, arrayReferenceByType,
  arrayReferenceByAutowire (a Java `String` is not a D class bean), possibleMatches, customEditor, customConverter,
  customEditorWithBeanReference, customTypeConverter, customTypeConverterWithBeanReference,
  arrayPropertyWithAutowiring, arrayPropertyWithOptionalAutowiring, arrayConstructorWithAutowiring,
  arrayConstructorWithOptionalAutowiring, doubleArrayConstructorWithAutowiring,
  doubleArrayConstructorWithOptionalAutowiring, expressionInStringArray, withOverloadedSetters,
  applyBeanPropertyValues, applyBeanPropertyValuesWithIncompleteDefinition, prototypeStringCreatedRepeatedly,
  prototypeWithArrayConversionForConstructor, prototypeWithArrayConversionForFactoryMethod, nonPublicEnum.
- Constructor argument values and reflective constructor resolution:
  beanDefinitionOverridingWithConstructorArgumentMismatch,
  hintAtPossibleDuplicateArgumentsInParentAndChildWhenMixingIndexAndNamed, constructorDependencyWithClassResolution,
  constructorDependencyWithUnresolvableClass, autowirePreferredConstructors,
  autowirePreferredConstructorsFromAttribute, autowirePreferredConstructorFromAttribute, beanDefinitionWithInterface,
  beanDefinitionWithAbstractClass (an interface or abstract class cannot be a generated `new`),
  getBeanByTypeInstanceWithConstructorIgnoresInstanceSupplier, getBeanWithArgsNotCreatedForFactoryBeanChecking
  (explicit `getBean` arguments).
- Parent/child bean definitions (`ChildBeanDefinition`, merged definitions): prototypeExtendsPrototype,
  canReferenceParentBeanFromChildViaAlias, getTypeWorksAfterParentChildMerging,
  mergedBeanDefinitionChangesRetainedAfterFreezeConfiguration, explicitScopeInheritanceForChildBeanDefinitions,
  scopeInheritanceForChildBeanDefinitions.
- FactoryBean (not supported in Phase 1): factoryBeanDidNotCreatePrototype,
  prototypeFactoryBeanIgnoredByNonEagerTypeMatching, singletonFactoryBeanIgnoredByNonEagerTypeMatching,
  nonInitializedFactoryBeanIgnoredByNonEagerTypeMatching, nonInitializedFactoryBeanIgnoredByEagerTypeMatching,
  initializedFactoryBeanFoundByNonEagerTypeMatching, getFactoryBeanByTypeWithPrimary,
  autowireBeanWithFactoryBeanByType, autowireBeanWithFactoryBeanByTypeWithPrimary, autowireBeanWithFactoryBeanByName,
  autowireBeanByTypeWithTwoPrimaryFactoryBeans, getTypeForAbstractFactoryBean,
  getBeanNamesForTypeBeforeFactoryBeanCreation, getBeanNamesForTypeAfterFactoryBeanCreation,
  getBeanNamesForTypeWithPrototypeScopedFactoryBean, getBeanNamesForTypeWithFactoryBeanDefinedAsTargetType,
  circularReferenceThroughFactoryBeanAutowiring, circularReferenceThroughFactoryBeanTypeCheck,
  avoidCircularReferenceThroughAutowiring, prototypeFactoryBeanNotEagerlyCalled,
  prototypeFactoryBeanNotEagerlyCalledInCaseOfBeanClassName, lazyInitFactory, smartInitFactory.
- Factory-method definitions (`setFactoryMethodName`; `@Bean` methods are generated code):
  staticFactoryMethodFoundByNonEagerTypeMatching, staticPrototypeFactoryMethodFoundByNonEagerTypeMatching,
  nonStaticFactoryMethodFoundByNonEagerTypeMatching, nonStaticPrototypeFactoryMethodFoundByNonEagerTypeMatching,
  findTypeOfSingletonFactoryMethodOnBeanInstance, findTypeOfPrototypeFactoryMethodOnBeanInstance,
  getBeanByTypeInstanceWithFactoryMethodIgnoresInstanceSupplier, populatedJavaUtilOptionalBean,
  emptyJavaUtilOptionalBean, mostSpecificCacheEntryForTypeMatching.
- Reflective AutowireCapableBeanFactory API (autowire by name, dependency checks, createBean, configureBean,
  autowireBeanProperties): autowireBeanByName, autowireBeanByNameWithDependencyCheck,
  autowireBeanByNameWithNoDependencyCheck, autowireExistingBeanByName, autowireExistingBeanByNameWithDependencyCheck,
  autowireExistingBeanByNameWithNoDependencyCheck, autowireExistingBeanByType,
  autowireExistingBeanByTypeWithDependencyCheck, autowireExistingBeanByTypeWithNoDependencyCheck,
  invalidAutowireMode, createBean, createBeanWithDisposableBean, createBeanWithNonDefaultConstructor,
  createBeanWithPreferredDefaultConstructor, configureBean, configureBeanWithAutowiring,
  fieldSettingWithInstantiationAwarePostProcessorNoShortCircuit,
  fieldSettingWithInstantiationAwarePostProcessorWithShortCircuit (InstantiationAwareBeanPostProcessor).
- `@Priority` candidate selection and the dependency comparator (not implemented): getBeanByTypeWithPriority,
  mapInjectionWithPriority, getBeanByTypeWithMultipleHighestPriorityCandidates,
  getBeanByTypeWithMultipleNonHighestPriorityCandidates, getBeanByTypeWithPriorityAndNullInstance,
  getBeanByTypePrimaryHasPrecedenceOverPriority, autowireBeanByTypeWithTwoMatchesAndPriority,
  autowireBeanByTypeWithIdenticalPriorityCandidates, autowireBeanByTypePrimaryTakesPrecedenceOverPriority,
  beanProviderWithParentBeanFactoryDetectsOrder, beanProviderWithParentBeanFactoryAndMixedOrder.
- `AbstractBeanDefinition.ORDER_ATTRIBUTE` and `getOrder(beanName)` (not ported): orderFromAttribute,
  orderFromAttributeOverridesAnnotation, invalidOrderAttribute.
- ResolvableType generics and caches: getBeanByNameWithTypeReference,
  getBeanByNameWithTypeReferenceMatchingGenericTypeOnAopProxy, cachesBeanNamesForGenericType,
  cachesSingletonBeanNamesForGenericType, cachesBeanNamesForRecursiveGenericType.
- A null `Class` token cannot be written (deviation D-4): getBeanProviderByTypeWithNullRequiredType,
  resolveNamedBeanByTypeWithNullRequiredType.
- Inner bean definitions: destroyMethodOnInnerBean, destroyMethodOnInnerBeanAsPrototype.
- Java serialization: beanProviderSerialization.
+/
module flint.beans.dlbf_lifecycle_test;

import flint.beans.dlbf_fixtures : containsCause, createdBy, definitionOf, ITestBean, TestBean,
    testBeanDefinition, withDestroy, withInitialize;
import flint.beans.factory : BeanCreationException, BeanCurrentlyInCreationException,
    DisposableBean, InitializingBean, NoSuchBeanDefinitionException, NoUniqueBeanDefinitionException;
import flint.beans.factory.config : BeanPostProcessor;
import flint.beans.factory.support : DefaultListableBeanFactory;
import flint.engine.aot.bean : AotBeanFactory = BeanFactory;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : Integer, valueOf;
import std.exception : collectException;
import std.string : indexOf;

@safe:

// ---- DependenciesBean, ConstructorDependency and friends, with their generated factories

private final class DependenciesBean
{
    TestBean spouse;
}

private void autowireSpouse(Object bean, AotBeanFactory factory)
{
    (cast(DependenciesBean) bean).spouse = cast(TestBean) factory.getBeanOfType(typeNameOf!TestBean);
}

private void autowireOptionalSpouse(Object bean, AotBeanFactory factory)
{
    (cast(DependenciesBean) bean).spouse = cast(TestBean) factory.findBeanOfType(typeNameOf!TestBean);
}

private final class SpouseConstructorBean
{
    TestBean spouse;

    this(TestBean spouse) pure nothrow @nogc
    {
        this.spouse = spouse;
    }
}

private Object createWithSpouse(AotBeanFactory factory)
{
    return new SpouseConstructorBean(cast(TestBean) factory.getBeanOfType(typeNameOf!TestBean));
}

private final class NoDependencies
{
}

private final class UnsatisfiedConstructorDependency
{
    this(TestBean, NoDependencies) pure nothrow @nogc
    {
    }
}

private Object createUnsatisfied(AotBeanFactory factory)
{
    return new UnsatisfiedConstructorDependency(cast(TestBean) factory.getBeanOfType(typeNameOf!TestBean),
            cast(NoDependencies) factory.getBeanOfType(typeNameOf!NoDependencies));
}

private DefaultListableBeanFactory withDependenciesBean(DefaultListableBeanFactory lbf,
        void function(Object, AotBeanFactory) @safe initialize = &autowireSpouse)
{
    lbf.registerBeanDefinition("dependencies", withInitialize(definitionOf!DependenciesBean(), initialize));
    return lbf;
}

private void primaryTestBean(DefaultListableBeanFactory lbf, string name)
{
    auto definition = testBeanDefinition();
    definition.setPrimary(true);
    lbf.registerBeanDefinition(name, definition);
}

unittest
{
    // autowireWithNoDependencies
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("rod", testBeanDefinition());
    lbf.registerBeanDefinition("noDependencies", definitionOf!NoDependencies());
    assert(lbf.getBeanDefinitionCount() == 2);
    assert(cast(NoDependencies) lbf.getBean("noDependencies") !is null);
}

unittest
{
    // autowireWithSatisfiedJavaBeanDependency
    auto lbf = withDependenciesBean(new DefaultListableBeanFactory);
    lbf.registerBeanDefinition("rod", testBeanDefinition());
    auto kerry = cast(DependenciesBean) lbf.getBean("dependencies");
    assert(kerry.spouse is lbf.getBean("rod"));
}

unittest
{
    // autowireWithSatisfiedConstructorDependency
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("rod", testBeanDefinition());
    lbf.registerBeanDefinition("kerry", createdBy!SpouseConstructorBean(&createWithSpouse));
    auto kerry = cast(SpouseConstructorBean) lbf.getBean("kerry");
    assert(kerry.spouse is lbf.getBean("rod"));
}

unittest
{
    // autowireWithTwoMatchesForConstructorDependency
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("rod", testBeanDefinition());
    lbf.registerBeanDefinition("rod2", testBeanDefinition());
    lbf.registerBeanDefinition("kerry", createdBy!SpouseConstructorBean(&createWithSpouse));
    auto e = collectException!BeanCreationException(lbf.getBean("kerry"));
    assert(e !is null && e.msg.indexOf("rod") >= 0 && e.msg.indexOf("rod2") >= 0);
    assert(containsCause!NoUniqueBeanDefinitionException(e));
}

unittest
{
    // autowireWithUnsatisfiedConstructorDependency
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("rod", testBeanDefinition());
    lbf.registerBeanDefinition("bean", createdBy!UnsatisfiedConstructorDependency(&createUnsatisfied));
    auto e = collectException!BeanCreationException(lbf.getBean("bean"));
    assert(e !is null && containsCause!NoSuchBeanDefinitionException(e));
}

unittest
{
    // autowireConstructor
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("spouse", testBeanDefinition());
    lbf.registerBeanDefinition("bean", createdBy!SpouseConstructorBean(&createWithSpouse));
    auto bean = cast(SpouseConstructorBean) lbf.getBean("bean");
    assert(bean.spouse is lbf.getBean("spouse"));
    assert(lbf.getBean!TestBean() is lbf.getBean("spouse"));
}

unittest
{
    // autowireBeanByType
    auto lbf = withDependenciesBean(new DefaultListableBeanFactory);
    lbf.registerBeanDefinition("test", testBeanDefinition());
    auto bean = cast(DependenciesBean) lbf.getBean("dependencies");
    assert(bean.spouse is lbf.getBean("test"));
}

unittest
{
    // autowireBeanByTypeWithTwoMatches
    auto lbf = withDependenciesBean(new DefaultListableBeanFactory);
    lbf.registerBeanDefinition("test", testBeanDefinition());
    lbf.registerBeanDefinition("spouse", testBeanDefinition());
    auto e = collectException!BeanCreationException(lbf.getBean("dependencies"));
    assert(e !is null && e.msg.indexOf("test") >= 0 && e.msg.indexOf("spouse") >= 0);
}

unittest
{
    // autowireBeanByTypeWithDependencyCheck
    auto lbf = withDependenciesBean(new DefaultListableBeanFactory);
    auto e = collectException!BeanCreationException(lbf.getBean("dependencies"));
    assert(e !is null && containsCause!NoSuchBeanDefinitionException(e));
}

unittest
{
    // autowireBeanByTypeWithNoDependencyCheck
    auto lbf = withDependenciesBean(new DefaultListableBeanFactory, &autowireOptionalSpouse);
    assert((cast(DependenciesBean) lbf.getBean("dependencies")).spouse is null);
}

unittest
{
    // autowireBeanByTypeWithTwoMatchesAndOnePrimary
    auto lbf = withDependenciesBean(new DefaultListableBeanFactory);
    primaryTestBean(lbf, "test");
    lbf.registerBeanDefinition("spouse", testBeanDefinition());
    assert((cast(DependenciesBean) lbf.getBean("dependencies")).spouse is lbf.getBean("test"));
}

unittest
{
    // autowireBeanByTypeWithTwoPrimaryCandidates
    auto lbf = withDependenciesBean(new DefaultListableBeanFactory);
    primaryTestBean(lbf, "test");
    primaryTestBean(lbf, "spouse");
    auto e = collectException!BeanCreationException(lbf.getBean("dependencies"));
    assert(e !is null && cast(NoUniqueBeanDefinitionException) e.getCause() !is null);
}

unittest
{
    // autowireBeanByTypeWithTwoPrimaryCandidatesInOneAncestor
    auto parent = new DefaultListableBeanFactory;
    primaryTestBean(parent, "test");
    primaryTestBean(parent, "spouse");
    auto lbf = withDependenciesBean(new DefaultListableBeanFactory(parent));
    auto e = collectException!BeanCreationException(lbf.getBean("dependencies"));
    assert(e !is null && cast(NoUniqueBeanDefinitionException) e.getCause() !is null);
}

// ---- circular references

private void spouseByIndex(Object bean, AotBeanFactory factory)
{
    auto testBean = cast(TestBean) bean;
    const i = Integer.parseInt(testBean.getBeanName()[4 .. $]);
    testBean.setSpouse(cast(ITestBean) factory.getBean("bean" ~ valueOf(i < 99 ? i + 1 : 0)));
}

unittest
{
    // extensiveCircularReference
    auto lbf = new DefaultListableBeanFactory;
    foreach (i; 0 .. 1000)
        lbf.registerBeanDefinition("bean" ~ valueOf(i), withInitialize(testBeanDefinition(), &spouseByIndex));
    lbf.preInstantiateSingletons();
    foreach (i; 0 .. 1000)
    {
        auto bean = cast(TestBean) lbf.getBean("bean" ~ valueOf(i));
        const otherBean = lbf.getBean("bean" ~ valueOf(i < 99 ? i + 1 : 0));
        assert(cast(Object) bean.getSpouse() is otherBean);
    }
}

private final class ConstructorDependencyBean
{
    this(ConstructorDependencyBean) pure nothrow @nogc
    {
    }
}

private Object createConstructorDependencyBean(AotBeanFactory factory)
{
    return new ConstructorDependencyBean(
            cast(ConstructorDependencyBean) factory.getBeanOfType(typeNameOf!ConstructorDependencyBean));
}

unittest
{
    // circularReferenceThroughAutowiring
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("test", createdBy!ConstructorDependencyBean(&createConstructorDependencyBean));
    auto e = collectException!BeanCreationException(lbf.preInstantiateSingletons());
    assert(e !is null && containsCause!BeanCurrentlyInCreationException(e));
}

// ---- post-processors and destruction

private final class ReplacingPostProcessor : BeanPostProcessor
{
    override Object postProcessBeforeInitialization(Object, string)
    {
        return new TestBean;
    }
}

private final class BeanWithDisposableBean : DisposableBean
{
    static bool closed;

    void destroy()
    {
        closed = true;
    }
}

private final class BeanWithCloseable
{
    static bool closed;

    void close()
    {
        closed = true;
    }
}

private final class BeanWithDestroyMethod
{
    static int closeCount;

    void close()
    {
        closeCount++;
    }
}

private void closeCloseable(Object bean)
{
    (cast(BeanWithCloseable) bean).close();
}

private void closeDestroyMethod(Object bean)
{
    (cast(BeanWithDestroyMethod) bean).close();
}

unittest
{
    // beanPostProcessorWithWrappedObjectAndDisposableBean
    auto lbf = new DefaultListableBeanFactory;
    const disposable = typeNameOf!DisposableBean;
    lbf.registerBeanDefinition("test", definitionOf!BeanWithDisposableBean([disposable]));
    lbf.addBeanPostProcessor(new ReplacingPostProcessor);
    BeanWithDisposableBean.closed = false;
    lbf.preInstantiateSingletons();
    lbf.destroySingletons();
    assert(BeanWithDisposableBean.closed, "Destroy method invoked");
}

unittest
{
    // beanPostProcessorWithWrappedObjectAndCloseable
    // The inferred close() is called by the generated destroy function.
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("test", withDestroy(definitionOf!BeanWithCloseable(), &closeCloseable));
    lbf.addBeanPostProcessor(new ReplacingPostProcessor);
    BeanWithCloseable.closed = false;
    lbf.preInstantiateSingletons();
    lbf.destroySingletons();
    assert(BeanWithCloseable.closed, "Destroy method invoked");
}

unittest
{
    // beanPostProcessorWithWrappedObjectAndDestroyMethod
    auto lbf = new DefaultListableBeanFactory;
    lbf.registerBeanDefinition("test", withDestroy(definitionOf!BeanWithDestroyMethod(), &closeDestroyMethod));
    lbf.addBeanPostProcessor(new ReplacingPostProcessor);
    BeanWithDestroyMethod.closeCount = 0;
    lbf.preInstantiateSingletons();
    lbf.destroySingletons();
    assert(BeanWithDestroyMethod.closeCount == 1, "Destroy methods invoked");
}

private final class BeanWithInitAndDestroyMethods : InitializingBean, DisposableBean
{
    string[] initMethods;
    string[] destroyMethods;

    void afterPropertiesSet()
    {
        initMethods ~= "init";
    }

    void init1()
    {
        initMethods ~= "init1";
    }

    void init2()
    {
        initMethods ~= "init2";
    }

    void destroy()
    {
        destroyMethods ~= "destroy";
    }

    void destroy1()
    {
        destroyMethods ~= "destroy1";
    }

    void destroy2()
    {
        destroyMethods ~= "destroy2";
    }
}

/// setInitMethodNames("init1", "init2") as generated: afterPropertiesSet first, then the named methods.
private void initMethods(Object bean, AotBeanFactory)
{
    auto target = cast(BeanWithInitAndDestroyMethods) bean;
    target.afterPropertiesSet();
    target.init1();
    target.init2();
}

/// setDestroyMethodNames("destroy2", "destroy1") as generated: destroy() first, then the named methods.
private void destroyMethods(Object bean)
{
    auto target = cast(BeanWithInitAndDestroyMethods) bean;
    target.destroy();
    target.destroy2();
    target.destroy1();
}

unittest
{
    // multipleInitAndDestroyMethods
    auto lbf = new DefaultListableBeanFactory;
    auto definition = withDestroy(withInitialize(definitionOf!BeanWithInitAndDestroyMethods(),
            &initMethods), &destroyMethods);
    lbf.registerBeanDefinition("test", definition);
    const bean = lbf.getBean!BeanWithInitAndDestroyMethods("test");
    assert(bean.initMethods == ["init", "init1", "init2"]);
    assert(bean.destroyMethods.length == 0);
    lbf.destroySingletons();
    assert(bean.destroyMethods == ["destroy", "destroy2", "destroy1"]);
}
