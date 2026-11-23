// Ported from spring-framework v7.1.0: spring-beans/src/main/java/org/springframework/beans/factory
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
 * spring-beans/src/main/java/org/springframework/beans/factory/{BeanFactory,ListableBeanFactory,
 * HierarchicalBeanFactory,ObjectFactory,ObjectProvider,Aware,BeanNameAware,BeanFactoryAware,InitializingBean,
 * DisposableBean,SmartInitializingSingleton,NoSuchBeanDefinitionException,NoUniqueBeanDefinitionException,
 * BeanCreationException,BeanCurrentlyInCreationException,BeanNotOfRequiredTypeException,
 * UnsatisfiedDependencyException,BeanDefinitionStoreException}.java. Class-typed lookups are template façades (R4)
 * over erased primitives (deviation D-22); bean types are canonical D names.
 */

/++
`org.springframework.beans.factory`: the bean container API.

`getBean!T()`, `getBean!T(name)`, `getBeansOfType!T()` and `getBeanProvider!T()` are Java's `Class`-typed
lookups (R4); they are `final` façades over the erased `getBeanErased`, `getBeanNamesForTypeErased` and
`getBeansOfTypeErased`, which implementations provide (deviation D-22).
+/
module flint.beans.factory;

import flint.beans : BeansException, FatalBeanException;
import flint.core.annotation.types : AnnotationAwareOrderComparator;
import flint.engine.aot.any : Any;
import flint.engine.aot.name : typeNameOf;
import flint.java.util : LinkedHashMap, Map;
import flint.java.util.stream : Stream;

@safe:

/++
The root interface for accessing a bean container.
+/
interface BeanFactory
{
    /// The prefix that dereferences a `FactoryBean` (`&myBean`). FactoryBeans are not supported in Phase 1.
    enum FACTORY_BEAN_PREFIX = "&";

    /++
    The erased primitive behind every `getBean`: the bean named `name` (or, with a null `name`, the single bean
    of `requiredType`), checked against `requiredType` when it is given. Throws `NoSuchBeanDefinitionException`,
    `NoUniqueBeanDefinitionException`, `BeanNotOfRequiredTypeException` or `BeansException`.
    +/
    Object getBeanErased(string name, string requiredType, Any[] args);

    /// Whether a bean (definition or singleton) named `name` exists.
    bool containsBean(string name);
    /// Whether `name` is a singleton.
    bool isSingleton(string name);
    /// Whether `name` is a prototype.
    bool isPrototype(string name);
    /// Whether the bean `name` can be injected as the type `typeName`.
    bool isTypeMatchErased(string name, string typeName);
    /// The canonical type name of the bean `name`, or null (Java's `getType`, a `Class`, R4).
    string getTypeName(string name);
    /// The aliases of `name`.
    string[] getAliases(string name);

    /// The bean named `name`.
    final Object getBean(string name)
    {
        return getBeanErased(name, null, null);
    }

    /// The bean named `name`, created with explicit constructor arguments when it is a prototype.
    final Object getBean(string name, Any[] args...)
    {
        return getBeanErased(name, null, args.dup);
    }

    /// The bean named `name` as a `T`. Throws `BeanNotOfRequiredTypeException` when it is not one.
    T getBean(T)(string name)
    {
        return cast(T) getBeanErased(name, typeNameOf!T, null);
    }

    /// The single bean of type `T`.
    T getBean(T)()
    {
        return cast(T) getBeanErased(null, typeNameOf!T, null);
    }

    /// A provider for beans of type `T`, resolved on use.
    ObjectProvider!T getBeanProvider(T)()
    {
        return new BeanObjectProvider!T(this);
    }

    /// Whether the bean `name` can be injected as a `T`.
    bool isTypeMatch(T)(string name)
    {
        return isTypeMatchErased(name, typeNameOf!T);
    }
}

/// A `BeanFactory` that can enumerate all its bean instances.
interface ListableBeanFactory : BeanFactory
{
    /// Whether a definition named `beanName` exists.
    bool containsBeanDefinition(string beanName);
    /// How many definitions exist.
    int getBeanDefinitionCount();
    /// Every definition name, in registration order.
    string[] getBeanDefinitionNames();
    /// The names of beans injectable as `typeName`, in registration order.
    string[] getBeanNamesForTypeErased(string typeName, bool includeNonSingletons = true, bool allowEagerInit = true);
    /// The names of beans whose class carries the annotation `annotationType` (merged).
    string[] getBeanNamesForAnnotationErased(string annotationType);

