// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/validation
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/*
 * Ports DefaultMessageCodesResolverTests (14 of 14), ValidationUtilsTests (9 of 9) and ValidatorTests (1 of 2:
 * supportsForInstanceOf needs the class hierarchy, which a type name does not carry). SpringValidatorAdapterTests and
 * ValidatorFactoryTests need Hibernate Validator and a MessageSource; the adapter is tested below against a stub
 * provider instead. TestBean is the fixture's bean, reduced to the properties the tests read.
 */
module flint.validation_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : IllegalArgumentException, IllegalStateException, RuntimeException;
import flint.java.util.function_ : Function;
import flint.validation : BeanPropertyBindingResult, BindException, DefaultMessageCodesResolver, Errors,
    FieldError, MapBindingResult, MessageCodeFormatter, ObjectError, SimpleErrors, ValidationUtils, Validator;

@safe:

private final class TestBean
{
    string name;
    int age;
    Pet pet;

    this(string name = null)
    {
        this.name = name;
    }
}

private final class Pet
{
    string name;
}

private enum testBean = typeNameOf!TestBean;

// DefaultMessageCodesResolverTests

unittest
{
    // shouldResolveMessageCode, shouldResolveFieldMessageCode
    auto resolver = new DefaultMessageCodesResolver;
    assert(resolver.resolveMessageCodes("errorCode", "objectName") == [
        "errorCode.objectName", "errorCode"
    ]);
    assert(resolver.resolveMessageCodes("errorCode", "objectName", "field",
            testBean) == [
        "errorCode.objectName.field", "errorCode.field", "errorCode." ~ testBean, "errorCode"
    ]);
}

unittest
{
    // shouldResolveIndexedFieldMessageCode
    auto resolver = new DefaultMessageCodesResolver;
    assert(resolver.resolveMessageCodes("errorCode", "objectName", "a.b[3].c[5].d",
            testBean) == [
        "errorCode.objectName.a.b[3].c[5].d", "errorCode.objectName.a.b[3].c.d",
        "errorCode.objectName.a.b.c.d", "errorCode.a.b[3].c[5].d", "errorCode.a.b[3].c.d",
        "errorCode.a.b.c.d", "errorCode.d", "errorCode." ~ testBean, "errorCode"
    ]);
}

unittest
{
    // shouldResolveIndexedFieldMessageCodeWithMaxNumberOfKeys
    auto resolver = new DefaultMessageCodesResolver;
    string[] expected;
    foreach (prefix; ["errorCode.objectName.", "errorCode."])
    {
        string field = "a[0][1][2][3][4][5][6][7]";
        foreach_reverse (keys; 0 .. 9)
            expected ~= prefix ~ field[0 .. 1 + 3 * keys];
    }
    expected ~= "errorCode";
    assert(resolver.resolveMessageCodes("errorCode", "objectName", "a[0][1][2][3][4][5][6][7]", null) == expected);
}

unittest
{
    // resolveMessageCodesLimitsIndexedVariants, resolveMessageCodesLimitsIndexedVariantsForNestedField
    auto resolver = new DefaultMessageCodesResolver;
    string field = "a";
    foreach (i; 0 .. 1000)
        field ~= "[0]";
    assert(resolver.resolveMessageCodes("errorCode", "objectName", field,
            null) == ["errorCode.objectName." ~ field, "errorCode." ~ field, "errorCode"]);
    string keys;
    foreach (i; 0 .. 9)
        keys ~= "[0]";
    assert(resolver.resolveMessageCodes("errorCode", "objectName", "a.b" ~ keys,
            null) == [
        "errorCode.objectName.a.b" ~ keys, "errorCode.a.b" ~ keys, "errorCode.b" ~ keys, "errorCode"
    ]);
}

