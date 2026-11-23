/++
`java.util.Calendar` and `GregorianCalendar` (clean room, from the Java SE specification), for `java.util.Date`
arithmetic and `java.text.SimpleDateFormat`.

The calendar is Java's default `GregorianCalendar`: Gregorian from 1582-10-15, Julian before, so
`new Date(-62135596800000L)` is 0001-01-03 AD. Fields follow Java's numbering (`MONTH` counts from 0) and its
resolution: the most recently set group of date fields decides the date (month and day, day of year, or week of
year and day of week), and `HOUR_OF_DAY` competes with `HOUR` and `AM_PM`. A lenient calendar carries fields out of
range into the next ones (month 12 is January of the next year); a strict one rejects them with Java's
`IllegalArgumentException` (the field name, or "MONTH: 12 -> 0" when the computed value differs). Weeks follow the
`en_US` rules: they start on Sunday, and week 1 is the week holding January 1.

Deviations: zones are `flint.java.util.TimeZone`'s fixed offsets (the zone database is not ported), so
`DST_OFFSET` is always 0. `getDisplayName` and the localized `getInstance(Locale)` are not provided; calendars are
English-only and `en_US`-weeked whatever the default locale. `roll` and `getActualMaximum` are not provided.
+/
module flint.java.util.calendar;

import flint.java.lang : IllegalArgumentException;
import flint.java.util.date : Date;
import flint.java.util.timezone : TimeZone;

@safe:

/// Java's `Calendar`: an instant and its calendar fields in a time zone.
abstract class Calendar
{
    enum int ERA = 0; ///
    enum int YEAR = 1; ///
    enum int MONTH = 2; /// 0 for January
    enum int WEEK_OF_YEAR = 3; ///
    enum int WEEK_OF_MONTH = 4; ///
    enum int DATE = 5; /// `DAY_OF_MONTH`
    enum int DAY_OF_MONTH = 5; ///
    enum int DAY_OF_YEAR = 6; ///
    enum int DAY_OF_WEEK = 7; /// 1 for Sunday
    enum int DAY_OF_WEEK_IN_MONTH = 8; ///
    enum int AM_PM = 9; ///
    enum int HOUR = 10; /// 0 to 11
    enum int HOUR_OF_DAY = 11; /// 0 to 23
    enum int MINUTE = 12; ///
    enum int SECOND = 13; ///
    enum int MILLISECOND = 14; ///
    enum int ZONE_OFFSET = 15; /// milliseconds
    enum int DST_OFFSET = 16; /// milliseconds
    enum int FIELD_COUNT = 17; ///

    enum int SUNDAY = 1; ///
    enum int MONDAY = 2; ///
    enum int TUESDAY = 3; ///
    enum int WEDNESDAY = 4; ///
    enum int THURSDAY = 5; ///
    enum int FRIDAY = 6; ///
    enum int SATURDAY = 7; ///

    enum int JANUARY = 0; ///
    enum int FEBRUARY = 1; ///
    enum int MARCH = 2; ///
    enum int APRIL = 3; ///
    enum int MAY = 4; ///
    enum int JUNE = 5; ///
    enum int JULY = 6; ///
    enum int AUGUST = 7; ///
    enum int SEPTEMBER = 8; ///
    enum int OCTOBER = 9; ///
    enum int NOVEMBER = 10; ///
    enum int DECEMBER = 11; ///

    enum int AM = 0; ///
    enum int PM = 1; ///

    /// The calendar field values.
    protected int[FIELD_COUNT] fields;
    /// The instant, in milliseconds since the epoch.
    protected long time;
    /// Whether `time` is current.
    protected bool isTimeSet;
    /// Whether `fields` are current.
    protected bool areFieldsSet;

    // 0 unset, 1 computed, from 2 the order in which the fields were set: the most recent group decides.
    private int[FIELD_COUNT] stamp;
    private int nextStamp = 2;
    private bool lenient = true;
    private TimeZone zone;

    /// A calendar in `zone`, with no time set.
    protected this(TimeZone zone) pure nothrow @nogc
    {
        this.zone = zone;
    }

    /// A `GregorianCalendar` for the current time in the default zone (UTC).
    static Calendar getInstance()
    {
        return new GregorianCalendar();
    }

