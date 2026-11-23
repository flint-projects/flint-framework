// Ported from spring-framework v7.1.0: spring-context/src/main/java/org/springframework/validation
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/*
 * Ported from spring-framework v7.1.0, spring-context/src/main/java/org/springframework/validation/{Errors,
 * AbstractErrors,BindingResult,AbstractBindingResult,BeanPropertyBindingResult,MapBindingResult,BindException,
 * ObjectError,FieldError,MessageCodesResolver,MessageCodeFormatter,DefaultMessageCodesResolver,Validator,
 * SmartValidator,ValidationUtils}.java. Object-typed values are flint.engine.aot.any.Any; bean properties are read
 * through Flint AOT descriptors instead of BeanWrapper reflection; Class-typed parameters are type names (R4).
 */

/++
`org.springframework.validation`: errors, binding results and Spring's `Validator`.

`Errors` keeps Java's methods; its default methods are implemented once in `AbstractErrors` (rule R3), which every
Flint implementation extends. `BeanPropertyBindingResult` reads field values through the target's Flint AOT
descriptor (nested paths through the descriptor table), so rejected values and `getFieldValue` work without
reflection.
+/
module flint.validation;

import flint.context : MessageSourceResolvable;
import flint.context.support : DefaultMessageSourceResolvable;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, DescriptorTable;
import flint.java.lang : IllegalArgumentException, IllegalStateException, RuntimeException,
    UnsupportedOperationException, valueOf;
import flint.java.util : ArrayList, Collections, List, Map;
import flint.java.util.function_ : Function;
import flint.util : Assert, StringUtils;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Errors

/// An error on an object: codes, arguments and a default message (Spring's `ObjectError`).
class ObjectError : DefaultMessageSourceResolvable
{
    private string objectName;
    private Object source;

    /// An error on `objectName` with `defaultMessage`.
    this(string objectName, string defaultMessage)
    {
        this(objectName, null, null, defaultMessage);
    }

    /// An error on `objectName`.
    this(string objectName, string[] codes, Any[] arguments, string defaultMessage)
    {
        super(codes, arguments, defaultMessage);
        Assert.notNull(objectName, "Object name must not be null");
        this.objectName = objectName;
    }

    /// The name of the affected object.
    string getObjectName() const pure nothrow @nogc
    {
        return objectName;
    }

    /// Record the source behind this error (a `ConstraintViolation`, a `TypeMismatchException`).
    void wrap(Object source)
    {
        if (this.source !is null)
            throw new IllegalStateException("Already wrapping " ~ valueOf(this.source));
        this.source = source;
    }

    /// The source of type `T`, or of its cause. Throws `IllegalArgumentException` when there is none.
    T unwrap(T)()
    {
        if (auto found = cast(T) source)
            return found;
        throw new IllegalArgumentException(
                "No source object of the given type available: " ~ imported!"flint.engine.aot.name".typeNameOf!T);
    }

    /// Whether the source is a `T`.
    bool contains(T)()
    {
        return cast(T) source !is null;
    }

    /// Equal class, resolvable parts and object name.
    override bool opEquals(Object other)
    {
        auto that = cast(ObjectError) other;
        return that !is null && super.opEquals(other) && that.objectName == objectName;
    }

    /// Hash including the object name.
    override size_t toHash() nothrow
    {
        return 29 * super.toHash() + hashOf(objectName);
    }

    /// `Error in object 'name': codes [...]; arguments [...]; default message [...]`.
    override string toString()
    {
        return "Error in object '" ~ objectName ~ "': " ~ resolvableToString();
    }
}

/// An error on a field of an object (Spring's `FieldError`).
class FieldError : ObjectError
{
    private string field;
    private Any rejectedValue;
    private bool bindingFailure;

    /// An error on `field` of `objectName` with `defaultMessage`.
    this(string objectName, string field, string defaultMessage)
    {
        this(objectName, field, Any.init, false, null, null, defaultMessage);
    }

    /// An error on `field` of `objectName`, rejecting `rejectedValue`.
    this(string objectName, string field, Any rejectedValue, bool bindingFailure, string[] codes,
            Any[] arguments, string defaultMessage)
    {
        super(objectName, codes, arguments, defaultMessage);
        Assert.notNull(field, "Field must not be null");
        this.field = field;
        this.rejectedValue = rejectedValue;
        this.bindingFailure = bindingFailure;
    }

    /// The affected field.
    string getField() const pure nothrow @nogc
    {
        return field;
    }

    /// The rejected value.
    Any getRejectedValue() pure nothrow @nogc
    {
        return rejectedValue;
    }

    /// Whether this is a binding failure (a type mismatch) rather than a validation failure.
    bool isBindingFailure() const pure nothrow @nogc
    {
        return bindingFailure;
    }

    /// Equal error, field, rejected value and binding-failure flag.
    override bool opEquals(Object other)
    {
        auto that = cast(FieldError) other;
        return that !is null && super.opEquals(other) && that.field == field
            && that.rejectedValue == rejectedValue && that.bindingFailure == bindingFailure;
    }

    /// Hash including the field.
    override size_t toHash() nothrow
    {
        return 29 * (29 * super.toHash() + hashOf(field)) + (bindingFailure ? 1 : 0);
    }

    /// `Field error in object 'o' on field 'f': rejected value [v]; codes [...]; ...`.
    override string toString()
    {
        return "Field error in object '" ~ getObjectName() ~ "' on field '" ~ field
            ~ "': rejected value [" ~ rejectedValue.toString() ~ "]; " ~ resolvableToString();
    }
}

/// Stores and exposes information about data-binding and validation errors for a specific object.
interface Errors
{
    /// The separator between path elements in a nested path.
    enum NESTED_PATH_SEPARATOR = ".";

