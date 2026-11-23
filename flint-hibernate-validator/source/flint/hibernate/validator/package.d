/*
 * Ported from Hibernate Validator 9.1.6.Final, https://github.com/hibernate/hibernate-validator,
 * tag 9.1.6.Final: engine/src/main/java/org/hibernate/validator/{HibernateValidator,
 * HibernateValidatorConfiguration}.java and internal/engine/ConfigurationImpl.java
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright Red Hat Inc. and Hibernate Authors
 *
 * Modified by the Flint authors: the provider registers itself with Jakarta
 * Validation when it is linked in (Flint's replacement for META-INF/services), and
 * its configuration takes the descriptor table the application's Flint AOT
 * registry filled.
 */

/// Hibernate Validator, the Jakarta Validation provider.
module flint.hibernate.validator;

import flint.engine.aot.descriptor : DescriptorTable;
import flint.hibernate.validator.internal.engine : ValidatorFactoryImpl;
import flint.hibernate.validator.messageinterpolation : ResourceBundleMessageInterpolator;
import flint.jakarta.validation : Configuration, MessageInterpolator, Validation, ValidatorFactory;
import flint.jakarta.validation.spi : ValidationProvider;

@safe:

/// Default implementation of `ValidationProvider` within Hibernate Validator.
final class HibernateValidator : ValidationProvider
{
    /// Returns a `HibernateValidatorConfiguration` with Hibernate's defaults.
    Configuration createGenericConfiguration()
    {
        return new HibernateValidatorConfiguration();
    }

    /// Returns the provider-specific configuration (Java's `createSpecializedConfiguration`).
    HibernateValidatorConfiguration createSpecializedConfiguration()
    {
        return new HibernateValidatorConfiguration();
    }
}

/// Hibernate Validator's `Configuration`: the interpolator and, in Flint, the descriptor table.
final class HibernateValidatorConfiguration : Configuration
{
    private MessageInterpolator interpolator;
    private DescriptorTable table;

    /// Defines the message interpolator used; null restores `ResourceBundleMessageInterpolator`.
    Configuration messageInterpolator(MessageInterpolator interpolator)
    {
        this.interpolator = interpolator;
        return this;
    }

    /// Hibernate's default interpolator.
    MessageInterpolator getDefaultMessageInterpolator()
    {
        return new ResourceBundleMessageInterpolator();
    }

    /// Use `descriptors` for application types (Flint): the table the AOT registry filled.
    HibernateValidatorConfiguration descriptors(DescriptorTable descriptors)
    {
        table = descriptors;
        return this;
    }

    /// Builds the `ValidatorFactory`.
    ValidatorFactory buildValidatorFactory()
    {
        return new ValidatorFactoryImpl(table is null ? DescriptorTable.withBuiltins() : table,
                interpolator is null ? getDefaultMessageInterpolator() : interpolator);
    }
}

// The provider is the default as soon as this module is linked in, as Hibernate's META-INF/services entry makes it.
shared static this()
{
    Validation.registerProvider(new HibernateValidator());
}
