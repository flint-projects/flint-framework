# storage exercised probe

`source/app.d` exercises the public Storage client and `baseline/source/app.d`
calls the pinned libcurl C ABI. Both consume the shared 1 GiB workload and check its
observable SHA-256 in release builds.

## Equivalent provider baseline

The baseline contains the same D harness, input construction, output checksum consumption, setup/cleanup and direct Flint dependencies (arena, http, security, conc). It has no DUB dependency on `flint:engine-storage` and imports none of that package's implementation modules. With no selected native provider, this is the direct-dependency-only control with this package's operation omitted or replaced by the specified reference operation.

With a selected native provider, the baseline instead performs the **same native operation** directly through the pinned upstream C ABI. Keep the same provider feature set, payloads, iteration counts, resource limits, cache state and observable result. A minimal adapter used only to expose an upstream ABI may be common; an adapter containing Flint validation, ownership, scheduling or business logic is framework code and cannot be subtracted as provider overhead. Both programs must execute, terminate with exit code 0 and produce their documented equivalent output. Calls must contribute to the consumed result so optimization cannot remove the workload.

Native preparation writes the identical verified `versions`/`lflags` provider block into the package recipe and this baseline recipe. This establishes the same available native closure; it does **not** establish that the linker retained equivalent code. Calling the same provider operations establishes that additional requirement. Merely adding a static archive, forcing whole-archive retention, padding the control, or retaining unrelated provider features to inflate the baseline is prohibited.

## Size accounting

Build both variants under O3 and Oz with the same compiler and native profile. Record each complete stripped byte count and SHA256. Define `signed_delta = feature_bytes - baseline_bytes` for each profile and cap `max(0, O3_signed_delta, Oz_signed_delta)` using this package's proposed byte ceiling. Zero is a legitimate observation; raw negative differences remain visible.

The complete feature binary is the deployed-size observation for this fixture. The baseline's full bytes are the common provider/dependency/harness footprint, not an exact isolated C-only byte count. Native archive inventories are diagnostic and are not subtracted from executables. Report these absolute sizes beside the wrapper delta; never describe a small delta as the full package deployment size.

The fixed 3,000,000-byte CLI, 8,000,000-byte REST, 300,000-byte raw browser WASM and 100,000-byte gzip WASM application caps remain unchanged and include their actual selected dependency closure. A large provider cannot bypass an application cap through this per-package control. Freeze both source workloads and selected provider profile before collecting the first baseline; changing them requires a separately reviewed baseline experiment. All ceilings are unmeasured engineering targets until actual implementations produce evidence.

## Local replay

Prepare the pinned curl and OpenSSL archives with the native HTTP profile. Build `bench` and
`bench/baseline` with DUB and the same compiler flags, then run each linked executable through
`python3 engine/storage/bench/loopback.py /path/to/executable`. The harness binds a numeric
loopback address, supplies fixture-only credentials through compile-time constants and verifies
each SigV4 request independently. Four initial part responses wait for all four signed uploads,
which proves the selected concurrency was exercised.

Both probes write 128 full 8 MiB parts, download the complete object into an incremental
OpenSSL SHA-256 context, and remove the object. The peer checks each uploaded stripe against
the deterministic fixture pattern. It retains part digests and regenerates each part for
the download, checking those digests again. The peer's memory stays bounded independently of
object length.

The SDK producer uses one 64 KiB input stripe and its configured four 8 MiB owner buffers.
The reference fills four owned part buffers and submits through the pinned libcurl multi and
SigV4 APIs. Both use the fixture's canonical path, method and query parameters. The reference
uses libcurl's ordinary path setting because its built-in SigV4 rejects `PATH_AS_IS`.

Report actual bytes, the matching download digest, upload/download elapsed time,
same-thread D GC bytes, and independent high-water RSS for the client and the fixture process.
Total RSS includes code, allocator metadata and fixed transport costs. Compare its observation
alongside the measured workload's fixed payload reservation.
