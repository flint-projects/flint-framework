/++
`java.text` (clean room, from the Java SE specification): the `MessageFormat` and `NumberFormat` subset that Spring's
`MessageSource` renders messages with.

`MessageFormat` supports Java's quoting (`''` for a quote, `'...'` for literal text, braces included) and the
format elements `{n}`, `{n,number}` and `{n,number,integer}`; other element types format the argument as `{n}`
does. An argument is formatted as Java does: a number with the locale's `NumberFormat` (grouping, at most three
fraction digits, half-even rounding), a string as is, null as `null`, anything else by its `toString`. An index
without an argument stays as `{n}`.
+/
module flint.java.text;

import flint.engine.aot.any : Any;
import flint.java.lang : IllegalArgumentException;
import flint.java.util : Locale;

@safe:

/// Java's `NumberFormat.getInstance(locale)` and `getIntegerInstance(locale)`, for the separators of common locales.
struct NumberFormat
{
    private string groupingSeparator = ",";
    private string decimalSeparator = ".";
    private int maximumFractionDigits = 3;

    /// The general-purpose format of `locale`: grouping, at most three fraction digits.
    static NumberFormat getInstance(const Locale locale = Locale.getDefault()) pure nothrow
    {
        NumberFormat format;
        switch (locale.getLanguage())
        {
        case "de", "es", "it", "nl", "pt", "da", "id", "tr":
            format.groupingSeparator = ".";
            format.decimalSeparator = ",";
            break;
        case "fr":
            format.groupingSeparator = " ";
            format.decimalSeparator = ",";
            break;
        case "ru", "pl", "cs", "sv", "fi", "nb", "uk":
            format.groupingSeparator = " ";
            format.decimalSeparator = ",";
            break;
        default:
            break;
        }
        return format;
    }

    /// The integer format of `locale`: no fraction digits, rounding half-even.
    static NumberFormat getIntegerInstance(const Locale locale = Locale.getDefault()) pure nothrow
    {
        auto format = getInstance(locale);
        format.maximumFractionDigits = 0;
        return format;
    }

    /// `value` with grouping.
    string format(long value) const pure nothrow
    {
        const negative = value < 0;
        ulong magnitude = negative ? -cast(ulong) value : value;
        return (negative ? "-" : "") ~ grouped(magnitude);
    }

    /// `value` with grouping and at most `maximumFractionDigits` fraction digits (half-even).
    string format(double value) const pure nothrow
    {
        if (value != value)
            return "NaN";
        if (value == double.infinity || value == -double.infinity)
            return value < 0 ? "-∞" : "∞";
        const negative = value < 0;
        const magnitude = negative ? -value : value;
        ulong scale = 1;
        foreach (_; 0 .. maximumFractionDigits)
            scale *= 10;
        const scaled = magnitude * scale;
        ulong units = cast(ulong) scaled;
        const remainder = scaled - units;
        if (remainder > 0.5 || (remainder == 0.5 && (units & 1)))
            units++;
        const whole = units / scale;
        ulong fraction = units % scale;
        string text = grouped(whole);
        if (fraction)
        {
            char[] digits;
            foreach (_; 0 .. maximumFractionDigits)
            {
                digits = cast(char)('0' + fraction % 10) ~ digits;
                fraction /= 10;
            }
            size_t end = digits.length;
            while (end > 0 && digits[end - 1] == '0')
                end--;
            text ~= decimalSeparator ~ digits[0 .. end].idup;
        }
        return (negative && text != "0" ? "-" : "") ~ text;
    }

    private string grouped(ulong value) const pure nothrow
    {
        char[20] digits;
        size_t n;
        do
        {
            digits[n++] = cast(char)('0' + value % 10);
            value /= 10;
        }
        while (value);
        string result;
        foreach_reverse (i; 0 .. n)
        {
            result ~= digits[i];
            if (i && i % 3 == 0)
                result ~= groupingSeparator;
        }
        return result;
    }
}

/// Java's `MessageFormat`: a pattern with `{n}` arguments.
final class MessageFormat
{
    private string pattern;
    private Locale locale;

    /// A format for `pattern` in `locale`. Throws `IllegalArgumentException` for an unmatched brace.
    this(string pattern, Locale locale = Locale.getDefault())
    {
        this.pattern = pattern;
        this.locale = locale;
        validate(pattern);
    }

    /// The pattern.
    string toPattern() const pure nothrow @nogc
    {
        return pattern;
    }

    /// The locale.
    Locale getLocale() const pure nothrow @nogc
    {
        return locale;
    }

