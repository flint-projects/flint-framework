# Security acceptance traceability

Source: `handoff/specs/tier-2/security.md`, section 7 ("Required unit, protocol, fuzz and benchmark acceptance"). Each row maps a case to its covering tests.

Locations:

- `behavior` is `tests/security_behavior.d`.
- `acceptance` is `tests/security_acceptance.d`.
- `native.c` is `tests/security_fixture/native.c`. Run it with `tests/security_fixture/native.py`, which builds with `-fsanitize=address,undefined`.
- `bench` is `bench/source/app.d` with `bench/harness/security_workload.d`.

Tests marked "fixture" need the HTTPS JWKS peer (`tests/security_fixture/run.py`). Without the peer they return early.

| Case | Spec item (abridged) | Covering test(s) | Status |
| --- | --- | --- | --- |
| jwt_confusion | `alg=none` fails | behavior: "verified claims, JWKS rotation and one refresh across concurrent readers" (fixture token `NONE`) | covered |
| jwt_confusion | RS256 token with an HMAC key fails | behavior: same test (`HMAC`, an `HS256` header over an RSA key ID). acceptance: "jwt_confusion: symmetric, mismatched-curve and mislabelled JWKs never become verification keys" checks that a JWKS `oct` key under an asymmetric key ID is never retained, and that an RSA JWK labelled `HS256`/`ES256`/`none` rejects the snapshot | covered |
| jwt_confusion | Wrong curve fails | behavior: same test (`CURVE`, a P-384 signature under the ES256 key ID). acceptance: the same JWK test checks that a P-384 JWK is never an ES256 key | covered |
| jwt_confusion | Unknown `crit` fails | behavior: same test (`CRIT`) | covered |
| jwt_confusion | Duplicate `alg`/`iss`/`aud` fails | behavior: same test (`DUP_ALG`, `DUP_ISS` with escaped spelling, `DUP_AUD`) | covered |
| jwt_confusion (section 4 edge) | Key type and RSA size match the algorithm | acceptance: "jwt_confusion: RSA keys below 2048 bits fail the whole snapshot". acceptance: "crypto_vectors: RFC 7515 and RFC 8037 JWS vectors verify and every signature bit flip fails" checks that a retained key never verifies under, or is looked up for, another algorithm | added |
| jwt_claims | Exact `exp`/`nbf` skew boundaries with a fake clock | behavior: same test (exp 1000 accepted at 1029 and denied at 1030; nbf 1100 accepted at 1070 and denied at 1069). acceptance: "jwt_claims: exact exp/nbf skew boundaries, issuer, audience and expiry with a fake clock" (skew 30 and 0, signed-range extremes) | covered |
| jwt_claims | Wrong audience | behavior: same test (`BAD_AUD`). acceptance: jwt_claims test (case-different, absent and array forms) | covered |
| jwt_claims | Wrong issuer | behavior: same test (`BAD_ISS`). acceptance: jwt_claims test (prefix, case and absent issuer) | covered |
| jwt_claims | Missing expiry | behavior: same test (`NO_EXP`). behavior: "JWKS redirect, key-count and byte bounds and optional expiration" covers `requireExpiry = false`. acceptance: jwt_claims test, plus "jwt_claims: role list and principal arena bounds fail closed" | covered |
| jwks_rotation | Rotate keys while 256 requests verify, and readers see whole snapshots | behavior: "verified claims, JWKS rotation ..." (4 reader threads × 64 = 256 verifies during rotation, an unchanged EC key verifies on every turn, 2 concurrent refreshers) | covered |
| jwks_rotation | Expired unknown keys fail | behavior: same test (the retired `rsa1` is denied after rotation, and every key is denied once the snapshot is past its TTL). behavior: "a verified snapshot renews in the background before its lifetime ends" | covered |
| jwks_rotation | Refresh is single-flight | behavior: same test (the fixture `/keys` counter is exactly 2 after two concurrent refreshers; a second refresh inside 30 s returns `unavailable` even across verifier reopen) | covered |
| jwks_ssrf | Token-supplied `jku`/`x5u` never triggers a request | behavior: same test (`JKU`, `X5U` denied, and the untrusted-target counter stays 0) | covered |
| jwks_ssrf | Configured JWKS redirects cannot escape | behavior: "JWKS redirect, key-count and byte bounds and optional expiration" (`/redirect` gives `ioError` and the target counter stays 0). behavior: the first unittest covers `http://` and userinfo JWKS URLs being refused | covered |
| cors_matrix | Credentialed wildcard fails | behavior: first unittest (`origins ~= "*"` with credentials). acceptance: "cors_matrix: denied and allowed preflights both vary on origin and request fields" | covered |
| cors_matrix | Malicious suffix origin fails | behavior: first unittest (`valid.example.attacker`, `@other`, path, scheme and port variants). acceptance: cors_matrix test | covered |
| cors_matrix | `null` origin fails | behavior: first unittest (with and without wildcard). acceptance: cors_matrix test | covered |
| cors_matrix | Disallowed requested headers fail | behavior: first unittest (`x-unlisted`, empty list member, disallowed method) | covered |
| cors_matrix | Vary is correct | behavior: first unittest (allowed decision). acceptance: cors_matrix test (denied decisions carry the same Vary, with no credentials and no max age) | covered |
| password_vectors | Correct and incorrect passwords | behavior: "interactive Argon2id with binary passwords, verifier limits and cancellation". native.c: `worker_retirement` | covered |
| password_vectors | Malformed verifier | behavior: same test (`$argon2id$v=19$invalid`, and an inflated cost gives `resourceExhausted`) | covered |
| password_vectors | Embedded NUL | behavior: same test (`p\0ss`). native.c: `worker_retirement` (NUL at byte 7, prefix denied) | covered |
| password_vectors | Maximum configured length | behavior: same test (1024 accepted, 1025 `invalidArgument`). native.c: `worker_retirement`, `queue_bound` | covered |
| secret_lifetime | Secure buffers are zeroed on error | native.c: `digests` and `worker_retirement` (outputs are `sodium_is_zero` after argument and resource errors), under ASan and UBSan | covered |
| secret_lifetime | Secure buffers are zeroed on cancellation | native.c: `worker_retirement` (an abandoned ticket is wiped, `flint_security_test_erased`). behavior: Argon2id test (a cancelled wait leaves no arena allocation, and the next hash succeeds) | covered |
| secret_lifetime | No log or test artifact includes raw passwords or bearer tokens | acceptance: "secret_lifetime: unopened and failed verification report only a stable category". behavior: every fixture rejection asserts the message `JWT verification denied`. The package has no logging import, the fixture passes tokens only through a pipe and the environment, and the DMD and LDC test logs contain no `eyJ` or `$argon2id$` text (checked after each run) | added |
| crypto_vectors | RFC and AWS HMAC/SHA vectors pass | behavior: "pinned SHA-256 and HMAC-SHA-256 vectors" (FIPS `abc`, RFC 4231 case 1). acceptance: "crypto_vectors: FIPS 180-2 SHA-256, RFC 4231 HMAC-SHA-256 and AWS SigV4 key derivation" (empty, 448-bit and one-million-`a` SHA-256; RFC 4231 cases 2–7, with case 5 truncated; the AWS SigV4 `kDate`→`kSigning` chain) | added |
| crypto_vectors | Upstream signature vectors pass | acceptance: "crypto_vectors: RFC 7515 and RFC 8037 JWS vectors verify ..." (RFC 7515 A.2 RS256, A.3 ES256, RFC 8037 A.4 EdDSA through the JWKS parser and native key). native.c: `signatures` (independently Go-signed RS256/ES256/EdDSA) | added |
| crypto_vectors | Signature bit flips always fail | acceptance: same RFC test (every bit of each of the three signatures is flipped, plus truncated signatures and inputs). behavior: `TAMPER`. native.c: `signatures` (bit flip, every truncated length) | added |
| verification_bench | 10,000 cached-key RS256/ES256 verifies report median, p99 and C heap counts | bench: `measure` over `rounds = 10_000` for RSA and EC, with native allocation counting through `--wrap=malloc`. `bench/check.py` compares against the direct EVP baseline | covered |
| verification_bench | Zero D allocations after warm-up | bench: `measure` requires `allocated == 0`. behavior: rotation test (`GC.stats.allocatedInCurrentThread` is unchanged across a warm verify) | covered |

