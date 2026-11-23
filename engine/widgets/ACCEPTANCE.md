# flint:engine-widgets acceptance traceability

Source: `handoff/specs/tier-4/widgets.md` section 6. Unit tests run with `dub test :widgets` on DMD and LDC.
The PTY snapshot runs `fixtures/test_snapshot.py fixtures/build/test-widgets-pty` (build with
`dub build --root=engine/widgets/fixtures`).

| ID | Required item | Covering test(s) | Status |
| --- | --- | --- | --- |
| WIDGET-01 | Backspace an emoji ZWJ sequence deletes one grapheme | `tests/contract_tests.d:Widget editing removes, navigates, and selects complete graphemes` (`👩‍🔬`) | covered |
| WIDGET-01 | Backspace a combining sequence deletes one grapheme | same test (`é`) | covered |
| WIDGET-02 | Paste at the 4096-byte limit accepts complete graphemes only | `tests/contract_tests.d:The byte cap rejects incomplete paste clusters and normalizes CRLF` | covered |
| WIDGET-02 | Cap falling inside a multibyte character or grapheme | `tests/contract_tests.d:WIDGET-02 a grapheme crossing the byte cap is rejected whole, including typed input` (combining sequence at 4095, truncated scalar, typed key at the cap, ZWJ emoji over a 3-byte cap) | added |
| WIDGET-03 | Filter removes the selected item, all remaining items disabled: deterministic no-selection | `tests/contract_tests.d:WIDGET-03 filtering away the selection over disabled survivors leaves no selection`; `List filtering preserves stable identity and guards disabled submissions` | added |
| WIDGET-03 | Enter does not submit a disabled item | `WIDGET-03 ...` (Enter and every navigation key keep `size_t.max`); prompt PTY `select`/`multi` with a disabled first choice (`engine/prompt/fixtures/test_prompt.py`) | added |
| WIDGET-04 | Empty columns | `tests/contract_tests.d:Table cells clip printable ASCII without splitting a trailing mark and pad every column` (zero-width column); `WIDGET-04 tables without columns, narrower areas and stale selections stay in bounds` (no columns) | added |
| WIDGET-04 | Short rows padded | `Table cells clip ...` (rows with 2 and 0 cells) | covered |
| WIDGET-04 | Oversized cell clipped, no bounds access | `Table cells clip ...`; `WIDGET-04 ...` (40-cell column in a 5-cell frame, stale selection 99, origin outside the frame) | covered |
| WIDGET-05 | Progress -1 and 2 clamp to finite output | `tests/contract_tests.d:WIDGET-05 progress clamps finite values, rejects NaN, and zero pages draw nothing`; PTY snapshot rows 8-9 | added (unit test) |
| WIDGET-05 | Progress NaN/infinity returns invalidArgument | `Navigation and indicator edge cases remain bounded`; `WIDGET-05 ...` (active frame, -infinity) | covered |
| WIDGET-05 | Paginator zero pages: empty state, no division by zero | `WIDGET-05 ...` (`Paginator(0, 0)` and `Paginator(7, 0)` draw nothing; `Paginator(9, 4)` shows `4/4`); PTY snapshot rows 11-12. The earlier unit test only read the `page` field | added |
| WIDGET-06 | Million-row table with 20 visible rows visits O(visible rows) | `tests/contract_tests.d:WIDGET-06 a million-row table touches only visible row pages per frame` (rows live in an mmap region; every page outside the visible window is `PROT_NONE`, so any other row access faults; checked at the start, middle and end, and `update` runs with every row page unreadable) | added |
| Fuzz | Paste lengths 0..256 and 1 KiB/1 MiB | `tests/fuzz/edit.d:Widget paste handles malformed prefixes and the 1 MiB boundary` | covered |

Stub review: none found. `bench/trace/visits.c` (a style-scalar counter) is not wired to any runner and the
bench rows are ASCII, so it cannot observe row visits; WIDGET-06 now has its own guard-page test.