    /// The name of the bound root object.
    string getObjectName();
    /// Set the nested path (the prefix of field names).
    void setNestedPath(string nestedPath);
    /// The current nested path.
    string getNestedPath();
    /// Push `subPath` onto the nested path stack.
    void pushNestedPath(string subPath);
    /// Pop the previous nested path. Throws `IllegalStateException` when the stack is empty.
    void popNestedPath();
    /// Register a global error for the whole target object.
    void reject(string errorCode);
    /// Register a global error with a default message.
    void reject(string errorCode, string defaultMessage);
    /// Register a global error with arguments and a default message.
    void reject(string errorCode, Any[] errorArgs, string defaultMessage);
    /// Register a field error for `field` of the current object.
    void rejectValue(string field, string errorCode);
    /// Register a field error with a default message.
    void rejectValue(string field, string errorCode, string defaultMessage);
    /// Register a field error with arguments and a default message.
    void rejectValue(string field, string errorCode, Any[] errorArgs, string defaultMessage);
    /// Add every error of `errors` (which must have the same object name).
    void addAllErrors(Errors errors);
    /// Whether there are errors.
    bool hasErrors();
    /// The number of errors.
    int getErrorCount();
    /// Every error, global and field.
    List!ObjectError getAllErrors();
    /// Whether there are global errors.
    bool hasGlobalErrors();
    /// The number of global errors.
    int getGlobalErrorCount();
    /// The global errors.
    List!ObjectError getGlobalErrors();
    /// The first global error, or null.
    ObjectError getGlobalError();
    /// Whether there are field errors.
    bool hasFieldErrors();
    /// The number of field errors.
    int getFieldErrorCount();
    /// The field errors.
    List!FieldError getFieldErrors();
    /// The first field error, or null.
    FieldError getFieldError();
    /// Whether `field` has errors.
    bool hasFieldErrors(string field);
    /// The number of errors on `field`.
    int getFieldErrorCount(string field);
    /// The errors on `field`.
    List!FieldError getFieldErrors(string field);
    /// The first error on `field`, or null.
    FieldError getFieldError(string field);
    /// The current value of `field`: the rejected value when it has an error.
    Any getFieldValue(string field);
    /// The type name of `field`, or null.
    string getFieldType(string field);

    /// Throw the exception made from this object's summary when there are errors.
    final void failOnError(Function!(string, RuntimeException) messageToException)
    {
        if (hasErrors())
            throw messageToException.apply(valueOf(cast(Object) this));
    }
}

/// Implements the default methods of `Errors` and the nested-path stack (Spring's `AbstractErrors`).
abstract class AbstractErrors : Errors
{
    private string nestedPath = "";
    private string[] nestedPathStack;

    /// Set the nested path.
    void setNestedPath(string nestedPath)
    {
        doSetNestedPath(nestedPath);
        nestedPathStack = null;
    }

    /// The nested path.
    string getNestedPath()
    {
        return nestedPath;
    }

    /// Push a sub-path.
    void pushNestedPath(string subPath)
    {
        nestedPathStack ~= nestedPath;
        doSetNestedPath(nestedPath ~ subPath);
    }

    /// Pop the previous nested path.
    void popNestedPath()
    {
        if (nestedPathStack.length == 0)
            throw new IllegalStateException("Cannot pop nested path: no nested path on stack");
        doSetNestedPath(nestedPathStack[$ - 1]);
        nestedPathStack = nestedPathStack[0 .. $ - 1];
    }

    /// Set the nested path, appending the separator when it is not empty.
    protected void doSetNestedPath(string path)
    {
        string canonical = path is null ? "" : canonicalFieldName(path);
        if (canonical.length && canonical[$ - 1 .. $] != NESTED_PATH_SEPARATOR)
            canonical ~= NESTED_PATH_SEPARATOR;
        nestedPath = canonical;
    }

    /// The nested path prepended to `field`.
    protected string fixedField(string field)
    {
        if (StringUtils.hasLength(field))
            return nestedPath ~ canonicalFieldName(field);
        const path = nestedPath;
        return path.length && path[$ - 1 .. $] == NESTED_PATH_SEPARATOR ? path[0 .. $ - 1] : path;
    }

    /// The canonical name of `field` (no change by default).
    protected string canonicalFieldName(string field)
    {
        return field;
    }

    /// Register a global error.
    void reject(string errorCode)
    {
        reject(errorCode, null, null);
    }

    /// Register a global error with a default message.
    void reject(string errorCode, string defaultMessage)
    {
        reject(errorCode, null, defaultMessage);
    }

    /// Register a global error with arguments and a default message.
    abstract void reject(string errorCode, Any[] errorArgs, string defaultMessage);

    /// Register a field error.
    void rejectValue(string field, string errorCode)
    {
        rejectValue(field, errorCode, null, null);
    }

    /// Register a field error with a default message.
    void rejectValue(string field, string errorCode, string defaultMessage)
    {
        rejectValue(field, errorCode, null, defaultMessage);
    }

    /// Register a field error with arguments and a default message.
    abstract void rejectValue(string field, string errorCode, Any[] errorArgs, string defaultMessage);

    /// The global errors.
    abstract List!ObjectError getGlobalErrors();

    /// The field errors.
    abstract List!FieldError getFieldErrors();

    /// Every error: the global errors, then the field errors.
    List!ObjectError getAllErrors()
    {
        ObjectError[] result = getGlobalErrors().toArray();
        foreach (error; getFieldErrors().toArray())
            result ~= error;
        return Collections.unmodifiableList!ObjectError(new ArrayList!ObjectError(result));
    }

    /// The first global error, or null.
    ObjectError getGlobalError()
    {
        auto errors = getGlobalErrors();
        return errors.isEmpty() ? null : errors.get(0);
    }

    /// The first field error, or null.
    FieldError getFieldError()
    {
        auto errors = getFieldErrors();
        return errors.isEmpty() ? null : errors.get(0);
    }

