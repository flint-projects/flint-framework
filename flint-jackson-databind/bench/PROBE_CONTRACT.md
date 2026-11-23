# flint:jackson-databind probe

The fixture serializes a record through JsonMapper and a Flint AOT descriptor. It prints one line that depends on its arguments: `{"id":1,"content":"Hello, World!"}` with none, and `{"id":2,"content":"Hello, World!"}` with one.

The baseline in `baseline/` declares the module's direct dependencies (flint:engine-aot, flint:jackson-annotations, flint:jackson-core, flint:java, flint:serde), but not the module. It prints the same line computed without the module: the operation is omitted, as packages' PROBE_CONTRACT.md allows for a package without a native provider.

`tools/measure_builds.py` takes the larger O3/Oz stripped-size difference as the module's `incremental_linked_bytes`. That is what the module, together with what it pulls in from its dependencies, adds to an application. Template instances count the compiler invocations that compile `flint-jackson-databind`, the probe included. The budget is in `policy/framework.json` (`tools/framework_budgets.py`).
