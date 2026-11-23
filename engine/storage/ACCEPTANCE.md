# flint:engine-storage acceptance traceability

Source: `handoff/specs/tier-6/storage.md` section 7 ("Required unit, protocol, fuzz and benchmark acceptance").
Network rows run under `tests/local_peer.py`, an independent Python S3 peer that re-verifies every SigV4 signature
with `hmac`/`hashlib`, checks exact wire paths and asserts its own post-run invariants. MinIO is not installed on
this host and there are no AWS or R2 accounts or recorded fixtures, so provider rows are blocked.

| Spec item | Covering test(s) | Status |
| --- | --- | --- |
| sigv4_vectors — AWS GET object (Range) example, empty payload hash | `tests/storage_behavior.d:"SigV4 matches the published S3 GET object Range signature"` | covered |
| sigv4_vectors — AWS PUT object, GET bucket lifecycle and list-objects (sorted query) examples | `tests/storage_behavior.d:"sigv4_vectors: published PUT object, bucket lifecycle and list-objects signatures match byte for byte"` | added |
| sigv4_vectors — AWS presigned GET URL example, byte for byte | `tests/storage_behavior.d:"presign_bounds: the published presigned GET URL matches and expiry is capped at seven days"` | added |
| sigv4_vectors — temporary session token | `tests/storage_behavior.d:"sigv4_vectors: a temporary session token is signed as a canonical header"` (reference signature from an independent Python implementation; AWS publishes no S3 token vector); every request in `tests/local_peer.py` carries and verifies `X-Amz-Security-Token` | added |
| key_encoding — space, plus, percent, UTF-8, repeated slash and dot segments sent exactly (loopback peer) | `tests/storage_behavior.d:"Real signed HTTP verifies multipart, embedded failures, private presigning and opaque metadata"` under `tests/local_peer.py` (peer asserts the exact path `/flint-test/a//../white%20space%2B%25%F0%9F%A6%8A.json`) | covered |
| key_encoding — round trip on MinIO | `tests/storage_behavior.d:"MinIO accepts the signed multipart upload, ranged GET, and presigned GET"` via `tests/minio_peer.py` | blocked (MinIO not installed here; `IMPLEMENTATION.md` records an earlier DMD/LDC/ASan MinIO run, where MinIO itself rejected `//` and `..` keys with HTTP 400) |
| key_encoding — recorded AWS/R2 fixtures | — | blocked (no AWS/R2 account and no recorded fixtures exist; the loopback peer is the closest evidence) |
| multipart_limits — 5 MiB nonfinal boundary | `tests/storage_behavior.d:"multipart_limits: part size below 5 MiB, above 5 GiB or beyond the buffer budget is rejected at open"`; peer asserts every nonfinal part ≥ 5 MiB | added |
| multipart_limits — small final part | 8 MiB + 123 B upload in the real-HTTP test (final part 123 B) | covered |
| multipart_limits — 10,000-part cap | `tests/storage_behavior.d:"multipart_limits: part numbers outside 1..10000 and empty upload IDs are rejected before transfer"` (`Part.queue` guard); session guard at `submitted == maximumParts` in `multipart.d` | added (end-to-end 10,001 × 5 MiB = 50 GB transfer not run) |
| multipart_limits — invalid part order | part 1 is retried after a 503 so part 2 finishes first; the peer asserts the completion lists parts 1..n in order with matching ETags; part number 0 rejected by the `Part.queue` test | covered |
| completion_error — HTTP 200 with an error XML body is a failure | `finish-fails` case in the real-HTTP test (→ `ioError`; peer asserts the SDK then aborts once) | covered |
| completion_error — malformed XML on HTTP 200 is never success | `finish-malformed` case in the real-HTTP test (truncated success envelope; peer asserts one completion attempt and one abort); `tests/storage_behavior.d:"S3 XML accepts bounded envelopes and rejects active XML constructs and ambiguous fields"` | added |
| abort_race — cancel with four parts in flight; orphan upload ID reported when cleanup fails | `verifyAbort` in the real-HTTP test (peer holds four parts, first abort gets 503 → `unavailable` and `copyUploadId` returns the ID; retry succeeds; peer asserts four held parts and two DELETEs) | covered |
| abort_race — no request-arena pointer survives | writes copy into the four owned part buffers before returning; the fixture resets its arena while parts are in flight; LDC ASan run below | covered |
| credential_rotation — refresh publishes one immutable snapshot; expired identity unavailable | `tests/storage_behavior.d:"credential refresh publishes one immutable snapshot and expires old identities"` | covered |
| credential_rotation — concurrent signers during refresh see whole snapshots and never an expired session | `tests/storage_behavior.d:"credential_rotation: concurrent signers observe whole snapshots and never an expired session"` (4 threads, ~2.6 s, ≥ 1 rotation each) | added |
| presign_bounds — reject > 604800 s; accept exactly 604800 | `"presign_bounds: the published presigned GET URL matches and expiry is capped at seven days"` | added |
| presign_bounds — reject expiry beyond the credential lifetime | real-HTTP test (601 s with 600 s credentials → `permissionDenied`); `tests/storage_behavior.d:"presign_bounds: temporary credentials bound expiry and the URL never carries the secret"` | covered / added |
| presign_bounds — logged URL omits authentication query fields | the package has no logging dependency and never logs URLs, credentials or signatures; the URL never contains the secret (temporary-credentials presign test) | covered (no log path exists) |
| storage_bench — upload/download 1 GiB with four 8 MiB buffers; live payload under 40 MiB plus fixed transport | `bench/loopback.py bench/build/probe-storage`: 1 GiB up and down, 128 parts, 4 buffers, matching SHA-256, peer peak 4 concurrent parts, `d_gc_bytes=0`; payload reservation 32 MiB. Client peak RSS 43.8 MB vs 42.2 MB for the libcurl baseline (`bench/baseline`); 63.7 MB before the completion buffers were left uninitialised | covered + fixed |
| Native boundary corpora under ASan / LDC sanitizer configuration | whole D suite under LDC `-fsanitize=address` (`--build=plain`) inside `tests/local_peer.py`; no storage-owned C code (HTTP/OpenSSL shims belong to http/security) | covered (run) |
| Fuzz seeds: truncated input, maximum lengths, empty values, cancellation, generation reuse | XML test (truncated, entities, DTD, out-of-range character references); empty-object single PUT; abort with four live parts; stale upload write → `notFound`/`unavailable` | covered |
| Compile-fail tests assert nonzero exit and stable diagnostic | `fixtures/negative/forge_upload.d`, `fixtures/negative/signing_internal.d`, run by `fixtures/negative/verify.py` (DMD and LDC) | added |

## Stub review and findings

No always-success paths found.

Finding (fixed): each upload session preallocated worst-case completion metadata in its constructor:
`receipts` (10,000 × 264 B ≈ 2.6 MB) and `xml` (10,000 × 1,636 B ≈ 16.4 MB), zero-filled by the GC so every page
was resident. Both buffers are read only after being written, so `Session.this()` now allocates them with
`uninitializedArray`; untouched pages stay non-resident. The 1 GiB probe's client peak RSS fell from 63.7 MB to
43.8 MB (libcurl baseline 42.2 MB) with unchanged throughput.

## Commands

```sh
python3 engine/storage/tests/local_peer.py dub test :storage --compiler=dmd
python3 engine/storage/tests/local_peer.py dub test :storage --compiler=ldc2
python3 engine/storage/fixtures/negative/verify.py <log-dir>
python3 engine/storage/bench/loopback.py engine/storage/bench/build/probe-storage
python3 engine/storage/bench/loopback.py engine/storage/bench/baseline/build/probe-storage-baseline
```
