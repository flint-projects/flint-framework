/++
`java.text.DateFormat`, `SimpleDateFormat`, `ParsePosition` and `ParseException` (clean room, from the Java SE
specification), checked against JDK 21 by flint-java/tests/golden/dates.tsv.

`SimpleDateFormat` formats and parses through a `GregorianCalendar`, as Java's does: every pattern letter of
`GyMdkHmsSEDFwWahKzZYuXL`, quoting with `'`, Java's messages for an illegal letter or an open quote, lenient
parsing by default (fields carry over, text after the pattern is ignored, numbers that abut read their letter
count), two-digit years in the 80 years before and 20 after the format's creation, and zones as "GMT±hh:mm",
RFC 822 offsets, ISO 8601 offsets or the English names of UTC and GMT.

Deviations: names (months, days, eras, AM/PM, zones) are English, the `en_US` names; a non-English `Locale` with a
pattern that uses names throws `IllegalArgumentException` rather than print the wrong language. Zone names other
than UTC's and GMT's need the time-zone database, which Flint has not ported. `DateFormat.format` returns a string:
the `StringBuffer` and `FieldPosition` overload is not provided. 'F' and 'W' are formatted but do not decide a
parsed date. 'Y' parses as the calendar year.
+/
module flint.java.text.simpledateformat;

import flint.java.lang : IllegalArgumentException;
import flint.java.util : Locale;
import flint.java.util.calendar : Calendar, GregorianCalendar;
import flint.java.util.date : Date;
import flint.java.util.timezone : TimeZone;

@safe:

/// Java's checked `ParseException`: text that does not match the format, and where.
class ParseException : Exception
{
    private int errorOffset;

    /// `message`, at `errorOffset` in the text.
    this(string message, int errorOffset, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc
    {
        super(message, file, line);
        this.errorOffset = errorOffset;
    }

    /// The position in the text where the error was found.
    int getErrorOffset() const pure nothrow @nogc
    {
        return errorOffset;
    }

    /// The detail message.
    string getMessage() const pure nothrow @nogc
    {
        return msg;
    }
}

/// Java's `ParsePosition`: where parsing starts, and where it stopped or failed.
class ParsePosition
{
    private int index;
    private int errorIndex = -1;

    /// A position at `index`.
    this(int index) pure nothrow @nogc
    {
        this.index = index;
    }

    /// The current position.
    int getIndex() const pure nothrow @nogc
    {
        return index;
    }

    /// Set the current position.
    void setIndex(int index) pure nothrow @nogc
    {
        this.index = index;
    }

    /// Where an error was found; -1 when none was.
    int getErrorIndex() const pure nothrow @nogc
    {
        return errorIndex;
    }

    /// Set where an error was found.
    void setErrorIndex(int errorIndex) pure nothrow @nogc
    {
        this.errorIndex = errorIndex;
    }
}

/// Java's `DateFormat`: formats and parses dates through its `calendar`.
abstract class DateFormat
{
    /// The calendar the format computes fields with; its zone and leniency are the format's.
    protected Calendar calendar;

    /// `date` as text.
    abstract string format(const Date date);

    /// Parse a date from `source` at `pos`: on success `pos` moves past it, on failure the result is null and
    /// `pos`'s error index is set.
    abstract Date parse(string source, ParsePosition pos);

    /// Parse a date from the beginning of `source`; text after it is ignored. Throws `ParseException`.
    Date parse(string source)
    {
        auto pos = new ParsePosition(0);
        auto result = parse(source, pos);
        if (result is null)
            throw new ParseException("Unparseable date: \"" ~ source ~ "\"", pos.getErrorIndex());
        return result;
    }

    /// The calendar.
    Calendar getCalendar() pure nothrow @nogc
    {
        return calendar;
    }

    /// Set the calendar.
    void setCalendar(Calendar newCalendar) pure nothrow @nogc
    {
        calendar = newCalendar;
    }

    /// The time zone.
    TimeZone getTimeZone()
    {
        return calendar.getTimeZone();
    }

    /// Set the time zone.
    void setTimeZone(TimeZone zone)
    {
        calendar.setTimeZone(zone);
    }

    /// Whether parsing is lenient.
    bool isLenient()
    {
        return calendar.isLenient();
    }

