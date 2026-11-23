/// Read-only table snapshots rendered by visible row.
module flint.engine.widgets.table;

import flint.arena : Error, Status;
import flint.engine.style : Style;
import flint.engine.tui : Effects, Event, Frame;
import flint.engine.widgets.internal : fit, navigate, paintLine;

@safe:

/// One display column and its fixed maximum width.
struct Column
{
    /// Heading displayed above visible values.
    string title;
    /// Width in terminal cells.
    uint width;
}

/// A viewport over caller-owned row and column snapshots.
struct Table
{
    /// Read-only columns during a view.
    Column[] columns;
    /// Read-only cells indexed by application row identity.
    string[][] rows;
    /// Selected application row index.
    size_t selected;

    /// Navigate the row snapshot through standard movement keys.
    void update(Event event, ref Effects)
    {
        selected = navigate(event, selected, rows.length);
    }

    /// Draw the heading and only the visible data rows.
    Error view(ref Frame frame, uint column, uint row, uint width, uint height) const
    {
        const area = fit(frame, column, row, width, height);
        if (!area.ok() || area.value.columns == 0 || area.value.rows == 0 || columns.length == 0)
            return area.error;
        const title = drawRow(frame, column, row, area.value.columns, [], true, false);
        if (title.code != Status.ok || rows.length == 0 || area.value.rows == 1)
            return title;
        const remaining = area.value.rows - 1;
        const total = rows.length;
        const current = selected < total ? selected : total - 1;
        const first = current >= remaining ? current - remaining + 1 : 0;
        const count = rows.length - first < remaining ? rows.length - first : remaining;
        foreach (offset; 0 .. count)
        {
            const index = first + offset;
            const written = drawRow(frame, column, row + 1 + cast(uint) offset, area.value.columns,
                    rows[index], false, index == current);
            if (written.code != Status.ok)
                return written;
        }
        return Error.init;
    }

    private Error drawRow(ref Frame frame, uint x, uint y, uint width, scope const(string)[] cells,
            bool heading, bool active) const
    {
        Style style;
        style.bold = heading || active;
        foreach (index, ref const item; columns)
        {
            if (width == 0)
                break;
            const room = item.width < width ? item.width : width;
            const text = heading ? item.title : index < cells.length ? cells[index] : "";
            const status = paintLine(frame, x, y, room, text, style, true);
            if (status.code != Status.ok)
                return status;
            x += room;
            width -= room;
        }
        return Error.init;
    }
}