    /// The errors on `field` (a trailing `*` matches any suffix).
    List!FieldError getFieldErrors(string field)
    {
        const fixed = fixedField(field);
        FieldError[] result;
        foreach (error; getFieldErrors().toArray())
            if (isMatchingFieldError(fixed, error))
                result ~= error;
        return Collections.unmodifiableList!FieldError(new ArrayList!FieldError(result));
    }

    /// The first error on `field`, or null.
    FieldError getFieldError(string field)
    {
        auto errors = getFieldErrors(field);
        return errors.isEmpty() ? null : errors.get(0);
    }

    /// Whether there are errors.
    bool hasErrors()
    {
        return getErrorCount() > 0;
    }

    /// The number of errors.
    int getErrorCount()
    {
        return getAllErrors().size();
    }

    /// Whether there are global errors.
    bool hasGlobalErrors()
    {
        return getGlobalErrorCount() > 0;
    }

    /// The number of global errors.
    int getGlobalErrorCount()
    {
        return getGlobalErrors().size();
    }

    /// Whether there are field errors.
    bool hasFieldErrors()
    {
        return getFieldErrorCount() > 0;
    }

    /// The number of field errors.
    int getFieldErrorCount()
    {
        return getFieldErrors().size();
    }

    /// Whether `field` has errors.
    bool hasFieldErrors(string field)
    {
        return getFieldErrorCount(field) > 0;
    }

    /// The number of errors on `field`.
    int getFieldErrorCount(string field)
    {
        return getFieldErrors(field).size();
    }

    /// Whether `fieldError` matches `field`, with a trailing `*` matching any suffix.
    protected bool isMatchingFieldError(string field, FieldError fieldError)
    {
        if (field == fieldError.getField())
            return true;
        const end = field.length - (field.length ? 1 : 0);
        return field.length && field[end] == '*' && fieldError.getField().length >= end
            && fieldError.getField()[0 .. end] == field[0 .. end];
    }

    /// `ClassName: N errors` followed by each error on its own line.
    override string toString()
    {
        import flint.engine.aot.name : canonicalTypeName;

        string result = canonicalTypeName(typeid(this).name) ~ ": " ~ valueOf(getErrorCount()) ~ " errors";
        foreach (error; getAllErrors().toArray())
            result ~= "\n" ~ error.toString();
        return result;
    }
}

/// Strategy for building message codes from validation error codes.
interface MessageCodesResolver
{
    /// The codes for a global error.
    string[] resolveMessageCodes(string errorCode, string objectName);
    /// The codes for a field error; `fieldType` is a type name or null.
    string[] resolveMessageCodes(string errorCode, string objectName, string field, string fieldType);
}

/// Formats a message code from its parts.
interface MessageCodeFormatter
{
    /// The code for `errorCode`, `objectName` and `field` (either may be null).
    string format(string errorCode, string objectName, string field);
}

/++
Spring's default `MessageCodesResolver`. For error code `typeMismatch`, object name `user` and field `age` of type
`int`, it gives `typeMismatch.user.age`, `typeMismatch.age`, `typeMismatch.int`, `typeMismatch`, and strips keyed
path elements (`groups[0].name` also yields `groups.name`).
+/
class DefaultMessageCodesResolver : MessageCodesResolver
{
    /// The separator between code parts.
    enum CODE_SEPARATOR = ".";
    private enum MAX_STRIPPED_KEYS = 8;

    /// The formats of `Format`.
    enum Format
    {
        /// `errorCode.objectName.field` (the default).
        PREFIX_ERROR_CODE,
        /// `objectName.field.errorCode`.
        POSTFIX_ERROR_CODE,
    }

    private string prefix = "";
    private Format format_ = Format.PREFIX_ERROR_CODE;
    private MessageCodeFormatter formatter;

    /// Prefix every code with `prefix`.
    void setPrefix(string prefix)
    {
        this.prefix = prefix is null ? "" : prefix;
    }

    /// The prefix.
    protected string getPrefix()
    {
        return prefix;
    }

    /// Use `format` for the codes.
    void setMessageCodeFormatter(Format format)
    {
        format_ = format;
        formatter = null;
    }

    /// Use a custom `formatter` for the codes; null restores `Format.PREFIX_ERROR_CODE`.
    void setMessageCodeFormatter(MessageCodeFormatter formatter)
    {
        format_ = Format.PREFIX_ERROR_CODE;
        this.formatter = formatter;
    }

    /// The codes for a global error.
    string[] resolveMessageCodes(string errorCode, string objectName)
    {
        return resolveMessageCodes(errorCode, objectName, "", null);
    }

    /// The codes for a field error.
    string[] resolveMessageCodes(string errorCode, string objectName, string field, string fieldType)
    {
        string[] codeList;
        string[] fieldList;
        buildFieldList(field, fieldList);
        foreach (f; fieldList)
            addCode(codeList, code(errorCode, objectName, f));
        size_t dot = field.length;
        foreach_reverse (i, c; field)
            if (c == '.')
            {
                dot = i;
                break;
            }
        if (dot != field.length)
            buildFieldList(field[dot + 1 .. $], fieldList);
        foreach (f; fieldList)
            addCode(codeList, code(errorCode, null, f));
        if (fieldType !is null)
            addCode(codeList, code(errorCode, null, fieldType));
        addCode(codeList, code(errorCode, null, null));
        return codeList;
    }

    /// Append `code` unless it is already present (Spring's `LinkedHashSet`).
    private static void addCode(ref string[] codes, string code) pure nothrow
    {
        foreach (existing; codes)
            if (existing == code)
                return;
        codes ~= code;
    }

    private string code(string errorCode, string objectName, string field)
    {
        string formatted;
        if (formatter !is null)
            formatted = formatter.format(errorCode, objectName, field);
        else if (format_ == Format.PREFIX_ERROR_CODE)
            formatted = toDelimitedString([errorCode, objectName, field]);
        else
            formatted = toDelimitedString([objectName, field, errorCode]);
        return postProcessMessageCode(formatted);
    }

