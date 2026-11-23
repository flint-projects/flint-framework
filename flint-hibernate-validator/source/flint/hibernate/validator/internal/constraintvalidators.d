/*
 * Ported from Hibernate Validator 9.1.6.Final, https://github.com/hibernate/hibernate-validator,
 * tag 9.1.6.Final: engine/src/main/java/org/hibernate/validator/internal/constraintvalidators/
 * bv/{NotNullValidator,NullValidator,AssertTrueValidator,AssertFalseValidator,NotBlankValidator,
 * PatternValidator,EmailValidator,DigitsValidatorForNumber,DigitsValidatorForCharSequence}.java,
 * bv/notempty/*, bv/size/*, bv/number/bound/*, bv/number/bound/decimal/*, bv/number/sign/*,
 * AbstractEmailValidator.java, internal/util/DomainNameUtil.java and bv/time/{past,pastorpresent,
 * future,futureorpresent}/*
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright Red Hat Inc. and Hibernate Authors
 *
 * Modified by the Flint authors: one erased dispatcher replaces Hibernate's validator
 * per (constraint, type) pair; values arrive boxed in Any. Character counts are
 * UTF-16 units, as CharSequence.length() is (rulebook R14); whitespace is
 * Character.isWhitespace's. The e-mail grammar is Hibernate's regular expressions
 * written as code. @Past/@Future and friends cover the flint.java.time types with the
 * default ClockProvider (the system clock, UTC) and a zero temporal tolerance.
 */

/// The built-in constraints: which ones exist, their attributes, and their validity checks.
module flint.hibernate.validator.internal.constraintvalidators;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor;
import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.internal.decimal : DecimalText, javaCompare;
import flint.hibernate.validator.internal.el : ElValue;
import flint.jakarta.validation : UnexpectedTypeException, ValidationException;
import flint.jakarta.validation.constraints : AssertFalse, AssertTrue, DecimalMax, DecimalMin,
    Digits, Email, Future, FutureOrPresent, Max, Min, Negative, NegativeOrZero, NotBlank, NotEmpty,
    NotNull, Null, Past, PastOrPresent, Pattern, Positive, PositiveOrZero, Size;
import flint.java.time : Instant, LocalDate, LocalDateTime, LocalTime, OffsetDateTime, ZonedDateTime;
import flint.java.util : RawCollection, RawMap;
import flint.hibernate.validator.internal.regex : Regex, RegexBudgetException, RegexSyntaxException,
    RegexUnsupportedException, compileRegex;

@safe:

/// One element of a constraint annotation: its name, its value for EL, and its text for `{name}`.
struct Attribute
{
    /// The element name.
    string name;
    /// The value expressions see.
    ElValue value;
}

/// A built-in constraint read from its annotation: template, attributes and the check to run.
struct BuiltinConstraint
{
    /// The annotation's Flint type name.
    string annotationType;
    /// The message template.
    string message;
    /// The elements, in declaration order.
    Attribute[] attributes;
    /// The annotation value, boxed.
    Any annotation;
}

/// Whether `type` names a built-in Jakarta constraint.
bool isBuiltin(scope const(char)[] type) pure nothrow @nogc
{
    enum prefix = "flint.jakarta.validation.constraints.";
    return type.length > prefix.length && type[0 .. prefix.length] == prefix;
}

/// Read the built-in constraint `annotation` of type `type`.
BuiltinConstraint read(string type, ref const Any annotation)
{
    BuiltinConstraint c;
    c.annotationType = type;
    static foreach (A; ConstraintTypes)
    {
        if (type == typeNameOf!A)
            readInto!A(c, annotation);
    }
    return c;
}

/// Read a user-defined constraint `annotation` of type `A`: its `message` and the attributes EL can see.
BuiltinConstraint readCustom(A)(ref const Any annotation)
{
    BuiltinConstraint c;
    c.annotationType = typeNameOf!A;
    const a = annotation.get!A();
    c.annotation = Any.of(mutableCopy(a));
    c.message = a.message;
    static foreach (i; 0 .. A.tupleof.length)
    {
        static if (__traits(identifier, A.tupleof[i]) != "message" && __traits(compiles, elValue(a.tupleof[i])))
            c.attributes ~= Attribute(__traits(identifier, A.tupleof[i]), elValue(a.tupleof[i]));
    }
    return c;
}

private void readInto(A)(ref BuiltinConstraint c, ref const Any annotation)
{
    const a = annotation.get!A();
    c.annotation = Any.of(mutableCopy(a));
    c.message = a.message;
    static foreach (i; 0 .. A.tupleof.length)
    {
        static if (__traits(identifier, A.tupleof[i]) != "message")
            c.attributes ~= Attribute(__traits(identifier, A.tupleof[i]), elValue(a.tupleof[i]));
    }
}

