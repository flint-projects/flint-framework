# Flint desktop on Linux

Use `flint.desktop.Window` on the process UI thread to open, run and destroy a native window.
The default renderer is pinned SDL3 with its X11 and software backends. Prepare its system X11
development dependencies, then run
`python3 tools/native_build.py --profile desktop --target linux-x86_64-glibc --phase build --emit-dub`.
The SDL3 header, archive and provider linker metadata are recorded by that build.

`Window.submit` validates a complete frame and queues an owned copy. `postMessage` copies
application bytes from any thread. Each window's shared queue holds 256 packets of up to 16 KiB,
with explicit backpressure. SDL pointer motion coalesces consecutive moves. Resize, clicks, keys
and close requests stay meaningful. The close request retires queue admission before the callback.

`submitWork` accepts a Conc work function and a bounded input copy from the owner thread. Successful
work is delivered as a message with an arena handle valid through its callback. The shared desktop
worker pool holds 256 tickets. Close cancels queued work, joins running work, and releases native
resources on the UI thread. Work functions must eventually return.

## Version-1 draw lists

Use little-endian bytes. The header is `FDL`, version byte `1`, a two-byte record count and two
zero bytes. Each record begins with a one-byte opcode, one zero byte and a two-byte payload length.

| Opcode | Operation | Payload |
| --- | --- | --- |
| 1 | Clear | RGBA bytes |
| 2 | Rectangle | Signed 32-bit x, y, width, height, then RGBA |
| 3 | Glyphs | Signed 32-bit x and y, 16-bit font ID 1, 16-bit glyph count, RGBA, printable ASCII glyph bytes |
| 4 | Image | Signed 32-bit x, y, width, height, 16-bit image ID 1, 16 zero bits, RGBA |
| 5 | Push clip | Signed 32-bit x, y, width, height |
| 6 | Pop clip | Empty |

Coordinates are limited to ±16,384 and dimensions to 0–16,384. A frame can hold 1,024 records,
1,024 glyphs per run and 32 nested clips. The pinned SDL debug-font atlas supplies font ID 1
under its SDL notice. Flint creates image ID 1 as a white pixel and renders it with the requested
size and tint. The renderer presents once after the complete draw list.

## Explicit Linux WebKitGTK profile

Build the system adapter in a separate checkout with
`python3 packages/desktop/native/build_webkitgtk.py --output /path/to/optional-prefix --emit-dub`
after preparing the native desktop profile. It resolves `webkit2gtk-4.1` through pkg-config,
records the actual system SDK versions and adds a separate machine-local DUB block. The opt-in
profile uses the system WebKitGTK and GTK libraries under their own terms. SDL's permissive
profile has a separate provider receipt and link closure.

Select `DesktopBackend.systemWebView` and pass embedded `WindowOptions.html` with an
`entryAsset` name. That document is served through a per-window in-memory origin. It has a CSP
that restricts network requests, frames, forms, objects and base URLs. An optional exact HTTPS
origin permits navigation. It receives no host IPC capability.

Local JavaScript sends an array of byte values to
`window.webkit.messageHandlers.flint.postMessage`. The header is version byte 1, method byte
1 for `app.message`, and a little-endian 16-bit payload length. The payload is limited to 4 KiB. Convert typed buffers with `Array.from`.
Navigation, popup, download and permission handlers close the platform boundary.

Use `native/check_permissive.py` to check an ELF from the default release profile. The optional
adapter inventory and its linked dependency check are separate. `fixtures/verify_webkitgtk.py`
exercises a real native app plus a loopback HTTPS origin with a fixture-specific certificate.

Run the native unit suite with valid SDL provider flags. Set `SDL_VIDEODRIVER=dummy` and
`SDL_RENDER_DRIVER=software` for deterministic headless execution. Use Xvfb and
`SDL_VIDEODRIVER=x11` to exercise the Linux X11 path.
