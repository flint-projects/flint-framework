// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/context/support/GenericApplicationContextTests.java
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
 * spring-context/src/test/java/org/springframework/context/support/GenericApplicationContextTests.java.
 */

/++
`GenericApplicationContextTests`. A Java `String` bean is a `TestString` here (D strings are not class instances);
`registerBean(BeanA.class)` with constructor autowiring is the definition Flint AOT generates for `BeanA`.

Skipped Java tests (42 in the class):
- configureApplicationStartupOnBeanFactory: `ApplicationStartup` / Java Flight Recorder.
- getResourceWithCustomResourceLoader: `GenericApplicationContext.setResourceLoader` is not ported.
- refreshForAotSetsContextActive, refreshForAotRegistersEnvironment, refreshForAotLoadsBeanClassName,
  refreshForAotLoadsBeanClassNameOfIndexedConstructorArgumentInnerBeanDefinition,
  refreshForAotLoadsBeanClassNameOfGenericConstructorArgumentInnerBeanDefinition,
  refreshForAotLoadsBeanClassNameOfPropertyValueInnerBeanDefinition,
  refreshForAotLoadsTypedStringValueClassNameInProperty,
  refreshForAotLoadsTypedStringValueClassNameInIndexedConstructorArgument,
  refreshForAotLoadsTypedStringValueClassNameInGenericConstructorArgument,
  refreshForAotInvokesBeanFactoryPostProcessors, refreshForAotInvokesMergedBeanDefinitionPostProcessors,
  refreshForAotInvokesMergedBeanDefinitionPostProcessorsOnIndexedConstructorArgument,
  refreshForAotInvokesMergedBeanDefinitionPostProcessorsOnGenericConstructorArgument,
  refreshForAotInvokesMergedBeanDefinitionPostProcessorsOnPropertyValue, refreshForAotFreezeConfiguration,
  refreshForAotInvokesBeanPostProcessorContractOnMergedBeanDefinitionPostProcessors,
  refreshForAotFailsOnAnActiveContext, refreshForAotDoesNotInitializeFactoryBeansEarly,
  refreshForAotDoesNotInstantiateBean, refreshForAotRegisterProxyHint: `refreshForAotProcessing` and
  `RuntimeHints` (Flint AOT runs at build time).
- beanRegistrar, beanRegistrarWithCircularReference, beanRegistrarWithDefinitionOverride, importAwareBeanRegistrar,
  beanRegistrarWithConditionNotMet, beanRegistrarWithConditionMet: Spring 7's `BeanRegistrar` API is not ported.
+/
module flint.context.generic_context_test;

import flint.beans.factory : BeanCreationException, InitializingBean, DisposableBean,
    NoUniqueBeanDefinitionException, SmartInitializingSingleton;
import flint.beans.factory.config : BeanDefinition;
import flint.beans.factory.support : RootBeanDefinition;
import flint.context : ApplicationContext, ApplicationContextAware;
import flint.context.support : GenericApplicationContext;
import flint.core.io : ByteArrayResource, ClassPathResource, FileSystemResource, ProtocolResolver,
    Resource, ResourceLoader;
import flint.engine.aot.bean : AotBeanDefinition = BeanDefinition, AotBeanFactory = BeanFactory;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : IllegalStateException;
import flint.engine.aot.registry : AotRegistry;
import std.exception : assertThrown, collectException;
import std.string : indexOf;

@safe:

private interface CharSequence
{
}

/// Java's `String` bean.
private final class TestString : CharSequence
{
    string value;

    this(string value = "") pure nothrow @nogc
    {
        this.value = value;
    }
}

private Object createTestString(AotBeanFactory)
{
    return new TestString;
}

/// `new RootBeanDefinition(String.class)`: injectable as String and CharSequence.
private RootBeanDefinition testStringDefinition()
{
    AotBeanDefinition record;
    record.type = typeNameOf!TestString;
    record.types = [typeNameOf!TestString, typeNameOf!CharSequence];
    record.create = &createTestString;
    return new RootBeanDefinition(record);
}

private final class BeanA
{
    BeanB b;
    BeanC c;

    this(BeanB b, BeanC c) pure nothrow @nogc
    {
        this.b = b;
        this.c = c;
    }
}

private final class BeanB : ApplicationContextAware
{
    ApplicationContext applicationContext;

    void setApplicationContext(ApplicationContext applicationContext)
    {
        this.applicationContext = applicationContext;
    }
}

private final class BeanC
{
}

private class BeanE : InitializingBean, DisposableBean
{
    bool initialized;
    bool destroyed;

    void afterPropertiesSet()
    {
        if (initialized)
            throw new IllegalStateException("AfterPropertiesSet called twice");
        initialized = true;
    }

