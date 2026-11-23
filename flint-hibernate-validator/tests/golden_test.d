/// Message and path equality with Hibernate Validator 9.1.6.Final: the D twin of the bean in
/// tests/golden/GoldenValidation.java, whose violations the real Hibernate Validator wrote to
/// tests/golden/validation.tsv (path, message, template and invalid value, sorted).
module golden_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.hibernate.validator : HibernateValidatorConfiguration;
import flint.jakarta.validation : ConstraintViolation, Valid, Validation, Validator;
import flint.jakarta.validation.constraints;
import flint.java.time : Duration, Instant, LocalDate, LocalDateTime, LocalTime, OffsetDateTime, ZoneOffset,
    ZonedDateTime;
import flint.java.util : ArrayList, List, Optional;

@safe:

private final class Pet
{
    @NotBlank string name;
    @NotNull string type;

    this(string name, string type)
    {
        this.name = name;
        this.type = type;
    }
}

private final class Owner
{
    @NotBlank string firstName = "";
    @NotNull string lastName;
    @Size(min : 2, max:
            30) string city = "A";
    @Pattern(regexp : `\d{1,10}`) string telephone = "60855510239999";
    @Email string email = "not-an-email";
    @Email string goodEmail = "george@example.com";
    @Min(1) int age = 0;
    @Max(120) long maxAge = 150;
    @Positive int id = -3;
    @NegativeOrZero int debt = 5;
    @PositiveOrZero double balance = -0.5;
    @DecimalMax("99.5") double rating = 100.0;
    @DecimalMin(value : "0", inclusive:
            false) double price = 0.0;
    @Digits(integer : 3, fraction:
            2) double amount = 1234.567;
    @AssertTrue bool active = false;
    @AssertFalse bool deleted = true;
    @NotEmpty List!string tags;
    @Size(max : 2) List!string nicknames;
    @Null string nothing = "x";
    @NotBlank string blankName = " \t";
    @Size(min : 3, message:
            "'${validatedValue}' must have at least {min} characters") string code = "ab";
    @NotNull(message : `literal \{min\} and {min}`) string escaped;
    @Size(min : 1, max:
            5) string ok = "fine";
    @Past LocalDate birthDate = LocalDate.of(3000, 1, 1);
    @Future Instant expiry = Instant.parse("2000-01-01T00:00:00Z");
    @PastOrPresent LocalDateTime created = LocalDateTime.of(3000, 1, 1, 0, 0);
    @FutureOrPresent OffsetDateTime due = OffsetDateTime.of(2000, 1, 1, 0, 0, 0, 0, ZoneOffset.ofHours(2));
    @Future LocalTime closing = LocalTime.MIN;
    @Past ZonedDateTime okPast = ZonedDateTime.of(2000, 1, 1, 0, 0, 0, 0, ZoneOffset.UTC);
    @Future LocalDate okFuture = LocalDate.of(3000, 1, 1);
    @PastOrPresent Instant okNow = Instant.parse("2020-01-01T00:00:00Z");
    @Size(min : 4) int[] scores = [1, 2, 3];
    @NotEmpty string[] aliases = [];
    @Size(max : 1) int[string] limits;
    @Size(min : 1, max : 3) long[] okArray = [7];
    @Valid Pet[] petArray;
    @Valid Optional!Pet maybePet;
    @Valid Pet[string] petsByName;
    @Valid List!Pet pets;

    this()
    {
        limits = ["a": 1, "b": 2];
        petArray = [new Pet("Rex", null)];
        maybePet = Optional!Pet.of(new Pet("", "dog"));
        petsByName = ["tom": new Pet("Tom", null)];
        tags = new ArrayList!string();
        nicknames = new ArrayList!string();
        nicknames.add("a");
        nicknames.add("b");
        nicknames.add("c");
        pets = new ArrayList!Pet();
        pets.add(new Pet("  ", null));
        pets.add(new Pet("Leo", "cat"));
    }
}

