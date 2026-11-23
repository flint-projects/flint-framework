# flint:slf4j-api probe

The fixture logs through LoggerFactory and the default provider and formats the event. It prints one line that depends on its arguments: `Found owner George with 2 pets` with none, and `Found owner Jean with 2 pets` with one.

The baseline in `baseline/` declares the module's direct dependencies (flint:arena, flint:conc, flint:engine-aot, flint:engine-reactor, flint:java, flint:log, flint:serde), but not the module. It prints the same line computed without the module: the operation is omitted, as packages' PROBE_CONTRACT.md allows for a package without a native provider.

`tools/measure_builds.py` takes the larger O3/Oz stripped-size difference as the module's `incremental_linked_bytes`. That is what the module, together with what it pulls in from its dependencies, adds to an application. Template instances count the compiler invocations that compile `framework/slf4j-api`, the probe included. The budget is in `policy/framework.json` (`tools/framework_budgets.py`).
