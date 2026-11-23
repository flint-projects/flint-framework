/*
 * Ported from Jackson Databind 3.1.8, https://github.com/FasterXML/jackson-databind,
 * tag jackson-databind-3.1.8: src/main/java/tools/jackson/databind/util/StdDateFormat.java,
 * ser/jdk/{JavaUtilDateSerializer,DateTimeSerializerBase}.java,
 * deser/jdk/{JavaUtilDateDeserializer,DateBasedDeserializer}.java, StdDeserializer._parseDate and
 * _parseDateFromArray, and the Date keys of ser/jdk/StdKeySerializers and deser/jdk/StdKeyDeserializer.
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D (rulebook v2) over flint.java.util's Date, Calendar and TimeZone
 * and flint.java.text's SimpleDateFormat, as upstream delegates to the JDK's. The serializer and deserializer
 * classes and their contextual copies become functions of the property's @JsonFormat; the ISO-8601 regular
 * expression is matched by hand. The context time zone is UTC and the context locale English; only fixed-offset
 * time zones resolve, and names are English (deviation D-JACKSON-9).
 */

/// Jackson's `java.util.Date` support: StdDateFormat's ISO-8601 text by default, epoch milliseconds under
/// `WRITE_DATES_AS_TIMESTAMPS`, and `@JsonFormat` shapes, patterns, time zones and leniency.
module flint.jackson.databind.stddateformat;

import flint.engine.aot.any : Any;
import flint.jackson.annotation : JsonFormat, OptBoolean;
import flint.jackson.core : JsonGenerator, JsonParser, JsonToken;
import flint.jackson.databind.cfg : DateHooks, DateTimeFeature, DeserializationFeature, MapperConfig;
import flint.jackson.databind.exc : InvalidDefinitionException, InvalidFormatException, MismatchedInputException;
import flint.jackson.databind.ext.javatime : JavaTimeFormat;
import flint.java.lang : IllegalArgumentException;
import flint.java.text : DateFormat, ParseException, ParsePosition, SimpleDateFormat;
import flint.java.util : Calendar, Date, GregorianCalendar, Locale, TimeZone;

@safe:

// Dates are off the hot path (an error timestamp, a formatted property): LDC compiles them for size.
version (LDC)
{
    import ldc.attributes : optStrategy;

    private enum cold = optStrategy("minsize");
}
else
{
    private enum cold = 0;
}

package(flint.jackson.databind):

/// The Flint type name of `java.util.Date`.
enum string DATE_TYPE = "flint.java.util.date.Date";

/// Whether `type` is `java.util.Date`.
bool isJavaUtilDate(string type) pure nothrow @nogc
{
    return type == DATE_TYPE;
}

private enum string DATE_FORMAT_STR_ISO8601 = "yyyy-MM-dd'T'HH:mm:ss.SSSX";
private enum string DATE_FORMAT_STR_PLAIN = "yyyy-MM-dd";
private enum string DATE_FORMAT_STR_RFC1123 = "EEE, dd MMM yyyy HH:mm:ss zzz";
private enum string ALL_FORMATS = `"yyyy-MM-dd'T'HH:mm:ss.SSSX", "yyyy-MM-dd'T'HH:mm:ss.SSS", `
    ~ `"EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd"`;

/// StdDateFormat: writes ISO-8601 with milliseconds ("2009-02-13T23:31:30.123Z"), reads ISO-8601, RFC 1123 and
/// stringified timestamps. Jackson 3's defaults: a colon in the offset, and "Z" for a zero offset.
final class StdDateFormat : DateFormat
{
    alias parse = DateFormat.parse;

    private TimeZone _timezone; // null: UTC
    private OptBoolean _lenient = OptBoolean.DEFAULT; // Java's nullable Boolean
    private bool _tzSerializedWithColon = true;
    private bool _writeZeroOffsetAsZ = true;
    private Calendar _calendar;
    private DateFormat _formatRFC1123;

    /// UTC, lenient, Jackson 3's offsets.
    @cold
    this() pure nothrow @nogc
    {
    }

    @cold
    private this(TimeZone tz, OptBoolean lenient, bool colon, bool zeroAsZ) pure nothrow @nogc
    {
        _timezone = tz;
        _lenient = lenient;
        _tzSerializedWithColon = colon;
        _writeZeroOffsetAsZ = zeroAsZ;
    }

