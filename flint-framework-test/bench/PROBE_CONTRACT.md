# flint:framework-test probe

The fixture performs one MockMvc request against a standalone `@RestController` and prints the status: `200` with no arguments and `404` with one.

The baseline in `baseline/` declares the module's direct dependencies (flint:context, flint:core, flint:engine-aot, flint:jackson-databind, flint:jakarta-servlet, flint:java, flint:web, flint:webmvc), but not the module. It prints the same line computed without the module.

`tools/measure_builds.py` takes the larger O3/Oz stripped-size difference as the module's `incremental_linked_bytes`, and counts the template instances of the invocations that compile `flint-framework-test`. The budget is in `policy/framework.json` (`tools/framework_budgets.py`).
