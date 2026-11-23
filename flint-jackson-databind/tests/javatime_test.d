/// Jackson 3.1.8's java.time support under Spring Boot 4.2's default mapper: each case is the D twin of a case in
/// tests/golden/GoldenJavaTime.java, whose results the real Jackson wrote to tests/golden/javatime.tsv.
module javatime_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.annotation : JsonFormat;
import flint.jackson.core : JacksonException;
import flint.jackson.databind : JsonMapper;
import flint.jackson.databind.cfg : DateTimeFeature;
import flint.jackson.databind.ext.javatime : decimalSeconds;
import flint.java.time : Duration, Instant, LocalDate, LocalDateTime, LocalTime, OffsetDateTime, ZoneId, ZoneOffset,
    ZonedDateTime;
import flint.java.util : ArrayList, List;

@safe:

private final class Event
{
    LocalDate date;
    LocalTime time;
    LocalDateTime when;
    Instant instant;
    OffsetDateTime offset;
    ZonedDateTime zoned;
    Duration timeout;
    ZoneOffset zoneOffset;
    ZoneId zone;

    this()
    {
        date = LocalDate.of(2010, 9, 7);
        time = LocalTime.of(14, 5, 9, 120_000_000);
        when = LocalDateTime.of(2010, 9, 7, 14, 5);
        instant = Instant.ofEpochSecond(1_700_000_000L, 5_000_000);
        offset = OffsetDateTime.of(2010, 9, 7, 14, 5, 9, 0, ZoneOffset.ofHours(2));
        zoned = ZonedDateTime.of(2010, 9, 7, 14, 5, 9, 0, ZoneId.of("UTC"));
        timeout = Duration.ofSeconds(90);
        zoneOffset = ZoneOffset.ofHours(-5);
        zone = ZoneId.of("UTC");
    }

    override string toString() const
    {
        return date.toString() ~ " " ~ time.toString() ~ " " ~ when.toString() ~ " " ~ instant.toString() ~ " "
            ~ offset.toString() ~ " " ~ zoned.toString() ~ " " ~ timeout.toString() ~ " " ~ zoneOffset.toString()
            ~ " " ~ zone.toString();
    }
}

private final class Formatted
{
    @JsonFormat(pattern: "dd/MM/yyyy") LocalDate date;
    @JsonFormat(pattern: "yyyy-MM-dd HH:mm:ss") LocalDateTime when;
    @JsonFormat(pattern: "HH:mm") LocalTime time;
    @JsonFormat(pattern: "yyyy-MM-dd'T'HH:mm:ss.SSSXXX") OffsetDateTime offset;
    @JsonFormat(shape: JsonFormat.Shape.NUMBER) LocalDate epochDay;
    @JsonFormat(shape: JsonFormat.Shape.STRING) Duration asString;

    this()
    {
        date = LocalDate.of(2010, 9, 7);
        when = LocalDateTime.of(2010, 9, 7, 14, 5, 9);
        time = LocalTime.of(14, 5, 9);
        offset = OffsetDateTime.of(2010, 9, 7, 14, 5, 9, 120_000_000, ZoneOffset.ofHours(2));
        epochDay = LocalDate.of(2010, 9, 7);
        asString = Duration.ofMillis(1500);
    }

    override string toString() const
    {
        return date.toString() ~ " " ~ when.toString() ~ " " ~ time.toString() ~ " " ~ offset.toString() ~ " "
            ~ epochDay.toString() ~ " " ~ asString.toString();
    }
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    t.add(descriptorOf!Event());
    t.add(descriptorOf!Formatted());
    t.add(descriptorOf!(List!LocalDate)());
    t.add(descriptorOf!(ArrayList!LocalDate)());
    return t;
}

private JsonMapper mapper(string mode)
{
    auto b = JsonMapper.builder().findAndAddModules().descriptors(table());
    switch (mode)
    {
    case "stamps":
        b.enable(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS);
        break;
    case "millis":
        b.enable(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS, DateTimeFeature.WRITE_DURATIONS_AS_TIMESTAMPS);
        b.disable(DateTimeFeature.WRITE_DATE_TIMESTAMPS_AS_NANOSECONDS);
        break;
    case "durations":
        b.enable(DateTimeFeature.WRITE_DURATIONS_AS_TIMESTAMPS);
        break;
    case "zone_ids":
        b.enable(DateTimeFeature.WRITE_DATES_WITH_ZONE_ID);
        break;
    default:
        break;
    }
    return b.build();
}