    /// This format in `tz` (UTC when null).
    @cold
    StdDateFormat withTimeZone(TimeZone tz)
    {
        if (tz is null)
            tz = TimeZone.getTimeZone("UTC");
        if (tz is _timezone || (_timezone !is null && tz.getID() == _timezone.getID()))
            return this;
        return new StdDateFormat(tz, _lenient, _tzSerializedWithColon, _writeZeroOffsetAsZ);
    }

    /// This format with the leniency `b` (`DEFAULT` for unset).
    @cold
    StdDateFormat withLenient(OptBoolean b)
    {
        return b == _lenient ? this : new StdDateFormat(_timezone, b, _tzSerializedWithColon, _writeZeroOffsetAsZ);
    }

    /// This format writing offsets as "+05:00" (`b`) or "+0500".
    @cold
    StdDateFormat withColonInTimeZone(bool b)
    {
        return b == _tzSerializedWithColon ? this : new StdDateFormat(_timezone, _lenient, b, _writeZeroOffsetAsZ);
    }

    /// This format writing a zero offset as "Z" (`b`) or numerically.
    @cold
    StdDateFormat withZeroOffsetAsZ(bool b)
    {
        return b == _writeZeroOffsetAsZ ? this : new StdDateFormat(_timezone, _lenient, _tzSerializedWithColon, b);
    }

    /// A copy.
    @cold
    StdDateFormat clone()
    {
        return new StdDateFormat(_timezone, _lenient, _tzSerializedWithColon, _writeZeroOffsetAsZ);
    }

    @cold
    override TimeZone getTimeZone()
    {
        return _timezone;
    }

    @cold
    override void setTimeZone(TimeZone tz)
    {
        if (_timezone is null || tz.getID() != _timezone.getID())
        {
            _formatRFC1123 = null;
            _timezone = tz;
        }
    }

    @cold
    override void setLenient(bool enabled)
    {
        const value = enabled ? OptBoolean.TRUE : OptBoolean.FALSE;
        if (value != _lenient)
        {
            _lenient = value;
            _formatRFC1123 = null;
        }
    }

    @cold
    override bool isLenient()
    {
        return _lenient != OptBoolean.FALSE;
    }

    /// Whether offsets are written with a colon.
    @cold
    bool isColonIncludedInTimeZone() const pure nothrow @nogc
    {
        return _tzSerializedWithColon;
    }

    /// StdDateFormat.toPattern.
    @cold
    string toPattern() const pure nothrow
    {
        enum prefix = "[one of: '" ~ DATE_FORMAT_STR_ISO8601 ~ "', '" ~ DATE_FORMAT_STR_RFC1123 ~ "' (";
        return _lenient == OptBoolean.FALSE ? prefix ~ "strict)]" : prefix ~ "lenient)]";
    }

    /// Trims, then reads ISO-8601, a stringified timestamp or RFC 1123. Throws `ParseException` with Jackson's
    /// message.
    @cold
    override Date parse(string dateStr)
    {
        dateStr = javaTrim(dateStr);
        auto pos = new ParsePosition(0);
        if (auto dt = _parseDate(dateStr, pos))
            return dt;
        enum notCompatible = "\": not compatible with any of standard forms (" ~ ALL_FORMATS ~ ")";
        throw new ParseException("Cannot parse date \"" ~ dateStr ~ notCompatible, pos.getErrorIndex());
    }

    @cold
    override Date parse(string dateStr, ParsePosition pos)
    {
        try
            return _parseDate(dateStr, pos);
        catch (ParseException)
            return null;
    }

    @cold
    private Date _parseDate(string dateStr, ParsePosition pos)
    {
        if (looksLikeISO8601(dateStr))
            return parseAsISO8601(dateStr, pos);
        // A stringified timestamp: digits, a leading '-' allowed; a positive one within long's range.
        bool digits = dateStr.length > 0;
        foreach (i, ch; dateStr)
            digits = digits && ((ch >= '0' && ch <= '9') || (i == 0 && ch == '-'));
        if (digits && (dateStr[0] == '-' || inLongRange(dateStr)))
            return new Date(parseDateFromLong(dateStr, pos));
        return parseAsRFC1123(dateStr, pos);
    }

    @cold
    override string format(const Date date)
    {
        return _format(_timezone is null ? TimeZone.getTimeZone("UTC") : _timezone, date);
    }

    @cold
    private string _format(TimeZone tz, const Date date)
    {
        const millis = date.getTime();
        return formatIso(millis, tz.getOffset(millis), _tzSerializedWithColon, _writeZeroOffsetAsZ);
    }

