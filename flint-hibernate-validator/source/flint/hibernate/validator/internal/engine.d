/*
 * Ported from Hibernate Validator 9.1.6.Final, https://github.com/hibernate/hibernate-validator,
 * tag 9.1.6.Final: engine/src/main/java/org/hibernate/validator/internal/engine/
 * {ValidatorImpl,ValidatorFactoryImpl,ConstraintViolationImpl}.java, engine/path/{PathImpl,
 * NodeImpl}.java and metadata/descriptor/ConstraintDescriptorImpl.java
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright Red Hat Inc. and Hibernate Authors
 *
 * Modified by the Flint authors: the validator walks Flint AOT descriptors (properties
 * with merged constraint annotations) instead of reflecting over classes; the Default
 * group is the only group until Class-valued annotation elements exist. Violations
 * are returned in property declaration order, a deterministic instance of the Set
 * Hibernate returns.
 */

/// The validation engine: walking descriptors, cascading, and building violations.
module flint.hibernate.validator.internal.engine;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, DescriptorTable, MergedAnnotation, PropertyDescriptor, TypeKind;
import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.internal.constraintvalidators : BuiltinConstraint, PatternCache,
    attributeText, isBuiltin, isValid, javaConstraintName, javaTypeName, read;
import flint.hibernate.validator.internal.custom : ConstraintValidatorContextImpl, CustomValidator;
import flint.jakarta.validation : Constraint, ConstraintViolation, ElementKind, MessageInterpolator,
    Path, UnexpectedTypeException, Valid, ValidationException, Validator, ValidatorFactory;
import flint.jakarta.validation.metadata : ConstraintDescriptor;
import flint.java.util : RawCollection, RawMap;

@safe:

/// A node of a property path.
final class NodeImpl : Path.Node
{
    private string name;
    private bool inIterable;
    private int index = -1;
    private Any key;
    private ElementKind kind;

    ///
    this(string name, ElementKind kind) pure nothrow @nogc
    {
        this.name = name;
        this.kind = kind;
    }

    /// The node name, or null.
    string getName()
    {
        return name;
    }

    /// Whether the node is in an iterable or a map.
    bool isInIterable()
    {
        return inIterable;
    }

    /// The index, or -1.
    int getIndex()
    {
        return index;
    }

    /// The map key, or `Any.init`.
    Any getKey()
    {
        return key;
    }

    /// The element kind.
    ElementKind getKind()
    {
        return kind;
    }

    /// The node as it appears in a path: `name`, `[3]name`, `[key]name`.
    override string toString() const
    {
        import flint.engine.aot.text : decimal;

        string text;
        if (inIterable)
            text = "[" ~ (index >= 0 ? decimal(cast(long) index) : key.isNull() ? "" : key.toString()) ~ "]";
        return name is null ? text : text ~ name;
    }
}

/// Default implementation of `jakarta.validation.Path`.
final class PathImpl : Path
{
    private NodeImpl[] nodeList;

    /// The root path of bean validation: one bean node with no name.
    static PathImpl createRootPath() pure nothrow
    {
        auto path = new PathImpl();
        path.nodeList = [new NodeImpl(null, ElementKind.BEAN)];
        return path;
    }

    private PathImpl copy() pure nothrow
    {
        auto path = new PathImpl();
        path.nodeList = nodeList.dup;
        return path;
    }

    /// A path one property deeper.
    PathImpl addPropertyNode(string propertyName) pure nothrow
    {
        auto path = copy();
        if (path.nodeList.length == 1 && path.nodeList[0].name is null && !path.nodeList[0].inIterable)
            path.nodeList = null;
        path.nodeList ~= new NodeImpl(propertyName, ElementKind.PROPERTY);
        return path;
    }

    /// This path, its next node marked as inside an iterable at `index` (or under `key`).
    PathImpl inIterable(int index, Any key) pure nothrow
    {
        auto path = copy();
        auto marker = new NodeImpl(null, ElementKind.BEAN);
        marker.inIterable = true;
        marker.index = index;
        marker.key = key;
        path.nodeList ~= marker;
        return path;
    }

    /// The nodes from the root, in order.
    Path.Node[] nodes()
    {
        Path.Node[] result;
        foreach (n; nodeList)
            result ~= n;
        return result;
    }

    /// `owner.pets[0].name`: names joined by dots, an iterable position attached to the node after it.
    override string toString() const
    {
        string text;
        bool pendingIterable;
        string position;
        foreach (n; nodeList)
        {
            if (n.name is null && n.inIterable)
            {
                pendingIterable = true;
                position = n.toString();
                continue;
            }
            if (pendingIterable)
            {
                text ~= position;
                pendingIterable = false;
            }
            if (n.name !is null)
                text ~= (text.length ? "." : "") ~ n.name;
        }
        if (pendingIterable)
            text ~= position;
        return text;
    }
}

