/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/
BaseMinMaxValidatorForNumberTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: the shared checks of MinValidatorForNumberTest and MaxValidatorForNumberTest (no
tests of its own). Each `ConstraintValidator<A, T>` Hibernate picks per type is Flint's one dispatcher, so each
helper takes the annotation; Java's boxed `Byte`, `Short`, `Integer`, `Long`, `Float` and `Double` are the D
scalars, `BigInteger` is `long` and `BigDecimal` is `double` (Flint has neither big type).
+/
module flint.hibernate.validator.base_min_max_validator_for_number_test;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.validator_test_support : isValidFor;

@safe:

/// `testNumberValidator`: a `Number`-typed element.
void testNumberValidator(A)(A constraint, bool inclusive, bool isMax)
{
    const byte b = 1;
    const byte bWrapper = 127;
    if (inclusive)
    {
        assert(isValidFor(constraint, 15L));
        assert(isValidFor(constraint, 15));
        assert(isValidFor(constraint, 15.0));
    }
    else
    {
        assert(!isValidFor(constraint, 15L));
        assert(!isValidFor(constraint, 15));
        assert(!isValidFor(constraint, 15.0));
    }
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, 10) == isMax);
    assert(isValidFor(constraint, b) == isMax);
    assert(isValidFor(constraint, 14.99) == isMax);
    assert(isValidFor(constraint, -14.99) == isMax);
    assert(isValidFor(constraint, 14.99f) == isMax);
    assert(isValidFor(constraint, -14.99f) == isMax);
    assert(isValidFor(constraint, 14) == isMax);
    assert(isValidFor(constraint, 16) == !isMax);
    assert(isValidFor(constraint, cast(short) 14) == isMax);
    assert(isValidFor(constraint, cast(short) 16) == !isMax);
    assert(isValidFor(constraint, 14L) == isMax);
    assert(isValidFor(constraint, 16L) == !isMax);
    assert(isValidFor(constraint, 14.0) == isMax);
    assert(isValidFor(constraint, 16.0) == !isMax);
    assert(isValidFor(constraint, 14.99) == isMax);
    assert(isValidFor(constraint, 15.001) == !isMax);
    assert(isValidFor(constraint, bWrapper) == !isMax);
    assert(isValidFor(constraint, 20) == !isMax);
}

/// `testValidatorBigDecimal`, with `BigDecimal.valueOf(x)` as the `double` x.
void testValidatorBigDecimal(A)(A constraint, bool inclusive, bool isMax)
{
    if (inclusive)
    {
        assert(isValidFor(constraint, 15.0));
        assert(isValidFor(constraint, 15.0));
        assert(isValidFor(constraint, 15.0));
    }
    else
    {
        assert(!isValidFor(constraint, 15.0));
        assert(!isValidFor(constraint, 15.0));
        assert(!isValidFor(constraint, 15.0));
    }
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, -156_000_000_000.0) == isMax);
    assert(isValidFor(constraint, 156_000_000_000.0) == !isMax);
}

/// `testValidatorBigInteger`, with `BigInteger.valueOf(x)` as the `long` x.
void testValidatorBigInteger(A)(A constraint, bool inclusive, bool isMax)
{
    if (inclusive)
    {
        assert(isValidFor(constraint, 15L));
        assert(isValidFor(constraint, 15L));
    }
    else
    {
        assert(!isValidFor(constraint, 15L));
        assert(!isValidFor(constraint, 15L));
    }
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, -1_560_000_000L) == isMax);
    assert(isValidFor(constraint, 1_560_000_000L) == !isMax);
}

/// `testValidatorByte`.
void testValidatorByte(A)(A constraint, bool inclusive, bool isMax)
{
    assert(isValidFor(constraint, cast(byte) 15) == inclusive);
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, cast(byte) 14) == isMax);
    assert(isValidFor(constraint, cast(byte) 16) == !isMax);
    assert(isValidFor(constraint, byte.min) == isMax);
    assert(isValidFor(constraint, byte.max) == !isMax);
}

/// `testValidatorShort`.
void testValidatorShort(A)(A constraint, bool inclusive, bool isMax)
{
    assert(isValidFor(constraint, cast(short) 15) == inclusive);
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, cast(short) 14) == isMax);
    assert(isValidFor(constraint, cast(short) 16) == !isMax);
    assert(isValidFor(constraint, short.min) == isMax);
    assert(isValidFor(constraint, short.max) == !isMax);
}

/// `testValidatorInteger`.
void testValidatorInteger(A)(A constraint, bool inclusive, bool isMax)
{
    assert(isValidFor(constraint, 15) == inclusive);
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, 14) == isMax);
    assert(isValidFor(constraint, 16) == !isMax);
    assert(isValidFor(constraint, int.min) == isMax);
    assert(isValidFor(constraint, int.max) == !isMax);
}

/// `testValidatorLong`.
void testValidatorLong(A)(A constraint, bool inclusive, bool isMax)
{
    assert(isValidFor(constraint, 15L) == inclusive);
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, -1_560_000_000L) == isMax);
    assert(isValidFor(constraint, 1_560_000_000L) == !isMax);
}

/// `testValidatorDouble`.
void testValidatorDouble(A)(A constraint, bool inclusive, bool isMax)
{
    assert(isValidFor(constraint, 15.0) == inclusive);
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, 14.99) == isMax);
    assert(isValidFor(constraint, 15.001) == !isMax);
    assert(isValidFor(constraint, -14.99) == isMax);
    assert(isValidFor(constraint, -1_560_000_000.0) == isMax);
    assert(isValidFor(constraint, -double.infinity) == isMax);
    assert(isValidFor(constraint, 1_560_000_000.0) == !isMax);
    assert(!isValidFor(constraint, double.nan));
    assert(isValidFor(constraint, double.infinity) == !isMax);
}

/// `testValidatorFloat`.
void testValidatorFloat(A)(A constraint, bool inclusive, bool isMax)
{
    assert(isValidFor(constraint, 15.0f) == inclusive);
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, -1_560_000_000.0f) == isMax);
    assert(isValidFor(constraint, -float.infinity) == isMax);
    assert(isValidFor(constraint, 1_560_000_000.0f) == !isMax);
    assert(!isValidFor(constraint, float.nan));
    assert(isValidFor(constraint, float.infinity) == !isMax);
}

/// Every per-type helper in the order MinValidatorForNumberTest and MaxValidatorForNumberTest call them.
void testAllTypes(A)(A constraint, bool inclusive, bool isMax)
{
    testNumberValidator(constraint, inclusive, isMax);
    testValidatorBigDecimal(constraint, inclusive, isMax);
    testValidatorBigInteger(constraint, inclusive, isMax);
    testValidatorByte(constraint, inclusive, isMax);
    testValidatorShort(constraint, inclusive, isMax);
    testValidatorInteger(constraint, inclusive, isMax);
    testValidatorLong(constraint, inclusive, isMax);
    testValidatorFloat(constraint, inclusive, isMax);
    testValidatorDouble(constraint, inclusive, isMax);
}