    @cold
    private Date parseAsISO8601(string dateStr, ParsePosition pos)
    {
        try
            return _parseAsISO8601(dateStr);
        catch (IllegalArgumentException e)
            throw new ParseException("Cannot parse date \"" ~ dateStr ~ "\", problem: " ~ e.msg, pos.getErrorIndex());
    }

    @cold
    private Date _parseAsISO8601(string dateStr)
    {
        const totalLen = dateStr.length;
        // One short-cut: text ending in "Z" is UTC.
        auto cal = _getCalendar(_timezone !is null && dateStr[totalLen - 1] != 'Z' ? _timezone : TimeZone.getTimeZone(
                "UTC"));
        cal.clear();
        if (totalLen <= 10)
        {
            if (!isPlainDate(dateStr))
                throw fitsButFails(dateStr, DATE_FORMAT_STR_PLAIN);
            cal.set(parse4D(dateStr, 0), parse2D(dateStr, 5) - 1, parse2D(dateStr, 8), 0, 0, 0);
            cal.set(Calendar.MILLISECOND, 0);
            return cal.getTime();
        }
        const m = Iso8601.match(dateStr);
        if (!m.matches)
            throw fitsButFails(dateStr, DATE_FORMAT_STR_ISO8601);
        // [databind#5429]: an extended year runs to the first '-' after any sign.
        const yearEnd = indexOf(dateStr, '-', dateStr[0] == '-' ? 1 : 0);
        const year = yearEnd <= 4 ? parse4D(dateStr, 0) : parseInt(dateStr[0 .. yearEnd]);
        const offset = yearEnd - 4;
        const seconds = totalLen > 16 + offset && dateStr[16 + offset] == ':' ? parse2D(dateStr, 17 + offset) : 0;
        // Important! START with the optional time zone; otherwise Calendar will explode.
        if (m.zoneEnd - m.zoneStart > 1)
        {
            int offsetSecs = parse2D(dateStr, m.zoneStart + 1) * 3600;
            if (m.zoneEnd - m.zoneStart >= 5)
                offsetSecs += parse2D(dateStr, m.zoneEnd - 2) * 60;
            cal.set(Calendar.ZONE_OFFSET, offsetSecs * (dateStr[m.zoneStart] == '-' ? -1000 : 1000));
            cal.set(Calendar.DST_OFFSET, 0);
        }
        cal.set(year, parse2D(dateStr, 5 + offset) - 1, parse2D(dateStr, 8 + offset), parse2D(dateStr,
                11 + offset), parse2D(dateStr, 14 + offset), seconds);
        cal.set(Calendar.MILLISECOND, fractionMillis(dateStr, m));
        return cal.getTime();
    }

    @cold
    private ParseException fitsButFails(string dateStr, string formatStr) const pure nothrow
    {
        const leniency = _lenient == OptBoolean.DEFAULT ? "null" : _lenient == OptBoolean.TRUE ? "true" : "false";
        return new ParseException("Cannot parse date \"" ~ dateStr ~ "\": while it seems to fit format '"
                ~ formatStr ~ "', parsing fails (leniency? " ~ leniency ~ ")", 0);
    }

    // RFC 1123 through SimpleDateFormat, which ignores text after the pattern and returns null on a mismatch.
    @cold
    private Date parseAsRFC1123(string dateStr, ParsePosition pos)
    {
        if (_formatRFC1123 is null)
        {
            _formatRFC1123 = new SimpleDateFormat(DATE_FORMAT_STR_RFC1123, Locale.US);
            _formatRFC1123.setTimeZone(_timezone is null ? TimeZone.getTimeZone("UTC") : _timezone);
            if (_lenient != OptBoolean.DEFAULT)
                _formatRFC1123.setLenient(_lenient == OptBoolean.TRUE);
        }
        return _formatRFC1123.parse(dateStr, pos);
    }

    @cold
    private Calendar _getCalendar(TimeZone tz)
    {
        if (_calendar is null)
            _calendar = new GregorianCalendar(tz);
        else if (_calendar.getTimeZone().getID() != tz.getID() || _calendar.getTimeZone()
                .getRawOffset() != tz.getRawOffset())
            _calendar.setTimeZone(tz);
        _calendar.setLenient(isLenient());
        return _calendar;
    }
}