/// A built-in constraint as metadata.
final class ConstraintDescriptorImpl : ConstraintDescriptor
{
    private BuiltinConstraint constraint;

    ///
    this(BuiltinConstraint constraint) pure nothrow @nogc
    {
        this.constraint = constraint;
    }

    /// The annotation, boxed.
    Any getAnnotation()
    {
        return constraint.annotation;
    }

    /// The annotation's Flint type name.
    string getAnnotationType()
    {
        return constraint.annotationType;
    }

    /// The non-interpolated message.
    string getMessageTemplate()
    {
        return constraint.message;
    }

    /// The element named `name`.
    Any getAttribute(string name)
    {
        import flint.hibernate.validator.internal.el : ElValue;

        if (name == "message")
            return Any.of(constraint.message);
        foreach (a; constraint.attributes)
        {
            if (a.name != name)
                continue;
            final switch (a.value.kind)
            {
            case ElValue.Kind.null_:
                return Any.init;
            case ElValue.Kind.boolean:
                return Any.of(a.value.boolean);
            case ElValue.Kind.number:
                return a.value.integral ? Any.of(cast(long) a.value.number) : Any.of(a.value.number);
            case ElValue.Kind.string_:
                return Any.of(a.value.text);
            }
        }
        return Any.init;
    }

    /// The element names, `message` first.
    string[] getAttributeNames()
    {
        string[] names = ["message"];
        foreach (a; constraint.attributes)
            names ~= a.name;
        return names;
    }

    /// Built-in constraints report each failure on its own.
    bool isReportAsSingleViolation()
    {
        return false;
    }

    /// The constraint read from its annotation.
    const(BuiltinConstraint) builtin() const pure nothrow @nogc
    {
        return constraint;
    }
}

/// The single implementation of `ConstraintViolation`.
final class ConstraintViolationImpl : ConstraintViolation
{
    private string interpolatedMessage;
    private string messageTemplate;
    private Any rootBean;
    private string rootBeanClass;
    private Any leafBean;
    private Path propertyPath;
    private Any value;
    private ConstraintDescriptor descriptor;

    ///
    this(string messageTemplate, string interpolatedMessage, string rootBeanClass, Any rootBean,
            Any leafBean, Any value, Path propertyPath, ConstraintDescriptor descriptor)
    {
        this.messageTemplate = messageTemplate;
        this.interpolatedMessage = interpolatedMessage;
        this.rootBeanClass = rootBeanClass;
        this.rootBean = rootBean;
        this.leafBean = leafBean;
        this.value = value;
        this.propertyPath = propertyPath;
        this.descriptor = descriptor;
    }

    /// The interpolated message.
    string getMessage()
    {
        return interpolatedMessage;
    }

    /// The message template.
    string getMessageTemplate()
    {
        return messageTemplate;
    }

    /// The root bean.
    Any getRootBean()
    {
        return rootBean;
    }

    /// The root bean's Flint type name.
    string getRootBeanClass()
    {
        return rootBeanClass;
    }

    /// The bean holding the failing value.
    Any getLeafBean()
    {
        return leafBean;
    }

    /// The path from the root bean.
    Path getPropertyPath()
    {
        return propertyPath;
    }

    /// The failing value.
    Any getInvalidValue()
    {
        return value;
    }

    /// The failing constraint.
    ConstraintDescriptor getConstraintDescriptor()
    {
        return descriptor;
    }

    /// As Hibernate prints a violation.
    override string toString() const
    {
        return "ConstraintViolationImpl{interpolatedMessage='" ~ interpolatedMessage
            ~ "', propertyPath=" ~ propertyPath.toString() ~ ", rootBeanClass=class "
            ~ rootBeanClass ~ ", messageTemplate='" ~ messageTemplate ~ "'}";
    }
}

/// The interpolation context Hibernate passes to a `MessageInterpolator`.
final class MessageInterpolatorContext : MessageInterpolator.Context
{
    private ConstraintDescriptor descriptor;
    private Any validatedValue;

    ///
    this(ConstraintDescriptor descriptor, Any validatedValue) pure nothrow @nogc
    {
        this.descriptor = descriptor;
        this.validatedValue = validatedValue;
    }

    /// The constraint.
    ConstraintDescriptor getConstraintDescriptor()
    {
        return descriptor;
    }

    /// The validated value.
    Any getValidatedValue()
    {
        return validatedValue;
    }
}

/// Hibernate's `ValidatorFactory`: descriptors, the interpolator and the shared pattern cache.
final class ValidatorFactoryImpl : ValidatorFactory
{
    private DescriptorTable descriptors;
    private MessageInterpolator interpolator;
    private PatternCache patterns;
    private CustomValidator[][string] custom;

