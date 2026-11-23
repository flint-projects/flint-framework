/++
`java.util.TimeZone` and `SimpleTimeZone` (clean room, from the Java SE specification), for `Calendar` and
`java.text.SimpleDateFormat`.

`getTimeZone` resolves the IDs that need no zone data: `UTC`, `GMT`, `Etc/UTC`, `Etc/GMT`, and Java's custom IDs
`GMT±h`, `GMT±hh`, `GMT±hhmm` and `GMT±h[h]:mm`, normalized as Java does ("GMT+2" is "GMT+02:00"). The default zone
is UTC, as `ZoneId.systemDefault()` and `Date.toString` are in Flint. Display names are English.

Deviations: a region ID ("Europe/Paris", "PST") needs the time-zone database, which Flint has not ported, so
`getTimeZone` throws `IllegalArgumentException` rather than falling back to GMT as Java does for an unknown ID:
a silent GMT would be a wrong offset. Zones have no daylight saving time. The six-argument `getOffset` and
`getAvailableIDs` are not provided.
+/
module flint.java.util.timezone;

import flint.java.lang : IllegalArgumentException;
import flint.java.util.date : Date;

@safe:

/// Java's `TimeZone`: an offset from UTC and an ID.
abstract class TimeZone
{
    /// `getDisplayName` style: an abbreviation such as "UTC".
    enum int SHORT = 0;
    /// `getDisplayName` style: a full name such as "Coordinated Universal Time".
    enum int LONG = 1;

    private string ID;

    /// The offset from UTC, in milliseconds, without daylight saving time.
    abstract int getRawOffset() const pure nothrow @nogc;

    /// Set the offset from UTC, in milliseconds.
    abstract void setRawOffset(int offsetMillis) pure nothrow @nogc;

    /// Whether this zone has daylight saving time.
    abstract bool useDaylightTime() const pure nothrow @nogc;

    /// Whether `date` is in daylight saving time in this zone.
    abstract bool inDaylightTime(const Date date) const pure nothrow @nogc;

    /// The offset from UTC at `date` (milliseconds since the epoch), daylight saving included. Flint's zones have
    /// no transitions, so `date` does not change the result; a port of the zone database must make it count.
    int getOffset(long date) const pure nothrow @nogc
    {
        return getRawOffset() + (useDaylightTime() ? getDSTSavings() : 0);
    }

    /// The daylight saving amount, in milliseconds: an hour when the zone has daylight saving time.
    int getDSTSavings() const pure nothrow @nogc
    {
        return useDaylightTime() ? 3_600_000 : 0;
    }

    /// This zone's ID.
    string getID() const pure nothrow @nogc
    {
        return ID;
    }

    /// Set this zone's ID; the offset is unchanged.
    void setID(string ID) pure nothrow @nogc
    {
        this.ID = ID;
    }

    /// The long standard-time name, in English.
    string getDisplayName() const pure nothrow
    {
        return getDisplayName(false, LONG);
    }

    /// The name in `style` (`SHORT` or `LONG`), in English: "UTC" and "Coordinated Universal Time", "GMT" and
    /// "Greenwich Mean Time", otherwise the normalized custom ID ("GMT+05:30"), as Java prints a zone without names.
    string getDisplayName(bool daylight, int style) const pure nothrow
    {
        if (style != SHORT && style != LONG)
            return null;
        switch (ID)
        {
        case "UTC":
        case "Etc/UTC":
            return style == SHORT ? "UTC" : "Coordinated Universal Time";
        case "GMT":
        case "Etc/GMT":
            return style == SHORT ? "GMT" : "Greenwich Mean Time";
        default:
            return customID(getRawOffset() + (daylight ? getDSTSavings() : 0));
        }
    }

    /// Whether `other` has the same offset and daylight saving rules.
    bool hasSameRules(const TimeZone other) const pure nothrow @nogc
    {
        return other !is null && getRawOffset() == other.getRawOffset() && useDaylightTime() == other.useDaylightTime();
    }