    /// A `GregorianCalendar` for the current time in `zone`.
    static Calendar getInstance(TimeZone zone)
    {
        return new GregorianCalendar(zone);
    }

    /// Convert the set fields to `time`.
    protected abstract void computeTime();

    /// Convert `time` to all the fields.
    protected abstract void computeFields();

    /// The value of `field`, after computing whatever is out of date.
    int get(int field)
    {
        complete();
        return fields[field];
    }

    /// Set `field` to `value`; the instant is recomputed when next needed.
    void set(int field, int value)
    {
        if (isTimeSet && !areFieldsSet)
            computeFields();
        fields[field] = value;
        stamp[field] = nextStamp++;
        isTimeSet = false;
    }

    /// Set the year, month (0-based) and day of the month.
    final void set(int year, int month, int date)
    {
        set(YEAR, year);
        set(MONTH, month);
        set(DATE, date);
    }

    /// Set the date, the hour of the day and the minute.
    final void set(int year, int month, int date, int hourOfDay, int minute)
    {
        set(year, month, date);
        set(HOUR_OF_DAY, hourOfDay);
        set(MINUTE, minute);
    }

    /// Set the date and the time of day to the second.
    final void set(int year, int month, int date, int hourOfDay, int minute, int second)
    {
        set(year, month, date, hourOfDay, minute);
        set(SECOND, second);
    }

    /// Clear every field and the instant: unset fields take their defaults (1970-01-01T00:00 in this zone).
    final void clear() pure nothrow @nogc
    {
        fields[] = 0;
        stamp[] = 0;
        isTimeSet = false;
        areFieldsSet = false;
    }

    /// Clear `field`.
    final void clear(int field) pure nothrow @nogc
    {
        fields[field] = 0;
        stamp[field] = 0;
        isTimeSet = false;
        areFieldsSet = false;
    }

    /// Whether `field` has a value.
    final bool isSet(int field) const pure nothrow @nogc
    {
        return stamp[field] != 0;
    }

    /// The instant as a `Date`.
    final Date getTime()
    {
        return new Date(getTimeInMillis());
    }

    /// Set the instant from a `Date`.
    final void setTime(const Date date)
    {
        setTimeInMillis(date.getTime());
    }

    /// The instant, in milliseconds since the epoch.
    long getTimeInMillis()
    {
        if (!isTimeSet)
            updateTime();
        return time;
    }

    /// Set the instant, in milliseconds since the epoch; every field is recomputed.
    void setTimeInMillis(long millis)
    {
        time = millis;
        isTimeSet = true;
        areFieldsSet = false;
        computeFields();
    }

    /// Add `amount` to `field`, carrying into the larger fields; adding years or months keeps the day of the month
    /// within the resulting month.
    void add(int field, int amount)
    {
        if (amount == 0)
            return;
        if (field == YEAR || field == MONTH)
            return addMonths(field == YEAR ? amount * 12L : amount);
        const unit = unitMillis(field);
        if (unit == 0)
            throw new IllegalArgumentException("Calendar.add: unsupported field " ~ fieldName(field));
        setTimeInMillis(getTimeInMillis() + unit * amount);
    }

    private void addMonths(long months)
    {
        complete();
        const day = fields[DAY_OF_MONTH];
        auto total = (fields[ERA] == 0 ? 1 - fields[YEAR] : fields[YEAR]) * 12L + fields[MONTH] + months;
        const year = floorDiv(total, 12);
        const month = cast(int) floorMod(total, 12);
        const length = monthLength(year, month + 1, gregorianYear(year, month + 1));
        const date = epochDayOf(year, month, day > length ? length : day);
        const ofDay = fields[HOUR_OF_DAY] * 3_600_000L + fields[MINUTE] * 60_000L + fields[SECOND]
            * 1000L + fields[MILLISECOND];
        setTimeInMillis(date * DAY + ofDay - fields[ZONE_OFFSET] - fields[DST_OFFSET]);
    }

