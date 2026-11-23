/*
 * Ported from Jakarta Validation API 3.1.1 (jakarta.validation-api), https://github.com/jakartaee/validation,
 * tag 3.1.1: src/main/java/jakarta/validation/metadata/ConstraintDescriptor.java
 *
 * Jakarta Validation API
 * License: Apache License, Version 2.0
 *
 * Modified by the Flint authors: translated to D (rulebook v2). The annotation is
 * the boxed UDA value and its type's Flint name, as Flint AOT descriptors carry it.
 */

/// Constraint metadata.
module flint.jakarta.validation.metadata;

import flint.engine.aot.any : Any;

@safe:

/// Describes a single constraint and its composing constraints.
interface ConstraintDescriptor
{
    /// Returns the annotation describing the constraint declaration, boxed (Java's `T getAnnotation()`).
    Any getAnnotation();

    /// The Flint type name of the constraint annotation (Java's `getAnnotation().annotationType()`).
    string getAnnotationType();

    /// The non-interpolated error message.
    string getMessageTemplate();

    /// The value of the annotation element `name`, as Java's `getAttributes().get(name)`; `Any.init` when absent.
    Any getAttribute(string name);

    /// The names of the annotation's elements, in declaration order (Java's `getAttributes().keySet()`).
    string[] getAttributeNames();

    /// Whether the constraint is reported as a single violation (`@ReportAsSingleViolation`).
    bool isReportAsSingleViolation();
}
