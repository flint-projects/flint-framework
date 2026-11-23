/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/MessagePropertiesTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: the Bean is registered as a Flint AOT descriptor; its `BigDecimal` is a `double`, its
`List<String>` flint.java.util's. Flint ports Hibernate's English bundle only, so the loop over the 24 supported
locales and the 24 Hibernate-specific constraints (`@CreditCardNumber` … `@UUID`, `@ScriptAssert`,
`@ParameterScriptAssert`, whose script engines are Java-only) are not ported; the 22 Jakarta constraints are checked
in the default locale.
+/
module flint.hibernate.validator.message_properties_test;

import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.validator_test_support : assertOnlyViolations, validatorFor;
import flint.jakarta.validation : ConstraintViolation;
import flint.jakarta.validation.constraints;
import flint.java.time : LocalDate;
import flint.java.util : ArrayList, List;

@safe:

private final class Bean
{
    @AssertFalse bool assertFalse = true;
    @AssertTrue bool assertTrue = false;
    @DecimalMax("3") double decimalMax = 4;
    @DecimalMin("3") double decimalMin = 2;
    @Digits(integer : 1, fraction:
            3) double digits = 13_333.3333f;
    @Email string email = "invalid";
    @Future LocalDate future = LocalDate.of(2010, 10, 4);
    @FutureOrPresent LocalDate futureOrPresent = LocalDate.of(2010, 10, 4);
    @Max(4) int max = 6;
    @Min(4) int min = 2;
    @Negative int negative = 4;
    @NegativeOrZero int negativeOrZero = 4;
    @NotBlank string notBlank = "";
    @NotEmpty List!string notEmpty;
    @NotNull string notNull = null;
    @Null string nullConstraint = "not null";
    @Past LocalDate past = LocalDate.of(2890, 10, 4);
    @PastOrPresent LocalDate pastOrPresent = LocalDate.of(2890, 10, 4);
    @Pattern(regexp : "[0-9]+") string pattern = "invalid";
    @Positive int positive = -4;
    @PositiveOrZero int positiveOrZero = -4;
    @Size(min : 2, max:
            4) string size = "666666";

    this()
    {
        notEmpty = new ArrayList!string();
    }
}

@("MessagePropertiesTest.testMessageProperties")
unittest
{
    string[] invalidMessages;

    // One locale (English) and the Jakarta constraints only: the other locales and Hibernate's own constraints are
    // not ported.
    auto validator = validatorFor!Bean();
    auto violations = validator.validate(new Bean());
    assertOnlyViolations(violations, typeNameOf!AssertFalse, typeNameOf!AssertTrue, typeNameOf!DecimalMax,
            typeNameOf!DecimalMin, typeNameOf!Digits, typeNameOf!Email, typeNameOf!Future,
            typeNameOf!FutureOrPresent,
            typeNameOf!Max, typeNameOf!Min, typeNameOf!Negative, typeNameOf!NegativeOrZero,
            typeNameOf!NotBlank, typeNameOf!NotEmpty, typeNameOf!NotNull, typeNameOf!Null, typeNameOf!Past,
            typeNameOf!PastOrPresent, typeNameOf!Pattern, typeNameOf!Positive,
            typeNameOf!PositiveOrZero, typeNameOf!Size);

    collectInvalidMessages("en", invalidMessages, violations);

    assert(invalidMessages.length == 0, "Some messages are invalid:\n\t- " ~ join(invalidMessages));
}

private void collectInvalidMessages(string locale, ref string[] invalidMessages, ConstraintViolation[] violations)
{
    foreach (violation; violations)
    {
        if (contains(violation.getMessage(), '{'))
            invalidMessages ~= "Message for constraint " ~ violation.getConstraintDescriptor()
                .getAnnotationType() ~ " and locale " ~ locale ~ " contains a curly brace: " ~ violation.getMessage();
        if (contains(violation.getMessage(), '$'))
            invalidMessages ~= "Message for constraint " ~ violation.getConstraintDescriptor()
                .getAnnotationType() ~ " and locale " ~ locale ~ " contains a dollar sign: " ~ violation.getMessage();
    }
}

private bool contains(string text, char c) pure nothrow @nogc
{
    foreach (ch; text)
        if (ch == c)
            return true;
    return false;
}

private string join(string[] lines) pure nothrow
{
    string text;
    foreach (i, line; lines)
        text ~= (i ? "\n\t- " : "") ~ line;
    return text;
}