    /// Set the leniency of parsing.
    void setLenient(bool lenient)
    {
        calendar.setLenient(lenient);
    }
}

/// Java's `SimpleDateFormat`.
class SimpleDateFormat : DateFormat
{
    alias parse = DateFormat.parse;

    private string pattern;
    private Element[] compiled;
    private long defaultCenturyStart;
    private int defaultCenturyStartYear;

    /// A format for `pattern`, with English names, in the default zone (UTC). Throws `IllegalArgumentException`
    /// with Java's message for an invalid pattern.
    this(string pattern)
    {
        this(pattern, Locale.US);
    }

    /// A format for `pattern` in `locale`. Throws `IllegalArgumentException` for an invalid pattern, and for a
    /// pattern with names in a locale other than English (deviation).
    this(string pattern, const Locale locale)
    {
        compiled = compilePattern(pattern);
        const language = locale.getLanguage();
        if (language.length && language != "en" && usesNames(compiled))
            throw new IllegalArgumentException("SimpleDateFormat \"" ~ pattern
                    ~ "\" needs the names of locale " ~ language ~ "; Flint has English names only");
        this.pattern = pattern;
        calendar = new GregorianCalendar(TimeZone.getDefault());
        auto start = new GregorianCalendar(TimeZone.getDefault());
        start.add(Calendar.YEAR, -80);
        defaultCenturyStart = start.getTimeInMillis();
        defaultCenturyStartYear = start.get(Calendar.YEAR);
    }

    /// The pattern.
    string toPattern() const pure nothrow @nogc
    {
        return pattern;
    }

    /// Use `pattern` from now on.
    void applyPattern(string pattern)
    {
        compiled = compilePattern(pattern);
        this.pattern = pattern;
    }

    /// The start of the hundred years that two-digit years are read into.
    Date get2DigitYearStart() const pure nothrow
    {
        return new Date(defaultCenturyStart);
    }

    /// Read two-digit years into the hundred years from `startDate`.
    void set2DigitYearStart(const Date startDate)
    {
        auto start = new GregorianCalendar(calendar.getTimeZone());
        start.setTime(startDate);
        defaultCenturyStart = startDate.getTime();
        defaultCenturyStartYear = start.get(Calendar.YEAR);
    }

    override string format(const Date date)
    {
        calendar.setTime(date);
        TextBuffer result;
        foreach (e; compiled)
            if (e.letter == 0)
                result.put(e.text);
            else
                formatField(result, e);
        return result.text();
    }

    private void formatField(ref TextBuffer result, Element e)
    {
        switch (e.letter)
        {
        case 'y':
            return formatYear(result, calendar.get(Calendar.YEAR), e.count);
        case 'Y':
            auto gregorian = cast(GregorianCalendar) calendar;
            return formatYear(result, gregorian ? gregorian.getWeekYear() : calendar.get(Calendar.YEAR), e.count);
        case 'M':
        case 'L':
            if (e.count < 3)
                return result.number(calendar.get(Calendar.MONTH) + 1, e.count);
            goto case;
        case 'G':
        case 'E':
        case 'a':
            return result.put(nameField(e));
        case 'z':
        case 'Z':
        case 'X':
            return formatZone(result, e);
        default:
            return result.number(numericField(e.letter), e.count);
        }
    }

    // Eras, months, days of the week and AM/PM, in English; four letters or more give the full name.
    private string nameField(Element e)
    {
        const full = e.count >= 4;
        switch (e.letter)
        {
        case 'G':
            return eras[calendar.get(Calendar.ERA)];
        case 'E':
            const day = calendar.get(Calendar.DAY_OF_WEEK) - 1;
            return full ? dayNames[day] : dayShort[day];
        case 'a':
            return amPm[calendar.get(Calendar.AM_PM)];
        default:
            const month = calendar.get(Calendar.MONTH);
            return full ? monthNames[month] : monthShort[month];
        }
    }

    private void formatZone(ref TextBuffer result, Element e)
    {
        const dst = calendar.get(Calendar.DST_OFFSET);
        if (e.letter == 'z')
            return result.put(calendar.getTimeZone().getDisplayName(dst != 0, e.count >= 4
                    ? TimeZone.LONG : TimeZone.SHORT));
        const offset = calendar.get(Calendar.ZONE_OFFSET) + dst;
        if (e.letter == 'X' && offset == 0)
            return result.put('Z');
        result.offset(offset, e.letter == 'Z' ? 2 : e.count);
    }

