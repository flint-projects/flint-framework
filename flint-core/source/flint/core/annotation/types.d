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
import flint.engine.aot.descriptor : Descriptor, DescriptorTable, EngineMergedAnnotation = MergedAnnotation;
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
    private const(A) value_;

    private this(ubyte distance, const A value) pure nothrow @nogc
    {
        present_ = true;
        distance_ = distance;
        value_ = value;
    }

    /// The value meaning the annotation is not present.
    static MergedAnnotation missing() pure nothrow @nogc
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
        return present_ && distance_ == 0;
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

    /// The merged annotation struct (annotations are immutable, so the view is `const`). Throws
    /// `NoSuchElementException` when missing.
    const(A) synthesize() const
    {
        if (!present_)
            throw new NoSuchElementException("Unable to synthesize missing annotation");
        return value_;
    }
}

/// How `MergedAnnotations.from` searches; Flint AOT merges with `INHERITED_ANNOTATIONS` semantics.
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

    private this(const(EngineMergedAnnotation)[] annotations) pure nothrow @nogc
    {
        this.annotations = annotations;
    }

    /// The annotations of the type `descriptor` describes.
    static MergedAnnotations from(const Descriptor descriptor, SearchStrategy = SearchStrategy.INHERITED_ANNOTATIONS)
    {
        return new MergedAnnotations(descriptor is null ? null : descriptor.annotations);
    }

    /// The annotations of an element whose merged table is `annotations` (a property, method or parameter).
    static MergedAnnotations from(const(EngineMergedAnnotation)[] annotations) pure nothrow
    {
        return new MergedAnnotations(annotations);
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
        return found !is null && found.distance == 0;
    }

    /// Whether `A` is directly present.
    bool isDirectlyPresent(A)() const nothrow @nogc
    {
        return isDirectlyPresent(typeNameOf!A);
    }

    /// The nearest `A`, or `MergedAnnotation!A.missing()`.
    MergedAnnotation!A get(A)() const
    {
        auto found = find(typeNameOf!A);
        if (found is null)
            return MergedAnnotation!A.missing();
        return MergedAnnotation!A(found.distance, found.value.get!(const A));
    }

    /// The canonical type names of every present annotation, nearest first.
    string[] typeNames() const pure nothrow
    {
        string[] result;
        foreach (ref annotation; annotations)
            result ~= annotation.type;
        return result;
    }

    /// How many annotations are present.
    size_t size() const pure nothrow @nogc
    {
        return annotations.length;
    }

    private const(EngineMergedAnnotation)* find(string annotationType) const nothrow @nogc
    {
        const(EngineMergedAnnotation)* best;
        foreach (ref annotation; annotations)
            if (annotation.type == annotationType && (best is null || annotation.distance < best.distance))
                best = &annotation;
        return best;
    }
}

/// General utility for determining the order of an object from its descriptor's `@Order`.
struct OrderUtils
{
    /// The `@Order` value on `descriptor`'s type, or `defaultOrder`.
    static int getOrder(const Descriptor descriptor, int defaultOrder)
    {
        auto order = descriptor is null ? null : descriptor.annotation(typeNameOf!Order);
        return order is null ? defaultOrder : order.value.get!(const Order).value;
    }

    /// The `@Order` value on `descriptor`'s type; `found` is false when there is none.
    static int getOrder(const Descriptor descriptor, out bool found)
    {
        if (descriptor is null)
            return 0;
        auto order = descriptor.annotation(typeNameOf!Order);
        found = order !is null;
        if (!found)
            return 0;
        return order.value.get!(const Order).value;
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

    /// `Ordered.getOrder()`, else the `@Order` of the object's class.
    protected override Optional!int findOrder(Object obj)
    {
        auto order = super.findOrder(obj);
        if (order.isPresent() || descriptors is null || obj is null)
            return order;
        auto descriptor = descriptors.find(canonicalTypeName(typeid(obj).name));
        auto annotation = descriptor is null ? null : descriptor.annotation(typeNameOf!Order);
        if (annotation is null)
            return Optional!int.empty();
        return Optional!int.of(annotation.value.get!(const Order).value);
    }
}

/// General utility methods for working with merged annotations in descriptors.
struct AnnotationUtils
{
    /// The `value` attribute name.
    enum VALUE = "value";

    /// The nearest `A` on `descriptor`'s type, with `found` false when absent.
    static const(A) findAnnotation(A)(const Descriptor descriptor, out bool found)
    {
        auto merged = MergedAnnotations.from(descriptor).get!A();
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
