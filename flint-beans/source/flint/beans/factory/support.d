// Ported from spring-framework v7.1.0: spring-beans/src/main/java/org/springframework/beans/factory/support
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
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
 * spring-beans/src/main/java/org/springframework/beans/factory/support/{BeanDefinitionRegistry,
 * AbstractBeanDefinition,RootBeanDefinition,GenericBeanDefinition,BeanDefinitionOverrideException,
 * DefaultSingletonBeanRegistry,AbstractBeanFactory,AbstractAutowireCapableBeanFactory,
 * DefaultListableBeanFactory}.java. Instances are created by Flint AOT's generated factories
 * (flint.engine.aot.bean.BeanDefinition) instead of reflection; candidate resolution, primary/fallback selection,
 * circular-reference detection, post-processing and destruction follow Spring.
 */

/++
`org.springframework.beans.factory.support`: the bean factory implementation.

A definition is a `RootBeanDefinition` wrapping the record Flint AOT generates (or one built by
`GenericApplicationContext.registerBean`). `DefaultListableBeanFactory` creates singletons in definition order,
each dependency on demand, in Spring's sequence: instantiate, `BeanNameAware`/`BeanFactoryAware`,
`postProcessBeforeInitialization`, the generated `initialize` (injection, `@PostConstruct`, `afterPropertiesSet`),
`postProcessAfterInitialization`, then the generated AOP proxy. Generated code calls the factory through
`aotBeanFactory()`, the contract's `flint.engine.aot.bean.BeanFactory`.
+/
module flint.beans.factory.support;

import flint.beans : BeansException;
import flint.beans.factory : BeanCreationException, BeanCurrentlyInCreationException,
    BeanDefinitionStoreException, BeanFactory, BeanFactoryAware, BeanNameAware,
    BeanNotOfRequiredTypeException, DisposableBean, InitializingBean,
    NoSuchBeanDefinitionException, NoUniqueBeanDefinitionException, SmartInitializingSingleton;
import flint.beans.factory.config : BeanDefinition, BeanPostProcessor,
    ConfigurableListableBeanFactory, ConfigurationPropertiesBinder, DestructionAwareBeanPostProcessor;
import flint.engine.aot.descriptor : DescriptorTable;
import flint.core : AliasRegistry, AttributeAccessorSupport, Ordered, PriorityOrdered, SimpleAliasRegistry;
import flint.core.convert : ConversionService, TypeDescriptor;
import flint.engine.aot.any : Any;
import flint.engine.aot.bean : AotBeanDefinition = BeanDefinition, AotBeanFactory = BeanFactory, ScopeKind;
import flint.engine.aot.descriptor : findAnnotation, MergedAnnotation;
import flint.engine.aot.name : canonicalTypeName, typeNameOf;
import flint.java.lang : IllegalStateException, UnsupportedOperationException, valueOf;
import flint.java.util : stableSort;
import flint.util : Assert, StringValueResolver;

@safe:

/// Interface for registries that hold bean definitions.
interface BeanDefinitionRegistry : AliasRegistry
{
    /// Register `beanDefinition` under `beanName`. Throws `BeanDefinitionOverrideException` when overriding is off.
    void registerBeanDefinition(string beanName, BeanDefinition beanDefinition);
    /// Remove the definition. Throws `NoSuchBeanDefinitionException`.
    void removeBeanDefinition(string beanName);
    /// The definition. Throws `NoSuchBeanDefinitionException`.
    BeanDefinition getBeanDefinition(string beanName);
    /// Whether a definition named `beanName` exists.
    bool containsBeanDefinition(string beanName);
    /// Every definition name.
    string[] getBeanDefinitionNames();
    /// How many definitions exist.
    int getBeanDefinitionCount();
    /// Whether `beanName` is in use as a bean name or alias.
    bool isBeanNameInUse(string beanName);
}

/// Thrown when a definition is registered under a name that is taken and overriding is not allowed.
class BeanDefinitionOverrideException : BeanDefinitionStoreException
{
    /// Spring's message for `beanName`.
    this(string beanName, BeanDefinition beanDefinition, BeanDefinition existingDefinition)
    {
        super(beanDefinition.getResourceDescription(), beanName, "Cannot register bean definition [" ~ describe(
                beanDefinition) ~ "] for bean '" ~ beanName ~ "' since there is already [" ~ describe(
                existingDefinition) ~ "] bound.");
    }

    private static string describe(BeanDefinition definition)
    {
        return valueOf(cast(Object) definition);
    }
}

/++
A bean definition: the Spring-shaped view of a Flint AOT record, plus the settings Spring code changes after
registration (scope, laziness, primary, dependencies).
+/
class RootBeanDefinition : AttributeAccessorSupport, BeanDefinition
{
    private AotBeanDefinition record;
    private string scopeName;
    private bool autowireCandidate = true;
    private bool abstract_;
    private int role;
    private string description;

