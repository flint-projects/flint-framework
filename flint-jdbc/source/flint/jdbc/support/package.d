// Ported from spring-framework v7.1.0: spring-jdbc/src/main/java/org/springframework/jdbc/support/SQLExceptionTranslator.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: AbstractFallbackSQLExceptionTranslator.java, SQLExceptionSubclassTranslator.java,
// SQLStateSQLExceptionTranslator.java, JdbcTransactionManager.java, JdbcAccessor.java, JdbcUtils.java,
// KeyHolder.java and GeneratedKeyHolder.java.

/++
`org.springframework.jdbc.support`: the translation of `SQLException`s into Spring's `DataAccessException`
hierarchy. `SQLExceptionSubclassTranslator` reads the JDBC 4 subclass the Flint driver throws and falls back to
`SQLStateSQLExceptionTranslator`, which reads the SQLSTATE class (ADR-030). `JdbcTransactionManager` is the
`DataSourceTransactionManager` that translates commit and rollback failures with them. `JdbcAccessor` is the base of
`JdbcTemplate`; `JdbcUtils` closes resources and reads column values; `KeyHolder` collects generated keys. The
error-code translator, which reads `sql-error-codes.xml`, is not ported: Flint ships no error-code files.
+/
module flint.jdbc.support;

import flint.dao : CannotAcquireLockException, DataAccessException,
    DataAccessResourceFailureException,
    DataIntegrityViolationException, DuplicateKeyException, InvalidDataAccessApiUsageException,
    PermissionDeniedDataAccessException,
    PessimisticLockingFailureException,
    QueryTimeoutException, RecoverableDataAccessException,
    TransientDataAccessResourceException, DataRetrievalFailureException;
import flint.beans.factory : InitializingBean;
import flint.engine.aot.any : Any;
import flint.java.lang : IllegalArgumentException, RuntimeException;
import flint.java.util : ArrayList, List, Map;
import flint.java.sql : BatchUpdateException, Connection, ResultSet, ResultSetMetaData, Statement,
    Types, SQLDataException, SQLException,
    SQLFeatureNotSupportedException,
    SQLIntegrityConstraintViolationException,
    SQLInvalidAuthorizationSpecException,
    SQLNonTransientConnectionException, SQLNonTransientException, SQLRecoverableException, SQLSyntaxErrorException,
    SQLTimeoutException, SQLTransactionRollbackException, SQLTransientConnectionException, SQLTransientException;
import flint.javax.sql : DataSource;
import flint.jdbc : BadSqlGrammarException, orNull;
import flint.jdbc.datasource : DataSourceTransactionManager;
import flint.slf4j : Logger, LoggerFactory;

@safe:

/++
Strategy interface for translating between `SQLException`s and Spring's data access strategy-agnostic
`DataAccessException` hierarchy. Implementations can be generic (for example, using SQLState codes for JDBC) or wholly
proprietary (for example, using Oracle error codes) for greater precision.
+/
interface SQLExceptionTranslator
{
    /// Translate the given `SQLException` into a generic `DataAccessException`, or return null if not able to
    /// translate (letting other translators have a go). `task` describes the attempted operation and `sql` is the
    /// SQL that caused the problem, if known.
    DataAccessException translate(string task, string sql, SQLException ex);
}

/// Base class for `SQLExceptionTranslator` implementations that allow for a fallback to some other
/// `SQLExceptionTranslator`, as well as for custom overrides.
abstract class AbstractFallbackSQLExceptionTranslator : SQLExceptionTranslator
{
    /// Logger available to subclasses.
    protected Logger logger;

    private SQLExceptionTranslator fallbackTranslator;
    private SQLExceptionTranslator customTranslator;

    ///
    this()
    {
        logger = LoggerFactory.getLogger(typeid(this).name);
    }

    /// Set the fallback translator to use when this translator cannot find a specific match itself.
    void setFallbackTranslator(SQLExceptionTranslator fallback)
    {
        fallbackTranslator = fallback;
    }

    /// Return the fallback exception translator, if any.
    SQLExceptionTranslator getFallbackTranslator()
    {
        return fallbackTranslator;
    }

