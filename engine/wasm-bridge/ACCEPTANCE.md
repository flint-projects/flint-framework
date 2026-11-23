# flint:engine-wasm-bridge acceptance traceability

Source: `handoff/specs/tier-5/wasm-bridge.md` section 6. Guest-side encoding is tested in `tests/contract_tests.d`. Host-side validation is in `benchmarks/bench-wasm/driver.mjs`, which this package's `fixtures/parity.mjs` (Node) and `fixtures/browser.html` (headless Chromium via `fixtures/check_browser.mjs`) exercise. All seeds are fixed.

| Item | Requirement (brief) | Covering test or fixture | Status |
| --- | --- | --- | --- |
| BRIDGE-01 | Exact capacity succeeds; overflow is resourceExhausted and the prior batch is unchanged | `tests/contract_tests.d:exact capacity, atomic failure and nested scoped borrows` | covered |
| BRIDGE-01 | One byte beyond an exact fit; 16 MiB storage accepted, 16 MiB + 1 rejected | `tests/contract_tests.d:BRIDGE-01 one byte beyond an exact frame is rejected without touching the prior batch` | added |
| BRIDGE-01 | Host batch limits: 4096 commands accepted and 4097 rejected; 1048576 bytes accepted and 1048584 rejected | `fixtures/parity.mjs` (command limit block, then the "exact batch limit" block) | covered / added |
| BRIDGE-02 | Malformed record length, integer wrap, unknown opcode and invalid UTF-8 rejected by the host | `fixtures/parity.mjs` (record lengths 0/1/15/17/0x80000000/0xffffffff, every truncation, opcode 65535, padding, surrogate UTF-8) | covered |
| BRIDGE-02 | A batch with a valid prefix and a bad final record leaves the registry and the DOM untouched | `fixtures/parity.mjs` (atomic rejection block); `fixtures/browser.html` corrupts the last record's opcode and checks that no MutationObserver records appear | added |
| BRIDGE-02 | Encoder rejects invalid UTF-8, matching an independent decoder; every text length 0..256, 1 KiB and 64 KiB boundaries encode exactly; 65537 bytes and 1 MiB rejected | `tests/contract_tests.d:BRIDGE-02 seeded UTF-8 corpus matches an independent validator and every length 0..256 encodes exactly` | added |
| BRIDGE-02 | Freestanding wasm32 build of every opcode links without libc | `tests/betterc.d` (all seven opcodes, unoptimized `wasm_betterc` flags). It failed before the fix with `undefined symbol: memcmp` from `permittedAttribute` | fixed |
| BRIDGE-03 | Stale generation, duplicate create, retired create and cross-root reparent rejected | `fixtures/parity.mjs` (shadow-registry block) | covered |
| BRIDGE-03 | Encoder rejects mount creation, the mount as a child, a bad mount generation, a zero generation and out-of-range children | `tests/contract_tests.d:BRIDGE-03 mount and handle misuse is rejected by the encoder` | added |
| BRIDGE-04 | `<script>` text and Unicode rendered as text | `fixtures/parity.d` text, `fixtures/browser.html` (`textContent`, no `script` element) | covered |
| BRIDGE-04 | A quoted event handler and an `<img onerror>` stay text, and attributes are allowlisted | `fixtures/parity.d` text with `onerror="..."`, `fixtures/browser.html` (no `script`/`img`/`[onerror]`, single text node), `fixtures/parity.mjs` hostile text decode, `tests/contract_tests.d:BRIDGE-04 and attribute policy: only allowlisted names, any valid UTF-8 text is carried verbatim` | added |
| BRIDGE-05 | memory.grow between frames: views recreated and old views never reused | `fixtures/parity.mjs` (old buffer detached, identical decode), `tests/wasm/run.mjs` on `bench-wasm`, `fixtures/browser.html` | covered |
| BRIDGE-06 | WebGPU absent gives unsupported; NaN colour and oversized canvas give invalidArgument | `fixtures/parity.mjs`, `tests/contract_tests.d:bounded UTF-8, handle, attribute and exact graphics payload validation` | covered |
| BRIDGE-06 | -1, +/-inf, just above 1 and negative NaN payloads; wrong version; wrong lengths | `tests/contract_tests.d:BRIDGE-06 and BRIDGE-12 exact canvas surface, wrapped geometry and malformed RGBA` | added |
| BRIDGE-07 | Native D and wasm32 serialize byte-identical fixtures | `fixtures/parity.d` + `fixtures/parity.mjs`: DMD, LDC and LDC wasm32 (unoptimized, O3, Oz) give the same 304 bytes | covered |
| BRIDGE-08 | Epoch 0, wrong epoch or an unsolicited larger epoch rejected; only an explicit reset changes the epoch | `tests/contract_tests.d:exact capacity, atomic failure and nested scoped borrows` (epoch 0), `fixtures/parity.mjs` (epochs 0/18/20), `fixtures/browser.html` (`reset(20)` then stale 19 rejected) | covered |
| BRIDGE-09 | Duplicate, reverse and half-range sequences rejected; wrap from 0xffffffff to 0 accepted | `fixtures/parity.mjs` (serial block) | covered |
| BRIDGE-09 | Largest forward step 0x7fffffff accepted, off-by-one window edges; `clear` advances exactly once and visiting or encoding never does | `fixtures/parity.mjs` (serial window block), `tests/contract_tests.d:BRIDGE-09 clear advances the sequence exactly once per frame and never during a borrow` | added |
| BRIDGE-10 | Detached tree creation, mounted-to-detached reparent, depth over 64 caught via a deep descendant | `fixtures/parity.mjs` (66-node detached chain, `attach(66, 1)`) | covered |
| BRIDGE-11 | 65536-byte text accepted, 65537 rejected; node index 65535 accepted, 65536 rejected | `tests/contract_tests.d:bounded UTF-8, handle, attribute and exact graphics payload validation`, `fixtures/parity.mjs` | covered |
| BRIDGE-11 | Attribute name and value at 65536/65537, a capacity-limited 65536 field, host index 65535 | `tests/contract_tests.d:BRIDGE-11 field and index boundaries: 65536-byte fields and index 65535 accepted, one more rejected`, `fixtures/parity.mjs` | added |
| BRIDGE-12 | (299,149,1,1) and (300,150,0,0) accepted; one pixel beyond rejected | `tests/contract_tests.d:bounded UTF-8, handle, attribute and exact graphics payload validation`, `fixtures/parity.mjs` | covered |
| BRIDGE-12 | Full 300x150 surface, every one-pixel overflow, 32-bit wrap of origin plus size, negative host origins | `tests/contract_tests.d:BRIDGE-06 and BRIDGE-12 exact canvas surface, wrapped geometry and malformed RGBA`, `fixtures/parity.mjs` | added |
| Compile-fail safety | Frame copy and escape of a borrowed visit slice rejected | `negative/copy_frame.d`, `negative/escaped_frame.d`, run with `python3 negative/run.py dmd` and `python3 negative/run.py ldc2` | covered (runner added) |
| Required benchmark | 1, 100 and 4096 operations with native and wasm32 encoders | `bench/` probe (`gc_bytes=0`), `fixtures/parity.mjs` `fixture_bench`; `bench-wasm` 8,339 raw / 4,032 gzip (O3) and 9,942 / 4,472 (Oz) bytes, under the 100,000-byte gzip cap | covered |
| ASan smoke | 60-second sanitizer run | LDC `-fsanitize=address` unittest build, looped with the signals suite | covered |

The only stub-like defect found was the `memcmp` dependency. `clear()` on a borrowed or uninitialised frame is a documented no-op.
