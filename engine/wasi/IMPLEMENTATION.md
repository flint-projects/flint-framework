# Linux WebAssembly host

Flint embeds Wasmtime 51.0.0 from the verified native lock. `Plugin.load` compiles and instantiates a raw WebAssembly guest. Use `CompiledPlugin.compile` to reuse compilation across tenants, and pass matching engine and ABI options to `instantiate`. Each tenant receives its own store, globals, memories, output, and capabilities. Both handles are move-only. Close them explicitly to retire resources promptly. Existing tenants retain the resources they need after the compiled handle closes. Serialize closure of the compiled handle with instantiation from that handle.

## Guest profiles

- `core` accepts a binary core module with no imports. BetterC guest code can target this profile.
- `wasiPreview1` accepts core modules linked to the `wasi_snapshot_preview1` functions.
- `wasi02Component` links a Component Model binary against the upstream WASI 0.2 interfaces.
- `wasi03Component` uses the separate stable WASI 0.3 linker from the same pinned Wasmtime source.

WIT tooling generates the Canonical ABI wiring. `callI32` accepts one scalar export with signed 32-bit inputs and one signed 32-bit result. It checks the name, arity, and types before invocation. Raw core Wasm and components have distinct loaders. The pinned Wasmtime extension supplies async Preview1 linking, WASI 0.3 linking, and a bounded host runtime. Selecting WAMR returns `unsupported` in this profile.

## Execution limits

Each instantiation and call starts with fresh fuel and a monotonic wall deadline. The native watchdog uses Wasmtime epochs to stop overdue execution. Interrupt affects the active tenant only, including when other stores share the compiled engine. A store rejects overlapping operations. Close cancels active use and waits for retirement before invalidating the native generation.

The default limits are 10 million fuel, 16 MiB linear memory, 1,024 table elements, one instance, 1 MiB captured output, and one second wall time. A store admits one memory and one table. Wasmtime counts core instances inside a component toward `maxInstances`, so a component with generated adapter modules may require a larger explicit limit. Source inputs are capped at 16 MiB, memory at 1 GiB, and captured output at 16 MiB. The process admits at most 128 tenant stores.

WASI calls and host imports run through provider futures. The host runtime has two event-loop workers and up to eight blocking workers. Cancellation drops a pending future and retires its store from further calls. Started filesystem work retains its own native state and can finish after cancellation. Store contexts and stdout callbacks hold native data only.

## Capabilities

An empty capability set provides no preopen paths, guest environment or network access. Preopens open link-free directory paths component by component by descriptor. Wasmtime's capability handles resolve guest paths relative to that directory. Read-only is the default. Set `Preopen.writable` to grant filesystem mutation inside that directory. Up to 32 paths can be mounted per tenant.

The Linux preopen adapter passes its retained directory descriptor through `/proc/self/fd`. A Linux deployment that supplies preopens must expose this procfs path. Failure to resolve a retained descriptor returns a capability error.

Set `PluginOptions.environment` to supply up to 64 explicit names and values, with up to 64 KiB across the entries. Names use ASCII letters, digits, and underscores and must start with a letter or underscore. Values are UTF-8 without NUL. The compatibility flag `inheritEnvironment=true` requires explicit entries. The runtime uses only those entries. Set `allowNetwork=true` to grant WASI network and name lookup capability.

Standard output and error share a bounded capture per operation. An oversized write retains its prefix and returns a resource limit error. `copyOutput` copies the latest capture to the supplied request arena. Its handle lasts for that arena's epoch.

## Linux checks

Prepare the pinned engine and run its linked tests with both compilers.

~~~sh
python3 tools/install_rust.py --target linux-x86_64-glibc
export RUSTUP_HOME="$PWD/.tools/rust/rustup" CARGO_HOME="$PWD/.tools/rust/cargo" RUSTUP_TOOLCHAIN=1.97.0
export PATH="$CARGO_HOME/bin:$PATH"
python3 tools/native_build.py --profile wasm-host \
  --target linux-x86_64-glibc --phase build --emit-dub
dub test :wasi --compiler=dmd
dub test :wasi --compiler=ldc2
python3 engine/wasi/tests/fixtures/negative.py dmd
python3 engine/wasi/tests/fixtures/negative.py ldc2
python3 tools/gates.py --package wasi --gate structural
~~~

The linked suite exercises core and Preview1 calls, independent stores, typed exports, memory and table bounds, fuel, a guest trap, epoch interruption, host wait cancellation, descriptor-held preopens, read-only and writable capabilities, default and explicit environment and network, stdout and stderr bounds, and the versioned WASI 0.2.12 and 0.3.0 component matrix. The pure fixture assembler uses the locked `wat` and `wit-component` tools and the pinned Wasmtime WIT source. Run `tests/fixtures/generate.py` with the provider source checkout and assembled tool to regenerate the guest binaries and the D test module.

The native sanitizer corpus exercises short inputs, 1 KiB and 1 MiB boundaries, fixed mutations, and stale handles. GCC instruments the C shim and corpus. LDC ASan instruments the D bindings and uses the instrumented C shim with the separately built pinned Rust engine.

The feature and direct-provider benchmarks load the same four guests and measure module compilation and cached instantiation separately. Their scalar benchmark verifies the same 100,000-call workload in each batch and reports GC activity and process RSS with the engine loaded. Report stripped executable bytes and hashes for each optimization profile alongside the wrapper delta.
