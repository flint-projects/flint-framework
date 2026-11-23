/++
`java.util.Date` (clean room, from the Java SE specification): an instant with millisecond precision, as Spring
Boot's `DefaultErrorAttributes` timestamps an error (`new Date()`).

Only the non-deprecated API: the constructors `Date()` and `Date(long)`, `getTime`/`setTime`, `before`/`after`,
`equals`/`hashCode`/`compareTo`, `toString`, `clone`, and `from(Instant)`/`toInstant()`. The deprecated
field-based constructors and accessors (`getYear`, `getMonth`, `parse`, ...) are left out, as Java's
documentation directs callers to `Calendar` and `java.time`.

Deviation: `toString` formats in the default time-zone, which is UTC in Flint (`ZoneId.systemDefault()`), with the
proleptic Gregorian calendar; Java switches to the Julian calendar before 1582-10-15.
+/
module flint.java.util.date;

import flint.java.lang : Comparable, JavaObject;

@safe:

/// Java's `java.util.Date`: milliseconds since 1970-01-01T00:00:00Z.
class Date : Comparable!Date
{
    private long fastTime;

    /// The current time, to the millisecond (`System.currentTimeMillis()`).
    this() nothrow @nogc
    {
        import flint.engine.aot.clock : currentTimeMillis;

        this(currentTimeMillis());
    }

    /// The instant `date` milliseconds after 1970-01-01T00:00:00Z ("the epoch").
    this(long date) pure nothrow @nogc
    {
        fastTime = date;
    }

    /// The `Date` of `instant`. Throws `IllegalArgumentException` when it is too large for epoch milliseconds.
    static Date from(imported!"flint.java.time".Instant instant)
    {
        import flint.java.lang : IllegalArgumentException;

        const seconds = instant.getEpochSecond();
        if (seconds > long.max / 1000 || seconds < long.min / 1000)
            throw new IllegalArgumentException("java.lang.ArithmeticException: long overflow");
        return new Date(instant.toEpochMilli());
    }

    /// This date as an `Instant`.
    imported!"flint.java.time".Instant toInstant() const pure nothrow @nogc
    {
        import flint.java.time : Instant;

        return Instant.ofEpochMilli(fastTime);
    }

    /// Milliseconds since the epoch.
    long getTime() const pure nothrow @nogc
    {
        return fastTime;
    }

    /// Set this date to `time` milliseconds since the epoch.
    void setTime(long time) pure nothrow @nogc
    {
        fastTime = time;
    }

    /// Whether this date is strictly earlier than `when`.
    bool before(const Date when) const pure nothrow @nogc
    {
        return fastTime < when.fastTime;
    }

    /// Whether this date is strictly later than `when`.
    bool after(const Date when) const pure nothrow @nogc
    {
        return fastTime > when.fastTime;
    }

    /// Whether `obj` is a `Date` for the same millisecond.
    bool equals(Object obj)
    {
        auto other = cast(Date) obj;
        return other !is null && other.fastTime == fastTime;
    }

    /// `(int)(time ^ (time >>> 32))`, as Java specifies.
    int hashCode() const pure nothrow @nogc
    {
        return cast(int)(fastTime ^ (cast(ulong) fastTime >>> 32));
    }

    /// Orders by the millisecond.
    int compareTo(Date anotherDate)
    {
        const other = anotherDate.fastTime;
        return fastTime < other ? -1 : fastTime == other ? 0 : 1;
    }

    mixin JavaObject;

    /// A copy of this date.
    Date clone() const pure nothrow
    {
        return new Date(fastTime);
    }

    /// `dow mon dd hh:mm:ss zzz yyyy`, such as `Mon Nov 23 14:51:00 UTC 2026`, in the default time-zone.
    override string toString() const pure nothrow
    {
        import flint.engine.aot.text : decimal;

        static immutable string[7] days = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"];
        static immutable string[12] months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
        ];
        const day = floorDiv(fastTime, 86_400_000);
        const millisOfDay = fastTime - day * 86_400_000;
        const secondOfDay = millisOfDay / 1000;
        const civil = civilFromDays(day);
        return days[cast(size_t) floorMod(day, 7)] ~ " " ~ months[civil.month - 1] ~ " " ~ twoDigits(
                civil.day) ~ " " ~ twoDigits(secondOfDay / 3600) ~ ":" ~ twoDigits(
                secondOfDay / 60 % 60) ~ ":" ~ twoDigits(secondOfDay % 60) ~ " UTC " ~ decimal(civil.year);
    }
}

private struct Civil
{
    long year;
    int month;
    int day;
}

/// The proleptic Gregorian date `days` after 1970-01-01 (Howard Hinnant's `civil_from_days`).
private Civil civilFromDays(long days) pure nothrow @nogc
{
    const z = days + 719_468;
    const era = floorDiv(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const day = cast(int)(doy - (153 * mp + 2) / 5 + 1);
    const month = cast(int)(mp < 10 ? mp + 3 : mp - 9);
    return Civil(yoe + era * 400 + (month <= 2 ? 1 : 0), month, day);
}

private long floorDiv(long x, long y) pure nothrow @nogc
{
    const q = x / y;
    return (x % y != 0 && ((x < 0) != (y < 0))) ? q - 1 : q;
}

private long floorMod(long x, long y) pure nothrow @nogc
{
    return x - floorDiv(x, y) * y;
}

private string twoDigits(long value) pure nothrow
{
    return [cast(char)('0' + value / 10), cast(char)('0' + value % 10)];
}
