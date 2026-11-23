/// Hibernate Validator as the default provider: a bean validated through a Flint AOT descriptor.
module app;

import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.hibernate.validator : HibernateValidatorConfiguration;
import flint.jakarta.validation : Validation;
import flint.jakarta.validation.constraints : NotBlank, Size;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

/// @Size(min = 2, max = 30), written without named arguments for the formatter.
private enum Size cityLength = () { Size size; size.min = 2; size.max = 30; return size; }();

private final class Owner
{
    @NotBlank
    string firstName;
    @cityLength
    string city;

    this(string firstName, string city)
    {
        this.firstName = firstName;
        this.city = city;
    }
}

int main(string[] args)
{
    auto table = DescriptorTable.withBuiltins();
    table.add(descriptorOf!Owner());
    auto configuration = cast(HibernateValidatorConfiguration) Validation.byDefaultProvider();
    auto validator = configuration.descriptors(table).buildValidatorFactory().getValidator();
    string outcome;
    foreach (violation; validator.validate(new Owner(args.length > 1 ? "George" : "", "A")))
        outcome ~= violation.getPropertyPath().toString() ~ ":" ~ violation.getMessage() ~ ";";
    emit(outcome);
    return 0;
}