// A mutable copy of a const annotation value, duplicating its arrays.
private A mutableCopy(A)(const A value)
{
    import std.traits : isDynamicArray;

    A copy;
    static foreach (i; 0 .. A.tupleof.length)
    {
        static if (isDynamicArray!(typeof(A.tupleof[i])) && !is(typeof(A.tupleof[i]) : const(char)[]))
            copy.tupleof[i] = value.tupleof[i].dup;
        else
            copy.tupleof[i] = value.tupleof[i];
    }
    return copy;
}

private alias ConstraintTypes = imported!"std.meta".AliasSeq!(AssertFalse, AssertTrue, DecimalMax, DecimalMin,
        Digits, Email, Future, FutureOrPresent, Max, Min, Negative, NegativeOrZero, NotBlank,
        NotEmpty, NotNull, Null, Past, PastOrPresent, Pattern, Positive, PositiveOrZero, Size);

private ElValue elValue(T)(const T value)
{
    static if (is(T == string))
        return ElValue.of(value);
    else static if (is(T == bool))
        return ElValue.of(value);
    else static if (__traits(isIntegral, T))
        return ElValue.of(cast(long) value);
    else
    {
        // Arrays (Pattern.flags): Arrays.toString, as Hibernate's ParameterTermResolver prints them.
        string text = "[";
        foreach (i, element; value)
            text ~= (i ? ", " : "") ~ elementText(element);
        return ElValue.of(text ~ "]");
    }
}

// An array element's Java text. An enum prints its constant's name, as to!string did, without std.format: one
// to!string of an enum instantiated most of std.format in this module.
private string elementText(E)(const E element)
{
    static if (is(E == enum))
    {
        foreach (member; __traits(allMembers, E))
            if (element == __traits(getMember, E, member))
                return member;
        return "";
    }
    else static if (__traits(isIntegral, E))
        return imported!"flint.engine.aot.text".decimal(cast(long) element);
    else static if (is(E : const(char)[]))
        return element.idup;
    else
        static assert(false, "no Java text for an array of " ~ E.stringof);
}

/// The attribute named `name`, as text for `{name}`; null when there is none.
string attributeText(ref const BuiltinConstraint c, string name) pure nothrow
{
    foreach (a; c.attributes)
        if (a.name == name)
            return a.value.coerceToString();
    return null;
}

private ElValue attribute(ref const BuiltinConstraint c, string name) pure nothrow @nogc
{
    foreach (a; c.attributes)
        if (a.name == name)
            return a.value;
    return ElValue.init;
}

/// A `@Pattern` (or `@Email` regexp) compiled once: the program, or why it does not compile.
struct CompiledPattern
{
    /// The program, when `problem` is null.
    Regex regex;
    /// HV000022's cause for a malformed expression, or the engine's message for an unsupported one.
    string problem;
    /// Whether `problem` is a syntax error (Hibernate's HV000022) rather than a missing engine feature.
    bool malformed;
}

/// Compiled patterns, shared by a validator factory and so by every reactor thread.
final class PatternCache
{
    // Copy-on-write: a published table is never changed, so lookups take no lock; a miss compiles and publishes a
    // larger copy under the monitor.
    private CompiledPattern[string] patterns;

    /// The compiled pattern for `regexp` with `java.util.regex.Pattern` flag bits `flags`, compiling it once.
    CompiledPattern get(string regexp, int flags = 0)
    {
        import flint.engine.aot.text : decimal;

        const key = decimal(flags) ~ "/" ~ regexp;
        // A single word read of a table published after a fence (RCU-style publication).
        auto published = patterns;
        if (auto found = key in published)
            return *found;
        CompiledPattern compiled;
        try
            compiled.regex = compileRegex(regexp, flags);
        catch (RegexSyntaxException e)
        {
            compiled.problem = e.msg;
            compiled.malformed = true;
        }
        catch (RegexUnsupportedException e)
            compiled.problem = e.msg;
        synchronized (this)
        {
            if (auto raced = key in patterns)
                return *raced;
            auto grown = patterns.dup;
            grown[key] = compiled;
            imported!"core.atomic".atomicFence(); // the pattern and the table are complete before publication
            patterns = grown;
        }
        return compiled;
    }
}

