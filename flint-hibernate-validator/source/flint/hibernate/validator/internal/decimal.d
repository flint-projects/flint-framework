/*
 * Ported from Hibernate Validator 9.1.6.Final, https://github.com/hibernate/hibernate-validator,
 * tag 9.1.6.Final: engine/src/main/java/org/hibernate/validator/internal/constraintvalidators/
 * bv/number/bound/NumberComparatorHelper.java, bv/number/bound/decimal/DecimalNumberComparatorHelper.java,
 * bv/number/sign/NumberSignHelper.java, bv/number/InfinityNumberComparatorHelper.java (behaviour)
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright Red Hat Inc. and Hibernate Authors
 *
 * Modified by the Flint authors: java.math.BigDecimal's exact comparison, precision and scale are
 * computed on the decimal text (`new BigDecimal(String)`, `BigDecimal.valueOf(long)`,
 * `BigDecimal.valueOf(double)`) instead of a BigDecimal object, which flint.java does not have.
 */

/// Exact decimal arithmetic for the number constraints: BigDecimal's comparison, precision and scale on decimal text.
module flint.hibernate.validator.internal.decimal;

@safe:

/// A decimal number as `new BigDecimal(String)` reads it: `unscaled × 10^-scale`.
struct DecimalText
{
    /// Whether the number is negative (never for zero).
    bool negative;
    /// The unscaled magnitude's digits, without leading zeros; empty for zero.
    string digits;
    /// The scale: the number of digits after the decimal point (negative for trailing zeros before it).
    long scale;

    /**
     * Parse `text` with `new BigDecimal(String)`'s syntax: an optional sign, digits with an optional fraction (at
     * least one digit in all), and an optional exponent within int range. No whitespace, suffix, NaN or Infinity.
     * Returns false, leaving `result` unset, where Java throws NumberFormatException.
     */
    static bool parse(string text, out DecimalText result) pure nothrow
    {
        size_t at = text.length && (text[0] == '+' || text[0] == '-') ? 1 : 0;
        const negative = at == 1 && text[0] == '-';
        const intPart = digitsAt(text, at);
        string fracPart;
        if (at < text.length && text[at] == '.')
        {
            ++at;
            fracPart = digitsAt(text, at);
        }
        long exponent;
        if (intPart.length + fracPart.length == 0 || !exponentAt(text, at, exponent) || at != text.length)
            return false;
        const scale = cast(long) fracPart.length - exponent;
        if (scale < int.min || scale > int.max)
            return false;
        result.digits = stripLeadingZeros(fracPart.length ? intPart ~ fracPart : intPart);
        result.negative = negative && result.digits.length;
        result.scale = scale;
        return true;
    }

    /// `BigDecimal.valueOf(long)`.
    static DecimalText of(long value) pure nothrow
    {
        import flint.engine.aot.text : decimal;

        DecimalText result;
        parse(decimal(value), result);
        return result;
    }

    /// `BigDecimal.valueOf(double)`: the decimal of `Double.toString(value)`, for a finite value.
    static DecimalText ofDouble(double value) pure nothrow
    {
        import flint.serde.java_number : javaDoubleString;

        DecimalText result;
        parse(javaDoubleString(value), result);
        return result;
    }

    /// `BigDecimal.signum()`.
    int signum() const pure nothrow @nogc
    {
        return digits.length == 0 ? 0 : negative ? -1 : 1;
    }

    /// `BigDecimal.precision()`: the number of unscaled digits, 1 for zero.
    long precision() const pure nothrow @nogc
    {
        return digits.length ? cast(long) digits.length : 1;
    }

    /// `BigDecimal.stripTrailingZeros()`; zero becomes `0` with scale 0, as Java 8 and later make it.
    DecimalText stripTrailingZeros() const pure nothrow @nogc
    {
        DecimalText result = this;
        while (result.digits.length && result.digits[$ - 1] == '0')
        {
            result.digits = result.digits[0 .. $ - 1];
            --result.scale;
        }
        if (result.digits.length == 0)
            result.scale = 0;
        return result;
    }

    /// `BigDecimal.compareTo`: the numeric order, ignoring scale (2.0 equals 2.00).
    int compareTo(const DecimalText other) const pure nothrow @nogc
    {
        const sign = signum();
        const otherSign = other.signum();
        if (sign != otherSign)
            return sign < otherSign ? -1 : 1;
        if (sign == 0)
            return 0;
        const magnitude = compareMagnitude(stripTrailingZeros(), other.stripTrailingZeros());
        return sign < 0 ? -magnitude : magnitude;
    }

    // Both stripped and non-zero: the one whose leading digit has the higher place value is larger, then the digits
    // decide (a longer string after an equal prefix has a further non-zero digit).
    private static int compareMagnitude(const DecimalText a, const DecimalText b) pure nothrow @nogc
    {
        const aPlace = cast(long) a.digits.length - a.scale;
        const bPlace = cast(long) b.digits.length - b.scale;
        if (aPlace != bPlace)
            return aPlace < bPlace ? -1 : 1;
        const common = a.digits.length < b.digits.length ? a.digits.length : b.digits.length;
        foreach (i; 0 .. common)
            if (a.digits[i] != b.digits[i])
                return a.digits[i] < b.digits[i] ? -1 : 1;
        return a.digits.length == b.digits.length ? 0 : a.digits.length < b.digits.length ? -1 : 1;
    }
}

