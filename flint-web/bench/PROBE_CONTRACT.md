# flint:web probe

The fixture parses an `Accept` value with `MediaType.parseMediaTypes`, and prints the last type with `HttpStatus.NOT_FOUND`'s reason phrase: `application/json Not Found` with or without an argument.

The baseline in `baseline/` declares the module's direct dependencies (flint:context, flint:core, flint:engine-aot, flint:jackson-databind, flint:jakarta-servlet, flint:java), but not the module. It prints the same line computed without the module.

`tools/measure_builds.py` takes the larger O3/Oz stripped-size difference as the module's `incremental_linked_bytes`, and counts the template instances of the invocations that compile `framework/web`. The budget is in `policy/framework.json` (`tools/framework_budgets.py`).
