# Dependency injection

`flint.engine.di` creates a startup context from the registration types in `AppContext!(...)`. It expands explicit registrars, resolves constructor dependencies and checks the graph at compile time. Generated startup code calls constructors and lifecycle methods directly. Singleton getters read typed storage. Bindings expose the requested interface or base-class type, so calls through an interface use ordinary D dispatch.

Configured values supplied through `provide!T` bypass construction and lifecycle callbacks. The caller keeps any underlying resource valid through shutdown and remains responsible for closing it. A bare interface or abstract class registration requires a configured instance. Class beans retain their identity. Copyable struct beans are retrieved by value, and `ref` constructor parameters refer to the context's stable typed storage. Call `shutdown()` to release context-owned resources. A failed startup closes the context and invokes `@PreDestroy` in reverse initialization order only for owned beans whose initialization succeeded: the constructor returned and the `@PostConstruct` hook, if any, returned without an error or exception. The bean whose startup hook failed is not destroyed (ADR-017 decision 8).

## Local Linux verification

Pinned DMD 2.114.0 and LDC 1.43.0 passed both unittest modules. Each compiler rejected all 17 negative fixtures with their expected diagnostics in debug and release. The LDC AddressSanitizer run enabled leak detection and passed. The structural audit checked generated code in both profiles. The golden REST example passed syntax checks with this DI implementation and the handoff declarations for dependencies that remain pending.

The linked benchmark verified both programs' results for 1, 16, 64 and 128 beans, typed access and interface invocation. The DMD instrumented build recorded 1,304 template instantiations. Local isolated build samples were 0.392 s cold and 0.367 s after a source edit with DMD, and 0.594 s cold and 0.540 s after an edit with LDC. The largest sampled process-tree RSS among those four builds was 192,020,480 bytes.

| LDC profile | Full stripped feature | Full stripped control | Signed difference | Startup GC bytes for 1, 16, 64 and 128 beans |
| --- | ---: | ---: | ---: | --- |
| O3 ThinLTO | 477,880 | 439,968 | 37,912 | 0, 128, 512, 816 |
| Oz ThinLTO | 481,976 | 439,968 | 42,008 | 32, 128, 512, 816 |

Local commands, logs, binary digests and runtime series are in `artifacts/tasks/m2-di/results.json` with SHA-256 `87be1cdf608b1cd5aa7be8b386153b182dc8d8d0e1a745b31a3fce448cb49adc`. These are local diagnostic samples. The designated-runner baseline and integrated target receipts remain pending.
