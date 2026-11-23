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
 * spring-beans/src/main/java/org/springframework/beans/factory/config/{BeanDefinition,BeanPostProcessor,
 * BeanFactoryPostProcessor,DestructionAwareBeanPostProcessor,SingletonBeanRegistry,ConfigurableBeanFactory,
 * ConfigurableListableBeanFactory}.java. BeanPostProcessor has only default methods, so it is an abstract class
 * (deviation D-3).
 */

/++
`org.springframework.beans.factory.config`: SPI interfaces for configuring a bean factory.
+/
module flint.beans.factory.config;

import flint.beans.factory : HierarchicalBeanFactory, ListableBeanFactory;
import flint.core : AttributeAccessor;
import flint.core.convert : ConversionService;
import flint.util : StringValueResolver;

@safe:

/// Describes a bean instance: its type, scope, laziness, dependencies and role.
interface BeanDefinition : AttributeAccessor
{
    /// The singleton scope.
    enum SCOPE_SINGLETON = "singleton";
    /// The prototype scope.
    enum SCOPE_PROTOTYPE = "prototype";
    /// An application-level bean.
    enum int ROLE_APPLICATION = 0;
    /// A supporting part of a larger configuration.
    enum int ROLE_SUPPORT = 1;
    /// An infrastructure bean, of no relevance to the user.
    enum int ROLE_INFRASTRUCTURE = 2;

    /// Set the bean's class name (canonical D name).
    void setBeanClassName(string beanClassName);
    /// The bean's class name, or null.
    string getBeanClassName();
    /// Set the scope.
    void setScope(string scope_);
    /// The scope; empty means singleton.
    string getScope();
    /// Set lazy initialization.
    void setLazyInit(bool lazyInit);
    /// Whether the bean is lazily initialized.
    bool isLazyInit();
    /// Set the names of beans this one depends on.
    void setDependsOn(string[] dependsOn...);
    /// The names of beans this one depends on.
    string[] getDependsOn();
    /// Set whether the bean is an autowiring candidate.
    void setAutowireCandidate(bool autowireCandidate);
    /// Whether the bean is an autowiring candidate.
    bool isAutowireCandidate();
    /// Set whether the bean is a primary autowire candidate.
    void setPrimary(bool primary);
    /// Whether the bean is a primary autowire candidate.
    bool isPrimary();
    /// Set whether the bean is a fallback autowire candidate.
    void setFallback(bool fallback);
    /// Whether the bean is a fallback autowire candidate.
    bool isFallback();
    /// Set the factory bean name for a `@Bean` method.
    void setFactoryBeanName(string factoryBeanName);
    /// The factory bean name, or null.
    string getFactoryBeanName();
    /// Set the factory method name for a `@Bean` method.
    void setFactoryMethodName(string factoryMethodName);
    /// The factory method name, or null.
    string getFactoryMethodName();
    /// Set the role hint.
    void setRole(int role);
    /// The role hint.
    int getRole();
    /// Set a human-readable description.
    void setDescription(string description);
    /// The description, or null.
    string getDescription();
    /// Whether the scope is singleton.
    bool isSingleton();
    /// Whether the scope is prototype.
    bool isPrototype();
    /// Whether the definition is abstract (never instantiated).
    bool isAbstract();
    /// Where the definition came from, for error messages.
    string getResourceDescription();
}

/++
Factory hook allowing custom modification of new bean instances (Java's interface of two default methods; an
abstract class here, deviation D-3).
+/
abstract class BeanPostProcessor
{
    /// Applied before initialization callbacks; returns the bean to use (or null to stop processing).
    Object postProcessBeforeInitialization(Object bean, string)
    {
        return bean;
    }

    /// Applied after initialization callbacks; returns the bean to use (or null to stop processing).
    Object postProcessAfterInitialization(Object bean, string)
    {
        return bean;
    }
}

/// A `BeanPostProcessor` that also receives destruction callbacks.
abstract class DestructionAwareBeanPostProcessor : BeanPostProcessor
{
    /// Applied before the bean's own destruction callbacks.
    abstract void postProcessBeforeDestruction(Object bean, string beanName);

    /// Whether this processor applies to `bean`.
    bool requiresDestruction(Object)
    {
        return true;
    }
}

/// Factory hook allowing custom modification of an application context's bean definitions.
interface BeanFactoryPostProcessor
{
    /// Modify the bean factory after standard initialization: every definition is loaded, no bean is created.
    void postProcessBeanFactory(ConfigurableListableBeanFactory beanFactory);
}

/// Interface that defines a registry for shared bean instances.
interface SingletonBeanRegistry
{
    /// Register a fully initialized singleton under `beanName`.
    void registerSingleton(string beanName, Object singletonObject);
    /// The raw singleton registered under `beanName`, or null.
    Object getSingleton(string beanName);
    /// Whether a singleton is registered under `beanName`.
    bool containsSingleton(string beanName);
    /// The registered singleton names.
    string[] getSingletonNames();
    /// How many singletons are registered.
    int getSingletonCount();
}

/// Configuration interface implemented by most bean factories.
interface ConfigurableBeanFactory : HierarchicalBeanFactory, SingletonBeanRegistry
{
    /// The singleton scope identifier.
    enum SCOPE_SINGLETON = "singleton";
    /// The prototype scope identifier.
    enum SCOPE_PROTOTYPE = "prototype";

    /// Set the conversion service for `@Value` and property conversion.
    void setConversionService(ConversionService conversionService);
    /// The conversion service, or null.
    ConversionService getConversionService();
    /// Add a resolver for `${...}` in annotation attributes and `@Value`.
    void addEmbeddedValueResolver(StringValueResolver valueResolver);
    /// Whether an embedded value resolver is registered.
    bool hasEmbeddedValueResolver();
    /// `value` through every embedded value resolver.
    string resolveEmbeddedValue(string value);
    /// Add a `BeanPostProcessor`, applied in registration order.
    void addBeanPostProcessor(BeanPostProcessor beanPostProcessor);
    /// How many post-processors are registered.
    int getBeanPostProcessorCount();
    /// Register `alias` for `beanName`.
    void registerAlias(string beanName, string alias_);
    /// Whether `beanName` is currently in creation.
    bool isCurrentlyInCreation(string beanName);
    /// Register `dependentBeanName` as depending on `beanName`, to be destroyed first.
    void registerDependentBean(string beanName, string dependentBeanName);
    /// The beans that depend on `beanName`.
    string[] getDependentBeans(string beanName);
    /// The beans `beanName` depends on.
    string[] getDependenciesForBean(string beanName);
    /// Destroy the singleton `beanName`.
    void destroyBean(string beanName);
    /// Destroy every singleton, in reverse creation order.
    void destroySingletons();
}

/// Configuration interface implemented by most listable bean factories.
interface ConfigurableListableBeanFactory : ListableBeanFactory, ConfigurableBeanFactory
{
    /// The definition named `beanName`. Throws `NoSuchBeanDefinitionException`.
    BeanDefinition getBeanDefinition(string beanName);
    /// Freeze the definitions: no further changes are expected.
    void freezeConfiguration();
    /// Whether the definitions are frozen.
    bool isConfigurationFrozen();
    /// Create every non-lazy singleton, then call `SmartInitializingSingleton` callbacks.
    void preInstantiateSingletons();
}
