/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/MinValidatorForNumberTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: the annotation built with `ConstraintAnnotationDescriptor.Builder` is a D UDA value
(the `{validator.min}` message is not used by `isValid`); the nine `…ValidatorFor<Type>` classes are Flint's one
dispatcher run on each D type (see base_min_max_validator_for_number_test). The local `Foo` with a `Number` field is
one D class per value type, `BigDecimal.valueOf(x)` the `double` x. Hibernate rejects a malformed `DecimalMin`
value in `initialize`; Flint has no such step and the gated port expects the failure when validating.
+/
module flint.hibernate.validator.min_validator_for_number_test;

import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.base_min_max_validator_for_number_test : testAllTypes;
import flint.hibernate.validator.validator_test_support : assertNoViolations, assertOnlyViolations,
    isValidFor, validatorFor;
import flint.jakarta.validation.constraints : DecimalMin, Min;

@safe:

private final class IntFoo
{
    @DecimalMin("15.0001") int num;

    this(int num)
    {
        this.num = num;
    }
}

private final class DoubleFoo
{
    @DecimalMin("15.0001") double num;

    this(double num)
    {
        this.num = num;
    }
}

@("MinValidatorForNumberTest.testIsValidMinValidator")
unittest
{
    const m = Min(15L, "{validator.min}");
    testAllTypes(m, true, false);
}

@("MinValidatorForNumberTest.testIsValidDecimalMinValidator")
unittest
{
    const m = DecimalMin("1500E-2", "{validator.min}");
    testAllTypes(m, true, false);
}

@("MinValidatorForNumberTest.testIsValidDecimalMinWithDecimalFractionInConstraint")
unittest
{
    auto validator = validatorFor!(IntFoo, DoubleFoo)();
    assertOnlyViolations(validator.validate(new IntFoo(15)), typeNameOf!DecimalMin);
    assertNoViolations(validator.validate(new IntFoo(16)));
    assertOnlyViolations(validator.validate(new DoubleFoo(15.00001)), typeNameOf!DecimalMin);
    assertNoViolations(validator.validate(new DoubleFoo(15.01)));
    assertOnlyViolations(validator.validate(new DoubleFoo(15.00001)), typeNameOf!DecimalMin);
    assertNoViolations(validator.validate(new DoubleFoo(15.01)));
}

@("MinValidatorForNumberTest.testInitializeDecimalMinWithInvalidValue")
unittest
{
    import std.exception : collectException;

    const m = DecimalMin("foobar", "{validator.min}");
    assert(collectException!Exception(isValidFor(m, 1)) !is null);
}

@("MinValidatorForNumberTest.testIsValidDecimalMinExclusive")
unittest
{
    const inclusive = false;
    const m = DecimalMin("1500E-2", "{validator.min}", inclusive);
    testAllTypes(m, inclusive, false);
}
