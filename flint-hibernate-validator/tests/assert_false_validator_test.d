/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/AssertFalseValidatorTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `new AssertFalseValidator().isValid(value, null)` is Flint's built-in
dispatcher run on the boxed value (`isValidFor`); `Boolean.FALSE` is the same D `bool` as `false`.
+/
module flint.hibernate.validator.assert_false_validator_test;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.validator_test_support : isValidFor;
import flint.jakarta.validation.constraints : AssertFalse;

@safe:

@("AssertFalseValidatorTest.testIsValid")
unittest
{
    const constraint = AssertFalse();
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, false));
    assert(isValidFor(constraint, Any.of(false)));
    assert(!isValidFor(constraint, true));
    assert(!isValidFor(constraint, Any.of(true)));
}
