// Ported from spring-framework v7.1.0: spring-context/src/main/java/org/springframework/validation/beanvalidation
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/*
 * Ported from spring-framework v7.1.0, spring-context/src/main/java/org/springframework/validation/beanvalidation/
 * {SpringValidatorAdapter,LocalValidatorFactoryBean,OptionalValidatorFactoryBean}.java. The provider is the one
 * registered with `Validation.registerProvider` (Flint has no ServiceLoader); a configuration initializer customizes
 * the provider's configuration, as Hibernate Validator's descriptor table does in Boot.
 */

/++
`org.springframework.validation.beanvalidation`: adapting a Jakarta Validation `Validator` to Spring's `Validator`
and `Errors`.

`SpringValidatorAdapter` turns each `ConstraintViolation` into a `FieldError` (or an `ObjectError` for a class-level
constraint) whose codes come from the binding result's `MessageCodesResolver` and the constraint's simple name, for
example `NotBlank.owner.name`, `NotBlank.name`, `NotBlank.string`, `NotBlank`.
+/
module flint.validation.beanvalidation;

import flint.beans.factory : DisposableBean, InitializingBean;
import flint.context.support : DefaultMessageSourceResolvable;
import flint.engine.aot.any : Any;
import flint.engine.aot.name : simpleTypeName;
import flint.jakarta.validation : ConstraintViolation, ElementKind, JakartaValidator = Validator,
    MessageInterpolator, ValidationException, Validation, ValidatorFactory, Configuration;
import flint.jakarta.validation.metadata : ConstraintDescriptor;
import flint.java.lang : IllegalStateException, valueOf;
import flint.java.util.function_ : Consumer;
import flint.validation : BindingResult, Errors, FieldError, ObjectError, SmartValidator;

@safe:

/// Adapts a Jakarta `Validator` to Spring's `SmartValidator`, and exposes it as a Jakarta `Validator` too.
class SpringValidatorAdapter : SmartValidator, JakartaValidator
{
    private JakartaValidator targetValidator;

    /// An adapter over `targetValidator`.
    this(JakartaValidator targetValidator)
    {
        imported!"flint.util".Assert.notNull(cast(Object) targetValidator, "Target Validator must not be null");
        this.targetValidator = targetValidator;
    }

    /// An adapter whose target is set later (`LocalValidatorFactoryBean`).
    protected this()
    {
    }

    /// Set the target validator.
    package(flint.validation) final void setTargetValidator(JakartaValidator targetValidator)
    {
        this.targetValidator = targetValidator;
    }

    // Spring's Validator

    /// Every type is supported once a target validator is set.
    bool supports(string)
    {
        return targetValidator !is null;
    }

    /// Validate `target`, registering each violation on `errors`.
    void validate(Any target, Errors errors)
    {
        if (targetValidator !is null)
            processConstraintViolations(targetValidator.validate(target), errors);
    }

    /// Validate `target`; Flint's Jakarta port validates the default group, so the hints are not applied.
    void validate(Any target, Errors errors, Any[])
    {
        validate(target, errors);
    }

    /// Validate `value` as the property `fieldName` of the type named `targetType`; hints are not applied.
    void validateValue(string targetType, string fieldName, Any value, Errors errors, Any[] = null)
    {
        if (targetValidator !is null)
            processConstraintViolations(targetValidator.validateValue(targetType, fieldName, value), errors);
    }

    /// Register each violation on `errors`, unless the field already has a binding failure.
    protected void processConstraintViolations(ConstraintViolation[] violations, Errors errors)
    {
        foreach (violation; violations)
        {
            const field = determineField(violation);
            auto fieldError = errors.getFieldError(field);
            if (fieldError !is null && fieldError.isBindingFailure())
                continue;
            auto descriptor = violation.getConstraintDescriptor();
            const errorCode = determineErrorCode(descriptor);
            auto errorArgs = getArgumentsForConstraint(errors.getObjectName(), field, descriptor);
            if (auto bindingResult = cast(BindingResult) errors)
                addViolationError(bindingResult, violation, field, errorCode, errorArgs);
            else
                errors.rejectValue(field, errorCode, errorArgs, violation.getMessage());
        }
    }

