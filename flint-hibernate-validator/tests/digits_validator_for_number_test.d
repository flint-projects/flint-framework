/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/DigitsValidatorForNumberTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `DigitsValidatorForNumber` is Flint's one dispatcher run on each D type
(`isValidFor`); `new BigDecimal("…")` is the D `double` of the same text (Flint has no BigDecimal). Hibernate rejects
negative `integer` or `fraction` in `initialize`; Flint has no such step and the gated ports expect the failure when
validating.
+/
module flint.hibernate.validator.digits_validator_for_number_test;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.validator_test_support : isValidFor;
import flint.jakarta.validation.constraints : Digits;

@safe:

@("DigitsValidatorForNumberTest.testIsValid")
unittest
{
    const constraint = Digits("{validator.digits}", 5, 2);
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, cast(byte) 0));
    assert(isValidFor(constraint, 500.2));
    assert(isValidFor(constraint, -12_345.12));
    assert(!isValidFor(constraint, -123_456.12));
    assert(!isValidFor(constraint, -123_456.123));
    assert(!isValidFor(constraint, -12_345.123));
    assert(!isValidFor(constraint, 12_345.123));
    assert(isValidFor(constraint, -0.22f)); // Float.valueOf("-000000000.22")
    assert(!isValidFor(constraint, 256_874));
    assert(!isValidFor(constraint, 12.0001));
}

@("DigitsValidatorForNumberTest.testIsValidZeroLength")
unittest
{
    const constraint = Digits("{validator.digits}", 0, 0);
    assert(isValidFor(constraint, Any.init));
    assert(!isValidFor(constraint, cast(byte) 0));
    assert(!isValidFor(constraint, 500.2));
}

@("DigitsValidatorForNumberTest.testNegativeIntegerLength")
unittest
{
    import std.exception : collectException;

    const p = Digits("{validator.digits}", -1, 1);
    assert(collectException!Exception(isValidFor(p, 1)) !is null);
}

@("DigitsValidatorForNumberTest.testNegativeFractionLength")
unittest
{
    import std.exception : collectException;

    const p = Digits("{validator.digits}", 1, -1);
    assert(collectException!Exception(isValidFor(p, 1)) !is null);
}

@("DigitsValidatorForNumberTest.testTrailingZerosAreTrimmed")
unittest
{
    const constraint = Digits("{validator.digits}", 12, 3);
    assert(isValidFor(constraint, 0.001));
    assert(isValidFor(constraint, 0.00100));
    assert(!isValidFor(constraint, 0.0001));
}
