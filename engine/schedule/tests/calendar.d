module flint.schedule.calendar_test;

import flint.arena : Status;
import flint.schedule.cron : firstSecond, lastSecond, parseCron;

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
