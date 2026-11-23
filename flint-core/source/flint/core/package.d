// Ported from spring-framework v7.1.0: spring-core/src/main/java/org/springframework/core
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
 * spring-core/src/main/java/org/springframework/core/{Ordered,PriorityOrdered,OrderComparator,AliasRegistry,
 * SimpleAliasRegistry,AttributeAccessor,AttributeAccessorSupport,NestedRuntimeException,NestedExceptionUtils,
 * SpringVersion}.java. Object-typed values are flint.engine.aot.any.Any (rulebook "Erased types"); Class-typed
 * parameters are template parameters (R4).
 */

/++
`org.springframework.core`: ordering, aliases, attributes and nested exceptions.
+/
module flint.core;

import flint.engine.aot.any : Any;
import flint.java.lang : IllegalStateException, Integer, RuntimeException;
import flint.java.util : List, Optional, RawCollection, stableSort;
import flint.util : Assert, StringValueResolver;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Ordering

/++
`Ordered` is implemented by objects that should be orderable: lower values have higher priority. Same order values
keep their original relative position (the sort is stable).
+/
interface Ordered
{
    /// The highest precedence value.
    enum int HIGHEST_PRECEDENCE = int.min;
    /// The lowest precedence value.
    enum int LOWEST_PRECEDENCE = int.max;

    /// This object's order value.
    int getOrder();
}

/++
An `Ordered` that sorts before every plain `Ordered` object, whatever the order values: infrastructure that must be
applied first (`BeanFactoryPostProcessor`s, `BeanPostProcessor`s).
+/
interface PriorityOrdered : Ordered
{
}

/++
`OrderComparator` sorts `Ordered` objects by order value, with `PriorityOrdered` objects first; objects without an
order are `LOWEST_PRECEDENCE`. `AnnotationAwareOrderComparator` (in `flint.core.annotation.types`) adds `@Order`.
+/
class OrderComparator
{
    /// The shared default instance.
    static OrderComparator INSTANCE()
    {
        return new OrderComparator;
    }

    /// Strategy interface providing an order source for a given object.
    interface OrderSourceProvider
    {
        /// The order source for `obj` (null if none): an object whose order is used instead of `obj`'s.
        Object getOrderSource(Object obj);
    }

    /// Compare two objects: `PriorityOrdered` first, then by order value.
    int compare(Object o1, Object o2)
    {
        return doCompare(o1, o2, null);
    }

    /// A comparison that first consults `sourceProvider` for each object's order source.
    int delegate(Object, Object) @safe withSourceProvider(OrderSourceProvider sourceProvider)
    {
        return (Object o1, Object o2) => doCompare(o1, o2, sourceProvider);
    }

    private int doCompare(Object o1, Object o2, OrderSourceProvider sourceProvider)
    {
        const p1 = cast(PriorityOrdered) o1 !is null;
        const p2 = cast(PriorityOrdered) o2 !is null;
        if (p1 && !p2)
            return -1;
        if (p2 && !p1)
            return 1;
        return Integer.compare(getOrder(o1, sourceProvider), getOrder(o2, sourceProvider));
    }

    /// The order of `obj`, consulting `sourceProvider` first. An order source that is a collection (Java's array
    /// order source) is searched in order for the first element that declares an order.
    int getOrder(Object obj, OrderSourceProvider sourceProvider)
    {
        Optional!int order;
        if (obj !is null && sourceProvider !is null)
        {
            auto orderSource = sourceProvider.getOrderSource(obj);
            if (auto sources = cast(RawCollection) orderSource)
            {
                foreach (source; sources.toAnyArray())
                {
                    auto element = source.asObject();
                    order = element is null ? Optional!int.empty() : findOrder(element);
                    if (order.isPresent())
                        break;
                }
            }
            else if (orderSource !is null)
                order = findOrder(orderSource);
        }
        return order.isPresent() ? order.get() : getOrder(obj);
    }

    /// The order of `obj`: its `Ordered.getOrder()`, else `LOWEST_PRECEDENCE`.
    protected int getOrder(Object obj)
    {
        if (obj !is null)
        {
            const order = findOrder(obj);
            if (order.isPresent())
                return order.get();
        }
        return Ordered.LOWEST_PRECEDENCE;
    }

