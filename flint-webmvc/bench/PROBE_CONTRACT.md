# flint:webmvc probe

The fixture builds a `DispatcherServlet` from `WebMvcConfigurationSupport` with no controllers and prints its name and whether its handler mappings were created: `dispatcherServlet mapped`.

The baseline in `baseline/` declares the module's direct dependencies (flint:context, flint:core, flint:engine-aot, flint:jakarta-servlet, flint:java, flint:web), but not the module. It prints the same line computed without the module.

`tools/measure_builds.py` takes the larger O3/Oz stripped-size difference as the module's `incremental_linked_bytes`, and counts the template instances of the invocations that compile `flint-webmvc`. The budget is in `policy/framework.json` (`tools/framework_budgets.py`).
