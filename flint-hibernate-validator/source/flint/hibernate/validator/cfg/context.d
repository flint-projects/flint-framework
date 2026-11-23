/*
 * Ported from Hibernate Validator 9.1.6.Final, https://github.com/hibernate/hibernate-validator,
 * tag 9.1.6.Final: engine/src/main/java/org/hibernate/validator/cfg/context/ConstraintDefinitionContext.java
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright Red Hat Inc. and Hibernate Authors
 *
 * Modified by the Flint authors: Class<? extends ConstraintValidator<A, ?>> is a
 * template parameter (rulebook R4); the interface is a final class here.
 */

/// Constraint definitions in the programmatic API.
module flint.hibernate.validator.cfg.context;

import flint.hibernate.validator.cfg : ConstraintMapping;
import flint.hibernate.validator.internal.custom : customValidator;

@safe:

/// Constraint mapping creational context representing a constraint (i.e. annotation type).
final class ConstraintDefinitionContext(A)
{
    private ConstraintMapping mapping;
    private bool includeExisting = true;

    package(flint.hibernate.validator) this(ConstraintMapping mapping) pure nothrow @nogc
    {
        this.mapping = mapping;
    }

    /// Whether the validators declared with `@Constraint(validatedBy)` stay in use; Flint binds validators here.
    ConstraintDefinitionContext includeExistingValidators(bool includeExistingValidators) pure nothrow @nogc
    {
        includeExisting = includeExistingValidators;
        return this;
    }

    /// Adds `V`, an implementation of `ConstraintValidator!(A, T)` with a default constructor, as a validator for `A`.
    ConstraintDefinitionContext validatedBy(V)()
    {
        mapping.validators ~= customValidator!(A, V)();
        return this;
    }
}
