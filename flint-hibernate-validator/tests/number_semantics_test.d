/++
Flint tests: the number constraints' Java semantics, each case checked against Hibernate Validator 9.1.6.Final on
Java 21 (Spring Boot 4.2's resolution) with this probe, whose output the assertions repeat:

    public static class B {
        @PositiveOrZero public Double pz;          // -0.0
        @Negative public Double neg;               // -0.0
        @Min(0) public Double min0;                // -0.0
        @Min(16777217) public Float minF;          // 16777216f
        @Digits(integer = 1, fraction = 1) public String digitsText;  // "1.10"
        @Max(10) public String maxText;            // " 5"
        @DecimalMin("0.1") public Float decF;      // 0.1f
        @DecimalMax("9223372036854775806") public Long decL;          // Long.MAX_VALUE
    }
    -> decL, digitsText, maxText, min0 and pz are violated; neg, minF and decF are valid.

Double.compare orders -0.0 before 0; Float.compare widens the long bound to float; a CharSequence is
new BigDecimal(text) (no whitespace, trailing zeros counted by @Digits); BigDecimal.valueOf(Float) reads the widened
double; and a decimal bound is exact. The initialize checks and the NaN @Digits case print as Hibernate's messages.
+/
module flint.hibernate.validator.number_semantics_test;

import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.validator_test_support : assertOnlyViolationMessages, isValidFor,
    validatorFor, violationOf;
import flint.jakarta.validation : ValidationException;
import flint.jakarta.validation.constraints : DecimalMax, DecimalMin, Digits, Max, Min, Negative,
    Pattern, PositiveOrZero, Size;

@safe:

private final class B
{
    @PositiveOrZero
    double pz = -0.0;
    @Negative
    double neg = -0.0;
    @Min(0)
    double min0 = -0.0;
    @Min(16_777_217)
    float minF = 16_777_216f;
    @Digits(integer: 1, fraction: 1)
    string digitsText = "1.10";
    @Max(10)
    string maxText = " 5";
    @DecimalMin("0.1")
    float decF = 0.1f;
    @DecimalMax("9223372036854775806")
    long decL = long.max;
}

@("number constraints follow Double.compare, Float.compare and BigDecimal, as Hibernate does")
unittest
{
    auto violations = validatorFor!B().validate(new B());
    assertOnlyViolationMessages(violations,
            violationOf(typeNameOf!DecimalMax,
                "must be less than or equal to 9223372036854775806"), violationOf(typeNameOf!Digits,
                "numeric value out of bounds (<1 digits>.<1 digits> expected)"),
            violationOf(typeNameOf!Max, "must be less than or equal to 10"), violationOf(typeNameOf!Min,
                "must be greater than or equal to 0"),
            violationOf(typeNameOf!PositiveOrZero, "must be greater than or equal to 0"));
}

private void expectInitializeFailure(scope bool delegate() @safe check, string message, string cause)
{
    try
    {
        check();
        assert(false, "expected " ~ message);
    }
    catch (ValidationException e)
    {
        assert(e.msg == message, e.msg);
        const actual = e.getCause();
        assert(actual !is null && actual.msg == cause, actual is null ? "no cause" : actual.msg);
    }
}

@("invalid constraint attributes fail initialize with HV000032 and Hibernate's cause")
unittest
{
    enum bv = "org.hibernate.validator.internal.constraintvalidators.bv.";
    expectInitializeFailure(() => isValidFor(DecimalMin("foobar"), 1),
            "HV000032: Unable to initialize " ~ bv ~ "number.bound.decimal.DecimalMinValidatorForInteger.",
            "HV000016: foobar does not represent a valid BigDecimal format.");
    expectInitializeFailure(() => isValidFor(Digits(integer: -1, fraction: 1), "1"),
            "HV000032: Unable to initialize " ~ bv ~ "DigitsValidatorForCharSequence.",
            "HV000017: The length of the integer part cannot be negative.");
    expectInitializeFailure(() => isValidFor(Size(min: 5, max: 2), "1"),
            "HV000032: Unable to initialize " ~ bv ~ "size.SizeValidatorForCharSequence.",
            "HV000021: The length cannot be negative.");
    expectInitializeFailure(() => isValidFor(Pattern(regexp: "(unclosed"), "1"),
            "HV000032: Unable to initialize " ~ bv ~ "PatternValidator.", "HV000022: Invalid regular expression.");
}

@("@Digits on NaN: HV000028 wrapping BigDecimal's NumberFormatException")
unittest
{
    try
    {
        isValidFor(Digits(integer: 3, fraction: 1), double.nan);
        assert(false, "expected HV000028");
    }
    catch (ValidationException e)
    {
        assert(e.msg == "HV000028: Unexpected exception during isValid call.", e.msg);
        enum cause = `Character N is neither a decimal digit number, decimal point, nor "e" notation exponential mark.`;
        assert(e.getCause() !is null && e.getCause().msg == cause);
    }
}