    private static long unitMillis(int field) pure nothrow @nogc
    {
        switch (field)
        {
        case DAY_OF_MONTH:
        case DAY_OF_YEAR:
        case DAY_OF_WEEK:
            return DAY;
        case WEEK_OF_YEAR:
        case WEEK_OF_MONTH:
        case DAY_OF_WEEK_IN_MONTH:
            return 7 * DAY;
        case HOUR:
        case HOUR_OF_DAY:
            return 3_600_000;
        case MINUTE:
            return 60_000;
        case SECOND:
            return 1000;
        case MILLISECOND:
            return 1;
        default:
            return 0;
        }
    }

    /// The time zone.
    TimeZone getTimeZone() pure nothrow @nogc
    {
        return zone;
    }

    /// Set the time zone: the fields are recomputed from the instant, or the instant from the set fields.
    void setTimeZone(TimeZone value) pure nothrow @nogc
    {
        zone = value;
        areFieldsSet = false;
    }

    /// Whether fields out of range carry over (true by default) rather than being rejected.
    bool isLenient() const pure nothrow @nogc
    {
        return lenient;
    }

    /// Set the leniency.
    void setLenient(bool value) pure nothrow @nogc
    {
        lenient = value;
    }

    /// The first day of the week: Sunday (`en_US`).
    int getFirstDayOfWeek() const pure nothrow @nogc
    {
        return SUNDAY;
    }

    /// The minimal number of days in the first week of the year: 1 (`en_US`).
    int getMinimalDaysInFirstWeek() const pure nothrow @nogc
    {
        return 1;
    }

    /// Compute the instant and then every field, if out of date.
    protected void complete()
    {
        if (!isTimeSet)
            updateTime();
        if (!areFieldsSet)
            computeFields();
    }

    private void updateTime()
    {
        computeTime();
        isTimeSet = true;
    }

    /// The order in which `field` was set: 0 unset, 1 computed, from 2 set by the caller.
    protected final int stampOf(int field) const pure nothrow @nogc
    {
        return stamp[field];
    }

    /// Store computed fields, marking each one as computed rather than set.
    protected final void setComputed(scope const int[] values) pure nothrow @nogc
    {
        fields[] = values[];
        stamp[] = 1;
        areFieldsSet = true;
    }

    /// Java's `Calendar` field name, as its exceptions print it.
    static string fieldName(int field) pure nothrow @nogc
    {
        static immutable string[FIELD_COUNT] names = [
            "ERA", "YEAR", "MONTH", "WEEK_OF_YEAR", "WEEK_OF_MONTH", "DAY_OF_MONTH", "DAY_OF_YEAR",
            "DAY_OF_WEEK", "DAY_OF_WEEK_IN_MONTH", "AM_PM", "HOUR", "HOUR_OF_DAY", "MINUTE",
            "SECOND", "MILLISECOND", "ZONE_OFFSET", "DST_OFFSET"
        ];
        return field >= 0 && field < FIELD_COUNT ? names[field] : "UNKNOWN";
    }
}

/// Java's `GregorianCalendar`, with the default cutover (1582-10-15).
class GregorianCalendar : Calendar
{
    /// The era before the Common Era.
    enum int BC = 0;
    /// The Common Era.
    enum int AD = 1;

    private long weekYear = 1970;

    /// The current time in the default zone (UTC).
    this()
    {
        this(TimeZone.getDefault());
    }

    /// The current time in `zone`.
    this(TimeZone zone)
    {
        import flint.engine.aot.clock : currentTimeMillis;

        super(zone);
        setTimeInMillis(currentTimeMillis());
    }

    /// Midnight of `year`-`month`-`dayOfMonth` (month 0-based) in the default zone.
    this(int year, int month, int dayOfMonth)
    {
        this(year, month, dayOfMonth, 0, 0, 0);
    }

    /// `year`-`month`-`dayOfMonth` at `hourOfDay`:`minute`:`second` in the default zone.
    this(int year, int month, int dayOfMonth, int hourOfDay, int minute, int second = 0)
    {
        super(TimeZone.getDefault());
        set(year, month, dayOfMonth, hourOfDay, minute, second);
    }

    /// Whether `year` is a leap year: Gregorian rules from 1583, Julian before (every fourth year).
    bool isLeapYear(int year) const pure nothrow @nogc
    {
        return monthLength(year, 2, year > 1582) == 29;
    }

    /// The cutover from the Julian to the Gregorian calendar: 1582-10-15T00:00Z.
    final Date getGregorianChange() const pure nothrow
    {
        return new Date(CUTOVER_DAY * DAY);
    }