    /// Add `field` and its forms with keyed elements stripped to `fieldList`.
    protected void buildFieldList(string field, ref string[] fieldList)
    {
        fieldList ~= field;
        if (exceedsMaxStrippedKeys(field))
            return;
        string plain = field;
        for (auto key = lastIndexOf(plain, '['); key >= 0; key = lastIndexOf(plain, '['))
        {
            auto end = indexOf(plain, ']', key);
            if (end < 0)
                break;
            plain = plain[0 .. key] ~ plain[end + 1 .. $];
            fieldList ~= plain;
        }
    }

    private static bool exceedsMaxStrippedKeys(string field) pure nothrow @nogc
    {
        int keys;
        foreach (c; field)
            if (c == '[' && ++keys > MAX_STRIPPED_KEYS)
                return true;
        return false;
    }

    private static ptrdiff_t lastIndexOf(string s, char c) pure nothrow @nogc
    {
        foreach_reverse (i, x; s)
            if (x == c)
                return i;
        return -1;
    }

    private static ptrdiff_t indexOf(string s, char c, size_t from) pure nothrow @nogc
    {
        foreach (i; from .. s.length)
            if (s[i] == c)
                return i;
        return -1;
    }

    /// The code with the prefix applied.
    protected string postProcessMessageCode(string code)
    {
        return prefix ~ code;
    }

    /// The non-empty elements joined with `.`.
    static string toDelimitedString(string[] elements)
    {
        string result;
        foreach (element; elements)
            if (element.length)
                result ~= (result.length ? CODE_SEPARATOR : "") ~ element;
        return result;
    }
}

/// General interface representing the binding results of an object, with errors and field values.
interface BindingResult : Errors
{
    /// The prefix of the model attribute holding a `BindingResult`.
    enum MODEL_KEY_PREFIX = "flint.validation.BindingResult.";

    /// The bound object, or `Any.init`.
    Any getTarget();
    /// The raw (unformatted) value of `field`.
    Any getRawFieldValue(string field);
    /// Add a custom error.
    void addError(ObjectError error);
    /// The message codes for a global error code.
    string[] resolveMessageCodes(string errorCode);
    /// The message codes for a field error code.
    string[] resolveMessageCodes(string errorCode, string field);
    /// The fields suppressed during binding.
    string[] getSuppressedFields();
}

/// Abstract implementation of `BindingResult`: the error list and code resolution (Spring's `AbstractBindingResult`).
abstract class AbstractBindingResult : AbstractErrors, BindingResult
{
    private string objectName;
    private MessageCodesResolver messageCodesResolver;
    private ObjectError[] errors;
    private string[] suppressedFields;

    /// A result for `objectName`.
    protected this(string objectName)
    {
        this.objectName = objectName;
        messageCodesResolver = new DefaultMessageCodesResolver;
    }

    /// Set the codes resolver.
    void setMessageCodesResolver(MessageCodesResolver resolver)
    {
        Assert.notNull(resolver, "MessageCodesResolver must not be null");
        messageCodesResolver = resolver;
    }

    /// The codes resolver.
    MessageCodesResolver getMessageCodesResolver()
    {
        return messageCodesResolver;
    }

    /// The object name.
    string getObjectName()
    {
        return objectName;
    }

    alias reject = AbstractErrors.reject;
    alias rejectValue = AbstractErrors.rejectValue;

    /// Register a global error.
    override void reject(string errorCode, Any[] errorArgs, string defaultMessage)
    {
        addError(new ObjectError(getObjectName(), resolveMessageCodes(errorCode), errorArgs, defaultMessage));
    }

    /// Register a field error, or a global error at the top level without a field.
    override void rejectValue(string field, string errorCode, Any[] errorArgs, string defaultMessage)
    {
        if (!StringUtils.hasLength(getNestedPath()) && !StringUtils.hasLength(field))
        {
            reject(errorCode, errorArgs, defaultMessage);
            return;
        }
        const fixed = fixedField(field);
        addError(new FieldError(getObjectName(), fixed, getActualFieldValue(fixed), false,
                resolveMessageCodes(errorCode, field), errorArgs, defaultMessage));
    }

    /// Add every error of `errors`.
    void addAllErrors(Errors errors)
    {
        if (errors.getObjectName() != getObjectName())
            throw new IllegalArgumentException("Errors object needs to have same object name");
        foreach (error; errors.getAllErrors().toArray())
            this.errors ~= error;
    }

    /// Add `error`.
    void addError(ObjectError error)
    {
        errors ~= error;
    }

    override bool hasErrors()
    {
        return errors.length != 0;
    }

    override int getErrorCount()
    {
        return cast(int) errors.length;
    }

    /// Every error.
    override List!ObjectError getAllErrors()
    {
        return Collections.unmodifiableList!ObjectError(new ArrayList!ObjectError(errors));
    }

    /// The global errors.
    override List!ObjectError getGlobalErrors()
    {
        ObjectError[] result;
        foreach (error; errors)
            if (cast(FieldError) error is null)
                result ~= error;
        return Collections.unmodifiableList!ObjectError(new ArrayList!ObjectError(result));
    }

    /// The first global error, or null.
    override ObjectError getGlobalError()
    {
        foreach (error; errors)
            if (cast(FieldError) error is null)
                return error;
        return null;
    }

    /// The field errors.
    override List!FieldError getFieldErrors()
    {
        FieldError[] result;
        foreach (error; errors)
            if (auto fieldError = cast(FieldError) error)
                result ~= fieldError;
        return Collections.unmodifiableList!FieldError(new ArrayList!FieldError(result));
    }

    /// The first field error, or null.
    override FieldError getFieldError()
    {
        foreach (error; errors)
            if (auto fieldError = cast(FieldError) error)
                return fieldError;
        return null;
    }