    /// A definition over the generated `record`.
    this(AotBeanDefinition record)
    {
        this.record = record;
        scopeName = scopeNameOf(record.scope_);
    }

    /// A definition of type `beanClassName` created by `create`.
    this(string beanClassName, Object function(AotBeanFactory) @safe create)
    {
        AotBeanDefinition built;
        built.type = beanClassName;
        built.types = [beanClassName];
        built.create = create;
        this(built);
    }

    private static string scopeNameOf(ScopeKind kind) pure nothrow @nogc
    {
        final switch (kind)
        {
        case ScopeKind.singleton:
            return "singleton";
        case ScopeKind.prototype:
            return "prototype";
        case ScopeKind.request:
            return "request";
        case ScopeKind.session:
            return "session";
        }
    }

    /// The generated record.
    final AotBeanDefinition getAotDefinition() pure nothrow @nogc
    {
        return record;
    }

    /// Replace the creation callbacks with a delegate-backed factory (registerBean with a supplier).
    package(flint) final void setInstanceSupplier(Object delegate() @safe supplier) pure nothrow @nogc
    {
        instanceSupplier = supplier;
    }

    package(flint) Object delegate() @safe instanceSupplier;

    /// Every type the bean can be injected as.
    final string[] getTypes() pure nothrow @nogc
    {
        return record.types;
    }

    /// Set the types the bean can be injected as.
    final void setTypes(string[] types) pure nothrow @nogc
    {
        record.types = types;
    }

    /// The `@Qualifier` values on the definition.
    final string[] getQualifiers() pure nothrow @nogc
    {
        return record.qualifiers;
    }

    /// The `@Order` value (`Ordered.LOWEST_PRECEDENCE` when absent).
    final int getOrder() const pure nothrow @nogc
    {
        return record.order;
    }

    /// Set the canonical class name.
    void setBeanClassName(string beanClassName)
    {
        record.type = beanClassName;
        if (record.types.length == 0)
            record.types = [beanClassName];
    }

    /// The canonical class name.
    string getBeanClassName()
    {
        return record.type;
    }

    /// Set the scope.
    void setScope(string scope_)
    {
        scopeName = scope_;
    }

    /// The scope.
    string getScope()
    {
        return scopeName;
    }

    /// Set lazy initialization.
    void setLazyInit(bool lazyInit)
    {
        record.lazyInit = lazyInit;
    }

    /// Whether lazily initialized.
    bool isLazyInit()
    {
        return record.lazyInit;
    }

    /// Set the dependencies.
    void setDependsOn(string[] dependsOn...)
    {
        record.dependsOn = dependsOn.dup;
    }

    /// The dependencies.
    string[] getDependsOn()
    {
        return record.dependsOn;
    }

    /// Set whether an autowire candidate.
    void setAutowireCandidate(bool autowireCandidate)
    {
        this.autowireCandidate = autowireCandidate;
    }

    /// Whether an autowire candidate.
    bool isAutowireCandidate()
    {
        return autowireCandidate;
    }

    /// Set primary.
    void setPrimary(bool primary)
    {
        record.primary = primary;
    }

    /// Whether primary.
    bool isPrimary()
    {
        return record.primary;
    }

    /// Set fallback.
    void setFallback(bool fallback)
    {
        record.fallback = fallback;
    }

    /// Whether fallback.
    bool isFallback()
    {
        return record.fallback;
    }

    /// Unsupported: `@Bean` methods are wired by generated code.
    void setFactoryBeanName(string)
    {
        throw new UnsupportedOperationException("Flint AOT wires @Bean methods in generated code");
    }

    /// null: `@Bean` methods are wired by generated code.
    string getFactoryBeanName()
    {
        return null;
    }

    /// Unsupported: `@Bean` methods are wired by generated code.
    void setFactoryMethodName(string)
    {
        throw new UnsupportedOperationException("Flint AOT wires @Bean methods in generated code");
    }

    /// null.
    string getFactoryMethodName()
    {
        return null;
    }

    /// Set the role.
    void setRole(int role)
    {
        this.role = role;
    }

    /// The role.
    int getRole()
    {
        return role;
    }

    /// Set the description.
    void setDescription(string description)
    {
        this.description = description;
    }

    /// The description.
    string getDescription()
    {
        return description;
    }

    /// Whether the scope is singleton (or empty).
    bool isSingleton()
    {
        return scopeName.length == 0 || scopeName == SCOPE_SINGLETON;
    }

    /// Whether the scope is prototype.
    bool isPrototype()
    {
        return scopeName == SCOPE_PROTOTYPE;
    }

    /// Whether abstract.
    bool isAbstract()
    {
        return abstract_;
    }

    /// Set whether abstract.
    void setAbstract(bool abstract_)
    {
        this.abstract_ = abstract_;
    }

