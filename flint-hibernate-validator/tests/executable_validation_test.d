/// Executable validation: method parameters and return values checked against the constraints Flint AOT records in
/// a method's descriptor, with Hibernate Validator's paths and messages (`listPets.size`, `must be greater than or
/// equal to 1`).
module executable_validation_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, MergedAnnotation, MethodDescriptor,
    ParameterDescriptor, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator : HibernateValidatorConfiguration;
import flint.jakarta.validation : ConstraintViolation, ElementKind, Valid, Validation, ValidationException, Validator;
import flint.jakarta.validation.constraints : Max, Min, NotBlank, NotNull;
import flint.jakarta.validation.executable : ExecutableValidator;

@safe:

private final class Owner
{
    @NotBlank
    string firstName;

    this(string firstName)
    {
        this.firstName = firstName;
    }
}

private final class PetController
{
}

private MergedAnnotation annotation(T)(T value)
{
    return MergedAnnotation(typeNameOf!T, Any.of(value), 0);
}

// The descriptor Flint AOT writes for petclinic-rest's PetV2Api.listPets(@Min(0) Integer page,
// @Min(1) @Max(100) Integer size).
private MethodDescriptor listPets()
{
    MethodDescriptor method;
    method.name = "listPets";
    method.returnType = "string";
    method.parameters = [
        ParameterDescriptor("page", "int", [annotation(Min(0))]),
        ParameterDescriptor("size", "int", [annotation(Min(1)), annotation(Max(100))]),
    ];
    return method;
}

private ExecutableValidator executableValidator()
{
    auto table = new DescriptorTable;
    table.add(descriptorOf!Owner);
    auto configuration = cast(HibernateValidatorConfiguration) Validation.byDefaultProvider();
    return configuration.descriptors(table).buildValidatorFactory().getValidator().forExecutables();
}

private Any controller()
{
    return Any.of(new PetController());
}

@("validateParameters reports each failing parameter with a method.parameter path")
unittest
{
    auto validator = executableValidator();
    const method = listPets();
    assert(validator.validateParameters(controller(), &method, [Any.of(0), Any.of(20)]).length == 0);

    auto violations = validator.validateParameters(controller(), &method, [Any.of(-1), Any.of(0)]);
    assert(violations.length == 2);
    assert(violations[0].getPropertyPath().toString() == "listPets.page");
    assert(violations[0].getMessage() == "must be greater than or equal to 0", violations[0].getMessage());
    assert(violations[1].getPropertyPath().toString() == "listPets.size");
    assert(violations[1].getMessage() == "must be greater than or equal to 1");
    assert(violations[1].getInvalidValue() == Any.of(0));
    assert(violations[1].getRootBeanClass() == typeNameOf!PetController);

    auto nodes = violations[1].getPropertyPath().nodes();
    assert(nodes.length == 2);
    assert(nodes[0].getKind() == ElementKind.METHOD && nodes[0].getName() == "listPets");
    assert(nodes[1].getKind() == ElementKind.PARAMETER && nodes[1].getName() == "size");

    violations = validator.validateParameters(controller(), &method, [Any.of(0), Any.of(101)]);
    assert(violations.length == 1 && violations[0].getMessage() == "must be less than or equal to 100");
}

@("validateParameters cascades into a @Valid parameter")
unittest
{
    MethodDescriptor method;
    method.name = "addOwner";
    method.returnType = "void";
    method.parameters = [
        ParameterDescriptor("owner", typeNameOf!Owner, [annotation(Valid()), annotation(NotNull())])
    ];
    auto validator = executableValidator();
    auto violations = validator.validateParameters(controller(), &method, [Any.of(new Owner(" "))]);
    assert(violations.length == 1);
    assert(violations[0].getPropertyPath().toString() == "addOwner.owner.firstName");
    assert(violations[0].getMessage() == "must not be blank");

    violations = validator.validateParameters(controller(), &method, [Any.init]);
    assert(violations.length == 1 && violations[0].getPropertyPath().toString() == "addOwner.owner");
    assert(violations[0].getMessage() == "must not be null");
}

@("validateReturnValue checks the method's return-value constraints")
unittest
{
    MethodDescriptor method;
    method.name = "findName";
    method.returnType = "string";
    method.annotations = [annotation(NotBlank())];
    auto validator = executableValidator();
    assert(validator.validateReturnValue(controller(), &method, Any.of("Leo")).length == 0);
    auto violations = validator.validateReturnValue(controller(), &method, Any.of(""));
    assert(violations.length == 1);
    assert(violations[0].getPropertyPath().toString() == "findName.<return value>");
}

@("validateParameters rejects a wrong number of values")
unittest
{
    auto validator = executableValidator();
    const method = listPets();
    bool thrown;
    try
        validator.validateParameters(controller(), &method, [Any.of(1)]);
    catch (ValidationException ex)
        thrown = ex.msg
            == "HV000181: Wrong number of parameters. Method or constructor listPets expects 2 parameters,"
            ~ " but got 1.";
    assert(thrown);
}
