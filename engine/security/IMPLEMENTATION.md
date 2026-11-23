# Linux security implementation

## Bearer verification

Configure the exact issuer, audience and asymmetric algorithm allowlist before opening a verifier. The verifier accepts RS256 with RSA keys from 2048 through 4096 bits, ES256 with P-256, and EdDSA with Ed25519. The operator configures one HTTPS JWKS URL. TLS checks the trust chain and hostname and does not follow redirects. Set `jwksCaBundle` to override the platform trust bundle. Set `jwksTtlSeconds` from 1 through 86,400 to change the 300-second default.

Initialize keys with an explicit `refresh`. Later requests use the current snapshot, and unknown or expired key lookups request a background refresh from the same URL. One HTTPS request at a time can run per issuer in the process. The 30-second issuer limit persists through verifier close and reopen. The worker has a ten-second refresh deadline and accepts at most 64 keys and 1 MiB of decoded JSON. It publishes the whole snapshot only after validation and retires native key references after readers finish. A failed refresh keeps the previous snapshot through its original expiry. A canceled refresh caller releases its wait while the shared refresh continues.

Verification accepts a compact JWT with an optional `Bearer ` prefix. The compact token limit defaults to 16 KiB. The parser enforces unpadded canonical base64url and rejects duplicate JSON members, including equivalent escaped spellings. Unsupported critical headers and token-provided key or resource references fail closed. The exact issuer and audience must match. Expiration is required by default, and clock skew defaults to 30 seconds. Expiration exactly at the end of skew fails, and the not-before boundary at the start of skew succeeds.

Successful verification returns handles valid through the caller's arena epoch. Read the subject through the arena and test exact, case-sensitive role membership with `hasRole`. Treat the packed roles buffer as opaque. The verifier owns its worker, transport, and key cache until `close`. Verifier copies share that lifetime. Serialize initialization and closure of a handle with accesses to that same handle value.

## Authorization and CORS

Register typed checks with `RegisteredPolicy!(name, functionSymbol)` and invoke them with `authorize!(PreAuthorize(name), PolicyEntries...)`. Checks take a scoped principal and a caller context and return an error. Unknown or ambiguous names fail at compilation, as do invalid role lists in `rolesAllowed!(RolesAllowed([...]))`. Application middleware decides how to map the verdict.

Origin matching compares parsed HTTP or HTTPS scheme, hostname or IP address, and port. Credentialed policies reject wildcard origins. `preflight` checks the requested method and case-insensitive header subset, and returns the policy cache age and Vary fields for the application response.

## Passwords and native ownership

OpenSSL 3.5.9 provides SHA-256, HMAC-SHA-256 and all JWS signatures. Libsodium 1.0.22 provides Argon2id and secure erasure. Password inputs can contain NUL bytes and are limited to 1,024 bytes. Hashing uses the interactive cost of two iterations and 64 MiB. Verification rejects malformed verifiers and resource costs above that profile before submitting work. A wrong password produces a successful false result. The full encoded verifier is copied into the caller's arena.

The process-wide pool runs up to two native jobs per online CPU with at most 16 workers and 32 outstanding tickets. The queue copies inputs and never borrows arena memory. On cancellation queued inputs are wiped immediately and a running operation wipes and retires its owned buffers on completion. Awaiting a native job yields on an active Reactor fiber and sleeps briefly on a regular thread. Set the caller's Context deadline to bound wait time.

## Linux verification

Build the pinned transport and crypto closure before exercising HTTPS JWKS. The fixture uses ephemeral loopback TLS, independent signing keys for all three algorithms, and private request counters. It passes fixture tokens through an anonymous pipe and process environment.

~~~sh
python3 tools/native_build.py --library curl --library openssl --library libsodium \
  --target linux-x86_64-glibc --phase build --emit-dub
mkdir -p artifacts/security
CGO_ENABLED=0 go build -trimpath -o artifacts/security/fixture packages/engine-security/tests/security_fixture/server.go
python3 packages/engine-security/tests/security_fixture/run.py --server artifacts/security/fixture -- dub test :security --compiler=dmd
python3 packages/engine-security/tests/security_fixture/run.py --server artifacts/security/fixture -- dub test :security --compiler=ldc2
python3 packages/engine-security/tests/security_fixture/negative.py dmd
python3 packages/engine-security/tests/security_fixture/negative.py ldc2
python3 tools/gates.py --package security --gate structural
~~~

Run `packages/engine-security/tests/security_fixture/native.py` with the pinned install prefix, fixture server and an output binary path to exercise the C ABI under ASan and UBSan. The corpus verifies native signatures, bounds, output erasure, cancellation, generation reuse and the outstanding password-work limit. The D fixture covers issuer and time boundaries, cache refresh races, rejection of token-controlled destinations, CORS, authorization and Argon2id.

The two benchmark programs each exercise 10,000 cached-key verifications for RS256 and ES256. The direct baseline uses the same TLS fixture and exact signing input and calls OpenSSL EVP directly. Both report observed median, p99, D GC bytes and native heap allocation calls. Compare the stripped feature and baseline binaries with `bench/check.py` inside the same TLS fixture.