    /// Where the definition came from: the generated record's source location.
    string getResourceDescription()
    {
        return record.source;
    }

    /// `Root bean: class [type]; scope=singleton; lazyInit=false; primary=false; ...`.
    override string toString()
    {
        return "Root bean: class [" ~ record.type ~ "]; scope=" ~ scopeName ~ "; abstract=" ~ valueOf(
                abstract_) ~ "; lazyInit=" ~ valueOf(record.lazyInit) ~ "; dependsOn=" ~ joinComma(
                record.dependsOn) ~ "; primary=" ~ valueOf(record.primary) ~ "; fallback=" ~ valueOf(
                record.fallback) ~ (record.source.length ? "; defined in " ~ record.source : "");
    }
}

/// A `RootBeanDefinition` built programmatically (Spring's `GenericBeanDefinition`).
class GenericBeanDefinition : RootBeanDefinition
{
    /// A definition with no type yet.
    this()
    {
        super(AotBeanDefinition.init);
    }
}

private string joinComma(string[] values)
{
    if (values is null)
        return "null";
    string result;
    foreach (i, value; values)
        result ~= (i ? "," : "") ~ value;
    return result;
}

/++
Spring's default `ConfigurableListableBeanFactory` and `BeanDefinitionRegistry`: a factory fed by bean
definitions, creating singletons on demand.
+/
class DefaultListableBeanFactory : SimpleAliasRegistry, ConfigurableListableBeanFactory, BeanDefinitionRegistry
{
    private RootBeanDefinition[string] definitions;
    private string[] definitionNames;
    private Object[string] singletons;
    private Object[string] targets;
    private string[] singletonOrder;
    private bool[string] inCreation;
    private string[][string] dependents;
    private string[][string] dependencies;
    private BeanPostProcessor[] postProcessors;
    private StringValueResolver[] valueResolvers;
    private ConversionService conversionService;
    private DescriptorTable descriptors;
    private Object[string] resolvableDependencies;
    private BeanFactory parent;
    private bool frozen;
    private bool allowOverriding = true;
    private bool destroying;
    private AotAdapter adapter;

    /// An empty factory.
    this()
    {
        adapter = new AotAdapter(this);
    }

    /// An empty factory with `parentBeanFactory`.
    this(BeanFactory parentBeanFactory)
    {
        this();
        parent = parentBeanFactory;
    }

    /// The contract's `BeanFactory` that generated factories and initializers call.
    final AotBeanFactory aotBeanFactory() pure nothrow @nogc
    {
        return adapter;
    }

    /// Whether a definition may replace one with the same name (Spring's default true; Boot sets false).
    void setAllowBeanDefinitionOverriding(bool allowBeanDefinitionOverriding) pure nothrow @nogc
    {
        allowOverriding = allowBeanDefinitionOverriding;
    }

    /// Whether overriding is allowed.
    bool isAllowBeanDefinitionOverriding() const pure nothrow @nogc
    {
        return allowOverriding;
    }

    /// Make `autowiredValue` injectable as `dependencyType` without being a bean (Spring's
    /// `registerResolvableDependency`): the context registers itself, its environment and its factory this way.
    void registerResolvableDependency(string dependencyType, Object autowiredValue)
    {
        Assert.notNull(autowiredValue, "Autowired value must not be null");
        resolvableDependencies[dependencyType] = autowiredValue;
    }

    /// The descriptors the `@ConfigurationProperties` binder receives (the context's table).
    void setDescriptorTable(DescriptorTable table) pure nothrow @nogc
    {
        descriptors = table;
    }

    /// The `ConfigurationPropertiesBinder` bean, or null when none is registered.
    final ConfigurationPropertiesBinder getConfigurationPropertiesBinder()
    {
        return cast(ConfigurationPropertiesBinder) resolveByType(typeNameOf!ConfigurationPropertiesBinder, null, false);
    }

    // -----------------------------------------------------------------------------------------------------------
    // BeanDefinitionRegistry

    /// Register a generated record as a definition under its own name.
    void registerAotDefinition(AotBeanDefinition record)
    {
        registerBeanDefinition(record.name, new RootBeanDefinition(record));
    }

    /// Register `beanDefinition` under `beanName`.
    void registerBeanDefinition(string beanName, BeanDefinition beanDefinition)
    {
        Assert.hasText(beanName, "Bean name must not be empty");
        Assert.notNull(beanDefinition, "BeanDefinition must not be null");
        auto root = cast(RootBeanDefinition) beanDefinition;
        if (root is null)
            throw new BeanDefinitionStoreException("Flint bean definitions must be RootBeanDefinitions: " ~ beanName);
        if (auto existing = beanName in definitions)
        {
            if (!allowOverriding)
                throw new BeanDefinitionOverrideException(beanName, beanDefinition, *existing);
            definitions[beanName] = root;
            resetBeanDefinition(beanName);
            return;
        }
        if (isAlias(beanName))
        {
            if (!allowOverriding)
                throw new BeanDefinitionOverrideException(beanName, beanDefinition,
                        getBeanDefinition(canonicalName(beanName)));
            removeAlias(beanName);
        }
        definitions[beanName] = root;
        definitionNames ~= beanName;
    }

