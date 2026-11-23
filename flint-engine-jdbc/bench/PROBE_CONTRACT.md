# flint:engine-jdbc probe

The fixture maps a JDBC URL to engine settings with `parseUrl`, numbers `?` parameters with `numberParameters`, and checks that `FlintDriver` is registered with `DriverManager`. It prints one line that depends on its arguments: `/var/data/app.db | select $1 | registered` with none, and `host='db.example' port='6543' dbname='shop' | select $1 from t where a = $2 | registered` with one. It opens no database: SQLite and PostgreSQL execution is covered by the module's own tests with the native providers and the PostgreSQL peer.

The baseline in `baseline/` declares the module's direct dependencies (flint:arena, flint:conc, flint:engine-aot, flint:engine-sql, flint:java), but not the module. It prints the same line computed without the module: the operation is omitted, as packages' PROBE_CONTRACT.md allows.

`tools/measure_builds.py` takes the larger O3/Oz stripped-size difference as the module's `incremental_linked_bytes`. That is what the module, together with what it pulls in from its dependencies (the driver registration reaches `flint:engine-sql`), adds to an application. Template instances count the compiler invocations that compile `framework/engine-jdbc`, the probe included. The budget is in `policy/framework.json` (`tools/framework_budgets.py`).