/// Run the check of constraint `c` on `value`; `propertyPath` names the element in an UnexpectedTypeException.
/// `described` is the value's descriptor, through which arrays and associative arrays report their size.
bool isValid(ref const BuiltinConstraint c, ref Any value, PatternCache patterns, string propertyPath,
        const(Descriptor) described = null)
{
    const simple = simpleName(c.annotationType);
    initialize(c, simple, value, patterns);
    switch (simple)
    {
    case "NotNull":
    case "Null":
        return isNullConstraintMet(simple == "Null", value);
    case "AssertTrue":
    case "AssertFalse":
        return checkAssert(c, value, simple == "AssertTrue", propertyPath);
    case "NotBlank":
        return checkNotBlank(c, value, propertyPath);
    case "NotEmpty":
        return (!value.isNull() || isArray(value)) && size(c, value, propertyPath, described) > 0;
    case "Size":
        return checkSize(c, value, propertyPath, described);
    case "Pattern":
        return checkPattern(c, value, patterns, propertyPath);
    case "Email":
        return checkEmail(c, value, patterns, propertyPath);
    default:
        return checkNumber(c, simple, value, propertyPath);
    }
}

// NotNullValidator and NullValidator; a D array is never null.
private bool isNullConstraintMet(bool wantNull, ref Any value) pure nothrow @nogc
{
    const isNull = value.isNull() && !isArray(value);
    return wantNull == isNull;
}

private bool checkAssert(ref const BuiltinConstraint c, ref Any value, bool expected, string propertyPath)
{
    if (value.isNull())
        return true;
    if (!value.holds!bool())
        return unexpected(c, value, propertyPath);
    return value.get!bool() == expected;
}

private bool checkNotBlank(ref const BuiltinConstraint c, ref Any value, string propertyPath)
{
    if (value.isNull())
        return false;
    if (!value.holds!string())
        return unexpected(c, value, propertyPath);
    return !isBlank(value.get!string());
}

private bool checkSize(ref const BuiltinConstraint c, ref Any value, string propertyPath, const(Descriptor) described)
{
    if (value.isNull() && !isArray(value))
        return true;
    const n = size(c, value, propertyPath, described);
    return n >= attribute(c, "min").number && n <= attribute(c, "max").number;
}

private bool checkPattern(ref const BuiltinConstraint c, ref Any value, PatternCache patterns, string propertyPath)
{
    if (value.isNull())
        return true;
    if (!value.holds!string())
        return unexpected(c, value, propertyPath);
    return matchesPattern(patterns.get(attribute(c, "regexp").text, patternFlags(c)), value.get!string());
}

// PatternValidator: `pattern.matcher(value).matches()`. A match that runs out of steps is an exception inside
// isValid (HV000028), where Java's would keep backtracking.
private bool matchesPattern(CompiledPattern pattern, string text)
{
    try
        return pattern.regex.matches(text);
    catch (RegexBudgetException e)
        throw new ValidationException("HV000028: Unexpected exception during isValid call.", e);
}

// The `java.util.regex.Pattern` bits of `@Pattern.flags` (or `@Email.flags`).
private int patternFlags(ref const BuiltinConstraint c)
{
    import flint.jakarta.validation.constraints : Email, Pattern;

    int bits;
    if (c.annotation.holds!Pattern())
        foreach (flag; c.annotation.get!Pattern().flags)
            bits |= flag;
    else if (c.annotation.holds!Email())
                foreach (flag; c.annotation.get!Email().flags)
                    bits |= flag;
    return bits;
}

// The identifier after the last dot.
private string simpleName(string type) pure nothrow @nogc
{
    size_t start = type.length;
    while (start > 0 && type[start - 1] != '.')
        --start;
    return type[start .. $];
}

private bool checkEmail(ref const BuiltinConstraint c, ref Any value, PatternCache patterns, string propertyPath)
{
    if (value.isNull())
        return true;
    if (!value.holds!string())
        return unexpected(c, value, propertyPath);
    const text = value.get!string();
    if (!isValidEmail(text))
        return false;
    const extra = attribute(c, "regexp").text;
    return extra == ".*" || matchesPattern(patterns.get(extra, patternFlags(c)), text);
}

private bool checkNumber(ref const BuiltinConstraint c, string simple, ref Any value, string propertyPath)
{
    if (value.isNull())
        return true;
    if (isTemporal(simple))
        return checkTemporal(c, simple, value, propertyPath);
    const read = readNumber(value);
    if (read.kind == NumberRead.Kind.none)
        return unexpected(c, value, propertyPath);
    // The CharSequence validators' `new BigDecimal(value.toString())` threw NumberFormatException: invalid.
    if (read.kind == NumberRead.Kind.unparsable)
        return false;
    if (simple == "Digits")
        return checkDigits(c, read);
    if (simple == "Min" || simple == "Max" || simple == "DecimalMin" || simple == "DecimalMax")
        return checkBound(c, simple, read);
    return checkSign(simple, read);
}

private bool isTemporal(string simple) pure nothrow @nogc
{
    return simple == "Past" || simple == "PastOrPresent" || simple == "Future" || simple == "FutureOrPresent";
}