/// StdDateFormat._format without a calendar object, so writing a date links no parsing: `millis` at `offset`
/// milliseconds from UTC, "2009-02-13T23:31:30.123Z" ("+05:30" or "+0530" for an offset).
@cold
string formatIso(long millis, long offset, bool colon = true, bool zeroAsZ = true) pure nothrow
{
    import flint.java.util.calendar : gregorianFields;

    int[Calendar.FIELD_COUNT] f;
    gregorianFields(millis, offset, f);
    Text buffer;
    if (f[Calendar.ERA] == GregorianCalendar.BC)
        _formatBCEYear(buffer, f[Calendar.YEAR]);
    else
    {
        if (f[Calendar.YEAR] > 9999)
            buffer.put('+');
        buffer.pad(f[Calendar.YEAR], 4);
    }
    static immutable int[6] fields = [
        Calendar.MONTH, Calendar.DAY_OF_MONTH, Calendar.HOUR_OF_DAY, Calendar.MINUTE,
        Calendar.SECOND, Calendar.MILLISECOND
    ];
    static immutable string separators = "--T::.";
    foreach (i, field; fields)
    {
        buffer.put(separators[i]);
        buffer.pad(f[field] + (field == Calendar.MONTH ? 1 : 0), field == Calendar.MILLISECOND ? 3 : 2);
    }
    if (offset == 0 && zeroAsZ)
        buffer.put('Z');
    else
        appendOffset(buffer, offset, colon);
    return buffer.text();
}

@cold
private void appendOffset(ref Text buffer, long offsetMillis, bool colon) pure nothrow
{
    const totalMinutes = offsetMillis / (60 * 1000);
    buffer.put(offsetMillis < 0 ? '-' : '+');
    buffer.pad(totalMinutes / 60 < 0 ? -(totalMinutes / 60) : totalMinutes / 60, 2);
    if (colon)
        buffer.put(':');
    buffer.pad(totalMinutes % 60 < 0 ? -(totalMinutes % 60) : totalMinutes % 60, 2);
}

// The year before the Common Era: 1 BC is "+0000", 2 BC "-0001".
@cold
private void _formatBCEYear(ref Text buffer, int bceYearNoSign) pure nothrow
{
    if (bceYearNoSign == 1)
        return buffer.put("+0000");
    buffer.put('-');
    buffer.pad(bceYearNoSign - 1, 4);
}

// NumberInput.parseLong (Long.parseLong): digits after an optional '-', within long's range.
@cold
private long parseDateFromLong(string longStr, ParsePosition pos)
{
    const negative = longStr[0] == '-';
    const digits = longStr[negative ? 1 : 0 .. $];
    ulong value;
    bool ok = digits.length > 0;
    foreach (c; digits)
    {
        ok = ok && value <= (ulong.max - (c - '0')) / 10;
        value = value * 10 + (c - '0');
    }
    if (!ok || value > (negative ? 1UL << 63 : long.max))
        throw new ParseException("Timestamp value " ~ longStr ~ " out of 64-bit value range", pos.getErrorIndex());
    return negative ? -cast(long) value : cast(long) value;
}

// The milliseconds of the fraction, its first three digits; more than nine digits is Jackson's error.
@cold
private int fractionMillis(string dateStr, Iso8601 m)
{
    const fraction = m.fractionEnd > m.fractionStart ? dateStr[m.fractionStart + 1 .. m.fractionEnd] : null;
    if (fraction.length > 9)
        throw new ParseException("Cannot parse date \"" ~ dateStr ~ "\": invalid fractional seconds '"
                ~ fraction ~ "'; can use at most 9 digits", cast(int) m.fractionStart + 1);
    int msecs;
    foreach (i, scale; [100, 10, 1])
        if (i < fraction.length)
            msecs += scale * (fraction[i] - '0');
    return msecs;
}

// Text built in place: one growing array, copied once by `text`.
private struct Text
{
    char[] data;
    size_t used;

    @cold
    void put(scope const(char)[] s) pure nothrow
    {
        if (used + s.length > data.length)
            data.length = (used + s.length) * 2 + 16;
        data[used .. used + s.length] = s[];
        used += s.length;
    }

    @cold
    void put(char c) pure nothrow
    {
        const char[1] one = [c];
        put(one[]);
    }

    // A non-negative number, zero-padded to `width` digits.
    @cold
    void pad(long value, int width) pure nothrow
    {
        char[20] digits;
        size_t n;
        do
        {
            digits[$ - ++n] = cast(char)('0' + value % 10);
            value /= 10;
        }
        while (value);
        foreach (_; n .. width)
            put('0');
        put(digits[$ - n .. $]);
    }

    @cold
    string text() const pure nothrow
    {
        return data[0 .. used].idup;
    }
}