    /// Set a custom exception translator to override any match that this translator would find.
    void setCustomTranslator(SQLExceptionTranslator customTranslator)
    {
        this.customTranslator = customTranslator;
    }

    /// Return a custom exception translator, if any.
    SQLExceptionTranslator getCustomTranslator()
    {
        return customTranslator;
    }

    /// Pre-checks the arguments, calls `doTranslate`, and invokes the fallback translator if necessary.
    override DataAccessException translate(string task, string sql, SQLException ex)
    {
        if (ex is null)
            throw new IllegalArgumentException("Cannot translate a null SQLException");
        if (auto custom = getCustomTranslator())
        {
            if (auto dae = custom.translate(task, sql, ex))
                return dae; // Custom exception match found.
        }
        if (auto dae = doTranslate(task, sql, ex))
            return dae; // Specific exception match found.
        // Looking for a fallback...
        if (auto fallback = getFallbackTranslator())
            return fallback.translate(task, sql, ex);
        return null;
    }

    /// Template method for actually translating the given exception. Return null if no match.
    protected abstract DataAccessException doTranslate(string task, string sql, SQLException ex);

    /// Build a message `String` for the given `SQLException`.
    protected string buildMessage(string task, string sql, SQLException ex)
    {
        return task ~ "; " ~ (sql !is null ? "SQL [" ~ sql ~ "]; " : "") ~ orNull(ex.getMessage());
    }
}

/++
`SQLExceptionTranslator` implementation which analyzes the specific `SQLException` subclass thrown by the JDBC driver.
Falls back to a standard `SQLStateSQLExceptionTranslator` if the JDBC driver does not actually expose JDBC 4
compliant `SQLException` subclasses.
+/
class SQLExceptionSubclassTranslator : AbstractFallbackSQLExceptionTranslator
{
    ///
    this()
    {
        setFallbackTranslator(new SQLStateSQLExceptionTranslator);
    }

    override protected DataAccessException doTranslate(string task, string sql, SQLException ex)
    {
        SQLException sqlEx = ex;
        if (cast(BatchUpdateException) sqlEx !is null && sqlEx.getNextException() !is null)
            sqlEx = sqlEx.getNextException();
        if (cast(SQLTransientException) sqlEx !is null)
            return translateTransient(task, sql, sqlEx, ex);
        if (cast(SQLNonTransientException) sqlEx !is null)
            return translateNonTransient(task, sql, sqlEx, ex);
        if (cast(SQLRecoverableException) sqlEx !is null)
            return new RecoverableDataAccessException(buildMessage(task, sql, sqlEx), ex);
        // Fallback to Spring's own SQL state translation...
        return null;
    }

    private DataAccessException translateTransient(string task, string sql, SQLException sqlEx, SQLException ex)
    {
        if (cast(SQLTransientConnectionException) sqlEx !is null)
            return new TransientDataAccessResourceException(buildMessage(task, sql, sqlEx), ex);
        if (cast(SQLTransactionRollbackException) sqlEx !is null)
        {
            if (SQLStateSQLExceptionTranslator.indicatesCannotAcquireLock(sqlEx.getSQLState()))
                return new CannotAcquireLockException(buildMessage(task, sql, sqlEx), ex);
            return new PessimisticLockingFailureException(buildMessage(task, sql, sqlEx), ex);
        }
        if (cast(SQLTimeoutException) sqlEx !is null)
            return new QueryTimeoutException(buildMessage(task, sql, sqlEx), ex);
        return null;
    }

    private DataAccessException translateNonTransient(string task, string sql, SQLException sqlEx, SQLException ex)
    {
        if (cast(SQLNonTransientConnectionException) sqlEx !is null)
            return new DataAccessResourceFailureException(buildMessage(task, sql, sqlEx), ex);
        if (cast(SQLDataException) sqlEx !is null)
            return new DataIntegrityViolationException(buildMessage(task, sql, sqlEx), ex);
        if (cast(SQLIntegrityConstraintViolationException) sqlEx !is null)
        {
            if (SQLStateSQLExceptionTranslator.indicatesDuplicateKey(sqlEx.getSQLState(), sqlEx.getErrorCode()))
                return new DuplicateKeyException(buildMessage(task, sql, sqlEx), ex);
            return new DataIntegrityViolationException(buildMessage(task, sql, sqlEx), ex);
        }
        if (cast(SQLInvalidAuthorizationSpecException) sqlEx !is null)
            return new PermissionDeniedDataAccessException(buildMessage(task, sql, sqlEx), ex);
        if (cast(SQLSyntaxErrorException) sqlEx !is null)
            return new BadSqlGrammarException(task, sql !is null ? sql : "", ex);
        if (cast(SQLFeatureNotSupportedException) sqlEx !is null)
            return new InvalidDataAccessApiUsageException(buildMessage(task, sql, sqlEx), ex);
        return null;
    }
}

