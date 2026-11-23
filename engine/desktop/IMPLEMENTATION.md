# Flint desktop on Linux

Flint desktop apps are built the way Tauri v2 builds them, in D. The window and event loop come from GTK 3, which uses GDK's native Wayland backend or X11. The UI is a system WebKitGTK 4.1 webview. The frontend calls typed D commands, both sides exchange events, and capabilities scope every call. `docs/adr/ADR-020-desktop-webview-shell.md` records the design. GLib, GTK and WebKitGTK are bound directly with `extern(C)` declarations in `flint.desktop.ffi.webkit`; there is no Rust and no C shim on this path.

## Prepare and test

```bash
python3 tools/native_build.py --profile desktop --target linux-x86_64-glibc --phase build --emit-dub
dub test :desktop --compiler=dmd
dub test :desktop --compiler=ldc2
```

The `desktop` profile resolves `webkit2gtk-4.1` and `gtk+-3.0` through `pkg-config` (override with `--pkg-config` or `PKG_CONFIG`). It refuses versions older than the locked minimums and refuses static archives. The install receipt records the resolved versions, each `.pc` file's SHA256 and the link flags, with an rpath for every non-standard library directory, so NixOS needs no `LD_LIBRARY_PATH`. Emitted DUB blocks re-check those digests and set version `FlintNativeWebkitgtk`. The suite needs a real display and fails without one. On NixOS, `nix-shell -p cmake ninja gcc pkg-config webkitgtk_4_1 gtk3` provides the build inputs.

On macOS the `desktop` profile selects the `wkwebview` provider instead: AppKit and WKWebView, bound from D through the Objective-C runtime in `flint.desktop.ffi.wkwebview`, with the same IPC, asset, capability and navigation behaviour. The receipt records the macOS SDK and the SHA256 of each framework stub, and emitted DUB blocks set version `FlintNativeWkwebview`. The suite needs the user's GUI session (ADR-024).

## Application model

```d
@DesktopCommands
struct Calculator
{
    @Command("add")
    Result!Sum add(scope const ref AddRequest request, ref scope InvokeContext context) nothrow @nogc
    {
        return Result!Sum(Sum(request.a + request.b));
    }
}

struct Application { Calculator calculator; }

static immutable Asset[] assets = [Asset("index.html", import("index.html"))];
static immutable Capability[] grants = [Capability("main", ["main"], ["add"])];
```

Open a `Window` with `DesktopBackend.systemWebView`, `assets` and `capabilities`, then call `window.serve(app, context)` on the process main thread.

- **Commands.** A method in a `@DesktopCommands` field of the explicit application struct, marked `@Command("name")`. It takes `(ref scope InvokeContext)` or `(scope const ref Dto, ref scope InvokeContext)`, and returns `Result!T` or `Error`. Arguments are decoded with `flint:serde`, rejecting unknown fields, before the method runs. The result is encoded into the invocation arena, and the arena expires when the reply has been sent. Duplicate names and other signatures do not compile.
- **Events.** `Window.emit(name, value)` and `InvokeContext.emit` send to `flint.listen(name, callback)` and work on the UI thread only. `flint.emit(name, payload)` reaches `@Listen("name")` methods, typed like commands.
- **Capabilities.** A frame is dispatched only if some `Capability` lists its window label (or `"*"`), its origin and its command or event name. The private app origin `flint://localhost` always qualifies; exact HTTPS origins qualify only when listed in `origins`. Everything else is rejected with `permissionDenied` before decoding.
- **Frontend API.** A frozen `window.flint` object with `invoke`, `emit` and `listen` is injected into the top frame before page scripts run. Rejections are `Error` objects with a `code` (a Flint `Status` name) and a `message`.

## Assets, navigation and limits

`Asset { path, content, mime }` files are served at `flint://localhost/<path>`. The media type is inferred from the extension unless `mime` is set. Each response carries `Content-Type`, the default Content-Security-Policy (same-origin scripts, styles, images, fonts and fetches; inline scripts and styles; no frames, objects, forms or base URLs), `nosniff` and `no-store`. Navigation is limited to the app origin and the window's exact `httpsOrigin`. New windows, downloads and permission requests are refused.

Bridge frames are at most 16 KiB, and names match `[A-Za-z0-9_.:-]{1,64}`. Each window buffers 64 frames between GTK iterations; an overflowing invoke is rejected with `resourceExhausted`. Invocation arenas hold 32 KiB. `postMessage` and `submitWork` keep their 256-packet, 16 KiB queues and the 256-ticket worker pool. Close retires queue admission, cancels and joins work, disconnects every GTK signal, then destroys the window.

`FLINT_DESKTOP_CONSOLE=1` copies page console output to stdout. `FLINT_DESKTOP_DEVTOOLS=1` enables the WebKit inspector. On NVIDIA's driver under Wayland, Flint sets `__NV_DISABLE_EXPLICIT_SYNC=1` before GTK starts, unless it is already set: the driver's explicit-sync path otherwise fails the compositor's syncobj check with Wayland protocol error 71.

## Licensing

GTK and WebKitGTK are LGPL system libraries, linked dynamically and never redistributed modified, like glibc. `native/check_permissive.py <elf>` fails if an executable defines GTK, GDK, WebKit, JavaScriptCore or libsoup symbols itself (static linking). It lists the dynamic webview dependencies. `--no-system-webview` refuses them entirely, for canvas-only artifacts.

## SDL canvas backend

`DesktopBackend.sdl` and the version-1 draw list remain as an optional immediate-mode canvas. Build it with `--profile desktop-canvas`, which pins SDL3 with its X11, offscreen and dummy drivers. `Window.submit` validates a whole frame and queues an owned copy, and the renderer presents once per draw list.

Draw lists are little-endian. The header is `FDL`, version byte `1`, a two-byte record count and two zero bytes. Each record has a one-byte opcode, one zero byte and a two-byte payload length.

| Opcode | Operation | Payload |
| --- | --- | --- |
| 1 | Clear | RGBA bytes |
| 2 | Rectangle | Signed 32-bit x, y, width, height, then RGBA |
| 3 | Glyphs | Signed 32-bit x and y, 16-bit font ID 1, 16-bit glyph count, RGBA, printable ASCII glyph bytes |
| 4 | Image | Signed 32-bit x, y, width, height, 16-bit image ID 1, 16 zero bits, RGBA |
| 5 | Push clip | Signed 32-bit x, y, width, height |
| 6 | Pop clip | Empty |

Coordinates are limited to ±16,384 and dimensions to 0–16,384. A frame holds at most 1,024 records, 1,024 glyphs per run and 32 nested clips. The `bench/` probes measure this canvas backend.
