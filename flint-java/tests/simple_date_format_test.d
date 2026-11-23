/++
Flint tests: `SimpleDateFormat`, `GregorianCalendar` and `TimeZone` against JDK 21. `golden/dates.tsv` is the
file flint-jackson-databind/tests/golden/GoldenDates.java writes: Jackson 3.1.8's `java.util.Date` cases.
Jackson formats and parses a `@JsonFormat` pattern with `new SimpleDateFormat(pattern, locale)` in the format's
zone, so every pattern case is a JDK `SimpleDateFormat` result; these tests replay those cases here.
+/
module flint.java.simple_date_format_test;

import flint.java.lang : IllegalArgumentException;
import flint.java.text : ParseException, SimpleDateFormat;
import flint.java.util : Calendar, Date, GregorianCalendar, Locale, TimeZone;

@safe:

// A golden format spec of only SimpleDateFormat settings: pattern, time zone, locale and leniency.
private struct Spec
{
    bool usable;
    string pattern;
    string zone = "UTC";
    string language = "en";
    string lenient;
}

private Spec specOf(string text)
{
    import std.array : split;
    import std.string : indexOf;

    Spec spec;
    foreach (part; text.split(';'))
    {
        const eq = part.indexOf('=');
        if (eq < 0)
            return Spec.init; // a Jackson feature
        const value = part[eq + 1 .. $];
        switch (part[0 .. eq])
        {
        case "pattern":
            spec.pattern = value;
            break;
        case "tz":
            spec.zone = value;
            break;
        case "locale":
            spec.language = value[0 .. 2];
            break;
        case "lenient":
            spec.lenient = value;
            break;
        default:
            return Spec.init; // a shape
        }
    }
    spec.usable = spec.pattern.length > 0;
    return spec;
}

private SimpleDateFormat formatOf(Spec spec)
{
    auto format = new SimpleDateFormat(spec.pattern, Locale(spec.language));
    format.setTimeZone(TimeZone.getTimeZone(spec.zone));
    if (spec.lenient.length)
        format.setLenient(spec.lenient == "true");
    return format;
}

private string formatted(Spec spec, long millis)
{
    try
        return "\"" ~ formatOf(spec).format(new Date(millis)) ~ "\"";
    catch (IllegalArgumentException e)
        return "!IllegalArgumentException: " ~ e.msg;
}

// The parse outcome in the golden's terms: the millisecond, or a failure for Jackson's "expected format" error.
private string parsed(Spec spec, string text)
{
    import std.conv : to;

    try
        return formatOf(spec).parse(text).getTime().to!string;
    catch (ParseException)
        return "fails";
    catch (IllegalArgumentException e)
        return "!IllegalArgumentException: " ~ e.msg;
}

@("SimpleDateFormat: the golden pattern writes and reads agree with JDK 21")
unittest
{
    import std.array : split;
    import std.conv : to;
    import std.string : indexOf, lineSplitter, strip;

    size_t writes, reads, refused;
    string failures;
    foreach (line; import("dates.tsv").lineSplitter)
    {
        const row = line.split("\t");
        const spec = specOf(row[1]);
        if (!spec.usable || row[0] == "writekey" || row[0] == "readkey")
            continue;
        if (spec.language != "en" && spec.pattern == "EEE")
        {
            // French day names: Flint refuses them (deviation) rather than print English.
            assert(formatted(spec, 0).indexOf("English names only") > 0);
            ++refused;
            continue;
        }
        if (row[0] == "write")
        {
            const got = formatted(spec, row[2].to!long);
            ++writes;
            if (got != row[3])
                failures ~= "  " ~ row[1] ~ " " ~ row[2] ~ ": JDK " ~ row[3] ~ ", Flint " ~ got ~ "\n";
            continue;
        }
        // Jackson trims the text, reads "" as null, and reports any ParseException as "expected format".
        if (row[2].length < 2 || row[2][0] != '"' || row[2].strip() == `""`)
            continue;
        const text = row[2][1 .. $ - 1].strip();
        const expected = row[3].indexOf("expected format") >= 0 ? "fails" : row[3];
        const got = parsed(spec, text);
        ++reads;
        if (got != expected)
            failures ~= "  read " ~ row[1] ~ " " ~ row[2] ~ ": JDK " ~ expected ~ ", Flint " ~ got ~ "\n";
    }
    assert(failures.length == 0, "SimpleDateFormat cases that differ from JDK 21:\n" ~ failures);
    assert(writes == 900 && reads == 75 && refused == 1);
}