/++
`SQLExceptionTranslator` implementation that analyzes the SQL state in the `SQLException` based on the first two
digits (the SQL state "class"). Detects standard SQL state values and well-known vendor-specific SQL states.
+/
class SQLStateSQLExceptionTranslator : AbstractFallbackSQLExceptionTranslator
{
    private static immutable string[] badSqlGrammarCodes = [
        "07", // Dynamic SQL error
        "21", // Cardinality violation
        "2A", // Syntax error direct SQL
        "37", // Syntax error dynamic SQL
        "42", // General SQL syntax error
        "65", // Oracle: unknown identifier
    ];
    private static immutable string[] dataIntegrityViolationCodes = [
        "01", // Data truncation
        "02", // No data found
        "22", // Value out of range
        "23", // Integrity constraint violation
        "27", // Triggered data change violation
        "44", // With check violation
    ];
    private static immutable string[] pessimisticLockingFailureCodes = [
        "40", // Transaction rollback
        "61", // Oracle: deadlock
    ];
    private static immutable string[] dataAccessResourceFailureCodes = [
        "08", // Connection exception
        "53", // PostgreSQL: insufficient resources (for example, disk full)
        "54", // PostgreSQL: program limit exceeded (for example, statement too complex)
        "57", // DB2: out-of-memory exception / database not started
        "58", // DB2: unexpected system error
    ];
    private static immutable string[] transientDataAccessResourceCodes = [
        "JW", // Sybase: internal I/O error
        "JZ", // Sybase: unexpected I/O error
        "S1", // DB2: communication failure
    ];
    private static immutable int[] duplicateKeyErrorCodes = [
        1, // Oracle
        301, // SAP HANA
        1062, // MySQL/MariaDB
        2601, // MS SQL Server
        2627, // MS SQL Server
        -239, // Informix
        -268, // Informix
    ];

    override protected DataAccessException doTranslate(string task, string sql, SQLException ex)
    {
        SQLException sqlEx = ex;
        string sqlState;
        if (cast(BatchUpdateException) sqlEx !is null)
        {
            // Unwrap BatchUpdateException to expose contained exception with potentially more specific SQL state.
            auto nestedSqlEx = sqlEx.getNextException();
            if (nestedSqlEx !is null && nestedSqlEx.getSQLState() !is null)
                sqlEx = nestedSqlEx;
            sqlState = sqlEx.getSQLState();
        }
        else
        {
            // Expose top-level exception but potentially use nested SQL state.
            sqlState = getSqlState(sqlEx);
        }
        // The actual SQL state check...
        if (sqlState !is null && sqlState.length >= 2)
        {
            auto translated = translateClass(task, sql, sqlEx, ex, sqlState);
            if (translated !is null)
                return translated;
        }
        // For MySQL: exception class name indicating a timeout? (since MySQL doesn't throw the JDBC 4
        // SQLTimeoutException)
        if (contains(typeid(sqlEx).name, "Timeout"))
            return new QueryTimeoutException(buildMessage(task, sql, sqlEx), ex);
        // Couldn't resolve anything proper - resort to UncategorizedSQLException.
        return null;
    }

