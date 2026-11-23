/++
Java's `java.time.format`: `DateTimeFormatter`, its ISO constants and `ofPattern`, and `DateTimeParseException`.

Written clean-room from the Java SE 21 API specification of `DateTimeFormatter` and `DateTimeFormatterBuilder`.
A formatter is a list of printer-parser elements, as the specification describes: numeric fields with a width and
sign style, fractions, literals, text, offsets, zone IDs, the instant, and optional sections. English text only;
`Locale` arguments are not supported yet.

`Fields` stands in for `TemporalAccessor`: the erased set of fields one value supplies to a formatter, or one parse
produces.
+/
module flint.java.time.format;

import flint.java.lang : IllegalArgumentException;
import flint.java.time : DateTimeException, Duration, Instant, LocalDate, LocalDateTime, LocalTime,
    OffsetDateTime, ZoneId, ZoneOffset, ZonedDateTime, checkRange;

@safe:

/// An error that occurred while parsing: the text and the index of the error are kept.
class DateTimeParseException : DateTimeException
{
    private string parsedString_;
    private int errorIndex_;

    ///
    this(string message, string parsedData, int errorIndex, Throwable cause = null,
            string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
        parsedString_ = parsedData;
        errorIndex_ = errorIndex;
    }

    /// The text that was being parsed.
    string getParsedString() const pure nothrow @nogc
    {
        return parsedString_;
    }

    /// The index in the text where the error was found.
    int getErrorIndex() const pure nothrow @nogc
    {
        return errorIndex_;
    }
}

/// Styles of handling signs when printing and parsing numbers.
enum SignStyle
{
    /// A sign for negative values only; a sign is rejected when parsing a positive value strictly.
    NORMAL,
    /// Always a sign.
    ALWAYS,
    /// Never a sign: the absolute value.
    NEVER,
    /// Rejects negative values.
    NOT_NEGATIVE,
    /// A sign for negative values, and '+' when the value exceeds the minimum width.
    EXCEEDS_PAD,
}

private enum Field : ubyte
{
    year,
    yearOfEra,
    monthOfYear,
    dayOfMonth,
    dayOfYear,
    dayOfWeek,
    hourOfDay,
    clockHourOfAmPm,
    minuteOfHour,
    secondOfMinute,
    nanoOfSecond,
    amPmOfDay,
    instantSeconds,
}

private enum fieldCount = Field.max + 1;

private immutable string[fieldCount] fieldNames = [
    "Year", "YearOfEra", "MonthOfYear", "DayOfMonth", "DayOfYear", "DayOfWeek", "HourOfDay",
    "ClockHourOfAmPm", "MinuteOfHour", "SecondOfMinute", "NanoOfSecond", "AmPmOfDay", "InstantSeconds"
];

/**
 * The fields of a temporal value, as Java's `TemporalAccessor` supplies them to a formatter, or as a parse
 * produces them before they are resolved into a value.
 */
struct Fields
{
    private enum Kind : ubyte
    {
        parsed,
        date,
        time,
        dateTime,
        offsetDateTime,
        zonedDateTime,
        instant,
    }

    private Kind kind_;
    private long[fieldCount] values_;
    private uint present_;
    private bool hasOffset_;
    private int offsetSeconds_;
    private string zoneId_;
    private bool zoneIsRegion_;

    private void set(Field f, long value) pure nothrow @nogc
    {
        values_[f] = value;
        present_ |= 1u << f;
    }

    private bool has(Field f) const pure nothrow @nogc
    {
        return (present_ & (1u << f)) != 0;
    }

    private void addDate(LocalDate d) pure nothrow @nogc
    {
        set(Field.year, d.getYear());
        set(Field.yearOfEra, d.getYear() >= 1 ? d.getYear() : 1 - cast(long) d.getYear());
        set(Field.monthOfYear, d.getMonthValue());
        set(Field.dayOfMonth, d.getDayOfMonth());
        set(Field.dayOfYear, d.getDayOfYear());
        set(Field.dayOfWeek, d.getDayOfWeek() + 1);
    }

    private void addTime(LocalTime t) pure nothrow @nogc
    {
        set(Field.hourOfDay, t.getHour());
        set(Field.clockHourOfAmPm, t.getHour() % 12 == 0 ? 12 : t.getHour() % 12);
        set(Field.minuteOfHour, t.getMinute());
        set(Field.secondOfMinute, t.getSecond());
        set(Field.nanoOfSecond, t.getNano());
        set(Field.amPmOfDay, t.getHour() / 12);
    }

    private void addOffset(LocalDateTime dateTime, ZoneOffset offset) pure nothrow @nogc
    {
        hasOffset_ = true;
        offsetSeconds_ = offset.getTotalSeconds();
        set(Field.instantSeconds, dateTime.toEpochSecond(offset));
    }

    /// The fields of a date.
    static Fields of(LocalDate value) pure nothrow @nogc
    {
        Fields f;
        f.kind_ = Kind.date;
        f.addDate(value);
        return f;
    }

    /// The fields of a time.
    static Fields of(LocalTime value) pure nothrow @nogc
    {
        Fields f;
        f.kind_ = Kind.time;
        f.addTime(value);
        return f;
    }

    /// The fields of a date-time.
    static Fields of(LocalDateTime value) pure nothrow @nogc
    {
        Fields f;
        f.kind_ = Kind.dateTime;
        f.addDate(value.toLocalDate());
        f.addTime(value.toLocalTime());
        return f;
    }

    /// The fields of a date-time with an offset, the instant included.
    static Fields of(OffsetDateTime value) pure nothrow @nogc
    {
        auto f = of(value.toLocalDateTime());
        f.kind_ = Kind.offsetDateTime;
        f.addOffset(value.toLocalDateTime(), value.getOffset());
        return f;
    }

    /// The fields of a date-time with a zone, the instant and zone ID included.
    static Fields of(ZonedDateTime value) pure nothrow @nogc
    {
        auto f = of(value.toLocalDateTime());
        f.kind_ = Kind.zonedDateTime;
        f.addOffset(value.toLocalDateTime(), value.getOffset());
        f.zoneId_ = value.getZone().getId();
        f.zoneIsRegion_ = !value.getZone().isOffset();
        return f;
    }