    private void addViolationError(BindingResult bindingResult, ConstraintViolation violation,
            string field, string errorCode, Any[] errorArgs)
    {
        const nestedField = bindingResult.getNestedPath() ~ field;
        if (nestedField.length == 0)
        {
            auto codes = bindingResult.resolveMessageCodes(errorCode);
            bindingResult.addError(new ViolationObjectError(bindingResult.getObjectName(), codes,
                    errorArgs, violation, this));
            return;
        }
        auto rejected = getRejectedValue(field, violation, bindingResult);
        auto codes = bindingResult.resolveMessageCodes(errorCode, field);
        bindingResult.addError(new ViolationFieldError(bindingResult.getObjectName(), nestedField,
                rejected, codes, errorArgs, violation, this));
    }

    /// The Spring field for a violation's property path: `pets[0].name`, without the bean and container nodes.
    protected string determineField(ConstraintViolation violation)
    {
        string result;
        bool first = true;
        foreach (node; violation.getPropertyPath().nodes())
        {
            if (node.isInIterable() && !first)
            {
                result ~= "[";
                if (node.getIndex() >= 0)
                    result ~= valueOf(node.getIndex());
                else if (!node.getKey().isNull)
                    result ~= node.getKey().toString();
                result ~= "]";
            }
            const name = node.getName();
            if (name.length && node.getKind() == ElementKind.PROPERTY && name[0] != '<')
            {
                if (!first)
                    result ~= ".";
                first = false;
                result ~= name;
            }
        }
        return result;
    }

    /// The error code for a constraint: the simple name of its annotation type (`NotBlank`).
    protected string determineErrorCode(ConstraintDescriptor descriptor)
    {
        return simpleTypeName(descriptor.getAnnotationType());
    }

    /// The arguments: the field as a resolvable, then the constraint's attributes in name order.
    protected Any[] getArgumentsForConstraint(string objectName, string field, ConstraintDescriptor descriptor)
    {
        Any[] arguments = [Any.of(getResolvableField(objectName, field))];
        auto names = descriptor.getAttributeNames().dup;
        foreach (i; 1 .. names.length) // insertion sort: a handful of names, without std.algorithm's templates
            for (size_t j = i; j > 0 && names[j] < names[j - 1]; j--)
            {
                const swap = names[j];
                names[j] = names[j - 1];
                names[j - 1] = swap;
            }
        foreach (name; names)
            if (name != "message" && name != "groups" && name != "payload")
                arguments ~= descriptor.getAttribute(name);
        return arguments;
    }

    /// The resolvable for `field`: codes `objectName.field` and `field`, defaulting to the field name.
    protected DefaultMessageSourceResolvable getResolvableField(string objectName, string field)
    {
        return new DefaultMessageSourceResolvable([objectName ~ "." ~ field, field], null, field);
    }

    /// The rejected value: the raw field value when the violation reports its leaf bean or a nested path.
    protected Any getRejectedValue(string field, ConstraintViolation violation, BindingResult bindingResult)
    {
        auto invalidValue = violation.getInvalidValue();
        if (field.length && !contains(field, "[]") && (invalidValue == violation.getLeafBean()
                || contains(field, "[") || contains(field, ".")))
            invalidValue = bindingResult.getRawFieldValue(field);
        return invalidValue;
    }

    /// Whether the message needs `MessageFormat` rendering: it contains a `{0}` placeholder.
    protected bool requiresMessageFormat(ConstraintViolation violation)
    {
        return containsSpringStylePlaceholder(violation.getMessage());
    }

    private static bool containsSpringStylePlaceholder(string message) pure nothrow @nogc
    {
        return contains(message, "{0}");
    }

    private static bool contains(string text, string part) pure nothrow @nogc
    {
        foreach (i; 0 .. text.length + 1 > part.length ? text.length + 1 - part.length : 0)
            if (text[i .. i + part.length] == part)
                return true;
        return false;
    }

    // Jakarta's Validator

    /// Validate `object` with the target validator.
    ConstraintViolation[] validate(Any object)
    {
        return checkedTarget().validate(object);
    }

    /// Validate the property `propertyName` of `object`.
    ConstraintViolation[] validateProperty(Any object, string propertyName)
    {
        return checkedTarget().validateProperty(object, propertyName);
    }

