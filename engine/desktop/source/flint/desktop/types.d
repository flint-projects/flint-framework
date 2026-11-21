/// Value types shared by the desktop owner loop and native adapters.
module flint.desktop.types;

import flint.arena : Buffer, Error, RequestArena;

@safe:

/// Rendering and native window backend selected at startup.
enum DesktopBackend : ubyte
{
    /// Native SDL3 draw list.
    sdl,
    /// Explicit system WebView profile.
    systemWebView
}

/// Event delivered by the owner loop.
enum EventKind : ubyte
{
    close,
    resize,
    key,
    pointer,
    message
}

/// One event and its event-arena message payload.
struct DesktopEvent
{
    /// Event discriminator.
    EventKind kind;
    /// Horizontal coordinate or new width.
    int x;
    /// Vertical coordinate or new height.
    int y;
    /// Native key identifier for key events.
    uint keyCode;
    /// Owned bytes with the lifespan of this handler invocation.
    Buffer message;
}

/// Startup dimensions, backend and optional packaged WebView document.
struct WindowOptions
{
    /// UTF-8 window title.
    string title = "Flint";
    /// Initial width in logical pixels.
    uint width = 1024;
    /// Initial height in logical pixels.
    uint height = 768;
    /// Native renderer selection.
    DesktopBackend backend = DesktopBackend.sdl;
    /// Whether the window accepts resize gestures.
    bool resizable = true;
    /// Relative name of the packaged document.
    string entryAsset = "index.html";
    /// Embedded app HTML served at the native window's private app origin.
    string html;
    /// Optional exact HTTPS origin allowed for navigation with no host IPC.
    string httpsOrigin;
}

/// Owner-thread event visitor. Arena handles expire when the visitor returns.
alias DesktopHandler = Error delegate(ref DesktopEvent event, ref scope RequestArena arena) @safe nothrow @nogc;