    /// The fields of an instant: the instant seconds and the nano-of-second only.
    static Fields of(Instant value) pure nothrow @nogc
    {
        Fields f;
        f.kind_ = Kind.instant;
        f.set(Field.instantSeconds, value.getEpochSecond());
        f.set(Field.nanoOfSecond, value.getNano());
        return f;
    }

    /// The zone ID that was parsed or supplied; empty when none.
    string zoneId() const pure nothrow @nogc
    {
        return zoneId_;
    }

    /// Whether an offset was parsed or supplied.
    bool hasOffset() const pure nothrow @nogc
    {
        return hasOffset_;
    }

    private DateTimeParseException unresolved(string text, string type) const
    {
        return new DateTimeParseException("Text '" ~ text ~ "' could not be parsed: Unable to obtain "
                ~ type ~ " from TemporalAccessor: " ~ describe() ~ " of type java.time.format.Parsed", text, 0);
    }

    private bool hasDate() const pure nothrow @nogc
    {
        return (has(Field.year) || has(Field.yearOfEra)) && ((has(Field.monthOfYear)
                && has(Field.dayOfMonth)) || has(Field.dayOfYear));
    }

    private bool hasTime() const pure nothrow @nogc
    {
        return has(Field.hourOfDay) || (has(Field.clockHourOfAmPm) && has(Field.amPmOfDay));
    }

    /// The value these fields came from, as its `toString`; for parsed fields, Java's `Parsed` description.
    string describe() const
    {
        final switch (kind_)
        {
        case Kind.date:
            return toLocalDate("").toString();
        case Kind.time:
            return toLocalTime("").toString();
        case Kind.dateTime:
            return toLocalDate("").toString() ~ "T" ~ toLocalTime("").toString();
        case Kind.offsetDateTime:
            return toLocalDate("").toString() ~ "T" ~ toLocalTime("")
                .toString() ~ toOffset("").toString();
        case Kind.zonedDateTime:
            return describeZoned();
        case Kind.instant:
            return Instant.ofEpochSecond(values_[Field.instantSeconds],
                    values_[Field.nanoOfSecond]).toString();
        case Kind.parsed:
            return describeParsed();
        }
    }

    private string describeZoned() const
    {
        const zoned = toLocalDate("").toString() ~ "T" ~ toLocalTime("").toString() ~ toOffset("").toString();
        return zoneIsRegion_ ? zoned ~ "[" ~ zoneId_ ~ "]" : zoned;
    }

    // Java's `Parsed.toString`: the unresolved fields, the chronology, the zone and what was resolved.
    private string describeParsed() const
    {
        import std.conv : to;

        auto text = "{" ~ (hasOffset_ ? "OffsetSeconds=" ~ offsetSeconds_.to!string : "") ~ "},ISO";
        if (zoneId_.length)
            text ~= "," ~ zoneId_;
        const date = hasDate(), time = hasTime();
        if (date || time)
            text ~= " resolved to ";
        if (date)
            text ~= toLocalDate("").toString() ~ (time ? "T" : "");
        if (time)
            text ~= toLocalTime("").toString();
        return text;
    }

    /// Resolves the date fields into a `LocalDate`; throws `DateTimeParseException` when they are missing or invalid.
    LocalDate toLocalDate(string text, string type = "LocalDate") const
    {
        import std.conv : to;

        long year;
        if (has(Field.year))
            year = values_[Field.year];
        else if (has(Field.yearOfEra))
            year = values_[Field.yearOfEra];
        else
            throw unresolved(text, type);
        try
        {
            checkRange("Year", year, -999_999_999, 999_999_999);
            LocalDate date;
            if (has(Field.monthOfYear) && has(Field.dayOfMonth))
            {
                checkRange("MonthOfYear", values_[Field.monthOfYear], 1, 12);
                checkRange("DayOfMonth", values_[Field.dayOfMonth], 1, 31);
                date = LocalDate.of(cast(int) year, cast(int) values_[Field.monthOfYear],
                        cast(int) values_[Field.dayOfMonth]);
            }
            else if (has(Field.dayOfYear))
            {
                checkRange("DayOfYear", values_[Field.dayOfYear], 1, 366);
                date = LocalDate.ofYearDay(cast(int) year, cast(int) values_[Field.dayOfYear]);
            }
            else
                throw unresolved(text, type);
            if (has(Field.dayOfWeek) && date.getDayOfWeek() + 1 != values_[Field.dayOfWeek])
                throw new DateTimeException("Conflict found: Field DayOfWeek " ~ (date.getDayOfWeek() + 1)
                        .to!string ~ " differs from DayOfWeek "
                        ~ values_[Field.dayOfWeek].to!string ~ " derived from " ~ date.toString());
            return date;
        }
        catch (DateTimeParseException e)
            throw e;
        catch (DateTimeException e)
            throw new DateTimeParseException("Text '" ~ text ~ "' could not be parsed: " ~ e.msg, text, 0, e);
    }

    /// Resolves the time fields into a `LocalTime`; missing minutes, seconds and nanos are zero.
    LocalTime toLocalTime(string text, string type = "LocalTime") const
    {
        try
        {
            long hour;
            if (has(Field.hourOfDay))
                hour = values_[Field.hourOfDay];
            else if (has(Field.clockHourOfAmPm) && has(Field.amPmOfDay))
            {
                checkRange("ClockHourOfAmPm", values_[Field.clockHourOfAmPm], 1, 12);
                hour = values_[Field.clockHourOfAmPm] % 12 + 12 * values_[Field.amPmOfDay];
            }
            else
                throw unresolved(text, type);
            checkRange("HourOfDay", hour, 0, 23);
            const minute = has(Field.minuteOfHour) ? values_[Field.minuteOfHour] : 0;
            const second = has(Field.secondOfMinute) ? values_[Field.secondOfMinute] : 0;
            const nano = has(Field.nanoOfSecond) ? values_[Field.nanoOfSecond] : 0;
            checkRange("MinuteOfHour", minute, 0, 59);
            checkRange("SecondOfMinute", second, 0, 59);
            return LocalTime.of(cast(int) hour, cast(int) minute, cast(int) second, cast(int) nano);
        }
        catch (DateTimeParseException e)
            throw e;
        catch (DateTimeException e)
            throw new DateTimeParseException("Text '" ~ text ~ "' could not be parsed: " ~ e.msg, text, 0, e);
    }

