/// The Jakarta constraint UDAs keep the specification's defaults, and bootstrapping without a provider fails as
/// the specification says.
module validation_test;

import flint.jakarta.validation : ConstraintViolationException, NoProviderFoundException, Validation;
import flint.jakarta.validation.constraints;

@safe:

@("constraint defaults: message keys and bounds")
unittest
{
    static assert(NotNull.init.message == "{jakarta.validation.constraints.NotNull.message}");
    static assert(Size.init.min == 0 && Size.init.max == int.max);
    static assert(Size.init.message == "{jakarta.validation.constraints.Size.message}");
    static assert(DecimalMin.init.inclusive && DecimalMax.init.inclusive);
    static assert(Email.init.regexp == ".*" && Email.init.flags.length == 0);
    static assert(Pattern.Flag.CASE_INSENSITIVE == 2 && Pattern.Flag.CANON_EQ == 0x80);
    static assert(Min(5).value == 5 && Max(7).value == 7 && DecimalMax("9.5").value == "9.5");
    static assert(Size.List([Size(min: 1, max: 2), Size(min: 3, max: 4)]).value.length == 2);
}

@("bootstrapping with no provider registered throws NoProviderFoundException")
unittest
{
    import flint.jakarta.validation.spi : registeredProvider;

    if (registeredProvider() is null)
    {
        try
        {
            Validation.buildDefaultValidatorFactory();
            assert(false);
        }
        catch (NoProviderFoundException e)
            assert(e.msg.length > 0);
    }
}

@("ConstraintViolationException carries its violations")
unittest
{
    auto e = new ConstraintViolationException("bad", null);
    assert(e.getConstraintViolations().length == 0 && e.msg == "bad");
}