    /// The errors on `field` (a trailing `*` matches any suffix).
    override List!FieldError getFieldErrors(string field)
    {
        const fixed = fixedField(field);
        FieldError[] result;
        foreach (error; errors)
            if (auto fieldError = cast(FieldError) error)
                if (isMatchingFieldError(fixed, fieldError))
                    result ~= fieldError;
        return Collections.unmodifiableList!FieldError(new ArrayList!FieldError(result));
    }

    /// The first error on `field`, or null.
    override FieldError getFieldError(string field)
    {
        const fixed = fixedField(field);
        foreach (error; errors)
            if (auto fieldError = cast(FieldError) error)
                if (isMatchingFieldError(fixed, fieldError))
                    return fieldError;
        return null;
    }

    /// The rejected value when `field` has an error, else its current value.
    Any getFieldValue(string field)
    {
        if (auto fieldError = getFieldError(field))
            return fieldError.getRejectedValue();
        return getActualFieldValue(fixedField(field));
    }

    /// The type name of `field`'s current value, or null.
    string getFieldType(string field)
    {
        auto value = getActualFieldValue(fixedField(field));
        return value.isNull ? null : value.typeName;
    }

    /// The raw value of `field`.
    Any getRawFieldValue(string field)
    {
        return getActualFieldValue(fixedField(field));
    }

    /// The codes for a global error code.
    string[] resolveMessageCodes(string errorCode)
    {
        return messageCodesResolver.resolveMessageCodes(errorCode, getObjectName());
    }

    /// The codes for a field error code.
    string[] resolveMessageCodes(string errorCode, string field)
    {
        const fixed = fixedField(field);
        return messageCodesResolver.resolveMessageCodes(errorCode, getObjectName(), fixed, getFieldType(field));
    }

    /// Record a suppressed field.
    void recordSuppressedField(string field)
    {
        suppressedFields ~= field;
    }

    /// The suppressed fields.
    string[] getSuppressedFields()
    {
        return suppressedFields.dup;
    }

    /// The current value of `field` in the target.
    protected abstract Any getActualFieldValue(string field);
}

/++
A `BindingResult` over a target object, reading properties (nested with `.`) through Flint AOT descriptors.
Spring's version uses a `BeanWrapper`.
+/
class BeanPropertyBindingResult : AbstractBindingResult
{
    private Any target;
    private DescriptorTable descriptors;

    /// A result for `target`, named `objectName`; nested types resolve in `descriptors` (may be null).
    this(Any target, string objectName, DescriptorTable descriptors = null)
    {
        super(objectName);
        this.target = target;
        this.descriptors = descriptors;
    }

    /// The target.
    Any getTarget()
    {
        return target;
    }

    /// The declared type name of `field`, or the type of its current value.
    override string getFieldType(string field)
    {
        if (auto type = propertyType(target, fixedField(field), descriptors))
            return type;
        return super.getFieldType(field);
    }

    /// A result for `target`, whose descriptor (from `descriptorOf!T`) resolves its top-level properties.
    this(T)(T target, string objectName) if (!is(T == Any))
    {
        this(Any.of(target), objectName, tableOf!T);
    }

    protected override Any getActualFieldValue(string field)
    {
        return readProperty(target, field, descriptors);
    }
}

/// A table holding `descriptorOf!T`.
private DescriptorTable tableOf(T)()
{
    import flint.engine.aot.descriptor : descriptorOf;

    auto table = new DescriptorTable;
    table.add(descriptorOf!T);
    return table;
}

/// Read the property path `field` of `target` through `descriptors`, as Spring's `BeanWrapper` does: nested
/// (`a.b.c`) and indexed (`roles[0].name`, `map[key]`, `matrix[0][1]`) segments; `Any.init` when unknown.
private Any readProperty(Any target, string field, DescriptorTable descriptors)
{
    if (field.length == 0)
        return Any.init;
    Any current = target;
    size_t start;
    while (start <= field.length)
    {
        const end = segmentEnd(field, start);
        auto segment = field[start .. end];
        size_t bracket = segment.length;
        foreach (i, c; segment)
            if (c == '[')
            {
                bracket = i;
                break;
            }
        if (bracket > 0)
            current = readNamed(current, segment[0 .. bracket], descriptors);
        auto keys = segment[bracket .. $];
        while (keys.length && !current.isNull)
        {
            size_t close;
            while (close < keys.length && keys[close] != ']')
                close++;
            if (close == keys.length)
                return Any.init;
            current = readIndexed(current, unquoteKey(keys[1 .. close]), descriptors);
            keys = keys[close + 1 .. $];
        }
        if (current.isNull)
            return Any.init;
        start = end + 1;
    }
    return current;
}

/// The end of the path segment starting at `start`: the next `.` outside brackets, or the end.
private size_t segmentEnd(string field, size_t start) pure nothrow @nogc
{
    bool inKey;
    foreach (i; start .. field.length)
    {
        if (field[i] == '[')
            inKey = true;
        else if (field[i] == ']')
            inKey = false;
        else if (field[i] == '.' && !inKey)
            return i;
    }
    return field.length;
}

/// A bracketed key without the quotes Spring allows (`map['key']`, `map["key"]`).
private string unquoteKey(string key) pure nothrow @nogc
{
    if (key.length >= 2 && (key[0] == '\'' || key[0] == '"') && key[$ - 1] == key[0])
        return key[1 .. $ - 1];
    return key;
}

/// The property `name` of `owner`, read through its descriptor; `Any.init` when unknown.
private Any readNamed(Any owner, string name, DescriptorTable descriptors)
{
    if (owner.isNull || descriptors is null)
        return Any.init;
    auto descriptor = descriptors.find(owner.typeName);
    auto property = descriptor is null ? null : descriptor.property(name);
    if (property is null || property.get is null)
        return Any.init;
    return property.get(owner);
}

