/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/engine/messageinterpolation/TooBigMessageTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: GoldFish is registered as a Flint AOT descriptor.
+/
module flint.hibernate.validator.too_big_message_test;

import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.validator_test_support : assertOnlyViolationMessages, validatorFor, violationOf;
import flint.jakarta.validation.constraints : NotNull;

@safe:

/// Large enough to trigger a stack overflow with the recursive scheme, assuming default settings
private enum LARGE_MESSAGE = () {
    // Forty times the eighty-digit line Hibernate's constant concatenates.
    string message;
    foreach (i; 0 .. 40)
        message ~= "12345678901234567890123456789012345678901234567890123456789012345678901234567890";
    return message;
}();

private final class GoldFish
{
    @NotNull(message : LARGE_MESSAGE) string name;
}

/// HV-1091
@("TooBigMessageTest.largeMessageCanBeInterpolated")
unittest
{
    auto validator = validatorFor!GoldFish();
    auto fish = new GoldFish();
    assertOnlyViolationMessages(validator.validate(fish), violationOf(typeNameOf!NotNull, LARGE_MESSAGE));
}