    /// Remove the definition `beanName`.
    void removeBeanDefinition(string beanName)
    {
        if ((beanName in definitions) is null)
            throw new NoSuchBeanDefinitionException(beanName);
        definitions.remove(beanName);
        string[] kept;
        foreach (name; definitionNames)
            if (name != beanName)
                kept ~= name;
        definitionNames = kept;
        resetBeanDefinition(beanName);
    }

    /// Discard the cached singleton of `beanName`.
    protected void resetBeanDefinition(string beanName)
    {
        destroySingleton(beanName);
    }

    /// The definition `beanName` (aliases resolved).
    RootBeanDefinition getBeanDefinition(string beanName)
    {
        if (auto found = canonicalName(beanName) in definitions)
            return *found;
        throw new NoSuchBeanDefinitionException(beanName);
    }

    /// Whether the definition exists.
    bool containsBeanDefinition(string beanName)
    {
        return (beanName in definitions) !is null;
    }

    /// The definition names in registration order.
    string[] getBeanDefinitionNames()
    {
        return definitionNames.dup;
    }

    /// How many definitions exist.
    int getBeanDefinitionCount()
    {
        return cast(int) definitionNames.length;
    }

    /// Whether the name is used by a definition, alias or singleton.
    bool isBeanNameInUse(string beanName)
    {
        return isAlias(beanName) || containsBeanDefinition(beanName) || containsSingleton(beanName);
    }

    /// Register an alias, checking it does not shadow a definition.
    override void registerAlias(string name, string alias_)
    {
        if (containsBeanDefinition(alias_) && name != alias_ && !allowOverriding)
            throw new IllegalStateException("Cannot define alias '" ~ alias_ ~ "' for name '" ~ name
                    ~ "': It is already registered for name '" ~ alias_ ~ "'.");
        super.registerAlias(name, alias_);
    }

    // -----------------------------------------------------------------------------------------------------------
    // SingletonBeanRegistry

    /// Register a fully initialized singleton.
    void registerSingleton(string beanName, Object singletonObject)
    {
        Assert.notNull(beanName, "Bean name must not be null");
        Assert.notNull(singletonObject, "Singleton object must not be null");
        if (auto existing = beanName in singletons)
        {
            const bound = valueOf(*existing);
            throw new IllegalStateException("Could not register object [" ~ valueOf(
                    singletonObject) ~ "] under bean name '" ~ beanName
                    ~ "': there is already object [" ~ bound ~ "] bound");
        }
        addSingleton(beanName, singletonObject);
    }

    private void addSingleton(string beanName, Object singletonObject)
    {
        singletons[beanName] = singletonObject;
        singletonOrder ~= beanName;
    }

    /// The raw singleton, or null.
    Object getSingleton(string beanName)
    {
        auto found = beanName in singletons;
        return found is null ? null : *found;
    }

    /// Whether the singleton exists.
    bool containsSingleton(string beanName)
    {
        return (beanName in singletons) !is null;
    }

    /// The singleton names, in creation order.
    string[] getSingletonNames()
    {
        return singletonOrder.dup;
    }

    /// How many singletons exist.
    int getSingletonCount()
    {
        return cast(int) singletonOrder.length;
    }

    // -----------------------------------------------------------------------------------------------------------
    // ConfigurableBeanFactory

    /// The parent factory, or null.
    BeanFactory getParentBeanFactory()
    {
        return parent;
    }

    /// Set the parent factory once.
    void setParentBeanFactory(BeanFactory parentBeanFactory)
    {
        if (parent !is null && parent !is parentBeanFactory)
        {
            const current = valueOf(cast(Object) parent);
            throw new IllegalStateException("Already associated with parent BeanFactory: " ~ current);
        }
        parent = parentBeanFactory;
    }

    /// Whether this factory itself holds `name`.
    bool containsLocalBean(string name)
    {
        const beanName = canonicalName(name);
        return containsSingleton(beanName) || containsBeanDefinition(beanName);
    }

    /// Set the conversion service.
    void setConversionService(ConversionService service)
    {
        conversionService = service;
    }

    /// The conversion service.
    ConversionService getConversionService()
    {
        return conversionService;
    }

    /// Add an embedded value resolver.
    void addEmbeddedValueResolver(StringValueResolver valueResolver)
    {
        Assert.notNull(valueResolver, "StringValueResolver must not be null");
        valueResolvers ~= valueResolver;
    }

    /// Whether an embedded value resolver exists.
    bool hasEmbeddedValueResolver()
    {
        return valueResolvers.length != 0;
    }

