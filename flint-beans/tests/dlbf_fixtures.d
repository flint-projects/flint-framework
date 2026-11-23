// Ported from spring-framework v7.1.0: spring-beans/src/testFixtures/java/org/springframework/beans/testfixture/beans
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
 * spring-beans/src/testFixtures/java/org/springframework/beans/testfixture/beans/{ITestBean,TestBean,
 * DerivedTestBean,NestedTestBean}.java and the nested fixtures of
 * spring-beans/src/test/java/org/springframework/beans/factory/DefaultListableBeanFactoryTests.java.
 */

/++
The bean fixtures the `DefaultListableBeanFactory` tests share, with the definitions Flint AOT would generate for
them: a record naming the class and every type it can be injected as, and a `create` function.
+/
module flint.beans.dlbf_fixtures;

import flint.beans.factory : BeanFactory, BeanFactoryAware, BeanNameAware, DisposableBean;
import flint.beans.factory.support : RootBeanDefinition;
import flint.engine.aot.bean : AotBeanDefinition = BeanDefinition, AotBeanFactory = BeanFactory;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : RuntimeException;

@safe:

/// The interface of `TestBean`.
interface ITestBean
{
    /// The name.
    string getName();
    /// The spouse, or null.
    ITestBean getSpouse();
}

/// Spring's `TestBean`: a name, an age, a spouse and a doctor, and the `Aware` callbacks.
class TestBean : ITestBean, BeanNameAware, BeanFactoryAware
{
    private string name;
    private string beanName;
    private int age;
    private ITestBean spouse;
    private Object doctor;
    private BeanFactory beanFactory;

    /// A bean without a name.
    this() pure nothrow @nogc
    {
    }

    /// A bean named `name`.
    this(string name) pure nothrow @nogc
    {
        this.name = name;
    }

    /// The name.
    string getName()
    {
        return name;
    }

    /// Set the name.
    void setName(string name) pure nothrow @nogc
    {
        this.name = name;
    }

    /// The age.
    int getAge() const pure nothrow @nogc
    {
        return age;
    }

    /// Set the age.
    void setAge(int age) pure nothrow @nogc
    {
        this.age = age;
    }

    /// The spouse.
    ITestBean getSpouse()
    {
        return spouse;
    }

    /// Set the spouse.
    void setSpouse(ITestBean spouse) pure nothrow @nogc
    {
        this.spouse = spouse;
    }

    /// The doctor.
    Object getDoctor() pure nothrow @nogc
    {
        return doctor;
    }

    /// Set the doctor.
    void setDoctor(Object doctor) pure nothrow @nogc
    {
        this.doctor = doctor;
    }

    /// The bean name the factory gave.
    string getBeanName() const pure nothrow @nogc
    {
        return beanName;
    }

    /// `BeanNameAware`.
    void setBeanName(string beanName)
    {
        this.beanName = beanName;
    }

    /// The owning factory.
    BeanFactory getBeanFactory() pure nothrow @nogc
    {
        return beanFactory;
    }

    /// `BeanFactoryAware`.
    void setBeanFactory(BeanFactory beanFactory)
    {
        this.beanFactory = beanFactory;
    }
}

/// Spring's `DerivedTestBean`: a `TestBean` that records its destruction.
class DerivedTestBean : TestBean, DisposableBean
{
    private bool destroyed;

    /// `DisposableBean`.
    void destroy()
    {
        destroyed = true;
    }

    /// Whether `destroy` was called.
    bool wasDestroyed() const pure nothrow @nogc
    {
        return destroyed;
    }
}

/// Spring's `NestedTestBean`: a company name.
class NestedTestBean
{
    /// The company.
    string company;
}

/// Records whether an instance was ever created.
class KnowsIfInstantiated
{
    private static bool instantiated;

    /// Record the instantiation.
    this() nothrow @nogc
    {
        instantiated = true;
    }

    /// Forget earlier instantiations.
    static void clearInstantiationRecord() nothrow @nogc
    {
        instantiated = false;
    }

    /// Whether an instance was created since the last `clearInstantiationRecord`.
    static bool wasInstantiated() nothrow @nogc
    {
        return instantiated;
    }
}

/// A bean depending on a `TestBean` (DependenciesBean, ConstructorDependency): its spouse and its bean name.
class ConstructorDependency : BeanNameAware
{
    /// The spouse, when injected.
    TestBean spouse;
    /// The spouse's age, when given.
    int spouseAge;
    /// The bean name the factory gave.
    string beanName;

    /// A bean with `spouseAge`.
    this(int spouseAge) pure nothrow @nogc
    {
        this.spouseAge = spouseAge;
    }

    /// `BeanNameAware`.
    void setBeanName(string name)
    {
        beanName = name;
    }
}

/// `new T()`: the generated factory of a class with a default constructor.
Object instantiate(T)(AotBeanFactory)
{
    return new T();
}

/// A definition of `T`, injectable as `T` and as `types`, created with `new T()`: what Flint AOT emits for a
/// component class with a default constructor.
RootBeanDefinition definitionOf(T)(string[] types = null)
{
    return createdBy!T(&instantiate!T, types);
}

/// A definition of `T`, injectable as `T` and as `types`, created by the generated factory `create`.
RootBeanDefinition createdBy(T)(Object function(AotBeanFactory) @safe create, string[] types = null)
{
    AotBeanDefinition record;
    record.type = typeNameOf!T;
    record.types = typeNameOf!T ~ types;
    record.create = create;
    return new RootBeanDefinition(record);
}

/// A definition of `TestBean` (injectable as `TestBean` and `ITestBean`).
RootBeanDefinition testBeanDefinition()
{
    return definitionOf!TestBean([typeNameOf!ITestBean]);
}

/// A definition of `DerivedTestBean` (injectable as itself, `TestBean`, `ITestBean` and `DisposableBean`).
RootBeanDefinition derivedTestBeanDefinition()
{
    return definitionOf!DerivedTestBean([
        typeNameOf!TestBean, typeNameOf!ITestBean, typeNameOf!DisposableBean
    ]);
}

/// A definition `rbd` with `initialize` set: the generated injection and init callbacks.
RootBeanDefinition withInitialize(RootBeanDefinition rbd, void function(Object, AotBeanFactory) @safe initialize)
{
    auto record = rbd.getAotDefinition();
    record.initialize = initialize;
    return copyOf(rbd, record);
}

/// A definition `rbd` with `destroy` set: the generated destruction callbacks.
RootBeanDefinition withDestroy(RootBeanDefinition rbd, void function(Object) @safe destroy)
{
    auto record = rbd.getAotDefinition();
    record.destroy = destroy;
    return copyOf(rbd, record);
}

private RootBeanDefinition copyOf(RootBeanDefinition rbd, AotBeanDefinition record)
{
    auto copy = new RootBeanDefinition(record);
    copy.setScope(rbd.getScope());
    return copy;
}

/// Whether `t` or one of its causes is an `E` (Spring's `NestedRuntimeException.contains`).
bool containsCause(E)(Throwable t)
{
    for (; t !is null; t = causeOf(t))
        if (cast(E) t !is null)
            return true;
    return false;
}

private Throwable causeOf(Throwable t)
{
    auto runtime = cast(RuntimeException) t;
    return runtime is null ? null : runtime.getCause();
}
