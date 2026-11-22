# golden-desktop

A Flint desktop application in the Tauri style (see `docs/adr/ADR-020-desktop-webview-shell.md`): an HTML/JS frontend embedded with `import`, served from `flint://localhost/`, calling typed D commands through `flint.invoke`, receiving D events through `flint.listen`, and limited by a deny-by-default capability.

Prepare the native desktop profile, which records the system GTK 3 and WebKitGTK 4.1 libraries, then build and run from this directory:

```bash
python3 tools/native_build.py --profile desktop --target linux-x86_64-glibc --phase build --emit-dub
dub build --compiler=dmd
./golden-desktop
```

`./golden-desktop --self-test` loads `selftest.html`, which clicks the real controls, checks a denied command and a malformed argument, reports what the page observed and closes the window. `python3 verify.py ./golden-desktop` runs that session and checks the result. Set `FLINT_DESKTOP_CONSOLE=1` to copy page console messages to stdout and `FLINT_DESKTOP_DEVTOOLS=1` to enable the WebKit inspector.