    /// `value` through every embedded value resolver.
    string resolveEmbeddedValue(string value)
    {
        string result = value;
        foreach (resolver; valueResolvers)
        {
            if (result is null)
                return null;
            result = resolver.resolveStringValue(result);
        }
        return result;
    }

    /// Add a post-processor; a re-added one moves to the end.
    void addBeanPostProcessor(BeanPostProcessor beanPostProcessor)
    {
        Assert.notNull(beanPostProcessor, "BeanPostProcessor must not be null");
        BeanPostProcessor[] kept;
        foreach (existing; postProcessors)
            if (existing !is beanPostProcessor)
                kept ~= existing;
        postProcessors = kept ~ beanPostProcessor;
    }

    /// How many post-processors exist.
    int getBeanPostProcessorCount()
    {
        return cast(int) postProcessors.length;
    }

    /// The post-processors, in order.
    final BeanPostProcessor[] getBeanPostProcessors() pure nothrow
    {
        return postProcessors.dup;
    }

    /// Whether `beanName` is being created.
    bool isCurrentlyInCreation(string beanName)
    {
        return (canonicalName(beanName) in inCreation) !is null;
    }

    /// Record that `dependentBeanName` depends on `beanName`.
    void registerDependentBean(string beanName, string dependentBeanName)
    {
        const canonical = canonicalName(beanName);
        addUnique(dependents, canonical, dependentBeanName);
        addUnique(dependencies, dependentBeanName, canonical);
    }

    private static void addUnique(ref string[][string] map, string key, string value)
    {
        auto values = key in map;
        if (values is null)
        {
            map[key] = [value];
            return;
        }
        foreach (existing; *values)
            if (existing == value)
                return;
        *values ~= value;
    }

    /// The beans depending on `beanName`.
    string[] getDependentBeans(string beanName)
    {
        return dependents.get(beanName, null).dup;
    }

    /// The beans `beanName` depends on.
    string[] getDependenciesForBean(string beanName)
    {
        return dependencies.get(beanName, null).dup;
    }

    // -----------------------------------------------------------------------------------------------------------
    // BeanFactory

    /// The erased primitive behind `getBean`.
    Object getBeanErased(string name, string requiredType, Any[])
    {
        if (name is null)
            return resolveByType(requiredType, null, true);
        auto bean = doGetBean(name);
        if (requiredType !is null && !isInstance(name, bean, requiredType))
            throw new BeanNotOfRequiredTypeException(name, requiredType, canonicalTypeName(typeid(bean).name));
        return bean;
    }

    private bool isInstance(string name, Object bean, string requiredType)
    {
        if (isTypeMatchErased(name, requiredType))
            return true;
        return canonicalTypeName(typeid(bean).name) == requiredType;
    }

    /// Whether a definition or singleton named `name` exists (here or in the parent).
    bool containsBean(string name)
    {
        const beanName = canonicalName(name);
        if (containsSingleton(beanName) || containsBeanDefinition(beanName))
            return true;
        return parent !is null && parent.containsBean(name);
    }

    /// Whether `name` is a singleton.
    bool isSingleton(string name)
    {
        const beanName = canonicalName(name);
        if (containsSingleton(beanName) && !containsBeanDefinition(beanName))
            return true;
        return getBeanDefinition(beanName).isSingleton();
    }

    /// Whether `name` is a prototype.
    bool isPrototype(string name)
    {
        return getBeanDefinition(canonicalName(name)).isPrototype();
    }

    /// Whether the bean `name` can be injected as `typeName`.
    bool isTypeMatchErased(string name, string typeName)
    {
        const beanName = canonicalName(name);
        if (auto definition = beanName in definitions)
        {
            foreach (type; definition.getTypes())
                if (type == typeName)
                    return true;
            return definition.getBeanClassName() == typeName;
        }
        if (auto singleton = beanName in singletons)
            return canonicalTypeName(typeid(*singleton).name) == typeName;
        if (parent !is null)
            return parent.isTypeMatchErased(name, typeName);
        throw new NoSuchBeanDefinitionException(name);
    }

    /// The bean's type name, or null.
    string getTypeName(string name)
    {
        const beanName = canonicalName(name);
        if (auto definition = beanName in definitions)
            return definition.getBeanClassName();
        if (auto singleton = beanName in singletons)
            return canonicalTypeName(typeid(*singleton).name);
        return parent is null ? null : parent.getTypeName(name);
    }

    /// The aliases of `name` (Spring includes the canonical name when `name` is an alias).
    override string[] getAliases(string name)
    {
        const beanName = canonicalName(name);
        string[] result;
        if (beanName != name)
            result ~= beanName;
        foreach (alias_; super.getAliases(beanName))
            if (alias_ != name)
                result ~= alias_;
        return result;
    }