    /// Validate `value` as the property `propertyName` of the type named `beanType`.
    ConstraintViolation[] validateValue(string beanType, string propertyName, Any value)
    {
        return checkedTarget().validateValue(beanType, propertyName, value);
    }

    /// The target validator.
    final JakartaValidator getTargetValidator() pure nothrow @nogc
    {
        return targetValidator;
    }

    private JakartaValidator checkedTarget()
    {
        if (targetValidator is null)
            throw new IllegalStateException("No target Validator set");
        return targetValidator;
    }
}

/// An `ObjectError` wrapping its `ConstraintViolation`.
class ViolationObjectError : ObjectError
{
    private SpringValidatorAdapter adapter;
    private ConstraintViolation violation;

    /// An error from `violation`.
    this(string objectName, string[] codes, Any[] arguments, ConstraintViolation violation,
            SpringValidatorAdapter adapter)
    {
        super(objectName, codes, arguments, violation.getMessage());
        this.adapter = adapter;
        this.violation = violation;
        wrap(cast(Object) violation);
    }

    /// Render the default message when it has `{0}` placeholders.
    override bool shouldRenderDefaultMessage()
    {
        return adapter.requiresMessageFormat(violation);
    }
}

/// A `FieldError` wrapping its `ConstraintViolation`.
class ViolationFieldError : FieldError
{
    private SpringValidatorAdapter adapter;
    private ConstraintViolation violation;

    /// An error on `field` from `violation`.
    this(string objectName, string field, Any rejectedValue, string[] codes, Any[] arguments,
            ConstraintViolation violation, SpringValidatorAdapter adapter)
    {
        super(objectName, field, rejectedValue, false, codes, arguments, violation.getMessage());
        this.adapter = adapter;
        this.violation = violation;
        wrap(cast(Object) violation);
    }

    /// Render the default message when it has `{0}` placeholders.
    override bool shouldRenderDefaultMessage()
    {
        return adapter.requiresMessageFormat(violation);
    }
}

/++
The central bean-validation class in Spring: bootstraps a `ValidatorFactory` from the registered provider and exposes
it as both Spring's and Jakarta's `Validator`.
+/
class LocalValidatorFactoryBean : SpringValidatorAdapter, ValidatorFactory, InitializingBean, DisposableBean
{
    private MessageInterpolator messageInterpolator;
    private Consumer!Configuration configurationInitializer;
    private ValidatorFactory validatorFactory;

    /// Use `messageInterpolator` instead of the provider's default.
    void setMessageInterpolator(MessageInterpolator messageInterpolator)
    {
        this.messageInterpolator = messageInterpolator;
    }

    /// Customize the provider's `Configuration` before the factory is built.
    void setConfigurationInitializer(Consumer!Configuration configurationInitializer)
    {
        this.configurationInitializer = configurationInitializer;
    }

    /// Build the factory from the default provider and set the target validator.
    void afterPropertiesSet()
    {
        auto configuration = Validation.byDefaultProvider();
        if (messageInterpolator !is null)
            configuration.messageInterpolator(messageInterpolator);
        if (configurationInitializer !is null)
            configurationInitializer.accept(configuration);
        postProcessConfiguration(configuration);
        validatorFactory = configuration.buildValidatorFactory();
        setTargetValidator(validatorFactory.getValidator());
    }

    /// A hook for subclasses to customize the configuration.
    protected void postProcessConfiguration(Configuration)
    {
    }

    /// The factory's validator.
    JakartaValidator getValidator()
    {
        return checkedFactory().getValidator();
    }

    /// The factory's message interpolator.
    MessageInterpolator getMessageInterpolator()
    {
        return checkedFactory().getMessageInterpolator();
    }

    /// Close the factory.
    void close()
    {
        if (validatorFactory !is null)
            validatorFactory.close();
    }

    /// Close the factory when the context closes.
    void destroy()
    {
        close();
    }

    private ValidatorFactory checkedFactory()
    {
        if (validatorFactory is null)
            throw new IllegalStateException("No target ValidatorFactory set");
        return validatorFactory;
    }
}

