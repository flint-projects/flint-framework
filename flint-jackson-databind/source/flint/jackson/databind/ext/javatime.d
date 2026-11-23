/*
 * Ported from Jackson Databind 3.1.8, https://github.com/FasterXML/jackson-databind,
 * tag jackson-databind-3.1.8: src/main/java/tools/jackson/databind/ext/javatime/{ser,deser}/
 * (LocalDate, LocalTime, LocalDateTime, Instant, OffsetDateTime, ZonedDateTime, Duration,
 * ZoneId and ZoneOffset serializers and deserializers) and util/DecimalUtils.java.
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D (rulebook v2) over flint.java.time. The
 * per-type serializer and deserializer classes become one dispatch on the Flint type name;
 * the formats, timestamp shapes, context-time-zone adjustment (the context zone is UTC) and
 * messages follow Jackson's. Locale and time-zone attributes of @JsonFormat are not read yet.
 */

/// Jackson's java.time support: ISO-8601 strings by default, numeric timestamps on request, `@JsonFormat` patterns.
module flint.jackson.databind.ext.javatime;

import flint.engine.aot.any : Any;
import flint.jackson.annotation : JsonFormat;
import flint.jackson.core : JsonGenerator, JsonParser, JsonToken;
import flint.jackson.databind.cfg : DateTimeFeature, MapperConfig;
import flint.jackson.databind.exc : InvalidFormatException, MismatchedInputException;
import flint.java.time : DateTimeException, Duration, Instant, LocalDate, LocalDateTime, LocalTime,
    OffsetDateTime, ZoneId, ZoneOffset, ZonedDateTime;
import flint.java.time.format : DateTimeFormatter, DateTimeParseException;

@safe:

/// The parts of a property's `@JsonFormat` that the java.time serializers read.
struct JavaTimeFormat
{
    /// Whether the property carries `@JsonFormat`.
    bool present;
    /// The `pattern` element; empty for the default ISO format.
    string pattern;
    /// The `shape` element.
    JsonFormat.Shape shape = JsonFormat.Shape.ANY;

    /// The java.time view of an annotation.
    static JavaTimeFormat of(const JsonFormat format) pure nothrow @nogc
    {
        return JavaTimeFormat(true, format.pattern, format.shape);
    }
}

private enum Kind
{
    none,
    localDate,
    localTime,
    localDateTime,
    instant,
    offsetDateTime,
    zonedDateTime,
    duration,
    zoneOffset,
    zoneId,
}

private Kind kindOf(string type) pure nothrow @nogc
{
    switch (type)
    {
    case "flint.java.time.LocalDate":
        return Kind.localDate;
    case "flint.java.time.LocalTime":
        return Kind.localTime;
    case "flint.java.time.LocalDateTime":
        return Kind.localDateTime;
    case "flint.java.time.Instant":
        return Kind.instant;
    case "flint.java.time.OffsetDateTime":
        return Kind.offsetDateTime;
    case "flint.java.time.ZonedDateTime":
        return Kind.zonedDateTime;
    case "flint.java.time.Duration":
        return Kind.duration;
    case "flint.java.time.ZoneOffset":
        return Kind.zoneOffset;
    case "flint.java.time.ZoneId":
        return Kind.zoneId;
    default:
        return Kind.none;
    }
}

/// Whether `type` is a java.time type these serializers handle.
bool isJavaTime(string type) pure nothrow @nogc
{
    return kindOf(type) != Kind.none;
}

// Whether to write a timestamp: the shape decides when given, the feature otherwise; a pattern means a String.
private bool useTimestamp(MapperConfig config, JavaTimeFormat format, DateTimeFeature feature) pure nothrow @nogc
{
    with (JsonFormat.Shape) switch (format.shape)
    {
    case NUMBER:
    case NUMBER_FLOAT:
    case NUMBER_INT:
    case ARRAY:
        return true;
    case STRING:
        return false;
    default:
        return format.pattern.length == 0 && config.isEnabled(feature);
    }
}