    /// The week-based year (astronomical: 2 BC is -1), as pattern letter 'Y' prints it.
    int getWeekYear()
    {
        complete();
        return cast(int) weekYear;
    }

    protected override void computeFields()
    {
        const offset = getTimeZone().getOffset(time);
        computeFieldsAt(offset);
    }

    private void computeFieldsAt(long offset)
    {
        int[FIELD_COUNT] values;
        fieldsFor(time, offset, values, weekYear);
        setComputed(values[]);
    }

    protected override void computeTime()
    {
        if (!isLenient())
            checkRanges();
        int[FIELD_COUNT] original = fields;
        const year = fieldOr(ERA, AD) == BC ? 1 - cast(long) fieldOr(YEAR, 1970) : fieldOr(YEAR, 1970);
        const zoneSet = stampOf(ZONE_OFFSET) >= 2;
        const offset = zoneSet ? cast(long) fields[ZONE_OFFSET] + (stampOf(DST_OFFSET) >= 2
                ? fields[DST_OFFSET] : 0) : getTimeZone().getRawOffset();
        time = resolveDay(year) * DAY + timeOfDay() - offset;
        if (isLenient())
            return;
        int[FIELD_COUNT] computed;
        long ignored;
        fieldsFor(time, offset, computed, ignored);
        foreach (field; 0 .. FIELD_COUNT)
            if (stampOf(field) >= 2 && original[field] != computed[field])
                throw new IllegalArgumentException(
                        fieldName(field) ~ ": " ~ text(original[field]) ~ " -> " ~ text(computed[field]));
    }

    // Non-lenient: a set field outside its absolute range is rejected by name.
    private void checkRanges()
    {
        static immutable int[2][FIELD_COUNT] ranges = [
            [0, 1], [1, 292_278_994], [0, 11], [1, 53], [0, 6], [1, 31], [1, 366], [1, 7], [-1,
                6], [0, 1], [0, 11], [0, 23], [0, 59], [0, 59], [0, 999],
            [-13 * 3_600_000, 14 * 3_600_000], [0, 2 * 3_600_000]
        ];
        foreach (field; 0 .. FIELD_COUNT)
            if (stampOf(field) >= 2 && (fields[field] < ranges[field][0] || fields[field] > ranges[field][1]))
                throw new IllegalArgumentException(fieldName(field));
    }

    // A set or computed field's value, else its default.
    private int fieldOr(int field, int fallback) const pure nothrow @nogc
    {
        return stampOf(field) >= 1 ? fields[field] : fallback;
    }

    // The day the most recently set date fields name: month and day, day of year, or week of year.
    private long resolveDay(long year) const pure nothrow @nogc
    {
        const monthDay = max(stampOf(MONTH), stampOf(DAY_OF_MONTH));
        const yearDay = stampOf(DAY_OF_YEAR);
        const week = stampOf(WEEK_OF_YEAR) >= 2 ? max(stampOf(WEEK_OF_YEAR), stampOf(DAY_OF_WEEK)) : 0;
        if (yearDay > monthDay && yearDay >= week)
            return januaryFirst(year) + fields[DAY_OF_YEAR] - 1;
        if (week > monthDay)
            return weekOneStart(year) + (fields[WEEK_OF_YEAR] - 1) * 7L + (fieldOr(DAY_OF_WEEK, SUNDAY) - SUNDAY);
        return epochDayOf(year, fieldOr(MONTH, JANUARY), fieldOr(DAY_OF_MONTH, 1));
    }

    // HOUR_OF_DAY, or HOUR and AM_PM when those were set later; then minutes, seconds and milliseconds.
    private long timeOfDay() const pure nothrow @nogc
    {
        const hourOfDay = stampOf(HOUR_OF_DAY);
        const twelve = max(stampOf(HOUR), stampOf(AM_PM));
        const hours = twelve > hourOfDay ? fieldOr(HOUR, 0) + 12L * fieldOr(AM_PM, AM) : fieldOr(HOUR_OF_DAY, 0);
        return hours * 3_600_000 + fieldOr(MINUTE, 0) * 60_000L + fieldOr(SECOND, 0) * 1000L + fieldOr(MILLISECOND, 0);
    }
}

