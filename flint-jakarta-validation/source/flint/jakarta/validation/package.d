/*
 * Ported from Jakarta Validation API 3.1.1 (jakarta.validation-api), https://github.com/jakartaee/validation,
 * tag 3.1.1: src/main/java/jakarta/validation/{Valid,Validator,ValidatorFactory,Validation,
 * Configuration,ConstraintViolation,ConstraintValidator,ConstraintValidatorContext,Path,
 * ElementKind,MessageInterpolator,ValidationException,ConstraintViolationException,
 * ConstraintDeclarationException,ConstraintDefinitionException,UnexpectedTypeException,
 * NoProviderFoundException,GroupDefinitionException,Payload}.java and spi/ValidationProvider.java
 *
 * Jakarta Validation API
 * License: Apache License, Version 2.0
 *
 * Modified by the Flint authors: translated to D (rulebook v2). Generic types are
 * erased (ConstraintViolation<T> is ConstraintViolation; beans and values are Any,
 * classes are Flint type names, R4); `validate` has an (T) façade over the erased
 * method. Providers are registered instead of found by ServiceLoader
 * (deviation D-VALIDATION-1 in docs/spring/phase1/third-party.md).
 */

/// Jakarta Validation: validators, factories, violations and paths.
module flint.jakarta.validation;

import flint.engine.aot.any : Any;
import flint.jakarta.validation.metadata : ConstraintDescriptor;
import flint.java.lang : RuntimeException;

@safe:

/**
 * Marks a property, method parameter or method return type for validation
 * cascading. Constraints defined on the object and its properties are validated
 * when the property, method parameter or method return type is validated.
 */
struct Valid
{
}

/// Payload type that can be attached to a given constraint declaration.
interface Payload
{
}

/// Enum of possible kinds of elements encountered in Jakarta Validation.
enum ElementKind
{
    /// A Java Bean.
    BEAN,
    /// A property of a Java Bean.
    PROPERTY,
    /// A method.
    METHOD,
    /// A constructor.
    CONSTRUCTOR,
    /// A parameter of a method or constructor.
    PARAMETER,
    /// Element holding cross-parameter constraints of a method or constructor.
    CROSS_PARAMETER,
    /// The return value of a method or constructor.
    RETURN_VALUE,
    /// An element stored in a container such as a collection, a map or an `Optional`.
    CONTAINER_ELEMENT,
}

/**
 * Represents the navigation path from an object to another in an object graph.
 * Each path element is represented by a `Node`. The path corresponds to the
 * succession of nodes in the order they are returned by the iteration.
 */
interface Path
{
    /// Represents an element of a navigation path.
    interface Node
    {
        /// Returns the name of the element which the node represents, or null for a bean or a container element without a name.
        string getName();

        /// Whether the node is in an `Iterable` or a `Map`.
        bool isInIterable();

        /// The index the node is placed in when it is in an indexed iterable, or -1 (Java's null `Integer`).
        int getIndex();

        /// The key the node is placed in when it is in a `Map`, or `Any.init`.
        Any getKey();

        /// The kind of element represented by the node.
        ElementKind getKind();
    }

    /// The nodes from the root, in order (Java's `Iterable<Node>`).
    Node[] nodes();

    /// A string representation of the path, as `owner.pets[0].name`.
    string toString() const;
}

/**
 * Describes a constraint violation. This object exposes the constraint
 * violation context as well as the message describing the violation.
 */
interface ConstraintViolation
{
    /// Returns the interpolated error message for this constraint violation.
    string getMessage();

    /// Returns the non-interpolated error message for this constraint violation.
    string getMessageTemplate();

    /// Returns the root bean being validated, boxed; `Any.init` for method and value validation.
    Any getRootBean();

    /// Returns the Flint type name of the root bean being validated (Java's `getRootBeanClass()`).
    string getRootBeanClass();

    /// Returns the bean instance the constraint is applied on, boxed.
    Any getLeafBean();

    /// Returns the property path to the value from `rootBean`.
    Path getPropertyPath();

    /// Returns the value failing to pass the constraint, boxed.
    Any getInvalidValue();

    /// Returns the constraint metadata reported to fail.
    ConstraintDescriptor getConstraintDescriptor();
}

/**
 * Interpolates a given constraint violation message.
 */
interface MessageInterpolator
{
    /// Information related to the interpolation context.
    interface Context
    {
        /// Returns the ConstraintDescriptor corresponding to the constraint being validated.
        ConstraintDescriptor getConstraintDescriptor();

        /// Returns the value being validated, boxed.
        Any getValidatedValue();
    }

    /// Interpolates the message template based on the constraint validation context.
    string interpolate(string messageTemplate, Context context);
}

/**
 * Validates bean instances. Implementations of this interface must be
 * thread-safe.
 */
interface Validator
{
    /// Validates all constraints on `object`, cascading through `@Valid`; the erased form of `validate(T object)`.
    ConstraintViolation[] validate(Any object);

    /// Validates all constraints placed on the property of `object` named `propertyName`.
    ConstraintViolation[] validateProperty(Any object, string propertyName);

    /// Validates all constraints placed on the property `propertyName` of the type named `beanType` were it to have `value`.
    ConstraintViolation[] validateValue(string beanType, string propertyName, Any value);

    /// Validates all constraints on `object` (R4: one façade over the erased `validate(Any)`).
    ConstraintViolation[] validate(T)(T object) if (!is(T == Any))
    {
        return validate(Any.of(object));
    }

