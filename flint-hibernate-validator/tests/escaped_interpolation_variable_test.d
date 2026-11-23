/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/engine/messageinterpolation/
EscapedInterpolationVariableTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: the anonymous `ResourceBundleLocator` is the user bundle Flint's
`ResourceBundleMessageInterpolator` takes as a D associative array (Flint has no bundle caching to turn off; a key
the bundle does not know is simply absent rather than failing the test); the beans are registered as Flint AOT
descriptors.
+/
module flint.hibernate.validator.escaped_interpolation_variable_test;

import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.messageinterpolation : ResourceBundleMessageInterpolator;
import flint.hibernate.validator.validator_test_support : assertOnlyViolationMessages, configurationFor, violationOf;
import flint.jakarta.validation : Validator;
import flint.jakarta.validation.constraints : Max;

@safe:

private final class A
{
    @Max(value : 1, message:
            "{key-1}") int a = 2;
}

private final class B
{
    @Max(value : 1, message:
            "{key-2}") int a = 2;
}

private final class C
{
    @Max(value : 1, message:
            "{key-3}") int a = 2;
}

private final class D
{
    @Max(value : 1, message:
            "{key-4} {") int a = 2;
}

private Validator newValidator()
{
    auto interpolator = new ResourceBundleMessageInterpolator([
        "key-1": `\{escapedParameterKey\}`,
        // since {} are unbalanced the original key (key-2) should be returned from the interpolation
        "key-2": `{escapedParameterKey\}`,
        // since {} are unbalanced the original key (key-3) should be returned from the interpolation
        "key-3": `\{escapedParameterKey}`,
        "key-4": "foo",
    ]);
    auto config = configurationFor!(A, B, C, D)();
    return config.messageInterpolator(interpolator).buildValidatorFactory().getValidator();
}

@("EscapedInterpolationVariableTest.testEscapedOpeningAndClosingBrace")
unittest
{
    assertOnlyViolationMessages(newValidator().validate(new A()), violationOf(typeNameOf!Max,
            "{escapedParameterKey}"));
}

@("EscapedInterpolationVariableTest.testEscapedClosingBrace")
unittest
{
    assertOnlyViolationMessages(newValidator().validate(new B()), violationOf(typeNameOf!Max, "{key-2}"));
}

@("EscapedInterpolationVariableTest.testEscapedOpenBrace")
unittest
{
    assertOnlyViolationMessages(newValidator().validate(new C()), violationOf(typeNameOf!Max, "{key-3}"));
}

@("EscapedInterpolationVariableTest.testMessageStaysUnchangedDueToSingleCurlyBrace")
unittest
{
    assertOnlyViolationMessages(newValidator().validate(new D()), violationOf(typeNameOf!Max, "{key-4} {"));
}
