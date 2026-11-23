// Ported from spring-framework v7.1.0: spring-core/src/main/java/org/springframework/core/annotation/types
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
 * spring-core/src/main/java/org/springframework/core/annotation/{MergedAnnotations,MergedAnnotation,
 * AnnotationAwareOrderComparator,OrderUtils,AnnotationUtils,AnnotationConfigurationException}.java.
 * Annotations are merged at build time by Flint AOT (AOT contract section 2.1); these types read the merged
 * tables in flint.engine.aot descriptors instead of reflecting.
 */

/++
The runtime types of `org.springframework.core.annotation` (deviation D-21: they live beside the leaf annotation
module, so annotation imports stay cheap).

`MergedAnnotations` is backed by the merged annotation tables of Flint AOT descriptors: every annotation present on
an element, directly or as a meta-annotation, with `@AliasFor` already applied. `MergedAnnotation!A` is a typed view
of one entry; `synthesize()` returns the merged UDA struct.
+/
module flint.core.annotation.types;

import flint.core : OrderComparator, Ordered;
import flint.core.annotation : Order;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, DescriptorTable,
    EngineMergedAnnotation = MergedAnnotation, findAnnotation;
import flint.engine.aot.name : canonicalTypeName, typeNameOf;
import flint.java.util : NoSuchElementException, Optional;

@safe:

/// Thrown by the annotation support when an annotation is configured incorrectly (`@AliasFor` misuse).
class AnnotationConfigurationException : imported!"flint.core".NestedRuntimeException
{
    /// `message`, and optionally a `cause`.
    this(string message, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}

/// A single merged annotation of type `A`, or the "missing" annotation.
struct MergedAnnotation(A)
{
    private bool present_;
    private ubyte distance_;
    private ubyte aggregateIndex_;
    private const(A) value_;

    private this(ubyte distance, ubyte aggregateIndex, const A value) pure nothrow @nogc
    {
        present_ = true;
        distance_ = distance;
        aggregateIndex_ = aggregateIndex;
        value_ = value;
    }

    /// The value meaning the annotation is not present. Not `@nogc`: an annotation's array attribute may have a
    /// non-empty default (`string[] value = [""]`).
    static MergedAnnotation missing() pure nothrow
    {
        return MergedAnnotation.init;
    }

    /// The annotation's canonical type name.
    string getType() const pure nothrow @nogc
    {
        return typeNameOf!A;
    }

    /// Whether the annotation is present on the source element.
    bool isPresent() const pure nothrow @nogc
    {
        return present_;
    }

    /// Whether the annotation is declared directly on the source element.
    bool isDirectlyPresent() const pure nothrow @nogc
    {
        return present_ && distance_ == 0 && aggregateIndex_ == 0;
    }

    /// Whether the annotation is present as a meta-annotation.
    bool isMetaPresent() const pure nothrow @nogc
    {
        return present_ && distance_ > 0;
    }

    /// The distance from the source element: 0 when directly present, -1 when missing.
    int getDistance() const pure nothrow @nogc
    {
        return present_ ? distance_ : -1;
    }

    /// The index of the aggregate (0 for the element itself, n for its nth supertype) it was found in; -1 when
    /// missing.
    int getAggregateIndex() const pure nothrow @nogc
    {
        return present_ ? aggregateIndex_ : -1;
    }

    /// The merged annotation struct (annotations are immutable, so the view is `const`). Throws
    /// `NoSuchElementException` when missing.
    const(A) synthesize() const
    {
        if (!present_)
            throw new NoSuchElementException("Unable to synthesize missing annotation");
        return value_;
    }
}

/// How `MergedAnnotations.from` searches. Descriptors hold the element's own annotations (aggregate 0) and those of
/// each supertype (aggregates 1..n, contract 3); `DIRECT` and `INHERITED_ANNOTATIONS` read aggregate 0 (deviation:
/// `@Inherited` is not modelled), `SUPERCLASS` and `TYPE_HIERARCHY` read every aggregate.
enum SearchStrategy
{
    /// Only annotations directly declared (and their meta-annotations).
    DIRECT,
    /// Also `@Inherited` annotations of superclasses.
    INHERITED_ANNOTATIONS,
    /// Also every annotation of superclasses.
    SUPERCLASS,
    /// The full type hierarchy, superclasses and interfaces.
    TYPE_HIERARCHY,
}

/++
The merged annotations of one element, from a Flint AOT descriptor's tables.
+/
final class MergedAnnotations
{
    private const(EngineMergedAnnotation)[] annotations;
    private bool hierarchy;

