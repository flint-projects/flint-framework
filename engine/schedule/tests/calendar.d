module flint.engine.schedule.calendar_test;

import flint.arena : Status;
import flint.engine.schedule.cron : firstSecond, lastSecond, parseCron;

@safe:

@("cron supports leap days, Sunday aliases, ranges, steps and UTC midnight")
unittest
{
    const leap = parseCron("0 0 0 29 2 *");
    assert(leap.ok && leap.value.nextAfter(1_677_628_800) == 1_709_164_800);
    const sunday = parseCron("0 0 0 * * 7");
    assert(sunday.ok && sunday.value.nextAfter(1_705_190_400) == 1_705_795_200);
    const either = parseCron("0 0 0 15 * 0");
    assert(either.ok && either.value.nextAfter(1_705_190_399) == 1_705_190_400);
    assert(either.value.nextAfter(1_705_190_400) == 1_705_276_800);
    const stepped = parseCron("1-9/2,20 0,2 0 1 1 *");
    assert(stepped.ok && stepped.value.nextAfter(1_704_067_200) == 1_704_067_201);
    assert(stepped.value.nextAfter(1_704_067_209) == 1_704_067_220);
    assert(stepped.value.nextAfter(1_704_067_220) == 1_704_067_321);
    const everySecond = parseCron("* * * * * *");
    assert(everySecond.value.nextAfter(-2) == -1);
    assert(everySecond.value.nextAfter(lastSecond - 1) == lastSecond);
    assert(everySecond.value.nextAfter(lastSecond) == long.max);
    assert(everySecond.value.nextAfter(long.min) == firstSecond);
    const nonexistent = parseCron("0 0 0 30 2 *");
    assert(nonexistent.ok && nonexistent.value.nextAfter(0) == long.max);
}

@("invalid cron fields and the bounded deterministic text corpus")
unittest
{
    const string[] rejected = [
        "", "0 0 0 * *", "0 0 0 * * * *", "60 * * * * *", "0 0 0 0 1 0", "0 0 0 * MAR *",
        "0 0 0 * * 2#1", "*/0 0 0 * * *", "5-2 0 0 * * *", "0, 0 0 * * *", "0 0 0 * * L",
        "0 0 0 * * 77777777777777"
    ];
    foreach (expression; rejected)
        assert(parseCron(expression).error.code == Status.invalidArgument);
    uint random = 31;
    char[256] sample;
    foreach (length; 0 .. sample.length + 1)
    {
        foreach (ref ch; sample[0 .. length])
        {
            random = random * 1_664_525 + 1_013_904_223;
            ch = cast(char)(random >> 24);
        }
        assert(!parseCron(sample[0 .. length]).ok);
    }
}

@("cron_vectors: month and year rollover, 31st skips short months and Gregorian leap rules")
unittest
{
    const firstOfMonth = parseCron("0 0 0 1 * *");
    assert(firstOfMonth.ok && firstOfMonth.value.nextAfter(1_706_702_400) == 1_706_745_600);
    const newYear = parseCron("0 0 0 1 1 *");
    assert(newYear.ok && newYear.value.nextAfter(1_704_067_199) == 1_704_067_200);
    assert(newYear.value.nextAfter(1_704_067_200) == 1_735_689_600);
    const thirtyFirst = parseCron("0 0 0 31 * *");
    assert(thirtyFirst.ok && thirtyFirst.value.nextAfter(1_714_438_800) == 1_717_113_600);
    const leap = parseCron("0 0 0 29 2 *");
    assert(leap.value.nextAfter(1_740_700_800) == 1_835_395_200);
    assert(leap.value.nextAfter(920_246_400) == 951_782_400);
    assert(leap.value.nextAfter(4_012_934_400) == 4_233_686_400);
}

@("cron_vectors: Sunday is 0 or 7, DOM/DOW use OR only when both are restricted")
unittest
{
    const zero = parseCron("0 0 0 * * 0");
    const seven = parseCron("0 0 0 * * 7");
    assert(zero.ok && seven.ok);
    assert(zero.value.nextAfter(1_705_190_400) == 1_705_795_200);
    assert(seven.value.nextAfter(1_705_190_400) == 1_705_795_200);
    const weekend = parseCron("0 0 0 * * 6-7");
    assert(weekend.ok && weekend.value.nextAfter(1_705_017_600) == 1_705_104_000);
    assert(weekend.value.nextAfter(1_705_104_000) == 1_705_190_400);
    const either = parseCron("0 0 0 13 * 1");
    assert(either.ok && either.value.nextAfter(1_711_843_200) == 1_711_929_600);
    assert(either.value.nextAfter(1_711_929_600) == 1_712_534_400);
    assert(either.value.nextAfter(1_712_534_400) == 1_712_966_400);
    const dayOnly = parseCron("0 0 0 13 * *");
    assert(dayOnly.ok && dayOnly.value.nextAfter(1_711_843_200) == 1_712_966_400);
    const mondayOnly = parseCron("0 0 0 * * 1");
    assert(mondayOnly.ok && mondayOnly.value.nextAfter(1_711_929_600) == 1_712_534_400);
}

@("cron_vectors: comma, range and step forms select exact instants strictly after now")
unittest
{
    const quarter = parseCron("*/15 * * * * *");
    assert(quarter.ok && quarter.value.nextAfter(0) == 15 && quarter.value.nextAfter(45) == 60);
    const sixHours = parseCron("0 0 */6 * * *");
    assert(sixHours.ok && sixHours.value.nextAfter(1_704_067_200) == 1_704_067_200 + 6 * 3600);
    const ranged = parseCron("10-50/20 0 0 * * *");
    assert(ranged.ok && ranged.value.nextAfter(1_704_067_200) == 1_704_067_210);
    assert(ranged.value.nextAfter(1_704_067_210) == 1_704_067_230);
    assert(ranged.value.nextAfter(1_704_067_230) == 1_704_067_250);
    assert(ranged.value.nextAfter(1_704_067_250) == 1_704_067_210 + 86_400);
    const offset = parseCron("30/10 0 0 * * *");
    assert(offset.ok && offset.value.nextAfter(1_704_067_200) == 1_704_067_230);
    assert(offset.value.nextAfter(1_704_067_250) == 1_704_067_200 + 86_400 + 30);
    const listed = parseCron("0 0 9,17 * * 1-5");
    assert(listed.ok && listed.value.nextAfter(1_712_966_400) == 1_713_171_600);
}

@("cron fuzz seeds: truncated, maximum-length, empty and unsupported forms are rejected")
unittest
{
    const string[] rejected = [
        "0", "0 0", "0 0 0", "0 0 0 1", "0 0 0 1 1", "0 0 0 15W * *", "0 0 0 ? * *",
        "0 0 0 * JAN *", "0 0 0 * * SUN", "0 60 0 * * *",
        "0 0 24 * * *", "0 0 0 32 * *", "0 0 0 * 13 *", "0 0 0 * 0 *", "0 0 0 * * 8", "-1 0 0 * * *",
        "0-60 0 0 * * *", "0/61 0 0 * * *", "0,,1 0 0 * * *", "0 0 0 * * 1-", "*5 0 0 * * *",
        "0 0 0 * * *\n"
    ];
    foreach (expression; rejected)
        assert(parseCron(expression).error.code == Status.invalidArgument, expression);
    char[257] padded = ' ';
    padded[0 .. 11] = "0 0 0 * * *";
    assert(parseCron(padded[0 .. 256]).ok);
    assert(parseCron(padded[]).error.code == Status.invalidArgument);
}