    // -----------------------------------------------------------------------------------------------------------
    // ListableBeanFactory

    /// The names of beans injectable as `typeName`, in registration order (definitions, then manual singletons).
    string[] getBeanNamesForTypeErased(string typeName, bool includeNonSingletons = true, bool = true)
    {
        string[] result;
        foreach (name; definitionNames)
        {
            auto definition = definitions[name];
            if (definition.isAbstract() || (!includeNonSingletons && !definition.isSingleton()))
                continue;
            if (isTypeMatchErased(name, typeName))
                result ~= name;
        }
        foreach (name; singletonOrder)
            if ((name in definitions) is null && canonicalTypeName(typeid(singletons[name]).name) == typeName)
                result ~= name;
        return result;
    }

    /// The names of beans whose class carries `annotationType`.
    string[] getBeanNamesForAnnotationErased(string annotationType)
    {
        string[] result;
        foreach (name; definitionNames)
            if (findAnnotationOnBean(name, annotationType) !is null)
                result ~= name;
        return result;
    }

    /// The merged annotation `annotationType` on the bean's class, from its registered descriptor annotations.
    const(MergedAnnotation)* findAnnotationOnBean(string beanName, string annotationType)
    {
        auto definition = canonicalName(beanName) in definitions;
        if (definition is null)
            return null;
        auto annotations = definition.getAttribute("flint.annotations");
        if (annotations.isNull)
            return null;
        return findAnnotation(annotations.get!(MergedAnnotation[]), annotationType);
    }

    // -----------------------------------------------------------------------------------------------------------
    // ConfigurableListableBeanFactory

    /// Freeze configuration.
    void freezeConfiguration()
    {
        frozen = true;
    }

    /// Whether frozen.
    bool isConfigurationFrozen()
    {
        return frozen;
    }