    private this(const(EngineMergedAnnotation)[] annotations, bool hierarchy) pure nothrow @nogc
    {
        this.annotations = annotations;
        this.hierarchy = hierarchy;
    }

    /// The annotations of the type `descriptor` describes, searched with `strategy`.
    static MergedAnnotations from(const Descriptor descriptor,
            SearchStrategy strategy = SearchStrategy.INHERITED_ANNOTATIONS)
    {
        return from(descriptor is null ? null : descriptor.annotations, strategy);
    }

    /// The annotations of an element whose merged table is `annotations` (a property, method or parameter).
    static MergedAnnotations from(const(EngineMergedAnnotation)[] annotations,
            SearchStrategy strategy = SearchStrategy.INHERITED_ANNOTATIONS) pure nothrow
    {
        return new MergedAnnotations(annotations, strategy >= SearchStrategy.SUPERCLASS);
    }

    /// Whether an annotation named `annotationType` is present.
    bool isPresent(string annotationType) const nothrow @nogc
    {
        return find(annotationType) !is null;
    }

    /// Whether `A` is present, directly or as a meta-annotation.
    bool isPresent(A)() const nothrow @nogc
    {
        return isPresent(typeNameOf!A);
    }

    /// Whether an annotation named `annotationType` is directly present.
    bool isDirectlyPresent(string annotationType) const nothrow @nogc
    {
        auto found = find(annotationType);
        return found !is null && found.distance == 0 && found.aggregateIndex == 0;
    }

    /// Whether `A` is directly present.
    bool isDirectlyPresent(A)() const nothrow @nogc
    {
        return isDirectlyPresent(typeNameOf!A);
    }

    /// The nearest `A`, or `MergedAnnotation!A.missing()`. Throws `AnnotationConfigurationException` when the
    /// element's annotations declare `@AliasFor` incorrectly.
    MergedAnnotation!A get(A)() const
    {
        foreach (ref annotation; annotations)
            if (annotation.error.length)
                throw new AnnotationConfigurationException(annotation.error);
        auto found = find(typeNameOf!A);
        if (found is null)
            return MergedAnnotation!A.missing();
        return MergedAnnotation!A(found.distance, found.aggregateIndex, found.value.get!(const A));
    }

    /// The canonical type names of every present annotation, nearest first.
    string[] typeNames() const pure nothrow
    {
        string[] result;
        foreach (ref annotation; annotations)
            if (hierarchy || annotation.aggregateIndex == 0)
                result ~= annotation.type;
        return result;
    }

    /// How many annotations are present.
    size_t size() const pure nothrow @nogc
    {
        size_t count;
        foreach (ref annotation; annotations)
            if (hierarchy || annotation.aggregateIndex == 0)
                count++;
        return count;
    }

    /// Spring's `MergedAnnotationFinder`: the first aggregate holding one, then the `nearest` (lowest) distance.
    private const(EngineMergedAnnotation)* find(string annotationType) const nothrow @nogc
    {
        const(EngineMergedAnnotation)* best;
        foreach (ref annotation; annotations)
        {
            if (annotation.type != annotationType || (!hierarchy && annotation.aggregateIndex != 0))
                continue;
            if (best is null || annotation.aggregateIndex < best.aggregateIndex
                    || (annotation.aggregateIndex == best.aggregateIndex && annotation.distance < best.distance))
                best = &annotation;
        }
        return best;
    }
}

/// General utility for determining the order of an object from its descriptor's `@Order`, else Jakarta's
/// `@Priority`.
struct OrderUtils
{
    /// The `@Order` (else `@Priority`) value on `descriptor`'s type, or `defaultOrder`.
    static int getOrder(const Descriptor descriptor, int defaultOrder)
    {
        const order = findOrder(descriptor);
        return order.isPresent() ? order.get() : defaultOrder;
    }

