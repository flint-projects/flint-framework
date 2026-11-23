/*
 * Ported from Jakarta Validation API 3.1.1 (jakarta.validation-api), https://github.com/jakartaee/validation,
 * tag 3.1.1: src/main/java/jakarta/validation/groups/Default.java
 *
 * Jakarta Validation API
 * License: Apache License, Version 2.0
 *
 * Modified by the Flint authors: translated to D (rulebook v2).
 */

/// Validation groups.
module flint.jakarta.validation.groups;

@safe:

/**
 * Default Jakarta Validation group.
 *
 * Unless a list of groups is explicitly defined: constraints belong to the
 * `Default` group and validation applies to the `Default` group. Most
 * structural constraints should belong to the default group.
 */
interface Default
{
}
