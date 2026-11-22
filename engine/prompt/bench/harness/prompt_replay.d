module prompt_replay;

import core.stdc.stdio : printf;
import core.time : MonoTime;
import flint.tui.widget_display_probe : Screen, require;

@safe:

/// Fields validated on every pass.
enum fields = 100;
/// Choices in the representative selection case.
enum choices = 10_000;
/// Password prompt lifecycles observed per pass.
enum secrets = 10_000;
/// Shared native capacity for one password prompt.
enum capacity = 4_096;
/// Immutable fixture text consumed through the actual owner.
enum sample = "replay-42";
/// Exact app title supplied to both selectors.
enum title = "Pick a fixture option";
/// Simulated query for case-folded selection.
enum filter = "STRASSE";

/// Work that produces a consumed result.
alias Work = ulong function() @safe;
/// Password controls may call the pinned libc primitives directly.
alias PasswordWork = ulong function(Screen) @system;
/// Exercise one 10,000-entry selector and write its fake terminal output.
alias Pick = ulong function(Screen) @safe;

/// Decimal text of a fixture ordinal, used for generated keys and choice values.
string decimal(ulong value) pure nothrow
{
    char[20] digits;
    size_t start = digits.length;
    do
    {
        digits[--start] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value != 0);
    return digits[start .. $].idup;
}

/// Parse a selected decimal choice value, rejecting empty, non-digit or overflowing text.
ulong parseDecimal(scope const(char)[] text) pure
{
    if (text.length == 0)
        throw new Exception("choice value is empty");
    ulong value;
    foreach (character; text)
    {
        if (character < '0' || character > '9')
            throw new Exception("choice value is not a decimal number");
        const digit = character - '0';
        if (value > (ulong.max - digit) / 10)
            throw new Exception("choice value overflows");
        value = value * 10 + digit;
    }
    return value;
}

// SAFETY: Each C format string is a fixed NUL-terminated literal; the name is printed with its
// explicit length and every scalar matches its conversion.
private void printForm(string name, ulong total, bool repeat, long nanos, uint count) @trusted nothrow @nogc
{
    printf("prompt %.*s=%llu\n", cast(int) name.length, name.ptr, total);
    if (repeat)
        printf("prompt form_ns=%lld samples=%u\n", nanos, count);
}

private void measure(string name, Work work, bool repeat)
{
    ulong total;
    uint count;
    long nanos;
    do
    {
        const started = MonoTime.currTime;
        total = work();
        nanos += (MonoTime.currTime - started).total!"nsecs";
        ++count;
    }
    while (repeat && nanos < 100_000_000);
    require(total == fields);
    printForm(name, total, repeat, nanos, count);
}

/// Replay the full form, selector, and mass secret lifecycle workload.
void replay(string[] args, Work form, Pick pick, PasswordWork password) @system
{
    const passwordOnly = args.length > 1 && args[1] == "--password-only";
    const measureEnabled = args.length > 1 && args[1] == "--measure";
    if (!passwordOnly)
    {
        measure("fields", form, measureEnabled);
        ulong selected;
        ulong bytes;
        ulong keyBytes;
        ulong checksum;
        uint count;
        long nanos;
        do
        {
            auto terminal = new Screen(80, 24);
            const started = MonoTime.currTime;
            selected = pick(terminal);
            nanos += (MonoTime.currTime - started).total!"nsecs";
            bytes = terminal.bytes;
            keyBytes = bytes - terminal.firstBytes;
            checksum = terminal.checksum;
            ++count;
        }
        while (measureEnabled && nanos < 100_000_000);
        require(selected == 17);
        printf("prompt choice=%llu display_bytes=%llu checksum=%llu\n", selected, bytes, checksum);
        if (measureEnabled)
            printf("prompt selection_ns=%lld samples=%u update_bytes=%llu input_events=3\n", nanos, count, keyBytes);
    }
    ulong opened;
    ulong emitted;
    ulong checksum;
    uint passes;
    long total;
    do
    {
        auto terminal = new Screen(80, 24);
        const started = MonoTime.currTime;
        opened = password(terminal);
        total += (MonoTime.currTime - started).total!"nsecs";
        emitted = terminal.bytes;
        checksum = terminal.checksum;
        ++passes;
        require(opened == secrets * sample.length);
    }
    while (measureEnabled && total < 100_000_000);
    printf("prompt secret=%llu display_bytes=%llu checksum=%llu\n", opened, emitted, checksum);
    if (measureEnabled)
        printf("prompt password_ns=%lld samples=%u\n", total, passes);
}
