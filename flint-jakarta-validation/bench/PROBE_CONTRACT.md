# flint:jakarta-validation probe

The fixture reads @NotNull and @Min at compile time, as Flint AOT does, and bootstraps Validation without a provider. It prints one line that depends on its arguments: `{jakarta.validation.constraints.NotNull.message} 1 no-provider` with none, and `{jakarta.validation.constraints.NotNull.message} no-provider` with one.

The baseline in `baseline/` declares the module's direct dependencies (flint:conc, flint:engine-aot, flint:java), but not the module. It prints the same line computed without the module: the operation is omitted, as packages' PROBE_CONTRACT.md allows for a package without a native provider.

`tools/measure_builds.py` takes the larger O3/Oz stripped-size difference as the module's `incremental_linked_bytes`. That is what the module, together with what it pulls in from its dependencies, adds to an application. Template instances count the compiler invocations that compile `flint-jakarta-validation`, the probe included. The budget is in `policy/framework.json` (`tools/framework_budgets.py`).