    private int numericField(char letter)
    {
        switch (letter)
        {
        case 'k':
            const hour = calendar.get(Calendar.HOUR_OF_DAY);
            return hour == 0 ? 24 : hour;
        case 'h':
            const hour = calendar.get(Calendar.HOUR);
            return hour == 0 ? 12 : hour;
        case 'u':
            const day = calendar.get(Calendar.DAY_OF_WEEK);
            return day == Calendar.SUNDAY ? 7 : day - 1;
        default:
            return calendar.get(numericFields[letterIndex(letter)]);
        }
    }

    override Date parse(string text, ParsePosition pos)
    {
        auto state = Parser(text, pos.getIndex(), defaultCenturyStartYear);
        foreach (i, e; compiled)
        {
            const abutting = i + 1 < compiled.length && isNumeric(e) && isNumeric(compiled[i + 1]);
            if (!(e.letter == 0 ? state.literal(e.text) : state.field(e, abutting, isLenient())))
            {
                pos.setErrorIndex(cast(int) state.pos);
                return null;
            }
        }
        long millis;
        try
        {
            millis = establish(state, 0);
            if (state.ambiguousYear && millis < defaultCenturyStart)
                millis = establish(state, 100);
        }
        catch (IllegalArgumentException)
        {
            pos.setErrorIndex(cast(int) state.pos);
            return null;
        }
        pos.setIndex(cast(int) state.pos);
        return new Date(millis);
    }

    // CalendarBuilder.establish: the parsed fields, in the order they were parsed, set on a cleared calendar.
    private long establish(ref const Parser state, int yearDelta)
    {
        calendar.clear();
        foreach (f; state.parsed[0 .. state.count])
            calendar.set(f.field, f.field == Calendar.YEAR ? f.value + yearDelta : f.value);
        return calendar.getTimeInMillis();
    }
}

// ---- patterns

private struct Element
{
    char letter; // 0 for literal text
    int count;
    string text; // the literal text
}

// The pattern letters, and the Calendar field each numeric letter reads (-1 for the letters handled apart).
private enum string patternLetters = "GyMdkHmsSEDFwWahKzZYuXL";
private static immutable int[patternLetters.length] numericFields = [
    -1, -1, -1, Calendar.DAY_OF_MONTH, -1, Calendar.HOUR_OF_DAY, Calendar.MINUTE,
    Calendar.SECOND, Calendar.MILLISECOND, -1, Calendar.DAY_OF_YEAR,
    Calendar.DAY_OF_WEEK_IN_MONTH, Calendar.WEEK_OF_YEAR, Calendar.WEEK_OF_MONTH, -1, -1,
    Calendar.HOUR, -1, -1, -1, -1, -1, -1
];

private size_t letterIndex(char c) pure nothrow @nogc
{
    foreach (i, letter; patternLetters)
        if (letter == c)
            return i;
    return size_t.max;
}

// Java's compile: letters repeat into one element, quotes hold literal text ('' is a quote mark), other characters
// are literal; an unknown letter, an open quote or 'X' four times or more throws Java's IllegalArgumentException.
private Element[] compilePattern(string pattern)
{
    Element[] elements;
    for (size_t i; i < pattern.length;)
    {
        const c = pattern[i];
        if (c == '\'')
        {
            const quoted = quotedText(pattern, i);
            if (!quoted.closed)
                throw new IllegalArgumentException("Unterminated quote");
            appendLiteral(elements, quoted.text);
            i = quoted.end;
            continue;
        }
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')))
        {
            appendLiteral(elements, pattern[i .. i + 1]);
            ++i;
            continue;
        }
        if (letterIndex(c) == size_t.max)
            throw new IllegalArgumentException("Illegal pattern character '" ~ c ~ "'");
        size_t j = i;
        while (j < pattern.length && pattern[j] == c)
            ++j;
        const count = cast(int)(j - i);
        if (c == 'X' && count > 3)
            throw new IllegalArgumentException("invalid ISO 8601 format: length=" ~ cast(char)('0' + count % 10));
        elements ~= Element(c, count, null);
        i = j;
    }
    return elements;
}

private struct Quoted
{
    string text;
    size_t end;
    bool closed;
}

// The text of a quote starting at `start`: '' alone is a quote mark, and '' inside a quote is one too.
private Quoted quotedText(string pattern, size_t start) pure nothrow
{
    if (start + 1 < pattern.length && pattern[start + 1] == '\'')
        return Quoted("'", start + 2, true);
    string text;
    for (size_t i = start + 1; i < pattern.length; ++i)
    {
        if (pattern[i] != '\'')
        {
            text ~= pattern[i];
            continue;
        }
        if (i + 1 < pattern.length && pattern[i + 1] == '\'')
        {
            text ~= '\'';
            ++i;
            continue;
        }
        return Quoted(text, i + 1, true);
    }
    return Quoted(text, pattern.length, false);
}

private void appendLiteral(ref Element[] elements, string text) pure nothrow
{
    if (elements.length && elements[$ - 1].letter == 0)
        elements[$ - 1].text ~= text;
    else
        elements ~= Element(0, 0, text);
}

// Whether the pattern formats or parses names, which are locale-specific.
private bool usesNames(scope const Element[] elements) pure nothrow @nogc
{
    foreach (e; elements)
        if (e.letter == 'G' || e.letter == 'E' || e.letter == 'a' || e.letter == 'z'
                || ((e.letter == 'M' || e.letter == 'L') && e.count >= 3))
            return true;
    return false;
}

// Letters that parse as numbers (a month of one or two letters too): when two abut, the first reads its count.
private bool isNumeric(Element e) pure nothrow @nogc
{
    if (e.letter == 0)
        return false;
    if (e.letter == 'M' || e.letter == 'L')
        return e.count <= 2;
    foreach (c; "ydHmsSkKhDFwWuY")
        if (c == e.letter)
            return true;
    return false;
}

private static immutable string[12] monthNames = [
    "January", "February", "March", "April", "May", "June", "July", "August", "September",
    "October", "November", "December"
];
private static immutable string[12] monthShort = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
];
private static immutable string[7] dayNames = [
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"
];
private static immutable string[7] dayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
private static immutable string[2] amPm = ["AM", "PM"];
private static immutable string[2] eras = ["BC", "AD"];
private static immutable string[2] eraNames = ["Before Christ", "Anno Domini"];
private static immutable string[3] zoneNames = [
    "Coordinated Universal Time", "Greenwich Mean Time", "UTC"
];

