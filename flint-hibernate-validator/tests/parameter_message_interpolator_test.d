/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/engine/messageinterpolation/
ParameterMessageInterpolatorTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: Foo is registered as a Flint AOT descriptor. Flint's ParameterMessageInterpolator
logs nothing, so the check that it warned HV000185 through a Log4j `ListAppender` is gated.
+/
module flint.hibernate.validator.parameter_message_interpolator_test;

import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.messageinterpolation : ParameterMessageInterpolator;
import flint.hibernate.validator.validator_test_support : configurationFor;
import flint.jakarta.validation : ConstraintViolation, Validator;
import flint.jakarta.validation.constraints : Size;

@safe:

private final class Foo
{
    @Size(max: 1, message: "{max}")
    string snafu = "12";
    @Size(max: 2, message: "${validatedValue}")
    string bar = "123";
}

private Validator newValidator()
{
    return configurationFor!Foo().messageInterpolator(new ParameterMessageInterpolator())
        .buildValidatorFactory().getValidator();
}

// containsOnlyViolations(violationOf(Size.class).withProperty(property).withMessage(message))
private void assertOnlySizeViolation(ConstraintViolation[] constraintViolations, string property, string message)
{
    assert(constraintViolations.length == 1);
    assert(constraintViolations[0].getConstraintDescriptor().getAnnotationType() == typeNameOf!Size);
    assert(constraintViolations[0].getPropertyPath().toString() == property);
    assert(constraintViolations[0].getMessage() == message, constraintViolations[0].getMessage());
}

@("ParameterMessageInterpolatorTest.testParameterMessageInterpolatorInterpolatesParameters")
unittest
{
    auto foo = new Foo();
    assertOnlySizeViolation(newValidator().validateProperty(foo, "snafu"), "snafu", "1");
}

@("ParameterMessageInterpolatorTest.testParameterMessageInterpolatorIgnoresELExpressions")
unittest
{
    auto foo = new Foo();
    assertOnlySizeViolation(newValidator().validateProperty(foo, "bar"), "bar", "${validatedValue}");
    // Gap: ParameterMessageInterpolator does not log HV000185 for the expression it leaves alone.
    version (FlintInterpolatorWarnings)
        assert(listAppender.getEvents().any!(event => event.getLevel() == Level.WARN
                && event.getMessage().getFormattedMessage().startsWith("HV000185")));
}