    void destroy()
    {
        if (destroyed)
            throw new IllegalStateException("Destroy called twice");
        destroyed = true;
    }
}

// ---- what Flint AOT generates for registerBean(BeanA.class) and friends

private Object createBeanA(AotBeanFactory factory)
{
    return new BeanA(cast(BeanB) factory.getBeanOfType(typeNameOf!BeanB),
            cast(BeanC) factory.getBeanOfType(typeNameOf!BeanC));
}

private Object createBeanB(AotBeanFactory)
{
    return new BeanB;
}

private Object createBeanC(AotBeanFactory)
{
    return new BeanC;
}

private AotBeanDefinition record(T)(string name, Object function(AotBeanFactory) @safe create, string[] types...)
{
    AotBeanDefinition definition;
    definition.name = name;
    definition.type = typeNameOf!T;
    definition.types = typeNameOf!T ~ types.dup;
    definition.create = create;
    return definition;
}

private void populateClassNamed(scope AotRegistry registry)
{
    registry.begin(1, 1);
    registry.bean(record!BeanA(typeNameOf!BeanA, &createBeanA));
    registry.bean(record!BeanB(typeNameOf!BeanB, &createBeanB, typeNameOf!ApplicationContextAware));
    registry.bean(record!BeanC(typeNameOf!BeanC, &createBeanC));
    registry.end();
}

private void populateNamed(scope AotRegistry registry)
{
    registry.begin(1, 1);
    registry.bean(record!BeanA("a", &createBeanA));
    registry.bean(record!BeanB("b", &createBeanB, typeNameOf!ApplicationContextAware));
    registry.bean(record!BeanC("c", &createBeanC));
    registry.end();
}

unittest
{
    // getBeanForClass
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
    context.registerBeanDefinition("testBean", testStringDefinition());
    context.refresh();

    assert((cast(TestString) context.getBean("testBean")).value == "");
    assert(context.getBean!TestString() is context.getBean("testBean"));
    assert(cast(Object) context.getBean!CharSequence() is context.getBean("testBean"));
    assertThrown!NoUniqueBeanDefinitionException(context.getBean!Object());
}

unittest
{
    // withSingletonSupplier
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
    auto definition = testStringDefinition();
    definition.setInstanceSupplier(() => new TestString(context.toString()));
    context.registerBeanDefinition("testBean", definition);
    context.refresh();

    assert(context.getBean("testBean") is context.getBean("testBean"));
    assert(context.getBean!TestString() is context.getBean("testBean"));
    assert(cast(Object) context.getBean!CharSequence() is context.getBean("testBean"));
    assert(context.getBean!TestString("testBean").value == context.toString());
}

unittest
{
    // withScopedSupplier
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
    auto definition = testStringDefinition();
    definition.setScope(BeanDefinition.SCOPE_PROTOTYPE);
    definition.setInstanceSupplier(() => new TestString(context.toString()));
    context.registerBeanDefinition("testBean", definition);
    context.refresh();

    assert(context.getBean("testBean") !is context.getBean("testBean"));
    assert(context.getBean!TestString().value == context.getBean!TestString("testBean").value);
    assert((cast(TestString) context.getBean!CharSequence()).value == context.getBean!TestString("testBean").value);
    assert(context.getBean!TestString("testBean").value == context.toString());
}

unittest
{
    // accessAfterClosing
    // (getAutowireCapableBeanFactory is not ported.)
    auto context = new GenericApplicationContext;
    context.registerBeanDefinition("testBean", testStringDefinition());
    context.refresh();
    assert(context.getBean!TestString() is context.getBean("testBean"));
    context.close();
    assertThrown!IllegalStateException(context.getBean!TestString());
    assertThrown!IllegalStateException(context.getBean("testBean"));
}

unittest
{
    // individualBeans
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
    context.loadAotRegistry(&populateClassNamed);
    context.refresh();
    assert(context.getBean!BeanA().b is context.getBean!BeanB());
    assert(context.getBean!BeanA().c is context.getBean!BeanC());
    assert(context.getBean!BeanB().applicationContext is context);
}

unittest
{
    // individualNamedBeans
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
    context.loadAotRegistry(&populateNamed);
    context.refresh();
    assert(context.getBean!BeanA("a").b is context.getBean("b"));
    assert(context.getBean!BeanA("a").c is context.getBean("c"));
    assert(context.getBean!BeanB("b").applicationContext is context);
}