    ///
    this(DescriptorTable descriptors, MessageInterpolator interpolator)
    {
        this.descriptors = descriptors;
        this.interpolator = interpolator;
        patterns = new PatternCache();
    }

    /// Bind a user-defined constraint validator (from a `ConstraintMapping`).
    void bind(CustomValidator validator)
    {
        custom[validator.annotationType] ~= validator;
    }

    /// A validator; validators share the factory's state and are thread-safe.
    Validator getValidator()
    {
        return new ValidatorImpl(this);
    }

    /// The configured interpolator.
    MessageInterpolator getMessageInterpolator()
    {
        return interpolator;
    }

    /// Nothing to release.
    void close()
    {
    }
}

/// Hibernate's `Validator`: validates beans through their descriptors, cascading through `@Valid`.
final class ValidatorImpl : Validator
{
    alias validate = Validator.validate;
    alias validateProperty = Validator.validateProperty;

    private ValidatorFactoryImpl factory;

    private this(ValidatorFactoryImpl factory) pure nothrow @nogc
    {
        this.factory = factory;
    }

    /// Validate `object` and everything reachable through `@Valid`.
    ConstraintViolation[] validate(Any object)
    {
        if (object.isNull())
            throw new IllegalArgument("HV000116: The object to be validated must not be null.");
        auto run = Run(factory, object, object.typeName());
        run.validateBean(object, PathImpl.createRootPath(), null);
        return run.violations;
    }

    /// Validate the constraints of one property of `object`, without cascading.
    ConstraintViolation[] validateProperty(Any object, string propertyName)
    {
        if (object.isNull())
            throw new IllegalArgument("HV000116: The object to be validated must not be null.");
        auto run = Run(factory, object, object.typeName());
        auto d = run.descriptorOf(object.typeName());
        auto property = d.property(propertyName);
        if (property is null)
            throw new IllegalArgument("HV000039: Invalid property path. There is no property "
                    ~ propertyName ~ " in entity " ~ object.typeName() ~ ".");
        auto value = property.get(object);
        run.checkConstraints(object, value, property.annotations, PathImpl.createRootPath()
                .addPropertyNode(propertyName));
        return run.violations;
    }

    /// Validate `value` against the constraints of property `propertyName` of the type named `beanType`.
    ConstraintViolation[] validateValue(string beanType, string propertyName, Any value)
    {
        auto run = Run(factory, Any.init, beanType);
        auto d = run.descriptorOf(beanType);
        auto property = d.property(propertyName);
        if (property is null)
            throw new IllegalArgument(
                    "HV000039: Invalid property path. There is no property " ~ propertyName
                    ~ " in entity " ~ beanType ~ ".");
        run.checkConstraints(Any.init, value, property.annotations, PathImpl.createRootPath()
                .addPropertyNode(propertyName));
        return run.violations;
    }
}

private class IllegalArgument : ValidationException
{
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, null, file, line);
    }
}

// One validation call: the root, the violations found so far and the beans already visited.
private struct Run
{
    ValidatorFactoryImpl factory;
    Any root;
    string rootType;
    ConstraintViolation[] violations;
    bool[Object] visited;

    this(ValidatorFactoryImpl factory, Any root, string rootType)
    {
        this.factory = factory;
        this.root = root;
        this.rootType = rootType;
    }

    const(Descriptor) descriptorOf(string type)
    {
        auto d = factory.descriptors is null ? null : factory.descriptors.find(type);
        if (d is null)
            throw new ValidationException("HV000043: Unable to find a Flint AOT descriptor for type "
                    ~ type ~ ": register it, or let Flint AOT generate it.");
        return d;
    }

    void validateBean(ref Any bean, PathImpl path, scope const(char)[] declaredType)
    {
        if (auto o = bean.asObject())
        {
            // Cycles: a bean is validated once per call, as Hibernate's processed-beans tracking does.
            if (o in visited)
                return;
            visited[o] = true;
        }
        const type = bean.typeName().length ? bean.typeName() : declaredType.idup;
        auto d = factory.descriptors is null ? null : factory.descriptors.find(type);
        if (d is null || (d.kind != TypeKind.struct_ && d.kind != TypeKind.class_))
            return;
        foreach (ref property; d.properties)
        {
            if (property.get is null)
                continue;
            auto value = property.get(bean);
            auto at = path.addPropertyNode(property.name);
            checkConstraints(bean, value, property.annotations, at);
            if (findAnnotation(property.annotations, typeNameOf!Valid) && !value.isNull())
                cascade(value, at, property.type);
        }
    }