private bool checkTemporal(ref const BuiltinConstraint c, string simple, ref Any value, string propertyPath)
{
    const order = compareWithNow(value);
    if (order == int.min)
        return unexpected(c, value, propertyPath);
    switch (simple)
    {
    case "Past":
        return order < 0;
    case "PastOrPresent":
        return order <= 0;
    case "Future":
        return order > 0;
    default:
        return order >= 0;
    }
}

// The value's order relative to the current date or time of its kind; int.min for a type with no validator.
private int compareWithNow(ref Any value)
{
    switch (value.typeName())
    {
    case typeNameOf!Instant:
        return value.get!Instant().compareTo(Instant.now());
    case typeNameOf!LocalDate:
        return value.get!LocalDate().compareTo(LocalDate.now());
    case typeNameOf!LocalDateTime:
        return value.get!LocalDateTime().compareTo(LocalDateTime.now());
    case typeNameOf!LocalTime:
        return value.get!LocalTime().compareTo(LocalTime.now());
    case typeNameOf!OffsetDateTime:
        return value.get!OffsetDateTime().toInstant().compareTo(Instant.now());
    case typeNameOf!ZonedDateTime:
        return value.get!ZonedDateTime().toInstant().compareTo(Instant.now());
    default:
        return int.min;
    }
}

// AbstractMin/MaxValidator and AbstractDecimalMin/MaxValidator. @Min and @Max compare with the exact long bound;
// @DecimalMin and @DecimalMax with the exact decimal one (NumberComparatorHelper, DecimalNumberComparatorHelper).
private bool checkBound(ref const BuiltinConstraint c, string simple, ref const NumberRead read)
{
    switch (simple)
    {
    case "Min":
        return compareTo(read, c.annotation.get!Min().value, lessThan) >= 0;
    case "Max":
        return compareTo(read, c.annotation.get!Max().value, greaterThan) <= 0;
    case "DecimalMin":
        const order = compareTo(read, decimalBound(c), lessThan);
        return attribute(c, "inclusive").boolean ? order >= 0 : order > 0;
    default:
        const order = compareTo(read, decimalBound(c), greaterThan);
        return attribute(c, "inclusive").boolean ? order <= 0 : order < 0;
    }
}

// InfinityNumberComparatorHelper's NaN treatments: LESS_THAN fails a lower bound, GREATER_THAN an upper one.
private enum lessThan = -1, greaterThan = 1;

// `new BigDecimal(value())`, which initialize has already checked.
private DecimalText decimalBound(ref const BuiltinConstraint c) pure nothrow
{
    DecimalText bound;
    DecimalText.parse(attribute(c, "value").text, bound);
    return bound;
}

// NumberComparatorHelper.compare against a long bound: Long.compare, Float.compare and Double.compare (after the
// NaN and infinity checks), and BigDecimal.compareTo for a numeric String.
private int compareTo(ref const NumberRead read, long bound, int treatNanAs) pure nothrow
{
    final switch (read.kind)
    {
    case NumberRead.Kind.integral:
        return read.whole < bound ? -1 : read.whole > bound ? 1 : 0;
    case NumberRead.Kind.float_:
        return read.number != read.number ? treatNanAs
            : javaCompare(read.number, cast(float) bound);
    case NumberRead.Kind.double_:
        return read.number != read.number ? treatNanAs
            : javaCompare(read.number, cast(double) bound);
    case NumberRead.Kind.text:
        return read.text.compareTo(DecimalText.of(bound));
    case NumberRead.Kind.none:
    case NumberRead.Kind.unparsable:
        return treatNanAs;
    }
}

// DecimalNumberComparatorHelper.compare: BigDecimal.valueOf(long), BigDecimal.valueOf(double) (a Float widened)
// after the NaN and infinity checks, and new BigDecimal(String).
private int compareTo(ref const NumberRead read, const DecimalText bound, int treatNanAs) pure nothrow
{
    final switch (read.kind)
    {
    case NumberRead.Kind.integral:
        return DecimalText.of(read.whole).compareTo(bound);
    case NumberRead.Kind.float_:
    case NumberRead.Kind.double_:
        if (read.number != read.number)
            return treatNanAs;
        if (read.number == double.infinity || read.number == -double.infinity)
            return read.number > 0 ? 1 : -1;
        return DecimalText.ofDouble(read.number).compareTo(bound);
    case NumberRead.Kind.text:
        return read.text.compareTo(bound);
    case NumberRead.Kind.none:
    case NumberRead.Kind.unparsable:
        return treatNanAs;
    }
}

