// Ported from spring-framework v7.1.0: spring-jdbc/src/main/java/org/springframework/jdbc/support/SQLExceptionTranslator.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: AbstractFallbackSQLExceptionTranslator.java, SQLExceptionSubclassTranslator.java and
// SQLStateSQLExceptionTranslator.java.

/++
`org.springframework.jdbc.support`: the translation of `SQLException`s into Spring's `DataAccessException`
hierarchy. `SQLExceptionSubclassTranslator` reads the JDBC 4 subclass the Flint driver throws and falls back to
`SQLStateSQLExceptionTranslator`, which reads the SQLSTATE class (ADR-030). The error-code translator, which reads
`sql-error-codes.xml`, and the rest of the package follow with `JdbcTemplate`.
+/
module flint.jdbc.support;

import flint.dao : CannotAcquireLockException, DataAccessException,
    DataAccessResourceFailureException,
    DataIntegrityViolationException, DuplicateKeyException, InvalidDataAccessApiUsageException,
    PermissionDeniedDataAccessException,
    PessimisticLockingFailureException,
    QueryTimeoutException, RecoverableDataAccessException, TransientDataAccessResourceException;
import flint.java.lang : IllegalArgumentException;
import flint.java.sql : BatchUpdateException, SQLDataException, SQLException,
    SQLFeatureNotSupportedException, SQLIntegrityConstraintViolationException,
    SQLInvalidAuthorizationSpecException, SQLNonTransientConnectionException,
    SQLNonTransientException,
    SQLRecoverableException,
    SQLSyntaxErrorException, SQLTimeoutException,
    SQLTransactionRollbackException, SQLTransientConnectionException, SQLTransientException;
import flint.jdbc : BadSqlGrammarException, orNull;
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