    /// The parsed offset; throws `DateTimeParseException` when none was parsed.
    ZoneOffset toOffset(string text, string type = "ZoneOffset") const
    {
        if (!hasOffset_)
            throw unresolved(text, type);
        try
            return ZoneOffset.ofTotalSeconds(offsetSeconds_);
        catch (DateTimeException e)
            throw new DateTimeParseException("Text '" ~ text ~ "' could not be parsed: " ~ e.msg, text, 0, e);
    }
}

private enum Op : ubyte
{
    number,
    reducedYear,
    fraction,
    literal,
    text,
    offset,
    zoneId,
    zoneRegion,
    instant,
    // Control elements: everything from here on prints nothing.
    optionalStart,
    optionalEnd,
    caseInsensitive,
    caseSensitive,
}

private struct Element
{
    Op op;
    Field field;
    ubyte minWidth;
    ubyte maxWidth;
    SignStyle sign;
    string text; // literal text, offset pattern, or "full"/"short" for text
    string noOffsetText;
    bool lenient;
}

private Element num(Field f, int min, int max = 0, SignStyle sign = SignStyle.NOT_NEGATIVE) pure nothrow @nogc
{
    return Element(Op.number, f, cast(ubyte) min, cast(ubyte)(max ? max : min), sign);
}

private Element lit(string text) pure nothrow @nogc
{
    Element e;
    e.op = Op.literal;
    e.text = text;
    return e;
}

private Element op(Op o) pure nothrow @nogc
{
    Element e;
    e.op = o;
    return e;
}

private Element offsetElement(string pattern, string noOffsetText, bool lenient) pure nothrow @nogc
{
    Element e;
    e.op = Op.offset;
    e.text = pattern;
    e.noOffsetText = noOffsetText;
    e.lenient = lenient;
    return e;
}

private Element fraction(int min, int max, bool decimalPoint) pure nothrow @nogc
{
    Element e;
    e.op = Op.fraction;
    e.field = Field.nanoOfSecond;
    e.minWidth = cast(ubyte) min;
    e.maxWidth = cast(ubyte) max;
    e.lenient = decimalPoint;
    return e;
}

private immutable Element[] isoLocalDate = [
    num(Field.year, 4, 10, SignStyle.EXCEEDS_PAD), lit("-"), num(Field.monthOfYear, 2), lit("-"),
    num(Field.dayOfMonth, 2)
];
private immutable Element[] isoLocalTime = [
    num(Field.hourOfDay, 2), lit(":"), num(Field.minuteOfHour, 2), op(Op.optionalStart), lit(":"),
    num(Field.secondOfMinute, 2), op(Op.optionalStart), fraction(0, 9, true), op(Op.optionalEnd),
    op(Op.optionalEnd)
];
private immutable Element[] isoLocalDateTime = [op(Op.caseInsensitive)] ~ isoLocalDate ~ [lit("T")] ~ isoLocalTime;
private immutable Element isoOffset = offsetElement("+HH:MM:ss", "Z", true);
private immutable Element[] isoOffsetDateTime = isoLocalDateTime ~ [isoOffset];
private immutable Element[] isoZonedDateTime = isoOffsetDateTime ~ [
    op(Op.optionalStart), lit("["), op(Op.caseSensitive), op(Op.zoneRegion), lit("]"),
    op(Op.optionalEnd)
];
private immutable Element[] isoDateTime = isoLocalDateTime ~ [
    op(Op.optionalStart), isoOffset, op(Op.optionalStart), lit("["), op(Op.caseSensitive),
    op(Op.zoneRegion), lit("]"), op(Op.optionalEnd), op(Op.optionalEnd)
];
private immutable Element[] isoDate = [op(Op.caseInsensitive)] ~ isoLocalDate ~ [
    op(Op.optionalStart), isoOffset, op(Op.optionalEnd)
];
private immutable Element[] isoTime = [op(Op.caseInsensitive)] ~ isoLocalTime ~ [
    op(Op.optionalStart), isoOffset, op(Op.optionalEnd)
];
private immutable Element[] isoInstant = [op(Op.caseInsensitive), op(Op.instant)];
private immutable Element[] basicIsoDate = [
    op(Op.caseInsensitive), num(Field.year, 4), num(Field.monthOfYear, 2), num(Field.dayOfMonth,
            2), op(Op.optionalStart), offsetElement("+HHMMss", "Z", true), op(Op.optionalEnd)
];
// What the instant element parses: an ISO local date-time with seconds, and an offset.
private immutable Element[] instantParse = [op(Op.caseInsensitive)] ~ isoLocalDate ~ [
    lit("T"), num(Field.hourOfDay, 2), lit(":"), num(Field.minuteOfHour, 2), lit(":"),
    num(Field.secondOfMinute, 2), fraction(0, 9, true), isoOffset
];

/++
Formatter for printing and parsing date-time objects. Java's `DateTimeFormatter` is an immutable final class;
Flint's is an immutable value (ADR-030, R11), so the ISO constants are `static immutable` values.
+/
struct DateTimeFormatter
{
    private immutable(Element)[] elements_;
    private string description_;
    private bool hasZone_;
    private ZoneId zone_;

