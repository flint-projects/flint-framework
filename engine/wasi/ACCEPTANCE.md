# flint:wasi acceptance traceability

Source: `handoff/specs/tier-5/wasi.md` section 6. Unit tests live in `tests/contract_tests.d` and run against the linked Wasmtime 51.0.0 provider (`FlintNativeWasmtime`, `linux-x86_64-glibc`). Guests come from `tests/fixture_bytes.d` and hand-assembled byte arrays. All seeds are fixed.

| Item | Requirement (brief) | Covering test or fixture | Status |
| --- | --- | --- | --- |
| WASI-01 | Malformed module gives invalidArgument | `tests/contract_tests.d:Wasmtime validates and executes the required core fixture` | covered |
| WASI-01 | Unexpected import gives invalidArgument | `tests/contract_tests.d:core store bounds, signature validation, traps and fuel` | covered |
| WASI-01 | Missing export gives notFound | `tests/contract_tests.d:Wasmtime validates and executes the required core fixture` | covered |
| WASI-01 | Every truncation, 2,000 seeded mutations, and an input over 16 MiB fail deterministically with no crash | `tests/contract_tests.d:WASI-01 truncated, mutated and oversized modules fail deterministically and failed stores are reclaimed` | added |
| WASI-01 | No leaked store: 400 failed instantiations and 300 load/close cycles exceed the 128 native slots | same test; also `tests/fuzz/run.py` (ASan + LeakSanitizer + UBSan, 60 s) | added / covered |
| WASI-02 | Infinite loop stopped by fuel within 100 ms | `tests/contract_tests.d:core store bounds, signature validation, traps and fuel` | covered |
| WASI-02 | Infinite loop stopped by the wall deadline (30 ms deadline, under 130 ms) | `tests/contract_tests.d:one compiled artifact gives independent stores and a bounded wall deadline` | covered |
| WASI-02 | memory.grow and table.grow beyond the cap return -1 | `tests/contract_tests.d:core store bounds, signature validation, traps and fuel` | covered |
| WASI-02 | Initial memory beyond the cap is refused at instantiation (and loads with the default cap) | `tests/contract_tests.d:WASI-01 truncated, mutated and oversized modules fail deterministically and failed stores are reclaimed` | added |
| WASI-03 | `..` and symlink escapes denied, linked preopen root refused, read-only enforced | `tests/contract_tests.d:Preview1 preopens enforce directory handles, read-only rights and traversal restrictions` | covered |
| WASI-04 | Default environment is empty; default network denied (WASI 0.2 `resolve`) | `tests/contract_tests.d:Preview1 environment and output are explicit and bounded`, `tests/contract_tests.d:versioned WASI component linkers exercise their pinned WIT imports` | covered |
| WASI-04 | A process variable set before load stays invisible; the core ABI rejects network, environment and preopens; no preopen without a grant | `tests/contract_tests.d:WASI-04 no ambient environment or network: core rejects capabilities and Preview1 ignores process env` | added |
| WASI-05 | Core, Preview1, WASI 0.2 and WASI 0.3 accepted/rejected matrix | `tests/contract_tests.d:WASI-05 version-specific accepted and rejected guest matrix with real calls` (5 guests x 4 ABIs, each accepted cell calls `answer`) and `tests/contract_tests.d:versioned WASI component linkers exercise their pinned WIT imports` | added / covered |
| WASI-06 | WAMR with a component module is unsupported before execution | `tests/contract_tests.d:Wasmtime validates and executes the required core fixture` | covered |
| WASI-06 | WAMR is unsupported for every ABI, even for malformed bytes; out-of-range engine/ABI values give invalidArgument | `tests/contract_tests.d:WASI-06 WAMR selection is unsupported for every ABI before any parsing or execution` | added |
| WASI-07 | A host call blocking past the deadline is cancelled and the store retired | `tests/contract_tests.d:Preview1 async host wait observes the wall deadline and retires the pending store`, `tests/contract_tests.d:cross-thread interrupt cancels the active generation only` | covered |
| WASI-07 | A throwing host callback cannot cross C | blocked: the v1 contract has no D host-callback registration, and the only callbacks are the C shim's (output capture, epoch) and Wasmtime's Rust WASI host. Closest evidence is the blocking-call row above and the ASan corpus | blocked (no D callback surface) |
| WASI-08 | Default Wasmtime loads `answer() -> i32` and returns 42 | `tests/contract_tests.d:WASI-08 specification fixture: default options load answer() and return 42`, `tests/contract_tests.d:Wasmtime validates and executes the required core fixture` | added / covered |
| WASI-08 | Repeat in every native target lane | blocked: only `linux-x86_64-glibc` is available here. aarch64 glibc and x86-64/aarch64 musl need their runners; macOS and Windows are out of scope (ADR-017) | blocked (runner) |
| WAMR conformance | Separately selected WAMR core/Preview1 run | blocked: WAMR 2.4.6 is not built in this provider profile | blocked (provider) |
| Compile-fail safety | Plugin and CompiledPlugin are not copyable | `negative/copy_plugin.d.fail`, `negative/copy_compiled.d.fail` via `tests/fixtures/negative.py dmd` and `tests/fixtures/negative.py ldc2` | covered |
| Fuzz / ASan | Lengths 0..256, 1 KiB/1 MiB boundaries, mutations, stale generations | `tests/fuzz/run.py --seconds 60` (GCC ASan/UBSan shim and corpus); LDC `-fsanitize=address` D unittest build against the uninstrumented engine | covered |
| Budget probe | Compile, instantiate and 100,000-call scalar workload | `bench/` probe with the four fixture guests: `gc_bytes=0`, checksum `84000168` | covered |

No always-success path was found in the D wrapper: every non-native build returns `unsupported`. Two notes, neither a contract violation:
- When the store limiter refuses an initial memory, the native shim (`native/ffi/flint_wasi.c`, `fail_trap`) maps the refusal to `invalidArgument`, not `resourceExhausted`.
- `inheritEnvironment = true` never copies the server environment. It requires explicit entries, as documented in `IMPLEMENTATION.md`.