/// Java's `String.trim()`: characters up to U+0020 removed from both ends.
string javaTrim(string text) pure nothrow @nogc
{
    size_t start, end = text.length;
    while (start < end && text[start] <= ' ')
        ++start;
    while (end > start && text[end - 1] <= ' ')
        --end;
    return text[start .. end];
}

private bool isDigit(char c) pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

// StdDateFormat.looksLikeISO8601.
@cold
private bool looksLikeISO8601(string dateStr) pure nothrow @nogc
{
    if (dateStr.length < 7)
        return false;
    const c = dateStr[0];
    if (c == '+' || c == '-')
    {
        // [databind#5729]: a signed run of digits is a stringified timestamp.
        bool allDigits = dateStr.length > 1;
        foreach (ch; dateStr[1 .. $])
            allDigits = allDigits && isDigit(ch);
        return !allDigits && dateStr.length >= 11 && isDigit(dateStr[1]);
    }
    return isDigit(c) && isDigit(dateStr[3]) && dateStr[4] == '-' && isDigit(dateStr[5]);
}

// NumberInput.inLongRange(s, false): at most 19 digits, and no more than Long.MAX_VALUE.
@cold
private bool inLongRange(string s) pure nothrow @nogc
{
    enum maxLong = "9223372036854775807";
    if (s.length != maxLong.length)
        return s.length < maxLong.length;
    return s <= maxLong;
}

// PATTERN_PLAIN: \d\d\d\d[-]\d\d[-]\d\d, matching the whole text.
@cold
private bool isPlainDate(string s) pure nothrow @nogc
{
    if (s.length != 10 || s[4] != '-' || s[7] != '-')
        return false;
    foreach (i; [0, 1, 2, 3, 5, 6, 8, 9])
        if (!isDigit(s[i]))
            return false;
    return true;
}

// PATTERN_ISO8601, matched by hand: (?:[+-]?\d{4,})[-]\d\d[-]\d\d[T]\d\d[:]\d\d(?:[:]\d\d)?(\.\d+)?
// (Z|[+-]\d\d(?:[:]?\d\d)?)?, with the spans of group 1 (the fraction) and group 2 (the offset).
private struct Iso8601
{
    bool matches;
    size_t fractionStart, fractionEnd, zoneStart, zoneEnd;

    @cold
    static Iso8601 match(string s) pure nothrow @nogc
    {
        Iso8601 m;
        size_t i = s.length && (s[0] == '+' || s[0] == '-') ? 1 : 0;
        const yearStart = i;
        i = digitsEnd(s, i);
        if (i - yearStart < 4 || !fixed(s, i, "-dd-ddTdd:dd"))
            return m;
        if (i + 2 < s.length && s[i] == ':' && isDigit(s[i + 1]) && isDigit(s[i + 2]))
            i += 3;
        m.fractionStart = i;
        if (i + 1 < s.length && s[i] == '.' && isDigit(s[i + 1]))
            i = digitsEnd(s, i + 1);
        m.fractionEnd = i;
        m.zoneStart = i;
        if (i < s.length && s[i] == 'Z')
            ++i;
        else if (i < s.length && (s[i] == '+' || s[i] == '-'))
            i = offsetEnd(s, i);
        m.zoneEnd = i;
        m.matches = i == s.length;
        return m;
    }

    @cold
    private static size_t digitsEnd(string s, size_t i) pure nothrow @nogc
    {
        while (i < s.length && isDigit(s[i]))
            ++i;
        return i;
    }

    // [+-]\d\d(?:[:]?\d\d)?: the end of the offset at `i`, or the text's length plus one when it does not match.
    @cold
    private static size_t offsetEnd(string s, size_t i) pure nothrow @nogc
    {
        if (i + 2 >= s.length || !isDigit(s[i + 1]) || !isDigit(s[i + 2]))
            return s.length + 1;
        i += 3;
        const colon = i < s.length && s[i] == ':' ? 1 : 0;
        if (i + colon + 1 < s.length && isDigit(s[i + colon]) && isDigit(s[i + colon + 1]))
            i += colon + 2;
        return i;
    }

    // `form` with 'd' for a digit and anything else literal, starting at `i`.
    @cold
    private static bool fixed(string s, ref size_t i, string form) pure nothrow @nogc
    {
        if (s.length - i < form.length)
            return false;
        foreach (c; form)
        {
            if (c == 'd' ? !isDigit(s[i]) : s[i] != c)
                return false;
            ++i;
        }
        return true;
    }
}