    /// The ISO date formatter that formats or parses a date without an offset, such as '2011-12-03'.
    static immutable DateTimeFormatter ISO_LOCAL_DATE = DateTimeFormatter(isoLocalDate, "ISO_LOCAL_DATE");
    /// The ISO time formatter that formats or parses a time without an offset, such as '10:15' or '10:15:30'.
    static immutable DateTimeFormatter ISO_LOCAL_TIME = DateTimeFormatter(isoLocalTime, "ISO_LOCAL_TIME");
    /// The ISO date-time formatter without an offset, such as '2011-12-03T10:15:30'.
    static immutable DateTimeFormatter ISO_LOCAL_DATE_TIME = DateTimeFormatter(isoLocalDateTime, "ISO_LOCAL_DATE_TIME");
    /// The ISO date-time formatter with an offset, such as '2011-12-03T10:15:30+01:00'.
    static immutable DateTimeFormatter ISO_OFFSET_DATE_TIME = DateTimeFormatter(isoOffsetDateTime,
            "ISO_OFFSET_DATE_TIME");
    /// The ISO-like date-time formatter with an offset and a bracketed region zone, such as
    /// '2011-12-03T10:15:30+01:00[Europe/Paris]'.
    static immutable DateTimeFormatter ISO_ZONED_DATE_TIME = DateTimeFormatter(isoZonedDateTime, "ISO_ZONED_DATE_TIME");
    /// The ISO-like date-time formatter with the offset and zone if available.
    static immutable DateTimeFormatter ISO_DATE_TIME = DateTimeFormatter(isoDateTime, "ISO_DATE_TIME");
    /// The ISO date formatter with the offset if available, such as '2011-12-03' or '2011-12-03+01:00'.
    static immutable DateTimeFormatter ISO_DATE = DateTimeFormatter(isoDate, "ISO_DATE");
    /// The ISO time formatter with the offset if available, such as '10:15:30' or '10:15:30+01:00'.
    static immutable DateTimeFormatter ISO_TIME = DateTimeFormatter(isoTime, "ISO_TIME");
    /// The ISO instant formatter in UTC, such as '2011-12-03T10:15:30Z'.
    static immutable DateTimeFormatter ISO_INSTANT = DateTimeFormatter(isoInstant, "ISO_INSTANT");
    /// The ISO date formatter without punctuation, such as '20111203'.
    static immutable DateTimeFormatter BASIC_ISO_DATE = DateTimeFormatter(basicIsoDate, "BASIC_ISO_DATE");

    private this(immutable(Element)[] elements, string description) pure nothrow @nogc
    {
        elements_ = elements;
        description_ = description;
    }

    /**
     * Creates a formatter using the specified pattern, as `DateTimeFormatterBuilder.appendPattern` describes:
     * `u y D M d E a h H m s S n VV X x Z`, quoted text, `''` and `[ ]` optional sections. Other pattern letters
     * throw `IllegalArgumentException`.
     */
    static DateTimeFormatter ofPattern(string pattern)
    {
        return DateTimeFormatter(compilePattern(pattern).idup, pattern);
    }

    /// A copy of this formatter that converts an instant to a date-time in `zone` before formatting.
    DateTimeFormatter withZone(ZoneId zone) const pure nothrow @nogc
    {
        DateTimeFormatter copy = DateTimeFormatter(elements_, description_);
        copy.hasZone_ = true;
        copy.zone_ = zone;
        return copy;
    }

    /// Formats the fields of a temporal value.
    string format(Fields fields) const
    {
        if (hasZone_ && fields.has(Field.instantSeconds) && !fields.has(Field.year))
            fields = zoned(fields);
        auto printer = Printer(fields);
        printer.run(elements_);
        return printer.output;
    }

    /// Formats a date-time object: `LocalDate`, `LocalTime`, `LocalDateTime`, `OffsetDateTime`, `ZonedDateTime`
    /// or `Instant`.
    string format(T)(const T temporal) const if (!is(T == Fields))
    {
        return format(Fields.of(temporal));
    }

    private Fields zoned(Fields fields) const
    {
        const instant = Instant.ofEpochSecond(fields.values_[Field.instantSeconds], fields.values_[Field.nanoOfSecond]);
        return Fields.of(instant.atZone(zone_));
    }

    /// Parses the text into fields; throws `DateTimeParseException` with the error index when it does not match.
    Fields parse(string text) const
    {
        auto parser = Parser(text);
        const end = parser.run(elements_, 0);
        if (end < 0)
            throw new DateTimeParseException("Text '" ~ text ~ "' could not be parsed at index " ~ indexText(~end),
                    text, ~end);
        if (end != text.length)
            throw new DateTimeParseException(
                    "Text '" ~ text ~ "' could not be parsed, unparsed text found at index " ~ indexText(end),
                    text, end);
        return parser.fields;
    }

    /// The pattern or the name of the ISO constant.
    string toString() const pure nothrow @nogc
    {
        return description_;
    }
}

private string indexText(int index) pure nothrow
{
    import std.conv : to;

    return index.to!string;
}

private string padded(long value, int width) pure nothrow
{
    import std.conv : to;

    auto digits = value.to!string;
    while (digits.length < width)
        digits = "0" ~ digits;
    return digits;
}

private struct Printer
{
    Fields fields;
    string output;
    bool caseInsensitive;

    // Prints the elements; returns false when a field is missing in an optional section.
    bool run(scope const(Element)[] elements, bool optional = false)
    {
        for (size_t i = 0; i < elements.length; ++i)
        {
            const e = elements[i];
            if (e.op == Op.optionalStart)
            {
                const end = sectionEnd(elements, i);
                const mark = output.length;
                if (!run(elements[i + 1 .. end], true))
                    output = output[0 .. mark];
                i = end;
                continue;
            }
            if (!print(e))
            {
                if (optional)
                    return false;
                if (e.op == Op.zoneId)
                    throw new DateTimeException("Unable to extract ZoneId from temporal " ~ fields.describe());
                throw new DateTimeException("Unsupported field: " ~ missingField(e));
            }
        }
        return true;
    }

    string missingField(const Element e) const pure nothrow @nogc
    {
        switch (e.op)
        {
        case Op.offset:
            return "OffsetSeconds";
        case Op.zoneId:
        case Op.zoneRegion:
            return "ZoneId";
        case Op.instant:
            return "InstantSeconds";
        default:
            return fieldNames[e.field];
        }
    }