unittest
{
    // shouldResolveMessageCodeWithPrefix, shouldResolveFieldMessageCodeWithPrefix, shouldSupportNullPrefix
    auto resolver = new DefaultMessageCodesResolver;
    resolver.setPrefix("prefix.");
    assert(resolver.resolveMessageCodes("errorCode",
            "objectName") == ["prefix.errorCode.objectName", "prefix.errorCode"]);
    assert(resolver.resolveMessageCodes("errorCode", "objectName", "field",
            testBean) == [
        "prefix.errorCode.objectName.field", "prefix.errorCode.field",
        "prefix.errorCode." ~ testBean, "prefix.errorCode"
    ]);
    resolver.setPrefix(null);
    assert(resolver.resolveMessageCodes("errorCode", "objectName", "field",
            testBean) == [
        "errorCode.objectName.field", "errorCode.field", "errorCode." ~ testBean, "errorCode"
    ]);
}

unittest
{
    // shouldSupportMalformedIndexField, shouldSupportNullFieldType
    auto resolver = new DefaultMessageCodesResolver;
    assert(resolver.resolveMessageCodes("errorCode", "objectName", "field[",
            testBean) == [
        "errorCode.objectName.field[", "errorCode.field[", "errorCode." ~ testBean, "errorCode"
    ]);
    assert(resolver.resolveMessageCodes("errorCode", "objectName", "field",
            null) == ["errorCode.objectName.field", "errorCode.field", "errorCode"]);
}

private final class CustomFormatter : MessageCodeFormatter
{
    string format(string errorCode, string objectName, string field)
    {
        return DefaultMessageCodesResolver.toDelimitedString([
            "CUSTOM-" ~ errorCode, objectName, field
        ]);
    }
}

unittest
{
    // shouldSupportPostfixFormat, shouldSupportFieldPostfixFormat, shouldSupportCustomFormat
    auto resolver = new DefaultMessageCodesResolver;
    resolver.setMessageCodeFormatter(DefaultMessageCodesResolver.Format.POSTFIX_ERROR_CODE);
    assert(resolver.resolveMessageCodes("errorCode", "objectName") == [
        "objectName.errorCode", "errorCode"
    ]);
    assert(resolver.resolveMessageCodes("errorCode", "objectName", "field",
            testBean) == [
        "objectName.field.errorCode", "field.errorCode", testBean ~ ".errorCode", "errorCode"
    ]);
    resolver.setMessageCodeFormatter(new CustomFormatter);
    assert(resolver.resolveMessageCodes("errorCode",
            "objectName") == ["CUSTOM-errorCode.objectName", "CUSTOM-errorCode"]);
}

// ValidationUtilsTests

private Validator emptyValidator()
{
    return Validator.forInstanceOf!TestBean((TestBean, Errors errors) {
        ValidationUtils.rejectIfEmpty(errors, "name", "EMPTY", "You must enter a name!");
    });
}

private Validator emptyOrWhitespaceValidator()
{
    return Validator.forInstanceOf!TestBean((TestBean, Errors errors) {
        ValidationUtils.rejectIfEmptyOrWhitespace(errors, "name", "EMPTY_OR_WHITESPACE", "You must enter a name!");
    });
}

private Function!(string, RuntimeException) illegalState()
{
    return Function!(string, RuntimeException).of(
            (string message) => cast(RuntimeException) new IllegalStateException(message));
}

private bool failsWith(Errors errors, string[] parts...)
{
    try
        errors.failOnError(illegalState());
    catch (IllegalStateException e)
    {
        import flint.util : StringUtils;

        foreach (part; parts)
            if (e.getMessage().length < part.length || !contains(e.getMessage(), part))
                return false;
        return true;
    }
    return false;
}

private bool contains(string text, string part)
{
    foreach (i; 0 .. text.length - part.length + 1)
        if (text[i .. i + part.length] == part)
            return true;
    return false;
}

