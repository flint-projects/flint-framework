/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/MaxValidatorForStringTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `MaxValidatorForCharSequence` and `DecimalMaxValidatorForCharSequence` are
Flint's one dispatcher run on a D `string` (`isValidFor`). The HV-502 check on a custom `CharSequence`
(`MyCustomStringImpl`) has no D twin: Flint's character sequences are `string`s. Hibernate rejects a malformed
`DecimalMax` value in `initialize`; Flint has no such step and the gated port expects the failure when
validating.
+/
module flint.hibernate.validator.max_validator_for_string_test;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.validator_test_support : isValidFor;
import flint.jakarta.validation.constraints : DecimalMax, Max;

@safe:

@("MaxValidatorForStringTest.testIsValidMax")
unittest
{
    const m = Max(15L, "{validator.max}");
    testMaxValidator(m, true);
}

@("MaxValidatorForStringTest.testIsValidDecimalMax")
unittest
{
    const m = DecimalMax("15.0E0", "{validator.max}");
    testMaxValidator(m, true);
}

version (FlintConstraintAttributeChecks)
{
    // Gap: no initialize step rejects a DecimalMax value that is not a BigDecimal.
    @("MaxValidatorForStringTest.testInitializeDecimalMaxWithInvalidValue")
    unittest
    {
        import std.exception : collectException;

        const m = DecimalMax("foobar", "{validator.max}");
        assert(collectException!Exception(isValidFor(m, 1)) !is null);
    }
}

@("MaxValidatorForStringTest.testIsValidDecimalMaxExclusive")
unittest
{
    const inclusive = false;
    const m = DecimalMax("15.0E0", "{validator.max}", inclusive);
    testMaxValidator(m, inclusive);
}

private void testMaxValidator(A)(A constraint, bool inclusive)
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
    assert(isValidFor(constraint, "10"));
    assert(isValidFor(constraint, "14.99"));
    assert(isValidFor(constraint, "-14.99"));
    assert(!isValidFor(constraint, "20"));
    // number format exception
    assert(!isValidFor(constraint, "15l"));
}
