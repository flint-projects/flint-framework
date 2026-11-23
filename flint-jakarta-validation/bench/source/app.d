/// Jakarta Validation: constraint UDAs read at compile time, and bootstrapping without a provider.
module app;

import flint.jakarta.validation : NoProviderFoundException, Validation;
import flint.jakarta.validation.constraints : Min, NotNull;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

private struct Visit
{
    @NotNull string description;
    @Min(1) int pets;
}

int main(string[] args)
{
    // A bare @NotNull attaches the type; Flint AOT reads it as NotNull.init.
    static assert(is(__traits(getAttributes, Visit.description)[0] == NotNull));
    enum template_ = NotNull.init.message;
    enum least = __traits(getAttributes, Visit.pets)[0].value;
    string outcome = args.length > 1 ? template_ : template_ ~ " " ~ cast(char)('0' + least);
    try
        Validation.buildDefaultValidatorFactory();
    catch (NoProviderFoundException)
        outcome ~= " no-provider";
    emit(outcome);
    return 0;
}