private int max(int a, int b) pure nothrow @nogc
{
    return a > b ? a : b;
}

private string text(long value) pure nothrow
{
    import flint.engine.aot.text : decimal;

    return decimal(value);
}

private alias FieldValues = int[Calendar.FIELD_COUNT];

/// Flint: the calendar fields of `millis` (milliseconds since the epoch) at `offset` milliseconds from UTC, exactly as
/// `GregorianCalendar` computes them, without a calendar object, for code that only formats (no vtable keeps the
/// field resolution linked). `values` is indexed by `Calendar`'s field numbers (`Calendar.YEAR`, `Calendar.MONTH`...).
package(flint) void gregorianFields(long millis, long offset, ref FieldValues values) pure nothrow @nogc
{
    long weekYear;
    fieldsFor(millis, offset, values, weekYear);
}

@("gregorianFields agrees with GregorianCalendar.get across the cutover and at a negative offset")
unittest
{
    import flint.java.util.timezone : TimeZone;

    static immutable long[5] samples = [
        -12_219_292_800_001L, -12_219_292_800_000L, 1_234_567_890_123L, 0L, -62_198_755_200_000L
    ];
    foreach (zone; ["UTC", "GMT-05:30"])
    {
        auto cal = new GregorianCalendar(TimeZone.getTimeZone(zone));
        // The last Julian and first Gregorian milliseconds, a day that carries back across midnight at -05:30, and
        // a BC year.
        foreach (millis; samples)
        {
            cal.setTimeInMillis(millis);
            FieldValues values;
            gregorianFields(millis, cal.getTimeZone().getRawOffset(), values);
            foreach (field; 0 .. Calendar.FIELD_COUNT)
                assert(values[field] == cal.get(field), Calendar.fieldName(field));
        }
    }
}

// Every Calendar field of `millis` at `offset` (milliseconds), and the week-based year.
private void fieldsFor(long millis, long offset, ref FieldValues values, out long weekYear) pure nothrow @nogc
{
    const f = fieldsOf(millis, offset);
    const firstOfMonth = f.epochDay - f.day + 1;
    weekYear = f.epochDay >= weekOneStart(f.year + 1) ? f.year + 1 : f.year;
    values[Calendar.ERA] = f.year > 0 ? GregorianCalendar.AD : GregorianCalendar.BC;
    values[Calendar.YEAR] = cast(int)(f.year > 0 ? f.year : 1 - f.year);
    values[Calendar.MONTH] = f.month - 1;
    values[Calendar.WEEK_OF_YEAR] = cast(int)((f.epochDay - weekOneStart(weekYear)) / 7 + 1);
    values[Calendar.WEEK_OF_MONTH] = (f.day - 1 + dayOfWeek(firstOfMonth) - 1) / 7 + 1;
    values[Calendar.DAY_OF_MONTH] = f.day;
    values[Calendar.DAY_OF_YEAR] = cast(int)(f.epochDay - januaryFirst(f.year) + 1);
    values[Calendar.DAY_OF_WEEK] = dayOfWeek(f.epochDay);
    values[Calendar.DAY_OF_WEEK_IN_MONTH] = (f.day - 1) / 7 + 1;
    values[Calendar.AM_PM] = f.hour < 12 ? Calendar.AM : Calendar.PM;
    values[Calendar.HOUR] = f.hour % 12;
    values[Calendar.HOUR_OF_DAY] = f.hour;
    values[Calendar.MINUTE] = f.minute;
    values[Calendar.SECOND] = f.second;
    values[Calendar.MILLISECOND] = f.millis;
    values[Calendar.ZONE_OFFSET] = cast(int) offset;
    values[Calendar.DST_OFFSET] = 0;
}

// ---- the calendar arithmetic

/// Milliseconds in a day.
private enum long DAY = 86_400_000;

/// The epoch day of 1582-10-15, the first Gregorian day (GregorianCalendar's default cutover).
private enum long CUTOVER_DAY = -141_427;

private struct Fields
{
    long year; // astronomical: 1 BC is 0
    int month; // 1 to 12
    int day;
    int hour;
    int minute;
    int second;
    int millis;
    long epochDay; // days since 1970-01-01, in the zone
}

