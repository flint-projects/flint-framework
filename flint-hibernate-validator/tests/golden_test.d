/// Message and path equality with Hibernate Validator 9.1.6.Final: the D twin of the bean in
/// tests/golden/GoldenValidation.java, whose violations the real Hibernate Validator wrote to
/// tests/golden/validation.tsv (path, message, template and invalid value, sorted).
module golden_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.hibernate.validator : HibernateValidatorConfiguration;
import flint.jakarta.validation : Constraint, ConstraintValidator, ConstraintValidatorContext,
    ConstraintViolation, Valid, Validation, Validator;
import flint.java.lang : classOf;
import flint.jakarta.validation.constraints;
import flint.java.time : Duration, Instant, LocalDate, LocalDateTime, LocalTime, OffsetDateTime,
    ZoneOffset, ZonedDateTime;
import flint.java.util : ArrayList, List, Optional;
import std.typecons : Nullable;

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

/// spring-petclinic-rest's PetAgeValidation and PetAgeValidator.
@Constraint(validatedBy : [classOf!PetAgeValidator])
private struct PetAgeValidation
{
    string message = "Birth date must not be in the future or older than 50 years";
}

private final class PetAgeValidator : ConstraintValidator!(PetAgeValidation, LocalDate)
{
    void initialize(PetAgeValidation)
    {
    }

    bool isValid(LocalDate birthDate, ConstraintValidatorContext context)
    {
        const today = LocalDate.now();
        if (birthDate.isAfter(today))
        {
            context.disableDefaultConstraintViolation();
            context.buildConstraintViolationWithTemplate("Birth date cannot be in the future").addConstraintViolation();
            return false;
        }
        if (birthDate.isBefore(today.minusYears(50)))
        {
            context.disableDefaultConstraintViolation();
            context.buildConstraintViolationWithTemplate("Birth date cannot be older than 50 years")
                .addConstraintViolation();
            return false;
        }
        return true;
    }
}

/// A custom constraint that keeps its default violation and adds one with an attribute in its template.
@Constraint(validatedBy : [classOf!EvenValidator])
private struct Even
{
    string message = "must be even, not ${validatedValue}";
    int divisor = 2;
}

private final class EvenValidator : ConstraintValidator!(Even, int)
{
    private int divisor;

    void initialize(Even even)
    {
        divisor = even.divisor;
    }

    bool isValid(int value, ConstraintValidatorContext context)
    {
        if (value % divisor == 0)
            return true;
        context.buildConstraintViolationWithTemplate("{divisor} does not divide it").addConstraintViolation();
        return false;
    }
}

/// The @Pattern expressions spring-petclinic-rest's DTOs declare, on non-ASCII input. (Java's `unset = null`
/// birth date has no D twin: a struct is never null.)
private final class Petclinic
{
    @Pattern(regexp : `^[\p{L}]+([ '-][\p{L}]+){0,2}$`) string spanish = "Jos\u00e9 Mar\u00eda";
    @Pattern(regexp : `^[\p{L}]+([ '-][\p{L}]+){0,2}$`) string chinese = "\u674e";
    @Pattern(regexp : `^[\p{L}]+([ '-][\p{L}]+){0,2}$`) string supplementary = "\U0001D49Cda";
    @Pattern(regexp : `^[\p{L}]+([ '-][\p{L}]+){0,2}$`) string greekDigit = "\u0395\u03bb\u03ad\u03bd\u03b7 2";
    @Pattern(regexp : `^[\p{L}]+([ '-][\p{L}]+){0,2}$`) string combining = "Rene\u0301e";
    @Pattern(regexp : `^[\p{L}]+([ '-][\p{L}]+){0,2}\.?$`) string fourParts = "Van Der Berg Smith";
    @Pattern(regexp : `[\s\S]*\S[\s\S]*`) string blank = " \t ";
    @Pattern(regexp : `[\s\S]*\S[\s\S]*`) string nbsp = "\u00a0";
    @Pattern(regexp : `^[\p{L}][\p{L}\s\-']{0,79}$`) string petType = "\u00dcnicorn's-pet";
    @Pattern(regexp : `^[\p{L}][\p{L}\s\-']{0,79}$`) string digitFirst = "9cats";
    @Pattern(regexp : `^[\p{L}][\p{L}\s\-&/]{0,79}$`) string specialty = "dentistry & surgery/x";
    @Pattern(regexp : `^ROLE_[A-Z][A-Z0-9_]{1,74}$`) string role = "OWNER_ADMIN";
    @Pattern(regexp : `\P{L}+`) string notLetters = "12\u00e9";
    @PetAgeValidation LocalDate future = LocalDate.of(2999, 1, 1);
    @PetAgeValidation LocalDate ancient = LocalDate.of(1900, 1, 1);
    @PetAgeValidation LocalDate fine = LocalDate.of(2020, 2, 2);
    @NotNull Nullable!int missingId;
    @Min(1) Nullable!int zeroId = Nullable!int(0);
    @Min(1) Nullable!int nullId;
    @Even int odd = 7;
    @Even(divisor : 5) int five = 10;
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
    @Size(min : 1, max:
            3) long[] okArray = [7];
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

    if (value.typeName().length == 0)
        return "null";
    // A D array is never null (`[]` is null): it prints as Arrays.toString does.
    if (value.holds!(int[])())
        return list(value.get!(int[])());
    if (value.holds!(string[])())
        return list(value.get!(string[])());
    if (value.isNull())
        return "null";
    if (auto o = value.asObject())
        return objectToString(o);
    if (value.holds!(int[string])())
        return mapText(value.get!(int[string])());
    return scalarText(value);
}

// String.valueOf of a String, boolean, integral, java.time or floating-point value.
private string scalarText(Any value)
{
    import flint.serde.java_number : javaDoubleString;

    if (value.holds!string())
        return value.get!string();
    if (value.holds!bool())
        return value.get!bool() ? "true" : "false";
    if (value.holds!long())
        return value.toString();
    static foreach (T; imported!"std.meta".AliasSeq!(Instant, LocalDate, LocalDateTime, LocalTime,
            OffsetDateTime, ZonedDateTime))
        if (value.holds!T())
            return value.get!T().toString();
    return javaDoubleString(value.get!double());
}

// A HashMap's toString, keys sorted (the golden file sorts them too).
private string mapText(const int[string] map)
{
    import std.algorithm.sorting : sort;
    import std.conv : to;

    string text = "{";
    foreach (k; map.keys.sort)
        text ~= (text.length > 1 ? ", " : "") ~ k ~ "=" ~ map[k].to!string;
    return text ~ "}";
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
    table.add(descriptorOf!Petclinic());
    table.add(descriptorOf!(Nullable!int)());
    auto configuration = cast(HibernateValidatorConfiguration) Validation.byDefaultProvider();
    assert(configuration !is null, "Hibernate Validator registers itself as the default provider");
    auto mapping = configuration.createConstraintMapping();
    mapping.constraintDefinition!PetAgeValidation().validatedBy!PetAgeValidator();
    mapping.constraintDefinition!Even().includeExistingValidators(false).validatedBy!EvenValidator();
    return configuration.descriptors(table).addMapping(mapping).buildValidatorFactory().getValidator();
}

@("golden: paths, interpolated messages, templates and invalid values match Hibernate Validator")
unittest
{
    string[] lines;
    auto validator = validator();
    foreach (v; validator.validate(new Owner()) ~ validator.validate(new Petclinic()))
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
