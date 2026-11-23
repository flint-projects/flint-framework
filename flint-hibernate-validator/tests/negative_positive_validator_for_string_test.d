/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/
NegativePositiveValidatorForStringTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `<Sign>ValidatorForCharSequence` is Flint's one dispatcher run on a D `string`
(`isValidFor`); the `{validator.…}` messages the builder set are not used by `isValid`.
+/
module flint.hibernate.validator.negative_positive_validator_for_string_test;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.validator_test_support : isValidFor;
import flint.jakarta.validation.constraints : Negative, NegativeOrZero, Positive, PositiveOrZero;

@safe:

@("NegativePositiveValidatorForStringTest.testIsValidPositiveValidator")
unittest
{
    const constraint = Positive("{validator.positive}");
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, "15"));
    assert(isValidFor(constraint, "15.0"));
    assert(!isValidFor(constraint, "0"));
    assert(!isValidFor(constraint, "-10"));
    assert(!isValidFor(constraint, "-14.99"));
    // number format exception
    assert(!isValidFor(constraint, "15l"));
}

@("NegativePositiveValidatorForStringTest.testIsValidPositiveOrZeroValidator")
unittest
{
    const constraint = PositiveOrZero("{validator.positiveOrZero}");
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, "15"));
    assert(isValidFor(constraint, "15.0"));
    assert(isValidFor(constraint, "0"));
    assert(!isValidFor(constraint, "-10"));
    assert(!isValidFor(constraint, "-14.99"));
    // number format exception
    assert(!isValidFor(constraint, "15l"));
}

@("NegativePositiveValidatorForStringTest.testIsValidNegativeValidator")
unittest
{
    const constraint = Negative("{validator.negative}");
    assert(isValidFor(constraint, Any.init));
    assert(!isValidFor(constraint, "15"));
    assert(!isValidFor(constraint, "15.0"));
    assert(!isValidFor(constraint, "0"));
    assert(isValidFor(constraint, "-10"));
    assert(isValidFor(constraint, "-14.99"));
    // number format exception
    assert(!isValidFor(constraint, "15l"));
}

@("NegativePositiveValidatorForStringTest.testIsValidNegativeOrZeroValidator")
unittest
{
    const constraint = NegativeOrZero("{validator.negativeOrZero}");
    assert(isValidFor(constraint, Any.init));
    assert(!isValidFor(constraint, "15"));
    assert(!isValidFor(constraint, "15.0"));
    assert(isValidFor(constraint, "0"));
    assert(isValidFor(constraint, "-10"));
    assert(isValidFor(constraint, "-14.99"));
    // number format exception
    assert(!isValidFor(constraint, "15l"));
}
