/++
Flint's JDBC driver: `flint.java.sql`'s `Connection`, `PreparedStatement` and `ResultSet` over the SQL engine
(`flint.engine.sql`), for `jdbc:sqlite:` and `jdbc:postgresql:` URLs (docs/spring/phase1/data-access.md). It is Flint's
own driver, not a port of pgjdbc or sqlite-jdbc.

$(UL
    $(LI `FlintDriver` registers with `DriverManager` when this module loads. A connection it opens owns a one-lease
        engine pool, as a plain JDBC connection owns its socket. `FlintDataSource` is the pooled `DataSource`, with
        HikariCP's property names, and hands out leases of one engine pool.)
    $(LI Statements run on the engine: libpq's non-blocking protocol, or SQLite's per-connection worker, so a query
        on a reactor fiber suspends only that fiber. JDBC's `?` placeholders become `$1`, `$2`, ... for PostgreSQL.)
    $(LI A query's rows are copied into GC memory as they arrive, which is the user boundary (ADR-030 section 4):
        `ResultSet` values are GC strings and arrays, never arena memory.)
    $(LI Failures become `SQLException`s whose JDBC 4 subclass, SQLSTATE and vendor code come from the engine's
        failure record, so Spring's `SQLExceptionSubclassTranslator` sees what it sees on the JVM.)
    $(LI A connection in manual-commit mode begins its transaction lazily, with the first statement.)
)
+/
module flint.engine.jdbc;

import flint.arena : ArenaError = Error, Buffer, RequestArena, Result, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.engine.aot.any : Any;
import flint.engine.aot.objects : objectToString;
import flint.engine.sql : Driver, EngineConnection = Connection, Pool, PoolOptions, Row,
    SqlFailure, SqlValue, ValueKind;
import flint.java.sql;
import flint.java.util : Properties;
import flint.javax.sql : DataSource;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// URLs

/// The engine settings a JDBC URL selects.
struct JdbcTarget
{
    /// The engine driver.
    Driver driver;
    /// The engine connection string: a libpq conninfo string or a SQLite path or URI.
    string connectionString;
}

/++
Parse a JDBC URL with connection properties: `jdbc:sqlite:<path>`, `jdbc:sqlite::memory:`,
`jdbc:sqlite:file:<name>?mode=memory&cache=shared`, or `jdbc:postgresql://host[:port]/database[?key=value&...]`.
`user` and `password` come from `info` unless the URL names them. Throws `SQLException` (08001) for other URLs.
+/
JdbcTarget parseUrl(string url, string[string] info)
{
    enum sqlite = "jdbc:sqlite:";
    enum postgres = "jdbc:postgresql:";
    if (startsWith(url, sqlite))
    {
        auto path = url[sqlite.length .. $];
        // A private in-memory database would vanish with each connection; share one per process instead.
        if (path == ":memory:" || path.length == 0)
            path = "file:flint-memory?mode=memory&cache=shared";
        return JdbcTarget(Driver.sqlite, path);
    }
    if (startsWith(url, postgres))
        return JdbcTarget(Driver.postgres, postgresConninfo(url[postgres.length .. $], info));
    throw new SQLException("No suitable driver found for " ~ url, "08001");
}

private string postgresConninfo(string rest, string[string] info)
{
    string host = "localhost", port, database, query;
    if (startsWith(rest, "//"))
    {
        rest = rest[2 .. $];
        const slash = indexOf(rest, '/');
        auto authority = slash < 0 ? rest : rest[0 .. slash];
        rest = slash < 0 ? "" : rest[slash + 1 .. $];
        const colon = lastIndexOf(authority, ':');
        if (colon >= 0 && indexOf(authority, ']') < colon)
        {
            port = authority[colon + 1 .. $];
            authority = authority[0 .. colon];
        }
        if (authority.length)
            host = authority;
    }
    const question = indexOf(rest, '?');
    database = question < 0 ? rest : rest[0 .. question];
    query = question < 0 ? "" : rest[question + 1 .. $];
    string[string] settings;
    foreach (key, value; info)
        settings[key] = value;
    foreach (pair; split(query, '&'))
    {
        const equals = indexOf(pair, '=');
        if (equals > 0)
            settings[pair[0 .. equals]] = pair[equals + 1 .. $];
    }
    string conninfo = "host=" ~ quote(host);
    if (port.length)
        conninfo ~= " port=" ~ quote(port);
    if (database.length)
        conninfo ~= " dbname=" ~ quote(database);
    foreach (key; ["user", "password", "sslmode", "application_name", "connect_timeout"])
        if (auto value = key in settings)
            conninfo ~= " " ~ key ~ "=" ~ quote(*value);
    return conninfo;
}

private string quote(string value)
{
    string result = "'";
    foreach (ch; value)
    {
        if (ch == '\'' || ch == '\\')
            result ~= '\\';
        result ~= ch;
    }
    return result ~ "'";
}

/++
Rewrite JDBC's `?` parameter markers as PostgreSQL's `$1`, `$2`, ..., leaving those inside string literals, quoted
identifiers, dollar-quoted strings and comments alone. Returns the rewritten SQL and the number of markers.
+/
string numberParameters(string sql, out size_t count)
{
    string result;
    size_t i;
    while (i < sql.length)
    {
        const stop = skipLiteral(sql, i);
        if (stop > i)
        {
            result ~= sql[i .. stop];
            i = stop;
        }
        else if (sql[i] == '?')
        {
            result ~= "$" ~ decimal(++count);
            ++i;
        }
        else
            result ~= sql[i++];
    }
    return result;
}

/// The end of the string literal, quoted identifier, comment or dollar-quoted string at `i`, or `i` if none starts there.
private size_t skipLiteral(string sql, size_t i)
{
    const ch = sql[i];
    const next = i + 1 < sql.length ? sql[i + 1] : '\0';
    if (ch == '\'' || ch == '"')
        return closing(sql, i + 1, ch);
    if (ch == '-' && next == '-')
    {
        const end = indexOf(sql[i .. $], '\n');
        return end < 0 ? sql.length : i + end;
    }
    if ((ch == '/' && next == '*') || (ch == '$' && next == '$'))
    {
        const end = indexOfText(sql[i + 2 .. $], ch == '/' ? "*/" : "$$");
        return end < 0 ? sql.length : i + 2 + end + 2;
    }
    return i;
}

private size_t closing(string sql, size_t from, char quoteChar)
{
    size_t i = from;
    while (i < sql.length)
    {
        if (sql[i] == quoteChar)
        {
            // A doubled quote is an escaped quote.
            if (i + 1 < sql.length && sql[i + 1] == quoteChar)
            {
                i += 2;
                continue;
            }
            return i + 1;
        }
        ++i;
    }
    return sql.length;
}

// ---------------------------------------------------------------------------------------------------------------
// Values and failures

/// One materialized cell.
private struct Cell
{
    ValueKind kind;
    long integer;
    double floating;
    string text;
    ubyte[] bytes;
}

/// The `SQLException` for an engine failure: its JDBC 4 subclass chosen by SQLSTATE class.
SQLException sqlException(string task, Status status, string message, SqlFailure failure)
{
    string state = failure.reported ? failure.sqlState.idup : stateOf(status);
    const vendor = failure.vendorCode;
    string reason = failure.reported && failure.message.length ? failure.message.idup : message;
    if (task.length)
        reason = task ~ ": " ~ reason;
    if (status == Status.timedOut || state == "57014")
        return new SQLTimeoutException(reason, state, vendor);
    if (state is null || state.length < 2)
        return new SQLException(reason, state, vendor);
    return byStateClass(reason, state, vendor, status);
}

private SQLException byStateClass(string reason, string state, int vendor, Status status)
{
    switch (state[0 .. 2])
    {
    case "08":
        return status == Status.unavailable ? new SQLTransientConnectionException(reason, state,
                vendor) : new SQLNonTransientConnectionException(reason, state, vendor);
    case "22":
        return new SQLDataException(reason, state, vendor);
    case "23":
        return new SQLIntegrityConstraintViolationException(reason, state, vendor);
    case "28":
        return new SQLInvalidAuthorizationSpecException(reason, state, vendor);
    case "40":
        return new SQLTransactionRollbackException(reason, state, vendor);
    case "42":
        return new SQLSyntaxErrorException(reason, state, vendor);
    case "0A":
        return new SQLFeatureNotSupportedException(reason, state, vendor);
    default:
        return new SQLException(reason, state, vendor);
    }
}

/// The SQLSTATE of an engine status when the driver reported none.
private string stateOf(Status status) pure nothrow @nogc
{
    switch (status)
    {
    case Status.unavailable:
        return "08006"; // connection_failure
    case Status.cancelled:
        return "57014"; // query_canceled
    case Status.invalidArgument:
        return "42000";
    case Status.resourceExhausted:
        return "53000"; // insufficient_resources
    case Status.permissionDenied:
        return "42501";
    case Status.unsupported:
        return "0A000";
    default:
        return "HY000";
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Connections

/// A JDBC connection over one engine lease.
final class FlintConnection : Connection
{
    private Pool pool;
    private EngineConnection lease;
    private bool ownsPool;
    private bool closed_;
    private bool autoCommit = true;
    private bool inTransaction;
    private bool readOnly;
    private int isolation = TRANSACTION_READ_COMMITTED;
    private uint savepointCounter;
    private string url;
    private string user;
    private ubyte[] scratch;
    private FlintDataSource source;

    /// Wrap an acquired lease. `ownsPool` closes the pool with the connection.
    package(flint.engine) this(Pool pool, EngineConnection lease, bool ownsPool, string url, string user)
    {
        this.pool = pool;
        this.lease = lease;
        this.ownsPool = ownsPool;
        this.url = url;
        this.user = user;
        isolation = pool.driver == Driver.sqlite ? TRANSACTION_SERIALIZABLE : TRANSACTION_READ_COMMITTED;
    }

    /// The engine driver behind this connection.
    Driver driver() const pure nothrow @nogc
    {
        return pool.driver;
    }

    /// An arena over this connection's statement buffer, which a statement's parameters and rows pass through.
    package(flint.engine) RequestArena newArena()
    {
        if (scratch is null)
            scratch = new ubyte[1 << 20];
        return RequestArena(scratch);
    }

    package(flint.engine) void checkOpen()
    {
        if (closed_)
            throw new SQLNonTransientConnectionException("Connection is closed", "08003");
    }

    /// Run SQL without parameters or rows; for transaction control and session settings.
    package(flint.engine) void run(string sql, string task = null)
    {
        checkOpen();
        Context context;
        auto arena = newArena();
        auto result = lease.execute(sql, [], arena, context);
        if (!result.ok)
            throw sqlException(task, result.error.code, result.error.message, lease.lastFailure());
    }

    /// Begin the transaction a manual-commit connection needs before its next statement.
    package(flint.engine) void beginIfNeeded()
    {
        if (autoCommit || inTransaction)
            return;
        run(beginStatement(), "BEGIN");
        inTransaction = true;
    }

    private string beginStatement()
    {
        if (pool.driver == Driver.sqlite)
            return isolation == TRANSACTION_SERIALIZABLE ? "BEGIN DEFERRED" : "BEGIN";
        string sql = "BEGIN ISOLATION LEVEL " ~ isolationName(isolation);
        if (readOnly)
            sql ~= " READ ONLY";
        return sql;
    }

    package(flint.engine) EngineConnection* engineLease() return
    {
        return &lease;
    }

    override Statement createStatement()
    {
        checkOpen();
        return new FlintPreparedStatement(this, null, Statement.NO_GENERATED_KEYS, null);
    }

    override PreparedStatement prepareStatement(string sql)
    {
        checkOpen();
        return new FlintPreparedStatement(this, sql, Statement.NO_GENERATED_KEYS, null);
    }

    override PreparedStatement prepareStatement(string sql, int autoGeneratedKeys)
    {
        checkOpen();
        return new FlintPreparedStatement(this, sql, autoGeneratedKeys, null);
    }

    override PreparedStatement prepareStatement(string sql, string[] columnNames)
    {
        checkOpen();
        return new FlintPreparedStatement(this, sql, Statement.RETURN_GENERATED_KEYS, columnNames);
    }

    override string nativeSQL(string sql)
    {
        size_t count;
        return pool.driver == Driver.postgres ? numberParameters(sql, count) : sql;
    }

    override void setAutoCommit(bool autoCommit)
    {
        checkOpen();
        if (autoCommit == this.autoCommit)
            return;
        // JDBC: switching auto-commit on commits the current transaction.
        if (autoCommit && inTransaction)
            commit();
        this.autoCommit = autoCommit;
    }

    override bool getAutoCommit()
    {
        checkOpen();
        return autoCommit;
    }

    override void commit()
    {
        checkOpen();
        if (autoCommit)
            throw new SQLException("Cannot commit when autoCommit is enabled", "25000");
        if (!inTransaction)
            return;
        inTransaction = false;
        run("COMMIT", "COMMIT");
    }

    override void rollback()
    {
        checkOpen();
        if (autoCommit)
            throw new SQLException("Cannot rollback when autoCommit is enabled", "25000");
        if (!inTransaction)
            return;
        inTransaction = false;
        run("ROLLBACK", "ROLLBACK");
    }

    override void rollback(Savepoint savepoint)
    {
        checkOpen();
        auto flint = cast(FlintSavepoint) savepoint;
        if (flint is null || flint.connection !is this)
            throw new SQLException("Savepoint belongs to another connection", "3B001");
        run("ROLLBACK TO SAVEPOINT " ~ flint.identifier, "ROLLBACK TO SAVEPOINT");
    }

    override void close()
    {
        if (closed_)
            return;
        closed_ = true;
        Context context;
        if (inTransaction)
        {
            auto arena = newArena();
            // Returned to the pool mid-transaction: the engine rolls the lease back on release anyway.
            cast(void) lease.execute("ROLLBACK", [], arena, context);
            inTransaction = false;
        }
        if (readOnly && pool.driver == Driver.sqlite)
        {
            auto arena = newArena();
            cast(void) lease.execute("PRAGMA query_only = OFF", [], arena, context);
        }
        cast(void) pool.release(lease);
        if (ownsPool)
            cast(void) pool.close(context);
        if (source !is null)
            source.returned();
    }

    override bool isClosed()
    {
        return closed_;
    }

    override DatabaseMetaData getMetaData()
    {
        checkOpen();
        return new FlintDatabaseMetaData(this);
    }

    override void setReadOnly(bool readOnly)
    {
        checkOpen();
        if (inTransaction)
            throw new SQLException("Cannot change read-only mode during a transaction", "25001");
        if (pool.driver == Driver.sqlite && readOnly != this.readOnly)
            run(readOnly ? "PRAGMA query_only = ON" : "PRAGMA query_only = OFF");
        this.readOnly = readOnly;
    }

    override bool isReadOnly()
    {
        checkOpen();
        return readOnly;
    }

    override void setCatalog(string)
    {
        checkOpen();
    }

    override string getCatalog()
    {
        checkOpen();
        return null;
    }

    override void setTransactionIsolation(int level)
    {
        checkOpen();
        if (isolationName(level) is null)
            throw new SQLException("Unsupported transaction isolation level", "HY024");
        if (inTransaction)
            throw new SQLException("Cannot change the isolation level during a transaction", "25001");
        isolation = level;
    }

    override int getTransactionIsolation()
    {
        checkOpen();
        return isolation;
    }

    override SQLWarning getWarnings()
    {
        checkOpen();
        return null;
    }

    override void clearWarnings()
    {
        checkOpen();
    }

    override Savepoint setSavepoint()
    {
        return makeSavepoint(null);
    }

    override Savepoint setSavepoint(string name)
    {
        return makeSavepoint(name);
    }

    private Savepoint makeSavepoint(string name)
    {
        checkOpen();
        if (autoCommit)
            throw new SQLException("Cannot set a savepoint when autoCommit is enabled", "25000");
        beginIfNeeded();
        auto savepoint = new FlintSavepoint(this, ++savepointCounter, name);
        run("SAVEPOINT " ~ savepoint.identifier, "SAVEPOINT");
        return savepoint;
    }

    override void releaseSavepoint(Savepoint savepoint)
    {
        checkOpen();
        auto flint = cast(FlintSavepoint) savepoint;
        if (flint is null || flint.connection !is this)
            throw new SQLException("Savepoint belongs to another connection", "3B001");
        run("RELEASE SAVEPOINT " ~ flint.identifier, "RELEASE SAVEPOINT");
    }

    override bool isValid(int timeout)
    {
        if (closed_)
            return false;
        try
        {
            run("SELECT 1");
            return true;
        }
        catch (SQLException)
            return false;
    }

    override void setSchema(string schema)
    {
        checkOpen();
        if (pool.driver == Driver.postgres)
            run("SET search_path TO " ~ quoteIdentifier(schema));
    }

    override string getSchema()
    {
        checkOpen();
        return pool.driver == Driver.sqlite ? "main" : null;
    }

    override Object unwrap(const TypeInfo_Class iface)
    {
        if (isWrapperFor(iface))
            return this;
        throw new SQLException("Not a wrapper for " ~ iface.name);
    }

    override bool isWrapperFor(const TypeInfo_Class iface)
    {
        return iface is typeid(FlintConnection) || iface.isBaseOf(typeid(FlintConnection));
    }
}

private string isolationName(int level) pure nothrow @nogc
{
    switch (level)
    {
    case Connection.TRANSACTION_READ_UNCOMMITTED:
        return "READ UNCOMMITTED";
    case Connection.TRANSACTION_READ_COMMITTED:
        return "READ COMMITTED";
    case Connection.TRANSACTION_REPEATABLE_READ:
        return "REPEATABLE READ";
    case Connection.TRANSACTION_SERIALIZABLE:
        return "SERIALIZABLE";
    default:
        return null;
    }
}

private string quoteIdentifier(string name)
{
    string result = "\"";
    foreach (ch; name)
    {
        if (ch == '"')
            result ~= '"';
        result ~= ch;
    }
    return result ~ "\"";
}

/// A savepoint of a `FlintConnection`.
final class FlintSavepoint : Savepoint
{
    private FlintConnection connection;
    private int id;
    private string name;

    private this(FlintConnection connection, int id, string name)
    {
        this.connection = connection;
        this.id = id;
        this.name = name;
    }

    /// The SQL identifier of the savepoint.
    string identifier()
    {
        return name !is null ? quoteIdentifier(name) : "flint_savepoint_" ~ decimal(id);
    }

    override int getSavepointId()
    {
        if (name !is null)
            throw new SQLException("A named savepoint has no id", "3B001");
        return id;
    }

    override string getSavepointName()
    {
        if (name is null)
            throw new SQLException("An unnamed savepoint has no name", "3B001");
        return name;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Statements

/// A statement, prepared or not, on a `FlintConnection`.
final class FlintPreparedStatement : PreparedStatement
{
    private FlintConnection connection;
    private string sql;
    private Any[] parameters;
    private Any[][] batch;
    private string[] batchSql;
    private int autoGeneratedKeys;
    private string[] keyColumns;
    private bool closed_;
    private int maxRows;
    private int fetchSize;
    private int queryTimeout;
    private FlintResultSet current;
    private long updateCount = -1;
    private FlintResultSet generatedKeys;

    private this(FlintConnection connection, string sql, int autoGeneratedKeys, string[] keyColumns)
    {
        this.connection = connection;
        this.sql = sql;
        this.autoGeneratedKeys = autoGeneratedKeys;
        this.keyColumns = keyColumns;
    }

    private void checkOpen()
    {
        if (closed_)
            throw new SQLException("Statement is closed", "HY010");
        connection.checkOpen();
    }

    /// The cancellation source of the query timeout, or a failed result when there is none.
    private Result!CancelSource timeoutSource()
    {
        if (queryTimeout <= 0)
            return Result!CancelSource(CancelSource.init, ArenaError(Status.invalidArgument, "no query timeout"));
        return CancelSource.create(Context.init, Deadline.afterMillis(queryTimeout * 1000L));
    }

    private string nativeSql(string text)
    {
        size_t count;
        return connection.driver == Driver.postgres ? numberParameters(text, count) : text;
    }

    /// Bind the parameters into the arena as engine values.
    private SqlValue[] bind(ref RequestArena arena, Any[] values)
    {
        auto bound = new SqlValue[values.length];
        foreach (index, value; values)
            bound[index] = toSqlValue(arena, value, cast(int) index + 1);
        return bound;
    }

    /// Run `text` and materialize its rows, or count the rows it changed.
    private FlintResultSet execute(string text, Any[] values, bool wantRows)
    {
        checkOpen();
        connection.beginIfNeeded();
        auto timeout = timeoutSource();
        auto context = timeout.ok ? timeout.value.context() : Context.init;
        auto arena = connection.newArena();
        auto params = bind(arena, values);
        auto lease = connection.engineLease();
        const native = nativeSql(text);
        if (!wantRows)
        {
            auto result = lease.execute(native, params, arena, context);
            if (!result.ok)
                throw sqlException(null, result.error.code, result.error.message, lease.lastFailure());
            updateCount = cast(long) result.value;
            return null;
        }
        auto rows = new FlintResultSet(this);
        string failure;
        auto status = lease.queryRows(native, params, arena, context, (ref Row row) @safe nothrow{
            try
                rows.append(row, arena);
            catch (Exception ex)
            {
                failure = ex.msg;
                return ArenaError(Status.invalidArgument, "row copy failed");
            }
            // Each row is copied to GC memory, so the arena space it used is free again.
            cast(void) arena.reset();
            return ArenaError.init;
        });
        if (status.code != Status.ok)
        {
            if (failure.length)
                throw new SQLException("Could not read a row: " ~ failure, "HY000");
            throw sqlException(null, status.code, status.message, lease.lastFailure());
        }
        if (maxRows > 0)
            rows.limit(maxRows);
        return rows;
    }

    private bool returnsKeys()
    {
        return autoGeneratedKeys == Statement.RETURN_GENERATED_KEYS;
    }

    /// Run an update and keep its generated keys, as JDBC's `RETURN_GENERATED_KEYS` asks.
    private long update(string text, Any[] values)
    {
        generatedKeys = null;
        if (!returnsKeys())
        {
            execute(text, values, false);
            return updateCount;
        }
        if (connection.driver == Driver.postgres)
        {
            auto returning = text ~ " RETURNING " ~ (keyColumns.length ? joinIdentifiers(keyColumns) : "*");
            generatedKeys = execute(returning, values, true);
            updateCount = generatedKeys.rowCount;
            return updateCount;
        }
        execute(text, values, false);
        const changed = updateCount;
        // SQLite: the key of the row the statement inserted.
        generatedKeys = execute("SELECT last_insert_rowid() AS " ~ (keyColumns.length
                ? quoteIdentifier(keyColumns[0]) : "GENERATED_KEY"), null, true);
        updateCount = changed;
        return changed;
    }

    // Statement

    override ResultSet executeQuery(string text)
    {
        current = execute(text, null, true);
        updateCount = -1;
        return current;
    }

    override int executeUpdate(string text)
    {
        return clampInt(update(text, null));
    }

    override long executeLargeUpdate(string text)
    {
        return update(text, null);
    }

    override bool execute(string text)
    {
        return executeAny(text, null);
    }

    private bool executeAny(string text, Any[] values)
    {
        if (producesRows(text))
        {
            current = execute(text, values, true);
            updateCount = -1;
            return true;
        }
        current = null;
        update(text, values);
        return false;
    }

    override ResultSet getResultSet()
    {
        checkOpen();
        return current;
    }

    override int getUpdateCount()
    {
        checkOpen();
        return clampInt(updateCount);
    }

    override long getLargeUpdateCount()
    {
        checkOpen();
        return updateCount;
    }

    override bool getMoreResults()
    {
        checkOpen();
        current = null;
        updateCount = -1;
        return false;
    }

    override void setMaxRows(int max)
    {
        checkOpen();
        if (max < 0)
            throw new SQLException("Max rows must be >= 0", "HY024");
        maxRows = max;
    }

    override int getMaxRows()
    {
        checkOpen();
        return maxRows;
    }

    override void setFetchSize(int rows)
    {
        checkOpen();
        if (rows < 0)
            throw new SQLException("Fetch size must be >= 0", "HY024");
        fetchSize = rows;
    }

    override int getFetchSize()
    {
        checkOpen();
        return fetchSize;
    }

    override void setQueryTimeout(int seconds)
    {
        checkOpen();
        if (seconds < 0)
            throw new SQLException("Query timeout must be >= 0", "HY024");
        queryTimeout = seconds;
    }

    override int getQueryTimeout()
    {
        checkOpen();
        return queryTimeout;
    }

    override void cancel()
    {
        checkOpen();
        throw new SQLFeatureNotSupportedException("cancel: use setQueryTimeout or a cancellation context", "0A000");
    }

    override SQLWarning getWarnings()
    {
        checkOpen();
        return null;
    }

    override void clearWarnings()
    {
        checkOpen();
    }

    override void addBatch(string text)
    {
        checkOpen();
        batchSql ~= text;
    }

    override void clearBatch()
    {
        checkOpen();
        batchSql = null;
        batch = null;
    }

    override int[] executeBatch()
    {
        auto counts = executeLargeBatch();
        auto result = new int[counts.length];
        foreach (index, count; counts)
            result[index] = clampInt(count);
        return result;
    }

    override long[] executeLargeBatch()
    {
        checkOpen();
        long[] counts;
        try
        {
            foreach (text; batchSql)
                counts ~= update(text, null);
            foreach (values; batch)
                counts ~= update(sql, values);
        }
        catch (SQLException ex)
        {
            clearBatch();
            auto failure = new BatchUpdateException(ex.getMessage(), ex.getSQLState(), ex.getErrorCode(), counts, ex);
            failure.setNextException(ex);
            throw failure;
        }
        clearBatch();
        return counts;
    }

    override Connection getConnection()
    {
        checkOpen();
        return connection;
    }

    override ResultSet getGeneratedKeys()
    {
        checkOpen();
        if (generatedKeys is null)
            return new FlintResultSet(this);
        return generatedKeys;
    }

    override void close()
    {
        closed_ = true;
        current = null;
    }

    override bool isClosed()
    {
        return closed_;
    }

    // PreparedStatement

    override ResultSet executeQuery()
    {
        current = execute(requireSql(), parameters, true);
        updateCount = -1;
        return current;
    }

    override int executeUpdate()
    {
        return clampInt(update(requireSql(), parameters));
    }

    override long executeLargeUpdate()
    {
        return update(requireSql(), parameters);
    }

    override bool execute()
    {
        return executeAny(requireSql(), parameters);
    }

    override void addBatch()
    {
        checkOpen();
        batch ~= parameters.dup;
    }

    override void clearParameters()
    {
        checkOpen();
        parameters = null;
    }

    private string requireSql()
    {
        if (sql is null)
            throw new SQLException("This statement was created without SQL", "HY010");
        return sql;
    }

    private void set(int parameterIndex, Any value)
    {
        checkOpen();
        if (parameterIndex < 1)
            throw new SQLException("Parameter index out of range: " ~ decimal(parameterIndex), "07009");
        if (parameters.length < parameterIndex)
            parameters.length = parameterIndex;
        parameters[parameterIndex - 1] = value;
    }

    override void setNull(int parameterIndex, int)
    {
        set(parameterIndex, Any.init);
    }

    override void setNull(int parameterIndex, int, string)
    {
        set(parameterIndex, Any.init);
    }

    override void setBoolean(int parameterIndex, bool x)
    {
        set(parameterIndex, Any.of(x));
    }

    override void setByte(int parameterIndex, byte x)
    {
        set(parameterIndex, Any.of(cast(long) x));
    }

    override void setShort(int parameterIndex, short x)
    {
        set(parameterIndex, Any.of(cast(long) x));
    }

    override void setInt(int parameterIndex, int x)
    {
        set(parameterIndex, Any.of(cast(long) x));
    }

    override void setLong(int parameterIndex, long x)
    {
        set(parameterIndex, Any.of(x));
    }

    override void setFloat(int parameterIndex, float x)
    {
        set(parameterIndex, Any.of(cast(double) x));
    }

    override void setDouble(int parameterIndex, double x)
    {
        set(parameterIndex, Any.of(x));
    }

    override void setString(int parameterIndex, string x)
    {
        set(parameterIndex, x is null ? Any.init : Any.of(x));
    }

    override void setBytes(int parameterIndex, const(ubyte)[] x)
    {
        set(parameterIndex, x is null ? Any.init : Any.of(x.idup));
    }

    override void setObject(int parameterIndex, Any x)
    {
        set(parameterIndex, x);
    }

    override void setObject(int parameterIndex, Any x, int)
    {
        set(parameterIndex, x);
    }

    override ResultSetMetaData getMetaData()
    {
        checkOpen();
        return null;
    }

    override ParameterMetaData getParameterMetaData()
    {
        checkOpen();
        size_t count;
        numberParameters(requireSql(), count);
        return new FlintParameterMetaData(cast(int) count);
    }

    override Object unwrap(const TypeInfo_Class iface)
    {
        if (isWrapperFor(iface))
            return this;
        throw new SQLException("Not a wrapper for " ~ iface.name);
    }

    override bool isWrapperFor(const TypeInfo_Class iface)
    {
        return iface is typeid(FlintPreparedStatement) || iface.isBaseOf(typeid(FlintPreparedStatement));
    }
}

/// Convert a bound value to the engine's.
private SqlValue toSqlValue(ref RequestArena arena, Any value, int index)
{
    if (value.isNull)
        return SqlValue(ValueKind.null_);
    const number = scalar(value);
    if (number.kind != ValueKind.null_)
        return number;
    const name = value.typeName;
    if (name == "string")
        return SqlValue(ValueKind.text, 0, 0, copy(arena, cast(const(ubyte)[]) value.get!string));
    if (name == "immutable(ubyte)[]")
        return SqlValue(ValueKind.bytes, 0, 0, copy(arena, value.get!(immutable(ubyte)[])));
    if (name == "ubyte[]")
        return SqlValue(ValueKind.bytes, 0, 0, copy(arena, value.get!(ubyte[])));
    if (auto object = value.asObject())
        return SqlValue(ValueKind.text, 0, 0, copy(arena, cast(const(ubyte)[]) objectToString(object)));
    throw new SQLFeatureNotSupportedException("Unsupported parameter " ~ decimal(index) ~ " of type " ~ name, "0A000");
}

/// A boolean or numeric `Any` as an engine value; a null value for any other type.
private SqlValue scalar(Any value)
{
    const name = value.typeName;
    if (name == "bool")
        return SqlValue(ValueKind.boolean, value.get!bool ? 1 : 0);
    static foreach (T; imported!"std.meta".AliasSeq!(byte, short, int, long, ubyte, ushort, uint, ulong))
    {
        if (name == T.stringof)
            return SqlValue(ValueKind.int64, cast(long) value.get!T);
    }
    if (name == "float")
        return SqlValue(ValueKind.float64, 0, value.get!float);
    if (name == "double")
        return SqlValue(ValueKind.float64, 0, value.get!double);
    return SqlValue(ValueKind.null_);
}

private Buffer copy(ref RequestArena arena, scope const(ubyte)[] bytes)
{
    auto copied = arena.copyIn(bytes);
    if (!copied.ok)
        throw new SQLException("Parameter too large for the statement buffer", "54000");
    return copied.value;
}

/// Whether a statement returns rows, for `execute(String)`.
private bool producesRows(string sql)
{
    size_t i;
    while (i < sql.length && (sql[i] == ' ' || sql[i] == '\n' || sql[i] == '\t' || sql[i] == '\r' || sql[i] == '('))
        ++i;
    auto rest = sql[i .. $];
    foreach (keyword; ["SELECT", "WITH", "VALUES", "SHOW", "EXPLAIN", "PRAGMA", "TABLE"])
        if (rest.length >= keyword.length && equalsIgnoreCase(rest[0 .. keyword.length], keyword))
            return true;
    return indexOfText(upper(sql), " RETURNING ") >= 0;
}

private string joinIdentifiers(string[] names)
{
    string result;
    foreach (index, name; names)
        result ~= (index ? ", " : "") ~ quoteIdentifier(name);
    return result;
}

private int clampInt(long value) pure nothrow @nogc
{
    return value > int.max ? int.max : value < int.min ? int.min : cast(int) value;
}

// ---------------------------------------------------------------------------------------------------------------
// Result sets

/// The rows of a query, copied into GC memory.
final class FlintResultSet : ResultSet
{
    private FlintPreparedStatement statement;
    private string[] labels;
    private Cell[][] rows;
    private size_t position;
    private bool closed_;
    private bool lastWasNull;

    private this(FlintPreparedStatement statement)
    {
        this.statement = statement;
    }

    private void append(ref Row row, ref RequestArena arena)
    {
        const count = row.columns;
        if (labels is null && count)
        {
            labels = new string[count];
            foreach (column; 0 .. count)
            {
                auto label = row.name(column, arena);
                if (!label.ok)
                    throw new SQLException("Column label unavailable", "HY000");
                labels[column] = readText(arena, label.value);
            }
        }
        auto cells = new Cell[count];
        foreach (column; 0 .. count)
        {
            auto value = row.value(column, arena);
            if (!value.ok)
                throw new SQLException("Column value unavailable: " ~ value.error.message, "HY000");
            auto cell = Cell(value.value.kind, value.value.integer, value.value.floating);
            if (cell.kind == ValueKind.text)
                cell.text = readText(arena, value.value.bytes);
            else if (cell.kind == ValueKind.bytes)
                cell.bytes = readBytes(arena, value.value.bytes);
            cells[column] = cell;
        }
        rows ~= cells;
    }

    private void limit(int maxRows)
    {
        if (rows.length > maxRows)
            rows = rows[0 .. maxRows];
    }

    /// The number of rows.
    size_t rowCount() const pure nothrow @nogc
    {
        return rows.length;
    }

    private void checkOpen()
    {
        if (closed_)
            throw new SQLException("ResultSet is closed", "24000");
    }

    private Cell cell(int columnIndex)
    {
        checkOpen();
        if (position == 0 || position > rows.length)
            throw new SQLException("No current row: call next() first", "24000");
        if (columnIndex < 1 || columnIndex > labels.length)
            throw new SQLException("Column index out of range: " ~ decimal(columnIndex), "07009");
        auto found = rows[position - 1][columnIndex - 1];
        lastWasNull = found.kind == ValueKind.null_;
        return found;
    }

    override bool next()
    {
        checkOpen();
        if (position <= rows.length)
            ++position;
        return position <= rows.length;
    }

    override void close()
    {
        closed_ = true;
    }

    override bool wasNull()
    {
        checkOpen();
        return lastWasNull;
    }

    override string getString(int columnIndex)
    {
        auto c = cell(columnIndex);
        final switch (c.kind)
        {
        case ValueKind.null_:
            return null;
        case ValueKind.boolean:
            return c.integer ? "true" : "false";
        case ValueKind.int64:
            return decimal(c.integer);
        case ValueKind.float64:
            return floatText(c.floating);
        case ValueKind.text:
            return c.text;
        case ValueKind.bytes:
            return cast(string) c.bytes.idup;
        }
    }

    override bool getBoolean(int columnIndex)
    {
        auto c = cell(columnIndex);
        final switch (c.kind)
        {
        case ValueKind.null_:
            return false;
        case ValueKind.boolean, ValueKind.int64:
            return c.integer != 0;
        case ValueKind.float64:
            return c.floating != 0;
        case ValueKind.text:
            return c.text == "1" || equalsIgnoreCase(c.text, "true")
                || equalsIgnoreCase(c.text, "t") || equalsIgnoreCase(c.text, "yes") || equalsIgnoreCase(c.text, "y");
        case ValueKind.bytes:
            throw new SQLException("Cannot convert bytes to boolean", "22018");
        }
    }

    override byte getByte(int columnIndex)
    {
        return narrow!byte(getLong(columnIndex));
    }

    override short getShort(int columnIndex)
    {
        return narrow!short(getLong(columnIndex));
    }

    override int getInt(int columnIndex)
    {
        return narrow!int(getLong(columnIndex));
    }

    override long getLong(int columnIndex)
    {
        auto c = cell(columnIndex);
        final switch (c.kind)
        {
        case ValueKind.null_:
            return 0;
        case ValueKind.boolean, ValueKind.int64:
            return c.integer;
        case ValueKind.float64:
            return cast(long) c.floating;
        case ValueKind.text:
            return parseLong(c.text);
        case ValueKind.bytes:
            throw new SQLException("Cannot convert bytes to a number", "22018");
        }
    }

    override float getFloat(int columnIndex)
    {
        return cast(float) getDouble(columnIndex);
    }

    override double getDouble(int columnIndex)
    {
        auto c = cell(columnIndex);
        final switch (c.kind)
        {
        case ValueKind.null_:
            return 0;
        case ValueKind.boolean, ValueKind.int64:
            return cast(double) c.integer;
        case ValueKind.float64:
            return c.floating;
        case ValueKind.text:
            return parseDouble(c.text);
        case ValueKind.bytes:
            throw new SQLException("Cannot convert bytes to a number", "22018");
        }
    }

    override ubyte[] getBytes(int columnIndex)
    {
        auto c = cell(columnIndex);
        if (c.kind == ValueKind.null_)
            return null;
        if (c.kind == ValueKind.bytes)
            return c.bytes.dup;
        if (c.kind == ValueKind.text)
            return cast(ubyte[]) c.text.dup;
        throw new SQLException("Cannot convert a number to bytes", "22018");
    }

    override Any getObject(int columnIndex)
    {
        auto c = cell(columnIndex);
        final switch (c.kind)
        {
        case ValueKind.null_:
            return Any.init;
        case ValueKind.boolean:
            return Any.of(c.integer != 0);
        case ValueKind.int64:
            return Any.of(c.integer);
        case ValueKind.float64:
            return Any.of(c.floating);
        case ValueKind.text:
            return Any.of(c.text);
        case ValueKind.bytes:
            return Any.of(c.bytes.idup);
        }
    }

    override string getString(string columnLabel)
    {
        return getString(findColumn(columnLabel));
    }

    override bool getBoolean(string columnLabel)
    {
        return getBoolean(findColumn(columnLabel));
    }

    override byte getByte(string columnLabel)
    {
        return getByte(findColumn(columnLabel));
    }

    override short getShort(string columnLabel)
    {
        return getShort(findColumn(columnLabel));
    }

    override int getInt(string columnLabel)
    {
        return getInt(findColumn(columnLabel));
    }

    override long getLong(string columnLabel)
    {
        return getLong(findColumn(columnLabel));
    }

    override float getFloat(string columnLabel)
    {
        return getFloat(findColumn(columnLabel));
    }

    override double getDouble(string columnLabel)
    {
        return getDouble(findColumn(columnLabel));
    }

    override ubyte[] getBytes(string columnLabel)
    {
        return getBytes(findColumn(columnLabel));
    }

    override Any getObject(string columnLabel)
    {
        return getObject(findColumn(columnLabel));
    }

    override int findColumn(string columnLabel)
    {
        checkOpen();
        foreach (index, label; labels)
            if (equalsIgnoreCase(label, columnLabel))
                return cast(int) index + 1;
        throw new SQLException("The column name " ~ columnLabel ~ " was not found in this ResultSet", "42703");
    }

    override ResultSetMetaData getMetaData()
    {
        checkOpen();
        return new FlintResultSetMetaData(this);
    }

    override int getRow()
    {
        checkOpen();
        return position > rows.length ? 0 : cast(int) position;
    }

    override bool isClosed()
    {
        return closed_;
    }

    override Statement getStatement()
    {
        return statement;
    }

    override SQLWarning getWarnings()
    {
        checkOpen();
        return null;
    }

    override void clearWarnings()
    {
        checkOpen();
    }

    override int getType()
    {
        return ResultSet.TYPE_FORWARD_ONLY;
    }

    override int getConcurrency()
    {
        return ResultSet.CONCUR_READ_ONLY;
    }

    override Object unwrap(const TypeInfo_Class iface)
    {
        if (isWrapperFor(iface))
            return this;
        throw new SQLException("Not a wrapper for " ~ iface.name);
    }

    override bool isWrapperFor(const TypeInfo_Class iface)
    {
        return iface is typeid(FlintResultSet) || iface.isBaseOf(typeid(FlintResultSet));
    }

    /// The JDBC type of a column, from its first non-null value; `Types.NULL` when every value is null.
    private int columnType(int column)
    {
        foreach (row; rows)
        {
            final switch (row[column - 1].kind)
            {
            case ValueKind.null_:
                continue;
            case ValueKind.boolean:
                return Types.BOOLEAN;
            case ValueKind.int64:
                return Types.BIGINT;
            case ValueKind.float64:
                return Types.DOUBLE;
            case ValueKind.text:
                return Types.VARCHAR;
            case ValueKind.bytes:
                return Types.VARBINARY;
            }
        }
        return Types.NULL;
    }
}

private T narrow(T)(long value)
{
    if (value < T.min || value > T.max)
        throw new SQLDataException("Value " ~ decimal(value) ~ " is out of range for " ~ T.stringof, "22003");
    return cast(T) value;
}

/// The columns of a `FlintResultSet`. Types come from the values, since the engine reports no declared types.
final class FlintResultSetMetaData : ResultSetMetaData
{
    private FlintResultSet results;

    private this(FlintResultSet results)
    {
        this.results = results;
    }

    private void check(int column)
    {
        if (column < 1 || column > results.labels.length)
            throw new SQLException("Column index out of range: " ~ decimal(column), "07009");
    }

    override int getColumnCount()
    {
        return cast(int) results.labels.length;
    }

    override string getColumnName(int column)
    {
        check(column);
        return results.labels[column - 1];
    }

    override string getColumnLabel(int column)
    {
        check(column);
        return results.labels[column - 1];
    }

    override int getColumnType(int column)
    {
        check(column);
        return results.columnType(column);
    }

    override string getColumnTypeName(int column)
    {
        switch (getColumnType(column))
        {
        case Types.BOOLEAN:
            return "BOOLEAN";
        case Types.BIGINT:
            return "BIGINT";
        case Types.DOUBLE:
            return "DOUBLE";
        case Types.VARBINARY:
            return "BLOB";
        case Types.NULL:
            return "NULL";
        default:
            return "TEXT";
        }
    }

    override string getColumnClassName(int column)
    {
        switch (getColumnType(column))
        {
        case Types.BOOLEAN:
            return "bool";
        case Types.BIGINT:
            return "long";
        case Types.DOUBLE:
            return "double";
        case Types.VARBINARY:
            return "immutable(ubyte)[]";
        default:
            return "string";
        }
    }

    override int isNullable(int column)
    {
        check(column);
        return ResultSetMetaData.columnNullableUnknown;
    }

    override string getTableName(int column)
    {
        check(column);
        return "";
    }

    override string getSchemaName(int column)
    {
        check(column);
        return "";
    }

    override string getCatalogName(int column)
    {
        check(column);
        return "";
    }

    override int getPrecision(int column)
    {
        check(column);
        return 0;
    }

    override int getScale(int column)
    {
        check(column);
        return 0;
    }

    override bool isAutoIncrement(int column)
    {
        check(column);
        return false;
    }

    override Object unwrap(const TypeInfo_Class iface)
    {
        if (iface is typeid(FlintResultSetMetaData))
            return this;
        throw new SQLException("Not a wrapper for " ~ iface.name);
    }

    override bool isWrapperFor(const TypeInfo_Class iface)
    {
        return iface is typeid(FlintResultSetMetaData);
    }
}

/// The parameters of a prepared statement: their count; their types are unknown until bound.
final class FlintParameterMetaData : ParameterMetaData
{
    private int count;

    private this(int count)
    {
        this.count = count;
    }

    override int getParameterCount()
    {
        return count;
    }

    override int getParameterType(int)
    {
        return Types.OTHER;
    }

    override string getParameterTypeName(int)
    {
        return null;
    }

    override int isNullable(int)
    {
        return ParameterMetaData.parameterNullableUnknown;
    }

    override Object unwrap(const TypeInfo_Class iface)
    {
        if (iface is typeid(FlintParameterMetaData))
            return this;
        throw new SQLException("Not a wrapper for " ~ iface.name);
    }

    override bool isWrapperFor(const TypeInfo_Class iface)
    {
        return iface is typeid(FlintParameterMetaData);
    }
}

/// What a `FlintConnection`'s database is.
final class FlintDatabaseMetaData : DatabaseMetaData
{
    private FlintConnection connection;

    private this(FlintConnection connection)
    {
        this.connection = connection;
    }

    private bool sqlite()
    {
        return connection.driver == Driver.sqlite;
    }

    override string getURL()
    {
        return connection.url;
    }

    override string getUserName()
    {
        return connection.user;
    }

    override string getDatabaseProductName()
    {
        return sqlite() ? "SQLite" : "PostgreSQL";
    }

    override string getDatabaseProductVersion()
    {
        return sqlite() ? "3.54.1" : "18.7";
    }

    override int getDatabaseMajorVersion()
    {
        return sqlite() ? 3 : 18;
    }

    override int getDatabaseMinorVersion()
    {
        return sqlite() ? 54 : 7;
    }

    override string getDriverName()
    {
        return "Flint JDBC driver";
    }

    override string getDriverVersion()
    {
        return "1.0";
    }

    override int getJDBCMajorVersion()
    {
        return 4;
    }

    override int getJDBCMinorVersion()
    {
        return 3;
    }

    override string getIdentifierQuoteString()
    {
        return "\"";
    }

    override bool storesUpperCaseIdentifiers()
    {
        return false;
    }

    override bool storesLowerCaseIdentifiers()
    {
        return !sqlite();
    }

    override bool storesMixedCaseIdentifiers()
    {
        return sqlite();
    }

    override bool supportsBatchUpdates()
    {
        return true;
    }

    override bool supportsSavepoints()
    {
        return true;
    }

    override bool supportsGetGeneratedKeys()
    {
        return true;
    }

    override bool supportsTransactions()
    {
        return true;
    }

    override bool supportsTransactionIsolationLevel(int level)
    {
        return isolationName(level) !is null;
    }

    override bool supportsResultSetType(int type)
    {
        return type == ResultSet.TYPE_FORWARD_ONLY;
    }

    override int getDefaultTransactionIsolation()
    {
        return sqlite() ? Connection.TRANSACTION_SERIALIZABLE : Connection.TRANSACTION_READ_COMMITTED;
    }

    override Connection getConnection()
    {
        return connection;
    }

    override Object unwrap(const TypeInfo_Class iface)
    {
        if (iface is typeid(FlintDatabaseMetaData))
            return this;
        throw new SQLException("Not a wrapper for " ~ iface.name);
    }

    override bool isWrapperFor(const TypeInfo_Class iface)
    {
        return iface is typeid(FlintDatabaseMetaData);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Driver and data source

/// Open an engine pool for `target`, or throw `SQLException`.
private Pool openPool(JdbcTarget target, uint size, long acquireTimeoutNanos)
{
    PoolOptions options;
    options.driver = target.driver;
    options.connectionString = target.connectionString;
    options.maxConnections = size;
    options.acquireTimeoutNanos = acquireTimeoutNanos;
    Pool pool;
    auto opened = pool.open(options);
    if (opened.code != Status.ok)
        throw sqlException("Could not open the connection pool", opened.code, opened.message, SqlFailure.init);
    return pool;
}

private EngineConnection acquireLease(ref Pool pool)
{
    Context context;
    auto acquired = pool.acquire(context);
    if (!acquired.ok)
        throw sqlException("Could not acquire a connection", acquired.error.code,
                acquired.error.message, SqlFailure.init);
    return acquired.value;
}

/// The Flint JDBC driver, for `jdbc:sqlite:` and `jdbc:postgresql:` URLs.
final class FlintDriver : Driver_
{
    override Connection connect(string url, Properties info)
    {
        if (!acceptsURL(url))
            return null;
        string[string] settings;
        if (info !is null)
            foreach (name; info.stringPropertyNames().toArray())
                settings[name] = info.getProperty(name);
        auto target = parseUrl(url, settings);
        auto pool = openPool(target, 1, 30_000_000_000L);
        EngineConnection lease;
        try
            lease = acquireLease(pool);
        catch (SQLException ex)
        {
            Context context;
            cast(void) pool.close(context);
            throw ex;
        }
        auto connection = new FlintConnection(pool, lease, true, url, settings.get("user", null));
        // The engine opens the native session lazily; reach the server now, as JDBC's connect does.
        try
            connection.run("SELECT 1", "connect");
        catch (SQLException ex)
        {
            connection.close();
            throw ex;
        }
        return connection;
    }

    override bool acceptsURL(string url)
    {
        return startsWith(url, "jdbc:sqlite:") || startsWith(url, "jdbc:postgresql:");
    }

    override int getMajorVersion()
    {
        return 1;
    }

    override int getMinorVersion()
    {
        return 0;
    }

    override bool jdbcCompliant()
    {
        return false;
    }
}

private alias Driver_ = flint.java.sql.Driver;

private flint.java.sql.Driver supplyDriver()
{
    return new FlintDriver;
}

shared static this()
{
    DriverManager.registerDriver(&supplyDriver);
}

/++
A pooled `DataSource` over one engine pool, configured with HikariCP's property names (`jdbcUrl`, `username`,
`password`, `maximumPoolSize`, `connectionTimeout`, `poolName`, `autoCommit`, `readOnly`, `transactionIsolation`). The
engine pool opens on the first `getConnection` and holds at most 16 connections. `close` closes it.
+/
final class FlintDataSource : DataSource
{
    private string jdbcUrl;
    private string username;
    private string password;
    private int maximumPoolSize = 10;
    private long connectionTimeout = 30_000;
    private string poolName;
    private bool autoCommit = true;
    private bool readOnly;
    private int transactionIsolation = -1;
    private int loginTimeout;
    private Pool pool;
    private bool opened;
    private bool closed_;

    /// Create an unconfigured data source.
    this()
    {
    }

    /// Create a data source for `jdbcUrl`.
    this(string jdbcUrl)
    {
        this.jdbcUrl = jdbcUrl;
    }

    void setJdbcUrl(string jdbcUrl) ///
    {
        checkUnopened();
        this.jdbcUrl = jdbcUrl;
    }

    string getJdbcUrl() ///
    {
        return jdbcUrl;
    }

    void setUsername(string username) ///
    {
        checkUnopened();
        this.username = username;
    }

    string getUsername() ///
    {
        return username;
    }

    void setPassword(string password) ///
    {
        checkUnopened();
        this.password = password;
    }

    string getPassword() ///
    {
        return password;
    }

    /// The most connections the pool holds, between 1 and 16 (the engine's limit).
    void setMaximumPoolSize(int maximumPoolSize)
    {
        checkUnopened();
        if (maximumPoolSize < 1 || maximumPoolSize > 16)
            throw new SQLException("maximumPoolSize must be between 1 and 16", "HY024");
        this.maximumPoolSize = maximumPoolSize;
    }

    int getMaximumPoolSize() ///
    {
        return maximumPoolSize;
    }

    /// The milliseconds `getConnection` waits for a free connection before failing.
    void setConnectionTimeout(long connectionTimeoutMs)
    {
        checkUnopened();
        connectionTimeout = connectionTimeoutMs;
    }

    long getConnectionTimeout() ///
    {
        return connectionTimeout;
    }

    void setPoolName(string poolName) ///
    {
        this.poolName = poolName;
    }

    string getPoolName() ///
    {
        return poolName;
    }

    void setAutoCommit(bool autoCommit) ///
    {
        this.autoCommit = autoCommit;
    }

    /// Whether new connections start in auto-commit mode.
    bool isAutoCommit()
    {
        return autoCommit;
    }

    void setReadOnly(bool readOnly) ///
    {
        this.readOnly = readOnly;
    }

    /// Whether new connections are read-only.
    bool isReadOnly()
    {
        return readOnly;
    }

    /// The default isolation level of new connections, one of `Connection`'s `TRANSACTION_` constants.
    void setTransactionIsolation(int level)
    {
        transactionIsolation = level;
    }

    override void setLoginTimeout(int seconds)
    {
        loginTimeout = seconds;
    }

    override int getLoginTimeout()
    {
        return loginTimeout;
    }

    override Connection getConnection()
    {
        if (closed_)
            throw new SQLNonTransientConnectionException("The data source is closed", "08003");
        if (jdbcUrl is null)
            throw new SQLException("jdbcUrl is required", "08001");
        synchronized (this)
        {
            if (!opened)
            {
                string[string] info;
                if (username !is null)
                    info["user"] = username;
                if (password !is null)
                    info["password"] = password;
                pool = openPool(parseUrl(jdbcUrl, info), maximumPoolSize, connectionTimeout * 1_000_000L);
                opened = true;
            }
        }
        auto connection = new FlintConnection(pool, acquireLease(pool), false, jdbcUrl, username);
        connection.source = this;
        try
        {
            if (transactionIsolation >= 0)
                connection.setTransactionIsolation(transactionIsolation);
            if (readOnly)
                connection.setReadOnly(true);
            if (!autoCommit)
                connection.setAutoCommit(false);
        }
        catch (SQLException ex)
        {
            connection.close();
            throw ex;
        }
        return connection;
    }

    /// Credentials are fixed per pool, as HikariCP's are.
    override Connection getConnection(string username, string password)
    {
        throw new SQLFeatureNotSupportedException("FlintDataSource.getConnection(username, password)", "0A000");
    }

    private void returned()
    {
    }

    /// Close the pool. Connections still out are retired when they are closed.
    void close()
    {
        synchronized (this)
        {
            if (closed_)
                return;
            closed_ = true;
            if (opened)
            {
                Context context;
                cast(void) pool.close(context);
            }
        }
    }

    /// Whether `close` was called.
    bool isClosed()
    {
        return closed_;
    }

    private void checkUnopened()
    {
        if (opened)
            throw new IllegalStateExceptionShim("The configuration of a started pool cannot change");
    }

    override Object unwrap(const TypeInfo_Class iface)
    {
        if (isWrapperFor(iface))
            return this;
        throw new SQLException("Not a wrapper for " ~ iface.name);
    }

    override bool isWrapperFor(const TypeInfo_Class iface)
    {
        return iface is typeid(FlintDataSource) || iface.isBaseOf(typeid(FlintDataSource));
    }
}

private alias IllegalStateExceptionShim = imported!"flint.java.lang".IllegalStateException;

// ---------------------------------------------------------------------------------------------------------------
// Text helpers

private bool startsWith(string text, string prefix) pure nothrow @nogc
{
    return text.length >= prefix.length && text[0 .. prefix.length] == prefix;
}

private ptrdiff_t indexOf(string text, char ch) pure nothrow @nogc
{
    foreach (index, c; text)
        if (c == ch)
            return index;
    return -1;
}

private ptrdiff_t lastIndexOf(string text, char ch) pure nothrow @nogc
{
    foreach_reverse (index, c; text)
        if (c == ch)
            return index;
    return -1;
}

private ptrdiff_t indexOfText(string text, string needle) pure nothrow @nogc
{
    if (needle.length > text.length)
        return -1;
    foreach (start; 0 .. text.length - needle.length + 1)
        if (text[start .. start + needle.length] == needle)
            return start;
    return -1;
}

private string[] split(string text, char separator)
{
    string[] parts;
    size_t start;
    foreach (index, c; text)
    {
        if (c == separator)
        {
            if (index > start)
                parts ~= text[start .. index];
            start = index + 1;
        }
    }
    if (start < text.length)
        parts ~= text[start .. $];
    return parts;
}

private bool equalsIgnoreCase(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (index; 0 .. a.length)
    {
        char x = a[index], y = b[index];
        if (x >= 'A' && x <= 'Z')
            x += 32;
        if (y >= 'A' && y <= 'Z')
            y += 32;
        if (x != y)
            return false;
    }
    return true;
}

private string upper(string text)
{
    auto result = text.dup;
    foreach (ref c; result)
        if (c >= 'a' && c <= 'z')
            c -= 32;
    return result.idup;
}

private ubyte[] readBytes(ref RequestArena arena, Buffer buffer)
{
    auto result = new ubyte[buffer.length];
    // The visitor is @nogc: it fills a GC buffer allocated beforehand.
    const status = arena.read(buffer, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        result[0 .. bytes.length] = bytes[];
    });
    if (status != Status.ok)
        throw new SQLException("Could not read a value from the statement buffer", "HY000");
    return result;
}

private string readText(ref RequestArena arena, Buffer buffer)
{
    return (cast(const(char)[]) readBytes(arena, buffer)).idup;
}

private string decimal(long value) pure nothrow
{
    if (value == 0)
        return "0";
    char[20] digits;
    size_t start = digits.length;
    const negative = value < 0;
    ulong magnitude = negative ? -(cast(ulong) value) : cast(ulong) value;
    while (magnitude != 0)
    {
        digits[--start] = cast(char)('0' + magnitude % 10);
        magnitude /= 10;
    }
    return (negative ? "-" : "") ~ digits[start .. $].idup;
}

private string floatText(double value)
{
    import flint.engine.aot.text : doubleText;

    return doubleText(value);
}

private long parseLong(string text)
{
    import flint.engine.aot.text : parse = parseLong;

    long[1] value;
    if (!parse(text, value[0]))
        throw new SQLDataException("Cannot convert '" ~ text ~ "' to a number", "22018");
    return value[0];
}

private double parseDouble(string text)
{
    import flint.engine.aot.text : parse = parseDouble;

    double[1] value;
    if (!parse(text, value[0]))
        throw new SQLDataException("Cannot convert '" ~ text ~ "' to a number", "22018");
    return value[0];
}
