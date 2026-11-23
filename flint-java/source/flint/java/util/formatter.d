/++
`java.util.Formatter`'s format strings (clean room, from the Java SE specification), as `String.format` uses them:
one non-template engine over erased arguments (`Any[]`), so a call site instantiates nothing but its `Any.of`
boxing (rulebook R7) and never `std.format`.

Specifiers are `%[argument_index$][flags][width][.precision]conversion`, with `<` for the previous argument.
Conversions: `b B s S c d o x X f n %`; flags `- # + space 0 , (`. Arguments format as Java's would: `%s` as
`String.valueOf` (null, `true`, `Double.toString`, an object's `toString`), `%d`/`%o`/`%x` for integral types (`%x`
of a negative `int` is its 32-bit two's complement, of a `long` its 64-bit one), `%c` for a character or code
point, `%f` for floating point (precision 6 by default, rounded half up).

Deviations: no `Locale` (the root locale's `.` and `,`); `%e`, `%g`, `%a`, `%h` and the date/time conversions throw
`UnknownFormatConversionException`; `%f` rounds through `double` arithmetic, so it can differ from Java's exact
decimal rounding beyond 15 significant digits.
+/
module flint.java.util.formatter;

import flint.engine.aot.any : Any;
import flint.java.lang : IllegalArgumentException;

@safe:

/// Java's `IllegalFormatException`: a format string with illegal syntax or an argument it cannot format.
class IllegalFormatException : IllegalArgumentException
{
    /// With `message`.
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, null, file, line);
    }
}

/// Java's `MissingFormatArgumentException`: a specifier without an argument.
class MissingFormatArgumentException : IllegalFormatException
{
    private string specifier;

    /// For `specifier`, such as `%s`.
    this(string specifier, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super("Format specifier '" ~ specifier ~ "'", file, line);
        this.specifier = specifier;
    }

    /// The specifier.
    string getFormatSpecifier() const pure nothrow @nogc
    {
        return specifier;
    }
}

/// Java's `UnknownFormatConversionException`: an unknown (or unsupported) conversion.
class UnknownFormatConversionException : IllegalFormatException
{
    private string conversion;

    /// For `conversion`.
    this(string conversion, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super("Conversion = '" ~ conversion ~ "'", file, line);
        this.conversion = conversion;
    }

    /// The conversion.
    string getConversion() const pure nothrow @nogc
    {
        return conversion;
    }
}

/// Java's `IllegalFormatConversionException`: a conversion that does not apply to the argument's type.
class IllegalFormatConversionException : IllegalFormatException
{
    /// `conversion` given an argument of type `argumentType` (its Java name).
    this(char conversion, string argumentType, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super([conversion].idup ~ " != " ~ argumentType, file, line);
    }
}

/// `format` with `arguments` substituted, as `java.util.Formatter.format(format, args).toString()`.
string formatJava(string format, scope Any[] arguments)
{
    string result;
    size_t next; // the next ordinary index
    ptrdiff_t previous = -1;
    size_t i;
    while (i < format.length)
    {
        if (format[i] != '%')
        {
            size_t end = i;
            while (end < format.length && format[end] != '%')
                end++;
            result ~= format[i .. end];
            i = end;
            continue;
        }
        Spec spec;
        i = parseSpec(format, i, spec);
        result ~= render(spec, arguments, next, previous);
    }
    return result;
}

private struct Spec
{
    string text; // the specifier as written, for messages
    ptrdiff_t index = -1; // explicit 1-based index, 0 for `<`, -1 for ordinary
    bool leftJustify, alternate, plus, space, zeroPad, group, parentheses;
    int width = -1;
    int precision = -1;
    char conversion;
}

