/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/engine/messageinterpolation/
RegexpEscapingInterpolationTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: the entity is registered as a Flint AOT descriptor.
+/
module flint.hibernate.validator.regexp_escaping_interpolation_test;

import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.validator_test_support : assertOnlyViolationMessages, validatorFor, violationOf;
import flint.jakarta.validation.constraints : Pattern;

@safe:

private enum REGEXP_CONTAINING_SPECIAL_CHARACTERS = "[{0-9]{1,160}$";

private final class PatternWithCharactersUsedForInterpolationEntity
{
    @Pattern(regexp : REGEXP_CONTAINING_SPECIAL_CHARACTERS)
    string field;

    this(string field)
    {
        this.field = field;
    }
}

@("RegexpEscapingInterpolationTest.regexpShouldBeEscapedBeforeBeingInjectedIntoMessageDuringInterpolation")
unittest
{
    auto validator = validatorFor!PatternWithCharactersUsedForInterpolationEntity();
    auto violations = validator.validate(new PatternWithCharactersUsedForInterpolationEntity("test"));
    assertOnlyViolationMessages(violations, violationOf(typeNameOf!Pattern,
            "must match \"" ~ REGEXP_CONTAINING_SPECIAL_CHARACTERS ~ "\""));
}