// NumberSignHelper.signum: Float/Double.compareTo(0) (so -0.0 is negative) after the NaN check, which fails
// @Positive and @PositiveOrZero as LESS_THAN and @Negative and @NegativeOrZero as GREATER_THAN.
private bool checkSign(string simple, ref const NumberRead read) pure nothrow @nogc
{
    if (read.kind == NumberRead.Kind.none || read.kind == NumberRead.Kind.unparsable)
        return false;
    const sign = signum(read, simple == "Positive" || simple == "PositiveOrZero" ? lessThan : greaterThan);
    switch (simple)
    {
    case "Positive":
        return sign > 0;
    case "PositiveOrZero":
        return sign >= 0;
    case "Negative":
        return sign < 0;
    case "NegativeOrZero":
        return sign <= 0;
    default:
        return true;
    }
}

private int signum(ref const NumberRead read, int treatNanAs) pure nothrow @nogc
{
    if (read.kind == NumberRead.Kind.integral)
        return read.whole < 0 ? -1 : read.whole > 0 ? 1 : 0;
    if (read.kind == NumberRead.Kind.text)
        return read.text.signum();
    return read.number != read.number ? treatNanAs : javaCompare(read.number, 0.0);
}

// A number constraint's value, as the validator for its type sees it.
private struct NumberRead
{
    enum Kind
    {
        none, // no number validator for the type: HV000030
        integral, // Byte, Short, Integer, Long
        float_, // Float, widened into `number`
        double_, // Double
        text, // a CharSequence that new BigDecimal(String) reads
        unparsable, // a CharSequence it rejects
    }

    Kind kind;
    long whole;
    double number = double.nan;
    DecimalText text;
}

private NumberRead readNumber(ref Any value)
{
    NumberRead read;
    if (value.holds!long() && !value.holds!bool())
    {
        read.kind = NumberRead.Kind.integral;
        read.whole = value.get!long();
    }
    else if (value.holds!double() && !value.holds!string() && !value.holds!bool())
    {
        read.kind = value.typeName() == typeNameOf!float ? NumberRead.Kind.float_ : NumberRead.Kind.double_;
        read.number = value.get!double();
    }
    else if (value.holds!string())
    {
        // Hibernate's validators for CharSequence parse `new BigDecimal(value.toString())`, which reads no
        // whitespace.
        read.kind = DecimalText.parse(value.get!string(), read.text) ? NumberRead.Kind.text : NumberRead
            .Kind.unparsable;
    }
    return read;
}

// DigitsValidatorForNumber: `new BigDecimal(num.toString()).stripTrailingZeros()` (Float.toString for a float);
// DigitsValidatorForCharSequence: `new BigDecimal(text)`, trailing zeros kept. Integer digits are
// precision - scale, fraction digits the scale (0 when negative).
private bool checkDigits(ref const BuiltinConstraint c, ref const NumberRead read)
{
    import flint.serde.java_number : javaDoubleString, javaFloatString;

    DecimalText number;
    final switch (read.kind)
    {
    case NumberRead.Kind.integral:
        number = DecimalText.of(read.whole).stripTrailingZeros();
        break;
    case NumberRead.Kind.float_:
    case NumberRead.Kind.double_:
        const text = read.kind == NumberRead.Kind.float_
            ? javaFloatString(cast(float) read.number) : javaDoubleString(read.number);
        if (!DecimalText.parse(text, number))
            throw notANumber(text);
        number = number.stripTrailingZeros();
        break;
    case NumberRead.Kind.text:
        number = read.text;
        break;
    case NumberRead.Kind.none:
    case NumberRead.Kind.unparsable:
        return false;
    }
    const integerDigits = number.precision() - number.scale;
    const fractionDigits = number.scale < 0 ? 0 : number.scale;
    return integerDigits <= cast(long) attribute(c, "integer").number
        && fractionDigits <= cast(long) attribute(c, "fraction").number;
}

// `new BigDecimal("NaN")` (or "Infinity") inside isValid: HV000028 wrapping the NumberFormatException.
private ValidationException notANumber(string text)
{
    import flint.java.lang : NumberFormatException;

    const at = text[0] == '-' ? text[1] : text[0];
    return new ValidationException("HV000028: Unexpected exception during isValid call.", new NumberFormatException(
            "Character " ~ at ~ " is neither a decimal digit number, decimal point, nor"
            ~ " \"e\" notation exponential mark."));
}

