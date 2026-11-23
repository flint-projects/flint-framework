/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/engine/messageinterpolation/
MessageInterpolationWithDefaultBundleTest.java and its User.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: beans are registered as Flint AOT descriptors; `ValidatorUtil.getConfiguration(locale)`
is the default configuration, since Flint's default bundle is Hibernate's English one and nothing selects another
locale (the German and French tests are gated). Hibernate's own `@Range`, `@DurationMin` and `@DurationMax` have no
Flint port, so User's `@Range` age and the Duration test are gated.
+/
module flint.hibernate.validator.message_interpolation_with_default_bundle_test;

import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator : HibernateValidatorConfiguration;
import flint.hibernate.validator.messageinterpolation : ResourceBundleMessageInterpolator;
import flint.hibernate.validator.validator_test_support : assertOnlyViolationMessages, configurationFor, violationOf;
import flint.jakarta.validation : Validator;
import flint.jakarta.validation.constraints : DecimalMax, DecimalMin, Email;

@safe:

private final class User
{
    @Email string email;
    // Gap: Hibernate's own constraints (@Range, @DurationMin, @DurationMax) are not ported.
    version (FlintHibernateConstraints)
    {
        @Range(min : 18, max:
                21) int age;
    }
}

private final class DoubleHolder
{
    @DecimalMax(value : "1.0") double inclusiveMaxDouble;
    @DecimalMax(value : "1.0", inclusive:
            false) double exclusiveMaxDouble;

    @DecimalMin(value : "1.0") double inclusiveMinDouble;
    @DecimalMin(value : "1.0", inclusive:
            false) double exclusiveMinDouble;

    this()
    {
        this.inclusiveMaxDouble = 1.1;
        this.exclusiveMaxDouble = 1.0;

        this.inclusiveMinDouble = 0.9;
        this.exclusiveMinDouble = 1.0;
    }
}

// ValidatorUtil.getConfiguration(Locale.ENGLISH) with
// `config.messageInterpolator(new ResourceBundleMessageInterpolator())`.
private Validator englishValidator(Bean)()
{
    HibernateValidatorConfiguration config = configurationFor!Bean();
    config.messageInterpolator(new ResourceBundleMessageInterpolator());
    return config.buildValidatorFactory().getValidator();
}

private User newUser()
{
    auto user = new User();
    user.email = "foo";
    version (FlintHibernateConstraints)
        user.age = 16;
    return user;
}

@("MessageInterpolationWithDefaultBundleTest.testEmailAndRangeMessageEnglishLocale")
unittest
{
    auto validator = englishValidator!User();
    auto constraintViolations = validator.validate(newUser());
    version (FlintHibernateConstraints)
        assertOnlyViolationMessages(constraintViolations, violationOf(typeNameOf!Email,
                "must be a well-formed email address"), violationOf(typeNameOf!Range, "must be between 18 and 21"));
    else
        assertOnlyViolationMessages(constraintViolations, violationOf(typeNameOf!Email,
                "must be a well-formed email address"));
}

// Gap: only Hibernate's English bundle is ported, and no locale selects a message bundle.
version (FlintMessageLocales)
{
    /// A message interpolator that enforces one given locale to be used for message interpolation.
    private final class LocalizedMessageInterpolator : ResourceBundleMessageInterpolator
    {
        private Locale locale;

        this(Locale locale)
        {
            this.locale = locale;
        }

        override string interpolate(string messageTemplate, Context context)
        {
            return interpolate(messageTemplate, context, this.locale);
        }
    }

    @("MessageInterpolationWithDefaultBundleTest.testEmailAndRangeMessageGermanLocale")
    unittest
    {
        HibernateValidatorConfiguration config = configurationFor!User();
        config.defaultLocale(Locale.GERMAN);
        config.messageInterpolator(new ResourceBundleMessageInterpolator());
        auto validator = config.buildValidatorFactory().getValidator();
        assertOnlyViolationMessages(validator.validate(newUser()), violationOf(typeNameOf!Email,
                "muss eine korrekt formatierte E-Mail-Adresse sein"),
                violationOf(typeNameOf!Range, "muss zwischen 18 und 21 sein"));
    }

    @("MessageInterpolationWithDefaultBundleTest.testEmailAndRangeMessageFrenchLocale")
    unittest
    {
        HibernateValidatorConfiguration config = configurationFor!User();
        config.defaultLocale(Locale.FRENCH);
        config.messageInterpolator(new ResourceBundleMessageInterpolator());
        auto validator = config.buildValidatorFactory().getValidator();
        assertOnlyViolationMessages(validator.validate(newUser()), violationOf(typeNameOf!Email,
                "doit être une adresse électronique syntaxiquement correcte"),
                violationOf(typeNameOf!Range, "doit être compris entre 18 et 21"));
    }

    /// HV-306. If English is explicitly set as locale for message interpolation, it
    /// must take precedence over the system's default locale.
    @("MessageInterpolationWithDefaultBundleTest.testThatExplicitlySetEnglishLocaleHasPrecedenceOverDefaultLocale")
    unittest
    {
        HibernateValidatorConfiguration config = configurationFor!User();
        config.defaultLocale(Locale.FRENCH);
        config.messageInterpolator(new LocalizedMessageInterpolator(Locale.ENGLISH));
        auto validator = config.buildValidatorFactory().getValidator();
        assertOnlyViolationMessages(validator.validate(newUser()), violationOf(typeNameOf!Email,
                "must be a well-formed email address"), violationOf(typeNameOf!Range, "must be between 18 and 21"));
    }
}