unittest
{
    // individualBeanWithSupplier
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
    context.registerBean!BeanA(() => new BeanA(context.getBean!BeanB(), context.getBean!BeanC()));
    context.registerBean!BeanB(() => new BeanB);
    context.registerBean!BeanC(() => new BeanC);
    context.refresh();

    assert(context.getBeanFactory().containsSingleton(typeNameOf!BeanA));
    assert(context.getBean!BeanA().b is context.getBean!BeanB());
    assert(context.getBean!BeanA().c is context.getBean!BeanC());
    assert(context.getBean!BeanB().applicationContext is context);
    auto factory = context.getDefaultListableBeanFactory();
    assert(factory.getDependentBeans(typeNameOf!BeanB) == [typeNameOf!BeanA]);
    assert(factory.getDependentBeans(typeNameOf!BeanC) == [typeNameOf!BeanA]);
}

unittest
{
    // individualBeanWithSupplierAndCustomizer
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
    context.registerBean!BeanA(() => new BeanA(context.getBean!BeanB(), context.getBean!BeanC()),
            (BeanDefinition definition) { definition.setLazyInit(true); });
    context.registerBean!BeanB(() => new BeanB);
    context.registerBean!BeanC(() => new BeanC);
    context.refresh();

    assert(!context.getBeanFactory().containsSingleton(typeNameOf!BeanA));
    assert(context.getBean!BeanA().b is context.getBean!BeanB());
    assert(context.getBean!BeanA().c is context.getBean!BeanC());
    assert(context.getBean!BeanB().applicationContext is context);
}

unittest
{
    // individualNamedBeanWithSupplier
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
    context.registerBean!BeanA("a", () => new BeanA(context.getBean!BeanB(), context.getBean!BeanC()));
    context.registerBean!BeanB("b", () => new BeanB);
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
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
    context.registerBean!BeanA("a", () => new BeanA(context.getBean!BeanB(),
            context.getBean!BeanC()), (BeanDefinition definition) { definition.setLazyInit(true); });
    context.registerBean!BeanB("b", () => new BeanB);
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
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
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
}

private final class PingPongProtocolResolver : ProtocolResolver
{
    Resource resolve(string location, ResourceLoader)
    {
        if (location.length >= 5 && location[0 .. 5] == "ping:")
            return new ByteArrayResource(cast(immutable(ubyte)[])("pong:" ~ location[5 .. $]));
        return null;
    }
}

unittest
{
    // getResourceWithDefaultResourceLoader
    // A "file:" location is a FileSystemResource in Flint (Spring: FileUrlResource).
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
    assert(cast(ClassPathResource) context.getResource("foo") !is null);
    assert(cast(FileSystemResource) context.getResource("file:foo") !is null);
    assert(cast(ClassPathResource) context.getResource("ping:foo") !is null);

    context.addProtocolResolver(new PingPongProtocolResolver);
    assert(cast(ClassPathResource) context.getResource("foo") !is null);
    assert(cast(FileSystemResource) context.getResource("file:foo") !is null);
    auto pong = cast(ByteArrayResource) context.getResource("ping:foo");
    assert(pong !is null && cast(const(char)[]) pong.getByteArray() == "pong:foo");
}

/// Java's anonymous `BeanE` whose `afterPropertiesSet` fails.
private final class FailingBeanE : BeanE
{
    override void afterPropertiesSet()
    {
        throw new IllegalStateException("Expected");
    }
}

/// Java's lambda `SmartInitializingSingleton` that fails.
private final class FailingSmartInitializingSingleton : SmartInitializingSingleton
{
    void afterSingletonsInstantiated()
    {
        throw new IllegalStateException("expected");
    }
}

unittest
{
    // refreshWithRuntimeFailureOnBeanCreationDisposeExistingBeans
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
    auto one = new BeanE;
    context.registerBean!BeanE("one", () => one);
    context.registerBean!BeanE("two", () => new FailingBeanE);
    auto e = collectException!BeanCreationException(context.refresh());
    assert(e !is null && e.msg.indexOf("two") >= 0);
    assert(one.initialized);
    assert(one.destroyed);
}

unittest
{
    // refreshWithRuntimeFailureOnAfterSingletonInstantiatedDisposeExistingBeans
    auto context = new GenericApplicationContext;
    scope (exit)
        context.close();
    auto one = new BeanE;
    auto two = new BeanE;
    context.registerBean!BeanE("one", () => one);
    context.registerBean!BeanE("two", () => two);
    context.registerBean!SmartInitializingSingleton("int", () => new FailingSmartInitializingSingleton);
    auto e = collectException!IllegalStateException(context.refresh());
    assert(e !is null && e.msg.indexOf("expected") >= 0);
    assert(one.initialized && two.initialized);
    assert(one.destroyed && two.destroyed);
}