    /// The order `obj` declares, or empty when it declares none (Java's nullable `Integer`, R5). Subclasses add
    /// `@Order`.
    protected Optional!int findOrder(Object obj)
    {
        if (auto ordered = cast(Ordered) obj)
            return Optional!int.of(ordered.getOrder());
        return Optional!int.empty();
    }

    /// A priority value for an object; this implementation has none (empty).
    Optional!int getPriority(Object)
    {
        return Optional!int.empty();
    }

    /// Sort `list` with the default comparator (stable).
    static void sort(T)(List!T list)
    {
        if (list.size() > 1)
        {
            auto comparator = INSTANCE();
            auto items = list.toArray();
            stableSort(items, (T a, T b) => comparator.compare(cast(Object) a, cast(Object) b));
            foreach (i, item; items)
                list.set(cast(int) i, item);
        }
    }

    /// Sort `array` with the default comparator (stable).
    static void sort(T)(T[] array)
    {
        if (array.length > 1)
        {
            auto comparator = INSTANCE();
            stableSort(array, (T a, T b) => comparator.compare(cast(Object) a, cast(Object) b));
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Aliases

/// Common interface for managing aliases; a super-interface for `BeanDefinitionRegistry`.
interface AliasRegistry
{
    /// Register `alias` for `name`. Throws `IllegalStateException` if the alias is in use and may not be overridden.
    void registerAlias(string name, string alias_);
    /// Remove `alias`. Throws `IllegalStateException` when no such alias exists.
    void removeAlias(string alias_);
    /// Whether `name` is an alias (as opposed to a registered name).
    bool isAlias(string name);
    /// The aliases for `name`, if defined.
    string[] getAliases(string name);
}

/// Simple implementation of `AliasRegistry`, used by `BeanDefinitionRegistry` implementations.
class SimpleAliasRegistry : AliasRegistry
{
    private string[string] aliasMap;
    private string[] aliasNames;

    /// Register `alias` for `name`.
    void registerAlias(string name, string alias_)
    {
        Assert.hasText(name, "'name' must not be empty");
        Assert.hasText(alias_, "'alias' must not be empty");
        if (alias_ == name)
        {
            aliasMap.remove(alias_);
            removeName(alias_);
            return;
        }
        if (auto registeredName = alias_ in aliasMap)
        {
            if (*registeredName == name)
                return; // an existing alias: no need to re-register
            if (!allowAliasOverriding())
                throw new IllegalStateException("Cannot define alias '" ~ alias_ ~ "' for name '"
                        ~ name ~ "': It is already registered for name '" ~ *registeredName ~ "'.");
        }
        checkForAliasCircle(name, alias_);
        aliasMap[alias_] = name;
        aliasNames ~= alias_;
    }

    /// Whether alias overriding is allowed. Default is `true`.
    protected bool allowAliasOverriding()
    {
        return true;
    }

    /// Whether `name` has `alias` registered, directly or indirectly.
    bool hasAlias(string name, string alias_)
    {
        auto registeredName = alias_ in aliasMap;
        if (registeredName is null)
            return false;
        return *registeredName == name || hasAlias(name, *registeredName);
    }

    /// Remove `alias`.
    void removeAlias(string alias_)
    {
        const existed = (alias_ in aliasMap) !is null;
        aliasMap.remove(alias_);
        removeName(alias_);
        if (!existed)
            throw new IllegalStateException("No alias '" ~ alias_ ~ "' registered");
    }

    /// Whether `name` is an alias.
    bool isAlias(string name)
    {
        return (name in aliasMap) !is null;
    }

    /// The aliases of `name`, transitively, in registration order.
    string[] getAliases(string name)
    {
        string[] result;
        retrieveAliases(name, result);
        return result;
    }

    private void retrieveAliases(string name, ref string[] result)
    {
        // aliasNames may hold an alias twice, as Spring's list does after an override; the map is the truth.
        foreach (i, alias_; aliasNames)
        {
            auto registeredName = alias_ in aliasMap;
            if (registeredName is null || *registeredName != name || indexOfName(alias_) != i)
                continue;
            result ~= alias_;
            retrieveAliases(alias_, result);
        }
    }

    private size_t indexOfName(string alias_) const pure nothrow @nogc
    {
        foreach (i, existing; aliasNames)
            if (existing == alias_)
                return i;
        return size_t.max;
    }

    /// Resolve every alias target name and alias registered in this registry with `valueResolver`.
    void resolveAliases(StringValueResolver valueResolver)
    {
        Assert.notNull(valueResolver, "StringValueResolver must not be null");
        foreach (alias_; aliasNames.dup)
        {
            auto registered = alias_ in aliasMap;
            if (registered is null)
                continue;
            resolveAlias(alias_, *registered, valueResolver);
        }
    }

    private void resolveAlias(string alias_, string registeredName, StringValueResolver valueResolver)
    {
        const resolvedAlias = valueResolver.resolveStringValue(alias_);
        const resolvedName = valueResolver.resolveStringValue(registeredName);
        if (resolvedAlias is null || resolvedName is null || resolvedAlias == resolvedName)
        {
            aliasMap.remove(alias_);
            removeName(alias_);
        }
        else if (resolvedAlias != alias_)
        {
            if (auto existingName = resolvedAlias in aliasMap)
            {
                if (*existingName == resolvedName)
                {
                    aliasMap.remove(alias_); // pointing to an existing alias: just remove the placeholder
                    removeName(alias_);
                    return;
                }
                throw new IllegalStateException(
                        "Cannot register resolved alias '" ~ resolvedAlias ~ "' (original: '" ~ alias_
                        ~ "') for name '" ~ resolvedName ~ "': It is already registered for name '"
                        ~ *existingName ~ "'.");
            }
            checkForAliasCircle(resolvedName, resolvedAlias);
            aliasMap.remove(alias_);
            removeName(alias_);
            aliasMap[resolvedAlias] = resolvedName;
            aliasNames ~= resolvedAlias;
        }
        else if (registeredName != resolvedName)
        {
            checkForAliasCircle(resolvedName, alias_);
            aliasMap[alias_] = resolvedName;
            aliasNames ~= alias_;
        }
    }

    /// Throw `IllegalStateException` when `alias` for `name` would form a circle.
    protected void checkForAliasCircle(string name, string alias_)
    {
        if (hasAlias(alias_, name))
            throw new IllegalStateException("Cannot register alias '" ~ alias_ ~ "' for name '" ~ name
                    ~ "': Circular reference - '" ~ name ~ "' is a direct or indirect alias for '" ~ alias_
                    ~ "' already");
    }

    /// The raw name `name` resolves to through aliases.
    string canonicalName(string name)
    {
        string canonical = name;
        for (auto resolved = canonical in aliasMap; resolved !is null; resolved = canonical in aliasMap)
            canonical = *resolved;
        return canonical;
    }

    private void removeName(string alias_)
    {
        foreach (i, existing; aliasNames)
        {
            if (existing == alias_)
            {
                aliasNames = aliasNames[0 .. i] ~ aliasNames[i + 1 .. $];
                return;
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Attributes

/// Interface for attaching and accessing metadata to and from arbitrary objects.
interface AttributeAccessor
{
    /// Set the attribute `name` to `value`; an `Any.init` value removes it.
    void setAttribute(string name, Any value);
    /// The attribute `name`, or `Any.init`.
    Any getAttribute(string name);
    /// Remove the attribute `name`; its value, or `Any.init`.
    Any removeAttribute(string name);
    /// Whether the attribute `name` exists.
    bool hasAttribute(string name);
    /// The attribute names, in insertion order.
    string[] attributeNames();
}

/// `AttributeAccessor` backed by an insertion-ordered map.
class AttributeAccessorSupport : AttributeAccessor
{
    private Any[string] attributes;
    private string[] names;

    /// Set the attribute `name`; `Any.init` removes it.
    void setAttribute(string name, Any value)
    {
        Assert.notNull(name, "Name must not be null");
        if (value.isNull)
        {
            removeAttribute(name);
            return;
        }
        if ((name in attributes) is null)
            names ~= name;
        attributes[name] = value;
    }

    /// The attribute `name`, or `Any.init`.
    Any getAttribute(string name)
    {
        Assert.notNull(name, "Name must not be null");
        auto found = name in attributes;
        return found is null ? Any.init : *found;
    }

    /// The attribute `name`, computing it with `computeFunction` when absent.
    Any computeAttribute(string name, Any delegate(string) @safe computeFunction)
    {
        Assert.notNull(name, "Name must not be null");
        if (auto found = name in attributes)
            return *found;
        auto value = computeFunction(name);
        Assert.state(!value.isNull, "Compute function must not return null for attribute named '" ~ name ~ "'");
        setAttribute(name, value);
        return value;
    }

    /// Remove the attribute `name`.
    Any removeAttribute(string name)
    {
        Assert.notNull(name, "Name must not be null");
        auto found = name in attributes;
        if (found is null)
            return Any.init;
        auto value = *found;
        attributes.remove(name);
        foreach (i, existing; names)
            if (existing == name)
            {
                names = names[0 .. i] ~ names[i + 1 .. $];
                break;
            }
        return value;
    }

    /// Whether the attribute `name` exists.
    bool hasAttribute(string name)
    {
        Assert.notNull(name, "Name must not be null");
        return (name in attributes) !is null;
    }

    /// The attribute names, in insertion order.
    string[] attributeNames()
    {
        return names.dup;
    }

    /// Copy the attributes of `source` into this accessor.
    protected void copyAttributesFrom(AttributeAccessor source)
    {
        Assert.notNull(source, "Source must not be null");
        foreach (name; source.attributeNames())
            setAttribute(name, source.getAttribute(name));
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Nested exceptions

/++
A handy base class for runtime exceptions with a root cause. The `getMessage` of Spring 5 and earlier appended the
cause; since Spring 6 it is the exception's own message only, and this port follows that.
+/
abstract class NestedRuntimeException : RuntimeException
{
    /// `msg`, and optionally a `cause`.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }

    /// The innermost cause, or null when there is no cause.
    Throwable getRootCause() pure nothrow @nogc
    {
        return NestedExceptionUtils.getRootCause(this);
    }

    /// The root cause, or this exception when it has none.
    Throwable getMostSpecificCause() pure nothrow @nogc
    {
        auto rootCause = getRootCause();
        return rootCause !is null ? rootCause : this;
    }

    /// Whether this exception or a cause is an `E` (Java's `contains(Class)`, R4).
    bool contains(E : Throwable)() pure nothrow @nogc
    {
        return contains(typeid(E));
    }

    /// Whether this exception or a cause is an instance of `exType`; false for null.
    bool contains(const TypeInfo_Class exType) pure nothrow @nogc
    {
        if (exType is null)
            return false;
        for (Throwable cause = this; cause !is null; cause = causeOf(cause))
        {
            if (typeid(cause) is exType || exType.isBaseOf(typeid(cause)))
                return true;
            if (causeOf(cause) is cause)
                break;
        }
        return false;
    }
}

/// Helper for implementing exception classes that are capable of holding nested exceptions.
struct NestedExceptionUtils
{
    /// The innermost cause of `original`, or null when it has none.
    static Throwable getRootCause(Throwable original) pure nothrow @nogc
    {
        if (original is null)
            return null;
        Throwable rootCause;
        for (Throwable cause = causeOf(original); cause !is null && cause !is rootCause; cause = causeOf(cause))
            rootCause = cause;
        return rootCause;
    }

    /// The root cause of `original`, or `original` itself when it has none.
    static Throwable getMostSpecificCause(Throwable original) pure nothrow @nogc
    {
        auto rootCause = getRootCause(original);
        return rootCause !is null ? rootCause : original;
    }
}

/// Java's `Throwable.getCause()` for any throwable: the Java cause of Flint exceptions, D's `next` otherwise.
Throwable causeOf(Throwable t) pure nothrow @nogc
{
    import flint.java.io : IOException;

    if (auto runtime = cast(RuntimeException) t)
        return runtime.getCause();
    if (auto io = cast(IOException) t)
        return io.getCause();
    return t is null ? null : t.next;
}

/++
A method parameter as Flint AOT describes it (Spring's `MethodParameter`): a handler parameter's `ArgumentSpec`
(contract section 4.5) with its index, name, declared type name and merged annotations, instead of reflection.
`Class`-typed accessors return canonical type names (R4).
+/
final class MethodParameter
{
    import flint.engine.aot.descriptor : MergedAnnotation, MethodDescriptor, findAnnotation;
    import flint.engine.aot.mapping : ArgumentSpec;

    private ArgumentSpec argument;
    private int index;
    private string owner;
    private const(MethodDescriptor)* executable;

    /// Parameter `index` (-1 for a return type) described by `argument`, of the method `owner` names.
    this(ArgumentSpec argument, int index, string owner = null, const(MethodDescriptor)* executable = null) pure nothrow
    {
        this.argument = argument;
        this.index = index;
        this.owner = owner;
        this.executable = executable;
    }

    /// The parameter's position; -1 for a return type.
    int getParameterIndex() const pure nothrow @nogc
    {
        return index;
    }

    /// The parameter name.
    string getParameterName() const pure nothrow @nogc
    {
        return argument.name;
    }

    /// The canonical declared type (Java's `getParameterType()`, a `Class`; R4).
    string getParameterType() const pure nothrow @nogc
    {
        return argument.type;
    }

    /// The type after unwrapping `Optional!T` (Java's `getNestedParameterType()`).
    string getNestedParameterType() const pure nothrow
    {
        if (argument.elementType.length && isOptionalType(argument.type))
            return argument.elementType;
        enum prefix = "flint.java.util.Optional!";
        const type = argument.type;
        if (!isOptionalType(type))
            return type;
        auto rest = type[prefix.length .. $];
        return rest.length > 1 && rest[0] == '(' && rest[$ - 1] == ')' ? rest[1 .. $ - 1] : rest;
    }

    private static bool isOptionalType(string type) pure nothrow @nogc
    {
        enum prefix = "flint.java.util.Optional!";
        return type.length > prefix.length && type[0 .. prefix.length] == prefix;
    }

    /// Whether the parameter is `Optional!T`.
    bool isOptional() const pure nothrow @nogc
    {
        return isOptionalType(argument.type);
    }

    /// The parameter's merged annotations.
    const(MergedAnnotation)[] getParameterAnnotations() const pure nothrow @nogc
    {
        return argument.annotations;
    }

    /// The merged annotation named `type`, or null.
    const(MergedAnnotation)* getParameterAnnotation(string type) const nothrow @nogc
    {
        return findAnnotation(argument.annotations, type);
    }

    /// The annotation `A`, or `A.init` with `found` false.
    const(A) getParameterAnnotation(A)(out bool found) const
    {
        import flint.engine.aot.name : typeNameOf;

        auto merged = getParameterAnnotation(typeNameOf!A);
        found = merged !is null;
        return found ? merged.value.get!(const A) : A.init;
    }

    /// Whether the annotation `A` is present.
    bool hasParameterAnnotation(A)() const
    {
        import flint.engine.aot.name : typeNameOf;

        return getParameterAnnotation(typeNameOf!A) !is null;
    }

    /// The AOT argument record.
    ref const(ArgumentSpec) getArgumentSpec() const return pure nothrow @nogc
    {
        return argument;
    }

    /// The declaring method's description (`OwnerController.getOwner`), for messages.
    string getExecutable() const pure nothrow @nogc
    {
        return owner;
    }

    /// The declaring method's descriptor, when known.
    const(MethodDescriptor)* getMethod() const pure nothrow @nogc
    {
        return executable;
    }

    /// `method 'owner' parameter index`, as Spring prints it.
    override string toString() const
    {
        import flint.java.lang : valueOf;

        return "method '" ~ owner ~ "' parameter " ~ valueOf(index);
    }
}

/// The version of the Spring Framework API this module ports (Spring's `SpringVersion`).
struct FlintVersion
{
    /// `7.1.0`: the Spring Framework release whose API flint-framework implements.
    static string getVersion() pure nothrow @nogc
    {
        return "7.1.0";
    }
}
