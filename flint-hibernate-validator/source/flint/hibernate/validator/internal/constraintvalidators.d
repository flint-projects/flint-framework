/*
 * Ported from Hibernate Validator 9.1.6.Final, https://github.com/hibernate/hibernate-validator,
 * tag 9.1.6.Final: engine/src/main/java/org/hibernate/validator/internal/constraintvalidators/
 * bv/{NotNullValidator,NullValidator,AssertTrueValidator,AssertFalseValidator,NotBlankValidator,
 * PatternValidator,EmailValidator,DigitsValidatorForNumber,DigitsValidatorForCharSequence}.java,
 * bv/notempty/*, bv/size/*, bv/number/bound/*, bv/number/bound/decimal/*, bv/number/sign/*,
 * AbstractEmailValidator.java and internal/util/DomainNameUtil.java
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright Red Hat Inc. and Hibernate Authors
 *
 * Modified by the Flint authors: one erased dispatcher replaces Hibernate's validator
 * per (constraint, type) pair; values arrive boxed in Any. Character counts are
 * UTF-16 units, as CharSequence.length() is (rulebook R14); whitespace is
 * Character.isWhitespace's. The e-mail grammar is Hibernate's regular expressions
 * written as code. @Past/@Future and friends wait for flint.java.time.
 */

/// The built-in constraints: which ones exist, their attributes, and their validity checks.
module flint.hibernate.validator.internal.constraintvalidators;

import flint.engine.aot.any : Any;
import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.internal.el : ElValue;
import flint.jakarta.validation : UnexpectedTypeException;
import flint.jakarta.validation.constraints : AssertFalse, AssertTrue, DecimalMax, DecimalMin,
    Digits, Email, Future, FutureOrPresent, Max, Min, Negative, NegativeOrZero, NotBlank, NotEmpty,
    NotNull, Null, Past, PastOrPresent, Pattern, Positive, PositiveOrZero, Size;
import flint.java.util : RawCollection, RawMap;
import flint.validate.patterns : RuntimePattern, compileRuntimePattern;

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
        import std.conv : to;

        string text = "[";
        foreach (i, element; value)
            text ~= (i ? ", " : "") ~ element.to!string;
        return ElValue.of(text ~ "]");
    }
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

/// Compiled patterns, shared by a validator factory.
final class PatternCache
{
    private RuntimePattern[string] patterns;

    /// The compiled pattern for `regexp`, compiling it once.
    RuntimePattern get(string regexp)
    {
        synchronized (this)
        {
            if (auto found = regexp in patterns)
                return *found;
            auto compiled = compileRuntimePattern(regexp);
            patterns[regexp] = compiled;
            return compiled;
        }
    }
}