unittest
{
    // invokeValidatorWithNullValidator, invokeValidatorWithNullErrors, invokeValidatorSunnyDay
    auto tb = new TestBean;
    Errors errors = new SimpleErrors(tb);
    bool threw;
    try
        ValidationUtils.invokeValidator(null, Any.of(tb), errors);
    catch (IllegalArgumentException)
        threw = true;
    assert(threw);
    threw = false;
    try
        ValidationUtils.invokeValidator(emptyValidator(), Any.of(tb), null);
    catch (IllegalArgumentException)
        threw = true;
    assert(threw);
    ValidationUtils.invokeValidator(emptyValidator(), Any.of(tb), errors);
    assert(errors.hasFieldErrors("name") && errors.getFieldError("name").getCode() == "EMPTY");
}

unittest
{
    // validationUtilsSunnyDay, validationUtilsNull, validationUtilsEmpty
    auto tb = new TestBean("");
    tb.name = " ";
    auto errors = emptyValidator().validateObject(tb);
    assert(!errors.hasFieldErrors("name"));
    tb.name = "Roddy";
    errors = emptyValidator().validateObject(tb);
    assert(!errors.hasFieldErrors("name"));
    errors.failOnError(illegalState());

    errors = emptyValidator().validateObject(new TestBean);
    assert(errors.hasFieldErrors("name") && errors.getFieldError("name").getCode() == "EMPTY");
    assert(failsWith(errors, "'name'", "EMPTY"));
    errors = emptyValidator().validateObject(new TestBean(""));
    assert(errors.hasFieldErrors("name") && errors.getFieldError("name").getCode() == "EMPTY");
    assert(failsWith(errors, "'name'", "EMPTY"));
}

unittest
{
    // validationUtilsEmptyVariants
    auto tb = new TestBean;
    Errors errors = new SimpleErrors(tb);
    ValidationUtils.rejectIfEmpty(errors, "name", "EMPTY_OR_WHITESPACE", [Any.of("arg")]);
    assert(errors.hasFieldErrors("name") && errors.getFieldError("name").getCode() == "EMPTY_OR_WHITESPACE");
    assert(errors.getFieldError("name").getArguments()[0] == Any.of("arg"));
    errors = new SimpleErrors(tb);
    ValidationUtils.rejectIfEmpty(errors, "name", "EMPTY_OR_WHITESPACE", [Any.of("arg")], "msg");
    assert(errors.getFieldError("name").getCode() == "EMPTY_OR_WHITESPACE");
    assert(errors.getFieldError("name").getArguments()[0] == Any.of("arg"));
    assert(errors.getFieldError("name").getDefaultMessage() == "msg");
}

unittest
{
    // validationUtilsEmptyOrWhitespace
    auto tb = new TestBean;
    foreach (name; [null, "", " "])
    {
        tb.name = name;
        auto errors = emptyOrWhitespaceValidator().validateObject(tb);
        assert(errors.hasFieldErrors("name") && errors.getFieldError("name").getCode() == "EMPTY_OR_WHITESPACE");
    }
    tb.name = "Roddy";
    assert(!emptyOrWhitespaceValidator().validateObject(tb).hasFieldErrors("name"));
}

unittest
{
    // validationUtilsEmptyOrWhitespaceVariants
    auto tb = new TestBean;
    tb.name = " ";
    Errors errors = new SimpleErrors(tb);
    ValidationUtils.rejectIfEmptyOrWhitespace(errors, "name", "EMPTY_OR_WHITESPACE", [Any.of("arg")]);
    assert(errors.hasFieldErrors("name") && errors.getFieldError("name").getCode() == "EMPTY_OR_WHITESPACE");
    assert(errors.getFieldError("name").getArguments()[0] == Any.of("arg"));
    errors = new SimpleErrors(tb);
    ValidationUtils.rejectIfEmptyOrWhitespace(errors, "name", "EMPTY_OR_WHITESPACE", [Any.of("arg")], "msg");
    assert(errors.getFieldError("name").getDefaultMessage() == "msg");
}

// ValidatorTests

