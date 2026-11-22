/// Scrollable blocks and compact terminal indicators.
module flint.widgets.display;

import flint.arena : Error, Status;
import flint.tui : Effects, Event, EventKind, Frame;
import flint.widgets.internal : fit, lineCount, navigate, paintLine, paintLines;
import std.math.traits : isFinite;

@safe:

// Decimal text of a page number, as std.conv.to!string writes it.
package(flint) string decimal(size_t value) pure nothrow
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

/// A scrollable snapshot of multiline text.
struct Viewport
{
    /// Text displayed by the viewport.
    string text;
    /// Zero-based position of the first visible line.
    size_t firstLine;

    /// Move the visible line origin using the supplied key.
    void update(Event event, ref Effects)
    {
        if (event.kind == EventKind.key)
            firstLine = navigate(event, firstLine, lineCount(text));
    }

    /// Draw visible content within the supplied rectangle.
    Error view(ref Frame frame, uint column, uint row, uint width, uint height) const
    {
        const region = fit(frame, column, row, width, height);
        if (!region.ok())
            return region.error;
        return paintLines(frame, column, row, region.value, text, firstLine);
    }
}

/// A bounded horizontal completion indicator.
struct Progress
{
    /// Completion fraction, clamped to the unit interval at view time.
    double fraction;

    /// Draw the clamped fraction in the available columns.
    Error view(ref Frame frame, uint column, uint row, uint width) const
    {
        if (!isFinite(fraction))
            return Error(Status.invalidArgument, "progress fraction must be finite");
        const area = fit(frame, column, row, width, 1);
        if (!area.ok())
            return area.error;
        const normalized = fraction < 0.0 ? 0.0 : fraction > 1.0 ? 1.0 : fraction;
        const filled = cast(uint)(normalized * area.value.columns);
        auto text = new char[area.value.columns];
        text[0 .. filled] = '=';
        text[filled .. $] = '-';
        return area.value.columns == 0 ? Error.init : frame.put(column, row, text);
    }
}

/// A small monochrome activity indicator.
struct Spinner
{
    /// Current step, advanced only by tick.
    uint frame;
    private enum steps = "|/-\\";

    /// Advance to the next animation step.
    void tick()
    {
        frame = (frame % steps.length + 1) % steps.length;
    }

    /// Draw one indicator cell.
    Error view(ref Frame surface, uint column, uint row) const
    {
        const index = frame % steps.length;
        return surface.put(column, row, steps[index .. index + 1]);
    }
}

/// A display-only current page indicator.
struct Paginator
{
    /// Zero-based preferred page.
    size_t page;
    /// Number of available pages.
    size_t pageCount;

    /// Draw the one-based page number, or leave the empty state blank.
    Error view(ref Frame frame, uint column, uint row) const
    {
        const area = fit(frame, column, row, uint.max, 1);
        if (!area.ok() || pageCount == 0)
            return area.error;
        const current = page < pageCount ? page + 1 : pageCount;
        return paintLine(frame, column, row, area.value.columns, decimal(current) ~ "/" ~ decimal(pageCount));
    }
}
