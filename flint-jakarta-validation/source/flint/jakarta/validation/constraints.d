/*
 * Ported from Jakarta Validation API 3.1.1 (jakarta.validation-api), https://github.com/jakartaee/validation,
 * tag 3.1.1: src/main/java/jakarta/validation/constraints/*.java
 *
 * Jakarta Validation API
 * License: Apache License, Version 2.0
 *
 * Modified by the Flint authors: each constraint is a D UDA struct with the same
 * elements and defaults (rulebook R2); `value` comes first where the constraint
 * has one, and each repeatable constraint keeps its nested `List` container
 * (R13). The Class<?>[] elements `groups` and `payload` follow once ClassRef
 * lands in flint.java.lang; until then every constraint is in the Default group.
 */

/// The built-in Jakarta Validation constraints.
module flint.jakarta.validation.constraints;

@safe:

/// The annotated element must be false. Supported types are `boolean` and `Boolean`.
struct AssertFalse
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.AssertFalse.message}";

    /// Defines several `AssertFalse` annotations on the same element.
    static struct List
    {
        /// The constraints.
        AssertFalse[] value;
    }
}

/// The annotated element must be true. Supported types are `boolean` and `Boolean`.
struct AssertTrue
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.AssertTrue.message}";

    /// Defines several `AssertTrue` annotations on the same element.
    static struct List
    {
        /// The constraints.
        AssertTrue[] value;
    }
}

/// The annotated element must be a number whose value must be lower or equal to the specified maximum.
struct DecimalMax
{
    /// The `String` representation of the bound, following the `BigDecimal` string representation.
    string value;

    /// The error message template.
    string message = "{jakarta.validation.constraints.DecimalMax.message}";

    /// Whether the specified bound is inclusive or exclusive.
    bool inclusive = true;

    /// Defines several `DecimalMax` annotations on the same element.
    static struct List
    {
        /// The constraints.
        DecimalMax[] value;
    }
}

/// The annotated element must be a number whose value must be higher or equal to the specified minimum.
struct DecimalMin
{
    /// The `String` representation of the bound, following the `BigDecimal` string representation.
    string value;

    /// The error message template.
    string message = "{jakarta.validation.constraints.DecimalMin.message}";

    /// Whether the specified bound is inclusive or exclusive.
    bool inclusive = true;

    /// Defines several `DecimalMin` annotations on the same element.
    static struct List
    {
        /// The constraints.
        DecimalMin[] value;
    }
}

/// The annotated element must be a number within accepted range.
struct Digits
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.Digits.message}";

    /// Maximum number of integral digits accepted for this number.
    int integer;

    /// Maximum number of fractional digits accepted for this number.
    int fraction;

    /// Defines several `Digits` annotations on the same element.
    static struct List
    {
        /// The constraints.
        Digits[] value;
    }
}

/// The string has to be a well-formed email address. Exact semantics of what makes up a valid email address are left to Jakarta Validation providers. Accepts `CharSequence`.
struct Email
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.Email.message}";

    /// An additional regular expression the annotated element must match. The default is any string.
    string regexp = ".*";

    /// Array of `Flag`s considered when resolving the regular expression.
    Pattern.Flag[] flags = [];

    /// Defines several `Email` annotations on the same element.
    static struct List
    {
        /// The constraints.
        Email[] value;
    }
}

/// The annotated element must be an instant, date or time in the future.
struct Future
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.Future.message}";

    /// Defines several `Future` annotations on the same element.
    static struct List
    {
        /// The constraints.
        Future[] value;
    }
}

/// The annotated element must be an instant, date or time in the present or in the future.
struct FutureOrPresent
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.FutureOrPresent.message}";

    /// Defines several `FutureOrPresent` annotations on the same element.
    static struct List
    {
        /// The constraints.
        FutureOrPresent[] value;
    }
}

/// The annotated element must be a number whose value must be lower or equal to the specified maximum.
struct Max
{
    /// Value the element must be lower or equal to.
    long value;

    /// The error message template.
    string message = "{jakarta.validation.constraints.Max.message}";

    /// Defines several `Max` annotations on the same element.
    static struct List
    {
        /// The constraints.
        Max[] value;
    }
}

/// The annotated element must be a number whose value must be higher or equal to the specified minimum.
struct Min
{
    /// Value the element must be higher or equal to.
    long value;

