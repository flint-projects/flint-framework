# flint:jakarta-annotation probe

The fixture reads @Resource, @PostConstruct and @Priority at compile time, as Flint AOT does. It prints one line that depends on its arguments: `jdbc/petclinic 7 1` with none, and `jdbc/petclinic` with one.

The baseline in `baseline/` declares the module's direct dependencies (none), but not the module. It prints the same line computed without the module: the operation is omitted, as packages' PROBE_CONTRACT.md allows for a package without a native provider.

`tools/measure_builds.py` takes the larger O3/Oz stripped-size difference as the module's `incremental_linked_bytes`. That is what the module, together with what it pulls in from its dependencies, adds to an application. Template instances count the compiler invocations that compile `framework/jakarta-annotation`, the probe included. The budget is in `policy/framework.json` (`tools/framework_budgets.py`).
