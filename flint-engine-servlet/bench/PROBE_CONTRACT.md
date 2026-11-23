# flint:engine-servlet probe

The fixture configures a `ServletEngine` and registers a servlet at `/` without binding, and prints `registered -1` (the port before `start`). Starting needs the native llhttp provider, which the size measurement does not link.

The baseline in `baseline/` declares the module's direct dependencies (flint:arena, flint:conc, flint:engine-aot, flint:engine-web, flint:jakarta-servlet, flint:java), but not the module. It prints the same line computed without the module.

`tools/measure_builds.py` takes the larger O3/Oz stripped-size difference as the module's `incremental_linked_bytes`, and counts the template instances of the invocations that compile `framework/engine-servlet`. The budget is in `policy/framework.json` (`tools/framework_budgets.py`).
