module flint.engine.schedule.cron;

import core.bitop : bsf;
import flint.arena : Error, Result, Status;

@safe:

package(flint.engine.schedule) enum long firstSecond = -62_135_596_800;
package(flint.engine.schedule) enum long lastSecond = 253_402_300_799;
private enum secondsPerDay = 86_400L;
private enum daysPerGregorianCycle = 146_097;

/// A validated six-field cron expression. Calendar calculations are always in UTC.
package(flint.engine.schedule) struct Cron
{
    private ulong[6] masks;
    private bool anyDayOfMonth;
    private bool anyDayOfWeek;

    /// Return the next UTC second strictly after the supplied instant, if one exists.
    long nextAfter(long after) const pure nothrow @nogc
    {
        if (after >= lastSecond)
            return long.max;
        const start = after < firstSecond ? firstSecond : after + 1;
        long day = start / secondsPerDay;
        if (start % secondsPerDay < 0)
            --day;
        auto second = cast(uint)(start - day * secondsPerDay);
        const lastDay = lastSecond / secondsPerDay;
        foreach (offset; 0 .. daysPerGregorianCycle + 1)
        {
            if (day > lastDay)
                break;
            if (matchesDate(day))
            {
                const time = firstTimeAtOrAfter(second);
                if (time < secondsPerDay)
                    return day * secondsPerDay + time;
            }
            ++day;
            second = 0;
        }
        return long.max;
    }

    private bool matchesDate(long epochDay) const pure nothrow @nogc
    {
        const date = civilDate(epochDay);
        if (!contains(masks[4], date.month))
            return false;
        const weekday = cast(uint)(((epochDay + 4) % 7 + 7) % 7);
        const dayOfMonth = contains(masks[3], date.day);
        const dayOfWeek = contains(masks[5], weekday);
        if (anyDayOfMonth || anyDayOfWeek)
            return dayOfMonth && dayOfWeek;
        return dayOfMonth || dayOfWeek;
    }

    private uint firstTimeAtOrAfter(uint start) const pure nothrow @nogc
    {
        const firstHour = start / 3600;
        const firstMinute = (start / 60) % 60;
        for (auto hours = masks[2] & (ulong.max << firstHour); hours != 0; hours &= hours - 1)
        {
            const hour = cast(uint) bsf(hours);
            const minuteStart = hour == firstHour ? firstMinute : 0;
            for (auto minutes = masks[1] & (ulong.max << minuteStart); minutes != 0; minutes &= minutes - 1)
            {
                const minute = cast(uint) bsf(minutes);
                const secondStart = hour == firstHour && minute == firstMinute ? start % 60 : 0;
                const seconds = masks[0] & (ulong.max << secondStart);
                if (seconds != 0)
                    return hour * 3600 + minute * 60 + cast(uint) bsf(seconds);
            }
        }
        return cast(uint) secondsPerDay;
    }
}

private struct Date
{
    uint month;
    uint day;
}

// Gregorian cycles start in March so leap day is the final day of its year.
private Date civilDate(long epochDay) pure nothrow @nogc
{
    const shifted = epochDay + 719_468;
    const era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097;
    const eraDay = cast(uint)(shifted - era * 146_097);
    const year = (eraDay - eraDay / 1460 + eraDay / 36_524 - eraDay / 146_096) / 365;
    const yearDay = eraDay - (365 * year + year / 4 - year / 100);
    const marchMonth = (5 * yearDay + 2) / 153;
    return Date(marchMonth < 10 ? marchMonth + 3 : marchMonth - 9, yearDay - (153 * marchMonth + 2) / 5 + 1);
}

private bool contains(ulong mask, uint value) pure nothrow @nogc
{
    return (mask & (1UL << value)) != 0;
}

private bool whitespace(char value) pure nothrow @nogc
{
    return value == ' ' || value == '\t';
}

private bool consume(scope const(char)[] field, ref size_t offset, char literal) pure nothrow @nogc
{
    if (offset == field.length || field[offset] != literal)
        return false;
    ++offset;
    return true;
}

private bool number(scope const(char)[] field, ref size_t offset, uint maximum, out uint value) pure nothrow @nogc
{
    const start = offset;
    while (offset < field.length && field[offset] >= '0' && field[offset] <= '9')
    {
        value = value * 10 + (field[offset++] - '0');
        if (value > maximum)
            return false;
    }
    return start != offset;
}

private bool readField(scope const(char)[] field, uint minimum, uint maximum, out ulong mask) pure nothrow @nogc
{
    size_t offset;
    do
    {
        uint low = minimum;
        uint high = maximum;
        uint step;
        if (!consume(field, offset, '*'))
        {
            if (!number(field, offset, maximum, low) || low < minimum)
                return false;
            if (consume(field, offset, '-'))
            {
                if (!number(field, offset, maximum, high) || high < low)
                    return false;
            }
            else if (offset == field.length || field[offset] != '/')
                high = low;
        }
        if (consume(field, offset, '/'))
        {
            if (!number(field, offset, maximum - minimum + 1, step) || step == 0)
                return false;
        }
        else
            step = 1;
        for (uint value = low; value <= high; value += step)
            mask |= 1UL << value;
    }
    while (consume(field, offset, ','));
    return offset == field.length;
}

package(flint.engine.schedule) Result!Cron parseCron(scope const(char)[] expression) pure nothrow @nogc
{
    if (expression.length == 0 || expression.length > 256)
        return Result!Cron(Cron.init, Error(Status.invalidArgument, "invalid cron expression length"));
    enum uint[6] minimum = [0, 0, 0, 1, 1, 0];
    enum uint[6] maximum = [59, 59, 23, 31, 12, 7];
    Result!Cron result;
    size_t offset;
    foreach (index; 0 .. 6)
    {
        while (offset < expression.length && whitespace(expression[offset]))
            ++offset;
        const start = offset;
        while (offset < expression.length && !whitespace(expression[offset]))
            ++offset;
        const field = expression[start .. offset];
        if (field.length == 0 || !readField(field, minimum[index], maximum[index], result.value.masks[index]))
            return Result!Cron(Cron.init, Error(Status.invalidArgument, "invalid cron field", start));
    }
    while (offset < expression.length && whitespace(expression[offset]))
        ++offset;
    if (offset != expression.length)
        return Result!Cron(Cron.init, Error(Status.invalidArgument, "unexpected cron field", offset));
    if (contains(result.value.masks[5], 7))
        result.value.masks[5] |= 1;
    result.value.anyDayOfMonth = result.value.masks[3] == 0xffff_fffeUL;
    result.value.anyDayOfWeek = (result.value.masks[5] & 0x7f) == 0x7f;
    return result;
}