unittest
{
    // supportsForType
    auto validator = Validator.forType!TestBean((TestBean, Errors) {});
    assert(validator.supports(testBean) && !validator.supports(typeNameOf!Pet));
}

// Errors, binding results and BindException (Flint behavior over Spring's formats)

unittest
{
    auto global = new ObjectError("owner", ["required.owner", "required"], null, "Required");
    assert(global.toString() == "Error in object 'owner': codes [required.owner,required]; arguments []; "
            ~ "default message [Required]");
    auto field = new FieldError("owner", "name", Any.of("x"), false, ["size"], null, "Too short");
    assert(field.toString() == "Field error in object 'owner' on field 'name': rejected value [x]; codes [size]; "
            ~ "arguments []; default message [Too short]");
    assert(field == new FieldError("owner", "name", Any.of("x"), false, ["size"], null, "Too short"));
    assert(field != new FieldError("owner", "name", Any.of("y"), false, ["size"], null, "Too short"));
    assert(field.getCode() == "size" && !field.isBindingFailure());
}

unittest
{
    // BeanPropertyBindingResult: codes from the resolver, nested paths through the descriptor table.
    auto table = new DescriptorTable;
    table.add(descriptorOf!TestBean);
    table.add(descriptorOf!Pet);
    auto tb = new TestBean("Ann");
    tb.pet = new Pet;
    tb.pet.name = "Rex";
    auto result = new BeanPropertyBindingResult(Any.of(tb), "testBean", table);
    result.reject("invalid");
    result.rejectValue("name", "taken", "Name taken");
    result.pushNestedPath("pet");
    result.rejectValue("name", "short");
    assert(result.getFieldValue("name") == Any.of("Rex"));
    result.popNestedPath();
    assert(result.getErrorCount() == 3 && result.getGlobalErrorCount() == 1 && result.getFieldErrorCount() == 2);
    assert(result.getGlobalError().getCodes() == ["invalid.testBean", "invalid"]);
    assert(result.getFieldError("name").getCodes() == [
        "taken.testBean.name", "taken.name", "taken.string", "taken"
    ]);
    assert(result.getFieldError("pet.name").getRejectedValue() == Any.of("Rex"));
    assert(result.getFieldErrors("pet.*").size() == 1 && result.getFieldType("age") == "int");
    bool threw;
    try
        result.popNestedPath();
    catch (IllegalStateException)
        threw = true;
    assert(threw);
    auto exception = new BindException(result);
    assert(exception.getBindingResult() is result && exception.getFieldErrorCount("name") == 1);
    assert(contains(exception.getMessage(), "3 errors"));
}

unittest
{
    import flint.java.util : HashMap, Map;

    auto map = new HashMap!(string, Any);
    map.put("name", Any.of("Ann"));
    auto result = new MapBindingResult(map, "form");
    result.rejectValue("name", "taken");
    assert(result.getFieldValue("name") == Any.of("Ann") && result.getFieldError().getField() == "name");
    assert(result.getTargetMap() is map);
}

// Bean validation over a stub Jakarta provider

private struct NotBlank
{
}

private struct Size
{
    int min;
    int max;
}

private final class StubNode : imported!"flint.jakarta.validation".Path.Node
{
    import flint.jakarta.validation : ElementKind;

    private string name;
    private int index;
    private ElementKind kind;

    this(string name, int index = -1, ElementKind kind = ElementKind.PROPERTY)
    {
        this.name = name;
        this.index = index;
        this.kind = kind;
    }

    string getName()
    {
        return name;
    }

    bool isInIterable()
    {
        return index >= 0;
    }

    int getIndex()
    {
        return index;
    }

    Any getKey()
    {
        return Any.init;
    }

    ElementKind getKind()
    {
        return kind;
    }
}

private final class StubPath : imported!"flint.jakarta.validation".Path
{
    private Node[] path;

    this(Node[] path)
    {
        this.path = path;
    }

    Node[] nodes()
    {
        return path;
    }

