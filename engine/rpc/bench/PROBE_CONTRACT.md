# rpc exercised probe

The probe runs the generated Envelope through pinned protobuf-c with 128-byte and 64-KiB payloads. Both variants verify the same scalar fields, payload length and checksum on every round trip. The two fixed checksums are 3,763 and 73,140. Each trial runs for at least 150 ms. The direct C control uses the upstream generated codec and default bounded test input. The Flint feature uses the typed DTO and arena handle path.

The independent gRPC-Go loopback benchmark uses the standard Protobuf codec and checks responses at each of the same nominal payload sizes with 1 and 64 concurrent calls. The 128-byte case is unary and the 64-KiB case opens bidirectional streams. Codec allocation samples use a separate Linux profile with GNU link wrappers around malloc, calloc and realloc. That profile reports those C call counts alongside thread-local D GC allocated bytes. It is separate from the stripped size observations.

## Local Linux observations

| Profile | Complete feature bytes | Complete provider-control bytes | Signed delta |
| --- | ---: | ---: | ---: |
| LDC O3 | 1,201,056 | 1,054,200 | 146,856 |
| LDC Oz | 1,143,712 | 1,021,432 | 122,280 |

| Compiler | Cache-cold build | Edited leaf build | Peak process-tree RSS |
| --- | ---: | ---: | ---: |
| DMD 2.114 | 1.102 s | 0.564 s | 155,930,624 bytes |
| LDC 1.43 O3 | 2.785 s | 1.134 s | 253,751,296 bytes |
| LDC 1.43 Oz | 2.371 s | 0.990 s | 250,621,952 bytes |

Each codec round trip used two wrapped native allocation calls in both variants. Every timed codec trial reported zero D GC bytes. The cold-build runs used fresh copied workspaces and isolated DUB caches. These local samples leave the dedicated-runner baseline open.

## Equivalent provider baseline

The baseline contains the same D harness, input construction, output checksum consumption, setup/cleanup and direct Flint dependencies (arena, reactor, conc, web, http, serde). It has no DUB dependency on `flint:engine-rpc` and imports none of that package's implementation modules. With no selected native provider, this is the direct-dependency-only control with this package's operation omitted or replaced by the specified reference operation.

With a selected native provider, the baseline instead performs the **same native operation** directly through the pinned upstream C ABI. Keep the same provider feature set, payloads, iteration counts, resource limits, cache state and observable result. A minimal adapter used only to expose an upstream ABI may be common; an adapter containing Flint validation, ownership, scheduling or business logic is framework code and cannot be subtracted as provider overhead. Both programs must execute, terminate with exit code 0 and produce their documented equivalent output. Calls must contribute to the consumed result so optimization cannot remove the workload.

Native preparation writes the identical verified `versions`/`lflags` provider block into the package recipe and this baseline recipe. This establishes the same available native closure; it does **not** establish that the linker retained equivalent code. Calling the same provider operations establishes that additional requirement. Merely adding a static archive, forcing whole-archive retention, padding the control, or retaining unrelated provider features to inflate the baseline is prohibited.

## Size accounting

Build both variants under O3 and Oz with the same compiler and native profile. Record each complete stripped byte count and SHA256. Define `signed_delta = feature_bytes - baseline_bytes` for each profile and cap `max(0, O3_signed_delta, Oz_signed_delta)` using this package's proposed byte ceiling. Zero is a legitimate observation; raw negative differences remain visible.

The complete feature binary is the deployed-size observation for this fixture. The baseline's full bytes are the common provider/dependency/harness footprint, not an exact isolated C-only byte count. Native archive inventories are diagnostic and are not subtracted from executables. Report these absolute sizes beside the wrapper delta; never describe a small delta as the full package deployment size.

The fixed 3,000,000-byte CLI, 8,000,000-byte REST, 300,000-byte raw browser WASM and 100,000-byte gzip WASM application caps remain unchanged and include their actual selected dependency closure. A large provider cannot bypass an application cap through this per-package control. Freeze both source workloads and selected provider profile before collecting the first baseline; changing them requires a separately reviewed baseline experiment. All ceilings are unmeasured engineering targets until actual implementations produce evidence.