// Hibernate's initialize: attribute values the validator rejects before it validates anything, reported as HV000032
// wrapping the IllegalArgumentException that names the problem.
private void initialize(ref const BuiltinConstraint c, string simple, ref Any value, PatternCache patterns)
{
    import flint.java.lang : IllegalArgumentException;

    string problem;
    switch (simple)
    {
    case "DecimalMin":
    case "DecimalMax":
        DecimalText bound;
        const text = attribute(c, "value").text;
        if (!DecimalText.parse(text, bound))
            problem = "HV000016: " ~ text ~ " does not represent a valid BigDecimal format.";
        break;
    case "Digits":
        if (attribute(c, "integer").number < 0)
            problem = "HV000017: The length of the integer part cannot be negative.";
        else if (attribute(c, "fraction").number < 0)
            problem = "HV000018: The length of the fraction part cannot be negative.";
        break;
    case "Size":
        const min = attribute(c, "min").number, max = attribute(c, "max").number;
        problem = min < 0 ? "HV000019: The min parameter cannot be negative." : max < 0
            ? "HV000020: The max parameter cannot be negative." : max < min
            ? "HV000021: The length cannot be negative." : null;
        break;
    case "Pattern":
        const compiled = patterns.get(attribute(c, "regexp").text, patternFlags(c));
        if (compiled.problem !is null)
            problem = compiled.malformed ? "HV000022: Invalid regular expression." : compiled.problem;
        break;
    default:
        return;
    }
    if (problem !is null)
        throw new ValidationException("HV000032: Unable to initialize " ~ validatorClass(simple,
                value) ~ ".", new IllegalArgumentException(problem));
}

// The name of the Hibernate validator class that would have been chosen for `value`.
private string validatorClass(string simple, ref Any value)
{
    enum base = "org.hibernate.validator.internal.constraintvalidators.bv.";
    const text = value.holds!string();
    switch (simple)
    {
    case "Pattern":
        return base ~ "PatternValidator";
    case "Digits":
        return base ~ "DigitsValidatorFor" ~ (text ? "CharSequence" : "Number");
    case "Size":
        return base ~ "size.SizeValidatorFor" ~ (text ? "CharSequence" : isArray(value)
                ? "Array" : cast(RawMap) value.asObject() !is null ? "Map" : "Collection");
    default:
        const java = javaTypeName(value.typeName());
        const boxed = java.length > 10 && java[0 .. 10] == "java.lang." ? java[10 .. $] : "Number";
        return base ~ "number.bound.decimal." ~ simple ~ "ValidatorFor" ~ (text ? "CharSequence" : boxed);
    }
}

// SizeValidatorForCharSequence, ForCollection, ForMap and ForArray.
private size_t size(ref const BuiltinConstraint c, ref Any value, string propertyPath, const(Descriptor) described)
{
    if (value.holds!string())
        return utf16Length(value.get!string());
    if (auto collection = cast(RawCollection) value.asObject())
        return collection.size();
    if (auto map = cast(RawMap) value.asObject())
        return map.keysAsAny().length;
    if (isArray(value) && value.isNull())
        return 0;
    if (described !is null && described.length !is null)
        return described.length(value);
    if (described !is null && described.toKeys !is null)
        return described.toKeys(value).length;
    return unexpected(c, value, propertyPath) ? 0 : 0;
}

/// Whether `value` is a D array. D's `[]` is null, so a null array counts as an empty one, not as null.
bool isArray(ref const Any value) pure nothrow @nogc
{
    const type = value.typeName();
    return type.length > 2 && type[$ - 2 .. $] == "[]";
}

/// Java's `String.length()`: UTF-16 code units (rulebook R14).
size_t utf16Length(string s) pure nothrow @nogc
{
    // Each UTF-8 lead byte starts one UTF-16 unit, or two for a four-byte sequence (a surrogate pair).
    size_t n;
    foreach (b; cast(const(ubyte)[]) s)
    {
        if ((b & 0xC0) != 0x80)
            n += b >= 0xF0 ? 2 : 1;
    }
    return n;
}

/// Java's `String.isBlank()`: empty, or only `Character.isWhitespace` characters.
bool isBlank(string s) pure
{
    foreach (dchar c; s)
        if (!isJavaWhitespace(c))
            return false;
    return true;
}

/// Java's `Character.isWhitespace`: space, line and paragraph separators except the non-breaking spaces, and
/// the ASCII controls tab, line feed, vertical tab, form feed, carriage return and the four separators.
bool isJavaWhitespace(dchar c) pure nothrow @nogc
{
    if ((c >= 0x09 && c <= 0x0D) || (c >= 0x1C && c <= 0x1F))
        return true;
    if (c == 0xA0 || c == 0x2007 || c == 0x202F)
        return false;
    // Unicode Zs, Zl and Zp.
    return c == 0x20 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029
        || c == 0x205F || c == 0x3000;
}

// AbstractEmailValidator: local part (at most 64 UTF-16 units) up to the last '@', then DomainNameUtil.
private bool isValidEmail(string text)
{
    if (text.length == 0)
        return true;
    size_t at = size_t.max;
    foreach (i, ch; text)
        if (ch == '@')
            at = i;
    if (at == size_t.max)
        return false;
    return validLocalPart(text[0 .. at]) && validDomain(text[at + 1 .. $]);
}