    void cascade(ref Any value, PathImpl at, string declaredType)
    {
        if (cascadeDescribed(value, at))
            return;
        if (auto collection = cast(RawCollection) value.asObject())
        {
            foreach (i, element; collection.toAnyArray())
                if (!element.isNull())
                    validateBean(element, at.inIterable(cast(int) i, Any.init), null);
            return;
        }
        if (auto map = cast(RawMap) value.asObject())
        {
            foreach (key; map.keysAsAny())
            {
                auto element = map.getAny(key);
                if (!element.isNull())
                    validateBean(element, at.inIterable(-1, key), null);
            }
            return;
        }
        validateBean(value, at, declaredType);
    }

    // Arrays and associative arrays cascade into their elements, Optional into its value, through the descriptor
    // thunks; Hibernate's value extractors for arrays, Map values and Optional.
    bool cascadeDescribed(ref Any value, PathImpl at)
    {
        auto d = described(value);
        if (d is null)
            return false;
        if (d.unwrap !is null)
        {
            auto inner = d.unwrap(value);
            if (!inner.isNull())
                validateBean(inner, at, d.elementType);
        }
        else if (d.length !is null && d.element !is null && d.kind == TypeKind.array)
        {
            foreach (i; 0 .. d.length(value))
            {
                auto element = d.element(value, i);
                if (!element.isNull())
                    validateBean(element, at.inIterable(cast(int) i, Any.init), d.elementType);
            }
        }
        else if (d.toKeys !is null && d.toValues !is null)
        {
            auto keys = d.toKeys(value);
            auto values = d.toValues(value);
            foreach (i, ref element; values)
                if (!element.isNull())
                    validateBean(element, at.inIterable(-1, keys[i]), d.elementType);
        }
        else
            return false;
        return true;
    }

    const(Descriptor) described(ref Any value)
    {
        return factory.descriptors is null || value.typeName().length == 0
            ? null : factory.descriptors.find(value.typeName());
    }

    void checkConstraints(Any leaf, ref Any value, scope const(MergedAnnotation)[] annotations, PathImpl at)
    {
        foreach (ref a; annotations)
        {
            if (isBuiltin(a.type))
            {
                auto constraint = read(a.type, a.value);
                if (!isValid(constraint, value, factory.patterns, at.toString(), described(value)))
                    report(leaf, value, at, constraint, [constraint.message]);
            }
            else if (auto bound = a.type in factory.custom)
                checkCustom(leaf, value, a, *bound, at);
            else
                requireBinding(a.type, value, at);
        }
    }

    // SimpleConstraintTree: run the bound validator that accepts the value's type, then report the default and the
    // built templates.
    void checkCustom(Any leaf, ref Any value, ref const MergedAnnotation a, CustomValidator[] bound, PathImpl at)
    {
        CustomValidator chosen;
        foreach (candidate; bound)
        {
            if (value.isNull() || candidate.accepts(value))
            {
                chosen = candidate;
                break;
            }
        }
        if (chosen.run is null)
            throw unexpectedType(a.type, value, at);
        auto constraint = chosen.read(a.value);
        auto context = new ConstraintValidatorContextImpl(constraint.message);
        if (!chosen.run(constraint.annotation, value, context))
            report(leaf, value, at, constraint, context.violationTemplates());
    }

    // An annotation whose descriptor carries @Constraint but has no bound validator: Hibernate would instantiate
    // `validatedBy`, which Flint never does from a class name.
    void requireBinding(string annotationType, ref Any value, PathImpl at)
    {
        auto d = factory.descriptors is null ? null : factory.descriptors.find(annotationType);
        if (d !is null && findAnnotation(d.annotations, typeNameOf!Constraint))
            throw unexpectedType(annotationType, value, at);
    }

    UnexpectedTypeException unexpectedType(string annotationType, ref Any value, PathImpl at)
    {
        const constraint = javaConstraintName(annotationType), type = javaTypeName(value.typeName());
        return new UnexpectedTypeException("HV000030: No validator could be found for constraint '"
                ~ constraint ~ "' validating type '" ~ type ~ "'. Check configuration for '" ~ at.toString() ~ "'");
    }

    void report(Any leaf, ref Any value, PathImpl at, BuiltinConstraint constraint, string[] templates)
    {
        auto descriptor = new ConstraintDescriptorImpl(constraint);
        foreach (messageTemplate; templates)
        {
            const message = factory.interpolator.interpolate(messageTemplate,
                    new MessageInterpolatorContext(descriptor, value));
            violations ~= new ConstraintViolationImpl(messageTemplate, message, rootType, root,
                    leaf, value, at, descriptor);
        }
    }
}

private bool findAnnotation(scope const(MergedAnnotation)[] annotations, string type) pure nothrow @nogc
{
    foreach (ref a; annotations)
        if (a.type == type)
            return true;
    return false;
}
