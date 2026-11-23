/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/engine/messageinterpolation/
DefaultLocaleMessageInterpolationTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `Validation.byProvider(HibernateValidator.class).configure()` is the default
provider's configuration; `TestContext.unwrap` has no counterpart in Flint's `MessageInterpolator.Context`. Flint
ports Hibernate's English bundle only and its configuration has no `defaultLocale`, so testDefaultLocaleHonored is
gated.
+/
module flint.hibernate.validator.default_locale_message_interpolation_test;

import flint.engine.aot.any : Any;
import flint.jakarta.validation : MessageInterpolator, Validation;
import flint.jakarta.validation.metadata : ConstraintDescriptor;

@safe:

private final class TestContext : MessageInterpolator.Context
{
    ConstraintDescriptor getConstraintDescriptor()
    {
        return null;
    }

    Any getValidatedValue()
    {
        return Any.init;
    }
}

@("DefaultLocaleMessageInterpolationTest.testNoDefaultLocaleDefinedStillWorking")
unittest
{
    auto validatorFactory = Validation.byDefaultProvider().buildValidatorFactory();
    auto messageInterpolator = validatorFactory.getMessageInterpolator();
    assert(messageInterpolator.interpolate("{jakarta.validation.constraints.AssertFalse.message}",
            new TestContext()) == "must be false");
}

// Gap: only Hibernate's English bundle is ported, and the configuration has no defaultLocale.
version (FlintMessageLocales)
{
    @("DefaultLocaleMessageInterpolationTest.testDefaultLocaleHonored")
    unittest
    {
        import flint.hibernate.validator : HibernateValidatorConfiguration;

        auto configuration = cast(HibernateValidatorConfiguration) Validation.byDefaultProvider();
        auto validatorFactory = configuration.defaultLocale(Locale.FRANCE).buildValidatorFactory();
        auto messageInterpolator = validatorFactory.getMessageInterpolator();
        assert(messageInterpolator.interpolate("{jakarta.validation.constraints.AssertFalse.message}",
                new TestContext()) == "doit avoir la valeur faux");

        configuration = cast(HibernateValidatorConfiguration) Validation.byDefaultProvider();
        validatorFactory = configuration.defaultLocale(Locale.ITALY).buildValidatorFactory();
        messageInterpolator = validatorFactory.getMessageInterpolator();
        assert(messageInterpolator.interpolate("{jakarta.validation.constraints.AssertFalse.message}",
                new TestContext()) == "deve essere false");
    }
}
