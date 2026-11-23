/// MethodValidationInterceptor and MethodValidationPostProcessor over a stub executable validator: which methods
/// they advise, the order of validation around the call, unwrapping a SpringValidatorAdapter, and the
/// ConstraintViolationException they throw. Hibernate Validator's own executable validation is tested in
/// flint-hibernate-validator/tests/executable_validation_test.d.
module method_validation_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, MergedAnnotation, MethodDescriptor, ParameterDescriptor, TypeKind;
import flint.engine.aot.name : typeNameOf;
import flint.engine.aot.proxy : Invocation;
import flint.jakarta.validation : ConstraintViolation, ConstraintViolationException, ElementKind,
    JakartaValidator = Validator, Path, ValidationException;
import flint.jakarta.validation.executable : ExecutableValidator;
import flint.jakarta.validation.metadata : ConstraintDescriptor;
import flint.validation.annotation : Validated;
import flint.validation.beanvalidation : MethodValidationInterceptor, MethodValidationPostProcessor,
    SpringValidatorAdapter;

@safe:

private final class StubPath : Path
{
    private string text;

    this(string text)
    {
        this.text = text;
    }

    Node[] nodes()
    {
        return null;
    }

    override string toString() const
    {
        return text;
    }
}

private final class StubViolation : ConstraintViolation
{
    private string path;
    private string message;

    this(string path, string message)
    {
        this.path = path;
        this.message = message;
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
        return Any.init;
    }

    string getRootBeanClass()
    {
        return null;
    }

    Any getLeafBean()
    {
        return Any.init;
    }

    Path getPropertyPath()
    {
        return new StubPath(path);
    }

    Any getInvalidValue()
    {
        return Any.init;
    }

    ConstraintDescriptor getConstraintDescriptor()
    {
        return null;
    }
}

/// Rejects a negative `int` argument (`@Min(0)`) and a negative return value, and records what it saw.
private final class StubExecutableValidator : JakartaValidator, ExecutableValidator
{
    alias validate = JakartaValidator.validate;
    alias validateProperty = JakartaValidator.validateProperty;

    string[] calls;
    string rootType;

    ConstraintViolation[] validate(Any)
    {
        return null;
    }

    ConstraintViolation[] validateProperty(Any, string)
    {
        return null;
    }

    ConstraintViolation[] validateValue(string, string, Any)
    {
        return null;
    }

    ConstraintViolation[] validateParameters(Any object, scope const(MethodDescriptor)* method, Any[] parameterValues)
    {
        calls ~= "parameters";
        rootType = object.typeName();
        ConstraintViolation[] violations;
        foreach (i, value; parameterValues)
            if (value.holds!int && value.get!int < 0)
                violations ~= new StubViolation(method.name ~ "." ~ method.parameters[i].name,
                        "must be greater than or equal to 0");
        return violations;
    }

    ConstraintViolation[] validateReturnValue(Any, scope const(MethodDescriptor)* method, Any returnValue)
    {
        calls ~= "return";
        if (returnValue.holds!int && returnValue.get!int < 0)
            return [
            new StubViolation(method.name ~ ".<return value>", "must be greater than or equal to 0")
        ];
        return null;
    }
}

private final class PetController
{
}

private Descriptor descriptor(bool validated)
{
    auto d = new Descriptor(typeNameOf!PetController, TypeKind.class_);
    if (validated)
        d.annotations = [MergedAnnotation(typeNameOf!Validated, Any.of(Validated()), 0)];
    MethodDescriptor method;
    method.name = "getPet";
    method.returnType = "int";
    method.parameters = [ParameterDescriptor("petId", "int", null)];
    d.methods = [method];
    return d;
}

private Invocation invocation(Descriptor d, int argument)
{
    Invocation call;
    call.method = &d.methods[0];
    call.target = new PetController();
    call.arguments = [Any.of(argument)];
    return call;
}

private string thrownMessage(scope void delegate() @safe action)
{
    try
        action();
    catch (ConstraintViolationException ex)
        return ex.msg;
    return null;
}