/// Element `key` of `container`: a list or set position (iteration order, as Spring's `BeanWrapper` reads a set),
/// a map key, or an array index through the array's descriptor; `Any.init` when absent.
private Any readIndexed(Any container, string key, DescriptorTable descriptors)
{
    if (auto object = container.asObject())
        return readJavaElement(object, key);
    auto descriptor = descriptors is null ? null : descriptors.find(container.typeName);
    return descriptor is null ? Any.init : readDescriptorElement(descriptor, container, key);
}

/// Element `key` of a `flint.java.util` collection (by position) or map (by key text).
private Any readJavaElement(Object object, string key)
{
    import flint.java.util : RawCollection, RawMap;

    if (auto collection = cast(RawCollection) object)
    {
        auto elements = collection.toAnyArray();
        const index = parseIndex(key);
        return index < elements.length ? elements[index] : Any.init;
    }
    if (auto map = cast(RawMap) object)
        foreach (candidate; map.keysAsAny())
            if (keyText(candidate) == key)
                return map.getAny(candidate);
    return Any.init;
}

/// Element `key` of a D array (by index) or associative array (by key text), through its descriptor's builders.
private Any readDescriptorElement(const Descriptor descriptor, Any container, string key)
{
    if (descriptor.length !is null && descriptor.element !is null)
    {
        const index = parseIndex(key);
        return index < descriptor.length(container) ? descriptor.element(container, index) : Any.init;
    }
    if (descriptor.toKeys !is null && descriptor.toValues !is null)
        foreach (i, candidate; descriptor.toKeys(container))
            if (keyText(candidate) == key)
                return descriptor.toValues(container)[i];
    return Any.init;
}

/// A non-negative decimal index, or `size_t.max` when `key` is not one.
private size_t parseIndex(string key) pure nothrow @nogc
{
    if (key.length == 0 || key.length > 18)
        return size_t.max;
    size_t index;
    foreach (c; key)
    {
        if (c < '0' || c > '9')
            return size_t.max;
        index = index * 10 + (c - '0');
    }
    return index;
}

/// A map key as it appears in a property path.
private string keyText(Any key)
{
    return key.typeName == "string" ? key.get!string : key.toString();
}

/// The declared type name of the property path `field` of `target`, or null. An indexed last segment
/// (`roles[0]`) gives the element's type.
private string propertyType(Any target, string field, DescriptorTable descriptors)
{
    if (field.length && field[$ - 1] == ']')
    {
        auto element = readProperty(target, field, descriptors);
        return element.isNull ? null : element.typeName;
    }
    size_t dot = field.length;
    size_t depth;
    foreach_reverse (i, c; field)
    {
        if (c == ']')
            depth++;
        else if (c == '[' && depth)
            depth--;
        else if (c == '.' && depth == 0)
        {
            dot = i;
            break;
        }
    }
    auto owner = dot == field.length ? target : readProperty(target, field[0 .. dot], descriptors);
    if (owner.isNull || descriptors is null)
        return null;
    auto descriptor = descriptors.find(owner.typeName);
    auto property = descriptor is null ? null : descriptor.property(dot == field.length ? field : field[dot + 1 .. $]);
    return property is null ? null : property.type;
}

/++
A simple `Errors` over a target object, holding global and field errors without a `BindingResult`'s message-code
resolution: each error's code is the given error code (Spring's `SimpleErrors`). Nested paths are not supported.
+/
class SimpleErrors : AbstractErrors
{
    private Any target;
    private string objectName;
    private DescriptorTable descriptors;
    private ObjectError[] globalErrors;
    private FieldError[] fieldErrors;

    /// Errors for `target`, named `objectName`; properties resolve through `descriptors`.
    this(Any target, string objectName, DescriptorTable descriptors = null)
    {
        Assert.isTrue(!target.isNull, "Target must not be null");
        this.target = target;
        this.objectName = objectName;
        this.descriptors = descriptors;
    }

    /// Errors for `target`, named after its type's simple name unless `objectName` is given.
    this(T)(T target, string objectName = null) if (!is(T == Any))
    {
        import flint.engine.aot.name : simpleTypeName, typeNameOf;

        this(Any.of(target), objectName is null ? simpleTypeName(typeNameOf!T) : objectName, tableOf!T);
    }

    /// The object name.
    string getObjectName()
    {
        return objectName;
    }

    /// Nested paths are not supported.
    override void setNestedPath(string nestedPath)
    {
        throw new UnsupportedOperationException("SimpleErrors does not support nested paths");
    }

    /// Nested paths are not supported.
    override void pushNestedPath(string subPath)
    {
        throw new UnsupportedOperationException("SimpleErrors does not support nested paths");
    }

    /// Nested paths are not supported.
    override void popNestedPath()
    {
        throw new UnsupportedOperationException("SimpleErrors does not support nested paths");
    }

    alias reject = AbstractErrors.reject;
    alias rejectValue = AbstractErrors.rejectValue;

    /// Register a global error with `errorCode` as its only code.
    override void reject(string errorCode, Any[] errorArgs, string defaultMessage)
    {
        globalErrors ~= new ObjectError(objectName, [errorCode], errorArgs, defaultMessage);
    }

    /// Register a field error with `errorCode` as its only code, or a global error without a field.
    override void rejectValue(string field, string errorCode, Any[] errorArgs, string defaultMessage)
    {
        if (!StringUtils.hasLength(field))
        {
            reject(errorCode, errorArgs, defaultMessage);
            return;
        }
        fieldErrors ~= new FieldError(objectName, field, getFieldValue(field), false, [errorCode],
                errorArgs, defaultMessage);
    }

    /// Add the global and field errors of `errors`.
    void addAllErrors(Errors errors)
    {
        globalErrors ~= errors.getGlobalErrors().toArray();
        fieldErrors ~= errors.getFieldErrors().toArray();
    }

    /// The global errors.
    override List!ObjectError getGlobalErrors()
    {
        return Collections.unmodifiableList!ObjectError(new ArrayList!ObjectError(globalErrors));
    }

    /// The field errors.
    override List!FieldError getFieldErrors()
    {
        return Collections.unmodifiableList!FieldError(new ArrayList!FieldError(fieldErrors));
    }

