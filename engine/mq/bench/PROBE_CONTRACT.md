# mq exercised probe

The implementation task creates `source/app.d` and `baseline/source/app.d` in this directory. The recipes resolve the local implementation root. Source is intentionally absent until real behavior exists; the measurement tool rejects missing probes.

`source/app.d` must instantiate and execute the required workload in `handoff/specs/tier-6/mq.md`. Preserve an observable checksum derived from actual results and check correctness through code that remains active in the release build. A bare import, constant-only substitute or discarded operation is invalid. Use the pinned input sizes/seeds from the specification; microbenchmark timing, where applicable, must exceed 100 ms per trial.

## Equivalent provider baseline

The baseline contains the same D harness, input construction, output checksum consumption, setup/cleanup and direct Flint dependencies (arena, reactor, conc, serde, log). It has no DUB dependency on `flint:mq` and imports none of that package's implementation modules. With no selected native provider, this is the direct-dependency-only control with this package's operation omitted or replaced by the specified reference operation.

With a selected native provider, the baseline instead performs the **same native operation** directly through the pinned upstream C ABI. Keep the same provider feature set, payloads, iteration counts, resource limits, cache state and observable result. A minimal adapter used only to expose an upstream ABI may be common; an adapter containing Flint validation, ownership, scheduling or business logic is framework code and cannot be subtracted as provider overhead. Both programs must execute, terminate with exit code 0 and produce their documented equivalent output. Calls must contribute to the consumed result so optimization cannot remove the workload.

Native preparation writes the identical verified `versions`/`lflags` provider block into the package recipe and this baseline recipe. This establishes the same available native closure; it does **not** establish that the linker retained equivalent code. Calling the same provider operations establishes that additional requirement. Merely adding a static archive, forcing whole-archive retention, padding the control, or retaining unrelated provider features to inflate the baseline is prohibited.

## Size accounting

Build both variants under O3 and Oz with the same compiler and native profile. Record each complete stripped byte count and SHA256. Define `signed_delta = feature_bytes - baseline_bytes` for each profile and cap `max(0, O3_signed_delta, Oz_signed_delta)` using this package's proposed byte ceiling. Zero is a legitimate observation; raw negative differences remain visible.

The complete feature binary is the deployed-size observation for this fixture. The baseline's full bytes are the common provider/dependency/harness footprint, not an exact isolated C-only byte count. Native archive inventories are diagnostic and are not subtracted from executables. Report these absolute sizes beside the wrapper delta; never describe a small delta as the full package deployment size.

The fixed 3,000,000-byte CLI, 8,000,000-byte REST, 300,000-byte raw browser WASM and 100,000-byte gzip WASM application caps remain unchanged and include their actual selected dependency closure. A large provider cannot bypass an application cap through this per-package control. Freeze both source workloads and selected provider profile before collecting the first baseline; changing them requires a separately reviewed baseline experiment. All ceilings are unmeasured engineering targets until actual implementations produce evidence.
