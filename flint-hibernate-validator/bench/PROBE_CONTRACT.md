# flint:hibernate-validator probe

The fixture validates a bean with @NotBlank and @Size through Hibernate Validator as the default provider. It prints one line that depends on its arguments: `firstName:must not be blank;city:size must be between 2 and 30;` with none, and `city:size must be between 2 and 30;` with one.

The baseline in `baseline/` declares the module's direct dependencies (flint:engine-aot, flint:jakarta-validation, flint:java, flint:serde, flint:validate), but not the module. It prints the same line computed without the module: the operation is omitted, as packages' PROBE_CONTRACT.md allows for a package without a native provider.

`tools/measure_builds.py` takes the larger O3/Oz stripped-size difference as the module's `incremental_linked_bytes`. That is what the module, together with what it pulls in from its dependencies, adds to an application. Template instances count the compiler invocations that compile `framework/hibernate-validator`, the probe included. The budget is in `policy/framework.json` (`tools/framework_budgets.py`).