    /// `MessageFormat.format(pattern, arguments)`.
    static string format(string pattern, Any[] arguments...)
    {
        return new MessageFormat(pattern).format(arguments.dup);
    }

    /// The pattern with `arguments` substituted.
    string format(Any[] arguments)
    {
        string result;
        bool quoted;
        size_t i;
        while (i < pattern.length)
        {
            const c = pattern[i];
            if (c == '\'')
            {
                if (i + 1 < pattern.length && pattern[i + 1] == '\'')
                {
                    result ~= '\'';
                    i += 2;
                    continue;
                }
                quoted = !quoted;
                i++;
            }
            else if (c == '{' && !quoted)
            {
                const end = closingBrace(pattern, i);
                result ~= element(pattern[i + 1 .. end], arguments);
                i = end + 1;
            }
            else
            {
                result ~= c;
                i++;
            }
        }
        return result;
    }

    private string element(string body, Any[] arguments)
    {
        string[] parts;
        size_t start;
        foreach (j, c; body)
            if (c == ',' && parts.length < 2)
            {
                parts ~= trim(body[start .. j]);
                start = j + 1;
            }
        parts ~= trim(body[start .. $]);
        const index = parseIndex(parts[0]);
        if (index >= arguments.length)
            return "{" ~ parts[0] ~ "}";
        auto argument = arguments[index];
        if (parts.length >= 2 && parts[1] == "number")
        {
            const integer = parts.length == 3 && parts[2] == "integer";
            return formatNumber(argument, integer
                    ? NumberFormat.getIntegerInstance(locale) : NumberFormat.getInstance(locale));
        }
        return formatArgument(argument);
    }

    private string formatArgument(Any argument)
    {
        if (argument.isNull)
            return "null";
        const type = argument.typeName;
        if (type == "string")
            return argument.get!string;
        if (isNumber(type))
            return formatNumber(argument, NumberFormat.getInstance(locale));
        return argument.toString();
    }

    private static string formatNumber(Any argument, NumberFormat format)
    {
        switch (argument.typeName)
        {
        case "double", "float", "real":
            return format.format(argument.get!double);
        case "byte", "short", "int", "long", "ubyte", "ushort", "uint":
            return format.format(argument.get!long);
        case "ulong":
            return format.format(cast(long) argument.get!ulong);
        default:
            return argument.isNull ? "null" : argument.toString();
        }
    }

    private static bool isNumber(string type) pure nothrow @nogc
    {
        switch (type)
        {
        case "byte", "short", "int", "long", "ubyte", "ushort", "uint", "ulong", "float",
                "double", "real":
                return true;
        default:
            return false;
        }
    }

    private static size_t parseIndex(string text)
    {
        if (!text.length)
            throw new IllegalArgumentException("can't parse argument number: " ~ text);
        size_t index;
        foreach (c; text)
        {
            if (c < '0' || c > '9')
                throw new IllegalArgumentException("can't parse argument number: " ~ text);
            index = index * 10 + (c - '0');
        }
        return index;
    }

    private static size_t closingBrace(string pattern, size_t open)
    {
        int depth;
        foreach (j; open .. pattern.length)
        {
            if (pattern[j] == '{')
                depth++;
            else if (pattern[j] == '}' && --depth == 0)
                return j;
        }
        throw new IllegalArgumentException("Unmatched braces in the pattern.");
    }

    private static void validate(string pattern)
    {
        bool quoted;
        size_t i;
        while (i < pattern.length)
        {
            if (pattern[i] == '\'')
            {
                if (i + 1 < pattern.length && pattern[i + 1] == '\'')
                    i++;
                else
                    quoted = !quoted;
            }
            else if (pattern[i] == '{' && !quoted)
            {
                const end = closingBrace(pattern, i);
                parseIndex(trim(pattern[i + 1 .. end].length && indexOfComma(pattern[i + 1 .. end]) >= 0
                        ? pattern[i + 1 .. i + 1 + indexOfComma(pattern[i + 1 .. end])] : pattern[i + 1 .. end]));
                i = end;
            }
            i++;
        }
    }

    private static ptrdiff_t indexOfComma(string text) pure nothrow @nogc
    {
        foreach (j, c; text)
            if (c == ',')
                return j;
        return -1;
    }

    private static string trim(string text) pure nothrow @nogc
    {
        size_t start, end = text.length;
        while (start < end && text[start] == ' ')
            start++;
        while (end > start && text[end - 1] == ' ')
            end--;
        return text[start .. end];
    }
}