    bool print(const Element e)
    {
        if (e.op >= Op.optionalStart)
            return true;
        switch (e.op)
        {
        case Op.number:
            return printNumber(e);
        case Op.reducedYear:
            return printReducedYear(e);
        case Op.fraction:
            return printFraction(e);
        case Op.literal:
            output ~= e.text;
            return true;
        case Op.text:
            return printText(e);
        case Op.offset:
            return printOffset(e);
        case Op.zoneId:
        case Op.zoneRegion:
            return printZone(e.op == Op.zoneRegion);
        default:
            return printInstant();
        }
    }

    bool printReducedYear(const Element e)
    {
        if (!fields.has(e.field))
            return false;
        output ~= padded(((fields.values_[e.field] % 100) + 100) % 100, 2);
        return true;
    }

    bool printZone(bool regionOnly)
    {
        if (fields.zoneId_.length == 0 || (regionOnly && !fields.zoneIsRegion_))
            return false;
        output ~= fields.zoneId_;
        return true;
    }

    bool printNumber(const Element e)
    {
        import std.conv : to;

        if (!fields.has(e.field))
            return false;
        const value = fields.values_[e.field];
        const magnitude = value < 0 ? -value : value;
        auto digits = padded(magnitude, e.minWidth);
        if (digits.length > e.maxWidth)
            throw new DateTimeException("Field " ~ fieldNames[e.field] ~ " cannot be printed as the value "
                    ~ value.to!string ~ " exceeds the maximum print width of " ~ (cast(int) e.maxWidth).to!string);
        final switch (e.sign)
        {
        case SignStyle.EXCEEDS_PAD:
            if (value < 0)
                output ~= "-";
            else if (e.minWidth < 19 && value >= tenPow(e.minWidth))
                output ~= "+";
            break;
        case SignStyle.ALWAYS:
            output ~= value < 0 ? "-" : "+";
            break;
        case SignStyle.NORMAL:
            if (value < 0)
                output ~= "-";
            break;
        case SignStyle.NOT_NEGATIVE:
            if (value < 0)
                throw new DateTimeException("Field " ~ fieldNames[e.field]
                        ~ " cannot be printed as the value " ~ value.to!string
                        ~ " cannot be negative according to the SignStyle");
            break;
        case SignStyle.NEVER:
            break;
        }
        output ~= digits;
        return true;
    }

    bool printFraction(const Element e)
    {
        if (!fields.has(Field.nanoOfSecond))
            return false;
        auto digits = padded(fields.values_[Field.nanoOfSecond], 9)[0 .. e.maxWidth];
        while (digits.length > e.minWidth && digits[$ - 1] == '0')
            digits = digits[0 .. $ - 1];
        if (digits.length == 0)
            return true;
        if (e.lenient)
            output ~= ".";
        output ~= digits;
        return true;
    }

    bool printText(const Element e)
    {
        if (!fields.has(e.field))
            return false;
        const value = cast(size_t) fields.values_[e.field];
        const full = e.text == "full";
        switch (e.field)
        {
        case Field.monthOfYear:
            output ~= full ? monthFull[value - 1] : monthFull[value - 1][0 .. 3];
            break;
        case Field.dayOfWeek:
            output ~= full ? dayFull[value - 1] : dayFull[value - 1][0 .. 3];
            break;
        default:
            output ~= value == 0 ? "AM" : "PM";
            break;
        }
        return true;
    }

    bool printOffset(const Element e)
    {
        if (!fields.hasOffset_)
            return false;
        output ~= formatOffset(fields.offsetSeconds_, e.text, e.noOffsetText);
        return true;
    }

    bool printInstant()
    {
        if (!fields.has(Field.instantSeconds))
            return false;
        const nano = fields.has(Field.nanoOfSecond) ? fields.values_[Field.nanoOfSecond] : 0;
        output ~= Instant.ofEpochSecond(fields.values_[Field.instantSeconds], nano).toString();
        return true;
    }
}

private long tenPow(int n) pure nothrow @nogc
{
    long p = 1;
    foreach (_; 0 .. n)
        p *= 10;
    return p;
}

private immutable string[12] monthFull = [
    "January", "February", "March", "April", "May", "June", "July", "August", "September",
    "October", "November", "December"
];
private immutable string[7] dayFull = [
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"
];

// The index of the optionalEnd matching the optionalStart at `start`, or the end of the list.
private size_t sectionEnd(scope const(Element)[] elements, size_t start) pure nothrow @nogc
{
    int depth;
    foreach (i; start .. elements.length)
    {
        if (elements[i].op == Op.optionalStart)
            ++depth;
        else if (elements[i].op == Op.optionalEnd && --depth == 0)
            return i;
    }
    return elements.length;
}

private struct OffsetShape
{
    bool minutes;
    bool minutesOptional;
    bool seconds;
    bool secondsOptional;
    bool colon;
}

// "+HH", "+HHmm", "+HH:mm", "+HHMM", "+HH:MM", "+HHMMss", "+HH:MM:ss", "+HHMMSS", "+HH:MM:SS".
private OffsetShape offsetShape(string pattern) pure nothrow @nogc
{
    OffsetShape shape;
    shape.colon = pattern.length > 3 && pattern[3] == ':';
    const rest = pattern.length > 3 ? pattern[shape.colon ? 4 : 3 .. $] : "";
    shape.minutes = rest.length >= 2;
    shape.minutesOptional = shape.minutes && rest[0] == 'm';
    const tail = rest.length > 2 ? rest[shape.colon ? 3 : 2 .. $] : "";
    shape.seconds = tail.length >= 2;
    shape.secondsOptional = shape.seconds && tail[0] == 's';
    return shape;
}

private string formatOffset(int totalSeconds, string pattern, string noOffsetText) pure nothrow
{
    if (totalSeconds == 0)
        return noOffsetText;
    const shape = offsetShape(pattern);
    const total = totalSeconds < 0 ? -totalSeconds : totalSeconds;
    const hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60;
    auto text = (totalSeconds < 0 ? "-" : "+") ~ padded(hours, 2);
    const separator = shape.colon ? ":" : "";
    const printMinutes = shape.minutes && (!shape.minutesOptional || minutes != 0 || seconds != 0);
    if (printMinutes)
        text ~= separator ~ padded(minutes, 2);
    if (printMinutes && shape.seconds && (!shape.secondsOptional || seconds != 0))
        text ~= separator ~ padded(seconds, 2);
    return text;
}

