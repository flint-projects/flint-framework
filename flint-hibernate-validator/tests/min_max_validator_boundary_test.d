/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/MinMaxValidatorBoundaryTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: the test class validates itself; its D twin is a separate bean registered as a Flint
AOT descriptor.
+/
module flint.hibernate.validator.min_max_validator_boundary_test;

import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.validator_test_support : assertOnlyViolations, validatorFor;
import flint.jakarta.validation.constraints : Max, Min;

@safe:

private final class Boundary
{
    @Min(9_223_372_036_854_775_807L)
    long min;
    @Max(9_223_372_036_854_775_806L)
    long max;
}

@("MinMaxValidatorBoundaryTest.testMinBoundaryValue")
unittest
{
    auto validator = validatorFor!Boundary();
    auto bean = new Boundary();
    bean.min = 9_223_372_036_854_775_806L;
    bean.max = 0L;
    // Current min value is smaller, should fail, but it doesn't
    assertOnlyViolations(validator.validate(bean), typeNameOf!Min);
}

@("MinMaxValidatorBoundaryTest.testMaxBoundaryValue")
unittest
{
    auto validator = validatorFor!Boundary();
    auto bean = new Boundary();
    bean.min = long.max;
    bean.max = 9_223_372_036_854_775_807L;
    // Current max value is bigger, should fail, but it doesn't
    assertOnlyViolations(validator.validate(bean), typeNameOf!Max);
}