@("GregorianCalendar: Julian before 1582-10-15, Java's fields, strict rejection and add")
unittest
{
    auto cal = new GregorianCalendar(TimeZone.getTimeZone("UTC"));
    cal.setTimeInMillis(-12_219_292_800_001L); // the millisecond before the cutover
    assert(cal.get(Calendar.YEAR) == 1582 && cal.get(Calendar.MONTH) == Calendar.OCTOBER);
    assert(cal.get(Calendar.DAY_OF_MONTH) == 4 && cal.get(Calendar.DAY_OF_WEEK) == Calendar.THURSDAY);
    cal.setTimeInMillis(-62_198_755_200_000L);
    assert(cal.get(Calendar.ERA) == GregorianCalendar.BC && cal.get(Calendar.YEAR) == 2);

    // Lenient: month 12 is January of the next year; strict: the field is rejected by name.
    cal.clear();
    cal.set(2010, 12, 45, 25, 61, 61);
    assert(cal.getTimeInMillis() == 1_297_735_321_000L);
    cal.setLenient(false);
    cal.clear();
    cal.set(2010, 12, 1);
    try
    {
        cal.getTimeInMillis();
        assert(false, "a strict calendar must reject MONTH 12");
    }
    catch (IllegalArgumentException e)
        assert(e.msg == "MONTH", e.msg);
    cal.clear();
    cal.set(2010, Calendar.FEBRUARY, 30);
    try
    {
        cal.getTimeInMillis();
        assert(false, "a strict calendar must reject February 30");
    }
    catch (IllegalArgumentException e)
        assert(e.msg == "MONTH: 1 -> 2", e.msg); // JDK 21 reports the first field that changed

    // Adding months keeps the day within the month; the week year follows the en_US weeks.
    cal.setLenient(true);
    cal.setTime(new Date(1_264_896_000_000L)); // 2010-01-31
    cal.add(Calendar.MONTH, 1);
    assert(cal.get(Calendar.MONTH) == Calendar.FEBRUARY && cal.get(Calendar.DAY_OF_MONTH) == 28);
    cal.setTime(new Date(1_293_753_600_000L)); // 2010-12-31, a Friday in week 1 of 2011
    assert(cal.get(Calendar.WEEK_OF_YEAR) == 1 && (cast(GregorianCalendar) cal).getWeekYear() == 2011);
}

@("TimeZone: fixed offsets and Java's custom IDs; a region ID needs the zone database")
unittest
{
    assert(TimeZone.getDefault().getID() == "UTC");
    assert(TimeZone.getDefault().getDisplayName(false, TimeZone.SHORT) == "UTC");
    assert(new Date(0).toString() == "Thu Jan 01 00:00:00 UTC 1970"); // Date.toString agrees with the default
    auto zone = TimeZone.getTimeZone("GMT+2");
    assert(zone.getID() == "GMT+02:00" && zone.getRawOffset() == 7_200_000);
    assert(TimeZone.getTimeZone("GMT-0530").getRawOffset() == -19_800_000);
    assert(TimeZone.getTimeZone("GMT").getDisplayName() == "Greenwich Mean Time");
    assert(zone.getDisplayName(false, TimeZone.SHORT) == "GMT+02:00");
    foreach (id; ["Europe/Paris", "PST", "GMT+24", "GMT+5:3", "GMT+530"])
        try
        {
            TimeZone.getTimeZone(id);
            assert(false, id);
        }
        catch (IllegalArgumentException e)
        {
        }
}

@("SimpleDateFormat: Java's pattern errors, and DateFormat.parse's ParseException")
unittest
{
    foreach (bad; ["yyyy-q", "yyyy'T", "XXXX"])
        try
        {
            new SimpleDateFormat(bad);
            assert(false, bad);
        }
        catch (IllegalArgumentException e)
        {
        }
    auto format = new SimpleDateFormat("yyyy-MM-dd");
    try
    {
        format.parse("2010/01/01");
        assert(false);
    }
    catch (ParseException e)
        assert(e.getMessage() == `Unparseable date: "2010/01/01"` && e.getErrorOffset() == 4, e.msg);
    assert(format.toPattern() == "yyyy-MM-dd" && format.format(format.parse("2010-01-01x")) == "2010-01-01");
}
