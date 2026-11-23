/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/SignValidatorForNumberTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: the nine `<Sign>ValidatorFor<Type>` classes are Flint's one dispatcher run on each D
type (`isValidFor`); `BigInteger` is `long` and `BigDecimal` is `double` (Flint has neither big type), so
`BigDecimal.ONE.negate()` is `-1.0`.
+/
module flint.hibernate.validator.sign_validator_for_number_test;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.validator_test_support : isValidFor;
import flint.jakarta.validation.constraints : Negative, NegativeOrZero, Positive, PositiveOrZero;

@safe:

@("SignValidatorForNumberTest.testPositiveValidator")
unittest
{
    testSign(Positive(), true, true);
}

@("SignValidatorForNumberTest.testPositiveOrZeroValidator")
unittest
{
    testSign(PositiveOrZero(), false, true);
}

@("SignValidatorForNumberTest.testNegativeValidator")
unittest
{
    testSign(Negative(), true, false);
}

@("SignValidatorForNumberTest.testNegativeOrZeroValidator")
unittest
{
    testSign(NegativeOrZero(), false, false);
}

// testPositive, testPositiveOrZero, testNegative and testNegativeOrZero: every type, in Hibernate's order.
private void testSign(A)(A m, bool strict, bool positive)
{
    testSignNumber(m, strict, positive);
    testSignBigDecimal(m, strict, positive);
    testSignBigInteger(m, strict, positive);
    testSignLong(m, strict, positive);
    testSignFloat(m, strict, positive);
    testSignDouble(m, strict, positive);
    testSignShort(m, strict, positive);
    testSignByte(m, strict, positive);
    testSignInteger(m, strict, positive);
}

private void testSignShort(A)(A validator, bool strict, bool positive)
{
    assert(isValidFor(validator, Any.init));
    assert(isValidFor(validator, cast(short) 0) == !strict);
    assert(isValidFor(validator, cast(short) 1) == positive);
    assert(isValidFor(validator, cast(short)-1) == !positive);
    assert(isValidFor(validator, cast(short) 10.0) == positive);
    assert(isValidFor(validator, cast(short)-10.0) == !positive);
}

private void testSignByte(A)(A validator, bool strict, bool positive)
{
    assert(isValidFor(validator, Any.init));
    assert(isValidFor(validator, cast(byte) 0) == !strict);
    assert(isValidFor(validator, cast(byte) 1) == positive);
    assert(isValidFor(validator, cast(byte)-1) == !positive);
    assert(isValidFor(validator, cast(byte) 10.0) == positive);
    assert(isValidFor(validator, cast(byte)-10.0) == !positive);
}

private void testSignInteger(A)(A validator, bool strict, bool positive)
{
    assert(isValidFor(validator, Any.init));
    assert(isValidFor(validator, 0) == !strict);
    assert(isValidFor(validator, 1) == positive);
    assert(isValidFor(validator, -1) == !positive);
    assert(isValidFor(validator, 10) == positive);
    assert(isValidFor(validator, -10) == !positive);
}

private void testSignNumber(A)(A validator, bool strict, bool positive)
{
    assert(isValidFor(validator, Any.init));
    assert(isValidFor(validator, 0) == !strict);
    assert(isValidFor(validator, 1) == positive);
    assert(isValidFor(validator, -1) == !positive);
    assert(isValidFor(validator, 10.0) == positive);
    assert(isValidFor(validator, -10.0) == !positive);
}

private void testSignBigDecimal(A)(A validator, bool strict, bool positive)
{
    assert(isValidFor(validator, Any.init));
    assert(isValidFor(validator, 0.0) == !strict);
    assert(isValidFor(validator, 1.0) == positive);
    assert(isValidFor(validator, -1.0) == !positive);
    assert(isValidFor(validator, 10.0) == positive);
    assert(isValidFor(validator, -10.0) == !positive);
}

private void testSignBigInteger(A)(A validator, bool strict, bool positive)
{
    assert(isValidFor(validator, Any.init));
    assert(isValidFor(validator, 0L) == !strict);
    assert(isValidFor(validator, 1L) == positive);
    assert(isValidFor(validator, -1L) == !positive);
    assert(isValidFor(validator, 10L) == positive);
    assert(isValidFor(validator, -10L) == !positive);
}

private void testSignLong(A)(A validator, bool strict, bool positive)
{
    assert(isValidFor(validator, Any.init));
    assert(isValidFor(validator, 0L) == !strict);
    assert(isValidFor(validator, 1L) == positive);
    assert(isValidFor(validator, -1L) == !positive);
    assert(isValidFor(validator, 10L) == positive);
    assert(isValidFor(validator, -10L) == !positive);
}

private void testSignDouble(A)(A validator, bool strict, bool positive)
{
    assert(isValidFor(validator, Any.init));
    assert(isValidFor(validator, 0.0) == !strict);
    assert(isValidFor(validator, 1.0) == positive);
    assert(isValidFor(validator, -1.0) == !positive);
    assert(isValidFor(validator, 10.0) == positive);
    assert(isValidFor(validator, -10.0) == !positive);
    assert(isValidFor(validator, double.infinity) == positive);
    assert(isValidFor(validator, -double.infinity) == !positive);
    assert(!isValidFor(validator, double.nan));
}

private void testSignFloat(A)(A validator, bool strict, bool positive)
{
    assert(isValidFor(validator, Any.init));
    assert(isValidFor(validator, 0.0f) == !strict);
    assert(isValidFor(validator, 1.0f) == positive);
    assert(isValidFor(validator, -1.0f) == !positive);
    assert(isValidFor(validator, 10.0f) == positive);
    assert(isValidFor(validator, -10.0f) == !positive);
    assert(isValidFor(validator, float.infinity) == positive);
    assert(isValidFor(validator, -float.infinity) == !positive);
    assert(!isValidFor(validator, float.nan));
}
