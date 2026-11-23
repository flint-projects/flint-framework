/// Jakarta Validation: constraint UDAs read at compile time, and bootstrapping without a provider.
module app;

import flint.jakarta.validation : NoProviderFoundException, Validation;
import flint.jakarta.validation.constraints : Min, NotNull;
import std.stdio : writeln;

@safe:

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
    writeln(outcome);
    return 0;
}