/// Write a java.time value; returns false when `type` is not a java.time type.
bool writeJavaTime(MapperConfig config, ref Any value, string type, JsonGenerator g,
        JavaTimeFormat format = JavaTimeFormat.init)
{
    const kind = kindOf(type);
    if (kind == Kind.none)
        return false;
    if (kind == Kind.duration)
        writeDuration(config, value.get!Duration(), g, format);
    else if (kind == Kind.zoneOffset)
        g.writeString(value.get!ZoneOffset().getId());
    else if (kind == Kind.zoneId)
        g.writeString(value.get!ZoneId().getId());
    else if (useTimestamp(config, format, DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS))
        writeTimestamp(config, value, kind, g);
    else
        g.writeString(formatted(config, value, kind, format));
    return true;
}

private string formatted(MapperConfig config, ref Any value, Kind kind, JavaTimeFormat format)
{
    const custom = format.pattern.length != 0;
    const pattern = custom ? DateTimeFormatter.ofPattern(format.pattern) : DateTimeFormatter.init;
    switch (kind)
    {
    case Kind.localDate:
        return value.get!LocalDate().format(custom ? pattern : DateTimeFormatter.ISO_LOCAL_DATE);
    case Kind.localTime:
        return value.get!LocalTime().format(custom ? pattern : DateTimeFormatter.ISO_LOCAL_TIME);
    case Kind.localDateTime:
        return value.get!LocalDateTime().format(custom ? pattern
                : DateTimeFormatter.ISO_LOCAL_DATE_TIME);
    case Kind.instant:
        const instant = value.get!Instant();
        return custom ? pattern.withZone(ZoneId.of("UTC"))
            .format(instant) : DateTimeFormatter.ISO_INSTANT.format(instant);
    case Kind.offsetDateTime:
        return value.get!OffsetDateTime().format(custom ? pattern
                : DateTimeFormatter.ISO_OFFSET_DATE_TIME);
    default:
        const zoned = config.isEnabled(DateTimeFeature.WRITE_DATES_WITH_ZONE_ID)
            ? DateTimeFormatter.ISO_ZONED_DATE_TIME : DateTimeFormatter.ISO_OFFSET_DATE_TIME;
        return value.get!ZonedDateTime().format(custom ? pattern : zoned);
    }
}

private void writeTimestamp(MapperConfig config, ref Any value, Kind kind, JsonGenerator g)
{
    const nanos = config.isEnabled(DateTimeFeature.WRITE_DATE_TIMESTAMPS_AS_NANOSECONDS);
    switch (kind)
    {
    case Kind.localDate:
        g.writeStartArray();
        writeDate(value.get!LocalDate(), g);
        g.writeEndArray();
        break;
    case Kind.localTime:
        g.writeStartArray();
        writeTime(value.get!LocalTime(), g, nanos);
        g.writeEndArray();
        break;
    case Kind.localDateTime:
        const dateTime = value.get!LocalDateTime();
        g.writeStartArray();
        writeDate(dateTime.toLocalDate(), g);
        writeTime(dateTime.toLocalTime(), g, nanos);
        g.writeEndArray();
        break;
    default:
        writeInstant(instantOf(value, kind), g, nanos);
        break;
    }
}

private Instant instantOf(ref Any value, Kind kind)
{
    switch (kind)
    {
    case Kind.instant:
        return value.get!Instant();
    case Kind.offsetDateTime:
        return value.get!OffsetDateTime().toInstant();
    default:
        return value.get!ZonedDateTime().toInstant();
    }
}

private void writeDate(LocalDate date, JsonGenerator g)
{
    g.writeNumber(date.getYear());
    g.writeNumber(date.getMonthValue());
    g.writeNumber(date.getDayOfMonth());
}

// Hours and minutes; the seconds when they or the fraction are not zero; the fraction when not zero.
private void writeTime(LocalTime time, JsonGenerator g, bool nanos)
{
    g.writeNumber(time.getHour());
    g.writeNumber(time.getMinute());
    if (time.getSecond() == 0 && time.getNano() == 0)
        return;
    g.writeNumber(time.getSecond());
    if (time.getNano() != 0)
        g.writeNumber(nanos ? time.getNano() : time.getNano() / 1_000_000);
}

private void writeInstant(Instant instant, JsonGenerator g, bool nanos)
{
    if (nanos)
        g.writeNumber(decimalSeconds(instant.getEpochSecond(), instant.getNano()));
    else
        g.writeNumber(instant.toEpochMilli());
}