/// Parse the specifier at `format[start]` (a `%`); returns the index after it.
private size_t parseSpec(string format, size_t start, out Spec spec)
{
    size_t i = parseIndex(format, start + 1, spec);
    i = parseFlags(format, i, spec);
    const widthStart = i;
    while (i < format.length && format[i] >= '0' && format[i] <= '9')
        i++;
    if (i > widthStart)
        spec.width = cast(int) number(format[widthStart .. i]);
    if (i < format.length && format[i] == '.')
    {
        const precisionStart = ++i;
        while (i < format.length && format[i] >= '0' && format[i] <= '9')
            i++;
        if (i == precisionStart)
            throw new UnknownFormatConversionException(format[precisionStart - 1 .. i]);
        spec.precision = cast(int) number(format[precisionStart .. i]);
    }
    if (i >= format.length)
        throw new UnknownFormatConversionException("%");
    spec.conversion = format[i];
    spec.text = format[start .. i + 1];
    return i + 1;
}

/// The argument index: `n$`, or `<` for the previous argument.
private size_t parseIndex(string format, size_t i, ref Spec spec) pure nothrow @nogc
{
    size_t digits = i;
    while (digits < format.length && format[digits] >= '0' && format[digits] <= '9')
        digits++;
    if (digits > i && digits < format.length && format[digits] == '$')
    {
        spec.index = number(format[i .. digits]);
        return digits + 1;
    }
    if (i < format.length && format[i] == '<')
    {
        spec.index = 0;
        return i + 1;
    }
    return i;
}

private size_t parseFlags(string format, size_t i, ref Spec spec) pure nothrow @nogc
{
    for (; i < format.length; i++)
    {
        switch (format[i])
        {
        case '-':
            spec.leftJustify = true;
            break;
        case '#':
            spec.alternate = true;
            break;
        case '+':
            spec.plus = true;
            break;
        case ' ':
            spec.space = true;
            break;
        case '0':
            spec.zeroPad = true;
            break;
        case ',':
            spec.group = true;
            break;
        case '(':
            spec.parentheses = true;
            break;
        default:
            return i;
        }
    }
    return i;
}

private long number(string digits) pure nothrow @nogc
{
    long value;
    foreach (c; digits)
        value = value * 10 + (c - '0');
    return value;
}

/// The text of one specifier, taking its argument from `arguments`.
private string render(const ref Spec spec, scope Any[] arguments, ref size_t next, ref ptrdiff_t previous)
{
    switch (spec.conversion)
    {
    case 'n':
        return "\n";
    case '%':
        return pad(spec, "%");
    default:
        break;
    }
    size_t index;
    if (spec.index > 0)
        index = spec.index - 1;
    else if (spec.index == 0)
    {
        if (previous < 0)
            throw new MissingFormatArgumentException(spec.text);
        index = previous;
    }
    else
        index = next++;
    if (index >= arguments.length)
        throw new MissingFormatArgumentException(spec.text);
    previous = index;
    return pad(spec, convert(spec, arguments[index]));
}

private string convert(const ref Spec spec, Any argument)
{
    switch (spec.conversion)
    {
    case 'b', 'B':
        return cased(spec, truncate(spec, booleanText(argument)));
    case 's', 'S':
        return cased(spec, truncate(spec, stringText(argument)));
    case 'c':
        return argument.isNull ? "null" : characterText(argument);
    case 'd':
        return integralText(spec, argument);
    case 'o', 'x', 'X':
        return radixText(spec, argument);
    case 'f':
        return fixedText(spec, argument);
    default:
        throw new UnknownFormatConversionException([spec.conversion]);
    }
}

private string truncate(const ref Spec spec, string text) pure nothrow @nogc
{
    return spec.precision >= 0 && spec.precision < text.length ? text[0 .. spec.precision] : text;
}

private string cased(const ref Spec spec, string text) pure nothrow
{
    if (spec.conversion != 'S' && spec.conversion != 'B' && spec.conversion != 'X')
        return text;
    auto upper = text.dup;
    foreach (ref c; upper)
        if (c >= 'a' && c <= 'z')
            c = cast(char)(c - 32);
    return upper.idup;
}

/// Pad to the width: spaces on the left, or the right with `-`.
private string pad(const ref Spec spec, string text) pure nothrow
{
    if (spec.width < 0 || text.length >= spec.width)
        return text;
    auto spaces = new char[](spec.width - text.length);
    spaces[] = ' ';
    return spec.leftJustify ? text ~ spaces : spaces ~ text;
}

