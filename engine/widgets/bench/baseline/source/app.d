module flint.benchmarks.reference_widget_probe;

import core.time : MonoTime;
import flint.arena : Status;
import flint.style : Style, foldGraphemes, measure, truncateCells;
import flint.tui : Frame;
import flint.tui.widget_display_probe : Screen, require;
import std.string : indexOf;
import widget_replay : Renderer, matchLabel, maximumText, ordinaryLabel, query, replay, tableOnly;

@safe:

private void cell(ref Frame frame, uint x, uint row, scope const(char)[] input, Style style)
{
    const actual = truncateCells(input, 12, "");
    require(frame.put(x, row, actual, style).code == Status.ok);
    const width = measure(actual).cells;
    if (width < 12)
    {
        auto padding = new char[12 - width];
        padding[] = ' ';
        require(frame.put(x + width, row, padding, style).code == Status.ok);
    }
}

private long prepare(size_t count, out Renderer renderList, out Renderer renderTable)
{
    auto items = new string[count];
    auto rows = new string[][](count);
    auto sample = new string[2];
    sample[] = ["0123456789012345", "bounded"];
    foreach (index; 0 .. count)
    {
        items[index] = index % 10 == 0 ? matchLabel : ordinaryLabel;
        rows[index] = sample;
    }
    string pattern;
    size_t[] visible;
    const start = MonoTime.currTime;
    require(foldGraphemes(query, pattern));
    foreach (index, item; items)
    {
        string folded;
        if (foldGraphemes(item, folded) && folded.indexOf(pattern) >= 0)
            visible ~= index;
    }
    const filtering = (MonoTime.currTime - start).total!"nsecs";
    require(visible.length == count / 10 && visible[0] == 0);
    renderList = (Screen surface) @safe {
        surface.draw((ref Frame frame) @safe {
            foreach (row; 0 .. frame.rows)
            {
                Style style;
                style.bold = row == 0;
                require(frame.put(0, row, row == 0 ? "> " : "  ", style).code == Status.ok);
                const label = truncateCells(items[visible[row]], frame.columns - 2, "");
                require(frame.put(2, row, label, style).code == Status.ok);
            }
        });
    };
    renderTable = (Screen surface) @safe {
        surface.draw((ref Frame frame) @safe {
            Style bold;
            bold.bold = true;
            cell(frame, 0, 0, "Item", bold);
            cell(frame, 12, 0, "Value", bold);
            foreach (row; 1 .. frame.rows)
            {
                const style = row == 1 ? bold : Style.init;
                cell(frame, 0, row, rows[row - 1][0], style);
                cell(frame, 12, row, rows[row - 1][1], style);
            }
        });
    };
    return filtering;
}

private ulong edit()
{
    auto bytes = new char[maximumText];
    bytes[] = 'x';
    string value = bytes.idup;
    foreach (_; 0 .. 32)
    {
        value = value[0 .. $ - 1];
        value ~= "x";
    }
    require(value[$ - 1] == 'x');
    return value.length;
}

int main(string[] args)
{
    if (args.length == 3 && args[1] == "--table-only")
        tableOnly(&prepare, args[2]);
    else
        replay(&prepare, &edit, args.length > 1 && args[1] == "--measure");
    return 0;
}