private struct Parser
{
    string text;
    Fields fields;
    bool caseInsensitive;

    // Parses the elements from `position`; returns the end position, or `~errorIndex` on failure.
    int run(scope const(Element)[] elements, int position)
    {
        for (size_t i = 0; i < elements.length; ++i)
        {
            const e = elements[i];
            if (e.op == Op.optionalStart)
            {
                const end = sectionEnd(elements, i);
                const saved = fields;
                const savedCase = caseInsensitive;
                const next = run(elements[i + 1 .. end], position);
                if (next < 0)
                {
                    fields = saved;
                    caseInsensitive = savedCase;
                }
                else
                    position = next;
                i = end;
                continue;
            }
            position = parseOne(e, elements[i + 1 .. $], position);
            if (position < 0)
                return position;
        }
        return position;
    }

    int control(const Element e, int position) pure nothrow @nogc
    {
        if (e.op == Op.caseInsensitive)
            caseInsensitive = true;
        else if (e.op == Op.caseSensitive)
            caseInsensitive = false;
        return position;
    }

    int parseOne(const Element e, scope const(Element)[] following, int position)
    {
        if (e.op >= Op.optionalStart)
            return control(e, position);
        switch (e.op)
        {
        case Op.number:
            return parseNumber(e, following, position);
        case Op.reducedYear:
            return parseReducedYear(e, position);
        case Op.fraction:
            return parseFraction(e, position);
        case Op.literal:
            return parseLiteral(e.text, position);
        case Op.text:
            return parseText(e, position);
        case Op.offset:
            return parseOffset(e, position);
        case Op.zoneId:
        case Op.zoneRegion:
            return parseZone(position);
        default:
            return run(instantParse, position);
        }
    }

    static bool digit(char c) pure nothrow @nogc
    {
        return c >= '0' && c <= '9';
    }

    // Digits reserved for the fixed-width numbers that directly follow (adjacent value parsing).
    static int reserved(scope const(Element)[] following) pure nothrow @nogc
    {
        int total;
        foreach (e; following)
        {
            if (e.op == Op.number || e.op == Op.reducedYear)
                total += e.op == Op.reducedYear ? 2 : e.minWidth;
            else if (e.op == Op.fraction && !e.lenient)
                total += e.minWidth;
            else
                break;
        }
        return total;
    }

    // The sign at `position`: 0 for none, 1 for '+', -1 for '-', or 2 when the sign style rejects it.
    int sign(const Element e, int position) const pure nothrow @nogc
    {
        const present = position < text.length && (text[position] == '+' || text[position] == '-');
        if (!present)
            return e.sign == SignStyle.ALWAYS ? 2 : 0;
        if (e.sign == SignStyle.NOT_NEGATIVE || e.sign == SignStyle.NEVER)
            return 2;
        return text[position] == '-' ? -1 : 1;
    }

    // EXCEEDS_PAD parsed strictly: '+' only for more digits than the minimum width, which then need a sign.
    static bool padSignMismatch(bool plus, bool signed, int digits, int minWidth) pure nothrow @nogc
    {
        return (plus && digits <= minWidth) || (!signed && digits > minWidth);
    }

    int parseNumber(const Element e, scope const(Element)[] following, int position)
    {
        const signValue = sign(e, position);
        if (signValue == 2)
            return ~position;
        const negative = signValue < 0, signed = signValue != 0;
        const pos = signed ? position + 1 : position;
        int available;
        while (pos + available < text.length && digit(text[pos + available]))
            ++available;
        int take = available - reserved(following);
        take = take > e.maxWidth ? e.maxWidth : take;
        if (take < e.minWidth)
            return ~pos;
        if (e.sign == SignStyle.EXCEEDS_PAD && padSignMismatch(signed && !negative, signed, take, e.minWidth))
            return ~position;
        long value;
        foreach (c; text[pos .. pos + take])
            value = value * 10 + (c - '0');
        fields.set(e.field, negative ? -value : value);
        return pos + take;
    }

    int parseReducedYear(const Element e, int position)
    {
        if (position + 2 > text.length || !digit(text[position]) || !digit(text[position + 1]))
            return ~position;
        fields.set(e.field, 2000 + (text[position] - '0') * 10 + (text[position + 1] - '0'));
        return position + 2;
    }

    int parseFraction(const Element e, int position)
    {
        int pos = position;
        if (e.lenient)
        {
            if (pos >= text.length || text[pos] != '.')
                return e.minWidth > 0 ? ~position : position;
            ++pos;
        }
        int count;
        long value;
        while (count < e.maxWidth && pos + count < text.length && digit(text[pos + count]))
        {
            value = value * 10 + (text[pos + count] - '0');
            ++count;
        }
        if (count < e.minWidth || (e.lenient && count == 0))
            return ~pos;
        fields.set(Field.nanoOfSecond, value * tenPow(9 - count));
        return pos + count;
    }

    bool matches(string expected, int position) const pure nothrow @nogc
    {
        if (position + expected.length > text.length)
            return false;
        foreach (i, c; expected)
        {
            const a = text[position + i];
            if (a != c && !(caseInsensitive && (a | 0x20) == (c | 0x20) && ((c | 0x20) >= 'a' && (c | 0x20) <= 'z')))
                return false;
        }
        return true;
    }

    int parseLiteral(string expected, int position) pure nothrow @nogc
    {
        return matches(expected, position) ? position + cast(int) expected.length : ~position;
    }