    alias getFieldErrors = AbstractErrors.getFieldErrors;

    /// The rejected value when `field` has an error, else the property value read through the descriptor.
    Any getFieldValue(string field)
    {
        if (auto fieldError = getFieldError(field))
            return fieldError.getRejectedValue();
        return readProperty(target, field, descriptors);
    }

    /// The declared type name of `field`, or null.
    string getFieldType(string field)
    {
        return propertyType(target, field, descriptors);
    }

    /// Equal targets and errors.
    override bool opEquals(Object other)
    {
        auto that = cast(SimpleErrors) other;
        return that is this || (that !is null && that.target == target && equalErrors(that.globalErrors,
                globalErrors) && equalErrors(that.fieldErrors, fieldErrors));
    }

    private static bool equalErrors(E)(E[] left, E[] right)
    {
        if (left.length != right.length)
            return false;
        foreach (i, error; left)
            if (!error.opEquals(right[i]))
                return false;
        return true;
    }

    /// The target's hash.
    override size_t toHash() nothrow
    {
        return target.toHash();
    }

    /// Each error on its own line.
    override string toString()
    {
        string result;
        foreach (error; globalErrors)
            result ~= "\n" ~ error.toString();
        foreach (error; fieldErrors)
            result ~= "\n" ~ error.toString();
        return result;
    }
}

/// A `BindingResult` over a `Map!(string, Any)` target.
class MapBindingResult : AbstractBindingResult
{
    private Map!(string, Any) target;

    /// A result for `target`, named `objectName`.
    this(Map!(string, Any) target, string objectName)
    {
        super(objectName);
        Assert.notNull(target, "Target Map must not be null");
        this.target = target;
    }

    /// The target map.
    final Map!(string, Any) getTargetMap()
    {
        return target;
    }

    /// The target map, boxed.
    Any getTarget()
    {
        return Any.of(target);
    }

    protected override Any getActualFieldValue(string field)
    {
        return target.get(field);
    }
}

/// Thrown when binding errors are fatal: a `BindingResult` as an exception (Spring's `BindException`).
class BindException : Exception, BindingResult
{
    private BindingResult bindingResult;

    /// An exception over `bindingResult`.
    this(BindingResult bindingResult, string file = __FILE__, size_t line = __LINE__)
    {
        Assert.notNull(bindingResult, "BindingResult must not be null");
        this.bindingResult = bindingResult;
        super(valueOf(cast(Object) bindingResult), file, line);
    }

    /// An exception over a new `BeanPropertyBindingResult` for `target`.
    this(Any target, string objectName)
    {
        this(new BeanPropertyBindingResult(target, objectName));
    }

    /// The wrapped binding result.
    final BindingResult getBindingResult() pure nothrow @nogc
    {
        return bindingResult;
    }

    /// The message: the binding result's summary.
    string getMessage()
    {
        return valueOf(cast(Object) bindingResult);
    }

    // Errors and BindingResult, delegated.

    /// See `Errors`.
    string getObjectName()
    {
        return bindingResult.getObjectName();
    }

    /// See `Errors`.
    void setNestedPath(string nestedPath)
    {
        bindingResult.setNestedPath(nestedPath);
    }

    /// See `Errors`.
    string getNestedPath()
    {
        return bindingResult.getNestedPath();
    }

    /// See `Errors`.
    void pushNestedPath(string subPath)
    {
        bindingResult.pushNestedPath(subPath);
    }

    /// See `Errors`.
    void popNestedPath()
    {
        bindingResult.popNestedPath();
    }

    /// See `Errors`.
    void reject(string errorCode)
    {
        bindingResult.reject(errorCode);
    }

    /// See `Errors`.
    void reject(string errorCode, string defaultMessage)
    {
        bindingResult.reject(errorCode, defaultMessage);
    }

    /// See `Errors`.
    void reject(string errorCode, Any[] errorArgs, string defaultMessage)
    {
        bindingResult.reject(errorCode, errorArgs, defaultMessage);
    }

    /// See `Errors`.
    void rejectValue(string field, string errorCode)
    {
        bindingResult.rejectValue(field, errorCode);
    }

    /// See `Errors`.
    void rejectValue(string field, string errorCode, string defaultMessage)
    {
        bindingResult.rejectValue(field, errorCode, defaultMessage);
    }

    /// See `Errors`.
    void rejectValue(string field, string errorCode, Any[] errorArgs, string defaultMessage)
    {
        bindingResult.rejectValue(field, errorCode, errorArgs, defaultMessage);
    }

    /// See `Errors`.
    void addAllErrors(Errors errors)
    {
        bindingResult.addAllErrors(errors);
    }

    /// See `Errors`.
    bool hasErrors()
    {
        return bindingResult.hasErrors();
    }

    /// See `Errors`.
    int getErrorCount()
    {
        return bindingResult.getErrorCount();
    }

    /// See `Errors`.
    List!ObjectError getAllErrors()
    {
        return bindingResult.getAllErrors();
    }

    /// See `Errors`.
    bool hasGlobalErrors()
    {
        return bindingResult.hasGlobalErrors();
    }

    /// See `Errors`.
    int getGlobalErrorCount()
    {
        return bindingResult.getGlobalErrorCount();
    }

    /// See `Errors`.
    List!ObjectError getGlobalErrors()
    {
        return bindingResult.getGlobalErrors();
    }

    /// See `Errors`.
    ObjectError getGlobalError()
    {
        return bindingResult.getGlobalError();
    }

    /// See `Errors`.
    bool hasFieldErrors()
    {
        return bindingResult.hasFieldErrors();
    }

    /// See `Errors`.
    int getFieldErrorCount()
    {
        return bindingResult.getFieldErrorCount();
    }

    /// See `Errors`.
    List!FieldError getFieldErrors()
    {
        return bindingResult.getFieldErrors();
    }

