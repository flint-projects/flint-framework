module prompt_replay;

import core.time : MonoTime;
import flint.tui.widget_display_probe : Screen, require;
import std.stdio : writeln;

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
    writeln("prompt ", name, "=", total);
    if (repeat)
        writeln("prompt form_ns=", nanos, " samples=", count);
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
        writeln("prompt choice=", selected, " display_bytes=", bytes, " checksum=", checksum);
        if (measureEnabled)
            writeln("prompt selection_ns=", nanos, " samples=", count, " update_bytes=", keyBytes, " input_events=3");
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
    writeln("prompt secret=", opened, " display_bytes=", emitted, " checksum=", checksum);
    if (measureEnabled)
        writeln("prompt password_ns=", total, " samples=", passes);
}
