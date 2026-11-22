/// In-memory terminal capture for widget layout tests.
module flint.tui.widget_test_display;

import flint.arena : Error, Status;
import flint.term : ColorProfile;
import flint.tui : Frame, Size;
import flint.tui.grid : Grid;

@safe:

/// Render one frame on a fresh fake terminal and return its exact output bytes.
string capture(Size size, scope void delegate(ref Frame) @safe paint)
{
    auto grid = new Grid(ColorProfile.none);
    assert(grid.resize(size).code == Status.ok);
    auto frame = Frame(grid, grid.begin());
    paint(frame);
    grid.end();
    string output;
    assert(grid.diff((scope const(char)[] bytes) @safe { output = bytes.idup; return Error.init; }).code == Status.ok);
    return output;
}