    int parseText(const Element e, int position)
    {
        const full = e.text == "full";
        static immutable string[2] amPm = ["AM", "PM"];
        const(string)[] names = e.field == Field.monthOfYear ? monthFull[] : e.field == Field.dayOfWeek
            ? dayFull[] : amPm[];
        foreach (i, name; names)
        {
            const candidate = full || e.field == Field.amPmOfDay ? name : name[0 .. 3];
            if (matches(candidate, position))
            {
                fields.set(e.field, e.field == Field.amPmOfDay ? cast(long) i : cast(long) i + 1);
                return position + cast(int) candidate.length;
            }
        }
        return ~position;
    }

    int twoDigits(int position) const pure nothrow @nogc
    {
        if (position + 2 > text.length || !digit(text[position]) || !digit(text[position + 1]))
            return -1;
        return (text[position] - '0') * 10 + (text[position + 1] - '0');
    }

    // One optional `[:]dd` group of an offset; returns the new position, unchanged when absent.
    int offsetGroup(int position, bool colon, ref int value) const pure nothrow @nogc
    {
        int pos = position;
        if (colon && (pos >= text.length || text[pos] != ':'))
            return position;
        if (colon)
            ++pos;
        const v = twoDigits(pos);
        if (v < 0)
            return position;
        value = v;
        return pos + 2;
    }

    int parseOffset(const Element e, int position)
    {
        if (e.noOffsetText.length && matches(e.noOffsetText, position))
        {
            fields.hasOffset_ = true;
            fields.offsetSeconds_ = 0;
            return position + cast(int) e.noOffsetText.length;
        }
        if (position >= text.length || (text[position] != '+' && text[position] != '-'))
            return ~position;
        const sign = text[position] == '-' ? -1 : 1;
        const hours = twoDigits(position + 1);
        if (hours < 0 || hours > 23)
            return ~position;
        int[2] parts;
        const end = offsetMinutesSeconds(e, position + 3, parts);
        if (end < 0 || parts[0] > 59 || parts[1] > 59)
            return ~position;
        fields.hasOffset_ = true;
        fields.offsetSeconds_ = sign * (hours * 3600 + parts[0] * 60 + parts[1]);
        return end;
    }

    // The minutes and seconds groups after an offset's hours; returns the end, or -1 when a required group is
    // missing.
    int offsetMinutesSeconds(const Element e, int pos, ref int[2] parts) const pure nothrow @nogc
    {
        const shape = offsetShape(e.text);
        if (!shape.minutes && !e.lenient)
            return pos;
        const next = offsetGroup(pos, shape.colon, parts[0]);
        if (next == pos)
            return shape.minutes && !shape.minutesOptional && !e.lenient ? -1 : pos;
        if (!shape.seconds && !e.lenient)
            return next;
        const after = offsetGroup(next, shape.colon, parts[1]);
        if (after == next && shape.seconds && !shape.secondsOptional && !e.lenient)
            return -1;
        return after;
    }

    int parseZone(int position)
    {
        int end = position;
        while (end < text.length && zoneChar(text[end]))
            ++end;
        if (end == position)
            return ~position;
        try
            fields.zoneId_ = ZoneId.of(text[position .. end]).getId();
        catch (DateTimeException)
            return ~position;
        fields.zoneIsRegion_ = !ZoneId.of(fields.zoneId_).isOffset();
        return end;
    }

    static bool zoneChar(char c) pure nothrow @nogc
    {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || digit(c) || c == '/' || c == '_'
            || c == '+' || c == '-' || c == '.' || c == '~' || c == ':';
    }
}