private bool localAtomChar(dchar c) pure nothrow @nogc
{
    import std.ascii : isAlphaNum;

    if (c >= 0x80)
        return true;
    return isAlphaNum(cast(char) c) || "!#$%&'*+/=?^_`{|}~-".indexOfChar(cast(char) c);
}

private bool quotedAtomChar(dchar c) pure nothrow @nogc
{
    import std.ascii : isAlphaNum;

    if (c >= 0x80)
        return true;
    return isAlphaNum(cast(char) c) || "!#$%&'*.(),<>[]:; @+/=?^_`{|}~-".indexOfChar(cast(char) c);
}

private bool indexOfChar(string set, char c) pure nothrow @nogc
{
    foreach (s; set)
        if (s == c)
            return true;
    return false;
}

// (?:ATOM+|"QUOTED+")(?:\.(?:ATOM+|"QUOTED+"))*, case-insensitive.
private bool validLocalPart(string local)
{
    if (local.length == 0 || utf16Length(local) > 64)
        return false;
    size_t i;
    for (;;)
    {
        if (i < local.length && local[i] == '"')
        {
            if (!quotedWord(local, i))
                return false;
        }
        else
        {
            const start = i;
            while (i < local.length)
            {
                size_t next = i;
                const c = decodeAt(local, next);
                if (!localAtomChar(c))
                    break;
                i = next;
            }
            if (i == start)
                return false;
        }
        if (i == local.length)
            return true;
        if (local[i] != '.')
            return false;
        ++i;
    }
}

private bool quotedWord(string s, ref size_t i)
{
    ++i;
    const start = i;
    while (i < s.length && s[i] != '"')
    {
        if (s[i] == '\\' && i + 1 < s.length && (s[i + 1] == '\\' || s[i + 1] == '"'))
        {
            i += 2;
            continue;
        }
        size_t next = i;
        if (!quotedAtomChar(decodeAt(s, next)))
            return false;
        i = next;
    }
    if (i == s.length || i == start)
        return false;
    ++i;
    return true;
}

// std.utf.decode without Phobos: one well-formed UTF-8 sequence (no overlong form, surrogate or value above
// U+10FFFF); anything else advances one byte and reads as U+FFFD, as the std.utf fallback here did.
private dchar decodeAt(string s, ref size_t i) pure nothrow @nogc
{
    const lead = s[i];
    if (lead < 0x80)
        return s[i++];
    size_t length;
    dchar c;
    dchar least;
    if ((lead & 0xE0) == 0xC0)
    {
        length = 2;
        c = lead & 0x1F;
        least = 0x80;
    }
    else if ((lead & 0xF0) == 0xE0)
    {
        length = 3;
        c = lead & 0x0F;
        least = 0x800;
    }
    else if ((lead & 0xF8) == 0xF0)
    {
        length = 4;
        c = lead & 0x07;
        least = 0x10000;
    }
    if (length == 0 || i + length > s.length)
    {
        ++i;
        return 0xFFFD;
    }
    foreach (k; 1 .. length)
    {
        if ((s[i + k] & 0xC0) != 0x80)
        {
            ++i;
            return 0xFFFD;
        }
        c = (c << 6) | (s[i + k] & 0x3F);
    }
    if (c < least || c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF))
    {
        ++i;
        return 0xFFFD;
    }
    i += length;
    return c;
}

// DomainNameUtil.isValidEmailDomainAddress: no trailing dot, at most 255 characters, then labels separated by
// dots, or an IPv4 literal [1.2.3.4], or [IPv6:...].
private bool validDomain(string domain)
{
    if (domain.length == 0 || domain[$ - 1] == '.' || utf16Length(domain) > 255)
        return false;
    if (domain[0] == '[')
        return validAddressLiteral(domain);
    size_t i;
    for (;;)
    {
        if (!domainLabel(domain, i))
            return false;
        if (i == domain.length)
            return true;
        if (domain[i] != '.')
            return false;
        ++i;
    }
}

private bool domainChar(dchar c) pure nothrow @nogc
{
    import std.ascii : isAlphaNum;

    if (c >= 0x80)
        return true;
    return isAlphaNum(cast(char) c) || "!#$%&'*+/=?^_`{|}~".indexOfChar(cast(char) c);
}