    /// The names of beans injectable as `T`.
    string[] getBeanNamesForType(T)(bool includeNonSingletons = true, bool allowEagerInit = true)
    {
        return getBeanNamesForTypeErased(typeNameOf!T, includeNonSingletons, allowEagerInit);
    }

    /// The beans injectable as `T`, by name, in registration order.
    Map!(string, T) getBeansOfType(T)(bool includeNonSingletons = true, bool allowEagerInit = true)
    {
        Map!(string, T) result = new LinkedHashMap!(string, T)();
        foreach (name; getBeanNamesForTypeErased(typeNameOf!T, includeNonSingletons, allowEagerInit))
            result.put(name, cast(T) getBeanErased(name, typeNameOf!T, null));
        return result;
    }

    /// The names of beans annotated with `A`.
    string[] getBeanNamesForAnnotation(A)()
    {
        return getBeanNamesForAnnotationErased(typeNameOf!A);
    }

    /// The beans annotated with `A`, by name.
    Map!(string, Object) getBeansWithAnnotation(A)()
    {
        Map!(string, Object) result = new LinkedHashMap!(string, Object)();
        foreach (name; getBeanNamesForAnnotationErased(typeNameOf!A))
            result.put(name, getBeanErased(name, null, null));
        return result;
    }
}

/// A `BeanFactory` that is part of a hierarchy.
interface HierarchicalBeanFactory : BeanFactory
{
    /// The parent factory, or null.
    BeanFactory getParentBeanFactory();
    /// Whether this factory itself (not its ancestors) contains a bean named `name`.
    bool containsLocalBean(string name);
}

/// Defines a factory that returns an object instance on demand.
interface ObjectFactory(T)
{
    /// An instance of the object.
    T getObject();
}

/// A variant of `ObjectFactory` for injection points: optional, unique and streamed access.
interface ObjectProvider(T) : ObjectFactory!T
{
    /// The instance if available (exactly one candidate, or a primary one), else null.
    T getIfAvailable();
    /// The instance if unique (or primary), else null.
    T getIfUnique();
    /// Every matching instance, in registration order.
    Stream!T stream();
    /// Every matching instance, in `@Order`/`Ordered` order.
    Stream!T orderedStream();

    /// The instance if available, else `defaultSupplier()`.
    final T getIfAvailable(T delegate() @safe defaultSupplier)
    {
        auto dependency = getIfAvailable();
        return dependency !is null ? dependency : defaultSupplier();
    }

    /// Call `dependencyConsumer` with the instance if available.
    final void ifAvailable(void delegate(T) @safe dependencyConsumer)
    {
        auto dependency = getIfAvailable();
        if (dependency !is null)
            dependencyConsumer(dependency);
    }

    /// The instance if unique, else `defaultSupplier()`.
    final T getIfUnique(T delegate() @safe defaultSupplier)
    {
        auto dependency = getIfUnique();
        return dependency !is null ? dependency : defaultSupplier();
    }

    /// Call `dependencyConsumer` with the instance if unique.
    final void ifUnique(void delegate(T) @safe dependencyConsumer)
    {
        auto dependency = getIfUnique();
        if (dependency !is null)
            dependencyConsumer(dependency);
    }
}

/// The `ObjectProvider` a `BeanFactory` hands out.
private final class BeanObjectProvider(T) : ObjectProvider!T
{
    private BeanFactory factory;

    this(BeanFactory factory) pure nothrow @nogc
    {
        this.factory = factory;
    }

    T getObject()
    {
        return cast(T) factory.getBeanErased(null, typeNameOf!T, null);
    }

    T getIfAvailable()
    {
        try
            return getObject();
        catch (NoUniqueBeanDefinitionException e)
            throw e;
        catch (NoSuchBeanDefinitionException)
            return null;
    }

    T getIfUnique()
    {
        try
            return getObject();
        catch (NoSuchBeanDefinitionException)
            return null;
    }