## Counts

32 rows: 27 covered, 5 added, 0 fixed, 0 blocked.

## Stub and always-success review

No stub or always-success path was found.

- Every `return Error.init` in `jwt.d`, `jwt_parse.d` and `jwks.d` follows completed work, skips an ignored JSON member, or is the idempotent `close` of an unopened verifier.
- Without the pinned providers, `ffi/crypto.d` returns `unsupported` and never reports success.

## Verification (2026-11-21, Linux x86-64)

- `python3 tests/security_fixture/run.py --server <fixture> -- dub test :security`: run on DMD and LDC, passed. The fixture saw 2 `/keys` requests and 0 untrusted-target requests.
- The same suite without the peer passed on both compilers, running the offline acceptance tests only.
- `tests/security_fixture/negative.py dmd|ldc2`: all 4 compile-negative cases are rejected with their diagnostics.
- `tests/security_fixture/native.py` (ASan and UBSan): passed.
- `bench/build/probe-security` (LDC release) under the fixture: RS256 median 20.1 µs, p99 29.3 µs; ES256 median 54.5 µs, p99 80.6 µs. D GC bytes were 0 for both, and the checksum was `cached-jws 30660000`.
- `tools/gates.py --package security --gate structural`: passed.
- `tools/quality.py --path packages/engine-security`: 0 issues.
