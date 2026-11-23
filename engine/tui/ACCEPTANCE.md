# flint:engine-tui acceptance traceability

Source: `handoff/specs/tier-4/tui.md` section 6. Unit tests run with `dub test :tui` on DMD and LDC.
PTY rows run `fixtures/test_pty.py fixtures/build/test-tui-pty` (build with
`dub build --root=engine/tui/fixtures`). Compile-negative fixtures run with
`python3 engine/tui/negative/check.py <dmd|ldc2>`, which also compiles a repaired positive control.

| ID | Required item | Covering test(s) | Status |
| --- | --- | --- | --- |
| TUI-01 | Same model and size rendered twice emits zero cell updates | `tests/contract_tests.d:The second equal view emits zero bytes, and adjacent changed cells form one span` | covered |
| TUI-02 | One character change repaints only affected cells | same test (`\x1b[1;2HCD` only) | covered |
| TUI-02 | Width-2 grapheme: stale continuation cleared | `tests/contract_tests.d:Wide and combining graphemes retain intact bytes and clear obsolete continuation cells`; `tests/contract_tests.d:Printable ASCII clips at the right edge and clears the wide graphemes it overwrites` | covered |
| TUI-03 | Resize during a slow command gives one full repaint | `fixtures/test_pty.py:exercise` default mode (two resizes while a 360 ms command runs; exactly two `ESC[2J`: initial + one resize); `tests/contract_tests.d:A resize burst that returns to the displayed size still repaints the reflowed terminal once` | covered |
| TUI-03 | Command event returns to the same UI thread | `fixtures/interactive.d` asserts the owner thread in every `update`; PTY default mode receives `COMPLETED=1` | covered |
| TUI-04 | 257th submission with maxPendingCommands=256 fails | `tests/contract_tests.d:A 256-command registry refuses overflow and retires both queued and running identities`; PTY `saturated` (`QUEUE=256`, 257th `resourceExhausted`) | covered |
| TUI-04 | No unbounded allocation | registry arrays are sized once in `Commands.this`; the 256-command test reuses freed slots | covered |
| TUI-04 | No dropped key input | PTY `saturated` (Tab after saturation still repaints `FOCUS=2`) | covered |
| TUI-05 | quit while workers run completes within 2 s and restores the terminal | PTY `late` (timer quits with a 3.3 s worker; exit < 2.7 s, terminal restored before `WORKER COMPLETE`) | covered |
| TUI-05 | quit while terminal input blocks | PTY `auto` (command completion quits while input is idle) and `late` | covered |
| TUI-06 | Retained Frame: later mutation returns invalidArgument, stale storage untouched | `tests/contract_tests.d:Resize invalidates both surfaces, bounds are checked, and stale handles never touch storage` | covered |
| Safety | Borrowed command capture, mutable view and private worker import are rejected at compile time | `negative/borrowed_command.d`, `negative/mutable_view.d`, `negative/private_worker.d` via `negative/check.py` | covered (runner added) |
| Usage | Spec `Counter` fixture compiles against `run!M` | `tests/contract_tests.d` `static assert` over `SpecCounter`; `fixtures/model_minimal.d` | added |
| Fuzz | Frame text lengths 0..256 and 1 KiB/1 MiB | `tests/fuzz/corpus.d:Frame fuzz seeds exercise malformed UTF-8, control boundaries and the text byte ceiling` | covered |

Golden TUI: `/dev/shm/flint-review/bin/golden_tui_pty.py examples/golden-tui/golden-tui` passes on DMD and LDC.

Stub review: none found. A stale `Effects` handle ignores `quit` and returns invalidArgument for the other
operations, as documented.