    Stream!T stream()
    {
        return Stream!T.ofArray(instances());
    }

    Stream!T orderedStream()
    {
        auto items = instances();
        auto comparator = AnnotationAwareOrderComparator.INSTANCE();
        imported!"flint.java.util".stableSort(items, (T a, T b) => comparator.compare(cast(Object) a, cast(Object) b));
        return Stream!T.ofArray(items);
    }

    private T[] instances()
    {
        auto listable = cast(ListableBeanFactory) factory;
        if (listable is null)
            return [getObject()];
        T[] result;
        foreach (name; listable.getBeanNamesForTypeErased(typeNameOf!T))
            result ~= cast(T) listable.getBeanErased(name, typeNameOf!T, null);
        return result;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Callbacks

/// Marker superinterface for beans the container notifies through callback methods.
interface Aware
{
}

/// A bean that wants to know its bean name.
interface BeanNameAware : Aware
{
    /// Called after property population, before initialization callbacks.
    void setBeanName(string name);
}

/// A bean that wants to know its owning `BeanFactory`.
interface BeanFactoryAware : Aware
{
    /// Called after property population, before initialization callbacks.
    void setBeanFactory(BeanFactory beanFactory);
}

/// A bean that reacts once all its properties are set.
interface InitializingBean
{
    /// Called after the container set every property and applied the `Aware` callbacks.
    void afterPropertiesSet();
}

/// A bean that releases resources on destruction.
interface DisposableBean
{
    /// Called when the container destroys the bean.
    void destroy();
}

/// Callback triggered at the end of the singleton pre-instantiation phase.
interface SmartInitializingSingleton
{
    /// Called once every non-lazy singleton has been created.
    void afterSingletonsInstantiated();
}

// ---------------------------------------------------------------------------------------------------------------
// Exceptions

/// Thrown when a `BeanFactory` is asked for a bean it cannot find.
class NoSuchBeanDefinitionException : BeansException
{
    private string beanName;
    private string beanType;

    /// `No bean named 'name' available`.
    this(string name)
    {
        super("No bean named '" ~ name ~ "' available");
        beanName = name;
    }

    /// `No bean named 'name' available: message`.
    this(string name, string message)
    {
        super("No bean named '" ~ name ~ "' available: " ~ message);
        beanName = name;
    }

    /// `No qualifying bean of type 'type' available` (with `: message` when one is given).
    static NoSuchBeanDefinitionException forType(string type, string message = null)
    {
        auto e = new NoSuchBeanDefinitionException(ForType.init,
                "No qualifying bean of type '" ~ type ~ "' available" ~ (message is null ? "" : ": " ~ message));
        e.beanType = type;
        return e;
    }

    private struct ForType
    {
    }

    /// A message built by a subclass or factory.
    protected this(ForType, string message)
    {
        super(message);
    }

    /// The requested bean name, or null for a lookup by type.
    string getBeanName() const pure nothrow @nogc
    {
        return beanName;
    }

    /// The requested type's canonical name, or null for a lookup by name.
    string getBeanType() const pure nothrow @nogc
    {
        return beanType;
    }

    /// How many beans were found: 0 here.
    int getNumberOfBeansFound() const pure nothrow @nogc
    {
        return 0;
    }
}

/// Thrown when a single bean of a type is required but several candidates match.
class NoUniqueBeanDefinitionException : NoSuchBeanDefinitionException
{
    private string[] beanNamesFound;

    /// `No qualifying bean of type 't' available: expected single matching bean but found 2: a,b`.
    this(string type, string[] beanNamesFound)
    {
        string names;
        foreach (i, name; beanNamesFound)
            names ~= (i ? "," : "") ~ name;
        super(ForType.init,
                "No qualifying bean of type '" ~ type ~ "' available: expected single matching bean but found "
                ~ imported!"flint.java.lang".valueOf(cast(int) beanNamesFound.length) ~ ": " ~ names);
        this.beanNamesFound = beanNamesFound;
    }

    /// `No qualifying bean of type 't' available: message`, for the names found.
    this(string type, string[] beanNamesFound, string message)
    {
        super(ForType.init, "No qualifying bean of type '" ~ type ~ "' available: " ~ message);
        this.beanNamesFound = beanNamesFound;
    }

    /// How many beans were found.
    override int getNumberOfBeansFound() const pure nothrow @nogc
    {
        return cast(int) beanNamesFound.length;
    }

    /// The names of the beans found.
    string[] getBeanNamesFound() const
    {
        return beanNamesFound.dup;
    }
}

/// Thrown when a `BeanFactory` encounters an error creating a bean.
class BeanCreationException : FatalBeanException
{
    private string beanName;
    private string resourceDescription;

    /// `msg`, and optionally a `cause`, for no particular bean.
    this(string msg, Throwable cause = null)
    {
        super(msg, cause);
    }

    /// `Error creating bean with name 'beanName': msg`.
    this(string beanName, string msg, Throwable cause)
    {
        super("Error creating bean with name '" ~ beanName ~ "': " ~ msg, cause);
        this.beanName = beanName;
    }

    /// `Error creating bean with name 'beanName' defined in resourceDescription: msg`.
    this(string resourceDescription, string beanName, string msg, Throwable cause)
    {
        super("Error creating bean with name '" ~ beanName ~ "'" ~ (resourceDescription is null
                ? "" : " defined in " ~ resourceDescription) ~ ": " ~ msg, cause);
        this.beanName = beanName;
        this.resourceDescription = resourceDescription;
    }

    /// The bean's name, or null.
    string getBeanName() const pure nothrow @nogc
    {
        return beanName;
    }

    /// Where the bean was defined, or null.
    string getResourceDescription() const pure nothrow @nogc
    {
        return resourceDescription;
    }
}

/// Thrown when a bean is requested while it is being created: a circular reference.
class BeanCurrentlyInCreationException : BeanCreationException
{
    /// The standard circular-reference message for `beanName`.
    this(string beanName)
    {
        super(beanName, "Requested bean is currently in creation: "
                ~ "Is there an unresolvable circular reference or an asynchronous initialization dependency?", null);
    }
}

/// Thrown when a bean does not match the required type.
class BeanNotOfRequiredTypeException : BeansException
{
    private string beanName, requiredType, actualType;

    /// `Bean named 'n' is expected to be of type 'r' but was actually of type 'a'`.
    this(string beanName, string requiredType, string actualType)
    {
        super("Bean named '" ~ beanName ~ "' is expected to be of type '" ~ requiredType
                ~ "' but was actually of type '" ~ actualType ~ "'");
        this.beanName = beanName;
        this.requiredType = requiredType;
        this.actualType = actualType;
    }

    /// The bean name.
    string getBeanName() const pure nothrow @nogc
    {
        return beanName;
    }

    /// The required type's canonical name.
    string getRequiredType() const pure nothrow @nogc
    {
        return requiredType;
    }

    /// The actual type's canonical name.
    string getActualType() const pure nothrow @nogc
    {
        return actualType;
    }
}

/// Thrown when a bean depends on other beans or properties that cannot be satisfied.
class UnsatisfiedDependencyException : BeanCreationException
{
    /// `Error creating bean with name 'b': Unsatisfied dependency expressed through bean property 'p': msg`.
    this(string resourceDescription, string beanName, string propertyName, string msg, Throwable cause = null)
    {
        super(resourceDescription, beanName,
                "Unsatisfied dependency expressed through bean property '" ~ propertyName ~ "'" ~ (msg.length
                    ? ": " ~ msg : ""), cause);
    }
}

/// Thrown when a `BeanFactory` encounters an invalid bean definition.
class BeanDefinitionStoreException : FatalBeanException
{
    private string beanName;

    /// `msg`, and optionally a `cause`.
    this(string msg, Throwable cause = null)
    {
        super(msg, cause);
    }

    /// `Invalid bean definition with name 'beanName' defined in resource: msg`.
    this(string resourceDescription, string beanName, string msg, Throwable cause = null)
    {
        super("Invalid bean definition with name '" ~ beanName ~ "' defined in " ~ resourceDescription ~ ": " ~ msg,
                cause);
        this.beanName = beanName;
    }

    /// The bean name, or null.
    string getBeanName() const pure nothrow @nogc
    {
        return beanName;
    }
}
