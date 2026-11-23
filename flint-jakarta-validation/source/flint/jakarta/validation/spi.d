/*
 * Ported from Jakarta Validation API 3.1.1 (jakarta.validation-api), https://github.com/jakartaee/validation,
 * tag 3.1.1: src/main/java/jakarta/validation/spi/ValidationProvider.java
 *
 * Jakarta Validation API
 * License: Apache License, Version 2.0
 *
 * Modified by the Flint authors: translated to D (rulebook v2); the provider slot
 * replaces ServiceLoader discovery (deviation D-VALIDATION-1).
 */

/// The provider contract.
module flint.jakarta.validation.spi;

import flint.conc.slot : ProcessSlot;
import flint.jakarta.validation : Configuration;

@safe:

/// Contract between the validation bootstrap mechanism and the provider engine.
interface ValidationProvider
{
    /// Returns a `Configuration` instance implementing the provider's defaults.
    Configuration createGenericConfiguration();
}

private shared ProcessSlot!ValidationProvider provider;

/// The registered provider, or null.
ValidationProvider registeredProvider() nothrow @nogc
{
    return provider.get();
}

/// Register the default provider, replacing any earlier one.
void setProvider(ValidationProvider p) nothrow @nogc
{
    provider.set(p);
}
