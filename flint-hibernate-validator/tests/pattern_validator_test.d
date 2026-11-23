/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/PatternValidatorTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `PatternValidator` is Flint's one dispatcher run on a D `string` (`isValidFor`); the
HV-502 custom `CharSequence` (`MyCustomStringImpl`) is a D `string`. Hibernate rejects a malformed regular
expression in `initialize`; Flint has no such step and the gated port expects the failure when validating.
+/
module flint.hibernate.validator.pattern_validator_test;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.validator_test_support : isValidFor;
import flint.jakarta.validation.constraints : Pattern;

@safe:

@("PatternValidatorTest.testIsValid")
unittest
{
    const constraint = Pattern(regexp: "foobar", message: "pattern does not match");
    assert(isValidFor(constraint, Any.init));
    assert(!isValidFor(constraint, ""));
    assert(!isValidFor(constraint, "bla bla"));
    assert(!isValidFor(constraint, "This test is not foobar"));
}

@("PatternValidatorTest.testIsValidForCharSequence")
unittest
{
    const constraint = Pattern(regexp: "char sequence");
    assert(isValidFor(constraint, "char sequence"));
}

@("PatternValidatorTest.testIsValidForEmptyStringRegexp")
unittest
{
    const constraint = Pattern(regexp: "|^.*foo$", message: "pattern does not match");
    assert(isValidFor(constraint, Any.init));
    assert(isValidFor(constraint, ""));
    assert(!isValidFor(constraint, "bla bla"));
    assert(isValidFor(constraint, "foo"));
    assert(isValidFor(constraint, "a b c foo"));
}

@("PatternValidatorTest.testInvalidRegularExpression")
unittest
{
    import std.exception : collectException;

    const constraint = Pattern(regexp: "(unbalanced parentheses", message: "pattern does not match");
    assert(collectException!Exception(isValidFor(constraint, "x")) !is null);
}
