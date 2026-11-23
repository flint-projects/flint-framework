/++
Java's `java.time` value types: `LocalDate`, `LocalTime`, `LocalDateTime`, `Instant`, `OffsetDateTime`,
`ZonedDateTime`, `Duration`, `ZoneOffset`, `ZoneId`, `DayOfWeek` and `Month`.

Written clean-room from the Java SE 21 API specification: the ISO-8601 calendar system (proleptic Gregorian), the
`toString` and `parse` forms the specification documents, and its exceptions. Value types are structs (ADR-030
section 5), so equality is member-wise.

Time zones are fixed offsets: `ZoneId.of` accepts "Z", "UTC", "GMT", "UT", offsets ("+02:00") and prefixed offsets
("UTC+2"). Region zones ("Europe/Paris") need the time-zone database and throw `DateTimeException` until it is ported.
`now()` reads the system clock in UTC, which `ZoneId.systemDefault()` returns.
+/
module flint.java.time;

import flint.java.lang : RuntimeException;

@safe:

/// Exception used to indicate a problem while calculating a date-time.
class DateTimeException : RuntimeException
{
    ///
    this(string message, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}

private enum long secondsPerDay = 86_400;
private enum long nanosPerSecond = 1_000_000_000;
private enum long nanosPerDay = secondsPerDay * nanosPerSecond;

// Days since 1970-01-01 of a proleptic Gregorian date (era arithmetic over 400-year cycles).
package(flint.java) long epochDayOf(long year, int month, int day) pure nothrow @nogc
{
    const y = month <= 2 ? year - 1 : year;
    const era = (y >= 0 ? y : y - 399) / 400;
    const yoe = y - era * 400;
    const doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146_097 + doe - 719_468;
}

// A proleptic Gregorian year, month and day.
package(flint.java) struct Civil
{
    long year;
    int month;
    int day;
}

// The proleptic Gregorian date of an epoch day.
package(flint.java) Civil civilOf(long epochDay) pure nothrow @nogc
{
    const z = epochDay + 719_468;
    const era = (z >= 0 ? z : z - 146_096) / 146_097;
    const doe = z - era * 146_097;
    const yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const day = cast(int)(doy - (153 * mp + 2) / 5 + 1);
    const month = cast(int)(mp < 10 ? mp + 3 : mp - 9);
    return Civil(yoe + era * 400 + (month <= 2 ? 1 : 0), month, day);
}

private long floorDiv(long a, long b) pure nothrow @nogc
{
    const q = a / b;
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

private long floorMod(long a, long b) pure nothrow @nogc
{
    return a - floorDiv(a, b) * b;
}

private string pad(long value, int width) pure nothrow
{
    import flint.engine.aot.text : decimal;

    auto text = decimal(value < 0 ? -value : value);
    while (text.length < width)
        text = "0" ~ text;
    return value < 0 ? "-" ~ text : text;
}

// ISO-8601 year: four digits at least, '+' above 9999, '-' below 0.
package(flint.java) string isoYear(long year) pure nothrow
{
    if (year > 9999)
        return "+" ~ pad(year, 4);
    return pad(year, 4);
}

package(flint.java) void checkRange(string field, long value, long low, long high)
{
    import flint.engine.aot.text : decimal;

    if (value < low || value > high)
    {
        const range = decimal(low) ~ " - " ~ decimal(high);
        throw new DateTimeException("Invalid value for " ~ field ~ " (valid values " ~ range ~ "): " ~ decimal(value));
    }
}

/// A day-of-week, such as 'Tuesday'.
enum DayOfWeek
{
    ///
    MONDAY,
    ///
    TUESDAY,
    ///
    WEDNESDAY,
    ///
    THURSDAY,
    ///
    FRIDAY,
    ///
    SATURDAY,
    ///
    SUNDAY,
}

/// The ISO-8601 value of a day-of-week, from 1 (Monday) to 7 (Sunday).
int getValue(DayOfWeek d) pure nothrow @nogc
{
    return d + 1;
}

/// A month-of-year, such as 'July'.
enum Month
{
    ///
    JANUARY,
    ///
    FEBRUARY,
    ///
    MARCH,
    ///
    APRIL,
    ///
    MAY,
    ///
    JUNE,
    ///
    JULY,
    ///
    AUGUST,
    ///
    SEPTEMBER,
    ///
    OCTOBER,
    ///
    NOVEMBER,
    ///
    DECEMBER,
}

/// The month-of-year value, from 1 (January) to 12 (December).
int getValue(Month m) pure nothrow @nogc
{
    return m + 1;
}

/// Whether `year` is a leap year in the proleptic Gregorian calendar.
bool isLeap(long year) pure nothrow @nogc
{
    return (year & 3) == 0 && (year % 100 != 0 || year % 400 == 0);
}

private int monthLength(long year, int month) pure nothrow @nogc
{
    static immutable int[12] lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return month == 2 && isLeap(year) ? 29 : lengths[month - 1];
}

/// A date without a time-zone in the ISO-8601 calendar system, such as 2007-12-03.
struct LocalDate
{
    private int year_ = 1970;
    private ubyte month_ = 1;
    private ubyte day_ = 1;

    /// The minimum supported date, '-999999999-01-01'.
    enum LocalDate MIN = LocalDate(-999_999_999, 1, 1);
    /// The maximum supported date, '+999999999-12-31'.
    enum LocalDate MAX = LocalDate(999_999_999, 12, 31);
    /// The epoch year date, '1970-01-01'.
    enum LocalDate EPOCH = LocalDate(1970, 1, 1);

    private this(int year, int month, int day) pure nothrow @nogc
    {
        year_ = year;
        month_ = cast(ubyte) month;
        day_ = cast(ubyte) day;
    }

    /// Obtains an instance from a year, month and day; throws `DateTimeException` for an invalid date.
    static LocalDate of(int year, int month, int dayOfMonth)
    {
        import flint.engine.aot.text : decimal;

        checkRange("Year", year, -999_999_999, 999_999_999);
        checkRange("MonthOfYear", month, 1, 12);
        checkRange("DayOfMonth", dayOfMonth, 1, 31);
        if (dayOfMonth > monthLength(year, month))
        {
            const leap = "Invalid date 'February 29' as '" ~ decimal(year) ~ "' is not a leap year";
            throw new DateTimeException(dayOfMonth == 29 ? leap
                    : "Invalid date '" ~ monthName(month) ~ " " ~ decimal(dayOfMonth) ~ "'");
        }
        return LocalDate(year, month, dayOfMonth);
    }

    /// ditto, with a `Month`.
    static LocalDate of(int year, Month month, int dayOfMonth)
    {
        return of(year, month.getValue(), dayOfMonth);
    }

    /// Obtains an instance from the epoch day count, day 0 being 1970-01-01.
    static LocalDate ofEpochDay(long epochDay)
    {
        const civil = civilOf(epochDay);
        checkRange("Year", civil.year, -999_999_999, 999_999_999);
        return LocalDate(cast(int) civil.year, civil.month, civil.day);
    }

    /// Obtains an instance from a year and day-of-year.
    static LocalDate ofYearDay(int year, int dayOfYear)
    {
        checkRange("DayOfYear", dayOfYear, 1, isLeap(year) ? 366 : 365);
        return ofEpochDay(epochDayOf(year, 1, 1) + dayOfYear - 1);
    }

    /// Obtains the current date from the system clock, in UTC.
    static LocalDate now()
    {
        return LocalDateTime.now().toLocalDate();
    }

    /// Obtains an instance from a text string such as 2007-12-03 (`DateTimeFormatter.ISO_LOCAL_DATE`).
    static LocalDate parse(string text)
    {
        import flint.java.time.format : DateTimeFormatter;

        return parse(text, DateTimeFormatter.ISO_LOCAL_DATE);
    }

    /// Obtains an instance from a text string using a specific formatter.
    static LocalDate parse(string text, imported!"flint.java.time.format".DateTimeFormatter formatter)
    {
        return formatter.parse(text).toLocalDate(text);
    }

    /// The year field.
    int getYear() const pure nothrow @nogc
    {
        return year_;
    }

    /// The month-of-year field, from 1 to 12.
    int getMonthValue() const pure nothrow @nogc
    {
        return month_;
    }

    /// The month-of-year field as a `Month`.
    Month getMonth() const pure nothrow @nogc
    {
        return cast(Month)(month_ - 1);
    }

    /// The day-of-month field.
    int getDayOfMonth() const pure nothrow @nogc
    {
        return day_;
    }

    /// The day-of-year field, from 1 to 365 or 366.
    int getDayOfYear() const pure nothrow @nogc
    {
        return cast(int)(toEpochDay() - epochDayOf(year_, 1, 1) + 1);
    }

    /// The day-of-week field.
    DayOfWeek getDayOfWeek() const pure nothrow @nogc
    {
        // 1970-01-01 was a Thursday.
        return cast(DayOfWeek) floorMod(toEpochDay() + 3, 7);
    }

    /// Whether the year is a leap year.
    bool isLeapYear() const pure nothrow @nogc
    {
        return isLeap(year_);
    }

    /// The length of the month: 28 to 31 days.
    int lengthOfMonth() const pure nothrow @nogc
    {
        return monthLength(year_, month_);
    }

    /// The length of the year: 365 or 366 days.
    int lengthOfYear() const pure nothrow @nogc
    {
        return isLeap(year_) ? 366 : 365;
    }

    /// The epoch day: days since 1970-01-01.
    long toEpochDay() const pure nothrow @nogc
    {
        return epochDayOf(year_, month_, day_);
    }

    /// A copy with the given number of days added.
    LocalDate plusDays(long days) const
    {
        return days == 0 ? this : ofEpochDay(toEpochDay() + days);
    }

    /// A copy with the given number of weeks added.
    LocalDate plusWeeks(long weeks) const
    {
        return plusDays(weeks * 7);
    }

    /// A copy with the given number of months added, the day clamped to the end of the month.
    LocalDate plusMonths(long months) const
    {
        if (months == 0)
            return this;
        const total = cast(long) year_ * 12 + (month_ - 1) + months;
        const year = floorDiv(total, 12);
        const month = cast(int) floorMod(total, 12) + 1;
        checkRange("Year", year, -999_999_999, 999_999_999);
        const day = day_ < monthLength(year, month) ? day_ : monthLength(year, month);
        return LocalDate(cast(int) year, month, day);
    }

    /// A copy with the given number of years added, February 29 clamped to February 28.
    LocalDate plusYears(long years) const
    {
        return plusMonths(years * 12);
    }

    /// A copy with the given number of days subtracted.
    LocalDate minusDays(long days) const
    {
        return plusDays(-days);
    }

    /// A copy with the given number of weeks subtracted.
    LocalDate minusWeeks(long weeks) const
    {
        return plusWeeks(-weeks);
    }

    /// A copy with the given number of months subtracted.
    LocalDate minusMonths(long months) const
    {
        return plusMonths(-months);
    }

    /// A copy with the given number of years subtracted.
    LocalDate minusYears(long years) const
    {
        return plusYears(-years);
    }

    /// A copy with the year altered, February 29 clamped.
    LocalDate withYear(int year) const
    {
        checkRange("Year", year, -999_999_999, 999_999_999);
        const day = day_ < monthLength(year, month_) ? day_ : monthLength(year, month_);
        return LocalDate(year, month_, day);
    }

    /// A copy with the month altered, the day clamped.
    LocalDate withMonth(int month) const
    {
        checkRange("MonthOfYear", month, 1, 12);
        const day = day_ < monthLength(year_, month) ? day_ : monthLength(year_, month);
        return LocalDate(year_, month, day);
    }

    /// A copy with the day-of-month altered.
    LocalDate withDayOfMonth(int dayOfMonth) const
    {
        return of(year_, month_, dayOfMonth);
    }

    /// Combines this date with a time to create a `LocalDateTime`.
    LocalDateTime atTime(LocalTime time) const pure nothrow @nogc
    {
        return LocalDateTime(this, time);
    }

    /// Combines this date with a time to create a `LocalDateTime`.
    LocalDateTime atTime(int hour, int minute, int second = 0, int nanoOfSecond = 0) const
    {
        return LocalDateTime(this, LocalTime.of(hour, minute, second, nanoOfSecond));
    }

    /// Combines this date with the time of midnight.
    LocalDateTime atStartOfDay() const pure nothrow @nogc
    {
        return LocalDateTime(this, LocalTime.MIDNIGHT);
    }

    /// Compares this date to another date: negative, zero or positive.
    int compareTo(LocalDate other) const pure nothrow @nogc
    {
        if (year_ != other.year_)
            return year_ < other.year_ ? -1 : 1;
        if (month_ != other.month_)
            return month_ < other.month_ ? -1 : 1;
        return day_ < other.day_ ? -1 : day_ > other.day_ ? 1 : 0;
    }

    /// `<` and `>` follow `compareTo`.
    int opCmp(const LocalDate other) const pure nothrow @nogc
    {
        return compareTo(other);
    }

    /// Whether this date is before `other`.
    bool isBefore(LocalDate other) const pure nothrow @nogc
    {
        return compareTo(other) < 0;
    }

    /// Whether this date is after `other`.
    bool isAfter(LocalDate other) const pure nothrow @nogc
    {
        return compareTo(other) > 0;
    }

    /// Whether this date equals `other`.
    bool isEqual(LocalDate other) const pure nothrow @nogc
    {
        return compareTo(other) == 0;
    }

    /// Whether this date equals `other`.
    bool equals(LocalDate other) const pure nothrow @nogc
    {
        return this == other;
    }

    /// Java's `hashCode`.
    int hashCode() const pure nothrow @nogc
    {
        return (year_ & 0xFFFFF800) ^ ((year_ << 11) + (month_ << 6) + day_);
    }

    /// Formats this date using the specified formatter.
    string format(imported!"flint.java.time.format".DateTimeFormatter formatter) const
    {
        import flint.java.time.format : Fields;

        return formatter.format(Fields.of(this));
    }

    /// The date as `2007-12-03`.
    string toString() const pure nothrow
    {
        return isoYear(year_) ~ "-" ~ pad(month_, 2) ~ "-" ~ pad(day_, 2);
    }
}

private string monthName(int month) pure nothrow @nogc
{
    static immutable string[12] names = [
        "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER",
        "OCTOBER", "NOVEMBER", "DECEMBER"
    ];
    return names[month - 1];
}

/// A time without a time-zone in the ISO-8601 calendar system, such as 10:15:30.
struct LocalTime
{
    private ubyte hour_;
    private ubyte minute_;
    private ubyte second_;
    private int nano_;

    /// The time of midnight at the start of the day, '00:00'.
    enum LocalTime MIDNIGHT = LocalTime(0, 0, 0, 0);
    /// The minimum supported time, '00:00'.
    enum LocalTime MIN = LocalTime(0, 0, 0, 0);
    /// The time of noon in the middle of the day, '12:00'.
    enum LocalTime NOON = LocalTime(12, 0, 0, 0);
    /// The maximum supported time, '23:59:59.999999999'.
    enum LocalTime MAX = LocalTime(23, 59, 59, 999_999_999);

    private this(int hour, int minute, int second, int nano) pure nothrow @nogc
    {
        hour_ = cast(ubyte) hour;
        minute_ = cast(ubyte) minute;
        second_ = cast(ubyte) second;
        nano_ = nano;
    }

    /// Obtains an instance from an hour, minute, second and nanosecond.
    static LocalTime of(int hour, int minute, int second = 0, int nanoOfSecond = 0)
    {
        checkRange("HourOfDay", hour, 0, 23);
        checkRange("MinuteOfHour", minute, 0, 59);
        checkRange("SecondOfMinute", second, 0, 59);
        checkRange("NanoOfSecond", nanoOfSecond, 0, 999_999_999);
        return LocalTime(hour, minute, second, nanoOfSecond);
    }

    /// Obtains an instance from a second-of-day value.
    static LocalTime ofSecondOfDay(long secondOfDay)
    {
        checkRange("SecondOfDay", secondOfDay, 0, secondsPerDay - 1);
        return LocalTime(cast(int)(secondOfDay / 3600), cast(int)(secondOfDay / 60 % 60), cast(int)(secondOfDay % 60),
                0);
    }

    /// Obtains an instance from a nanos-of-day value.
    static LocalTime ofNanoOfDay(long nanoOfDay)
    {
        checkRange("NanoOfDay", nanoOfDay, 0, nanosPerDay - 1);
        const seconds = nanoOfDay / nanosPerSecond;
        return LocalTime(cast(int)(seconds / 3600), cast(int)(seconds / 60 % 60),
                cast(int)(seconds % 60), cast(int)(nanoOfDay % nanosPerSecond));
    }

    /// Obtains the current time from the system clock, in UTC.
    static LocalTime now()
    {
        return LocalDateTime.now().toLocalTime();
    }

    /// Obtains an instance from a text string such as 10:15 (`DateTimeFormatter.ISO_LOCAL_TIME`).
    static LocalTime parse(string text)
    {
        import flint.java.time.format : DateTimeFormatter;

        return parse(text, DateTimeFormatter.ISO_LOCAL_TIME);
    }

    /// Obtains an instance from a text string using a specific formatter.
    static LocalTime parse(string text, imported!"flint.java.time.format".DateTimeFormatter formatter)
    {
        return formatter.parse(text).toLocalTime(text);
    }

    /// The hour-of-day field.
    int getHour() const pure nothrow @nogc
    {
        return hour_;
    }

    /// The minute-of-hour field.
    int getMinute() const pure nothrow @nogc
    {
        return minute_;
    }

    /// The second-of-minute field.
    int getSecond() const pure nothrow @nogc
    {
        return second_;
    }

    /// The nano-of-second field.
    int getNano() const pure nothrow @nogc
    {
        return nano_;
    }

    /// The time as seconds of day.
    int toSecondOfDay() const pure nothrow @nogc
    {
        return hour_ * 3600 + minute_ * 60 + second_;
    }

    /// The time as nanos of day.
    long toNanoOfDay() const pure nothrow @nogc
    {
        return toSecondOfDay() * nanosPerSecond + nano_;
    }

    /// A copy with the given number of hours added, wrapping around midnight.
    LocalTime plusHours(long hours) const
    {
        return plusNanos(floorMod(hours, 24) * 3600 * nanosPerSecond);
    }

    /// A copy with the given number of minutes added, wrapping around midnight.
    LocalTime plusMinutes(long minutes) const
    {
        return plusNanos(floorMod(minutes, 24 * 60) * 60 * nanosPerSecond);
    }

    /// A copy with the given number of seconds added, wrapping around midnight.
    LocalTime plusSeconds(long seconds) const
    {
        return plusNanos(floorMod(seconds, secondsPerDay) * nanosPerSecond);
    }

    /// A copy with the given number of nanoseconds added, wrapping around midnight.
    LocalTime plusNanos(long nanos) const
    {
        return ofNanoOfDay(floorMod(toNanoOfDay() + floorMod(nanos, nanosPerDay), nanosPerDay));
    }

    /// A copy with the given number of hours subtracted.
    LocalTime minusHours(long hours) const
    {
        return plusHours(-(hours % 24));
    }

    /// A copy with the given number of minutes subtracted.
    LocalTime minusMinutes(long minutes) const
    {
        return plusMinutes(-(minutes % (24 * 60)));
    }

    /// A copy with the given number of seconds subtracted.
    LocalTime minusSeconds(long seconds) const
    {
        return plusSeconds(-(seconds % secondsPerDay));
    }

    /// A copy with the nano-of-second altered.
    LocalTime withNano(int nanoOfSecond) const
    {
        return of(hour_, minute_, second_, nanoOfSecond);
    }

    /// Combines this time with a date to create a `LocalDateTime`.
    LocalDateTime atDate(LocalDate date) const pure nothrow @nogc
    {
        return LocalDateTime(date, this);
    }

    /// Compares this time to another time: negative, zero or positive.
    int compareTo(LocalTime other) const pure nothrow @nogc
    {
        const a = toNanoOfDay(), b = other.toNanoOfDay();
        return a < b ? -1 : a > b ? 1 : 0;
    }

    /// `<` and `>` follow `compareTo`.
    int opCmp(const LocalTime other) const pure nothrow @nogc
    {
        return compareTo(other);
    }

    /// Whether this time is before `other`.
    bool isBefore(LocalTime other) const pure nothrow @nogc
    {
        return compareTo(other) < 0;
    }

    /// Whether this time is after `other`.
    bool isAfter(LocalTime other) const pure nothrow @nogc
    {
        return compareTo(other) > 0;
    }

    /// Whether this time equals `other`.
    bool equals(LocalTime other) const pure nothrow @nogc
    {
        return this == other;
    }

    /// Java's `hashCode`.
    int hashCode() const pure nothrow @nogc
    {
        const nod = toNanoOfDay();
        return cast(int)(nod ^ (nod >>> 32));
    }

    /// Formats this time using the specified formatter.
    string format(imported!"flint.java.time.format".DateTimeFormatter formatter) const
    {
        import flint.java.time.format : Fields;

        return formatter.format(Fields.of(this));
    }

    /// The time as `HH:mm`, `HH:mm:ss`, or with a fraction of 3, 6 or 9 digits, as `LocalTime.toString`.
    string toString() const pure nothrow
    {
        auto text = pad(hour_, 2) ~ ":" ~ pad(minute_, 2);
        if (second_ == 0 && nano_ == 0)
            return text;
        return text ~ ":" ~ pad(second_, 2) ~ groupedFraction(nano_);
    }
}

/// A date-time without a time-zone in the ISO-8601 calendar system, such as 2007-12-03T10:15:30.
struct LocalDateTime
{
    private LocalDate date_;
    private LocalTime time_;

    /// The minimum supported date-time.
    enum LocalDateTime MIN = LocalDateTime(LocalDate.MIN, LocalTime.MIN);
    /// The maximum supported date-time.
    enum LocalDateTime MAX = LocalDateTime(LocalDate.MAX, LocalTime.MAX);

    /// A date-time from a date and a time.
    this(LocalDate date, LocalTime time) pure nothrow @nogc
    {
        date_ = date;
        time_ = time;
    }

    /// Obtains an instance from year, month, day, hour, minute, second and nanosecond.
    static LocalDateTime of(int year, int month, int dayOfMonth, int hour, int minute,
            int second = 0, int nanoOfSecond = 0)
    {
        return LocalDateTime(LocalDate.of(year, month, dayOfMonth), LocalTime.of(hour, minute, second, nanoOfSecond));
    }

    /// Obtains an instance from a date and time.
    static LocalDateTime of(LocalDate date, LocalTime time) pure nothrow @nogc
    {
        return LocalDateTime(date, time);
    }

    /// Obtains an instance using seconds from the epoch of 1970-01-01T00:00:00Z at `offset`.
    static LocalDateTime ofEpochSecond(long epochSecond, int nanoOfSecond, ZoneOffset offset)
    {
        const local = epochSecond + offset.getTotalSeconds();
        return LocalDateTime(LocalDate.ofEpochDay(floorDiv(local, secondsPerDay)),
                LocalTime.ofNanoOfDay(floorMod(local, secondsPerDay) * nanosPerSecond + nanoOfSecond));
    }

    /// Obtains an instance from an instant and zone.
    static LocalDateTime ofInstant(Instant instant, ZoneId zone)
    {
        return ofEpochSecond(instant.getEpochSecond(), instant.getNano(), zone.offset());
    }

    /// Obtains the current date-time from the system clock, in UTC.
    static LocalDateTime now()
    {
        return ofInstant(Instant.now(), ZoneId.systemDefault());
    }

    /// Obtains an instance from a text string such as 2007-12-03T10:15:30 (`ISO_LOCAL_DATE_TIME`).
    static LocalDateTime parse(string text)
    {
        import flint.java.time.format : DateTimeFormatter;

        return parse(text, DateTimeFormatter.ISO_LOCAL_DATE_TIME);
    }

    /// Obtains an instance from a text string using a specific formatter.
    static LocalDateTime parse(string text, imported!"flint.java.time.format".DateTimeFormatter formatter)
    {
        auto fields = formatter.parse(text);
        return LocalDateTime(fields.toLocalDate(text, "LocalDateTime"), fields.toLocalTime(text, "LocalDateTime"));
    }

    /// The date part.
    LocalDate toLocalDate() const pure nothrow @nogc
    {
        return date_;
    }

    /// The time part.
    LocalTime toLocalTime() const pure nothrow @nogc
    {
        return time_;
    }

    /// The year field.
    int getYear() const pure nothrow @nogc
    {
        return date_.getYear();
    }

    /// The month-of-year field, from 1 to 12.
    int getMonthValue() const pure nothrow @nogc
    {
        return date_.getMonthValue();
    }

    /// The month-of-year field as a `Month`.
    Month getMonth() const pure nothrow @nogc
    {
        return date_.getMonth();
    }

    /// The day-of-month field.
    int getDayOfMonth() const pure nothrow @nogc
    {
        return date_.getDayOfMonth();
    }

    /// The day-of-week field.
    DayOfWeek getDayOfWeek() const pure nothrow @nogc
    {
        return date_.getDayOfWeek();
    }

    /// The hour-of-day field.
    int getHour() const pure nothrow @nogc
    {
        return time_.getHour();
    }

    /// The minute-of-hour field.
    int getMinute() const pure nothrow @nogc
    {
        return time_.getMinute();
    }

    /// The second-of-minute field.
    int getSecond() const pure nothrow @nogc
    {
        return time_.getSecond();
    }

    /// The nano-of-second field.
    int getNano() const pure nothrow @nogc
    {
        return time_.getNano();
    }

    /// Seconds from the epoch of 1970-01-01T00:00:00Z, reading this date-time at `offset`.
    long toEpochSecond(ZoneOffset offset) const pure nothrow @nogc
    {
        return date_.toEpochDay() * secondsPerDay + time_.toSecondOfDay() - offset.getTotalSeconds();
    }

    /// The instant this date-time denotes at `offset`.
    Instant toInstant(ZoneOffset offset) const pure nothrow @nogc
    {
        return Instant(toEpochSecond(offset), time_.getNano());
    }

    private LocalDateTime plusNanosTotal(long nanos) const
    {
        const total = time_.toNanoOfDay() + floorMod(nanos, nanosPerDay);
        const days = floorDiv(nanos, nanosPerDay) + floorDiv(total, nanosPerDay);
        return LocalDateTime(date_.plusDays(days), LocalTime.ofNanoOfDay(floorMod(total, nanosPerDay)));
    }

    /// A copy with the given number of days added.
    LocalDateTime plusDays(long days) const
    {
        return LocalDateTime(date_.plusDays(days), time_);
    }

    /// A copy with the given number of weeks added.
    LocalDateTime plusWeeks(long weeks) const
    {
        return LocalDateTime(date_.plusWeeks(weeks), time_);
    }

    /// A copy with the given number of months added.
    LocalDateTime plusMonths(long months) const
    {
        return LocalDateTime(date_.plusMonths(months), time_);
    }

    /// A copy with the given number of years added.
    LocalDateTime plusYears(long years) const
    {
        return LocalDateTime(date_.plusYears(years), time_);
    }

    /// A copy with the given number of hours added.
    LocalDateTime plusHours(long hours) const
    {
        return plusSeconds(hours * 3600);
    }

    /// A copy with the given number of minutes added.
    LocalDateTime plusMinutes(long minutes) const
    {
        return plusSeconds(minutes * 60);
    }

    /// A copy with the given number of seconds added.
    LocalDateTime plusSeconds(long seconds) const
    {
        const local = time_.toSecondOfDay() + seconds;
        return LocalDateTime(date_.plusDays(floorDiv(local, secondsPerDay)),
                LocalTime.ofNanoOfDay(floorMod(local, secondsPerDay) * nanosPerSecond + time_.getNano()));
    }

    /// A copy with the given number of nanoseconds added.
    LocalDateTime plusNanos(long nanos) const
    {
        return plusNanosTotal(nanos);
    }

    /// A copy with the given number of days subtracted.
    LocalDateTime minusDays(long days) const
    {
        return plusDays(-days);
    }

    /// A copy with the given number of hours subtracted.
    LocalDateTime minusHours(long hours) const
    {
        return plusHours(-hours);
    }

    /// A copy with the given number of minutes subtracted.
    LocalDateTime minusMinutes(long minutes) const
    {
        return plusMinutes(-minutes);
    }

    /// A copy with the given number of seconds subtracted.
    LocalDateTime minusSeconds(long seconds) const
    {
        return plusSeconds(-seconds);
    }

    /// Combines this date-time with an offset to create an `OffsetDateTime`.
    OffsetDateTime atOffset(ZoneOffset offset) const pure nothrow @nogc
    {
        return OffsetDateTime(this, offset);
    }

    /// Combines this date-time with a time-zone to create a `ZonedDateTime`.
    ZonedDateTime atZone(ZoneId zone) const
    {
        return ZonedDateTime.of(this, zone);
    }

    /// Compares this date-time to another: negative, zero or positive.
    int compareTo(LocalDateTime other) const pure nothrow @nogc
    {
        const c = date_.compareTo(other.date_);
        return c != 0 ? c : time_.compareTo(other.time_);
    }

    /// `<` and `>` follow `compareTo`.
    int opCmp(const LocalDateTime other) const pure nothrow @nogc
    {
        return compareTo(other);
    }

    /// Whether this date-time is before `other`.
    bool isBefore(LocalDateTime other) const pure nothrow @nogc
    {
        return compareTo(other) < 0;
    }

    /// Whether this date-time is after `other`.
    bool isAfter(LocalDateTime other) const pure nothrow @nogc
    {
        return compareTo(other) > 0;
    }

    /// Whether this date-time equals `other`.
    bool equals(LocalDateTime other) const pure nothrow @nogc
    {
        return this == other;
    }

    /// Java's `hashCode`.
    int hashCode() const pure nothrow @nogc
    {
        return date_.hashCode() ^ time_.hashCode();
    }

    /// Formats this date-time using the specified formatter.
    string format(imported!"flint.java.time.format".DateTimeFormatter formatter) const
    {
        import flint.java.time.format : Fields;

        return formatter.format(Fields.of(this));
    }

    /// The date-time as `2007-12-03T10:15:30`.
    string toString() const pure nothrow
    {
        return date_.toString() ~ "T" ~ time_.toString();
    }
}

/// A time-zone offset from Greenwich/UTC, such as +02:00.
struct ZoneOffset
{
    private int totalSeconds_;

    /// The time-zone offset for UTC, with an ID of 'Z'.
    enum ZoneOffset UTC = ZoneOffset.init;
    /// The minimum supported offset, '-18:00'.
    enum ZoneOffset MIN = ZoneOffset(-18 * 3600);
    /// The maximum supported offset, '+18:00'.
    enum ZoneOffset MAX = ZoneOffset(18 * 3600);

    private this(int totalSeconds) pure nothrow @nogc
    {
        totalSeconds_ = totalSeconds;
    }

    /// Obtains an instance specifying the total offset in seconds, from -18:00 to +18:00.
    static ZoneOffset ofTotalSeconds(int totalSeconds)
    {
        if (totalSeconds < -18 * 3600 || totalSeconds > 18 * 3600)
            throw new DateTimeException("Zone offset not in valid range: -18:00 to +18:00");
        return ZoneOffset(totalSeconds);
    }

    /// Obtains an instance using an offset in hours.
    static ZoneOffset ofHours(int hours)
    {
        return ofHoursMinutesSeconds(hours, 0, 0);
    }

    /// Obtains an instance using an offset in hours and minutes, both with the same sign.
    static ZoneOffset ofHoursMinutes(int hours, int minutes)
    {
        return ofHoursMinutesSeconds(hours, minutes, 0);
    }

    /// Obtains an instance using an offset in hours, minutes and seconds, all with the same sign.
    static ZoneOffset ofHoursMinutesSeconds(int hours, int minutes, int seconds)
    {
        import flint.engine.aot.text : decimal;

        if (hours < -18 || hours > 18)
        {
            const value = decimal(hours);
            throw new DateTimeException(
                    "Zone offset hours not in valid range: value " ~ value ~ " is not in the range -18 to 18");
        }
        checkOffsetSigns(hours, minutes, seconds);
        if (minutes < -59 || minutes > 59)
        {
            const value = decimal(minutes);
            throw new DateTimeException(
                    "Zone offset minutes not in valid range: value " ~ value ~ " is not in the range -59 to 59");
        }
        if (seconds < -59 || seconds > 59)
        {
            const value = decimal(seconds);
            throw new DateTimeException(
                    "Zone offset seconds not in valid range: value " ~ value ~ " is not in the range -59 to 59");
        }
        if ((hours == 18 || hours == -18) && (minutes | seconds) != 0)
            throw new DateTimeException("Zone offset not in valid range: -18:00 to +18:00");
        return ofTotalSeconds(hours * 3600 + minutes * 60 + seconds);
    }

    private static void checkOffsetSigns(int hours, int minutes, int seconds)
    {
        if (hours > 0 && (minutes < 0 || seconds < 0))
            throw new DateTimeException("Zone offset minutes and seconds must be positive because hours is positive");
        if (hours < 0 && (minutes > 0 || seconds > 0))
            throw new DateTimeException("Zone offset minutes and seconds must be negative because hours is negative");
        if (hours == 0 && ((minutes > 0 && seconds < 0) || (minutes < 0 && seconds > 0)))
            throw new DateTimeException("Zone offset minutes and seconds must have the same sign");
    }

    /// Obtains an instance from an ID: Z, +h, +hh, +hh:mm, +hhmm, +hh:mm:ss or +hhmmss.
    static ZoneOffset of(string offsetId)
    {
        if (offsetId == "Z")
            return UTC;
        string id = offsetId;
        int hours, minutes, seconds;
        switch (id.length)
        {
        case 2:
            id = id[0 .. 1] ~ "0" ~ id[1 .. 2];
            hours = offsetNumber(id, 1, false);
            break;
        case 3:
            hours = offsetNumber(id, 1, false);
            break;
        case 5:
            hours = offsetNumber(id, 1, false);
            minutes = offsetNumber(id, 3, false);
            break;
        case 6:
            hours = offsetNumber(id, 1, false);
            minutes = offsetNumber(id, 4, true);
            break;
        case 7:
            hours = offsetNumber(id, 1, false);
            minutes = offsetNumber(id, 3, false);
            seconds = offsetNumber(id, 5, false);
            break;
        case 9:
            hours = offsetNumber(id, 1, false);
            minutes = offsetNumber(id, 4, true);
            seconds = offsetNumber(id, 7, true);
            break;
        default:
            throw new DateTimeException("Invalid ID for ZoneOffset, invalid format: " ~ id);
        }
        if (id[0] == '-')
            return ofHoursMinutesSeconds(-hours, -minutes, -seconds);
        if (id[0] == '+')
            return ofHoursMinutesSeconds(hours, minutes, seconds);
        throw new DateTimeException("Invalid ID for ZoneOffset, plus/minus not found when expected: " ~ id);
    }

    // Two digits at `pos`, after a colon when `precededByColon`, as ZoneOffset.of reads them.
    private static int offsetNumber(string id, size_t pos, bool precededByColon)
    {
        if (precededByColon && id[pos - 1] != ':')
            throw new DateTimeException("Invalid ID for ZoneOffset, colon not found when expected: " ~ id);
        const a = id[pos], b = id[pos + 1];
        if (a < '0' || a > '9' || b < '0' || b > '9')
            throw new DateTimeException("Invalid ID for ZoneOffset, non numeric characters found: " ~ id);
        return (a - '0') * 10 + (b - '0');
    }

    /// The total offset in seconds.
    int getTotalSeconds() const pure nothrow @nogc
    {
        return totalSeconds_;
    }

    /// The normalized ID: "Z" or "+hh:mm" with ":ss" when the seconds are not zero.
    string getId() const pure nothrow
    {
        if (totalSeconds_ == 0)
            return "Z";
        const total = totalSeconds_ < 0 ? -totalSeconds_ : totalSeconds_;
        auto text = (totalSeconds_ < 0 ? "-" : "+") ~ pad(total / 3600, 2) ~ ":" ~ pad(total / 60 % 60, 2);
        return total % 60 == 0 ? text : text ~ ":" ~ pad(total % 60, 2);
    }

    /// The offset as a `ZoneId`.
    ZoneId toZoneId() const pure nothrow
    {
        return ZoneId(getId(), this);
    }

    /// Compares offsets in descending order, as Java does: a larger offset sorts first.
    int compareTo(ZoneOffset other) const pure nothrow @nogc
    {
        return other.totalSeconds_ < totalSeconds_ ? -1 : other.totalSeconds_ > totalSeconds_ ? 1 : 0;
    }

    /// The ID.
    string toString() const pure nothrow
    {
        return getId();
    }
}

/**
 * A time-zone ID, such as "UTC" or "+02:00". Java's `ZoneId` is abstract with the subclasses `ZoneOffset` and
 * `ZoneRegion`; Flint's is a value holding the ID and its fixed offset, because region rules need the time-zone
 * database.
 */
struct ZoneId
{
    private string id_ = "Z";
    private ZoneOffset offset_;

    private this(string id, ZoneOffset offset) pure nothrow @nogc
    {
        id_ = id;
        offset_ = offset;
    }

    /// Obtains an instance from an ID: an offset ("Z", "+02:00"), "UTC", "GMT", "UT", or such a prefix with an offset.
    static ZoneId of(string zoneId)
    {
        if (zoneId.length && (zoneId[0] == '+' || zoneId[0] == '-' || zoneId == "Z"))
            return ZoneOffset.of(zoneId).toZoneId();
        foreach (prefix; ["UTC", "GMT", "UT"])
        {
            if (zoneId == prefix)
                return ZoneId(zoneId, ZoneOffset.UTC);
            if (zoneId.length > prefix.length && zoneId[0 .. prefix.length] == prefix
                    && (zoneId[prefix.length] == '+' || zoneId[prefix.length] == '-'))
            {
                const offset = ZoneOffset.of(zoneId[prefix.length .. $]);
                if (offset.getTotalSeconds() == 0)
                    return ZoneId(prefix, offset);
                return ZoneId(prefix ~ offset.getId(), offset);
            }
        }
        throw new DateTimeException(
                "Unknown time-zone ID: " ~ zoneId
                ~ " (Flint supports fixed offsets until the time-zone database is ported)");
    }

    /// The system default time-zone: UTC.
    static ZoneId systemDefault() pure nothrow
    {
        return ZoneId("UTC", ZoneOffset.UTC);
    }

    /// The ID.
    string getId() const pure nothrow @nogc
    {
        return id_;
    }

    /// The fixed offset of this zone (Flint: every zone has one until the time-zone database is ported).
    ZoneOffset offset() const pure nothrow @nogc
    {
        return offset_;
    }

    /// Normalizes the ID to a `ZoneOffset`, as Java does for a zone with fixed rules.
    ZoneOffset normalized() const pure nothrow @nogc
    {
        return offset_;
    }

    /// Whether this zone is an offset ID such as "+02:00" rather than a named zone.
    bool isOffset() const pure nothrow @nogc
    {
        return id_.length && (id_[0] == '+' || id_[0] == '-' || id_ == "Z");
    }

    /// The ID.
    string toString() const pure nothrow @nogc
    {
        return id_;
    }
}

/// An instantaneous point on the time-line: seconds and nanoseconds from 1970-01-01T00:00:00Z.
struct Instant
{
    private long seconds_;
    private int nanos_;

    /// Constant for the 1970-01-01T00:00:00Z epoch instant.
    enum Instant EPOCH = Instant.init;

    private this(long seconds, int nanos) pure nothrow @nogc
    {
        seconds_ = seconds;
        nanos_ = nanos;
    }

    /// Obtains an instance using seconds from the epoch and a nanosecond adjustment.
    static Instant ofEpochSecond(long epochSecond, long nanoAdjustment = 0) pure nothrow @nogc
    {
        return Instant(epochSecond + floorDiv(nanoAdjustment, nanosPerSecond),
                cast(int) floorMod(nanoAdjustment, nanosPerSecond));
    }

    /// Obtains an instance using milliseconds from the epoch.
    static Instant ofEpochMilli(long epochMilli) pure nothrow @nogc
    {
        return Instant(floorDiv(epochMilli, 1000), cast(int)(floorMod(epochMilli, 1000) * 1_000_000));
    }

    /// Obtains the current instant from the system clock.
    static Instant now() nothrow
    {
        import flint.engine.aot.clock : currentTimeTicks;

        const hnsecs = currentTimeTicks(); // 100 ns ticks, std.datetime's resolution
        return Instant(floorDiv(hnsecs, 10_000_000), cast(int)(floorMod(hnsecs, 10_000_000) * 100));
    }

    /// Obtains an instance from a text string such as 2007-12-03T10:15:30.00Z (`ISO_INSTANT`, offsets accepted).
    static Instant parse(string text)
    {
        import flint.java.time.format : DateTimeFormatter;

        auto fields = DateTimeFormatter.ISO_INSTANT.parse(text);
        return LocalDateTime(fields.toLocalDate(text, "Instant"), fields.toLocalTime(text, "Instant")).toInstant(
                fields.toOffset(text, "Instant"));
    }

    /// The seconds from the epoch.
    long getEpochSecond() const pure nothrow @nogc
    {
        return seconds_;
    }

    /// The nanoseconds within the second.
    int getNano() const pure nothrow @nogc
    {
        return nanos_;
    }

    /// Milliseconds from the epoch.
    long toEpochMilli() const pure nothrow @nogc
    {
        return seconds_ * 1000 + nanos_ / 1_000_000;
    }

    /// A copy with the given number of seconds added.
    Instant plusSeconds(long seconds) const pure nothrow @nogc
    {
        return Instant(seconds_ + seconds, nanos_);
    }

    /// A copy with the given number of milliseconds added.
    Instant plusMillis(long millis) const pure nothrow @nogc
    {
        return ofEpochSecond(seconds_, nanos_ + millis * 1_000_000);
    }

    /// A copy with the given number of nanoseconds added.
    Instant plusNanos(long nanos) const pure nothrow @nogc
    {
        return ofEpochSecond(seconds_ + floorDiv(nanos, nanosPerSecond), nanos_ + floorMod(nanos, nanosPerSecond));
    }

    /// A copy with the given duration added.
    Instant plus(Duration duration) const pure nothrow @nogc
    {
        return ofEpochSecond(seconds_ + duration.getSeconds(), nanos_ + duration.getNano());
    }

    /// A copy with the given number of seconds subtracted.
    Instant minusSeconds(long seconds) const pure nothrow @nogc
    {
        return plusSeconds(-seconds);
    }

    /// A copy with the given number of milliseconds subtracted.
    Instant minusMillis(long millis) const pure nothrow @nogc
    {
        return plusMillis(-millis);
    }

    /// A copy with the given duration subtracted.
    Instant minus(Duration duration) const pure nothrow @nogc
    {
        return ofEpochSecond(seconds_ - duration.getSeconds(), nanos_ - duration.getNano());
    }

    /// Combines this instant with an offset to create an `OffsetDateTime`.
    OffsetDateTime atOffset(ZoneOffset offset) const
    {
        return OffsetDateTime(LocalDateTime.ofEpochSecond(seconds_, nanos_, offset), offset);
    }

    /// Combines this instant with a time-zone to create a `ZonedDateTime`.
    ZonedDateTime atZone(ZoneId zone) const
    {
        return ZonedDateTime(LocalDateTime.ofEpochSecond(seconds_, nanos_, zone.offset()), zone.offset(), zone);
    }

    /// Compares this instant to another: negative, zero or positive.
    int compareTo(Instant other) const pure nothrow @nogc
    {
        if (seconds_ != other.seconds_)
            return seconds_ < other.seconds_ ? -1 : 1;
        return nanos_ < other.nanos_ ? -1 : nanos_ > other.nanos_ ? 1 : 0;
    }

    /// `<` and `>` follow `compareTo`.
    int opCmp(const Instant other) const pure nothrow @nogc
    {
        return compareTo(other);
    }

    /// Whether this instant is before `other`.
    bool isBefore(Instant other) const pure nothrow @nogc
    {
        return compareTo(other) < 0;
    }

    /// Whether this instant is after `other`.
    bool isAfter(Instant other) const pure nothrow @nogc
    {
        return compareTo(other) > 0;
    }

    /// Whether this instant equals `other`.
    bool equals(Instant other) const pure nothrow @nogc
    {
        return this == other;
    }

    /// Java's `hashCode`.
    int hashCode() const pure nothrow @nogc
    {
        return cast(int)(seconds_ ^ (seconds_ >>> 32)) + 51 * nanos_;
    }

    /// The instant as `2007-12-03T10:15:30Z`, with a fraction of 3, 6 or 9 digits when it has one (ISO_INSTANT).
    string toString() const pure nothrow
    {
        const civil = civilOf(floorDiv(seconds_, secondsPerDay));
        const secondOfDay = floorMod(seconds_, secondsPerDay);
        auto text = isoYear(civil.year) ~ "-" ~ pad(civil.month, 2) ~ "-" ~ pad(civil.day,
                2) ~ "T" ~ pad(secondOfDay / 3600, 2) ~ ":" ~ pad(secondOfDay / 60 % 60, 2) ~ ":" ~ pad(
                secondOfDay % 60, 2);
        return text ~ groupedFraction(nanos_) ~ "Z";
    }
}

// A fraction of a second in groups of 3 digits, as LocalTime.toString and ISO_INSTANT print it; empty for 0.
package(flint.java) string groupedFraction(int nano) pure nothrow
{
    if (nano == 0)
        return "";
    if (nano % 1_000_000 == 0)
        return "." ~ pad(nano / 1_000_000, 3);
    if (nano % 1000 == 0)
        return "." ~ pad(nano / 1000, 6);
    return "." ~ pad(nano, 9);
}

/// A date-time with an offset from UTC/Greenwich in the ISO-8601 calendar system, such as 2007-12-03T10:15:30+01:00.
struct OffsetDateTime
{
    private LocalDateTime dateTime_;
    private ZoneOffset offset_;

    /// A date-time at an offset.
    this(LocalDateTime dateTime, ZoneOffset offset) pure nothrow @nogc
    {
        dateTime_ = dateTime;
        offset_ = offset;
    }

    /// Obtains an instance from a date-time and offset.
    static OffsetDateTime of(LocalDateTime dateTime, ZoneOffset offset) pure nothrow @nogc
    {
        return OffsetDateTime(dateTime, offset);
    }

    /// Obtains an instance from a date, time and offset.
    static OffsetDateTime of(LocalDate date, LocalTime time, ZoneOffset offset) pure nothrow @nogc
    {
        return OffsetDateTime(LocalDateTime(date, time), offset);
    }

    /// Obtains an instance from year, month, day, hour, minute, second, nanosecond and offset.
    static OffsetDateTime of(int year, int month, int dayOfMonth, int hour, int minute, int second,
            int nanoOfSecond, ZoneOffset offset)
    {
        return OffsetDateTime(LocalDateTime.of(year, month, dayOfMonth, hour, minute, second, nanoOfSecond), offset);
    }

    /// Obtains an instance from an instant and zone.
    static OffsetDateTime ofInstant(Instant instant, ZoneId zone)
    {
        return instant.atOffset(zone.offset());
    }

    /// Obtains the current date-time from the system clock, in UTC.
    static OffsetDateTime now()
    {
        return Instant.now().atOffset(ZoneOffset.UTC);
    }

    /// Obtains an instance from a text string such as 2007-12-03T10:15:30+01:00 (`ISO_OFFSET_DATE_TIME`).
    static OffsetDateTime parse(string text)
    {
        import flint.java.time.format : DateTimeFormatter;

        return parse(text, DateTimeFormatter.ISO_OFFSET_DATE_TIME);
    }

    /// Obtains an instance from a text string using a specific formatter.
    static OffsetDateTime parse(string text, imported!"flint.java.time.format".DateTimeFormatter formatter)
    {
        auto fields = formatter.parse(text);
        return OffsetDateTime(LocalDateTime(fields.toLocalDate(text, "OffsetDateTime"),
                fields.toLocalTime(text, "OffsetDateTime")), fields.toOffset(text, "OffsetDateTime"));
    }

    /// The local date-time part.
    LocalDateTime toLocalDateTime() const pure nothrow @nogc
    {
        return dateTime_;
    }

    /// The local date part.
    LocalDate toLocalDate() const pure nothrow @nogc
    {
        return dateTime_.toLocalDate();
    }

    /// The local time part.
    LocalTime toLocalTime() const pure nothrow @nogc
    {
        return dateTime_.toLocalTime();
    }

    /// The offset.
    ZoneOffset getOffset() const pure nothrow @nogc
    {
        return offset_;
    }

    /// The year field.
    int getYear() const pure nothrow @nogc
    {
        return dateTime_.getYear();
    }

    /// The instant this date-time denotes.
    Instant toInstant() const pure nothrow @nogc
    {
        return dateTime_.toInstant(offset_);
    }

    /// Seconds from the epoch.
    long toEpochSecond() const pure nothrow @nogc
    {
        return dateTime_.toEpochSecond(offset_);
    }

    /// The same instant at another offset.
    OffsetDateTime withOffsetSameInstant(ZoneOffset offset) const
    {
        return toInstant().atOffset(offset);
    }

    /// Converts to a `ZonedDateTime` at the same instant in `zone`.
    ZonedDateTime atZoneSameInstant(ZoneId zone) const
    {
        return toInstant().atZone(zone);
    }

    /// Compares by instant, then by local date-time.
    int compareTo(OffsetDateTime other) const pure nothrow @nogc
    {
        const c = toInstant().compareTo(other.toInstant());
        return c != 0 ? c : dateTime_.compareTo(other.dateTime_);
    }

    /// Whether this instant is before `other`'s.
    bool isBefore(OffsetDateTime other) const pure nothrow @nogc
    {
        return toInstant().isBefore(other.toInstant());
    }

    /// Whether this instant is after `other`'s.
    bool isAfter(OffsetDateTime other) const pure nothrow @nogc
    {
        return toInstant().isAfter(other.toInstant());
    }

    /// Whether this date-time equals `other`, offset included.
    bool equals(OffsetDateTime other) const pure nothrow @nogc
    {
        return this == other;
    }

    /// Formats this date-time using the specified formatter.
    string format(imported!"flint.java.time.format".DateTimeFormatter formatter) const
    {
        import flint.java.time.format : Fields;

        return formatter.format(Fields.of(this));
    }

    /// The date-time as `2007-12-03T10:15:30+01:00`.
    string toString() const pure nothrow
    {
        return dateTime_.toString() ~ offset_.toString();
    }
}

/// A date-time with a time-zone in the ISO-8601 calendar system, such as 2007-12-03T10:15:30+01:00[UTC+01:00].
struct ZonedDateTime
{
    private LocalDateTime dateTime_;
    private ZoneOffset offset_;
    private ZoneId zone_;

    private this(LocalDateTime dateTime, ZoneOffset offset, ZoneId zone) pure nothrow @nogc
    {
        dateTime_ = dateTime;
        offset_ = offset;
        zone_ = zone;
    }

    /// Obtains an instance from a local date-time and zone.
    static ZonedDateTime of(LocalDateTime dateTime, ZoneId zone) pure nothrow @nogc
    {
        return ZonedDateTime(dateTime, zone.offset(), zone);
    }

    /// ditto, with an offset as the zone.
    static ZonedDateTime of(LocalDateTime dateTime, ZoneOffset offset) pure nothrow
    {
        return ZonedDateTime(dateTime, offset, offset.toZoneId());
    }

    /// Obtains an instance from year, month, day, hour, minute, second, nanosecond and zone.
    static ZonedDateTime of(int year, int month, int dayOfMonth, int hour, int minute, int second,
            int nanoOfSecond, ZoneOffset offset)
    {
        return of(LocalDateTime.of(year, month, dayOfMonth, hour, minute, second, nanoOfSecond), offset);
    }

    /// ditto, with a `ZoneId`.
    static ZonedDateTime of(int year, int month, int dayOfMonth, int hour, int minute, int second,
            int nanoOfSecond, ZoneId zone)
    {
        return of(LocalDateTime.of(year, month, dayOfMonth, hour, minute, second, nanoOfSecond), zone);
    }

    /// Obtains an instance from an instant and zone.
    static ZonedDateTime ofInstant(Instant instant, ZoneId zone)
    {
        return instant.atZone(zone);
    }

    /// Obtains the current date-time from the system clock, in UTC.
    static ZonedDateTime now()
    {
        return Instant.now().atZone(ZoneId.systemDefault());
    }

    /// Obtains an instance from a text string such as 2007-12-03T10:15:30+01:00 or with a bracketed zone ID.
    static ZonedDateTime parse(string text)
    {
        import flint.java.time.format : DateTimeFormatter;

        return parse(text, DateTimeFormatter.ISO_ZONED_DATE_TIME);
    }

    /// Obtains an instance from a text string using a specific formatter.
    static ZonedDateTime parse(string text, imported!"flint.java.time.format".DateTimeFormatter formatter)
    {
        auto fields = formatter.parse(text);
        const dateTime = LocalDateTime(fields.toLocalDate(text, "ZonedDateTime"),
                fields.toLocalTime(text, "ZonedDateTime"));
        const offset = fields.toOffset(text, "ZonedDateTime");
        if (fields.zoneId.length == 0)
            return ZonedDateTime(dateTime, offset, offset.toZoneId());
        // As Java resolves a parsed offset and zone: the instant is kept, at the zone's own offset.
        return dateTime.toInstant(offset).atZone(ZoneId.of(fields.zoneId));
    }

    /// The local date-time part.
    LocalDateTime toLocalDateTime() const pure nothrow @nogc
    {
        return dateTime_;
    }

    /// The local date part.
    LocalDate toLocalDate() const pure nothrow @nogc
    {
        return dateTime_.toLocalDate();
    }

    /// The offset.
    ZoneOffset getOffset() const pure nothrow @nogc
    {
        return offset_;
    }

    /// The time-zone.
    ZoneId getZone() const pure nothrow @nogc
    {
        return zone_;
    }

    /// The instant this date-time denotes.
    Instant toInstant() const pure nothrow @nogc
    {
        return dateTime_.toInstant(offset_);
    }

    /// The same instant as an `OffsetDateTime`.
    OffsetDateTime toOffsetDateTime() const pure nothrow @nogc
    {
        return OffsetDateTime(dateTime_, offset_);
    }

    /// Whether this instant is before `other`'s.
    bool isBefore(ZonedDateTime other) const pure nothrow @nogc
    {
        return toInstant().isBefore(other.toInstant());
    }

    /// Whether this instant is after `other`'s.
    bool isAfter(ZonedDateTime other) const pure nothrow @nogc
    {
        return toInstant().isAfter(other.toInstant());
    }

    /// Formats this date-time using the specified formatter.
    string format(imported!"flint.java.time.format".DateTimeFormatter formatter) const
    {
        import flint.java.time.format : Fields;

        return formatter.format(Fields.of(this));
    }

    /// The date-time as `2007-12-03T10:15:30+01:00`, followed by `[zone]` when the zone is not the offset itself.
    string toString() const pure nothrow
    {
        auto text = dateTime_.toString() ~ offset_.toString();
        return zone_.isOffset() ? text : text ~ "[" ~ zone_.getId() ~ "]";
    }
}

/// A time-based amount of time, such as '34.5 seconds'.
struct Duration
{
    private long seconds_;
    private int nanos_;

    /// Constant for a duration of zero.
    enum Duration ZERO = Duration.init;

    private this(long seconds, int nanos) pure nothrow @nogc
    {
        seconds_ = seconds;
        nanos_ = nanos;
    }

    /// Obtains a duration of standard 24-hour days.
    static Duration ofDays(long days) pure nothrow @nogc
    {
        return Duration(days * secondsPerDay, 0);
    }

    /// Obtains a duration of hours.
    static Duration ofHours(long hours) pure nothrow @nogc
    {
        return Duration(hours * 3600, 0);
    }

    /// Obtains a duration of minutes.
    static Duration ofMinutes(long minutes) pure nothrow @nogc
    {
        return Duration(minutes * 60, 0);
    }

    /// Obtains a duration of seconds and a nanosecond adjustment.
    static Duration ofSeconds(long seconds, long nanoAdjustment = 0) pure nothrow @nogc
    {
        return Duration(seconds + floorDiv(nanoAdjustment, nanosPerSecond),
                cast(int) floorMod(nanoAdjustment, nanosPerSecond));
    }

    /// Obtains a duration of milliseconds.
    static Duration ofMillis(long millis) pure nothrow @nogc
    {
        return Duration(floorDiv(millis, 1000), cast(int)(floorMod(millis, 1000) * 1_000_000));
    }

    /// Obtains a duration of nanoseconds.
    static Duration ofNanos(long nanos) pure nothrow @nogc
    {
        return Duration(floorDiv(nanos, nanosPerSecond), cast(int) floorMod(nanos, nanosPerSecond));
    }

    /// The duration between two instants.
    static Duration between(Instant startInclusive, Instant endExclusive) pure nothrow @nogc
    {
        return ofSeconds(endExclusive.getEpochSecond() - startInclusive.getEpochSecond(),
                endExclusive.getNano() - startInclusive.getNano());
    }

    /// The duration between two local date-times.
    static Duration between(LocalDateTime startInclusive, LocalDateTime endExclusive) pure nothrow @nogc
    {
        return between(startInclusive.toInstant(ZoneOffset.UTC), endExclusive.toInstant(ZoneOffset.UTC));
    }

    /// The duration between two local times.
    static Duration between(LocalTime startInclusive, LocalTime endExclusive) pure nothrow @nogc
    {
        return ofNanos(endExclusive.toNanoOfDay() - startInclusive.toNanoOfDay());
    }

    /// Obtains a duration from a text string such as `PnDTnHnMn.nS`.
    static Duration parse(string text)
    {
        import flint.java.time.format : parseDuration;

        return parseDuration(text);
    }

    /// The seconds part (the duration is seconds plus a non-negative nanosecond adjustment).
    long getSeconds() const pure nothrow @nogc
    {
        return seconds_;
    }

    /// The nanoseconds within the second, from 0 to 999,999,999.
    int getNano() const pure nothrow @nogc
    {
        return nanos_;
    }

    /// Whether this duration is zero.
    bool isZero() const pure nothrow @nogc
    {
        return seconds_ == 0 && nanos_ == 0;
    }

    /// Whether this duration is negative, excluding zero.
    bool isNegative() const pure nothrow @nogc
    {
        return seconds_ < 0;
    }

    /// Whole days, truncated toward zero.
    long toDays() const pure nothrow @nogc
    {
        return seconds_ / secondsPerDay;
    }

    /// Whole hours, truncated toward zero.
    long toHours() const pure nothrow @nogc
    {
        return seconds_ / 3600;
    }

    /// Whole minutes, truncated toward zero.
    long toMinutes() const pure nothrow @nogc
    {
        return seconds_ / 60;
    }

    /// The total length in milliseconds.
    long toMillis() const pure nothrow @nogc
    {
        return seconds_ * 1000 + nanos_ / 1_000_000;
    }

    /// The total length in nanoseconds.
    long toNanos() const pure nothrow @nogc
    {
        return seconds_ * nanosPerSecond + nanos_;
    }

    /// A copy with `other` added.
    Duration plus(Duration other) const pure nothrow @nogc
    {
        return ofSeconds(seconds_ + other.seconds_, cast(long) nanos_ + other.nanos_);
    }

    /// A copy with `other` subtracted.
    Duration minus(Duration other) const pure nothrow @nogc
    {
        return ofSeconds(seconds_ - other.seconds_, cast(long) nanos_ - other.nanos_);
    }

    /// A copy with the given seconds added.
    Duration plusSeconds(long seconds) const pure nothrow @nogc
    {
        return Duration(seconds_ + seconds, nanos_);
    }

    /// A copy with the given milliseconds added.
    Duration plusMillis(long millis) const pure nothrow @nogc
    {
        return plus(ofMillis(millis));
    }

    /// A copy with the given minutes added.
    Duration plusMinutes(long minutes) const pure nothrow @nogc
    {
        return plusSeconds(minutes * 60);
    }

    /// A copy with the given hours added.
    Duration plusHours(long hours) const pure nothrow @nogc
    {
        return plusSeconds(hours * 3600);
    }

    /// A copy with the length negated.
    Duration negated() const pure nothrow @nogc
    {
        return ofSeconds(-seconds_, -cast(long) nanos_);
    }

    /// A copy with a positive length.
    Duration abs() const pure nothrow @nogc
    {
        return isNegative() ? negated() : this;
    }

    /// Compares by length.
    int compareTo(Duration other) const pure nothrow @nogc
    {
        if (seconds_ != other.seconds_)
            return seconds_ < other.seconds_ ? -1 : 1;
        return nanos_ < other.nanos_ ? -1 : nanos_ > other.nanos_ ? 1 : 0;
    }

    /// `<` and `>` follow `compareTo`.
    int opCmp(const Duration other) const pure nothrow @nogc
    {
        return compareTo(other);
    }

    /// Whether this duration equals `other`.
    bool equals(Duration other) const pure nothrow @nogc
    {
        return this == other;
    }

    /// The ISO-8601 seconds-based representation, such as `PT8H6M12.345S`, as `Duration.toString` specifies.
    string toString() const pure nothrow
    {
        import flint.engine.aot.text : decimal;

        if (isZero())
            return "PT0S";
        // A negative duration with a fraction is the next whole second up, minus the fraction.
        const total = seconds_ < 0 && nanos_ > 0 ? seconds_ + 1 : seconds_;
        const hours = total / 3600;
        const minutes = (total % 3600) / 60;
        const secs = total % 60;
        string text = "PT";
        if (hours != 0)
            text ~= decimal(hours) ~ "H";
        if (minutes != 0)
            text ~= decimal(minutes) ~ "M";
        if (secs == 0 && nanos_ == 0 && text.length > 2)
            return text;
        if (seconds_ < 0 && nanos_ > 0)
            text ~= secs == 0 ? "-0" : decimal(secs);
        else
            text ~= decimal(secs);
        if (nanos_ > 0)
        {
            auto fraction = pad(seconds_ < 0 ? nanosPerSecond - nanos_ : nanos_, 9);
            while (fraction[$ - 1] == '0')
                fraction = fraction[0 .. $ - 1];
            text ~= "." ~ fraction;
        }
        return text ~ "S";
    }
}