@cold
private int parse4D(string s, size_t index) pure nothrow @nogc
{
    return 1000 * (s[index] - '0') + 100 * (s[index + 1] - '0') + 10 * (s[index + 2] - '0') + (s[index + 3] - '0');
}

@cold
private int parse2D(string s, size_t index) pure nothrow @nogc
{
    return 10 * (s[index] - '0') + (s[index + 1] - '0');
}

@cold
private size_t indexOf(string s, char c, size_t from) pure nothrow @nogc
{
    foreach (i; from .. s.length)
        if (s[i] == c)
            return i;
    return s.length;
}

// Integer.parseInt of an extended year; NumberFormatException, an IllegalArgumentException, when it is no int.
@cold
private int parseInt(string digits)
{
    long value;
    foreach (c; digits[digits[0] == '+' || digits[0] == '-' ? 1 : 0 .. $])
    {
        value = value * 10 + (c - '0');
        if (value > int.max + 1L)
            break;
    }
    const negative = digits[0] == '-';
    if (value > (negative ? int.max + 1L : int.max))
        throw new IllegalArgumentException("For input string: \"" ~ digits ~ "\"");
    return cast(int)(negative ? -value : value);
}

// ---- JavaUtilDateSerializer and JavaUtilDateDeserializer

/// Write a `java.util.Date`; returns false when `type` is not `java.util.Date`. Timestamps and ISO-8601 text are
/// written here; a `@JsonFormat` pattern goes through the registered `JavaUtilDateModule`.
@cold
bool writeJavaUtilDate(MapperConfig config, ref Any value, string type, JsonGenerator g, JavaTimeFormat format)
{
    if (!isJavaUtilDate(type))
        return false;
    const millis = (cast(Date) value.asObject()).getTime();
    const shape = format.present ? format.shape : JsonFormat.Shape.ANY;
    // DateTimeSerializerBase.createContextual: a numeric shape, a pattern, or a zone, locale or STRING shape.
    if (shape == JsonFormat.Shape.NUMBER || shape == JsonFormat.Shape.NUMBER_INT
            || shape == JsonFormat.Shape.NUMBER_FLOAT)
        g.writeNumber(millis);
    else if (format.present && (format.pattern.length || hasTimeZone(format)))
        g.writeString(hooks(config, type).formatPattern(millis, format, type));
    else if (format.present && (hasLocale(format) || shape == JsonFormat.Shape.STRING))
        g.writeString(formatIso(millis, 0));
    else if (config.isEnabled(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS))
        g.writeNumber(millis);
    else
        g.writeString(formatIso(millis, 0));
    return true;
}

/// StdKeySerializers for a `java.util.Date` key: its timestamp under `WRITE_DATE_KEYS_AS_TIMESTAMPS`, else
/// StdDateFormat's text.
@cold
string dateKeyText(MapperConfig config, const Date date)
{
    import flint.engine.aot.text : decimal;

    if (config.isEnabled(DateTimeFeature.WRITE_DATE_KEYS_AS_TIMESTAMPS))
        return decimal(date.getTime());
    return formatIso(date.getTime(), 0);
}

/// JavaUtilDateDeserializer: read a `java.util.Date` at the parser's current token, through the registered
/// `JavaUtilDateModule`.
@cold
Any readJavaUtilDate(MapperConfig config, JsonParser p, string type, JavaTimeFormat format)
{
    if (p.currentToken() == JsonToken.VALUE_NULL)
        return Any.init;
    return hooks(config, type).read(config, p, type, format);
}

/// StdKeyDeserializer for a `java.util.Date` key, through the registered `JavaUtilDateModule`.
@cold
Any dateKey(MapperConfig config, string key, JsonParser p)
{
    return hooks(config, DATE_TYPE).readKey(key, p);
}

// The registered JavaUtilDateModule's hooks. Generated configurations and the templated ObjectMapper methods
// register it for every type that holds a Date; only a mapper built by hand over hand-registered descriptors, used
// through the erased methods, can lack it (deviation D-JACKSON-10).
@cold
private DateHooks hooks(MapperConfig config, string type)
{
    if (config.dateHooks.read is null)
        throw new InvalidDefinitionException(
                "`java.util.Date` is read, and formatted with a @JsonFormat pattern or time zone, by "
                ~ "JavaUtilDateModule, which this mapper does not have: register it with JsonMapper.builder()"
                ~ ".addModule(new JavaUtilDateModule()) (deviation D-JACKSON-10)", type);
    return config.dateHooks;
}