// The value each `write` case of GoldenJavaTime.java serializes, and its mapper.
private string written(string name)
{
    import std.string : indexOf;

    const cut = name[0 .. 4] == "zone" ? 8 : name.indexOf('_');
    const mode = cut < 0 ? "boot" : name[0 .. cut];
    auto m = mapper(mode);
    switch (name[cut + 1 .. $])
    {
    case "event":
        return m.writeValueAsString(new Event());
    case "formatted":
        return m.writeValueAsString(new Formatted());
    case "list":
        List!LocalDate list = new ArrayList!LocalDate();
        list.add(LocalDate.of(2010, 9, 7));
        list.add(LocalDate.of(2024, 2, 29));
        return m.writeValueAsString(list);
    case "time_whole":
        return m.writeValueAsString(LocalTime.of(10, 15));
    case "time_seconds":
        return m.writeValueAsString(LocalTime.of(10, 15, 30));
    case "datetime_whole":
        return m.writeValueAsString(LocalDateTime.of(2013, 1, 1, 9, 30));
    case "instant_whole":
        return m.writeValueAsString(Instant.ofEpochSecond(1_700_000_000L));
    case "instant_neg":
        return m.writeValueAsString(Instant.ofEpochSecond(-1L, 999_999_999));
    case "time":
        return m.writeValueAsString(LocalTime.of(10, 15, 30, 123_456_789));
    case "neg", "duration_neg":
        return m.writeValueAsString(Duration.ofMillis(-1500));
    case "zero":
        return m.writeValueAsString(Duration.ZERO);
    case "nano":
        return m.writeValueAsString(Duration.ofNanos(1));
    case "instant_epoch":
        return m.writeValueAsString(Instant.EPOCH);
    case "instant_small":
        return m.writeValueAsString(Instant.ofEpochSecond(0, 5));
    case "instant_milli":
        return m.writeValueAsString(Instant.ofEpochSecond(0, 123_000_000));
    case "instant_big":
        return m.writeValueAsString(Instant.ofEpochSecond(253_402_300_800L));
    case "datetime":
        return m.writeValueAsString(LocalDateTime.of(2013, 1, 1, 9, 30, 0, 1_000_000));
    default:
        assert(false, name);
    }
}

private string shown(Any value, string type)
{
    if (value.isNull())
        return "null";
    switch (type)
    {
    case "LocalDate":
        return value.get!LocalDate().toString();
    case "LocalTime":
        return value.get!LocalTime().toString();
    case "LocalDateTime":
        return value.get!LocalDateTime().toString();
    case "Instant":
        return value.get!Instant().toString();
    case "OffsetDateTime":
        return value.get!OffsetDateTime().toString();
    case "ZonedDateTime":
        return value.get!ZonedDateTime().toString();
    case "Duration":
        return value.get!Duration().toString();
    case "ZoneOffset":
        return value.get!ZoneOffset().toString();
    case "ZoneId":
        return value.get!ZoneId().toString();
    case "Event":
        return value.get!Event().toString();
    default:
        return value.get!Formatted().toString();
    }
}

private string read(string type, string json)
{
    const fqn = type == "Event" ? descriptorOf!Event().name : type == "Formatted" ? descriptorOf!Formatted().name
        : "flint.java.time." ~ type;
    try
        return shown(mapper("boot").readValue(json, fqn), type);
    catch (JacksonException e)
        return "!" ~ e.getOriginalMessage();
}

@("javatime: writes, timestamps, @JsonFormat and reads match Jackson 3.1.8 under Boot's defaults (javatime.tsv)")
unittest
{
    import std.array : split;
    import std.string : lineSplitter;

    size_t writes, reads;
    foreach (line; import("javatime.tsv").lineSplitter)
    {
        const row = line.split("\t");
        if (row[0] == "write")
        {
            const got = written(row[1]);
            assert(got == row[3], row[1] ~ "\nflint:   " ~ got ~ "\njackson: " ~ row[3]);
            ++writes;
        }
        else
        {
            const got = read(row[1].split(":")[1], row[2]);
            assert(got == row[3], row[1] ~ " " ~ row[2] ~ "\nflint:   " ~ got ~ "\njackson: " ~ row[3]);
            ++reads;
        }
    }
    assert(writes == 23 && reads == 59);
}

@("javatime: DecimalUtils seconds print as BigDecimal at scale 9")
unittest
{
    assert(decimalSeconds(0, 0) == "0.0");
    assert(decimalSeconds(0, 500) == "5.00E-7");
    assert(decimalSeconds(0, 1_000_000) == "0.001000000");
    assert(decimalSeconds(-2, 500_000_000) == "-1.500000000");
    assert(decimalSeconds(5, 0) == "5.000000000");
}
