/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/MinValidatorForStringTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `MinValidatorForCharSequence` and `DecimalMinValidatorForCharSequence` are
Flint's one dispatcher run on a D `string` (`isValidFor`). The HV-502 check on a custom `CharSequence`
(`MyCustomStringImpl`) has no D twin: Flint's character sequences are `string`s. Hibernate rejects a malformed
`DecimalMin` value in `initialize`; Flint has no such step and the gated port expects the failure when
validating.
+/
module flint.hibernate.validator.min_validator_for_string_test;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.validator_test_support : isValidFor;
import flint.jakarta.validation.constraints : DecimalMin, Min;

@safe:

@("MinValidatorForStringTest.testIsValidMinValidator")
unittest
{
    const m = Min(15L, "{validator.min}");
    testMinValidator(m, true);
}

@("MinValidatorForStringTest.testIsValidDecimalMinValidator")
unittest
{
    const m = DecimalMin("1500E-2", "{validator.min}");
    testMinValidator(m, true);
}

version (FlintConstraintAttributeChecks)
{
    // Gap: no initialize step rejects a DecimalMin value that is not a BigDecimal.
    @("MinValidatorForStringTest.testInitializeDecimalMaxWithInvalidValue")
    unittest
    {
        import std.exception : collectException;

        const m = DecimalMin("foobar", "{validator.min}");
        assert(collectException!Exception(isValidFor(m, 1)) !is null);
    }
}

@("MinValidatorForStringTest.testIsValidDecimalMinExclusive")
unittest
{
    const inclusive = false;
    const m = DecimalMin("1500E-2", "{validator.min}", inclusive);
    testMinValidator(m, inclusive);
}

private void testMinValidator(A)(A constraint, bool inclusive)
{
    if (inclusive)
    {
        assert(isValidFor(constraint, "15"));
        assert(isValidFor(constraint, "15.0"));
    }
    else
    {
        assert(!isValidFor(constraint, "15"));
        assert(!isValidFor(constraint, "15.0"));
    }
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, "20"));
    assert(!isValidFor(constraint, "10"));
    assert(!isValidFor(constraint, "14.99"));
    assert(!isValidFor(constraint, "-14.99"));
    // number format exception
    assert(!isValidFor(constraint, "15l"));
}
