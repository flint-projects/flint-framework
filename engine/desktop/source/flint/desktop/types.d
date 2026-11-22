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
    /// Optional exact HTTPS origin allowed for navigation. It has host IPC only through a capability.
    string httpsOrigin;
    /// Window label matched by capabilities.
    string label = "main";
    /// Embedded frontend files served from the private `flint://localhost/` origin.
    immutable(Asset)[] assets;
    /// Deny-by-default IPC grants for this window.
    immutable(Capability)[] capabilities;
}

/// One embedded frontend file, usually `Asset("index.html", import("index.html"))`.
struct Asset
{
    /// Relative path below the app origin.
    string path;
    /// Exact response bytes.
    string content;
    /// Optional media type; inferred from the extension when empty.
    string mime;
}

/// A set of IPC grants bound to window labels, as in Tauri capability files.
struct Capability
{
    /// Diagnostic name of the grant.
    string identifier;
    /// Window labels receiving the grant, or `"*"`.
    immutable(string)[] windows;
    /// Commands the frontend may invoke.
    immutable(string)[] commands;
    /// Events the frontend may emit to D listeners.
    immutable(string)[] events;
    /// Exact HTTPS origins sharing the grant; the private app origin always holds it.
    immutable(string)[] origins;
}

/// Owner-thread event visitor. Arena handles expire when the visitor returns.
alias DesktopHandler = Error delegate(ref DesktopEvent event, ref scope RequestArena arena) @safe nothrow @nogc;
