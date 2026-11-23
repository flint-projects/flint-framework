/++
Flint's own tests of `DefaultDataBinderFactory`, the stand-in for the `DefaultFormattingConversionService` that
Spring's `ConfigurableWebBindingInitializer` hands the binder. They cover:
- blank values, which become null for non-string targets, as `StringToBooleanConverter`, the number and
  character converters and `FormattingConversionService.ParserConverter` make them (gh-31336);
- `java.time` values, through `TemporalAccessorParser`'s ISO fallback;
- `Optional!T` and collection targets, through their descriptors.
+/
module flint.web.default_data_binder_factory_tests;

import flint.core.convert : ConversionFailedException;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.java.time : Instant, LocalDate, LocalDateTime, LocalTime;
import flint.java.util : List, Optional;
import flint.web.bind.support : DefaultDataBinderFactory;

@safe:

private Any convert(string value, string targetType, DescriptorTable descriptors = null)
{
    return new DefaultDataBinderFactory(descriptors).convertIfNecessary(Any.of(value), targetType, null);
}

private bool conversionFails(string value, string targetType)
{
    try
        convert(value, targetType);
    catch (ConversionFailedException)
        return true;
    return false;
}

@("DefaultDataBinderFactory converts a blank value to null unless the target is a string")
unittest
{
    foreach (type; ["bool", "int", "long", "double", typeNameOf!LocalDate])
    {
        assert(convert("", type).isNull(), type);
        assert(convert("   ", type).isNull(), type);
    }
    assert(convert("", "char").isNull());
    assert(convert(" ", "char").get!char == ' ');
    assert(convert("  ", "string").get!string == "  ");
}

@("DefaultDataBinderFactory parses java.time values in their ISO forms")
unittest
{
    assert(convert("2024-01-15", typeNameOf!LocalDate).get!LocalDate.toString() == "2024-01-15");
    assert(convert(" 10:15:30 ", typeNameOf!LocalTime).get!LocalTime.toString() == "10:15:30");
    assert(convert("2024-01-15T10:15:30", typeNameOf!LocalDateTime)
            .get!LocalDateTime.toString() == "2024-01-15T10:15:30");
    assert(convert("2024-01-15T10:15:30Z", typeNameOf!Instant).get!Instant.toString() == "2024-01-15T10:15:30Z");
    assert(conversionFails("2024-13-45", typeNameOf!LocalDate));
    assert(conversionFails("yesterday", typeNameOf!Instant));
}

@("DefaultDataBinderFactory names java.time types as Java does in conversion failures")
unittest
{
    try
    {
        convert("not-a-date", typeNameOf!LocalDate);
        assert(false);
    }
    catch (ConversionFailedException ex)
        assert(ex.getTargetType().getName() == "java.time.LocalDate", ex.getTargetType().getName());
}

@("DefaultDataBinderFactory wraps Optional targets through their descriptors")
unittest
{
    auto descriptors = new DescriptorTable;
    descriptors.add(descriptorOf!(Optional!LocalDate));
    const date = convert("2024-01-15", typeNameOf!(Optional!LocalDate), descriptors).get!(Optional!LocalDate);
    assert(date.isPresent() && date.get().toString() == "2024-01-15");

    const blank = convert(" ", typeNameOf!(Optional!LocalDate), descriptors).get!(Optional!LocalDate);
    assert(blank.isEmpty());

    auto factory = new DefaultDataBinderFactory(descriptors);
    assert(factory.convertIfNecessary(Any.init, typeNameOf!(Optional!LocalDate), null)
            .get!(Optional!LocalDate).isEmpty());
}

@("DefaultDataBinderFactory converts each value of a multi-valued parameter")
unittest
{
    auto descriptors = new DescriptorTable;
    descriptors.add(descriptorOf!(List!long));
    auto factory = new DefaultDataBinderFactory(descriptors);
    assert(factory.convertIfNecessary(Any.of(["1", "2"]), "int[]", null).get!(int[]) == [1, 2]);
    assert(factory.convertIfNecessary(Any.of(["3", "4"]), typeNameOf!(List!long), null).get!(List!long)
            .toArray() == [3L, 4L]);
    // ArrayToObjectConverter: a single-valued target takes the first value.
    assert(factory.convertIfNecessary(Any.of(["5", "6"]), "int", null).get!int == 5);
}

@("DefaultDataBinderFactory fills a list through an erased descriptor (create and addAny, no fromElements)")
unittest
{
    import flint.java.util : ArrayList;
    import flint.java.util.descriptors : rawListDescriptor;

    auto descriptors = new DescriptorTable;
    descriptors.add(rawListDescriptor(typeNameOf!(List!long), "long",
            () @safe => Any.of!(List!long)(new ArrayList!long)));
    auto factory = new DefaultDataBinderFactory(descriptors);
    auto list = factory.convertIfNecessary(Any.of(["7", "8"]), typeNameOf!(List!long), null).get!(List!long);
    assert(list.toArray() == [7L, 8L]);
}