    /// The zone for `ID`. Throws `IllegalArgumentException` for an ID that needs the zone database (deviation).
    static TimeZone getTimeZone(string ID)
    {
        switch (ID)
        {
        case "UTC":
        case "GMT":
        case "Etc/UTC":
        case "Etc/GMT":
            return new SimpleTimeZone(0, ID);
        default:
            break;
        }
        const offset = parseCustomOffset(ID);
        if (offset == int.min)
            throw new IllegalArgumentException("Time zone \"" ~ ID ~ "\" needs the time-zone database, which Flint "
                    ~ "has not ported: use UTC, GMT or a GMT+hh:mm offset");
        return new SimpleTimeZone(offset, customID(offset));
    }

    /// The default zone: UTC.
    static TimeZone getDefault() pure nothrow
    {
        return new SimpleTimeZone(0, "UTC");
    }
}

/// Java's `SimpleTimeZone`, without daylight saving rules: a fixed offset with an ID.
class SimpleTimeZone : TimeZone
{
    private int rawOffset;

    /// A zone `rawOffset` milliseconds from UTC, named `ID`.
    this(int rawOffset, string ID) pure nothrow @nogc
    {
        this.rawOffset = rawOffset;
        setID(ID);
    }

    override int getRawOffset() const pure nothrow @nogc
    {
        return rawOffset;
    }

    override void setRawOffset(int offsetMillis) pure nothrow @nogc
    {
        rawOffset = offsetMillis;
    }

    override bool useDaylightTime() const pure nothrow @nogc
    {
        return false;
    }

    override bool inDaylightTime(const Date date) const pure nothrow @nogc
    {
        return false;
    }

    /// A copy of this zone.
    SimpleTimeZone clone() const pure nothrow
    {
        return new SimpleTimeZone(rawOffset, getID());
    }
}

// Java's custom ID "GMT" sign hours [[:] minutes]: hours of one or two digits, minutes of two, the colon optional only
// after two hour digits. The offset in milliseconds, or int.min when `ID` is not a custom ID.
private int parseCustomOffset(string ID) pure nothrow @nogc
{
    if (ID.length < 5 || ID[0 .. 3] != "GMT" || (ID[3] != '+' && ID[3] != '-'))
        return int.min;
    const minutes = customMinutes(ID[4 .. $]);
    if (minutes < 0)
        return int.min;
    return (ID[3] == '-' ? -1 : 1) * minutes * 60_000;
}

// The hours and minutes after a custom ID's sign, in minutes; -1 when they are not Java's syntax.
private int customMinutes(string rest) pure nothrow @nogc
{
    size_t colon = rest.length;
    foreach (i, c; rest)
        if (c == ':')
            colon = i;
    const hasColon = colon < rest.length;
    const split = hasColon ? colon : rest.length == 4 ? 2 : rest.length;
    const minuteText = rest[hasColon ? colon + 1 : split .. $];
    const hours = digits(rest[0 .. split]);
    const minutes = minuteText.length ? digits(minuteText) : 0;
    if (split > 2 || (hasColon && minuteText.length != 2) || hours < 0 || minutes < 0)
        return -1;
    return hours > 23 || minutes > 59 ? -1 : hours * 60 + minutes;
}

// The value of one or more ASCII digits; -1 for anything else.
private int digits(scope const(char)[] text) pure nothrow @nogc
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

// "GMT+hh:mm" for an offset in milliseconds, the minutes truncated.
private string customID(int offset) pure nothrow
{
    const minutes = (offset < 0 ? -offset : offset) / 60_000;
    char[9] id = "GMT+00:00";
    id[3] = offset < 0 ? '-' : '+';
    id[4] = cast(char)('0' + minutes / 600);
    id[5] = cast(char)('0' + minutes / 60 % 10);
    id[7] = cast(char)('0' + minutes % 60 / 10);
    id[8] = cast(char)('0' + minutes % 10);
    return id[].idup;
}