// Compiles an `ofPattern` pattern into elements.
private Element[] compilePattern(string pattern)
{
    Element[] elements;
    size_t i;
    int depth;
    while (i < pattern.length)
    {
        const c = pattern[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
        {
            size_t count = 1;
            while (i + count < pattern.length && pattern[i + count] == c)
                ++count;
            elements ~= letterElement(c, cast(int) count);
            i += count;
        }
        else if (c == '\'')
            i = quoted(pattern, i, elements);
        else if (c == '[')
        {
            ++depth;
            elements ~= op(Op.optionalStart);
            ++i;
        }
        else if (c == ']')
        {
            if (depth-- == 0)
                throw new IllegalArgumentException("Pattern invalid as it contains ] without previous [");
            elements ~= op(Op.optionalEnd);
            ++i;
        }
        else if (c == '{' || c == '}' || c == '#')
            throw new IllegalArgumentException("Pattern includes reserved character: '" ~ c ~ "'");
        else
        {
            elements ~= lit(pattern[i .. i + 1]);
            ++i;
        }
    }
    foreach (_; 0 .. depth)
        elements ~= op(Op.optionalEnd);
    return elements;
}

// A quoted literal starting at `start`; `''` is a single quote. Returns the index after the closing quote.
private size_t quoted(string pattern, size_t start, ref Element[] elements)
{
    if (start + 1 < pattern.length && pattern[start + 1] == '\'')
    {
        elements ~= lit("'");
        return start + 2;
    }
    string text;
    size_t i = start + 1;
    for (;;)
    {
        if (i >= pattern.length)
            throw new IllegalArgumentException("Pattern ends with an incomplete string literal: " ~ pattern);
        if (pattern[i] == '\'')
        {
            if (i + 1 < pattern.length && pattern[i + 1] == '\'')
            {
                text ~= '\'';
                i += 2;
                continue;
            }
            break;
        }
        text ~= pattern[i++];
    }
    if (text.length)
        elements ~= lit(text);
    return i + 1;
}

private Element textElement(Field f, int count) pure nothrow @nogc
{
    Element e;
    e.op = Op.text;
    e.field = f;
    e.text = count >= 4 ? "full" : "short";
    return e;
}

private Element yearElement(Field f, int count) pure nothrow @nogc
{
    if (count == 2)
    {
        Element e;
        e.op = Op.reducedYear;
        e.field = f;
        return e;
    }
    if (count < 4)
        return num(f, count, 19, SignStyle.NORMAL);
    return num(f, count, 19, SignStyle.EXCEEDS_PAD);
}

private Element twoWide(Field f, char c, int count, int maxWide = 2)
{
    if (count == 1)
        return num(f, 1, 19, SignStyle.NORMAL);
    if (count <= maxWide)
        return num(f, count);
    throw new IllegalArgumentException("Too many pattern letters: " ~ c);
}

private Element letterElement(char c, int count)
{
    static immutable string twoWideLetters = "dHhms";
    static immutable Field[5] twoWideFields = [
        Field.dayOfMonth, Field.hourOfDay, Field.clockHourOfAmPm, Field.minuteOfHour,
        Field.secondOfMinute
    ];
    foreach (i, letter; twoWideLetters)
        if (letter == c)
            return twoWide(twoWideFields[i], c, count);
    return dateLetter(c, count);
}

private Element dateLetter(char c, int count)
{
    switch (c)
    {
    case 'u':
        return yearElement(Field.year, count);
    case 'y':
        return yearElement(Field.yearOfEra, count);
    case 'M':
    case 'L':
        return count <= 2 ? twoWide(Field.monthOfYear, c, count) : textElement(Field.monthOfYear, count);
    case 'D':
        return count == 1 ? num(Field.dayOfYear, 1, 19, SignStyle.NORMAL) : twoWide(Field.dayOfYear, c, count, 3);
    case 'E':
        return textElement(Field.dayOfWeek, count);
    default:
        return timeLetter(c, count);
    }
}

private Element timeLetter(char c, int count)
{
    switch (c)
    {
    case 'a':
        if (count > 1)
            throw new IllegalArgumentException("Too many pattern letters: a");
        return textElement(Field.amPmOfDay, count);
    case 'S':
        if (count > 9)
            throw new IllegalArgumentException("Too many pattern letters: S");
        return fraction(count, count, false);
    case 'n':
        return num(Field.nanoOfSecond, count == 1 ? 1 : count, 19, SignStyle.NORMAL);
    default:
        return zoneLetter(c, count);
    }
}

private Element zoneLetter(char c, int count)
{
    static immutable string[5] xPatterns = ["+HHmm", "+HHMM", "+HH:MM", "+HHMMss", "+HH:MM:ss"];
    static immutable string[5] xZero = ["+00", "+0000", "+00:00", "+0000", "+00:00"];
    switch (c)
    {
    case 'V':
        if (count != 2)
            throw new IllegalArgumentException("Pattern letter count must be 2: V");
        return op(Op.zoneId);
    case 'X':
    case 'x':
        if (count > 5)
            throw new IllegalArgumentException("Too many pattern letters: " ~ c);
        return offsetElement(xPatterns[count - 1], c == 'X' ? "Z" : xZero[count - 1], false);
    case 'Z':
        if (count < 4)
            return offsetElement("+HHMM", "+0000", false);
        if (count == 5)
            return offsetElement("+HH:MM:ss", "Z", false);
        throw new IllegalArgumentException("Pattern letter not supported by Flint yet: ZZZZ");
    default:
        throw new IllegalArgumentException("Pattern letter not supported by Flint yet: " ~ c);
    }
}

/// Parses a duration in the ISO-8601 form `PnDTnHnMn.nS`, as `Duration.parse` specifies.
Duration parseDuration(string text)
{
    import std.ascii : toUpper;

    size_t pos;
    bool negate;
    if (pos < text.length && (text[pos] == '+' || text[pos] == '-'))
        negate = text[pos++] == '-';
    if (pos >= text.length || toUpper(text[pos]) != 'P')
        throw durationError(text);
    ++pos;
    long seconds, nanos;
    bool any, inTime;
    while (pos < text.length)
    {
        if (toUpper(text[pos]) == 'T')
        {
            if (inTime)
                throw durationError(text);
            inTime = true;
            ++pos;
            if (pos == text.length)
                throw durationError(text);
            continue;
        }
        const part = durationPart(text, pos, inTime);
        seconds += part.seconds;
        nanos += part.nanos;
        any = true;
    }
    if (!any)
        throw durationError(text);
    const result = Duration.ofSeconds(seconds, nanos);
    return negate ? result.negated() : result;
}

private DateTimeParseException durationError(string text) pure nothrow
{
    return new DateTimeParseException("Text cannot be parsed to a Duration", text, 0);
}

private struct DurationPart
{
    long seconds;
    long nanos;
}

// The optional `.n` or `,n` fraction of seconds at `pos`, in nanoseconds; advances `pos` past it.
private long durationFraction(string text, ref size_t pos)
{
    if (pos >= text.length || (text[pos] != '.' && text[pos] != ','))
        return 0;
    ++pos;
    size_t count;
    long nanos;
    while (pos < text.length && Parser.digit(text[pos]) && count < 9)
    {
        nanos = nanos * 10 + (text[pos++] - '0');
        ++count;
    }
    if (count == 0)
        throw durationError(text);
    return nanos * tenPow(cast(int)(9 - count));
}

// One `[-]n[.n]X` component; advances `pos` past its unit letter.
private DurationPart durationPart(string text, ref size_t pos, bool inTime)
{
    import std.ascii : toUpper;

    const start = pos;
    const negative = pos < text.length && text[pos] == '-';
    if (pos < text.length && (text[pos] == '-' || text[pos] == '+'))
        ++pos;
    long whole;
    size_t digits;
    while (pos < text.length && Parser.digit(text[pos]))
    {
        whole = whole * 10 + (text[pos++] - '0');
        ++digits;
    }
    const fractionNanos = durationFraction(text, pos);
    if (digits == 0 || pos >= text.length)
        throw durationError(text);
    const unit = toUpper(text[pos++]);
    const sign = negative ? -1 : 1;
    const seconds = unitSeconds(unit, inTime);
    if (seconds == 0 || (fractionNanos != 0 && unit != 'S'))
    {
        pos = start;
        throw durationError(text);
    }
    return DurationPart(sign * whole * seconds, sign * fractionNanos);
}

// Seconds per unit of a duration component: D before the 'T', H, M and S after it; 0 when not allowed.
private long unitSeconds(char unit, bool inTime) pure nothrow @nogc
{
    if (!inTime)
        return unit == 'D' ? 86_400 : 0;
    return unit == 'H' ? 3600 : unit == 'M' ? 60 : unit == 'S' ? 1 : 0;
}