// ---- formatting

// 'y' and 'Y': two letters print the last two digits; otherwise at least `count` digits.
private void formatYear(ref TextBuffer result, long year, int count) pure nothrow
{
    if (count != 2)
        return result.number(year, count);
    if (year < 0)
        result.put('-');
    result.number((year < 0 ? -year : year) % 100, 2);
}

// Text built in place: one growing array, copied once by `text`.
private struct TextBuffer
{
    char[] data;
    size_t used;

    void put(scope const(char)[] s) pure nothrow
    {
        reserve(s.length);
        data[used .. used + s.length] = s[];
        used += s.length;
    }

    void put(char c) pure nothrow
    {
        reserve(1);
        data[used++] = c;
    }

    // `value` in decimal, zero-padded to `width` digits, after a '-' when negative.
    void number(long value, int width) pure nothrow
    {
        char[20] digits;
        size_t n;
        ulong v = value < 0 ? -cast(ulong) value : value;
        do
        {
            digits[$ - ++n] = cast(char)('0' + v % 10);
            v /= 10;
        }
        while (v);
        if (value < 0)
            put('-');
        foreach (_; n .. width < 0 ? 0 : width)
            put('0');
        put(digits[$ - n .. $]);
    }

    // An offset in milliseconds as "+HH" (`form` 1), "+HHMM" (2) or "+HH:MM" (3), the minutes truncated.
    void offset(long millis, int form) pure nothrow
    {
        const minutes = (millis < 0 ? -millis : millis) / 60_000;
        put(millis < 0 ? '-' : '+');
        number(minutes / 60, 2);
        if (form == 1)
            return;
        if (form == 3)
            put(':');
        number(minutes % 60, 2);
    }

    string text() const pure nothrow
    {
        return data[0 .. used].idup;
    }

