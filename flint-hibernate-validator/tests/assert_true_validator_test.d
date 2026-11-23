/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/AssertTrueValidatorTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `new AssertTrueValidator().isValid(value, null)` is Flint's built-in
dispatcher run on the boxed value (`isValidFor`); `Boolean.TRUE` is the same D `bool` as `true`.
+/
module flint.hibernate.validator.assert_true_validator_test;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.validator_test_support : isValidFor;
import flint.jakarta.validation.constraints : AssertTrue;

@safe:

@("AssertTrueValidatorTest.testIsValid")
unittest
{
    const constraint = AssertTrue();
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, true));
    assert(isValidFor(constraint, Any.of(true)));
    assert(!isValidFor(constraint, false));
    assert(!isValidFor(constraint, Any.of(false)));
}