    /// The error message template.
    string message = "{jakarta.validation.constraints.Min.message}";

    /// Defines several `Min` annotations on the same element.
    static struct List
    {
        /// The constraints.
        Min[] value;
    }
}

/// The annotated element must be a strictly negative number (i.e. 0 is considered as an invalid value).
struct Negative
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.Negative.message}";

    /// Defines several `Negative` annotations on the same element.
    static struct List
    {
        /// The constraints.
        Negative[] value;
    }
}

/// The annotated element must be a negative number or 0.
struct NegativeOrZero
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.NegativeOrZero.message}";

    /// Defines several `NegativeOrZero` annotations on the same element.
    static struct List
    {
        /// The constraints.
        NegativeOrZero[] value;
    }
}

/// The annotated element must not be `null` and must contain at least one non-whitespace character. Accepts `CharSequence`.
struct NotBlank
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.NotBlank.message}";

    /// Defines several `NotBlank` annotations on the same element.
    static struct List
    {
        /// The constraints.
        NotBlank[] value;
    }
}

/// The annotated element must not be `null` nor empty.
struct NotEmpty
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.NotEmpty.message}";

    /// Defines several `NotEmpty` annotations on the same element.
    static struct List
    {
        /// The constraints.
        NotEmpty[] value;
    }
}

/// The annotated element must not be `null`. Accepts any type.
struct NotNull
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.NotNull.message}";

    /// Defines several `NotNull` annotations on the same element.
    static struct List
    {
        /// The constraints.
        NotNull[] value;
    }
}

/// The annotated element must be `null`. Accepts any type.
struct Null
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.Null.message}";

    /// Defines several `Null` annotations on the same element.
    static struct List
    {
        /// The constraints.
        Null[] value;
    }
}

/// The annotated element must be an instant, date or time in the past.
struct Past
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.Past.message}";

    /// Defines several `Past` annotations on the same element.
    static struct List
    {
        /// The constraints.
        Past[] value;
    }
}

/// The annotated element must be an instant, date or time in the past or in the present.
struct PastOrPresent
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.PastOrPresent.message}";

    /// Defines several `PastOrPresent` annotations on the same element.
    static struct List
    {
        /// The constraints.
        PastOrPresent[] value;
    }
}

/// The annotated `CharSequence` must match the specified regular expression. The regular expression follows the Java regular expression conventions see `java.util.regex.Pattern`.
struct Pattern
{
    /// Possible Regexp flags, with the bit `java.util.regex.Pattern` gives each.
    enum Flag
    {
        /// Enables Unix lines mode.
        UNIX_LINES = 0x01,
        /// Enables case-insensitive matching.
        CASE_INSENSITIVE = 0x02,
        /// Permits whitespace and comments in pattern.
        COMMENTS = 0x04,
        /// Enables multiline mode.
        MULTILINE = 0x08,
        /// Enables dotall mode.
        DOTALL = 0x20,
        /// Enables Unicode-aware case folding.
        UNICODE_CASE = 0x40,
        /// Enables canonical equivalence.
        CANON_EQ = 0x80,
    }

    /// The regular expression to match.
    string regexp;

    /// Array of `Flag`s considered when resolving the regular expression.
    Flag[] flags = [];

    /// The error message template.
    string message = "{jakarta.validation.constraints.Pattern.message}";

    /// Defines several `Pattern` annotations on the same element.
    static struct List
    {
        /// The constraints.
        Pattern[] value;
    }
}

/// The annotated element must be a strictly positive number (i.e. 0 is considered as an invalid value).
struct Positive
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.Positive.message}";

    /// Defines several `Positive` annotations on the same element.
    static struct List
    {
        /// The constraints.
        Positive[] value;
    }
}

/// The annotated element must be a positive number or 0.
struct PositiveOrZero
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.PositiveOrZero.message}";

    /// Defines several `PositiveOrZero` annotations on the same element.
    static struct List
    {
        /// The constraints.
        PositiveOrZero[] value;
    }
}

/// The annotated element size must be between the specified boundaries (included).
struct Size
{
    /// The error message template.
    string message = "{jakarta.validation.constraints.Size.message}";

    /// Size the element must be higher or equal to.
    int min = 0;

    /// Size the element must be lower or equal to.
    int max = int.max;

    /// Defines several `Size` annotations on the same element.
    static struct List
    {
        /// The constraints.
        Size[] value;
    }
}