private string booleanText(Any argument)
{
    if (argument.isNull)
        return "false";
    if (argument.typeName == "bool")
        return argument.get!bool ? "true" : "false";
    return "true";
}

/// `String.valueOf` of the argument.
private string stringText(Any argument)
{
    import flint.java.lang : doubleToString, floatToString;

    if (argument.isNull)
        return "null";
    switch (argument.typeName)
    {
    case "double":
        return doubleToString(argument.get!double);
    case "float":
        return floatToString(cast(float) argument.get!double);
    default:
        break;
    }
    if (auto object = argument.asObject())
    {
        import flint.engine.aot.objects : objectToString;

        return objectToString(object);
    }
    return argument.toString();
}

private bool isIntegral(string typeName) pure nothrow @nogc
{
    switch (typeName)
    {
    case "byte", "short", "int", "long", "ubyte", "ushort", "uint", "ulong":
        return true;
    default:
        return false;
    }
}

private string javaTypeName(Any argument) pure nothrow
{
    switch (argument.typeName)
    {
    case "string":
        return "java.lang.String";
    case "bool":
        return "java.lang.Boolean";
    case "double":
        return "java.lang.Double";
    case "float":
        return "java.lang.Float";
    case "char", "wchar", "dchar":
        return "java.lang.Character";
    default:
        return argument.typeName;
    }
}

private string characterText(Any argument)
{
    import flint.engine.aot.text : utf8;

    const character = argument.typeName == "char" || argument.typeName == "wchar" || argument.typeName == "dchar";
    if (!character && !isIntegral(argument.typeName))
        throw new IllegalFormatConversionException('c', javaTypeName(argument));
    const code = character ? cast(long) argument.get!dchar : argument.get!long;
    const text = code < 0 || code > 0x10FFFF ? null : utf8(cast(dchar) code);
    if (text is null)
        throw new IllegalFormatException("Code point = 0x" ~ hex(cast(ulong) code));
    return text;
}

private string integralText(const ref Spec spec, Any argument)
{
    if (argument.isNull)
        return "null";
    if (!isIntegral(argument.typeName))
        throw new IllegalFormatConversionException('d', javaTypeName(argument));
    const unsigned = argument.typeName == "ulong";
    const value = argument.get!long;
    const negative = !unsigned && value < 0;
    const magnitude = negative ? -cast(ulong) value : cast(ulong) value;
    return signed(spec, digits(magnitude, 10, spec.group), negative);
}

/// Apply the sign flags and zero padding to `body`, the magnitude's digits.
private string signed(const ref Spec spec, string body, bool negative) pure nothrow
{
    string prefix = negative ? (spec.parentheses ? "(" : "-") : spec.plus ? "+" : spec.space ? " " : "";
    const suffix = negative && spec.parentheses ? ")" : "";
    if (spec.zeroPad && spec.width > 0)
    {
        const used = prefix.length + body.length + suffix.length;
        if (used < spec.width)
        {
            auto zeros = new char[](spec.width - used);
            zeros[] = '0';
            body = zeros.idup ~ body;
        }
    }
    return prefix ~ body ~ suffix;
}

private string radixText(const ref Spec spec, Any argument)
{
    if (argument.isNull)
        return "null";
    if (!isIntegral(argument.typeName))
        throw new IllegalFormatConversionException(spec.conversion, javaTypeName(argument));
    ulong bits = cast(ulong) argument.get!long;
    switch (argument.typeName)
    {
    case "byte":
        bits &= 0xFF;
        break;
    case "short":
        bits &= 0xFFFF;
        break;
    case "int":
        bits &= 0xFFFF_FFFF;
        break;
    default:
        break;
    }
    const octal = spec.conversion == 'o';
    auto body = digits(bits, octal ? 8 : 16, false);
    if (spec.alternate)
        body = (octal ? "0" : "0x") ~ body;
    return cased(spec, signed(spec, body, false));
}