    override string toString() const
    {
        return "path";
    }
}

private final class StubDescriptor : imported!"flint.jakarta.validation.metadata".ConstraintDescriptor
{
    private string type;
    private string[] names;
    private Any[] values;

    this(string type, string[] names = null, Any[] values = null)
    {
        this.type = type;
        this.names = names;
        this.values = values;
    }

    Any getAnnotation()
    {
        return Any.init;
    }

    string getAnnotationType()
    {
        return type;
    }

    string getMessageTemplate()
    {
        return "{message}";
    }

    Any getAttribute(string name)
    {
        foreach (i, n; names)
            if (n == name)
                return values[i];
        return Any.init;
    }

    string[] getAttributeNames()
    {
        return names;
    }

    bool isReportAsSingleViolation()
    {
        return false;
    }
}

private final class StubViolation : imported!"flint.jakarta.validation".ConstraintViolation
{
    import flint.jakarta.validation : Path;
    import flint.jakarta.validation.metadata : ConstraintDescriptor;

    private string message;
    private Path path;
    private Any invalid;
    private Any leaf;
    private ConstraintDescriptor descriptor;

    this(string message, Path path, Any invalid, Any leaf, ConstraintDescriptor descriptor)
    {
        this.message = message;
        this.path = path;
        this.invalid = invalid;
        this.leaf = leaf;
        this.descriptor = descriptor;
    }

    string getMessage()
    {
        return message;
    }

    string getMessageTemplate()
    {
        return message;
    }

    Any getRootBean()
    {
        return leaf;
    }

    string getRootBeanClass()
    {
        return leaf.typeName;
    }

    Any getLeafBean()
    {
        return leaf;
    }

    Path getPropertyPath()
    {
        return path;
    }

    Any getInvalidValue()
    {
        return invalid;
    }

    ConstraintDescriptor getConstraintDescriptor()
    {
        return descriptor;
    }
}

/// Rejects a blank name and a pet name shorter than 4, as Hibernate Validator would report them.
private final class StubValidator : imported!"flint.jakarta.validation".Validator
{
    import flint.jakarta.validation : ConstraintViolation, ElementKind;

    ConstraintViolation[] validate(Any object)
    {
        auto bean = object.get!TestBean;
        ConstraintViolation[] result;
        if (bean.name.length == 0)
            result ~= new StubViolation("must not be blank", new StubPath([new StubNode("name")]),
                    Any.of(bean.name), object, new StubDescriptor(typeNameOf!NotBlank));
        if (bean.pet !is null && bean.pet.name.length < 4)
            result ~= new StubViolation("size must be between {0} and 10",
                    new StubPath([new StubNode("pet"), new StubNode("name")]), Any.of(bean.pet.name),
                    Any.of(bean.pet), new StubDescriptor(typeNameOf!Size, [
                        "message", "max", "min", "groups"
        ], [Any.of("m"), Any.of(10), Any.of(4), Any.init]));
        if (bean.age < 0)
            result ~= new StubViolation("invalid", new StubPath([
            new StubNode(null, -1, ElementKind.BEAN)
        ]), object, object, new StubDescriptor(typeNameOf!NotBlank));
        return result;
    }

    ConstraintViolation[] validateProperty(Any object, string)
    {
        return validate(object);
    }

    ConstraintViolation[] validateValue(string, string, Any)
    {
        return null;
    }
}

private final class StubFactory : imported!"flint.jakarta.validation".ValidatorFactory
{
    import flint.jakarta.validation : JakartaValidator = Validator, MessageInterpolator;

    bool closed;

    JakartaValidator getValidator()
    {
        return new StubValidator;
    }

    MessageInterpolator getMessageInterpolator()
    {
        return null;
    }

    void close()
    {
        closed = true;
    }
}

private final class StubConfiguration : imported!"flint.jakarta.validation".Configuration
{
    import flint.jakarta.validation : Configuration, MessageInterpolator, ValidatorFactory;

