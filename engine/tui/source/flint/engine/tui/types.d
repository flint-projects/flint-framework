/// Shared terminal cells and configuration.
module flint.engine.tui.types;

import flint.term : Event;

@safe:

/// One display cell's base scalar and style.
struct Cell
{
    /// Base Unicode scalar.
    dchar rune = ' ';
    /// Packed RGB foreground (zero uses the terminal default).
    uint foreground;
    /// Packed RGB background (zero uses the terminal default).
    uint background;
    /// Bold, italic and underline bits.
    ushort attributes;
}

/// Identity of one submitted command.
struct CommandId
{
    /// Nonzero, process-unique command identity.
    ulong value;
}

/// Identity of one periodic timer.
struct TimerId
{
    /// Nonzero, process-unique timer identity.
    ulong value;
}

/// Work that owns its captures and returns an event from a TUI worker.
alias Command = Event delegate() @safe;

/// Runtime frame pacing and queue bounds.
struct RuntimeOptions
{
    /// Maximum number of frames rendered per second.
    uint maxFramesPerSecond = 60;
    /// Maximum number of live commands and undelivered completions.
    uint maxPendingCommands = 256;
    /// Maximum number of events delivered before the next frame.
    uint maxEventsPerFrame = 1024;
}