private string fixedText(const ref Spec spec, Any argument)
{
    if (argument.isNull)
        return "null";
    if (argument.typeName != "double" && argument.typeName != "float")
        throw new IllegalFormatConversionException('f', javaTypeName(argument));
    const value = argument.get!double;
    const negative = value < 0 || (value == 0 && 1 / value < 0);
    if (value != value || value == double.infinity || value == -double.infinity)
        return pad(spec, nonFinite(spec, value, negative));
    const precision = spec.precision < 0 ? 6 : spec.precision;
    string whole, fraction;
    decimalDigits(negative ? -value : value, whole, fraction);
    roundHalfUp(whole, fraction, precision);
    auto body = spec.group ? grouped(whole) : whole;
    if (precision > 0 || spec.alternate)
        body ~= "." ~ fraction;
    return signed(spec, body, negative);
}

/// `NaN` and the infinities, with Java's sign flags.
private string nonFinite(const ref Spec spec, double value, bool negative) pure nothrow @nogc
{
    if (value != value)
        return "NaN";
    if (negative)
        return spec.parentheses ? "(Infinity)" : "-Infinity";
    return spec.plus ? "+Infinity" : "Infinity";
}

/// The whole and fraction digits of `magnitude` from Java's shortest representation (`Double.toString`), which
/// Java's `Formatter` rounds from (a `float` is widened to `double` first, as Java does).
private void decimalDigits(double magnitude, out string whole, out string fraction)
{
    import flint.java.lang : doubleToString;

    const text = doubleToString(magnitude);
    size_t e;
    while (e < text.length && text[e] != 'E')
        e++;
    long exponent;
    if (e < text.length)
    {
        const negativeExponent = text[e + 1] == '-';
        exponent = number(text[e + (negativeExponent ? 2 : 1) .. $]);
        if (negativeExponent)
            exponent = -exponent;
    }
    string digitText;
    ptrdiff_t point = -1;
    foreach (i, c; text[0 .. e])
    {
        if (c == '.')
            point = cast(ptrdiff_t) digitText.length;
        else
            digitText ~= c;
    }
    ptrdiff_t position = (point < 0 ? cast(ptrdiff_t) digitText.length : point) + exponent;
    while (position <= 0)
    {
        digitText = "0" ~ digitText;
        position++;
    }
    while (position > digitText.length)
        digitText ~= '0';
    whole = digitText[0 .. position];
    fraction = digitText[position .. $];
    while (whole.length > 1 && whole[0] == '0')
        whole = whole[1 .. $];
}

/// Round `whole.fraction` to `precision` fraction digits, half up, as Java's `RoundingMode.HALF_UP`.
private void roundHalfUp(ref string whole, ref string fraction, int precision) pure nothrow
{
    if (fraction.length <= precision)
    {
        while (fraction.length < precision)
            fraction ~= '0';
        return;
    }
    const up = fraction[precision] >= '5';
    auto digits = (whole ~ fraction[0 .. precision]).dup;
    if (up)
    {
        size_t i = digits.length;
        while (i > 0 && digits[i - 1] == '9')
            digits[--i] = '0';
        if (i == 0)
            digits = "1".dup ~ digits;
        else
            digits[i - 1]++;
    }
    whole = digits[0 .. $ - precision].idup;
    fraction = digits[$ - precision .. $].idup;
}

/// Decimal digits with `,` every three from the right.
private string grouped(string digitText) pure nothrow
{
    string result;
    foreach (i, c; digitText)
    {
        if (i && (digitText.length - i) % 3 == 0)
            result ~= ',';
        result ~= c;
    }
    return result;
}

/// `value` in `radix`, with `,` every three digits when `group` (decimal only).
private string digits(ulong value, uint radix, bool group) pure nothrow
{
    char[66] buffer;
    size_t at = buffer.length;
    size_t count;
    do
    {
        if (group && count && count % 3 == 0)
            buffer[--at] = ',';
        const digit = cast(uint)(value % radix);
        buffer[--at] = cast(char)(digit < 10 ? '0' + digit : 'a' + digit - 10);
        value /= radix;
        count++;
    }
    while (value);
    return buffer[at .. $].idup;
}

private string hex(ulong value) pure nothrow
{
    return digits(value, 16, false);
}