// String.valueOf of the invalid value, as GoldenValidation prints it.
private string valueOf(Any value)
{
    import flint.engine.aot.objects : objectToString;
    import flint.serde.java_number : javaDoubleString;

    // A D array is never null (`[]` is null): it prints as Arrays.toString does.
    if (value.holds!(int[])())
        return list(value.get!(int[])());
    if (value.holds!(string[])())
        return list(value.get!(string[])());
    if (value.isNull())
        return "null";
    if (auto o = value.asObject())
        return objectToString(o);
    if (value.holds!string())
        return value.get!string();
    if (value.holds!bool())
        return value.get!bool() ? "true" : "false";
    if (value.holds!long())
        return value.toString();
    if (value.holds!(int[string])())
    {
        import std.algorithm.sorting : sort;
        import std.conv : to;

        auto map = value.get!(int[string])();
        string text = "{";
        foreach (k; map.keys.sort)
            text ~= (text.length > 1 ? ", " : "") ~ k ~ "=" ~ map[k].to!string;
        return text ~ "}";
    }
    static foreach (T; imported!"std.meta".AliasSeq!(Instant, LocalDate, LocalDateTime, LocalTime, OffsetDateTime,
            ZonedDateTime))
        if (value.holds!T())
            return value.get!T().toString();
    return javaDoubleString(value.get!double());
}

// Arrays.toString.
private string list(T)(const(T)[] items)
{
    import std.conv : to;

    string text = "[";
    foreach (i, item; items)
        text ~= (i ? ", " : "") ~ item.to!string;
    return text ~ "]";
}

private Validator validator()
{
    auto table = DescriptorTable.withBuiltins();
    table.add(descriptorOf!Owner());
    table.add(descriptorOf!Pet());
    foreach (d; [
            descriptorOf!(int[])(), descriptorOf!(string[])(), descriptorOf!(int[string])(),
            descriptorOf!(long[])(), descriptorOf!(Pet[])(), descriptorOf!(Optional!Pet)(),
            descriptorOf!(Pet[string])()
        ])
        table.add(d);
    auto configuration = cast(HibernateValidatorConfiguration) Validation.byDefaultProvider();
    assert(configuration !is null, "Hibernate Validator registers itself as the default provider");
    return configuration.descriptors(table).buildValidatorFactory().getValidator();
}

@("golden: paths, interpolated messages, templates and invalid values match Hibernate Validator")
unittest
{
    string[] lines;
    foreach (v; validator().validate(new Owner()))
        lines ~= v.getPropertyPath()
            .toString() ~ "\t" ~ v.getMessage() ~ "\t" ~ v.getMessageTemplate() ~ "\t" ~ valueOf(v.getInvalidValue());
    import std.algorithm.sorting : sort;
    import std.array : join;

    lines.sort();
    const actual = lines.join("\n") ~ "\n";
    const expected = import("validation.tsv");
    if (actual != expected)
    {
        import std.string : splitLines;

        auto want = expected.splitLines();
        foreach (i, line; lines)
            assert(i < want.length && line == want[i],
                    "\nflint:     " ~ line ~ "\nhibernate: " ~ (i < want.length ? want[i] : "(none)"));
        assert(false, "missing lines after " ~ lines[$ - 1]);
    }
}

@("validateProperty checks one property and does not cascade")
unittest
{
    auto violations = validator().validateProperty(new Owner(), "city");
    assert(violations.length == 1 && violations[0].getMessage() == "size must be between 2 and 30");
    assert(validator().validateProperty(new Owner(), "ok").length == 0);
}

@("validateValue checks a value against a property's constraints")
unittest
{
    auto violations = validator().validateValue("golden_test.Owner", "age", Any.of(5));
    assert(violations.length == 0);
    violations = validator().validateValue("golden_test.Owner", "age", Any.of(-1));
    assert(violations.length == 1 && violations[0].getPropertyPath().toString() == "age");
}

private final class Wrong
{
    @Past Duration elapsed;
}

@("HV000030 for @Past on a java.time type Hibernate has no validator for")
unittest
{
    import flint.jakarta.validation : UnexpectedTypeException;

    auto table = DescriptorTable.withBuiltins();
    table.add(descriptorOf!Wrong());
    auto configuration = cast(HibernateValidatorConfiguration) Validation.byDefaultProvider();
    auto v = configuration.descriptors(table).buildValidatorFactory().getValidator();
    try
    {
        v.validate(new Wrong());
        assert(false);
    }
    catch (UnexpectedTypeException e)
        assert(e.msg == "HV000030: No validator could be found for constraint "
                ~ "'jakarta.validation.constraints.Past' validating type 'java.time.Duration'. "
                ~ "Check configuration for 'elapsed'");
}