    /// Create every non-lazy singleton in definition order, then call `SmartInitializingSingleton` callbacks.
    void preInstantiateSingletons()
    {
        foreach (name; definitionNames.dup)
        {
            auto definition = definitions[name];
            if (!definition.isAbstract() && definition.isSingleton() && !definition.isLazyInit())
                doGetBean(name);
        }
        foreach (name; definitionNames.dup)
            if (auto smart = cast(SmartInitializingSingleton) getSingleton(name))
                smart.afterSingletonsInstantiated();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Creation

    /// The bean `name`, created on demand.
    protected Object doGetBean(string name)
    {
        const beanName = canonicalName(name);
        if (auto singleton = beanName in singletons)
            return *singleton;
        auto definition = beanName in definitions;
        if (definition is null)
        {
            if (parent !is null)
                return parent.getBean(name);
            throw new NoSuchBeanDefinitionException(name);
        }
        if (definition.isAbstract())
            throw new BeanCreationException(beanName, "Bean definition is abstract", null);
        foreach (dependsOn; definition.getDependsOn())
        {
            if (isDependent(beanName, dependsOn))
                throw new BeanCreationException(definition.getResourceDescription(), beanName,
                        "Circular depends-on relationship between '" ~ beanName ~ "' and '" ~ dependsOn ~ "'", null);
            registerDependentBean(dependsOn, beanName);
            doGetBean(dependsOn);
        }
        if (definition.isPrototype())
            return createBean(beanName, *definition);
        if (destroying)
            throw new BeanCreationException(beanName, "Singleton bean creation not allowed while singletons of "
                    ~ "this factory are in destruction (Do not request a bean from a BeanFactory in a destroy "
                    ~ "method implementation!)", null);
        auto bean = createBean(beanName, *definition);
        addSingleton(beanName, bean);
        return bean;
    }

    private bool isDependent(string beanName, string dependentBeanName)
    {
        foreach (dependent; dependents.get(beanName, null))
            if (dependent == dependentBeanName || isDependent(dependent, dependentBeanName))
                return true;
        return false;
    }

    /// Create, initialize and post-process the bean `beanName` from `definition`.
    protected Object createBean(string beanName, RootBeanDefinition definition)
    {
        if (beanName in inCreation)
            throw new BeanCurrentlyInCreationException(beanName);
        inCreation[beanName] = true;
        scope (exit)
            inCreation.remove(beanName);
        try
            return initializeBean(beanName, instantiate(beanName, definition), definition);
        catch (BeansException e)
            throw e;
        catch (Exception e)
            throw new BeanCreationException(definition.getResourceDescription(), beanName,
                    "Initialization of bean failed: " ~ e.msg, e);
    }

    private Object instantiate(string beanName, RootBeanDefinition definition)
    {
        Object bean;
        if (definition.instanceSupplier !is null)
            bean = definition.instanceSupplier();
        else if (definition.getAotDefinition().create !is null)
            bean = definition.getAotDefinition().create(adapter);
        else
            throw new BeanCreationException(definition.getResourceDescription(), beanName,
                    "No instance supplier or generated factory", null);
        if (bean is null)
            throw new BeanCreationException(definition.getResourceDescription(), beanName,
                    "Factory returned null", null);
        return bean;
    }

    private Object initializeBean(string beanName, Object bean, RootBeanDefinition definition)
    {
        if (auto aware = cast(BeanNameAware) bean)
            aware.setBeanName(beanName);
        if (auto aware = cast(BeanFactoryAware) bean)
            aware.setBeanFactory(this);
        Object current = bean;
        foreach (processor; postProcessors)
        {
            if (auto processed = processor.postProcessBeforeInitialization(current, beanName))
                current = processed;
            else
                return current;
        }
        auto record = definition.getAotDefinition();
        if (record.initialize !is null)
            record.initialize(current, adapter);
        else if (auto initializing = cast(InitializingBean) current)
            initializing.afterPropertiesSet();
        foreach (processor; postProcessors)
        {
            if (auto processed = processor.postProcessAfterInitialization(current, beanName))
                current = processed;
            else
                return current;
        }
        if (record.proxy !is null && definition.isSingleton())
            targets[beanName] = current; // destroy callbacks receive the target, not the proxy (AOT contract 5.2)
        if (record.proxy !is null)
            current = record.proxy(current, adapter);
        return current;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Resolution by type

    /// The single bean injectable as `type` (narrowed by `qualifier`); null when absent and not `required`.
    final Object resolveByType(string type, string qualifier, bool required)
    {
        auto candidates = candidateNames(type, qualifier);
        if (candidates.length == 0)
            if (auto dependency = type in resolvableDependencies)
                return *dependency;
        if (candidates.length == 0)
        {
            if (parent !is null)
            {
                auto listable = cast(DefaultListableBeanFactory) parent;
                if (listable !is null)
                    return listable.resolveByType(type, qualifier, required);
                if (required)
                    return parent.getBeanErased(null, type, null);
            }
            if (required)
                throw NoSuchBeanDefinitionException.forType(type, qualifier is null
                        ? null : "expected at least 1 bean which qualifies as autowire candidate. "
                        ~ "Dependency annotations: {@flint.beans.factory.annotation.Qualifier(\"" ~ qualifier ~ "\")}");
            return null;
        }
        if (candidates.length == 1)
            return doGetBean(candidates[0]);
        const chosen = determineAutowireCandidate(candidates, qualifier);
        if (chosen is null)
            throw new NoUniqueBeanDefinitionException(type, candidates);
        return doGetBean(chosen);
    }

    private string[] candidateNames(string type, string qualifier)
    {
        string[] result;
        foreach (name; getBeanNamesForTypeErased(type))
        {
            auto definition = name in definitions;
            if (definition !is null && !definition.isAutowireCandidate())
                continue;
            if (qualifier is null || matchesQualifier(name, qualifier))
                result ~= name;
        }
        return result;
    }

    private bool matchesQualifier(string name, string qualifier)
    {
        if (name == qualifier)
            return true;
        foreach (alias_; super.getAliases(name))
            if (alias_ == qualifier)
                return true;
        if (auto definition = name in definitions)
            foreach (value; definition.getQualifiers())
                if (value == qualifier)
                    return true;
        return false;
    }

    /// Among several candidates: the single primary one, else the single non-fallback one, else the one named
    /// like the qualifier; null when none is unique.
    protected string determineAutowireCandidate(string[] candidates, string qualifier)
    {
        string primary;
        foreach (name; candidates)
        {
            auto definition = name in definitions;
            if (definition is null || !definition.isPrimary())
                continue;
            if (primary !is null)
                throw new NoUniqueBeanDefinitionException(definition.getBeanClassName(), candidates,
                        "more than one 'primary' bean found among candidates: " ~ joinBrackets(candidates));
            primary = name;
        }
        if (primary !is null)
            return primary;
        string[] regular;
        foreach (name; candidates)
        {
            auto definition = name in definitions;
            if (definition is null || !definition.isFallback())
                regular ~= name;
        }
        if (regular.length == 1)
            return regular[0];
        if (qualifier !is null)
            foreach (name; candidates)
                if (name == qualifier)
                    return name;
        return null;
    }

    private static string joinBrackets(string[] names)
    {
        string result = "[";
        foreach (i, name; names)
            result ~= (i ? ", " : "") ~ name;
        return result ~ "]";
    }

    /// Every bean injectable as `type`, ordered by `PriorityOrdered`, then `Ordered`/`@Order`, then registration.
    final Object[] resolveAllByType(string type)
    {
        auto names = candidateNames(type, null);
        Object[] beans;
        int[] orders;
        foreach (name; names)
        {
            auto bean = doGetBean(name);
            beans ~= bean;
            orders ~= orderOf(name, bean);
        }
        size_t[] indices;
        foreach (i; 0 .. beans.length)
            indices ~= i;
        stableSort(indices, (size_t a, size_t b) => compareOrder(beans[a], orders[a], beans[b], orders[b]));
        Object[] sorted;
        foreach (i; indices)
            sorted ~= beans[i];
        return sorted;
    }

    private int orderOf(string name, Object bean)
    {
        if (auto ordered = cast(Ordered) bean)
            return ordered.getOrder();
        auto definition = name in definitions;
        return definition is null ? Ordered.LOWEST_PRECEDENCE : definition.getOrder();
    }

    private static int compareOrder(Object a, int orderA, Object b, int orderB)
    {
        const priorityA = cast(PriorityOrdered) a !is null, priorityB = cast(PriorityOrdered) b !is null;
        if (priorityA != priorityB)
            return priorityA ? -1 : 1;
        return orderA < orderB ? -1 : (orderA > orderB ? 1 : 0);
    }

    /// `expression` with embedded values resolved, converted to `targetType`.
    final Any resolveValue(string expression, string targetType)
    {
        const resolved = resolveEmbeddedValue(expression);
        if (resolved is null || targetType == "string")
            return resolved is null ? Any.init : Any.of(resolved);
        ConversionService service = conversionService;
        if (service is null)
            service = imported!"flint.core.convert.support".DefaultConversionService.getSharedInstance();
        return service.convert(Any.of(resolved), TypeDescriptor.valueOf!string, new TypeDescriptor(targetType));
    }

    /// Bind configuration properties through the `ConfigurationPropertiesBinder` bean.
    final void bindProperties(string prefix, Any target)
    {
        auto binder = requireBinder();
        binder.bind(prefix, target, descriptors is null ? null : descriptors.find(target.typeName));
    }

    /// Constructor-bind configuration properties through the `ConfigurationPropertiesBinder` bean.
    final Any bindPropertiesConstructor(string prefix, string type)
    {
        auto binder = requireBinder();
        return binder.bindConstructor(prefix, descriptors is null ? null : descriptors.find(type));
    }

    private ConfigurationPropertiesBinder requireBinder()
    {
        auto binder = getConfigurationPropertiesBinder();
        if (binder is null)
            throw new IllegalStateException("@ConfigurationProperties needs flint:boot");
        return binder;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Destruction

    /// Destroy the singleton `beanName` and its dependents.
    void destroyBean(string beanName)
    {
        destroySingleton(beanName);
    }

    /// Destroy every singleton, in reverse creation order.
    void destroySingletons()
    {
        destroying = true;
        scope (exit)
            destroying = false;
        foreach_reverse (name; singletonOrder.dup)
            destroySingleton(name);
        dependents = null;
        dependencies = null;
    }

    /// Destroy one singleton: its dependents first, then post-processors, then its own callbacks.
    protected void destroySingleton(string beanName)
    {
        auto found = beanName in singletons;
        if (found is null)
            return;
        auto bean = *found;
        if (auto target = beanName in targets)
            bean = *target;
        singletons.remove(beanName);
        targets.remove(beanName);
        string[] kept;
        foreach (name; singletonOrder)
            if (name != beanName)
                kept ~= name;
        singletonOrder = kept;
        foreach (dependent; dependents.get(beanName, null))
            destroySingleton(dependent);
        foreach (processor; postProcessors)
            if (auto destruction = cast(DestructionAwareBeanPostProcessor) processor)
                if (destruction.requiresDestruction(bean))
                    destruction.postProcessBeforeDestruction(bean, beanName);
        auto definition = beanName in definitions;
        auto destroy = definition is null ? null : definition.getAotDefinition().destroy;
        if (destroy !is null)
            destroy(bean);
        else if (auto disposable = cast(DisposableBean) bean)
            disposable.destroy();
    }
}

/// The contract's `BeanFactory` over a `DefaultListableBeanFactory`, for generated code.
private final class AotAdapter : AotBeanFactory
{
    private DefaultListableBeanFactory factory;

    this(DefaultListableBeanFactory factory) pure nothrow @nogc
    {
        this.factory = factory;
    }

    Object getBean(string name)
    {
        return factory.getBeanErased(name, null, null);
    }

    Object getBeanOfType(string type, string qualifier = null)
    {
        return factory.resolveByType(type, qualifier, true);
    }

    Object findBeanOfType(string type, string qualifier = null)
    {
        return factory.resolveByType(type, qualifier, false);
    }

    Object[] getBeansOfType(string type)
    {
        return factory.resolveAllByType(type);
    }

    Any resolveValue(string expression, string targetType)
    {
        return factory.resolveValue(expression, targetType);
    }

    void bind(string prefix, Any target)
    {
        factory.bindProperties(prefix, target);
    }

    Any bindConstructor(string prefix, string type)
    {
        return factory.bindPropertiesConstructor(prefix, type);
    }
}
