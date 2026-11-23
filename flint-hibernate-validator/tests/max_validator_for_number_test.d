/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/MaxValidatorForNumberTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: the annotation built with `ConstraintAnnotationDescriptor.Builder` is a D UDA value
(the `{validator.max}` message is not used by `isValid`); the nine `…ValidatorFor<Type>` classes are Flint's one
dispatcher run on each D type (see base_min_max_validator_for_number_test). The local `Foo` with a `Number` field is
one D class per value type, `BigDecimal` the `double` and `BigInteger` the `long` of the same value. Hibernate
rejects a malformed `DecimalMax` value in `initialize`; Flint has no such step and the gated port expects the
failure when validating.
+/
module flint.hibernate.validator.max_validator_for_number_test;

import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.base_min_max_validator_for_number_test : testAllTypes;
import flint.hibernate.validator.validator_test_support : assertNoViolations, assertOnlyViolations,
    isValidFor, validatorFor;
import flint.jakarta.validation.constraints : DecimalMax, Max;

@safe:

private final class IntFoo
{
    @DecimalMax("15.0001") int num;

    this(int num)
    {
        this.num = num;
    }
}

private final class DoubleFoo
{
    @DecimalMax("15.0001") double num;

    this(double num)
    {
        this.num = num;
    }
}

@("MaxValidatorForNumberTest.testIsValidMax")
unittest
{
    const m = Max(15L, "{validator.max}");
    testAllTypes(m, true, true);
}

@("MaxValidatorForNumberTest.testIsValidDecimalMax")
unittest
{
    const m = DecimalMax("15.0E0", "{validator.max}");
    testAllTypes(m, true, true);
}

@("MaxValidatorForNumberTest.testIsValidDecimalMaxWithDecimalFractionInConstraint")
unittest
{
    auto validator = validatorFor!(IntFoo, DoubleFoo)();
    assertOnlyViolations(validator.validate(new IntFoo(16)), typeNameOf!DecimalMax);
    assertNoViolations(validator.validate(new IntFoo(15)));
    assertOnlyViolations(validator.validate(new DoubleFoo(15.01)), typeNameOf!DecimalMax);
    assertNoViolations(validator.validate(new DoubleFoo(15.00001)));
    assertOnlyViolations(validator.validate(new DoubleFoo(15.01)), typeNameOf!DecimalMax);
    assertNoViolations(validator.validate(new DoubleFoo(15.00001)));
}

@("MaxValidatorForNumberTest.testIsValidDecimalMax1")
unittest
{
    import flint.engine.aot.text : decimal;

    const m = DecimalMax(decimal(int.max - 1));
    assert(!isValidFor(m, double.infinity));
}

version (FlintConstraintAttributeChecks)
{
    // Gap: no initialize step rejects a DecimalMax value that is not a BigDecimal.
    @("MaxValidatorForNumberTest.testInitializeDecimalMaxWithInvalidValue")
    unittest
    {
        import std.exception : collectException;

        const m = DecimalMax("foobar", "{validator.max}");
        assert(collectException!Exception(isValidFor(m, 1)) !is null);
    }
}

@("MaxValidatorForNumberTest.testIsValidDecimalMaxExclusive")
unittest
{
    const inclusive = false;
    const m = DecimalMax("15.0E0", "{validator.max}", inclusive);
    testAllTypes(m, false, true);
}

@("MaxValidatorForNumberTest.testIsValidNumberForFloatingPointOrBigNumbersStoredAsNumber")
unittest
{
    const m = Max(1L);
    assert(!isValidFor(m, 1.01));
    assert(!isValidFor(m, 1.01f));
    assert(!isValidFor(m, 1.01));
    assert(!isValidFor(m, 2L));
    assert(!isValidFor(m, double.infinity));
    assert(!isValidFor(m, float.infinity));
}