    StubFactory factory;

    Configuration messageInterpolator(MessageInterpolator)
    {
        return this;
    }

    MessageInterpolator getDefaultMessageInterpolator()
    {
        return null;
    }

    ValidatorFactory buildValidatorFactory()
    {
        factory = new StubFactory;
        return factory;
    }
}

private final class StubProvider : imported!"flint.jakarta.validation.spi".ValidationProvider
{
    import flint.jakarta.validation : Configuration;

    StubConfiguration last;

    Configuration createGenericConfiguration()
    {
        last = new StubConfiguration;
        return last;
    }
}

unittest
{
    import flint.context : MessageSourceResolvable;
    import flint.jakarta.validation.spi : setProvider;
    import flint.java.util.function_ : Consumer;
    import flint.jakarta.validation : Configuration, ConstraintViolation;
    import flint.validation.beanvalidation : LocalValidatorFactoryBean, OptionalValidatorFactoryBean;

    // Without a provider, the optional bean stays inactive and the local bean fails.
    setProvider(null);
    auto optional = new OptionalValidatorFactoryBean;
    optional.afterPropertiesSet();
    assert(!optional.supports(testBean));

    auto provider = new StubProvider;
    setProvider(provider);
    scope (exit)
        setProvider(null);
    bool initialized;
    auto bean = new LocalValidatorFactoryBean;
    bean.setConfigurationInitializer(Consumer!Configuration.of((Configuration) { initialized = true; }));
    bean.afterPropertiesSet();
    assert(initialized && bean.supports(testBean));

    auto table = new DescriptorTable;
    table.add(descriptorOf!TestBean);
    table.add(descriptorOf!Pet);
    auto tb = new TestBean("");
    tb.pet = new Pet;
    tb.pet.name = "Rex";
    tb.age = -1;
    auto result = new BeanPropertyBindingResult(Any.of(tb), "testBean", table);
    bean.validate(Any.of(tb), result);
    assert(result.getErrorCount() == 3 && result.getGlobalErrorCount() == 1);

    auto name = result.getFieldError("name");
    assert(name.getCodes() == [
        "NotBlank.testBean.name", "NotBlank.name", "NotBlank.string", "NotBlank"
    ]);
    assert(name.getDefaultMessage() == "must not be blank" && !name.shouldRenderDefaultMessage());
    assert(name.contains!ConstraintViolation && name.unwrap!ConstraintViolation.getMessage() == "must not be blank");
    auto field = cast(MessageSourceResolvable) name.getArguments()[0].get!Object;
    assert(field.getCodes() == ["testBean.name", "name"] && field.getDefaultMessage() == "name");

    // A nested field reads the rejected value from the binding result; attributes follow in name order.
    auto petName = result.getFieldError("pet.name");
    assert(petName.getRejectedValue() == Any.of("Rex") && petName.shouldRenderDefaultMessage());
    assert(petName.getArguments().length == 3 && petName.getArguments()[1] == Any.of(10)
            && petName.getArguments()[2] == Any.of(4));
    assert(result.getGlobalError().getCodes() == ["NotBlank.testBean", "NotBlank"]);

    // A field that already failed binding keeps its binding error only.
    auto bound = new BeanPropertyBindingResult(Any.of(tb), "testBean", table);
    bound.addError(new FieldError("testBean", "name", Any.of("x"), true, ["typeMismatch"], null, null));
    bean.validate(Any.of(tb), bound);
    assert(bound.getFieldErrorCount("name") == 1);

    // Plain Errors get rejectValue calls with the violation's message.
    auto simple = new SimpleErrors(tb);
    bean.validate(Any.of(tb), simple);
    assert(simple.getFieldError("name").getCode() == "NotBlank");
    assert(simple.getFieldError("name").getDefaultMessage() == "must not be blank");

    const factory = provider.last.factory;
    bean.destroy();
    assert(factory.closed);
}