private void writeDuration(MapperConfig config, Duration duration, JsonGenerator g, JavaTimeFormat format)
{
    if (!useTimestamp(config, format, DateTimeFeature.WRITE_DURATIONS_AS_TIMESTAMPS))
        g.writeString(duration.toString());
    else if (config.isEnabled(DateTimeFeature.WRITE_DATE_TIMESTAMPS_AS_NANOSECONDS))
        g.writeNumber(decimalSeconds(duration.getSeconds(), duration.getNano()));
    else
        g.writeNumber(duration.toMillis());
}

/**
 * DecimalUtils.toBigDecimal(seconds, nanos) as `BigDecimal.toString` prints it: `seconds + nanos / 10^9` at
 * scale 9, in scientific notation when the adjusted exponent is below -6 ("5E-9"), and "0.0" for zero.
 */
string decimalSeconds(long seconds, int nanos) pure nothrow
{
    import std.conv : to;

    if (seconds == 0 && nanos == 0)
        return "0.0";
    // seconds + nanos/1e9, with nanos in [0, 1e9): a negative value with a fraction borrows one second.
    const negative = seconds < 0;
    const borrow = negative && nanos > 0;
    const whole = borrow ? -(seconds + 1) : negative ? -seconds : seconds;
    const fraction = borrow ? 1_000_000_000 - nanos : nanos;
    const sign = negative ? "-" : "";
    auto digits = fraction.to!string;
    while (digits.length < 9)
        digits = "0" ~ digits;
    if (whole != 0)
        return sign ~ whole.to!string ~ "." ~ digits;
    const significant = fraction.to!string;
    const adjusted = cast(int) significant.length - 10;
    if (adjusted >= -6)
        return sign ~ "0." ~ digits;
    // Trailing zeros of the unscaled value stay in BigDecimal's mantissa: 0.000000500 is "5.00E-7".
    const mantissa = significant;
    return sign ~ mantissa[0 .. 1] ~ (mantissa.length > 1 ? "." ~ mantissa[1 .. $] : "") ~ "E" ~ adjusted.to!string;
}

/// Read a java.time value at the parser's current token; `type` must satisfy `isJavaTime`.
Any readJavaTime(MapperConfig config, JsonParser p, string type, JavaTimeFormat format = JavaTimeFormat.init)
{
    const kind = kindOf(type);
    const t = p.currentToken();
    switch (t)
    {
    case JsonToken.VALUE_NULL:
        return Any.init;
    case JsonToken.VALUE_STRING:
        return readText(config, p, kind, type, format);
    case JsonToken.VALUE_NUMBER_INT:
    case JsonToken.VALUE_NUMBER_FLOAT:
        return readNumber(config, p,
                kind, type, t == JsonToken.VALUE_NUMBER_INT);
    case JsonToken.START_ARRAY:
        if (kind == Kind.localDate || kind == Kind.localTime
                || kind == Kind.localDateTime)
            return readArray(config, p, kind, type);
        goto default;
    default:
        if (kind == Kind.localDate || kind == Kind.localTime || kind == Kind.localDateTime)
            throw new MismatchedInputException("Expected array or string.", type, p.currentLocation());
        import flint.jackson.databind.deser : mismatch;

        throw mismatch(type, t);
    }
}

private string javaName(string type) pure nothrow @nogc
{
    return type["flint.".length .. $];
}

// The formatter each type reads with by default, whose description Jackson's messages quote.
private DateTimeFormatter defaultFormatter(Kind kind) pure nothrow @nogc
{
    switch (kind)
    {
    case Kind.localDate:
        return DateTimeFormatter.ISO_LOCAL_DATE;
    case Kind.localTime:
        return DateTimeFormatter.ISO_LOCAL_TIME;
    case Kind.localDateTime:
        return DateTimeFormatter.ISO_LOCAL_DATE_TIME;
    case Kind.instant:
        return DateTimeFormatter.ISO_INSTANT;
    case Kind.offsetDateTime:
        return DateTimeFormatter.ISO_OFFSET_DATE_TIME;
    default:
        return DateTimeFormatter.ISO_ZONED_DATE_TIME;
    }
}