    private DataAccessException translateClass(string task, string sql, SQLException sqlEx,
            SQLException ex, string sqlState)
    {
        const classCode = sqlState[0 .. 2];
        if (logger.isDebugEnabled())
            logger.debug_("Extracted SQL state class '" ~ classCode ~ "' from value '" ~ sqlState ~ "'");
        if (among(badSqlGrammarCodes, classCode))
            return new BadSqlGrammarException(task, sql !is null ? sql : "", ex);
        if (among(dataIntegrityViolationCodes, classCode))
        {
            if (indicatesDuplicateKey(sqlState, sqlEx.getErrorCode()))
                return new DuplicateKeyException(buildMessage(task, sql, sqlEx), ex);
            return new DataIntegrityViolationException(buildMessage(task, sql, sqlEx), ex);
        }
        if (among(pessimisticLockingFailureCodes, classCode))
        {
            if (indicatesCannotAcquireLock(sqlState))
                return new CannotAcquireLockException(buildMessage(task, sql, sqlEx), ex);
            return new PessimisticLockingFailureException(buildMessage(task, sql, sqlEx), ex);
        }
        if (among(dataAccessResourceFailureCodes, classCode))
        {
            if (indicatesQueryTimeout(sqlState))
                return new QueryTimeoutException(buildMessage(task, sql, sqlEx), ex);
            return new DataAccessResourceFailureException(buildMessage(task, sql, sqlEx), ex);
        }
        if (among(transientDataAccessResourceCodes, classCode))
            return new TransientDataAccessResourceException(buildMessage(task, sql, sqlEx), ex);
        return null;
    }

    private string getSqlState(SQLException ex)
    {
        string sqlState = ex.getSQLState();
        if (sqlState is null)
        {
            if (auto nestedEx = ex.getNextException())
                sqlState = nestedEx.getSQLState();
        }
        return sqlState;
    }

    package(flint.jdbc) static bool indicatesDuplicateKey(string sqlState, int errorCode) pure nothrow @nogc
    {
        if (sqlState == "23505")
            return true;
        if (sqlState != "23000")
            return false;
        foreach (code; duplicateKeyErrorCodes)
            if (code == errorCode)
                return true;
        return false;
    }

    package(flint.jdbc) static bool indicatesCannotAcquireLock(string sqlState) pure nothrow @nogc
    {
        return sqlState == "40001";
    }

    package(flint.jdbc) static bool indicatesQueryTimeout(string sqlState) pure nothrow @nogc
    {
        return sqlState == "57014";
    }
}

private bool among(scope const(string)[] codes, scope const(char)[] code) pure nothrow @nogc
{
    foreach (candidate; codes)
        if (candidate == code)
            return true;
    return false;
}

private bool contains(string haystack, string needle) pure nothrow @nogc
{
    if (needle.length > haystack.length)
        return false;
    foreach (start; 0 .. haystack.length - needle.length + 1)
        if (haystack[start .. start + needle.length] == needle)
            return true;
    return false;
}

/++
`JdbcAccessor`-aligned subclass of the plain `DataSourceTransactionManager`, adding common JDBC exception translation
for the commit and rollback step. Functionally equivalent otherwise.

Flint has no `sql-error-codes.xml`, so the translator is always `SQLExceptionSubclassTranslator`, which falls back to
the SQLSTATE translator; `setDatabaseProductName` keeps the configuration surface.
+/
class JdbcTransactionManager : DataSourceTransactionManager
{
    private SQLExceptionTranslator exceptionTranslator;
    private bool lazyInit = true;

    /// Create a new `JdbcTransactionManager` instance. A `DataSource` has to be set to be able to use it.
    this()
    {
    }

    /// Create a new `JdbcTransactionManager` instance for the given `DataSource`.
    this(DataSource dataSource)
    {
        // Java's setDataSource and afterPropertiesSet; lazyInit is true here, so nothing else initializes.
        super(dataSource);
    }

    /// Specify the database product name for the `DataSource` that this transaction manager operates on. Without
    /// an error codes file, this selects `SQLExceptionSubclassTranslator`.
    void setDatabaseProductName(string)
    {
        exceptionTranslator = new SQLExceptionSubclassTranslator;
    }

    /// Set the exception translator for this transaction manager.
    void setExceptionTranslator(SQLExceptionTranslator exceptionTranslator)
    {
        this.exceptionTranslator = exceptionTranslator;
    }

    /// Return the exception translator to use for this instance, creating a default if necessary.
    SQLExceptionTranslator getExceptionTranslator()
    {
        synchronized (this)
        {
            if (exceptionTranslator is null)
                exceptionTranslator = new SQLExceptionSubclassTranslator;
            return exceptionTranslator;
        }
    }

