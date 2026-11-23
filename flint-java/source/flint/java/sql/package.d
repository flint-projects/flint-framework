/++
`java.sql` as Spring's JDBC support exposes it: the JDBC 4.3 interfaces `JdbcTemplate`, the exception translators and
`DataSourceTransactionManager` are written against (ADR-030, rulebook R1, R4, R8, R10). Written clean-room from the
Java SE 21 API specification.

$(UL
    $(LI Java `Object` parameters and results are `flint.engine.aot.any.Any` (`setObject`, `getObject`).)
    $(LI `Class<T>` tokens are template parameters (R4): `rs.getObject!long(1)`, `connection.unwrap!PGConnection()`.
        `Wrapper` also takes a `TypeInfo_Class` for tokens held in variables.)
    $(LI `SQLException` is checked in Java, so it extends D's `Exception`, not `RuntimeException` (R8). Its JDBC 4
        subclasses classify failures by SQLSTATE class, which Spring's `SQLExceptionSubclassTranslator` reads.)
    $(LI `DriverManager` keeps drivers as supplier functions, because a process-wide registry of driver objects cannot
        be shared in `@safe` D; see `DriverManager.registerDriver`.)
    $(LI The date and time types (`Date`, `Time`, `Timestamp`), LOBs, arrays, `SQLXML`, `RowId` and
        `CallableStatement` arrive with the packages that need them.)
)
+/
module flint.java.sql;

import flint.engine.aot.any : Any;
import flint.java.lang : AutoCloseable, javaToString;
import flint.java.util : Properties;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Exceptions (R8)

/// An exception that provides information on a database access error or other errors: a description, the
/// SQLSTATE, a vendor-specific error code and a chain of further exceptions.
class SQLException : Exception
{
    private string sqlState;
    private int vendorCode;
    private Throwable cause_;
    private SQLException nextException;

    /// A `reason`, the `SQLState`, a `vendorCode` and a `cause`, each optional.
    this(string reason = null, string sqlState = null, int vendorCode = 0, Throwable cause = null,
            string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(reason, file, line);
        this.sqlState = sqlState;
        this.vendorCode = vendorCode;
        this.cause_ = cause;
    }

    /// A `reason` and a `cause`.
    this(string reason, Throwable cause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        this(reason, null, 0, cause, file, line);
    }

    /// A `reason`, the `SQLState` and a `cause`.
    this(string reason, string sqlState, Throwable cause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        this(reason, sqlState, 0, cause, file, line);
    }

    /// The reason is `cause.toString()`, or null.
    this(Throwable cause, string file = __FILE__, size_t line = __LINE__)
    {
        this(cause is null ? null : javaToString(cause), null, 0, cause, file, line);
    }

    /// The detail message; null when there is none.
    string getMessage() const pure nothrow @nogc
    {
        return msg;
    }

    /// The five-character SQLSTATE, or null.
    string getSQLState() const pure nothrow @nogc
    {
        return sqlState;
    }

    /// The vendor-specific error code; zero when none was given.
    int getErrorCode() const pure nothrow @nogc
    {
        return vendorCode;
    }

    /// The cause; null when unknown.
    inout(Throwable) getCause() inout pure nothrow @nogc
    {
        return cause_;
    }

    /// The exception chained to this one by `setNextException`, or null.
    SQLException getNextException() pure nothrow @nogc
    {
        return nextException;
    }

    /// Append `ex` to the end of the chain.
    void setNextException(SQLException ex) pure nothrow @nogc
    {
        SQLException current = this;
        while (current.nextException !is null)
            current = current.nextException;
        current.nextException = ex;
    }

    /// Java's `Throwable.toString()`: the class name, then `: message` when there is one.
    override string toString() const
    {
        const name = typeid(this).name;
        return msg is null ? name : name ~ ": " ~ msg;
    }
}

/// Declares an `SQLException` subclass's constructors, forwarding to its superclass.
private mixin template SQLExceptionConstructors()
{
    /// A `reason`, the `SQLState`, a `vendorCode` and a `cause`, each optional.
    this(string reason = null, string sqlState = null, int vendorCode = 0, Throwable cause = null,
            string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(reason, sqlState, vendorCode, cause, file, line);
    }

    /// A `reason` and a `cause`.
    this(string reason, Throwable cause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(reason, null, 0, cause, file, line);
    }

    /// A `reason`, the `SQLState` and a `cause`.
    this(string reason, string sqlState, Throwable cause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(reason, sqlState, 0, cause, file, line);
    }

    /// The reason is `cause.toString()`, or null.
    this(Throwable cause, string file = __FILE__, size_t line = __LINE__)
    {
        super(cause is null ? null : javaToString(cause), null, 0, cause, file, line);
    }
}

/// A warning on database access. Warnings chain through `getNextWarning`.
class SQLWarning : SQLException
{
    mixin SQLExceptionConstructors;

    /// The warning chained to this one, or null.
    SQLWarning getNextWarning() pure nothrow @nogc
    {
        return cast(SQLWarning) getNextException();
    }

    /// Append `w` to the end of the chain.
    void setNextWarning(SQLWarning w) pure nothrow @nogc
    {
        setNextException(w);
    }
}

/// Thrown when an operation that failed would fail again unless its cause is corrected.
class SQLNonTransientException : SQLException
{
    mixin SQLExceptionConstructors;
}

/// Thrown when an operation that failed might succeed if retried without any change.
class SQLTransientException : SQLException
{
    mixin SQLExceptionConstructors;
}

/// Thrown when an operation might succeed after the application recovers, at least by opening a new connection.
class SQLRecoverableException : SQLException
{
    mixin SQLExceptionConstructors;
}

/// SQLSTATE class 22: a data error, such as an invalid value or a value out of range.
class SQLDataException : SQLNonTransientException
{
    mixin SQLExceptionConstructors;
}

/// SQLSTATE class 0A: the driver or database does not support an optional feature.
class SQLFeatureNotSupportedException : SQLNonTransientException
{
    mixin SQLExceptionConstructors;
}

/// SQLSTATE class 23: an integrity constraint, such as a unique or foreign key, was violated.
class SQLIntegrityConstraintViolationException : SQLNonTransientException
{
    mixin SQLExceptionConstructors;
}

/// SQLSTATE class 28: the authorization credentials were rejected.
class SQLInvalidAuthorizationSpecException : SQLNonTransientException
{
    mixin SQLExceptionConstructors;
}

/// SQLSTATE class 08 for a connection that failed and will fail again without a change.
class SQLNonTransientConnectionException : SQLNonTransientException
{
    mixin SQLExceptionConstructors;
}

/// SQLSTATE class 42: the SQL is invalid or names an object that does not exist.
class SQLSyntaxErrorException : SQLNonTransientException
{
    mixin SQLExceptionConstructors;
}

/// A statement's timeout, set by `setQueryTimeout` or a deadline, expired.
class SQLTimeoutException : SQLTransientException
{
    mixin SQLExceptionConstructors;
}

/// SQLSTATE class 40: the database rolled back the current statement or transaction, as for a deadlock or a
/// serialization failure.
class SQLTransactionRollbackException : SQLTransientException
{
    mixin SQLExceptionConstructors;
}

/// SQLSTATE class 08 for a connection failure that might succeed if retried.
class SQLTransientConnectionException : SQLTransientException
{
    mixin SQLExceptionConstructors;
}

/// Thrown when a command of a batch fails. `getUpdateCounts` holds the counts of the commands that ran.
class BatchUpdateException : SQLException
{
    private long[] counts;

    /// A `reason`, the `SQLState`, a `vendorCode`, the update counts and a `cause`.
    this(string reason, string sqlState, int vendorCode, long[] updateCounts, Throwable cause = null,
            string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(reason, sqlState, vendorCode, cause, file, line);
        counts = updateCounts;
    }

    /// The update counts and a `cause`.
    this(long[] updateCounts, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        this(null, null, 0, updateCounts, cause, file, line);
    }

    /// The update counts of the commands that ran before the failure, as `int`s.
    int[] getUpdateCounts() const pure nothrow
    {
        auto result = new int[counts.length];
        foreach (index, count; counts)
            result[index] = count > int.max ? int.max : cast(int) count;
        return result;
    }

    /// The update counts of the commands that ran before the failure.
    const(long)[] getLargeUpdateCounts() const pure nothrow @nogc
    {
        return counts;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Constants

/// The generic SQL type codes (`java.sql.Types`).
struct Types
{
    @disable this();

    enum int BIT = -7; ///
    enum int TINYINT = -6; ///
    enum int SMALLINT = 5; ///
    enum int INTEGER = 4; ///
    enum int BIGINT = -5; ///
    enum int FLOAT = 6; ///
    enum int REAL = 7; ///
    enum int DOUBLE = 8; ///
    enum int NUMERIC = 2; ///
    enum int DECIMAL = 3; ///
    enum int CHAR = 1; ///
    enum int VARCHAR = 12; ///
    enum int LONGVARCHAR = -1; ///
    enum int DATE = 91; ///
    enum int TIME = 92; ///
    enum int TIMESTAMP = 93; ///
    enum int BINARY = -2; ///
    enum int VARBINARY = -3; ///
    enum int LONGVARBINARY = -4; ///
    enum int NULL = 0; ///
    enum int OTHER = 1111; ///
    enum int JAVA_OBJECT = 2000; ///
    enum int DISTINCT = 2001; ///
    enum int STRUCT = 2002; ///
    enum int ARRAY = 2003; ///
    enum int BLOB = 2004; ///
    enum int CLOB = 2005; ///
    enum int REF = 2006; ///
    enum int DATALINK = 70; ///
    enum int BOOLEAN = 16; ///
    enum int ROWID = -8; ///
    enum int NCHAR = -15; ///
    enum int NVARCHAR = -9; ///
    enum int LONGNVARCHAR = -16; ///
    enum int NCLOB = 2011; ///
    enum int SQLXML = 2009; ///
    enum int REF_CURSOR = 2012; ///
    enum int TIME_WITH_TIMEZONE = 2013; ///
    enum int TIMESTAMP_WITH_TIMEZONE = 2014; ///
}

// ---------------------------------------------------------------------------------------------------------------
// Interfaces

/// Access to a driver's own object behind a JDBC interface.
interface Wrapper
{
    /// The object implementing `iface`: this object, or one it wraps. Throws `SQLException` when there is none.
    Object unwrap(const TypeInfo_Class iface);

    /// Whether this object implements `iface` or wraps one that does.
    bool isWrapperFor(const TypeInfo_Class iface);

    /// `unwrap` with a type parameter (R4).
    T unwrap(T)() if (is(T == class) || is(T == interface))
    {
        static if (is(T == class))
            return cast(T) unwrap(typeid(T));
        else
            return cast(T) unwrap(typeid(T).info);
    }
}

/// A named or numbered point inside a transaction that `Connection.rollback(Savepoint)` returns to.
interface Savepoint
{
    /// The id of an unnamed savepoint. Throws `SQLException` for a named one.
    int getSavepointId();

    /// The name of a named savepoint. Throws `SQLException` for an unnamed one.
    string getSavepointName();
}

/// A session with a database: statements run, and transactions commit or roll back, on a connection.
interface Connection : Wrapper, AutoCloseable
{
    enum int TRANSACTION_NONE = 0; /// Transactions are not supported.
    enum int TRANSACTION_READ_UNCOMMITTED = 1; /// Dirty, non-repeatable and phantom reads can occur.
    enum int TRANSACTION_READ_COMMITTED = 2; /// Dirty reads are prevented.
    enum int TRANSACTION_REPEATABLE_READ = 4; /// Dirty and non-repeatable reads are prevented.
    enum int TRANSACTION_SERIALIZABLE = 8; /// Dirty, non-repeatable and phantom reads are prevented.

    /// A statement for SQL without parameters.
    Statement createStatement();

    /// A precompiled statement with `?` parameters.
    PreparedStatement prepareStatement(string sql);

    /// A precompiled statement whose `getGeneratedKeys` returns generated keys when `autoGeneratedKeys` is
    /// `Statement.RETURN_GENERATED_KEYS`.
    PreparedStatement prepareStatement(string sql, int autoGeneratedKeys);

    /// A precompiled statement whose `getGeneratedKeys` returns the named columns.
    PreparedStatement prepareStatement(string sql, string[] columnNames);

    /// The SQL as the driver would send it.
    string nativeSQL(string sql);

    /// In auto-commit mode each statement is its own transaction; otherwise `commit` or `rollback` ends one.
    void setAutoCommit(bool autoCommit);
    /// ditto
    bool getAutoCommit();

    /// Make the current transaction's changes permanent.
    void commit();

    /// Undo the current transaction's changes.
    void rollback();

    /// Undo the changes made after `savepoint`.
    void rollback(Savepoint savepoint);

    /// Release the connection; a closed connection refuses further work.
    void close();

    /// Whether `close` was called or a fatal error closed the connection.
    bool isClosed();

    /// Information about the database.
    DatabaseMetaData getMetaData();

    /// A hint that the connection only reads, which lets the database optimize.
    void setReadOnly(bool readOnly);
    /// ditto
    bool isReadOnly();

    /// The catalog (database) statements run in.
    void setCatalog(string catalog);
    /// ditto
    string getCatalog();

    /// One of the `TRANSACTION_` levels.
    void setTransactionIsolation(int level);
    /// ditto
    int getTransactionIsolation();

    /// The first warning reported on this connection, or null.
    SQLWarning getWarnings();

    /// Forget the reported warnings.
    void clearWarnings();

    /// An unnamed savepoint in the current transaction.
    Savepoint setSavepoint();

    /// A named savepoint in the current transaction.
    Savepoint setSavepoint(string name);

    /// Remove `savepoint` from the current transaction.
    void releaseSavepoint(Savepoint savepoint);

    /// Whether the connection still works, waiting at most `timeout` seconds; zero means no limit.
    bool isValid(int timeout);

    /// The schema statements resolve unqualified names in.
    void setSchema(string schema);
    /// ditto
    string getSchema();
}

/// Runs SQL and returns its results.
interface Statement : Wrapper, AutoCloseable
{
    enum int CLOSE_CURRENT_RESULT = 1; ///
    enum int KEEP_CURRENT_RESULT = 2; ///
    enum int CLOSE_ALL_RESULTS = 3; ///
    enum int SUCCESS_NO_INFO = -2; /// A batch command succeeded without a row count.
    enum int EXECUTE_FAILED = -3; /// A batch command failed.
    enum int RETURN_GENERATED_KEYS = 1; ///
    enum int NO_GENERATED_KEYS = 2; ///

    /// Run a query and return its rows.
    ResultSet executeQuery(string sql);

    /// Run an `INSERT`, `UPDATE`, `DELETE` or DDL statement and return the row count, or zero.
    int executeUpdate(string sql);
    /// ditto
    long executeLargeUpdate(string sql);

    /// Run `sql`; true when the first result is a `ResultSet`, false for an update count or no result.
    bool execute(string sql);

    /// The current result as rows, or null.
    ResultSet getResultSet();

    /// The current result as a row count, or -1.
    int getUpdateCount();
    /// ditto
    long getLargeUpdateCount();

    /// Move to the next result; true when it is a `ResultSet`.
    bool getMoreResults();

    /// The most rows a `ResultSet` holds; zero means no limit.
    void setMaxRows(int max);
    /// ditto
    int getMaxRows();

    /// A hint for how many rows to fetch at once.
    void setFetchSize(int rows);
    /// ditto
    int getFetchSize();

    /// The seconds a statement may run; zero means no limit.
    void setQueryTimeout(int seconds);
    /// ditto
    int getQueryTimeout();

    /// Cancel the running statement from another thread or fiber.
    void cancel();

    /// The first warning reported on this statement, or null.
    SQLWarning getWarnings();
    /// Forget the reported warnings.
    void clearWarnings();

    /// Add a command to the batch.
    void addBatch(string sql);
    /// Empty the batch.
    void clearBatch();

    /// Run the batch; each element is a row count, `SUCCESS_NO_INFO` or `EXECUTE_FAILED`.
    int[] executeBatch();
    /// ditto
    long[] executeLargeBatch();

    /// The connection that created this statement.
    Connection getConnection();

    /// The keys the last statement generated, as rows.
    ResultSet getGeneratedKeys();

    /// Release the statement and its current `ResultSet`.
    void close();

    /// Whether `close` was called.
    bool isClosed();
}

/// A precompiled statement with `?` parameters, numbered from 1.
interface PreparedStatement : Statement
{
    /// Run the query and return its rows.
    ResultSet executeQuery();

    /// Run the update and return its row count, or zero.
    int executeUpdate();
    /// ditto
    long executeLargeUpdate();

    /// Run the statement; true when the first result is a `ResultSet`.
    bool execute();

    /// Add the current parameter values to the batch.
    void addBatch();

    /// Forget the current parameter values.
    void clearParameters();

    /// Bind SQL `NULL` of the `Types` code `sqlType`.
    void setNull(int parameterIndex, int sqlType);
    /// ditto, with the database's type name for user-defined and reference types.
    void setNull(int parameterIndex, int sqlType, string typeName);

    /// JDBC's `setBoolean`.
    void setBoolean(int parameterIndex, bool x);
    /// JDBC's `setByte`.
    void setByte(int parameterIndex, byte x);
    /// JDBC's `setShort`.
    void setShort(int parameterIndex, short x);
    /// JDBC's `setInt`.
    void setInt(int parameterIndex, int x);
    /// JDBC's `setLong`.
    void setLong(int parameterIndex, long x);
    /// JDBC's `setFloat`.
    void setFloat(int parameterIndex, float x);
    /// JDBC's `setDouble`.
    void setDouble(int parameterIndex, double x);
    /// JDBC's `setString`.
    void setString(int parameterIndex, string x);
    /// JDBC's `setBytes`.
    void setBytes(int parameterIndex, const(ubyte)[] x);

    /// Bind any supported value; a null `Any` binds SQL `NULL`.
    void setObject(int parameterIndex, Any x);
    /// ditto, converted to the `Types` code `targetSqlType`.
    void setObject(int parameterIndex, Any x, int targetSqlType);

    /// The columns the query returns, or null when the driver cannot tell before running it.
    ResultSetMetaData getMetaData();

    /// The number and types of the parameters.
    ParameterMetaData getParameterMetaData();
}

/// The rows of a query, read with a cursor that starts before the first row.
interface ResultSet : Wrapper, AutoCloseable
{
    enum int FETCH_FORWARD = 1000; ///
    enum int FETCH_REVERSE = 1001; ///
    enum int FETCH_UNKNOWN = 1002; ///
    enum int TYPE_FORWARD_ONLY = 1003; ///
    enum int TYPE_SCROLL_INSENSITIVE = 1004; ///
    enum int TYPE_SCROLL_SENSITIVE = 1005; ///
    enum int CONCUR_READ_ONLY = 1007; ///
    enum int CONCUR_UPDATABLE = 1008; ///
    enum int HOLD_CURSORS_OVER_COMMIT = 1; ///
    enum int CLOSE_CURSORS_AT_COMMIT = 2; ///

    /// Move to the next row; false after the last one.
    bool next();

    /// Release the rows.
    void close();

    /// Whether the last column read was SQL `NULL`.
    bool wasNull();

    /// JDBC's `getString`.
    string getString(int columnIndex);
    /// JDBC's `getBoolean`.
    bool getBoolean(int columnIndex);
    /// JDBC's `getByte`.
    byte getByte(int columnIndex);
    /// JDBC's `getShort`.
    short getShort(int columnIndex);
    /// JDBC's `getInt`.
    int getInt(int columnIndex);
    /// JDBC's `getLong`.
    long getLong(int columnIndex);
    /// JDBC's `getFloat`.
    float getFloat(int columnIndex);
    /// JDBC's `getDouble`.
    double getDouble(int columnIndex);
    /// JDBC's `getBytes`.
    ubyte[] getBytes(int columnIndex);
    /// The value as the driver's natural type; null `Any` for SQL `NULL`.
    Any getObject(int columnIndex);

    /// JDBC's `getString`.
    string getString(string columnLabel);
    /// JDBC's `getBoolean`.
    bool getBoolean(string columnLabel);
    /// JDBC's `getByte`.
    byte getByte(string columnLabel);
    /// JDBC's `getShort`.
    short getShort(string columnLabel);
    /// JDBC's `getInt`.
    int getInt(string columnLabel);
    /// JDBC's `getLong`.
    long getLong(string columnLabel);
    /// JDBC's `getFloat`.
    float getFloat(string columnLabel);
    /// JDBC's `getDouble`.
    double getDouble(string columnLabel);
    /// JDBC's `getBytes`.
    ubyte[] getBytes(string columnLabel);
    /// JDBC's `getObject`.
    Any getObject(string columnLabel);

    /// The value converted to `T` (R4: Java's `getObject(int, Class<T>)`).
    T getObject(T)(int columnIndex)
    {
        auto value = getObject(columnIndex);
        static if (is(T == class) || is(T == interface) || is(T : const(char)[]) || is(T : const(ubyte)[]))
        {
            if (value.isNull)
                return T.init;
        }
        else static if (is(T == struct) && __traits(compiles, T.parse("")))
        {
            // Java's java.time types: a null column is T.init (Java's null), and the driver's ISO text is parsed,
            // as JDBC 4.2 drivers convert DATE, TIME and TIMESTAMP columns.
            if (value.isNull)
                return T.init;
            if (!value.holds!T && value.holds!string)
                return T.parse(value.get!string);
        }
        return value.get!T;
    }

    /// The value of the column labelled `columnLabel` converted to `T` (R4).
    T getObject(T)(string columnLabel)
    {
        return getObject!T(findColumn(columnLabel));
    }

    /// The 1-based index of the column labelled `columnLabel`, matched without regard to case.
    int findColumn(string columnLabel);

    /// The columns' number, types and properties.
    ResultSetMetaData getMetaData();

    /// The 1-based number of the current row, or zero.
    int getRow();

    /// Whether `close` was called.
    bool isClosed();

    /// The statement that produced the rows, or null.
    Statement getStatement();

    /// The first warning reported on these rows, or null.
    SQLWarning getWarnings();
    /// Forget the reported warnings.
    void clearWarnings();

    /// `TYPE_FORWARD_ONLY`, `TYPE_SCROLL_INSENSITIVE` or `TYPE_SCROLL_SENSITIVE`.
    int getType();

    /// `CONCUR_READ_ONLY` or `CONCUR_UPDATABLE`.
    int getConcurrency();
}

/// The number, types and properties of a `ResultSet`'s columns, numbered from 1.
interface ResultSetMetaData : Wrapper
{
    enum int columnNoNulls = 0; ///
    enum int columnNullable = 1; ///
    enum int columnNullableUnknown = 2; ///

    /// JDBC's `getColumnCount`.
    int getColumnCount();
    /// The column's name.
    string getColumnName(int column);
    /// The `AS` alias, or the name.
    string getColumnLabel(int column);
    /// The `Types` code.
    int getColumnType(int column);
    /// The database's type name.
    string getColumnTypeName(int column);
    /// The D type `getObject` returns.
    string getColumnClassName(int column);
    /// JDBC's `isNullable`.
    int isNullable(int column);
    /// JDBC's `getTableName`.
    string getTableName(int column);
    /// JDBC's `getSchemaName`.
    string getSchemaName(int column);
    /// JDBC's `getCatalogName`.
    string getCatalogName(int column);
    /// JDBC's `getPrecision`.
    int getPrecision(int column);
    /// JDBC's `getScale`.
    int getScale(int column);
    /// JDBC's `isAutoIncrement`.
    bool isAutoIncrement(int column);
}

/// The number and types of a `PreparedStatement`'s parameters, numbered from 1.
interface ParameterMetaData : Wrapper
{
    enum int parameterNoNulls = 0; ///
    enum int parameterNullable = 1; ///
    enum int parameterNullableUnknown = 2; ///

    /// JDBC's `getParameterCount`.
    int getParameterCount();
    /// The `Types` code.
    int getParameterType(int param);
    /// JDBC's `getParameterTypeName`.
    string getParameterTypeName(int param);
    /// JDBC's `isNullable`.
    int isNullable(int param);
}

/// Information about the database behind a connection.
interface DatabaseMetaData : Wrapper
{
    /// JDBC's `getURL`.
    string getURL();
    /// JDBC's `getUserName`.
    string getUserName();
    /// JDBC's `getDatabaseProductName`.
    string getDatabaseProductName();
    /// JDBC's `getDatabaseProductVersion`.
    string getDatabaseProductVersion();
    /// JDBC's `getDatabaseMajorVersion`.
    int getDatabaseMajorVersion();
    /// JDBC's `getDatabaseMinorVersion`.
    int getDatabaseMinorVersion();
    /// JDBC's `getDriverName`.
    string getDriverName();
    /// JDBC's `getDriverVersion`.
    string getDriverVersion();
    /// JDBC's `getJDBCMajorVersion`.
    int getJDBCMajorVersion();
    /// JDBC's `getJDBCMinorVersion`.
    int getJDBCMinorVersion();
    /// JDBC's `getIdentifierQuoteString`.
    string getIdentifierQuoteString();
    /// JDBC's `storesUpperCaseIdentifiers`.
    bool storesUpperCaseIdentifiers();
    /// JDBC's `storesLowerCaseIdentifiers`.
    bool storesLowerCaseIdentifiers();
    /// JDBC's `storesMixedCaseIdentifiers`.
    bool storesMixedCaseIdentifiers();
    /// JDBC's `supportsBatchUpdates`.
    bool supportsBatchUpdates();
    /// JDBC's `supportsSavepoints`.
    bool supportsSavepoints();
    /// JDBC's `supportsGetGeneratedKeys`.
    bool supportsGetGeneratedKeys();
    /// JDBC's `supportsTransactions`.
    bool supportsTransactions();
    /// JDBC's `supportsTransactionIsolationLevel`.
    bool supportsTransactionIsolationLevel(int level);
    /// JDBC's `supportsResultSetType`.
    bool supportsResultSetType(int type);
    /// JDBC's `getDefaultTransactionIsolation`.
    int getDefaultTransactionIsolation();

    /++
    The tables matching the given catalog, schema and table name patterns (`%` and `_` wildcards; null matches
    any), and whose type is one of `types` (null for all). Each row has JDBC's columns `TABLE_CAT`, `TABLE_SCHEM`,
    `TABLE_NAME`, `TABLE_TYPE` and `REMARKS`.
    +/
    ResultSet getTables(string catalog, string schemaPattern, string tableNamePattern, string[] types);

    /++
    The columns matching the given patterns, in table and ordinal order. Each row has JDBC's columns `TABLE_CAT`,
    `TABLE_SCHEM`, `TABLE_NAME`, `COLUMN_NAME`, `DATA_TYPE` (a `Types` constant), `TYPE_NAME`, `COLUMN_SIZE`,
    `DECIMAL_DIGITS`, `NULLABLE`, `ORDINAL_POSITION` and `IS_NULLABLE`.
    +/
    ResultSet getColumns(string catalog, string schemaPattern, string tableNamePattern, string columnNamePattern);
    /// JDBC's `getConnection`.
    Connection getConnection();
}

/// A database driver: it recognizes its URLs and opens connections for them.
interface Driver
{
    /// A connection for `url`, or null when the URL belongs to another driver. `info` holds the connection
    /// properties, such as `user` and `password`; it may be null.
    Connection connect(string url, Properties info);

    /// Whether this driver opens connections for `url`.
    bool acceptsURL(string url);

    /// JDBC's `getMajorVersion`.
    int getMajorVersion();
    /// JDBC's `getMinorVersion`.
    int getMinorVersion();

    /// Whether the driver passes the JDBC compliance tests.
    bool jdbcCompliant();
}

/// Supplies the driver a `DriverManager` registration names; see `DriverManager.registerDriver`.
alias DriverSupplier = Driver function() @safe;

private shared DriverSupplier[] registeredDrivers;

/// The drivers a program registered, and connections by URL.
struct DriverManager
{
    @disable this();

    /++
    Register a driver. Java registers a `Driver` object; Flint registers a function returning the driver, because a
    process-wide list of objects cannot be shared between threads in `@safe` D while function pointers can. A
    driver calls this from its module's `shared static this()`. Registering the same supplier twice keeps one entry.
    +/
    static void registerDriver(DriverSupplier supplier)
    {
        if (supplier is null)
            throw new SQLException("The driver supplier must not be null", "HY009");
        synchronized
        {
            foreach (shared registered; registeredDrivers)
                if (registered is supplier)
                    return;
            registeredDrivers = registeredDrivers ~ supplier;
        }
    }

    /// Remove a registration.
    static void deregisterDriver(DriverSupplier supplier)
    {
        synchronized
        {
            shared(DriverSupplier)[] kept;
            foreach (shared registered; registeredDrivers)
                if (registered !is supplier)
                    kept ~= registered;
            registeredDrivers = kept;
        }
    }

    /// The registered drivers, in registration order.
    static Driver[] getDrivers()
    {
        Driver[] result;
        foreach (supplier; snapshot())
            result ~= supplier();
        return result;
    }

    /// The first registered driver that accepts `url`. Throws `SQLException` (SQLSTATE 08001) when none does.
    static Driver getDriver(string url)
    {
        foreach (supplier; snapshot())
        {
            auto driver = supplier();
            if (driver.acceptsURL(url))
                return driver;
        }
        throw new SQLException("No suitable driver", "08001");
    }

    /// A connection from the first registered driver that accepts `url`.
    static Connection getConnection(string url)
    {
        return getConnection(url, cast(Properties) null);
    }

    /// A connection from the first registered driver that accepts `url`, as `user` with `password`.
    static Connection getConnection(string url, string user, string password)
    {
        auto info = new Properties;
        if (user !is null)
            info.setProperty("user", user);
        if (password !is null)
            info.setProperty("password", password);
        return getConnection(url, info);
    }

    /// A connection from the first registered driver that accepts `url`, with the connection properties `info`.
    static Connection getConnection(string url, Properties info)
    {
        if (url is null)
            throw new SQLException("The url cannot be null", "08001");
        SQLException reason;
        foreach (supplier; snapshot())
        {
            try
            {
                auto connection = supplier().connect(url, info);
                if (connection !is null)
                    return connection;
            }
            catch (SQLException ex)
            {
                if (reason is null)
                    reason = ex;
            }
        }
        if (reason !is null)
            throw reason;
        throw new SQLException("No suitable driver found for " ~ url, "08001");
    }

    private static DriverSupplier[] snapshot()
    {
        DriverSupplier[] result;
        synchronized
        {
            foreach (shared registered; registeredDrivers)
            {
                DriverSupplier supplier = registered;
                result ~= supplier;
            }
        }
        return result;
    }
}