@("MessageInterpolationWithDefaultBundleTest.testConditionalDecimalMinMessageDependingOnInclusiveFlag")
unittest
{
    auto validator = englishValidator!DoubleHolder();
    assertOnlyViolationMessages(validator.validate(new DoubleHolder()), violationOf(typeNameOf!DecimalMin,
            "must be greater than or equal to 1.0"),
            violationOf(typeNameOf!DecimalMin, "must be greater than 1.0"), violationOf(typeNameOf!DecimalMax,
                "must be less than or equal to 1.0"), violationOf(typeNameOf!DecimalMax, "must be less than 1.0"));
}

version (FlintMessageLocales)
{
    @("MessageInterpolationWithDefaultBundleTest.testConditionalDecimalMinMaxMessagesForFrenchLocale")
    unittest
    {
        HibernateValidatorConfiguration config = configurationFor!DoubleHolder();
        config.defaultLocale(Locale.FRENCH);
        config.messageInterpolator(new ResourceBundleMessageInterpolator());
        auto validator = config.buildValidatorFactory().getValidator();
        assertOnlyViolationMessages(validator.validate(new DoubleHolder()),
                violationOf(typeNameOf!DecimalMin, "doit être supérieur ou égal à 1.0"),
                violationOf(typeNameOf!DecimalMin, "doit être supérieur à 1.0"), violationOf(typeNameOf!DecimalMax,
                    "doit être inférieur ou égal à 1.0"),
                violationOf(typeNameOf!DecimalMax, "doit être inférieur à 1.0"));
    }
}

// Gap: Hibernate's @DurationMin and @DurationMax are not ported (and the test also needs the French bundle).
version (FlintHibernateConstraints)
{
    private final class DurationHolder
    {
        @DurationMax(days : 2L) Duration inclusiveMaxDuration;
        @DurationMax(days : 2L, inclusive:
                false) Duration exclusiveMaxDuration;

        @DurationMin(days : 2L) Duration inclusiveMinDuration;
        @DurationMin(days : 2L, inclusive:
                false) Duration exclusiveMinDuration;

        this()
        {
            this.inclusiveMaxDuration = Duration.ofDays(3);
            this.exclusiveMaxDuration = Duration.ofDays(2);

            this.inclusiveMinDuration = Duration.ofDays(1);
            this.exclusiveMinDuration = Duration.ofDays(2);
        }
    }

    @("MessageInterpolationWithDefaultBundleTest.testConditionalDurationMinMaxMessagesForFrenchLocale")
    unittest
    {
        HibernateValidatorConfiguration config = configurationFor!DurationHolder();
        config.defaultLocale(Locale.FRENCH);
        config.messageInterpolator(new ResourceBundleMessageInterpolator());
        auto validator = config.buildValidatorFactory().getValidator();
        assertOnlyViolationMessages(validator.validate(new DurationHolder()),
                violationOf(typeNameOf!DurationMin, "doit être plus long ou égal à 2 jours"),
                violationOf(typeNameOf!DurationMin, "doit être plus long que 2 jours"),
                violationOf(typeNameOf!DurationMax,
                    "doit être plus court ou égal à 2 jours"),
                violationOf(typeNameOf!DurationMax, "doit être plus court que 2 jours"));
    }
}