    /// The `@Order` (else `@Priority`) value on `descriptor`'s type; `found` is false when there is none.
    static int getOrder(const Descriptor descriptor, out bool found)
    {
        const order = findOrder(descriptor);
        found = order.isPresent();
        return found ? order.get() : 0;
    }

    /// The `@Order` (else `@Priority`) value on `descriptor`'s type, or empty.
    static Optional!int findOrder(const Descriptor descriptor)
    {
        if (descriptor is null)
            return Optional!int.empty();
        // Spring's OrderUtils searches the TYPE_HIERARCHY: an @Order on a superclass or interface counts.
        if (auto order = findAnnotation(descriptor.annotations, typeNameOf!Order))
            return Optional!int.of(order.value.get!(const Order).value);
        return getPriority(descriptor);
    }

    /// The `@Priority` value on `descriptor`'s type, or empty.
    static Optional!int getPriority(const Descriptor descriptor)
    {
        import flint.jakarta.annotation : Priority;

        auto priority = descriptor is null ? null : findAnnotation(descriptor.annotations, typeNameOf!Priority);
        return priority is null ? Optional!int.empty() : Optional!int.of(priority.value.get!(const Priority).value);
    }
}

/++
`OrderComparator` that also reads `@Order`, from the Flint AOT descriptor of each object's class in `descriptors`.
`Ordered` wins over `@Order`, as in Spring.
+/
class AnnotationAwareOrderComparator : OrderComparator
{
    private DescriptorTable descriptors;

    /// A comparator reading `@Order` from `descriptors` (which may be null: then only `Ordered` counts).
    this(DescriptorTable descriptors = null) pure nothrow @nogc
    {
        this.descriptors = descriptors;
    }

    /// A comparator without descriptors.
    static AnnotationAwareOrderComparator INSTANCE()
    {
        return new AnnotationAwareOrderComparator;
    }

    /// `Ordered.getOrder()`, else the `@Order` (or `@Priority`) of the object's class.
    protected override Optional!int findOrder(Object obj)
    {
        auto order = super.findOrder(obj);
        if (order.isPresent() || descriptors is null || obj is null)
            return order;
        return OrderUtils.findOrder(descriptors.find(canonicalTypeName(typeid(obj).name)));
    }

    /// The `@Priority` of the object's class, or empty.
    override Optional!int getPriority(Object obj)
    {
        return obj is null ? Optional!int.empty() : getPriorityOfType(canonicalTypeName(typeid(obj).name));
    }

    /// The `@Priority` of the type named `typeName`, or empty.
    override Optional!int getPriorityOfType(string typeName)
    {
        return descriptors is null ? Optional!int.empty() : OrderUtils.getPriority(descriptors.find(typeName));
    }
}

/// General utility methods for working with merged annotations in descriptors.
struct AnnotationUtils
{
    /// The `value` attribute name.
    enum VALUE = "value";

    /// The nearest `A` on `descriptor`'s type or its supertypes (`TYPE_HIERARCHY`), with `found` false when absent.
    static const(A) findAnnotation(A)(const Descriptor descriptor, out bool found)
    {
        auto merged = MergedAnnotations.from(descriptor, SearchStrategy.TYPE_HIERARCHY).get!A();
        found = merged.isPresent();
        return found ? merged.synthesize() : A.init;
    }

    /// `A` when it is directly present on `descriptor`'s type, with `found` false otherwise.
    static const(A) getAnnotation(A)(const Descriptor descriptor, out bool found)
    {
        auto merged = MergedAnnotations.from(descriptor).get!A();
        found = merged.isDirectlyPresent();
        return found ? merged.synthesize() : A.init;
    }

    /// Whether `A` is present on `descriptor`'s type.
    static bool isAnnotationDeclaredLocally(A)(const Descriptor descriptor)
    {
        return MergedAnnotations.from(descriptor).isDirectlyPresent!A();
    }
}