    void reserve(size_t extra) pure nothrow
    {
        if (used + extra > data.length)
            data.length = (used + extra) * 2 + 16;
    }
}

// ---- parsing

private struct ParsedField
{
    int field;
    int value;
}

// SimpleDateFormat.subParse over a text: each field read is recorded for CalendarBuilder, in order.
private struct Parser
{
    string text;
    size_t pos;
    int centuryStartYear;
    ParsedField[24] parsed;
    size_t count;
    bool ambiguousYear;

    void record(int field, long value) pure nothrow @nogc
    {
        if (count < parsed.length)
            parsed[count++] = ParsedField(field, cast(int) value);
    }

    bool literal(string expected) pure nothrow @nogc
    {
        if (text.length - pos < expected.length || text[pos .. pos + expected.length] != expected)
            return false;
        pos += expected.length;
        return true;
    }

    bool field(Element e, bool abutting, bool lenient) pure nothrow @nogc
    {
        // Java skips spaces and tabs before every field.
        while (pos < text.length && (text[pos] == ' ' || text[pos] == '\t'))
            ++pos;
        switch (e.letter)
        {
        case 'G':
        case 'E':
        case 'a':
            return name(e.letter);
        case 'M':
        case 'L':
            if (e.count >= 3)
                return name(e.letter);
            goto default;
        case 'z':
        case 'Z':
            return zoneText();
        case 'X':
            return isoZone(e.count);
        default:
            return numeric(e, abutting, lenient);
        }
    }

    // An era, a day of the week, AM/PM or a month by name.
    bool name(char letter) pure nothrow @nogc
    {
        switch (letter)
        {
        case 'G':
            return named(eras[], eraNames[], Calendar.ERA, 0);
        case 'E':
            return named(dayNames[], dayShort[], Calendar.DAY_OF_WEEK, 1);
        case 'a':
            return named(amPm[], null, Calendar.AM_PM, 0);
        default:
            return named(monthNames[], monthShort[], Calendar.MONTH, 0);
        }
    }

    bool numeric(Element e, bool abutting, bool lenient) pure nothrow @nogc
    {
        const start = pos;
        const limit = abutting ? start + e.count : text.length;
        long value;
        while (pos < text.length && pos < limit && text[pos] >= '0' && text[pos] <= '9')
            value = value * 10 + (text[pos++] - '0');
        if (pos == start)
            return false;
        if (e.letter == 'y' && e.count <= 2 && pos - start == 2)
        {
            // A two-digit year falls in the hundred years from the century start.
            const twoDigits = centuryStartYear % 100;
            ambiguousYear = value == twoDigits;
            value += centuryStartYear / 100 * 100 + (value < twoDigits ? 100 : 0);
        }
        return assign(e.letter, value, lenient);
    }

    bool assign(char letter, long value, bool lenient) pure nothrow @nogc
    {
        switch (letter)
        {
        case 'y':
        case 'Y':
            record(Calendar.YEAR, value);
            return true;
        case 'M':
        case 'L':
            record(Calendar.MONTH, value - 1);
            return true;
        case 'k':
        case 'h':
            return clockHour(letter, value, lenient);
        case 'u':
            record(Calendar.DAY_OF_WEEK, value == 7 ? Calendar.SUNDAY : value + 1);
            return true;
        case 'F':
        case 'W':
            return true; // read, but the day of the month decides
        default:
            record(numericFields[letterIndex(letter)], value);
            return true;
        }
    }

    // 'k' (1 to 24) and 'h' (1 to 12): the top hour is hour 0; a strict format rejects anything outside the range.
    bool clockHour(char letter, long value, bool lenient) pure nothrow @nogc
    {
        const top = letter == 'k' ? 24 : 12;
        if (!lenient && (value < 1 || value > top))
            return false;
        record(letter == 'k' ? Calendar.HOUR_OF_DAY : Calendar.HOUR, value == top ? 0 : value);
        return true;
    }

    // The longest name that matches, ignoring case; `full` names are tried before `terse` ones.
    bool named(const string[] full, const string[] terse, int field, int base) pure nothrow @nogc
    {
        foreach (round; 0 .. 2)
        {
            const names = round == 0 ? full : terse;
            size_t best, bestLength;
            foreach (i, name; names)
                if (name.length > bestLength && startsWithIgnoringCase(text[pos .. $], name))
                {
                    best = i;
                    bestLength = name.length;
                }
            if (bestLength)
            {
                record(field, best + base);
                pos += bestLength;
                return true;
            }
        }
        return false;
    }

