# flint:engine-codec acceptance traceability

Source: `handoff/specs/tier-8/codec.md` section 7. Tests run against the real pinned zlib, Zstandard,
Brotli and libarchive providers (`FlintNative*` versions from the native DUB block); each test
skips only codecs that are not selected.

| # | Section 7 item | Covering test or fixture | Status |
| --- | --- | --- | --- |
| 1 | roundtrip: empty, 1-byte, random, repetitive, 64 MiB for all codecs | `tests/compression.d:Actual gzip, Zstandard and Brotli round trips through 64 MiB` | covered |
| 2 | stream_progress: every input/output chunk size 1..257, exact consumed/produced, no infinite loop | `tests/compression.d:Every 0..257 input and output capacity, short flush and backpressure` (turn bound asserted in `transform`) | covered |
| 3 | stream_progress: zero-sized output reports no progress | same test (`none == CodecStep.init`); `tests/compression.d:Deterministic streaming mutation corpus for every selected decoder` | covered |
| 4 | stream_progress: zero-sized input chunk terminates and leaves the stream usable | `tests/compression.d:zero_input_chunk: empty input steps terminate and leave the stream usable` | added |
| 5 | corruption: truncated header/body/trailer, checksum error, trailing garbage, concatenated frame | `tests/compression.d:Truncation, invalid headers, checksums, trailing frames and hard budgets` | covered |
| 6 | corruption: error releases native state | `tests/compression.d:corruption_release: a fatal decode error frees the provider state before close` (provider live bytes 0 after the error, further process refused) | added |
| 7 | bomb_limits: output and ratio budgets reject before crossing the byte budget | `Truncation, invalid headers, ...` (`output[31] == 0xff`, `output[1024] == 0xff` sentinels) | covered |
| 8 | bomb_limits: frame-count limit (single frame/member) | `Truncation, invalid headers, ...` (concatenated frame rejected) | covered |
| 9 | bomb_limits: window limit | `Truncation, invalid headers, ...` (Zstandard 32 MiB window descriptor, above the 16 MiB default -> resourceExhausted; Brotli large-window `0x11` header -> invalidArgument) | covered |
| 10 | Required external dictionary is unsupported, never corrupt output | `Truncation, invalid headers, ...` (Zstandard dictionary ID -> unsupported) | covered |
| 11 | state_calls: encoder process after finished/closed, double close, stale copies | `tests/compression.d:Generation aliases, cross-thread ownership, unsupported providers and overlapping buffers` | covered |
| 12 | state_calls: decoder process after finished/failed/closed, stale close after reopen | `tests/compression.d:decoder_state_calls: decoders refuse work after finish, failure, close and generation reuse` | added |
| 13 | native_allocator: C heap counts at creation vs steady state | `tests/compression.d:Native allocation counts distinguish startup, lazy initialization and steady state` (also asserts zero D GC bytes) | covered |
| 14 | codec_fuzz: shared corpus for every backend | `tests/compression.d:Deterministic streaming mutation corpus for every selected decoder` (320 seeded trials per codec) | covered |
| 15 | codec_fuzz: under ASan with allocation caps | blocked (needs the sanitized native rebuild from `tools/ci.py` native sanitize profile: Rust engine plus clang ASan/UBSan C providers; not rebuilt in this review). Closest evidence: item 14 under the real providers with a 2 KiB output cap | blocked |
| 16 | archive_paths: TAR `../`, absolute, drive, backslash traversal, invalid UTF-8, links/devices/FIFOs | `tests/archive.d:Archive metadata rejects traversal, invalid UTF-8, links, devices, and raw ZIP NUL` | covered |
| 17 | archive_paths: ZIP `../`, trailing `..`, drive, backslash-drive, absolute paths | `tests/archive.d:archive_paths_zip: ZIP entries with traversal and drive prefixes are rejected before exposure`; ZIP NUL/backslash/absolute/symlink in item 16 test | added |
| 18 | archive_paths: regular entries stream without touching disk | `tests/archive.d:Both archive types preserve directories and file bytes with retryable arena capacity` (in-memory source/sink) | covered |
| 19 | archive_limits: entry 10001, path 4097, decoded byte 1073741825 fail before exposure | `tests/archive.d:Archive hard limits reject entry 10001, path byte 4097, and decoded byte 1073741825` | covered |
| 20 | archive_limits boundaries: 4096-byte path and exactly 1 GiB accepted | `tests/archive.d:archive_limit_boundaries: 4096 path bytes and exactly 1 GiB declared bytes are accepted` | added |
| 21 | Archive callbacks: source/sink errors, reentry, partial writes | `tests/archive.d:Archive source and sink errors, reentry, stale aliases, and partial writes` | covered |
| 22 | codec_bench: 1 KiB / 64 KiB / 1 MiB fixtures at documented level | `bench/harness/codec_replay.d` (level 3; sizes 1024, 65536, 1048576) via the bench probes | covered (not rerun in this review) |
| 23 | Fuzz seeds: truncated input, maximum lengths, empty values, cancellation, generation reuse | items 1, 5, 14 (truncation/empty/64 MiB), item 21 (source cancellation), items 11-12 (generation reuse) | covered |
| 24 | Borrow and handle misuse rejected at compile time | `negative/check.py` (`source borrow`, `sink borrow`, `opaque identity`) | covered |

## Stub review

No always-success or ignored-input paths found. Every `Error.init` return follows completed native
work or an idempotent close of an already-released handle.

## Verification (this review)

- `rtest acc-cloud codec both`: DMD rc=0, LDC rc=0 (2 modules passed, all three codecs and libarchive selected).
- `negative/check.py dmd` and `ldc2`: 3/3 rejected.
- `tools/gates.py --package codec --gate structural`: rc=0. `tools/quality.py --path packages/engine-codec`: 0 issues.
