/++
Helpers shared by the tests ported from Hibernate Validator 9.1.6.Final's engine/src/test/java: the D side of
`ConstraintAnnotationDescriptor.Builder` plus `new XValidator().initialize(annotation).isValid(value, null)`,
`ValidatorUtil.getValidator()` over Flint AOT descriptors, and `ConstraintViolationAssert.containsOnlyViolations`.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: Hibernate's validator per (constraint, type) pair is Flint's one erased dispatcher,
so `isValidFor` reads the annotation and runs it on a boxed value; beans are registered as descriptors instead of
being reflected over.
+/
module flint.hibernate.validator.validator_test_support;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, DescriptorTable, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator : HibernateValidatorConfiguration;
import flint.hibernate.validator.internal.constraintvalidators : PatternCache, isValid, read;
import flint.hibernate.validator.internal.engine : ConstraintDescriptorImpl, MessageInterpolatorContext;
import flint.jakarta.validation : ConstraintViolation, Validation, Validator;

@safe:

/// `validator.initialize(annotation); validator.isValid(value, null)` for the built-in constraint `annotation`.
/// `described` is the descriptor through which an array reports its size.
bool isValidFor(A)(A annotation, Any value, const(Descriptor) described = null)
{
    const boxed = box(annotation);
    const constraint = read(typeNameOf!A, boxed);
    return isValid(constraint, value, new PatternCache(), "value", described);
}

/// `isValidFor` with the value boxed.
bool isValidFor(A, T)(A annotation, T value) if (!is(T == Any))
{
    return isValidFor(annotation, Any.of(value));
}

/// The descriptor of the built-in constraint `annotation`, as `new ConstraintDescriptorImpl<>(..., builder.build(),
/// ...)` makes it.
ConstraintDescriptorImpl descriptorFor(A)(A annotation)
{
    const boxed = box(annotation);
    return new ConstraintDescriptorImpl(read(typeNameOf!A, boxed));
}

/// The interpolation context of the built-in constraint `annotation` on `validatedValue`.
MessageInterpolatorContext contextFor(A)(A annotation, Any validatedValue = Any.init)
{
    return new MessageInterpolatorContext(descriptorFor(annotation), validatedValue);
}

/// A configuration whose descriptor table knows the built-ins and `Types`.
HibernateValidatorConfiguration configurationFor(Types...)()
{
    auto table = DescriptorTable.withBuiltins();
    static foreach (T; Types)
        table.add(descriptorOf!T());
    auto configuration = cast(HibernateValidatorConfiguration) Validation.byDefaultProvider();
    assert(configuration !is null, "Hibernate Validator registers itself as the default provider");
    return configuration.descriptors(table);
}

/// `ValidatorUtil.getValidator()` for beans of `Types`.
Validator validatorFor(Types...)()
{
    return configurationFor!Types().buildValidatorFactory().getValidator();
}

/// `assertThat(violations).containsOnlyViolations(violationOf(A)...)`: the violations' constraint types, as a
/// multiset, are exactly `types`.
void assertOnlyViolations(ConstraintViolation[] violations, string[] types...)
{
    import std.algorithm.sorting : sort;

    string[] actual;
    foreach (v; violations)
        actual ~= v.getConstraintDescriptor().getAnnotationType();
    auto expected = types.dup;
    actual.sort();
    expected.sort();
    assert(actual == expected, describe(actual) ~ " instead of " ~ describe(expected));
}

/// `violationOf(A).withMessage(message)`, for `assertOnlyViolationMessages`.
string violationOf(string type, string message) pure nothrow
{
    return type ~ ": " ~ message;
}

/// `containsOnlyViolations(violationOf(A).withMessage(m)...)`: the violations' constraint types and messages, as a
/// multiset, are exactly `expected` (each from `violationOf`).
void assertOnlyViolationMessages(ConstraintViolation[] violations, string[] expected...)
{
    import std.algorithm.sorting : sort;

    string[] actual;
    foreach (v; violations)
        actual ~= violationOf(v.getConstraintDescriptor().getAnnotationType(), v.getMessage());
    auto want = expected.dup;
    actual.sort();
    want.sort();
    assert(actual == want, describe(actual) ~ " instead of " ~ describe(want));
}

/// `assertNoViolations(violations)`.
void assertNoViolations(ConstraintViolation[] violations)
{
    assertOnlyViolations(violations);
}

// The annotation boxed as a mutable copy, so that a const annotation with array elements (Pattern.flags) can be boxed.
private Any box(A)(A annotation)
{
    import std.traits : Unqual, isDynamicArray;

    Unqual!A copy;
    static foreach (i; 0 .. A.tupleof.length)
    {
        static if (isDynamicArray!(typeof(A.tupleof[i])) && !is(typeof(A.tupleof[i]) : const(char)[]))
            copy.tupleof[i] = annotation.tupleof[i].dup;
        else
            copy.tupleof[i] = annotation.tupleof[i];
    }
    return Any.of(copy);
}

private string describe(string[] types) pure
{
    string text = "[";
    foreach (i, t; types)
        text ~= (i ? ", " : "") ~ t;
    return text ~ "]";
}
