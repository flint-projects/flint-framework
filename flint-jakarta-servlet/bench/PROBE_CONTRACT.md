# flint:jakarta-servlet probe

The fixture builds a `jakarta.servlet.http.Cookie`, sets its path and `HttpOnly`, and prints `visit=v1 / HttpOnly` with no arguments and `session=v1 / HttpOnly` with one.

The baseline in `baseline/` declares the module's direct dependencies (flint:engine-aot, flint:java), but not the module. It prints the same line computed without the module.

`tools/measure_builds.py` takes the larger O3/Oz stripped-size difference as the module's `incremental_linked_bytes`, and counts the template instances of the invocations that compile `framework/jakarta-servlet`. The budget is in `policy/framework.json` (`tools/framework_budgets.py`).