/// Install `JavaUtilDateModule`'s hooks: Date reading, Date keys and `@JsonFormat` patterns.
@cold
void installJavaUtilDate(MapperConfig config)
{
    import core.atomic : atomicFence;

    DateHooks h;
    h.read = &moduleReadDate;
    h.readKey = &moduleReadKey;
    h.formatPattern = &moduleFormatPattern;
    config.dateHooks = h;
    atomicFence();
}

// StdKeyDeserializer for a Date key: `DeserializationContext.parseDate`.
@cold
private Any moduleReadKey(string key, JsonParser p)
{
    try
        return Any.ofObject(new StdDateFormat().parse(key), DATE_TYPE);
    catch (ParseException e)
        throw new InvalidFormatException("Cannot deserialize Map key of type `java.util.Date` from String \"" ~ key
                ~ "\": not a valid representation, problem: (java.lang.IllegalArgumentException) "
                ~ "Failed to parse Date value '" ~ key ~ "': " ~ e.msg, key, DATE_TYPE, p.currentLocation());
}

// DateTimeSerializerBase with a pattern (SimpleDateFormat in the format's zone and locale) or a time zone
// (StdDateFormat in that zone).
@cold
private string moduleFormatPattern(long millis, JavaTimeFormat format, string type)
{
    if (format.pattern.length)
        return patternFormat(format, type).format(new Date(millis));
    return formatIso(millis, zoneOf(format, type).getRawOffset());
}

@cold
private bool hasLocale(JavaTimeFormat format) pure nothrow @nogc
{
    return format.locale != JsonFormat.DEFAULT_LOCALE && format.locale.length;
}

@cold
private bool hasTimeZone(JavaTimeFormat format) pure nothrow @nogc
{
    return format.timezone != JsonFormat.DEFAULT_TIMEZONE && format.timezone.length;
}

// JsonFormat.Value.getTimeZone, or the context's (UTC); Flint resolves fixed offsets only (D-JACKSON-9).
@cold
private TimeZone zoneOf(JavaTimeFormat format, string type)
{
    try
        return TimeZone.getTimeZone(hasTimeZone(format) ? format.timezone : "UTC");
    catch (IllegalArgumentException e)
        throw new InvalidDefinitionException(e.msg ~ " (deviation D-JACKSON-9)", type);
}

// new SimpleDateFormat(pattern, locale) in the annotation's zone or the context's: English names only.
@cold
private SimpleDateFormat patternFormat(JavaTimeFormat format, string type)
{
    SimpleDateFormat df;
    const locale = localeOf(format);
    try
        df = new SimpleDateFormat(format.pattern, locale);
    catch (IllegalArgumentException e)
    {
        if (locale.getLanguage() == "en")
            throw e;
        throw new InvalidDefinitionException(e.msg ~ " (deviation D-JACKSON-9)", type);
    }
    df.setTimeZone(zoneOf(format, type));
    return df;
}

// JsonFormat.Value.getLocale: the annotation's language (`fr_FR`, `en-GB`), else the context's, English.
@cold
private Locale localeOf(JavaTimeFormat format) pure nothrow
{
    if (!hasLocale(format))
        return Locale.US;
    size_t end;
    while (end < format.locale.length && format.locale[end] != '_' && format.locale[end] != '-')
        ++end;
    return Locale(format.locale[0 .. end]);
}

// DateBasedDeserializer.createContextual: the custom format a property's @JsonFormat selects, if any, and the
// format string its messages name.
private struct CustomFormat
{
    DateFormat format;
    string formatString;
}

@cold
private CustomFormat customFormat(JavaTimeFormat format, string type)
{
    if (!format.present)
        return CustomFormat.init;
    const lenient = format.lenient;
    if (format.pattern.length)
    {
        auto df = patternFormat(format, type);
        if (lenient != OptBoolean.DEFAULT)
            df.setLenient(lenient == OptBoolean.TRUE);
        return CustomFormat(df, format.pattern);
    }
    if (hasTimeZone(format))
        return CustomFormat(new StdDateFormat().withTimeZone(zoneOf(format, type)).withLenient(lenient), "null");
    if (lenient != OptBoolean.DEFAULT)
    {
        auto std = new StdDateFormat().withLenient(lenient);
        return CustomFormat(std, std.toPattern());
    }
    return CustomFormat.init;
}

// JavaUtilDateDeserializer.deserialize with DateBasedDeserializer.createContextual's custom format.
@cold
private Any moduleReadDate(MapperConfig config, JsonParser p, string type, JavaTimeFormat format)
{
    return readDate(config, p, customFormat(format, type));
}

