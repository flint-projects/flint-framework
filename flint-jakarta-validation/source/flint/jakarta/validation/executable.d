/*
 * Ported from Jakarta Validation API 3.1.1 (jakarta.validation-api), https://github.com/jakartaee/validation,
 * tag 3.1.1: src/main/java/jakarta/validation/executable/ExecutableValidator.java
 *
 * Jakarta Validation API
 * License: Apache License, Version 2.0
 *
 * Modified by the Flint authors: translated to D (rulebook v2). A method is its Flint AOT `MethodDescriptor`
 * (parameters with their merged constraint annotations) instead of a reflected `java.lang.reflect.Method`;
 * the object and the values are boxed (`Any`). Only the default group exists, so there is no `groups`
 * parameter, and constructors are not validated (`validateConstructorParameters` and
 * `validateConstructorReturnValue` wait for constructor descriptors with return-value constraints).
 */

/// Validating the parameters and return values of methods.
module flint.jakarta.validation.executable;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : MethodDescriptor;
import flint.jakarta.validation : ConstraintViolation;

@safe:

/// Validates parameters and return values of methods and constructors.
interface ExecutableValidator
{
    /// Validates all constraints placed on the parameters of `method` of `object`, cascading through `@Valid`.
    /// `parameterValues` are in the parameters' order.
    ConstraintViolation[] validateParameters(Any object, scope const(MethodDescriptor)* method, Any[] parameterValues);

    /// Validates all return value constraints of `method` of `object`, cascading through a `@Valid` method.
    ConstraintViolation[] validateReturnValue(Any object, scope const(MethodDescriptor)* method, Any returnValue);
}