    /// Set whether to lazily initialize the `SQLExceptionTranslator` for this transaction manager, on first
    /// encounter of an `SQLException`. Default is true; can be switched to false for initialization on startup.
    void setLazyInit(bool lazyInit)
    {
        this.lazyInit = lazyInit;
    }

    /// Return whether to lazily initialize the `SQLExceptionTranslator` for this transaction manager.
    bool isLazyInit()
    {
        return lazyInit;
    }

    /// Eagerly initialize the exception translator, if demanded, creating a default one for the specified
    /// `DataSource` if none set.
    override void afterPropertiesSet()
    {
        super.afterPropertiesSet();
        if (!isLazyInit())
            getExceptionTranslator();
    }

    /// This implementation attempts to use the `SQLExceptionTranslator`, falling back to a
    /// `TransactionSystemException`.
    protected override RuntimeException translateException(string task, SQLException ex)
    {
        auto dae = getExceptionTranslator().translate(task, null, ex);
        if (dae !is null)
            return dae;
        return super.translateException(task, ex);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// JdbcAccessor

/++
Base class for `JdbcTemplate` and other JDBC-accessing DAO helpers, defining common properties such as the
`DataSource` and the exception translator. Not intended to be used directly.
+/
abstract class JdbcAccessor : InitializingBean
{
    /// Logger available to subclasses.
    protected Logger logger;

    private DataSource dataSource;
    private SQLExceptionTranslator exceptionTranslator;
    private bool lazyInit = true;

    ///
    this()
    {
        logger = LoggerFactory.getLogger(typeid(this).name);
    }

    /// Set the JDBC `DataSource` to obtain connections from.
    void setDataSource(DataSource dataSource)
    {
        this.dataSource = dataSource;
    }

    /// Return the `DataSource` used by this template.
    DataSource getDataSource()
    {
        return dataSource;
    }

    /// Obtain the `DataSource` for actual use; throws `IllegalStateException` when none is set.
    protected DataSource obtainDataSource()
    {
        auto source = getDataSource();
        if (source is null)
            throw new IllegalStateExceptionShim("No DataSource set");
        return source;
    }

    /// Specify the database product name for the `DataSource` that this accessor uses. Without an error codes file,
    /// this selects `SQLExceptionSubclassTranslator`.
    void setDatabaseProductName(string)
    {
        exceptionTranslator = new SQLExceptionSubclassTranslator;
    }

    /// Set the exception translator for this instance.
    void setExceptionTranslator(SQLExceptionTranslator exceptionTranslator)
    {
        this.exceptionTranslator = exceptionTranslator;
    }

    /// Return the exception translator to use for this instance, creating a default if necessary.
    SQLExceptionTranslator getExceptionTranslator()
    {
        synchronized (this)
        {
            if (exceptionTranslator is null)
                exceptionTranslator = new SQLExceptionSubclassTranslator;
            return exceptionTranslator;
        }
    }

    /// Set whether to lazily initialize the `SQLExceptionTranslator` for this accessor, on first encounter of an
    /// `SQLException`. Default is true; can be switched to false for initialization on startup.
    void setLazyInit(bool lazyInit)
    {
        this.lazyInit = lazyInit;
    }

    /// Return whether to lazily initialize the `SQLExceptionTranslator` for this accessor.
    bool isLazyInit()
    {
        return lazyInit;
    }

    /// Eagerly initialize the exception translator, if demanded.
    override void afterPropertiesSet()
    {
        if (getDataSource() is null)
            throw new IllegalArgumentException("Property 'dataSource' is required");
        if (!isLazyInit())
            getExceptionTranslator();
    }
}

private alias IllegalStateExceptionShim = imported!"flint.java.lang".IllegalStateException;

// ---------------------------------------------------------------------------------------------------------------
// JdbcUtils

/// Generic utility methods for working with JDBC. Mainly for internal use within the framework, but also useful for
/// custom JDBC access code.
abstract class JdbcUtils
{
    /// Constant that indicates an unknown (or unspecified) SQL type.
    enum int TYPE_UNKNOWN = int.min;

    private static Logger logger()
    {
        return LoggerFactory.getLogger("org.springframework.jdbc.support.JdbcUtils");
    }

    /// Close the given JDBC `Connection` and ignore any thrown exception.
    static void closeConnection(Connection con)
    {
        if (con is null)
            return;
        try
            con.close();
        catch (SQLException ex)
            logger().debug_("Could not close JDBC Connection", ex);
        catch (Exception ex)
            logger().debug_("Unexpected exception on closing JDBC Connection", ex);
    }

    /// Close the given JDBC `Statement` and ignore any thrown exception.
    static void closeStatement(Statement stmt)
    {
        if (stmt is null)
            return;
        try
            stmt.close();
        catch (SQLException ex)
            logger().trace("Could not close JDBC Statement", ex);
        catch (Exception ex)
            logger().trace("Unexpected exception on closing JDBC Statement", ex);
    }

    /// Close the given JDBC `ResultSet` and ignore any thrown exception.
    static void closeResultSet(ResultSet rs)
    {
        if (rs is null)
            return;
        try
            rs.close();
        catch (SQLException ex)
            logger().trace("Could not close JDBC ResultSet", ex);
        catch (Exception ex)
            logger().trace("Unexpected exception on closing JDBC ResultSet", ex);
    }

    /// Retrieve a JDBC column value from a `ResultSet`, using the specified value type (R4).
    static T getResultSetValue(T)(ResultSet rs, int index)
    {
        return rs.getObject!T(index);
    }

    /// Retrieve a JDBC column value from a `ResultSet`, using the most appropriate value type.
    static Any getResultSetValue(ResultSet rs, int index)
    {
        return rs.getObject(index);
    }

    /// Return whether the given JDBC driver supports JDBC batch updates.
    static bool supportsBatchUpdates(Connection con)
    {
        try
        {
            auto dbmd = con.getMetaData();
            if (dbmd !is null)
            {
                if (dbmd.supportsBatchUpdates())
                {
                    logger().debug_("JDBC driver supports batch updates");
                    return true;
                }
                logger().debug_("JDBC driver does not support batch updates");
            }
        }
        catch (SQLException ex)
            logger().debug_("JDBC driver 'supportsBatchUpdates' method threw exception", ex);
        return false;
    }

    /// Extract a common name for the target database in use even if various drivers/platforms provide varying names
    /// at runtime.
    static string commonDatabaseName(string source)
    {
        if (source.length >= 3 && source[0 .. 3] == "DB2")
            return "DB2";
        if (source == "Sybase SQL Server" || source == "Adaptive Server Enterprise" || source == "ASE"
                || equalsIgnoreCase(source, "sql server"))
            return "Sybase";
        return source;
    }

    /// Check whether the given SQL type is numeric.
    static bool isNumeric(int sqlType)
    {
        return sqlType == Types.BIT || sqlType == Types.BIGINT || sqlType == Types.DECIMAL
            || sqlType == Types.DOUBLE || sqlType == Types.FLOAT || sqlType == Types.INTEGER
            || sqlType == Types.NUMERIC || sqlType == Types.REAL || sqlType == Types.SMALLINT || sqlType == Types
                .TINYINT;
    }

    /// Determine the column name to use. The column name is determined based on a lookup using
    /// `ResultSetMetaData`: the column label if it has one, otherwise the column name.
    static string lookupColumnName(ResultSetMetaData resultSetMetaData, int columnIndex)
    {
        auto name = resultSetMetaData.getColumnLabel(columnIndex);
        if (name.length == 0)
            name = resultSetMetaData.getColumnName(columnIndex);
        return name;
    }

    /// Convert a property name using "camelCase" to a corresponding column name with underscores. A name like
    /// "customerNumber" would match a "customer_number" column name.
    static string convertPropertyNameToUnderscoreName(string name)
    {
        if (name.length == 0)
            return "";
        string result = [toLower(name[0])];
        foreach (c; name[1 .. $])
        {
            if (c >= 'A' && c <= 'Z')
                result ~= ['_', toLower(c)];
            else
                result ~= c;
        }
        return result;
    }

    /// Convert a column name with underscores to the corresponding property name using "camelCase". A name like
    /// "customer_number" would match a "customerNumber" property name.
    static string convertUnderscoreNameToPropertyName(string name)
    {
        if (name.length == 0)
            return "";
        string result = [name.length > 1 && name[1] == '_' ? toUpper(name[0]) : toLower(name[0])];
        bool nextIsUpper;
        foreach (c; name[1 .. $])
        {
            if (c == '_')
                nextIsUpper = true;
            else if (nextIsUpper)
            {
                result ~= toUpper(c);
                nextIsUpper = false;
            }
            else
                result ~= toLower(c);
        }
        return result;
    }
}

private char toLower(char c) pure nothrow @nogc
{
    return c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
}

private char toUpper(char c) pure nothrow @nogc
{
    return c >= 'a' && c <= 'z' ? cast(char)(c - 32) : c;
}

private bool equalsIgnoreCase(string a, string b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if (toLower(a[i]) != toLower(b[i]))
            return false;
    return true;
}

// ---------------------------------------------------------------------------------------------------------------
// Key holders

/++
Interface for retrieving keys, typically used for auto-generated keys as potentially returned by JDBC insert
statements. Java's `Number` key is an `Any` holding the driver's integral type.
+/
interface KeyHolder
{
    /// Retrieve the first item from the first map, assuming that there is just one item and just one map, and that
    /// the item is a number. This is the typical case: a single, numeric generated key.
    Any getKey();

    /// Retrieve the first map of keys. If there are multiple entries in the list (meaning that multiple rows had
    /// keys returned), then an `InvalidDataAccessApiUsageException` is thrown.
    Map!(string, Any) getKeys();

    /// Return a reference to the `List` that contains the keys.
    List!(Map!(string, Any)) getKeyList();

    /// Retrieve the first item from the first map, assuming that there is just one item and just one map, and that
    /// the item is an instance of `T` (R4).
    T getKeyAs(T)()
    {
        auto key = getKey();
        if (key.isNull)
            return T.init;
        if (!key.holds!T)
            throw new DataRetrievalFailureException(
                    "The generated key type is not supported. Unable to cast [" ~ key.typeName
                    ~ "] to [" ~ T.stringof ~ "].");
        return key.get!T;
    }
}

/++
The standard implementation of the `KeyHolder` interface, to be used for holding auto-generated keys (as potentially
returned by JDBC insert statements). Create an instance of this class for each insert operation, and pass it to the
corresponding `JdbcTemplate` or `SqlUpdate` methods.
+/
class GeneratedKeyHolder : KeyHolder
{
    private List!(Map!(string, Any)) keyList;

    /// Create a new `GeneratedKeyHolder` with a default list.
    this()
    {
        keyList = new ArrayList!(Map!(string, Any));
    }

    /// Create a new `GeneratedKeyHolder` with a given list.
    this(List!(Map!(string, Any)) keyList)
    {
        this.keyList = keyList;
    }

    override Any getKey()
    {
        if (keyList.isEmpty())
            return Any.init;
        if (keyList.size() > 1 || keyList.get(0).size() > 1)
            throw new InvalidDataAccessApiUsageException(
                    "The getKey method should only be used when a single key is returned. "
                    ~ "The current key entry contains multiple keys: " ~ describeKeys());
        auto values = keyList.get(0).values().toArray();
        if (values.length == 0)
            throw new DataRetrievalFailureException(
                    "Unable to retrieve the generated key. Check that the table has an identity column enabled.");
        if (values[0].isNull)
            throw new DataRetrievalFailureException(
                    "The generated key type is not supported. Unable to cast [null] to [Number].");
        return values[0];
    }

    override Map!(string, Any) getKeys()
    {
        if (keyList.isEmpty())
            return null;
        if (keyList.size() > 1)
            throw new InvalidDataAccessApiUsageException(
                    "The getKeys method should only be used when keys for a single row are returned. "
                    ~ "The current key list contains keys for multiple rows: " ~ describeKeys());
        return keyList.get(0);
    }

    override List!(Map!(string, Any)) getKeyList()
    {
        return keyList;
    }

    private string describeKeys()
    {
        import flint.engine.aot.objects : objectToString;

        return objectToString(cast(Object) keyList);
    }
}
