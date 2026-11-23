/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/time/TimeValidatorTest.java and
its DateHolder.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: Flint has neither `java.util.Calendar` nor `java.util.Date`; DateHolder's calendars
are flint.java.time `ZonedDateTime`s (in UTC) and its dates the `Instant`s they denote, a year either side of now.
+/
module flint.hibernate.validator.time_validator_test;

import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.validator_test_support : assertOnlyViolations, validatorFor;
import flint.jakarta.validation.constraints : Future, Past;
import flint.java.time : Instant, LocalDateTime, ZoneOffset, ZonedDateTime;

@safe:

private final class DateHolder
{
    @Past ZonedDateTime calendarWithPastDate;
    @Future ZonedDateTime calendarWithFutureDate;
    @Past Instant past;
    @Past Instant future;

    this()
    {
        const now = LocalDateTime.now();
        calendarWithPastDate = ZonedDateTime.of(now.plusYears(-1), ZoneOffset.UTC);
        past = calendarWithPastDate.toInstant();

        calendarWithFutureDate = ZonedDateTime.of(now.plusYears(1), ZoneOffset.UTC);
        future = calendarWithFutureDate.toInstant();
    }
}

/// HV-158
@("TimeValidatorTest.testFutureAndPast")
unittest
{
    auto validator = validatorFor!DateHolder();
    auto dateHolder = new DateHolder();
    assertOnlyViolations(validator.validate(dateHolder), typeNameOf!Past);
}
