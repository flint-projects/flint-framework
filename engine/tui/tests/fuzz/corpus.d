module flint.engine.tui.corpus;

import flint.arena : Error, Status;
import flint.term : ColorProfile, Size;
import flint.engine.tui.grid : Frame, Grid;

@safe:

private void feed(Grid grid, scope const(char)[] input)
{
    auto frame = Frame(grid, grid.begin());
    assert(frame.put(0, 0, input).code == Status.ok);
    grid.end();
    const status = grid.diff((scope const(char)[] bytes) @safe {
        assert(bytes.length < 2048);
        return Error.init;
    });
    assert(status.code == Status.ok);
}

@("Frame fuzz seeds exercise malformed UTF-8, control boundaries and the text byte ceiling")
unittest
{
    auto grid = new Grid(ColorProfile.none);
    assert(grid.resize(Size(16, 3)).code == Status.ok);
    char[256] seeds;
    uint pseudo = 982;
    foreach (ref ch; seeds)
    {
        pseudo = pseudo * 1_664_525U + 1_013_904_223U;
        ch = cast(char)(pseudo >> 24);
    }
    foreach (length; 0 .. 257)
        feed(grid, seeds[0 .. length]);
    feed(grid, "\x1b]0;bad\a\x1b[31m\u0301\n" ~ "🧪\xF0");
    auto large = new char[1_048_577];
    large[] = 'x';
    foreach (length; [1_023, 1_024, 1_025, 1_048_575, 1_048_576])
        feed(grid, large[0 .. length]);
    auto frame = Frame(grid, grid.begin());
    assert(frame.put(0, 0, large).code == Status.resourceExhausted);
    grid.end();
}