@("MethodValidationInterceptor advises only the methods of @Validated beans")
unittest
{
    auto interceptor = new MethodValidationInterceptor(new StubExecutableValidator());
    auto validated = descriptor(true), plain = descriptor(false);
    assert(interceptor.appliesTo(validated, &validated.methods[0]));
    assert(!interceptor.appliesTo(plain, &plain.methods[0]));
    assert(interceptor.getOrder() == int.max);

    // An annotated interface: Flint AOT merges its @Validated onto the implementing methods.
    plain.methods[0].annotations = [MergedAnnotation(typeNameOf!Validated, Any.of(Validated()), 0)];
    assert(interceptor.appliesTo(plain, &plain.methods[0]));
}

@("MethodValidationInterceptor validates the arguments, proceeds, then validates the return value")
unittest
{
    auto validator = new StubExecutableValidator();
    auto interceptor = new MethodValidationInterceptor(validator);
    auto d = descriptor(true);
    assert(interceptor.appliesTo(d, &d.methods[0]));

    auto call = invocation(d, 7);
    bool proceeded;
    interceptor.invoke(call, (ref Invocation next) @safe { proceeded = true; next.result = Any.of(1); });
    assert(proceeded && validator.calls == ["parameters", "return"]);
    assert(validator.rootType == typeNameOf!PetController);
    assert(call.result == Any.of(1));
}

@("MethodValidationInterceptor throws ConstraintViolationException before the call for an invalid argument")
unittest
{
    auto validator = new StubExecutableValidator();
    auto interceptor = new MethodValidationInterceptor(validator);
    auto d = descriptor(true);
    interceptor.appliesTo(d, &d.methods[0]);

    bool proceeded;
    const message = thrownMessage(() {
        auto call = invocation(d, -1);
        interceptor.invoke(call, (ref Invocation next) @safe { proceeded = true; });
    });
    assert(message == "getPet.petId: must be greater than or equal to 0", message);
    assert(!proceeded && validator.calls == ["parameters"]);

    // The return value is checked after the call.
    const returned = thrownMessage(() {
        auto call = invocation(d, 3);
        interceptor.invoke(call, (ref Invocation next) @safe { next.result = Any.of(-5); });
    });
    assert(returned == "getPet.<return value>: must be greater than or equal to 0", returned);
}

@("MethodValidationInterceptor unwraps a SpringValidatorAdapter to its Jakarta target")
unittest
{
    auto target = new StubExecutableValidator();
    auto interceptor = new MethodValidationInterceptor(new SpringValidatorAdapter(target));
    auto d = descriptor(true);
    interceptor.appliesTo(d, &d.methods[0]);
    auto call = invocation(d, -1);
    assert(thrownMessage(() { interceptor.invoke(call, (ref Invocation next) @safe {}); }) !is null);
    assert(target.calls == ["parameters"]);
}

@("MethodValidationPostProcessor is the advisor, over the validator it was given")
unittest
{
    auto validator = new StubExecutableValidator();
    auto postProcessor = new MethodValidationPostProcessor();
    postProcessor.setValidator(validator);
    postProcessor.setOrder(5);
    postProcessor.afterPropertiesSet();
    auto d = descriptor(true);
    assert(postProcessor.appliesTo(d, &d.methods[0]) && postProcessor.getOrder() == 5);
    auto call = invocation(d, -2);
    assert(thrownMessage(() { postProcessor.invoke(call, (ref Invocation next) @safe {}); }) !is null);

    // Another marker annotation.
    auto custom = new MethodValidationPostProcessor();
    custom.setValidator(validator);
    custom.setValidatedAnnotationType("app.MyValidated");
    custom.afterPropertiesSet();
    assert(!custom.appliesTo(d, &d.methods[0]));
}

@("a validator without executable validation is reported")
unittest
{
    final class BeanOnly : JakartaValidator
    {
        alias validate = JakartaValidator.validate;
        alias validateProperty = JakartaValidator.validateProperty;

        ConstraintViolation[] validate(Any)
        {
            return null;
        }

        ConstraintViolation[] validateProperty(Any, string)
        {
            return null;
        }

        ConstraintViolation[] validateValue(string, string, Any)
        {
            return null;
        }
    }

    auto interceptor = new MethodValidationInterceptor(new BeanOnly());
    auto d = descriptor(true);
    interceptor.appliesTo(d, &d.methods[0]);
    auto call = invocation(d, 1);
    bool reported;
    try
        interceptor.invoke(call, (ref Invocation next) @safe {});
    catch (ValidationException ex)
        reported = ex.msg.length != 0;
    assert(reported);
}