/// A `LocalValidatorFactoryBean` that stays inactive when no Jakarta Validation provider is available.
class OptionalValidatorFactoryBean : LocalValidatorFactoryBean
{
    /// Bootstrap, ignoring a missing or failing provider.
    override void afterPropertiesSet()
    {
        try
            super.afterPropertiesSet();
        catch (ValidationException)
        {
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Method validation. Ported from spring-framework v7.1.0, spring-context/src/main/java/org/springframework/
// validation/beanvalidation/{MethodValidationInterceptor,MethodValidationPostProcessor}.java. Modified by the Flint
// authors: Flint AOT generates the proxies, so the interceptor is the engine-aot `Advisor` that a proxy's advice
// chain runs, and the post-processor is the bean that holds it (no BeanPostProcessor wraps beans at run time). A
// method is its `MethodDescriptor`; only the default group exists; `adaptConstraintViolations` (Spring's
// MethodValidationException) and Reactor arguments are not ported.

/++
`MethodValidationInterceptor`: validates the arguments of a call against the parameter constraints of the method
(`@Min`, `@NotNull`, `@Valid` and the like) before it proceeds, and its return value after, through Jakarta's
`ExecutableValidator`. Violations throw `ConstraintViolationException`.
+/
class MethodValidationInterceptor : imported!"flint.engine.aot.proxy".Advisor
{
    import flint.engine.aot.descriptor : Descriptor, MethodDescriptor;
    import flint.engine.aot.proxy : Invocation, Proceed;

    private JakartaValidator validator;
    private string validatedAnnotationType = "flint.validation.annotation.Validated";
    private int order = int.max;
    private string[const(MethodDescriptor)* ] beanTypes;

    /// With the validator of the default `ValidatorFactory`.
    this()
    {
        this(Validation.buildDefaultValidatorFactory());
    }

    /// With the validator of `validatorFactory`.
    this(ValidatorFactory validatorFactory)
    {
        this(validatorFactory.getValidator());
    }

    /// With `validator`; a `SpringValidatorAdapter` (such as Boot's `LocalValidatorFactoryBean`) is unwrapped
    /// to its target, as Spring's `MethodValidationAdapter` does.
    this(JakartaValidator validator)
    {
        this.validator = validator;
    }

    /// The type-level annotation that marks a bean for method validation; `@Validated` by default.
    final void setValidatedAnnotationType(string validatedAnnotationType)
    {
        if (validatedAnnotationType.length == 0)
            throw new imported!"flint.java.lang".IllegalArgumentException("'validatedAnnotationType' must not be null");
        this.validatedAnnotationType = validatedAnnotationType;
    }

    /// Spring's `AnnotationMatchingPointcut(validatedAnnotationType, true)`: every method of a bean whose type
    /// carries the annotation. Flint AOT merges it onto the bean's descriptor or, for an annotated interface,
    /// onto the methods that implement it.
    bool appliesTo(const Descriptor descriptor, const(MethodDescriptor)* method)
    {
        import flint.engine.aot.descriptor : findAnnotation;

        if (method is null || (findAnnotation(descriptor.annotations, validatedAnnotationType) is null
                && findAnnotation(method.annotations, validatedAnnotationType) is null))
            return false;
        synchronized (this)
            beanTypes[method] = descriptor.name;
        return true;
    }

    /// `Ordered.LOWEST_PRECEDENCE` unless set.
    int getOrder()
    {
        return order;
    }

    /// The advisor order.
    final void setOrder(int order) pure nothrow @nogc
    {
        this.order = order;
    }

    /// Validate the arguments, proceed, then validate the return value. Throws `ConstraintViolationException`.
    void invoke(ref Invocation invocation, scope Proceed proceed)
    {
        import flint.jakarta.validation : ConstraintViolationException;

        string beanType;
        synchronized (this)
        {
            if (auto found = invocation.method in beanTypes)
                beanType = *found;
        }
        auto target = Any.ofObject(invocation.target, beanType.length ? beanType : typeid(invocation.target).name);
        auto executable = executableValidator();
        auto violations = executable.validateParameters(target, invocation.method, invocation.arguments);
        if (violations.length != 0)
            throw new ConstraintViolationException(violations);
        proceed(invocation);
        violations = executable.validateReturnValue(target, invocation.method, invocation.result);
        if (violations.length != 0)
            throw new ConstraintViolationException(violations);
    }

    private imported!"flint.jakarta.validation.executable".ExecutableValidator executableValidator()
    {
        auto target = validator;
        if (auto adapter = cast(SpringValidatorAdapter) target)
            target = adapter.getTargetValidator();
        if (target is null)
            throw new IllegalStateException("No target Validator set");
        return target.forExecutables();
    }
}

/++
`MethodValidationPostProcessor`: method validation for beans whose type carries `@Validated` (or the annotation set
with `setValidatedAnnotationType`). Boot's `ValidationAutoConfiguration` registers it as
`methodValidationPostProcessor`. After `afterPropertiesSet` it is the `Advisor` the generated proxies of those
beans run: a `MethodValidationInterceptor` over the configured validator.
+/
class MethodValidationPostProcessor : imported!"flint.engine.aot.proxy".Advisor, InitializingBean
{
    import flint.engine.aot.descriptor : Descriptor, MethodDescriptor;
    import flint.engine.aot.proxy : Invocation, Proceed;

    private string validatedAnnotationType = "flint.validation.annotation.Validated";
    private JakartaValidator validator;
    private JakartaValidator delegate() @safe validatorProvider;
    private int order = int.max;
    private MethodValidationInterceptor advisor;

    /// The type-level annotation that marks beans for validation, by fully qualified name (R4).
    void setValidatedAnnotationType(string validatedAnnotationType)
    {
        if (validatedAnnotationType.length == 0)
            throw new imported!"flint.java.lang".IllegalArgumentException("'validatedAnnotationType' must not be null");
        this.validatedAnnotationType = validatedAnnotationType;
    }

    /// Validate with the validator of `validatorFactory`.
    void setValidatorFactory(ValidatorFactory validatorFactory)
    {
        validator = validatorFactory.getValidator();
    }

    /// Validate with `validator`.
    void setValidator(JakartaValidator validator)
    {
        this.validator = validator;
    }

    /// Validate with the validator `validatorProvider` returns, asked on first use (Spring's `ObjectProvider`).
    void setValidatorProvider(JakartaValidator delegate() @safe validatorProvider)
    {
        this.validatorProvider = validatorProvider;
    }

    /// Spring adapts violations to `MethodValidationException` when true; Flint does not port it yet, so `true`
    /// throws `UnsupportedOperationException`.
    void setAdaptConstraintViolations(bool adaptViolations)
    {
        if (adaptViolations)
            throw new imported!"flint.java.lang".UnsupportedOperationException(
                    "MethodValidationException is not ported: violations are thrown as ConstraintViolationException");
    }

    /// The advisor order; `Ordered.LOWEST_PRECEDENCE` by default.
    void setOrder(int order)
    {
        this.order = order;
        if (advisor !is null)
            advisor.setOrder(order);
    }

    /// Build the interceptor; with no validator set, the default provider's validator.
    void afterPropertiesSet()
    {
        advisor = createMethodValidationAdvice();
        advisor.setValidatedAnnotationType(validatedAnnotationType);
        advisor.setOrder(order);
    }

    /// The interceptor over the configured validator.
    protected MethodValidationInterceptor createMethodValidationAdvice()
    {
        if (validator !is null)
            return new MethodValidationInterceptor(validator);
        if (validatorProvider !is null)
            return new MethodValidationInterceptor(validatorProvider());
        return new MethodValidationInterceptor();
    }

    /// Whether `method` of a bean described by `descriptor` is validated.
    bool appliesTo(const Descriptor descriptor, const(MethodDescriptor)* method)
    {
        return checkedAdvisor().appliesTo(descriptor, method);
    }

    /// The advisor order.
    int getOrder()
    {
        return order;
    }

    /// Validate the call through the interceptor.
    void invoke(ref Invocation invocation, scope Proceed proceed)
    {
        checkedAdvisor().invoke(invocation, proceed);
    }

    private MethodValidationInterceptor checkedAdvisor()
    {
        if (advisor is null)
            afterPropertiesSet();
        return advisor;
    }
}
