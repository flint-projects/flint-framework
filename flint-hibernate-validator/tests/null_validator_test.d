/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/NullValidatorTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `new NullValidator().isValid(value, null)` is Flint's built-in
dispatcher run on the boxed value (`isValidFor`); `new Object()` is a fresh D `Object`.
+/
module flint.hibernate.validator.null_validator_test;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.validator_test_support : isValidFor;
import flint.jakarta.validation.constraints : Null;

@safe:

@("NullValidatorTest.testIsValid")
unittest
{
    const constraint = Null();
    assert(isValidFor(constraint, Any.init));
    assert(!isValidFor(constraint, new Object()));
}