    /// Validates the property `propertyName` of `object`.
    ConstraintViolation[] validateProperty(T)(T object, string propertyName) if (!is(T == Any))
    {
        return validateProperty(Any.of(object), propertyName);
    }
}

/**
 * Factory returning initialized `Validator` instances. Implementations are
 * thread-safe and instances should be cached.
 */
interface ValidatorFactory
{
    /// Returns an initialized `Validator` instance using the factory defaults.
    Validator getValidator();

    /// Returns the `MessageInterpolator` instance configured at initialization time for the factory.
    MessageInterpolator getMessageInterpolator();

    /// Closes the factory and releases all resources associated with it.
    void close();
}

/// Receives configuration information, selects the appropriate Jakarta Validation provider and builds the appropriate `ValidatorFactory`.
interface Configuration
{
    /// Defines the message interpolator used; null restores the provider's default.
    Configuration messageInterpolator(MessageInterpolator interpolator);

    /// Returns an implementation of the `MessageInterpolator` interface following the default `MessageInterpolator` defined in the specification.
    MessageInterpolator getDefaultMessageInterpolator();

    /// Builds a `ValidatorFactory` implementation.
    ValidatorFactory buildValidatorFactory();
}

/**
 * Defines the logic used to validate a given constraint `A` for a given object
 * type `T`. Implementations must comply to the following restriction: `T` must
 * resolve to a non parameterized type.
 */
interface ConstraintValidator(A, T)
{
    /// Initializes the validator in preparation for `isValid` calls.
    void initialize(A constraintAnnotation);

    /// Implements the validation logic. The state of `value` must not be altered.
    bool isValid(T value, ConstraintValidatorContext context);
}

/// Provides contextual data and operation when applying a given constraint validator.
interface ConstraintValidatorContext
{
    /// Disables the default `ConstraintViolation` object generation (which is using the message template declared on the constraint).
    void disableDefaultConstraintViolation();

    /// The current un-interpolated default message.
    string getDefaultConstraintMessageTemplate();

    /// Adds a violation with `messageTemplate` at the current path (Java's `buildConstraintViolationWithTemplate(t).addConstraintViolation()`).
    void addConstraintViolation(string messageTemplate);
}

/// Base exception of all Jakarta Validation "unexpected" problems.
class ValidationException : RuntimeException
{
    ///
    this(string message = null, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}

/// Reports the result of constraint violations.
class ConstraintViolationException : ValidationException
{
    private ConstraintViolation[] constraintViolations;

    /// Creates a constraint violation report.
    this(string message, ConstraintViolation[] constraintViolations) pure nothrow
    {
        super(message);
        this.constraintViolations = constraintViolations;
    }

    /// Creates a constraint violation report, with a message listing every violation as `path: message`.
    this(ConstraintViolation[] constraintViolations)
    {
        string text;
        foreach (i, v; constraintViolations)
            text ~= (i ? ", " : "") ~ v.getPropertyPath().toString() ~ ": " ~ v.getMessage();
        this(constraintViolations.length ? text : null, constraintViolations);
    }

    /// Returns the set of constraint violations reported during a validation.
    ConstraintViolation[] getConstraintViolations() pure nothrow @nogc
    {
        return constraintViolations;
    }
}

/// Exception raised if a constraint declaration is not legal.
class ConstraintDeclarationException : ValidationException
{
    ///
    this(string message = null, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}

/// Exception raised if a constraint definition is not legal.
class ConstraintDefinitionException : ValidationException
{
    ///
    this(string message = null, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}

/// Exception raised in the case that the constraint validator resolution cannot determine a suitable validator for a given type.
class UnexpectedTypeException : ConstraintDeclarationException
{
    ///
    this(string message = null, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}

/// Exception raised if a group definition is not legal.
class GroupDefinitionException : ValidationException
{
    ///
    this(string message = null, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}

/// Exception raised if no Jakarta Validation provider could be found.
class NoProviderFoundException : ValidationException
{
    ///
    this(string message = null, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}

/**
 * This class is the entry point for Jakarta Validation. Java finds the
 * provider with `ServiceLoader`; Flint's closed world registers it
 * (`registerProvider`), which Hibernate Validator's port does when it is
 * linked in.
 */
final class Validation
{
    private this()
    {
    }

    /// Builds and returns a `ValidatorFactory` instance based on the default Jakarta Validation provider.
    static ValidatorFactory buildDefaultValidatorFactory()
    {
        return byDefaultProvider().buildValidatorFactory();
    }

    /// Builds a `Configuration` of the default provider.
    static Configuration byDefaultProvider()
    {
        import flint.jakarta.validation.spi : registeredProvider;

        auto provider = registeredProvider();
        if (provider is null)
            throw new NoProviderFoundException("Unable to create a Configuration, because no Jakarta Validation "
                    ~ "provider could be found. Add a provider like Hibernate Validator (RI) to your classpath.");
        return provider.createGenericConfiguration();
    }

    /// Register `provider` as the default provider (Flint's replacement for `ServiceLoader` discovery).
    static void registerProvider(Object provider)
    {
        import flint.jakarta.validation.spi : ValidationProvider, setProvider;

        auto validationProvider = cast(ValidationProvider) provider;
        if (validationProvider is null)
            throw new ValidationException("not a ValidationProvider");
        setProvider(validationProvider);
    }
}
