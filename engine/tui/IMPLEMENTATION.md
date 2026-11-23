# Flint terminal UI

`run` owns a Linux terminal session on the caller’s thread. It calls the
model’s safe `update(Event, ref Effects)` method serially and calls its
safe const `view(ref Frame)` method at the configured frame rate.
Input and asynchronous results share a bounded per-frame event budget.
Resize changes coalesce before the next view, and each timer emits at most
one event per frame. Tab is a normal key event for application focus.

A frame’s dimensions are measured in terminal cells. Its writer borrows
grapheme boundaries and cell widths from Style, sanitizes controls, and
compares two grids. Dirty spans include both halves of wide characters
when needed. A copied frame handle expires at callback return. Copied
effect handles similarly expire at the end of their update callback.

Command delegates must capture owned data that is independent of the
model and the frame. A bounded worker queue copies the result payload
before posting an event to the caller’s thread. Queued cancellation
withdraws the work. Cancellation after a command has started discards
its eventual result. Quit closes intake, restores the terminal, and
allows up to two seconds for workers to finish. A late worker owns its
remaining command storage until return.

## Linux verification

```sh
python3 tools/native_build.py --profile tui --target linux-x86_64-glibc --phase build --emit-dub
dub test :tui --compiler=dmd
dub test :tui --compiler=ldc2
python3 tools/gates.py --package tui --gate structural
dub build --root=packages/engine-tui/fixtures --compiler=ldc2
python3 packages/engine-tui/fixtures/test_pty.py packages/engine-tui/fixtures/build/test-tui-pty
```

The PTY fixture checks resize during rendering, focus and paste input,
command saturation, completion on the UI thread, and exact terminal
restoration before a late worker returns. The benchmark and its
reference replay the same 10,000 transitions at each of two terminal
sizes. Both also support an idle terminal probe.

```sh
dub build --root=packages/engine-tui/bench --compiler=ldc2
packages/engine-tui/bench/build/probe-tui --measure
python3 packages/engine-tui/bench/idle.py packages/engine-tui/bench/build/probe-tui
```