private Any readText(MapperConfig config, JsonParser p, Kind kind, string type, JavaTimeFormat format)
{
    import std.string : strip;

    const text = p.getString().strip;
    if (text.length == 0)
        return Any.init;
    const custom = format.pattern.length != 0;
    const formatter = custom ? DateTimeFormatter.ofPattern(format.pattern) : defaultFormatter(kind);
    try
        return parseText(config, kind, text, formatter, custom);
    catch (DateTimeException e)
    {
        const formatName = kind >= Kind.duration ? "[default format]" : formatter.toString();
        const exceptionName = cast(DateTimeParseException) e ? "java.time.format.DateTimeParseException"
            : "java.time.DateTimeException";
        throw new InvalidFormatException("Cannot deserialize value of type `" ~ javaName(
                type) ~ "` from String \"" ~ text ~ "\": Failed to deserialize `" ~ javaName(
                type) ~ "` (with format '" ~ formatName ~ "'): (" ~ exceptionName ~ ") " ~ e.msg, text,
                type, p.currentLocation());
    }
}

private Any parseText(MapperConfig config, Kind kind, string text, DateTimeFormatter formatter, bool custom)
{
    switch (kind)
    {
    case Kind.localDate:
    case Kind.localTime:
    case Kind.localDateTime:
        return parseLocal(kind, text, formatter, custom);
    case Kind.duration:
        return Any.of(Duration.parse(text));
    case Kind.zoneOffset:
        return Any.of(ZoneOffset.of(text));
    case Kind.zoneId:
        return Any.of(ZoneId.of(text));
    default:
        if (!custom && numeric(text))
            return instantAs(kind, readDecimal(text, true));
        return parseInstant(config, kind, text, formatter, custom);
    }
}

// Jackson's lenient ISO readers: a date-time where a date or time is expected, a 'Z' where none is.
private Any parseLocal(Kind kind, string text, DateTimeFormatter formatter, bool custom)
{
    const isoDateTime = !custom && text.length > 10 && text[10] == 'T';
    if (kind == Kind.localDate)
        return isoDateTime ? Any.of(utcOrLocal(text).toLocalDate()) : Any.of(LocalDate.parse(text, formatter));
    if (kind == Kind.localTime)
        return isoDateTime ? Any.of(utcOrLocal(text).toLocalTime()) : Any.of(LocalTime.parse(text, formatter));
    if (!custom && text[$ - 1] == 'Z')
        return Any.of(utcOrLocal(text));
    return Any.of(LocalDateTime.parse(text, formatter));
}

private Any parseInstant(MapperConfig config, Kind kind, string text, DateTimeFormatter formatter, bool custom)
{
    if (kind == Kind.instant)
        return Any.of(custom ? OffsetDateTime.parse(text, formatter).toInstant() : Instant.parse(text));
    if (kind == Kind.offsetDateTime)
        return Any.of(adjust(config, OffsetDateTime.parse(text, formatter)));
    return Any.of(adjust(config, ZonedDateTime.parse(text, formatter)));
}

// An instant as an Instant, or as an OffsetDateTime or ZonedDateTime at UTC.
private Any instantAs(Kind kind, Instant instant)
{
    if (kind == Kind.instant)
        return Any.of(instant);
    if (kind == Kind.offsetDateTime)
        return Any.of(instant.atOffset(ZoneOffset.UTC));
    return Any.of(instant.atZone(ZoneOffset.UTC.toZoneId()));
}

// A local date-time from ISO text: an instant read at UTC when it ends in 'Z'.
private LocalDateTime utcOrLocal(string text)
{
    if (text[$ - 1] == 'Z')
        return LocalDateTime.ofInstant(Instant.parse(text), ZoneOffset.UTC.toZoneId());
    return LocalDateTime.parse(text, DateTimeFormatter.ISO_LOCAL_DATE_TIME);
}

private OffsetDateTime adjust(MapperConfig config, OffsetDateTime value)
{
    if (!config.isEnabled(DateTimeFeature.ADJUST_DATES_TO_CONTEXT_TIME_ZONE))
        return value;
    return value.withOffsetSameInstant(ZoneOffset.UTC);
}

private ZonedDateTime adjust(MapperConfig config, ZonedDateTime value)
{
    if (!config.isEnabled(DateTimeFeature.ADJUST_DATES_TO_CONTEXT_TIME_ZONE))
        return value;
    return value.toInstant().atZone(ZoneOffset.UTC.toZoneId());
}

