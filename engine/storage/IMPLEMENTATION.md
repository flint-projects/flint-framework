# S3-compatible storage

`ObjectStorage` signs requests and presigned GET URLs with the pinned OpenSSL provider. Select an endpoint and region explicitly. The default verifies the HTTPS chain and hostname. Plain HTTP requires a numeric loopback origin and an explicit opt-in. Credentials come from a caller-owned provider invoked on a management worker. Each signature uses one immutable snapshot. Expired credentials fail closed.

`beginUpload` reserves a generation-checked session. The SDK creates the remote multipart upload on the first nonempty write so that completing an empty upload sends one empty PUT. The default four owned 8 MiB buffers remain reserved by their workers until the HTTP transfers acknowledge retirement. Completion serializes receipts in part order and parses the bounded XML envelope, including errors returned with HTTP 200. An unsuccessful abort preserves the remote upload ID for a cleanup retry.

Downloads stream into the caller's scoped consumer. `DownloadOptions` selects an inclusive byte range, an opaque ETag condition or a version. Exact bytewise percent encoding preserves repeated slashes and dot segments in the signed path. Providers decide which keys they support.

## Linux verification

Prepare the locked HTTP provider, then run the linked fixtures with DMD and LDC:

```sh
python3 tools/native_build.py --profile http --target linux-x86_64-glibc --phase build --emit-dub
python3 engine/storage/tests/local_peer.py dub test :storage --compiler=dmd
python3 engine/storage/tests/local_peer.py dub test :storage --compiler=ldc2
python3 engine/storage/tests/minio_peer.py /path/to/minio dub test :storage --compiler=ldc2
python3 tools/gates.py --package storage --gate structural
```

The independent loopback peer checks SigV4, exact paths, temporary credentials, presign expiry, range and version conditions, part retry, embedded completion errors and abort with four live parts. DMD, LDC and LDC ASan with leak detection also ran against MinIO at source commit `0d7408fc9969caf07de6a8c3a84f9fbb10a6739e`. That run covered an 8 MiB plus 123-byte multipart upload, a key containing space, plus, percent and UTF-8 bytes, a signed HEAD, ranged and presigned reads, and deletion. MinIO rejected the separate double-slash and dot-segment probes with HTTP 400. The independent peer verified that Flint sent the original paths. AWS and R2 account verification remains open.

Local receipts are under `artifacts/tasks/m5-storage/`. The linked provider log has SHA-256 `6743676b597d56d137f8ab973298c27918392468e0d929af51dee961142dff32`. See [the probe contract](bench/PROBE_CONTRACT.md) for the 1 GiB paired workload.
