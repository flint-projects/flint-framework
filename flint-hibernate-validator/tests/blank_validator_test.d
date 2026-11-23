/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/BlankValidatorTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `new NotBlankValidator().isValid(value, null)` is Flint's built-in
dispatcher run on the boxed value (`isValidFor`); the bean `Foo` is registered as a Flint AOT descriptor and its
`String name` is a D `string` (null until set).
+/
module flint.hibernate.validator.blank_validator_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.validator_test_support : assertNoViolations, assertOnlyViolations,
    isValidFor, validatorFor;
import flint.jakarta.validation.constraints : NotBlank;

@safe:

private final class Foo
{
    @NotBlank
    string name;
}

@("BlankValidatorTest.testConstraintValidator")
unittest
{
    const constraintValidator = NotBlank();
    assert(isValidFor(constraintValidator, "a"));
    assert(!isValidFor(constraintValidator, Any.init));
    assert(!isValidFor(constraintValidator, ""));
    assert(!isValidFor(constraintValidator, " "));
    assert(!isValidFor(constraintValidator, "\t"));
    assert(!isValidFor(constraintValidator, "\n"));
}

@("BlankValidatorTest.testNotBlank")
unittest
{
    auto validator = validatorFor!Foo();
    auto foo = new Foo();
    assertOnlyViolations(validator.validate(foo), typeNameOf!NotBlank);

    foo.name = "";
    assertOnlyViolations(validator.validate(foo), typeNameOf!NotBlank);

    foo.name = " ";
    assertOnlyViolations(validator.validate(foo), typeNameOf!NotBlank);

    foo.name = "\t";
    assertOnlyViolations(validator.validate(foo), typeNameOf!NotBlank);

    foo.name = "\n";
    assertOnlyViolations(validator.validate(foo), typeNameOf!NotBlank);

    foo.name = "john doe";
    assertNoViolations(validator.validate(foo));
}
