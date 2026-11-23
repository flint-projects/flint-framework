module widget_replay;

import core.stdc.stdio : printf;
import core.time : MonoTime;
import flint.engine.tui.widget_display_probe : Screen, require;

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
        printRows(count, printedList, printedTable);
        if (measure)
            printViews(filter, listAverage, tableAverage);
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
    printEdit(edited, measure, elapsed, passes);
}

/// Run an isolated data-size case so native trace calls count only table rendering.
void tableOnly(Prepare prepare, scope const(char)[] requested)
{
    const count = parseCount(requested);
    require(count == 1_000 || count == 1_000_000);
    Renderer list;
    Renderer table;
    prepare(count, list, table);
    auto screen = new Screen(80, visibleRows + 1);
    table(screen);
    printTable(count, screen.bytes, screen.checksum);
}

private size_t parseCount(scope const(char)[] text) pure
{
    if (text.length == 0)
        throw new Exception("row count is empty");
    size_t value;
    foreach (character; text)
    {
        if (character < '0' || character > '9')
            throw new Exception("row count is not a decimal number");
        const digit = character - '0';
        if (value > (size_t.max - digit) / 10)
            throw new Exception("row count overflows");
        value = value * 10 + digit;
    }
    return value;
}

// SAFETY: The C format string is a fixed NUL-terminated literal with matching scalar arguments.
private void printRows(ulong count, Screen list, Screen table) @trusted
{
    printf("widgets rows=%llu list=%llu table=%llu list_bytes=%llu table_bytes=%llu\n", count,
            list.checksum, table.checksum, list.bytes, table.bytes);
}

// SAFETY: The C format string is a fixed NUL-terminated literal with matching scalar arguments.
private void printViews(long filter, long listAverage, long tableAverage) @trusted nothrow @nogc
{
    printf("widgets filter_ns=%lld cached_list_ns=%lld table_view_ns=%lld\n", filter, listAverage, tableAverage);
}

// SAFETY: Each C format string is a fixed NUL-terminated literal with matching scalar arguments.
private void printEdit(ulong edited, bool measure, long elapsed, uint passes) @trusted nothrow @nogc
{
    printf("widgets edit=%llu\n", edited);
    if (measure)
        printf("widgets edit_elapsed_ns=%lld edit_samples=%u\n", elapsed, passes);
}

// SAFETY: The C format string is a fixed NUL-terminated literal with matching scalar arguments.
private void printTable(size_t count, ulong bytes, ulong checksum) @trusted nothrow @nogc
{
    printf("widgets table_count=%zu bytes=%llu checksum=%llu\n", count, bytes, checksum);
}