// The fields of `millis` at `offset` milliseconds from UTC.
private Fields fieldsOf(long millis, long offset) pure nothrow @nogc
{
    auto epochDay = floorDiv(millis, DAY);
    long ofDay = floorMod(millis, DAY) + offset;
    epochDay += floorDiv(ofDay, DAY);
    ofDay = floorMod(ofDay, DAY);
    long year;
    int month, day;
    if (epochDay >= CUTOVER_DAY)
        gregorianDate(epochDay, year, month, day);
    else
        julianDate(epochDay, year, month, day);
    return Fields(year, month, day, cast(int)(ofDay / 3_600_000), cast(int)(ofDay / 60_000 % 60),
            cast(int)(ofDay / 1000 % 60), cast(int)(ofDay % 1000), epochDay);
}

// The epoch day of a date given leniently (any month0 and day, carried over), Gregorian when that day is on or after
// the cutover and Julian before.
private long epochDayOf(long year, long month0, long day) pure nothrow @nogc
{
    const y = year + floorDiv(month0, 12);
    const m = cast(int) floorMod(month0, 12) + 1;
    const gregorian = gregorianDays(y, m, 1) + day - 1;
    return gregorian >= CUTOVER_DAY ? gregorian : julianDays(y, m, 1) + day - 1;
}

private bool gregorianYear(long year, int month) pure nothrow @nogc
{
    return year > 1582 || (year == 1582 && month > 10);
}

// The last day of the month. October 1582 still ends on the 31st, though the cutover makes it 21 days long (the
// 5th to the 14th do not exist); `add` only needs the last day.
private int monthLength(long year, int month, bool gregorian) pure nothrow @nogc
{
    static immutable int[12] days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if (month != 2)
        return days[month - 1];
    const leap = gregorian ? (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) : floorMod(year, 4) == 0;
    return leap ? 29 : 28;
}

// 1 for Sunday to 7 for Saturday.
private int dayOfWeek(long epochDay) pure nothrow @nogc
{
    return cast(int) floorMod(epochDay + 4, 7) + 1;
}

// The epoch day of January 1 of `year`, in the calendar in force that day.
private long januaryFirst(long year) pure nothrow @nogc
{
    const gregorian = gregorianDays(year, 1, 1);
    return gregorian >= CUTOVER_DAY ? gregorian : julianDays(year, 1, 1);
}

// The Sunday that starts week 1 of `year`: the week holding January 1 (en_US).
private long weekOneStart(long year) pure nothrow @nogc
{
    const jan1 = januaryFirst(year);
    return jan1 - (dayOfWeek(jan1) - 1);
}

// Howard Hinnant's days_from_civil and civil_from_days, with floor division for any year.
private long gregorianDays(long year, int month, int day) pure nothrow @nogc
{
    const marchYear = month <= 2 ? year - 1 : year;
    const era = floorDiv(marchYear, 400);
    const yoe = marchYear - era * 400;
    const doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146_097 + doe - 719_468;
}

private void gregorianDate(long epochDay, out long year, out int month, out int day) pure nothrow @nogc
{
    const z = epochDay + 719_468;
    const era = floorDiv(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    day = cast(int)(doy - (153 * mp + 2) / 5 + 1);
    month = cast(int)(mp < 10 ? mp + 3 : mp - 9);
    year = yoe + era * 400 + (month <= 2 ? 1 : 0);
}

// The Julian calendar through the Julian day number (2440588 is 1970-01-01).
private long julianDays(long year, int month, int day) pure nothrow @nogc
{
    const a = (14 - month) / 12;
    const shifted = year + 4800 - a;
    const m = month + 12 * a - 3;
    return day + (153 * m + 2) / 5 + 365 * shifted + floorDiv(shifted, 4) - 32_083 - 2_440_588;
}

private void julianDate(long epochDay, out long year, out int month, out int day) pure nothrow @nogc
{
    const c = epochDay + 2_440_588 + 32_082;
    const d = floorDiv(4 * c + 3, 1461);
    const e = c - floorDiv(1461 * d, 4);
    const m = (5 * e + 2) / 153;
    day = cast(int)(e - (153 * m + 2) / 5 + 1);
    month = cast(int)(m + 3 - 12 * (m / 10));
    year = d - 4800 + m / 10;
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
