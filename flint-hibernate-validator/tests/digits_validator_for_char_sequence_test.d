/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/
DigitsValidatorForCharSequenceTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `DigitsValidatorForCharSequence` is Flint's one dispatcher run on a D `string`
(`isValidFor`). Hibernate rejects negative `integer` or `fraction` in `initialize`; Flint has no such step and the
gated ports expect the failure when validating. The HV-502 custom `CharSequence` (`MyCustomStringImpl`) is a D
`string`.
+/
module flint.hibernate.validator.digits_validator_for_char_sequence_test;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.validator_test_support : isValidFor;
import flint.jakarta.validation.constraints : Digits;

@safe:

private immutable constraint = Digits("{validator.digits}", 5, 2);

@("DigitsValidatorForCharSequenceTest.testIsValid")
unittest
{
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, "0"));
    assert(isValidFor(constraint, "500.2"));
    assert(isValidFor(constraint, "-12456.22"));
    assert(isValidFor(constraint, "-000000000.22"));
    //should throw number format exception
    assert(!isValidFor(constraint, ""));
    assert(!isValidFor(constraint, "256874.0"));
    assert(!isValidFor(constraint, "12.0001"));
}

version (FlintConstraintAttributeChecks)
{
    // Gap: no initialize step rejects a negative Digits.integer.
    @("DigitsValidatorForCharSequenceTest.testNegativeIntegerLength")
    unittest
    {
        import std.exception : collectException;

        const p = Digits(integer: -1, fraction: 1);
        assert(collectException!Exception(isValidFor(p, "1")) !is null);
    }

    // Gap: no initialize step rejects a negative Digits.fraction.
    @("DigitsValidatorForCharSequenceTest.testNegativeFractionLength")
    unittest
    {
        import std.exception : collectException;

        const p = Digits(integer: 1, fraction: -1);
        assert(collectException!Exception(isValidFor(p, "1")) !is null);
    }
}

@("DigitsValidatorForCharSequenceTest.testIsValidCharSequence")
unittest
{
    assert(isValidFor(constraint, "500.2"));
}