// Text a timestamp could be: digits with an optional leading '-' and at most one '.'.
private bool numeric(string text) pure nothrow @nogc
{
    size_t periods;
    foreach (i, c; text)
    {
        if (c == '.')
            ++periods;
        else if (!(c >= '0' && c <= '9') && !(c == '-' && i == 0))
            return false;
    }
    return periods <= 1 && text != "-" && text != ".";
}

// A decimal number of seconds, the fraction truncated to nanoseconds; or of milliseconds when not `seconds`.
private Instant readDecimal(string text, bool seconds) pure nothrow
{
    const negative = text[0] == '-';
    long whole, nanos;
    size_t i = negative ? 1 : 0;
    for (; i < text.length && text[i] != '.'; ++i)
        whole = whole * 10 + (text[i] - '0');
    if (i < text.length)
    {
        long scale = 100_000_000;
        foreach (c; text[i + 1 .. $])
        {
            nanos += (c - '0') * scale;
            scale /= 10;
        }
    }
    if (!seconds)
        return Instant.ofEpochMilli(negative ? -whole : whole);
    return negative ? Instant.ofEpochSecond(-whole, -nanos) : Instant.ofEpochSecond(whole, nanos);
}

private Any readNumber(MapperConfig config, JsonParser p, Kind kind, string type, bool integral)
{
    const text = p.getString();
    const asSeconds = !integral || config.isEnabled(DateTimeFeature.READ_DATE_TIMESTAMPS_AS_NANOSECONDS);
    switch (kind)
    {
    case Kind.localDate:
        if (integral)
            return Any.of(LocalDate.ofEpochDay(p.getLongValue()));
        break;
    case Kind.localTime:
    case Kind.localDateTime:
        throw new MismatchedInputException("raw timestamp (" ~ text ~ ") not allowed for `" ~ javaName(
                type) ~ "`: need additional information such as an offset or time-zone (see class Javadocs)",
                type, p.currentLocation());
    case Kind.instant:
    case Kind.offsetDateTime:
    case Kind.zonedDateTime:
        return instantAs(kind,
                readDecimal(text, asSeconds));
    case Kind.duration:
        const instant = readDecimal(text, true);
        return Any.of(Duration.ofSeconds(instant.getEpochSecond(), instant.getNano()));
    default:
        break;
    }
    import flint.jackson.databind.deser : mismatch;

    throw mismatch(type, p.currentToken());
}

// [year, month, day], [hour, minute, second?, fraction?] or both, as the timestamp writers produce them.
private Any readArray(MapperConfig config, JsonParser p, Kind kind, string type)
{
    long[7] parts;
    size_t count;
    for (auto t = p.nextToken(); t != JsonToken.END_ARRAY; t = p.nextToken())
    {
        if (t != JsonToken.VALUE_NUMBER_INT || count == parts.length)
            throw new MismatchedInputException("Unexpected token (" ~ (t == JsonToken.VALUE_NUMBER_INT
                    ? "VALUE_NUMBER_INT" : "non-integer") ~ "), expected END_ARRAY: Expected array to end",
                    type, p.currentLocation());
        parts[count++] = p.getLongValue();
    }
    const nanos = config.isEnabled(DateTimeFeature.READ_DATE_TIMESTAMPS_AS_NANOSECONDS);
    try
    {
        if (kind == Kind.localDate && count == 3)
            return Any.of(LocalDate.of(cast(int) parts[0], cast(int) parts[1], cast(int) parts[2]));
        if (kind == Kind.localTime && count >= 2 && count <= 4)
            return Any.of(arrayTime(parts[0 .. count], nanos));
        if (kind == Kind.localDateTime && count >= 5)
            return Any.of(LocalDateTime.of(LocalDate.of(cast(int) parts[0], cast(int) parts[1],
                    cast(int) parts[2]), arrayTime(parts[3 .. count], nanos)));
    }
    catch (DateTimeException e)
        throw new MismatchedInputException(e.msg, type, p.currentLocation());
    throw new MismatchedInputException("Unexpected number of elements in the array for `" ~ javaName(type) ~ "`",
            type, p.currentLocation());
}

private LocalTime arrayTime(scope const(long)[] parts, bool nanos)
{
    const second = parts.length > 2 ? cast(int) parts[2] : 0;
    const fraction = parts.length > 3 ? parts[3] : 0;
    return LocalTime.of(cast(int) parts[0], cast(int) parts[1], second, cast(int)(nanos ? fraction
            : fraction * 1_000_000));
}
