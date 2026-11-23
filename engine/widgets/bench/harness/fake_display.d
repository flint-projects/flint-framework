/// Shared in-memory terminal cell observer for the widget and prompt probes.
module flint.engine.tui.widget_display_probe;

import flint.arena : Error, Status;
import flint.term : ColorProfile;
import flint.engine.tui : Frame, Size;
import flint.engine.tui.grid : Grid;

@safe:

/// Fail release probes on incorrect output or a rejected cell write.
void require(bool valid) nothrow @nogc
{
    if (!valid)
        assert(0, "terminal probe invariant failed");
}

/// Fixed fake terminal with actual frame encoding and consumption.
final class Screen
{
    private Grid surface;

    /// Total output bytes consumed across frames.
    ulong bytes;
    /// Bytes in the first frame, isolated from update emission.
    ulong firstBytes;
    private uint draws;
    /// Rolling checksum of actual terminal bytes.
    ulong checksum = 14_695_981_039_346_656_037UL;

    /// Create a fake terminal viewport.
    this(uint width, uint height)
    {
        surface = new Grid(ColorProfile.none);
        require(surface.resize(Size(width, height)).code == Status.ok);
    }

    /// Render one frame and account for all emitted bytes.
    void draw(scope void delegate(ref Frame) @safe show)
    {
        auto frame = Frame(surface, surface.begin());
        show(frame);
        surface.end();
        require(surface.diff((scope const(char)[] data) @safe {
                bytes += data.length;
                foreach (value; data)
                    checksum = (checksum ^ cast(ubyte) value) * 1_099_511_628_211UL;
                return Error.init;
            }).code == Status.ok);
        if (draws++ == 0)
            firstBytes = bytes;
    }
}
