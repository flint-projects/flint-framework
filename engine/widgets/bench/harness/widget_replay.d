module widget_replay;

import core.time : MonoTime;
import flint.tui.widget_display_probe : Screen, require;
import std.stdio : writeln;
import std.conv : to;

@safe:

/// Fixed query requiring real Unicode normalization and folding.
enum query = "STRASSE";
/// Matching label in every tenth row.
enum matchLabel = "Straße";
/// Label excluded by the fixed query.
enum ordinaryLabel = "catalog record";
/// One snapshot displays exactly twenty data rows.
enum visibleRows = 20;
/// Retained exact input size for the editing measurement.
enum maximumText = 1_048_576;

/// Once-installed renderer receiving a warmed snapshot.
alias Renderer = void delegate(Screen) @safe;
/// Filtering, cached list and table rendering for the fixture.
alias Prepare = long function(size_t, out Renderer, out Renderer) @safe;
/// Append and erase one character from a full-size textarea.
alias Edit = ulong function() @safe;

private long time(Renderer draw, Screen display, bool measure)
{
    long total;
    uint passes;
    do
    {
        const start = MonoTime.currTime;
        draw(display);
        total += (MonoTime.currTime - start).total!"nsecs";
        ++passes;
    }
    while (measure && total < 100_000_000);
    return total / passes;
}

/// Exercise both dataset sizes and near-capacity editing.
void replay(Prepare prepare, Edit edit, bool measure)
{
    foreach (count; [1_000UL, 1_000_000UL])
    {
        Renderer list;
        Renderer table;
        const filter = prepare(cast(size_t) count, list, table);
        auto printedList = new Screen(80, visibleRows);
        auto printedTable = new Screen(80, visibleRows + 1);
        const listAverage = time(list, printedList, measure);
        const tableAverage = time(table, printedTable, measure);
        require(printedList.bytes != 0 && printedTable.bytes != 0);
        writeln("widgets rows=", count, " list=", printedList.checksum, " table=",
                printedTable.checksum, " list_bytes=", printedList.bytes, " table_bytes=", printedTable.bytes);
        if (measure)
            writeln("widgets filter_ns=", filter, " cached_list_ns=", listAverage, " table_view_ns=", tableAverage);
    }
    ulong edited;
    uint passes;
    long elapsed;
    do
    {
        const start = MonoTime.currTime;
        edited = edit();
        elapsed += (MonoTime.currTime - start).total!"nsecs";
        require(edited == maximumText);
        ++passes;
    }
    while (measure && elapsed < 100_000_000);
    writeln("widgets edit=", edited);
    if (measure)
        writeln("widgets edit_elapsed_ns=", elapsed, " edit_samples=", passes);
}

/// Run an isolated data-size case so native trace calls count only table rendering.
void tableOnly(Prepare prepare, scope const(char)[] requested)
{
    const count = requested.to!size_t;
    require(count == 1_000 || count == 1_000_000);
    Renderer list;
    Renderer table;
    prepare(count, list, table);
    auto screen = new Screen(80, visibleRows + 1);
    table(screen);
    writeln("widgets table_count=", count, " bytes=", screen.bytes, " checksum=", screen.checksum);
}