// The run of digits at `at`, which moves past it.
private string digitsAt(string text, ref size_t at) pure nothrow @nogc
{
    const start = at;
    while (at < text.length && isDigit(text[at]))
        ++at;
    return text[start .. at];
}

// An optional `e`/`E` exponent at `at` within int range, as BigDecimal reads it; false when malformed.
private bool exponentAt(string text, ref size_t at, out long exponent) pure nothrow @nogc
{
    if (at == text.length || (text[at] != 'e' && text[at] != 'E'))
        return true;
    ++at;
    const negative = at < text.length && text[at] == '-';
    if (at < text.length && (text[at] == '+' || text[at] == '-'))
        ++at;
    const digits = digitsAt(text, at);
    if (digits.length == 0)
        return false;
    foreach (c; digits)
    {
        exponent = exponent * 10 + (c - '0');
        if (exponent > 1L + int.max)
            return false;
    }
    exponent = negative ? -exponent : exponent;
    return exponent <= int.max;
}

private bool isDigit(char c) pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

private string stripLeadingZeros(string digits) pure nothrow @nogc
{
    size_t i;
    while (i < digits.length && digits[i] == '0')
        ++i;
    return digits[i .. $];
}

/// `Double.compare(a, b)` for non-NaN values: -0.0 orders before 0.0.
int javaCompare(double a, double b) pure nothrow @nogc
{
    if (a < b)
        return -1;
    if (a > b)
        return 1;
    const aNegativeZero = a == 0 && 1 / a < 0;
    const bNegativeZero = b == 0 && 1 / b < 0;
    return aNegativeZero == bNegativeZero ? 0 : aNegativeZero ? -1 : 1;
}

@("DecimalText reads what new BigDecimal(String) reads, and rejects the rest")
unittest
{
    DecimalText d;
    static immutable string[] valid = [
        "0", "-1", "+2", "15.0", ".5", "5.", "-000000000.22", "1e3", "2.5E-4", "1E+2", "1e-0"
    ];
    foreach (text; valid)
        assert(DecimalText.parse(text, d), text);
    static immutable string[] invalid = [
        "", "15l", "15f", "1d", "NaN", "Infinity", ".", "-", "1e", "1e+", "1.2.3", "0x10", "1 2",
        " 1", "1e+-2", "1e2147483648", "foobar"
    ];
    foreach (text; invalid)
        assert(!DecimalText.parse(text, d), text);
}

@("DecimalText: precision, scale and stripTrailingZeros as BigDecimal reports them")
unittest
{
    static struct Case
    {
        string text;
        long precision, scale, strippedPrecision, strippedScale;
    }

    static immutable Case[] cases = [
        Case("0", 1, 0, 1, 0), Case("0.00", 1, 2, 1, 0), Case("1.10", 3, 2, 2, 1),
        Case("100", 3, 0, 1, -2), Case("1E+2", 1, -2, 1, -2), Case("-000000000.22", 2, 2, 2, 2),
        Case("12.0001", 6, 4, 6, 4), Case("2.5E-4", 2, 5, 2, 5),
    ];
    foreach (c; cases)
    {
        DecimalText d;
        assert(DecimalText.parse(c.text, d), c.text);
        assert(d.precision == c.precision && d.scale == c.scale, c.text);
        const s = d.stripTrailingZeros();
        assert(s.precision == c.strippedPrecision && s.scale == c.strippedScale, c.text);
    }
}

@("DecimalText.compareTo: exact, scale-blind order")
unittest
{
    static int cmp(string a, string b)
    {
        DecimalText x, y;
        assert(DecimalText.parse(a, x) && DecimalText.parse(b, y));
        return x.compareTo(y);
    }

    assert(cmp("2.0", "2.00") == 0 && cmp("-0.0", "0") == 0 && cmp("1E+2", "100") == 0);
    assert(cmp("0.1", "0.100000000000000005") < 0 && cmp("0.100000000000000005", "0.1") > 0);
    assert(cmp("9223372036854775807", "9223372036854775806") > 0);
    assert(cmp("-5", "-4.99") < 0 && cmp("-0.001", "0") < 0 && cmp("1500E-2", "15") == 0);
    assert(cmp("99", "100") < 0 && cmp("0.0999", "0.1") < 0);
    assert(DecimalText.of(long.min).compareTo(DecimalText.of(long.max)) < 0);
    assert(DecimalText.ofDouble(0.1).compareTo(DecimalText.of(0)) > 0);
}

@("javaCompare orders -0.0 before 0.0, as Double.compare does")
unittest
{
    assert(javaCompare(-0.0, 0.0) == -1 && javaCompare(0.0, -0.0) == 1 && javaCompare(0.0, 0.0) == 0);
    assert(javaCompare(1, 2) == -1 && javaCompare(-double.infinity, -1e308) == -1);
}