/// Run the check of constraint `c` on `value`; `propertyPath` names the element in an UnexpectedTypeException.
bool isValid(ref const BuiltinConstraint c, ref Any value, PatternCache patterns, string propertyPath)
{
    const simple = simpleName(c.annotationType);
    switch (simple)
    {
    case "NotNull":
        return !value.isNull();
    case "Null":
        return value.isNull();
    case "AssertTrue":
    case "AssertFalse":
        return checkAssert(c, value, simple == "AssertTrue", propertyPath);
    case "NotBlank":
        return checkNotBlank(c, value, propertyPath);
    case "NotEmpty":
        return !value.isNull() && size(c, value, propertyPath) > 0;
    case "Size":
        return checkSize(c, value, propertyPath);
    case "Pattern":
        return checkPattern(c, value, patterns, propertyPath);
    case "Email":
        return checkEmail(c, value, patterns, propertyPath);
    default:
        return checkNumber(c, simple, value, propertyPath);
    }
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

private bool checkSize(ref const BuiltinConstraint c, ref Any value, string propertyPath)
{
    if (value.isNull())
        return true;
    const n = size(c, value, propertyPath);
    return n >= attribute(c, "min").number && n <= attribute(c, "max").number;
}

private bool checkPattern(ref const BuiltinConstraint c, ref Any value, PatternCache patterns, string propertyPath)
{
    if (value.isNull())
        return true;
    if (!value.holds!string())
        return unexpected(c, value, propertyPath);
    return patterns.get(attribute(c, "regexp").text).matches(cast(const(ubyte)[]) value.get!string());
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
    return extra == ".*" || patterns.get(extra).matches(cast(const(ubyte)[]) text);
}

private bool checkNumber(ref const BuiltinConstraint c, string simple, ref Any value, string propertyPath)
{
    if (value.isNull())
        return true;
    if (simple == "Past" || simple == "PastOrPresent" || simple == "Future" || simple == "FutureOrPresent")
        return unexpected(c, value, propertyPath);
    const read = readNumber(value);
    const integral = read.integral;
    const number = read.number;
    const whole = read.whole;
    if (!integral && number != number && !value.holds!double())
        return unexpected(c, value, propertyPath);
    if (simple == "Digits")
        return checkDigits(value, integral, number, cast(int) attribute(c, "integer").number,
                cast(int) attribute(c, "fraction").number);
    if (simple == "Min" || simple == "Max" || simple == "DecimalMin" || simple == "DecimalMax")
        return checkBound(c, simple, integral, whole, number);
    return checkSign(simple, number);
}

private bool checkBound(ref const BuiltinConstraint c, string simple, bool integral, long whole, double number)
{
    switch (simple)
    {
    case "Min":
        return compareTo(integral, whole, number, attribute(c, "value").number, -1) >= 0;
    case "Max":
        return compareTo(integral, whole, number, attribute(c, "value").number, 1) <= 0;
    case "DecimalMin":
        const lowest = decimal(attribute(c, "value").text);
        return attribute(c, "inclusive").boolean ? number >= lowest : number > lowest;
    default:
        const highest = decimal(attribute(c, "value").text);
        return attribute(c, "inclusive").boolean ? number <= highest : number < highest;
    }
}

// NumberSignHelper.signum with NaN treated as failing.
private bool checkSign(string simple, double number) pure nothrow @nogc
{
    if (number != number)
        return false;
    switch (simple)
    {
    case "Positive":
        return number > 0;
    case "PositiveOrZero":
        return number >= 0;
    case "Negative":
        return number < 0;
    case "NegativeOrZero":
        return number <= 0;
    default:
        return true;
    }
}

private struct NumberRead
{
    bool integral;
    double number = double.nan;
    long whole;
}

// Reads an integral, floating-point or numeric String value.
private NumberRead readNumber(ref Any value)
{
    if (value.holds!long() && !value.holds!bool())
    {
        const whole = value.get!long();
        return NumberRead(true, whole, whole);
    }
    if (value.holds!double() && !value.holds!string() && !value.holds!bool())
        return NumberRead(false, value.get!double());
    // Hibernate's validators for CharSequence parse a BigDecimal; an unparsable String is invalid.
    if (value.holds!string())
        return NumberRead(false, decimal(value.get!string()));
    return NumberRead.init;
}

private double decimal(string text) pure nothrow
{
    import std.conv : to;
    import std.string : strip;

    try
        return text.strip().to!double;
    catch (Exception)
        return double.nan;
}

// NumberComparatorHelper.compare: NaN compares as `nanAs` (-1 for @Min, 1 for @Max), so it fails both.
private int compareTo(bool integral, long whole, double number, double bound, int nanAs) pure nothrow @nogc
{
    if (integral)
    {
        const limit = cast(long) bound;
        return whole < limit ? -1 : whole > limit ? 1 : 0;
    }
    if (number != number)
        return nanAs;
    return number < bound ? -1 : number > bound ? 1 : 0;
}

// DigitsValidatorForNumber: BigDecimal(value.toString()).stripTrailingZeros(), integer digits = precision - scale.
private bool checkDigits(ref Any value, bool integral, double number, int maxInteger, int maxFraction)
{
    import flint.serde.java_number : javaDoubleString;
    import std.conv : to;

    string text = integral ? value.get!long().to!string : value.holds!string()
        ? value.get!string() : javaDoubleString(number);
    long[2] digits = countDigits(text);
    return digits[0] <= maxInteger && digits[1] <= maxFraction;
}

// Integer and fraction digits of a decimal text with an optional sign and exponent, trailing zeros stripped.
private long[2] countDigits(string text)
{
    import std.conv : to;

    if (text.length && (text[0] == '-' || text[0] == '+'))
        text = text[1 .. $];
    long exponent;
    foreach (i, ch; text)
    {
        if (ch == 'E' || ch == 'e')
        {
            exponent = text[i + 1 .. $].to!long;
            text = text[0 .. i];
            break;
        }
    }
    string intPart = text, fracPart;
    foreach (i, ch; text)
    {
        if (ch == '.')
        {
            intPart = text[0 .. i];
            fracPart = text[i + 1 .. $];
        }
    }
    while (fracPart.length && fracPart[$ - 1] == '0')
        fracPart = fracPart[0 .. $ - 1];
    while (intPart.length > 1 && intPart[0] == '0')
        intPart = intPart[1 .. $];
    const integerDigits = (intPart == "0" && fracPart.length ? 0 : cast(long) intPart.length) + exponent;
    const fractionDigits = -exponent + cast(long) fracPart.length;
    return [integerDigits < 0 ? 0 : integerDigits, fractionDigits < 0 ? 0 : fractionDigits];
}

private size_t size(ref const BuiltinConstraint c, ref Any value, string propertyPath)
{
    if (value.holds!string())
        return utf16Length(value.get!string());
    if (auto collection = cast(RawCollection) value.asObject())
        return collection.size();
    if (auto map = cast(RawMap) value.asObject())
        return map.keysAsAny().length;
    return unexpected(c, value, propertyPath) ? 0 : 0;
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

private dchar decodeAt(string s, ref size_t i)
{
    import std.utf : decode;

    try
        return decode(s, i);
    catch (Exception)
    {
        ++i;
        return 0xFFFD;
    }
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
        return type;
    }
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