@cold
private Any readDate(MapperConfig config, JsonParser p, CustomFormat custom)
{
    const t = p.currentToken();
    if (custom.format !is null && t == JsonToken.VALUE_STRING)
        return readCustom(p, custom);
    switch (t)
    {
    case JsonToken.VALUE_STRING:
        return readText(p, javaTrim(p.getString()));
    case JsonToken.VALUE_NUMBER_INT:
        return readTimestamp(p);
    case JsonToken.VALUE_NULL:
        return Any.init;
    case JsonToken.START_ARRAY:
        return readArray(config, p, custom);
    default:
        import flint.jackson.databind.deser : mismatch;

        throw mismatch(DATE_TYPE, t);
    }
}

// DateBasedDeserializer._parseDate with a custom format: "" is null, anything unparseable names the format.
@cold
private Any readCustom(JsonParser p, CustomFormat custom)
{
    const str = javaTrim(p.getString());
    if (str.length == 0)
        return Any.init;
    try
        return Any.ofObject(custom.format.parse(str), DATE_TYPE);
    catch (ParseException)
        throw new InvalidFormatException("Cannot deserialize value of type `java.util.Date` from String \"" ~ str
                ~ "\": expected format \"" ~ custom.formatString ~ "\"", str, DATE_TYPE, p.currentLocation());
}

// StdDeserializer._parseDate(String): "" and "null" are null; anything else goes to the context's StdDateFormat.
@cold
private Any readText(JsonParser p, string value)
{
    if (value.length == 0 || value == "null")
        return Any.init;
    try
        return Any.ofObject(new StdDateFormat().parse(value), DATE_TYPE);
    catch (ParseException e)
        throw new InvalidFormatException("Cannot deserialize value of type `java.util.Date` from String \"" ~ value
                ~ "\": not a valid representation (error: Failed to parse Date value '" ~ value ~ "': " ~ e.msg ~ ")",
                value, DATE_TYPE, p.currentLocation());
}

private enum string notALong = ": not a valid 64-bit `long` for creating `java.util.Date`";
private enum string moreThanOne = "`), expected `JsonToken.END_ARRAY`: Attempted to unwrap 'java.util.Date' value "
    ~ "from an array (with `DeserializationFeature.UNWRAP_SINGLE_VALUE_ARRAYS`) but it contains more than one value";

@cold
private Any readTimestamp(JsonParser p)
{
    import flint.jackson.core.exc : InputCoercionException;

    try
        return Any.ofObject(new Date(p.getLongValue()), DATE_TYPE);
    catch (InputCoercionException)
        throw new InvalidFormatException(
                "Cannot deserialize value of type `java.util.Date` from number " ~ p.getString() ~ notALong,
                p.getString(), DATE_TYPE, p.currentLocation());
}

// StdDeserializer._parseDateFromArray: an empty array is null under ACCEPT_EMPTY_ARRAY_AS_NULL_OBJECT, and one
// value unwraps under UNWRAP_SINGLE_VALUE_ARRAYS.
@cold
private Any readArray(MapperConfig config, JsonParser p, CustomFormat custom)
{
    import flint.jackson.core : tokenName;
    import flint.jackson.databind.deser : mismatch;

    const asNull = config.isEnabled(DeserializationFeature.ACCEPT_EMPTY_ARRAY_AS_NULL_OBJECT);
    const unwrap = config.isEnabled(DeserializationFeature.UNWRAP_SINGLE_VALUE_ARRAYS);
    if (unwrap || asNull)
    {
        const t = p.nextToken();
        if (t == JsonToken.END_ARRAY && asNull)
            return Any.init;
        if (t != JsonToken.END_ARRAY && unwrap)
        {
            if (t == JsonToken.START_ARRAY)
                throw new MismatchedInputException("Cannot deserialize value of type `java.util.Date` out of "
                        ~ "START_ARRAY token: nested Arrays not allowed with "
                        ~ "DeserializationFeature.UNWRAP_SINGLE_VALUE_ARRAYS", DATE_TYPE, p.currentLocation());
            auto parsed = readDate(config, p, custom);
            const next = p.nextToken();
            if (next != JsonToken.END_ARRAY)
                throw new MismatchedInputException("Unexpected token (`JsonToken." ~ tokenName(next) ~ moreThanOne,
                        DATE_TYPE, p.currentLocation());
            return parsed;
        }
    }
    throw mismatch(DATE_TYPE, JsonToken.START_ARRAY);
}