    /// See `Errors`.
    FieldError getFieldError()
    {
        return bindingResult.getFieldError();
    }

    /// See `Errors`.
    bool hasFieldErrors(string field)
    {
        return bindingResult.hasFieldErrors(field);
    }

    /// See `Errors`.
    int getFieldErrorCount(string field)
    {
        return bindingResult.getFieldErrorCount(field);
    }

    /// See `Errors`.
    List!FieldError getFieldErrors(string field)
    {
        return bindingResult.getFieldErrors(field);
    }

    /// See `Errors`.
    FieldError getFieldError(string field)
    {
        return bindingResult.getFieldError(field);
    }

    /// See `Errors`.
    Any getFieldValue(string field)
    {
        return bindingResult.getFieldValue(field);
    }

    /// See `Errors`.
    string getFieldType(string field)
    {
        return bindingResult.getFieldType(field);
    }

    /// See `BindingResult`.
    Any getTarget()
    {
        return bindingResult.getTarget();
    }

    /// See `BindingResult`.
    Any getRawFieldValue(string field)
    {
        return bindingResult.getRawFieldValue(field);
    }

    /// See `BindingResult`.
    void addError(ObjectError error)
    {
        bindingResult.addError(error);
    }

    /// See `BindingResult`.
    string[] resolveMessageCodes(string errorCode)
    {
        return bindingResult.resolveMessageCodes(errorCode);
    }

    /// See `BindingResult`.
    string[] resolveMessageCodes(string errorCode, string field)
    {
        return bindingResult.resolveMessageCodes(errorCode, field);
    }

    /// See `BindingResult`.
    string[] getSuppressedFields()
    {
        return bindingResult.getSuppressedFields();
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Validators

/++
A validator for application-specific objects (Spring's `Validator`). `supports` takes the type's canonical name
(Java's `Class`, R4).
+/
interface Validator
{
    /// Whether this validator can validate instances of the type named `typeName`.
    bool supports(string typeName);
    /// Validate `target`, registering errors on `errors`.
    void validate(Any target, Errors errors);

    /// Validate `target` into new `SimpleErrors`, which are returned.
    Errors validateObject(T)(T target)
    {
        auto errors = new SimpleErrors(target);
        validate(Any.of(target), errors);
        return errors;
    }

    /// A validator for `T`, running `validator`. Flint matches `T` by type name, so subtypes are not supported.
    static Validator forInstanceOf(T)(void delegate(T, Errors) @safe validator)
    {
        return new TypedValidator!T(validator);
    }

    /// A validator for `T`, running `validator` (Flint matches by type name, as `forType` does).
    static Validator forType(T)(void delegate(T, Errors) @safe validator)
    {
        return new TypedValidator!T(validator);
    }
}

/// The validator made by `Validator.forInstanceOf` and `Validator.forType` (Spring's `TypedValidator`).
private final class TypedValidator(T) : Validator
{
    import flint.engine.aot.name : typeNameOf;

    private void delegate(T, Errors) @safe validator;

    this(void delegate(T, Errors) @safe validator)
    {
        Assert.isTrue(validator !is null, "Validator must not be null");
        this.validator = validator;
    }

    bool supports(string typeName)
    {
        return typeName == typeNameOf!T;
    }

    void validate(Any target, Errors errors)
    {
        validator(target.get!T, errors);
    }
}

/// A `Validator` with validation hints (Spring's `SmartValidator`).
interface SmartValidator : Validator
{
    /// Validate `target` with `validationHints` (validation groups as `ClassRef`s, boxed).
    void validate(Any target, Errors errors, Any[] validationHints);
}

/// Utilities for invoking validators and rejecting empty fields (Spring's `ValidationUtils`).
struct ValidationUtils
{
    /// Invoke `validator` on `target`. Throws `IllegalArgumentException` when it does not support the target's type.
    static void invokeValidator(Validator validator, Any target, Errors errors, Any[] validationHints = null)
    {
        Assert.notNull(validator, "Validator must not be null");
        Assert.notNull(errors, "Errors object must not be null");
        if (!target.isNull && !validator.supports(target.typeName))
            throw new IllegalStateException("Validator [" ~ valueOf(
                    cast(Object) validator) ~ "] does not support [" ~ target.typeName ~ "]");
        auto smart = cast(SmartValidator) validator;
        if (validationHints.length && smart !is null)
            smart.validate(target, errors, validationHints);
        else
            validator.validate(target, errors);
    }

    /// Reject `field` with `errorCode` when its value is null or an empty string.
    static void rejectIfEmpty(Errors errors, string field, string errorCode, string defaultMessage = null)
    {
        rejectIfEmpty(errors, field, errorCode, null, defaultMessage);
    }

    /// Reject `field` with `errorCode` and `errorArgs` when its value is null or an empty string.
    static void rejectIfEmpty(Errors errors, string field, string errorCode, Any[] errorArgs,
            string defaultMessage = null)
    {
        const value = errors.getFieldValue(field);
        if (value.isNull || (value.typeName == "string" && value.get!string.length == 0))
            errors.rejectValue(field, errorCode, errorArgs, defaultMessage);
    }

    /// Reject `field` with `errorCode` when its value is null, empty or only whitespace.
    static void rejectIfEmptyOrWhitespace(Errors errors, string field, string errorCode, string defaultMessage = null)
    {
        rejectIfEmptyOrWhitespace(errors, field, errorCode, null, defaultMessage);
    }

    /// Reject `field` with `errorCode` and `errorArgs` when its value is null, empty or only whitespace.
    static void rejectIfEmptyOrWhitespace(Errors errors, string field, string errorCode,
            Any[] errorArgs, string defaultMessage = null)
    {
        auto value = errors.getFieldValue(field);
        if (value.isNull || (value.typeName == "string" && !StringUtils.hasText(value.get!string)))
            errors.rejectValue(field, errorCode, errorArgs, defaultMessage);
    }
}
