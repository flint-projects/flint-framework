/*
 * Ported from Hibernate Validator 9.1.6.Final, https://github.com/hibernate/hibernate-validator,
 * tag 9.1.6.Final: engine/src/main/java/org/hibernate/validator/internal/engine/constraintvalidation/
 * {ConstraintValidatorContextImpl,SimpleConstraintTree}.java (behaviour)
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright Red Hat Inc. and Hibernate Authors
 *
 * Modified by the Flint authors: a user-defined ConstraintValidator<A, T> is called
 * through an erased adapter that ConstraintMapping.validatedBy!V builds where the
 * binding is declared (no construction from a class name); the context keeps the
 * message templates the validator builds.
 */

/// User-defined constraints: the erased validator adapter and `ConstraintValidatorContext`.
module flint.hibernate.validator.internal.custom;

import flint.engine.aot.any : Any;
import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.internal.constraintvalidators : BuiltinConstraint, readCustom;
import flint.jakarta.validation : ConstraintValidator, ConstraintValidatorContext;

@safe:

/// A `ConstraintValidator` class bound to its constraint annotation, callable with erased values.
struct CustomValidator
{
    /// The constraint annotation's Flint type name.
    string annotationType;
    /// The type the validator accepts (`T` of `ConstraintValidator!(A, T)`).
    string valueType;
    /// Whether a non-null `value` is of the accepted type.
    bool function(ref Any value) @safe accepts;
    /// The constraint's message template and attributes, read from the annotation.
    BuiltinConstraint function(ref const Any annotation) @safe read;
    /// Create the validator, initialize it with the annotation and run `isValid`.
    bool function(ref Any annotation, ref Any value, ConstraintValidatorContext context) @safe run;
}

/// The adapter for validator class `V`, which implements `ConstraintValidator!(A, T)` and has a default constructor.
CustomValidator customValidator(A, V)()
{
    static if (is(V : ConstraintValidator!(A, T), T))
        return CustomValidator(typeNameOf!A, typeNameOf!T, &accepts!T, &readCustom!A, &run!(A, V, T));
    else
        static assert(false, V.stringof ~ " does not implement ConstraintValidator!(" ~ A.stringof ~ ", T)");
}

private bool accepts(T)(ref Any value)
{
    static if (is(T == class) || is(T == interface))
        return cast(T) value.asObject() !is null;
    else
        return value.holds!T();
}

// Hibernate creates the validator through its ConstraintValidatorFactory and initializes it with the annotation.
private bool run(A, V, T)(ref Any annotation, ref Any value, ConstraintValidatorContext context)
{
    auto validator = new V();
    validator.initialize(annotation.get!A());
    static if (is(T == class) || is(T == interface))
        T typed = value.isNull() ? null : cast(T) value.asObject();
    else
        T typed = value.isNull() ? T.init : value.get!T();
    return validator.isValid(typed, context);
}

/// Hibernate's `ConstraintValidatorContextImpl`: the default template and the templates the validator adds.
final class ConstraintValidatorContextImpl : ConstraintValidatorContext
{
    private string defaultTemplate;
    private bool defaultDisabled;
    private string[] templates;

    ///
    this(string defaultTemplate) pure nothrow @nogc
    {
        this.defaultTemplate = defaultTemplate;
    }

    private final class Builder : ConstraintViolationBuilder
    {
        private string template_;

        this(string messageTemplate) pure nothrow @nogc
        {
            template_ = messageTemplate;
        }

        /// Adds the violation; returns the context.
        ConstraintValidatorContext addConstraintViolation()
        {
            templates ~= template_;
            return this.outer;
        }
    }

    /// A builder for a violation with `messageTemplate`.
    ConstraintViolationBuilder buildConstraintViolationWithTemplate(string messageTemplate)
    {
        return new Builder(messageTemplate);
    }

    /// Disables the violation with the constraint's own template.
    void disableDefaultConstraintViolation()
    {
        defaultDisabled = true;
    }

    /// The constraint's own message template.
    string getDefaultConstraintMessageTemplate()
    {
        return defaultTemplate;
    }

    /// The templates to report for a failed check: the default one unless disabled, then the built ones, in order.
    /// Throws HV000033 when the default is disabled and none was built.
    string[] violationTemplates()
    {
        import flint.jakarta.validation : ValidationException;

        enum noMessage = "HV000033: At least one custom message must be created if the default error message"
            ~ " gets disabled.";
        if (defaultDisabled && templates.length == 0)
            throw new ValidationException(noMessage);
        return defaultDisabled ? templates : defaultTemplate ~ templates;
    }
}