// DOMAIN_LABEL: CHARS++(?:-++CHARS++)*+
private bool domainLabel(string s, ref size_t i)
{
    bool wantChars = true;
    bool any;
    while (i < s.length && s[i] != '.')
    {
        if (s[i] == '-')
        {
            if (!any)
                return false;
            while (i < s.length && s[i] == '-')
                ++i;
            wantChars = true;
            continue;
        }
        size_t next = i;
        if (!domainChar(decodeAt(s, next)))
            return false;
        i = next;
        any = true;
        wantChars = false;
    }
    return any && !wantChars;
}

private bool validAddressLiteral(string domain)
{
    if (domain[$ - 1] != ']')
        return false;
    const inner = domain[1 .. $ - 1];
    enum v6 = "IPv6:";
    if (inner.length > v6.length && (inner[0 .. v6.length] == v6 || inner[0 .. v6.length] == "ipv6:"))
        return validIpv6Text(inner[v6.length .. $]);
    return validIpv4(inner);
}

private bool isHexDigit(char ch) pure nothrow @nogc
{
    return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
}

private bool validIpv6Text(string text) pure nothrow @nogc
{
    foreach (ch; text)
        if (!isHexDigit(ch) && ch != ':' && ch != '.')
            return false;
    return true;
}

// [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}
private bool validIpv4(string text) pure nothrow @nogc
{
    int groups, digits;
    foreach (ch; text)
    {
        if (ch == '.')
        {
            if (digits == 0)
                return false;
            ++groups;
            digits = 0;
        }
        else if (ch >= '0' && ch <= '9' && digits < 3)
            ++digits;
        else
            return false;
    }
    return groups == 3 && digits > 0;
}

// HV000030 for a constraint applied to a type it has no validator for.
private bool unexpected(ref const BuiltinConstraint c, ref Any value, string propertyPath)
{
    throw new UnexpectedTypeException("HV000030: No validator could be found for constraint '" ~ javaConstraintName(
            c.annotationType) ~ "' validating type '" ~ javaTypeName(
            value.typeName()) ~ "'. Check configuration for '" ~ propertyPath ~ "'");
}

/// Hibernate's name of a constraint annotation: the Jakarta package for the built-ins.
string javaConstraintName(string type) pure nothrow
{
    enum prefix = "flint.";
    return type.length > prefix.length && type[0 .. prefix.length] == prefix ? type[prefix.length .. $] : type;
}

/// Java's name of a Flint scalar type, as Hibernate prints a validated type.
string javaTypeName(string type) pure nothrow
{
    switch (type)
    {
    case "int":
        return "java.lang.Integer";
    case "long":
        return "java.lang.Long";
    case "short":
        return "java.lang.Short";
    case "byte":
        return "java.lang.Byte";
    case "double":
        return "java.lang.Double";
    case "float":
        return "java.lang.Float";
    case "bool":
        return "java.lang.Boolean";
    case "string":
        return "java.lang.String";
    case "char", "wchar", "dchar":
        return "java.lang.Character";
    default:
        return javaLibraryName(type);
    }
}

// flint.java.time.Duration is java.time.Duration; other names are kept.
private string javaLibraryName(string type) pure nothrow @nogc
{
    enum prefix = "flint.java.";
    return type.length > prefix.length && type[0 .. prefix.length] == prefix ? type["flint.".length .. $] : type;
}

@("Character.isWhitespace and String.isBlank")
unittest
{
    assert(isBlank("") && isBlank(" \t\n\xE2\x80\x83") && !isBlank(" a "));
    assert(!isBlank("\xC2\xA0"), "Java does not count the non-breaking space as whitespace");
    assert(utf16Length("café") == 4 && utf16Length("😀") == 2);
}

@("Hibernate's e-mail grammar")
unittest
{
    foreach (ok; [
        "a@b", "first.last@example.com", "x+tag@sub.example.org", `"quoted local"@example.com`,
        "user@[192.168.0.1]", "user@[IPv6:2001:db8::1]", "ñandú@dominio.es", ""
    ])
        assert(isValidEmail(ok), ok);
    foreach (bad; [
        "plain", "a@b.", ".a@b", "a..b@c", "a@-b", "a@b..c", "a@[1.2.3]", "a@[1.2.3.4444]", "a b@c"
    ])
        assert(!isValidEmail(bad), bad);
}

unittest
{
    import std.utf : decode;

    static immutable texts = [
        "a", "é", "€", "😀", "\xC0\x80", "\xE0\x80\x80", "\xED\xA0\x80", "\xF4\x90\x80\x80",
        "\xFF", "\xC3", "\xE2\x82", "\xC3\x28", "a\xF0\x9F\x98"
    ];
    foreach (text; texts)
    {
        size_t mine, theirs;
        dchar expected;
        try
            expected = decode(text, theirs);
        catch (Exception)
        {
            expected = 0xFFFD;
            theirs = 1;
        }
        assert(decodeAt(text, mine) == expected && mine == theirs, text);
    }
}
