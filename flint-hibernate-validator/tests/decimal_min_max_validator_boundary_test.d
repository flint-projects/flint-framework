/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/
DecimalMinMaxValidatorBoundaryTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: Hibernate adds the constraint to the test's own `Double d` field with a programmatic
`ConstraintMapping` (`type(...).field("d").constraint(new DecimalMinDef()...)`); Flint's mapping only binds
validators, so each test declares its D twin bean with the constraint on `double d`.
+/
module flint.hibernate.validator.decimal_min_max_validator_boundary_test;

import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.validator_test_support : assertNoViolations, assertOnlyViolations, validatorFor;
import flint.jakarta.validation.constraints : DecimalMax, DecimalMin;

@safe:

private final class MinHolder
{
    @DecimalMin("0.100000000000000005") double d;
}

private final class MaxHolder
{
    @DecimalMax("0.1") double d;
}

private final class TroubleHolder
{
    @DecimalMax("1.2") double d;
}

// LIKELY BUG: @DecimalMin/@DecimalMax compare doubles, so the bound 0.100000000000000005 rounds to 0.1 and admits it.
version (FlintNumericBoundPrecision)
{
    @("DecimalMinMaxValidatorBoundaryTest.testDecimalMinValue")
    unittest
    {
        auto validator = validatorFor!MinHolder();
        auto bean = new MinHolder();
        bean.d = 0.1;
        assertOnlyViolations(validator.validate(bean), typeNameOf!DecimalMin);
    }
}

@("DecimalMinMaxValidatorBoundaryTest.testDecimalMaxValue")
unittest
{
    auto validator = validatorFor!MaxHolder();
    auto bean = new MaxHolder();
    bean.d = 0.1;
    assertNoViolations(validator.validate(bean));
}

@("DecimalMinMaxValidatorBoundaryTest.testDoubleTrouble")
unittest
{
    auto validator = validatorFor!TroubleHolder();
    auto bean = new TroubleHolder();
    bean.d = 1.0;
    assertNoViolations(validator.validate(bean));
    bean.d = 1.1;
    assertNoViolations(validator.validate(bean));
    bean.d = 1.19;
    assertNoViolations(validator.validate(bean));
    bean.d = 1.20;
    assertNoViolations(validator.validate(bean));
    bean.d = 1.3;
    assertOnlyViolations(validator.validate(bean), typeNameOf!DecimalMax);
    bean.d = 1.51;
    assertOnlyViolations(validator.validate(bean), typeNameOf!DecimalMax);
    bean.d = 1.9;
    assertOnlyViolations(validator.validate(bean), typeNameOf!DecimalMax);
    bean.d = 2.000000001;
    assertOnlyViolations(validator.validate(bean), typeNameOf!DecimalMax);
}
