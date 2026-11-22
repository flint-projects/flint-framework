# flint:ui-signals acceptance traceability

Source: `handoff/specs/tier-5/ui-signals.md` section 6. Unit tests live in `tests/contract_tests.d`, cited as `file:test name`. All seeds and traces are fixed.

| Item | Requirement (brief) | Covering test or fixture | Status |
| --- | --- | --- | --- |
| SIGNAL-01 | Same value set 1000 times: no emitted patch after the initial flush | `tests/contract_tests.d:equal values emit no command and repeated changes publish the final value in registration order` | covered |
| SIGNAL-01 | ... and no dirty-queue entry | `tests/contract_tests.d:SIGNAL-01 equal-value sets never occupy the dirty queue` (one-slot queue stays free after 1000 equal sets) | added |
| SIGNAL-02 | Three sets before a flush give one update with the final value | `tests/contract_tests.d:equal values emit no command and repeated changes publish the final value in registration order` | covered |
| SIGNAL-02 | One source drives several bindings, each updated once in registration order | `tests/contract_tests.d:SIGNAL-02 one source updates several bindings once each with the final value` | added |
| SIGNAL-03 | Dispose and reuse: old handle is notFound, new handle has a different generation | `tests/contract_tests.d:equal values emit no command and repeated changes publish the final value in registration order` | covered |
| SIGNAL-03 | Stale or out-of-range IDs on read/set/bindText/dispose, double dispose, and generation exhaustion retiring the slot (spec 4.3) | `tests/contract_tests.d:SIGNAL-03 stale handles, double disposal and generation exhaustion retire the slot` | added |
| SIGNAL-04 | Full dirty queue: resourceExhausted, value unchanged, retry after capacity recovers | `tests/contract_tests.d:failed queue admission and failed frame preflight preserve state for retry` | covered |
| SIGNAL-04 | Short output buffer: no partial batch, bytes untouched, retry works | `tests/contract_tests.d:failed queue admission and failed frame preflight preserve state for retry` | covered |
| SIGNAL-04 | Short or borrowed frame with a computed node: computed value not committed, dirty set kept, retry emits the final value | `tests/contract_tests.d:SIGNAL-04 a short or borrowed frame leaves computed values, dirty set and bytes intact` | added |
| SIGNAL-05 | int.min and int.max decimal text | `tests/contract_tests.d:equal values emit no command and repeated changes publish the final value in registration order` | covered |
| SIGNAL-05 | Zero, negatives, extremes and neighbours, with no GC allocation | `tests/contract_tests.d:SIGNAL-05 decimal text for zero, signs and both extremes without GC allocation` (a `nothrow @nogc` unittest) | added |
| SIGNAL-06 | A second binding to the same node returns conflict | `tests/contract_tests.d:equal values emit no command and repeated changes publish the final value in registration order` | covered |
| SIGNAL-06 | Conflict regardless of source or generation, invalid node handles rejected, rebinding allowed after dispose | `tests/contract_tests.d:SIGNAL-06 one destination per node: conflicts, invalid handles and rebinding after disposal` | added |
| SIGNAL-07 | Native and WASM runs of the same trace give identical status codes and bridge bytes | `fixtures/parity.d` + `fixtures/parity.mjs`: DMD, LDC and LDC wasm32 (unoptimized, O3 and Oz) produced the same 116 status and FLNT bytes | covered |
| Spec usage fixture | create, set and read | `tests/contract_tests.d:specification usage fixture: create, set and read one signal` | added |
| Spec 4.2 storage | Empty or unequal capacities and non-zeroed or reused slabs return invalidArgument | `tests/contract_tests.d:storage contract: invalid capacity combinations and reused slabs are rejected` | added |
| Spec 4.6 computed | 0 or more than 64 inputs, a null function, missing or full computed storage, stale inputs, a diamond evaluated once per flush, conflict when disposing a used input | `tests/contract_tests.d:computed contract: input bounds, storage exhaustion, stale inputs and once-per-flush diamond evaluation`, `tests/contract_tests.d:computed generations are evaluated once in topological order and unchanged values stop propagation` | added / covered |
| Compile-fail safety | Graph copy, capturing closure as `Compute`, and returning a graph over stack slabs are rejected | `negative/copy_graph.d.fail`, `negative/capturing_compute.d.fail`, `negative/escaped_storage.d.fail`, run with `python3 negative/run.py dmd` and `python3 negative/run.py ldc2` | added |
| Required benchmark | 100K sets over 1, 1000 and 10000 signals; equal-value frames allocate nothing and emit nothing | `bench/` probe (LDC release): every patch verified, `gc_bytes=0`, equal frame `usedBytes == 32` | covered |
| BetterC | Native and wasm32 BetterC runtime fixture | `tests/betterc.d` built as in `tools/ci.py` `betterc` (DMD, LDC) and `wasm_betterc` | covered |
| ASan smoke | 60-second sanitizer run | LDC `-fsanitize=address` unittest build, run in a loop alongside the bridge suite for 60 s | covered |

No always-success or stub path was found. `set` compares against the latest set value, so setting a value back to the last flushed value before a flush still emits one patch. The spec allows this.