    // 'z' and 'Z': "GMT" with an optional offset, an RFC 822 offset ("-0800"), or an English zone name.
    bool zoneText() pure nothrow @nogc
    {
        if (startsWithIgnoringCase(text[pos .. $], "GMT"))
        {
            pos += 3;
            if (pos < text.length && (text[pos] == '+' || text[pos] == '-'))
                return gmtOffset();
            return setOffset(false, 0, 0);
        }
        if (pos < text.length && (text[pos] == '+' || text[pos] == '-'))
            return numericZone(4);
        foreach (name; zoneNames)
            if (startsWithIgnoringCase(text[pos .. $], name))
            {
                pos += name.length;
                return setOffset(false, 0, 0);
            }
        return false;
    }

    // After "GMT": a sign, one or two hour digits, then optionally ":mm", or two more digits after two hour digits.
    bool gmtOffset() pure nothrow @nogc
    {
        const negative = text[pos++] == '-';
        const start = pos;
        while (pos < text.length && pos - start < 2 && text[pos] >= '0' && text[pos] <= '9')
            ++pos;
        const hours = digitValue(text[start .. pos]);
        const colon = pos < text.length && text[pos] == ':';
        const minutes = colon || pos - start == 2 ? twoDigitsAt(text, colon ? pos + 1 : pos) : -1;
        if (colon && minutes < 0)
            return false;
        if (minutes >= 0)
            pos += colon ? 3 : 2;
        return setOffset(negative, hours, minutes < 0 ? 0 : minutes);
    }

    // A sign and two hour digits, then: nothing (`form` 1), two minute digits (4), an optional colon and two minute
    // digits (2), or a colon and two minute digits (3).
    bool numericZone(int form) pure nothrow @nogc
    {
        const negative = text[pos] == '-';
        size_t i = pos + 1;
        const hours = twoDigitsAt(text, i);
        i += 2;
        const colon = form != 1 && i < text.length && text[i] == ':';
        if (hours < 0 || (form == 3 && !colon) || (form == 4 && colon))
            return false;
        int minutes;
        if (form != 1)
        {
            i += colon ? 1 : 0;
            minutes = twoDigitsAt(text, i);
            i += 2;
        }
        if (!setOffset(negative, hours, minutes))
            return false;
        pos = i;
        return true;
    }

    bool setOffset(bool negative, int hours, int minutes) pure nothrow @nogc
    {
        if (hours < 0 || minutes < 0 || hours > 23 || minutes > 59)
            return false;
        record(Calendar.ZONE_OFFSET, (negative ? -1 : 1) * (hours * 60 + minutes) * 60_000);
        record(Calendar.DST_OFFSET, 0);
        return true;
    }

    // 'X': "Z", or "+HH" (X), "+HHMM" or "+HH:MM" (XX accepts either), "+HH:MM" (XXX).
    bool isoZone(int count) pure nothrow @nogc
    {
        if (pos < text.length && text[pos] == 'Z')
        {
            ++pos;
            return setOffset(false, 0, 0);
        }
        if (pos >= text.length || (text[pos] != '+' && text[pos] != '-'))
            return false;
        return numericZone(count == 2 ? 2 : count);
    }
}

// The value of one or more ASCII digits; -1 for anything else.
private int digitValue(scope const(char)[] text) pure nothrow @nogc
{
    int value;
    foreach (c; text)
    {
        if (c < '0' || c > '9')
            return -1;
        value = value * 10 + (c - '0');
    }
    return text.length ? value : -1;
}

// The two digits at `i` as a number; -1 when there are not two digits there.
private int twoDigitsAt(scope const(char)[] text, size_t i) pure nothrow @nogc
{
    return i + 1 < text.length ? digitValue(text[i .. i + 2]) : -1;
}

private bool startsWithIgnoringCase(scope const(char)[] text, string prefix) pure nothrow @nogc
{
    if (text.length < prefix.length)
        return false;
    foreach (i, c; prefix)
        if (lower(text[i]) != lower(c))
            return false;
    return true;
}

private char lower(char c) pure nothrow @nogc
{
    return c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
}
