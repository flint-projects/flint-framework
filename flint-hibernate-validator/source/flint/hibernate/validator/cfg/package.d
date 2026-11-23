/*
 * Ported from Hibernate Validator 9.1.6.Final, https://github.com/hibernate/hibernate-validator,
 * tag 9.1.6.Final: engine/src/main/java/org/hibernate/validator/cfg/ConstraintMapping.java and
 * internal/cfg/context/DefaultConstraintMapping.java (constraint definitions only)
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright Red Hat Inc. and Hibernate Authors
 *
 * Modified by the Flint authors: the programmatic mapping covers constraint
 * definitions (validatedBy), which is how a Flint application binds the validators
 * of its own constraints; Java's interface is a final class here.
 */

/// Programmatic constraint configuration: `ConstraintMapping`.
module flint.hibernate.validator.cfg;

import flint.hibernate.validator.cfg.context : ConstraintDefinitionContext;
import flint.hibernate.validator.internal.custom : CustomValidator;

@safe:

/**
 * Represents a constraint mapping configured via the programmatic API:
 * `mapping.constraintDefinition!PetAgeValidation().validatedBy!PetAgeValidator()`.
 */
final class ConstraintMapping
{
    package(flint.hibernate.validator) CustomValidator[] validators;

    /// Starts defining the constraint annotation `A` (Java's `constraintDefinition(Class<A>)`, rulebook R4).
    ConstraintDefinitionContext!A constraintDefinition(A)()
    {
        return new ConstraintDefinitionContext!A(this);
    }
}
