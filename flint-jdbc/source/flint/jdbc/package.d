// Ported from spring-framework v7.1.0: spring-jdbc/src/main/java/org/springframework/jdbc/*.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.

/++
`org.springframework.jdbc`: the JDBC-specific subclasses of Spring's `DataAccessException` hierarchy, which the SQL
exception translators and `JdbcTemplate` throw (ADR-030, rule R8). Each keeps the original `SQLException` as its
cause.
+/
module flint.jdbc;

import flint.dao : DataAccessResourceFailureException, DataRetrievalFailureException,
    IncorrectUpdateSemanticsDataAccessException,
    InvalidDataAccessResourceUsageException, UncategorizedDataAccessException;
import flint.java.io : IOException;
import flint.java.lang : IllegalStateException;
import flint.java.sql : SQLException, SQLWarning;

@safe:

/// Exception thrown when SQL specified is invalid. Such exceptions always have a `SQLException` root cause.
class BadSqlGrammarException : InvalidDataAccessResourceUsageException
{
    private string sql;

    /// Constructor for `BadSqlGrammarException`: `task` names the current task, `sql` is the offending SQL
    /// statement, and `ex` the root cause.
    this(string task, string sql, SQLException ex, string file = __FILE__, size_t line = __LINE__)
    {
        super(task ~ "; bad SQL grammar [" ~ sql ~ "]", ex, file, line);
        this.sql = sql;
    }

    /// Return the wrapped `SQLException`.
    SQLException getSQLException()
    {
        return cast(SQLException) getCause();
    }

    /// Return the SQL that caused the problem.
    string getSql()
    {
        return sql;
    }
}

/// Fatal exception thrown when we can't connect to an RDBMS using JDBC.
class CannotGetJdbcConnectionException : DataAccessResourceFailureException
{
    /// Constructor for `CannotGetJdbcConnectionException`.
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, null, file, line);
    }

    /// Constructor for `CannotGetJdbcConnectionException`, with the root cause.
    this(string msg, SQLException ex, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, ex, file, line);
    }

    /// Constructor for `CannotGetJdbcConnectionException`, with an illegal-state root cause.
    this(string msg, IllegalStateException ex, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, ex, file, line);
    }
}

/// Data access exception thrown when a result set did not have the correct column count, for example when
/// expecting a single column but getting 0 or more than 1 column.
class IncorrectResultSetColumnCountException : DataRetrievalFailureException
{
    private int expectedCount;
    private int actualCount;

    /// Constructor for `IncorrectResultSetColumnCountException`.
    this(int expectedCount, int actualCount, string file = __FILE__, size_t line = __LINE__)
    {
        this("Incorrect column count: expected " ~ text(expectedCount) ~ ", actual " ~ text(actualCount),
                expectedCount, actualCount, file, line);
    }

    /// Constructor for `IncorrectResultSetColumnCountException`, with a message.
    this(string msg, int expectedCount, int actualCount, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, null, file, line);
        this.expectedCount = expectedCount;
        this.actualCount = actualCount;
    }

    /// Return the expected column count.
    int getExpectedCount()
    {
        return expectedCount;
    }

    /// Return the actual column count.
    int getActualCount()
    {
        return actualCount;
    }
}

/// Exception thrown when a `ResultSet` has been accessed in an invalid fashion, such as an invalid column index or
/// name. Also thrown by a disconnected `SqlRowSet`.
class InvalidResultSetAccessException : InvalidDataAccessResourceUsageException
{
    private string sql;

    /// Constructor for `InvalidResultSetAccessException`.
    this(string task, string sql, SQLException ex, string file = __FILE__, size_t line = __LINE__)
    {
        super(task ~ "; invalid ResultSet access for SQL [" ~ sql ~ "]", ex, file, line);
        this.sql = sql;
    }

    /// Constructor for `InvalidResultSetAccessException`, from the root cause alone.
    this(SQLException ex, string file = __FILE__, size_t line = __LINE__)
    {
        super(ex.getMessage(), ex, file, line);
    }

    /// Return the wrapped `SQLException`.
    SQLException getSQLException()
    {
        return cast(SQLException) getCause();
    }

    /// Return the SQL that caused the problem, or null if not known.
    string getSql()
    {
        return sql;
    }
}

/// Exception thrown when a JDBC update affects an unexpected number of rows. Typically we expect an update to affect
/// a single row, meaning it is an error if it affects multiple rows.
class JdbcUpdateAffectedIncorrectNumberOfRowsException : IncorrectUpdateSemanticsDataAccessException
{
    private int expected;
    private int actual;

    /// Constructor for `JdbcUpdateAffectedIncorrectNumberOfRowsException`.
    this(string sql, int expected, int actual, string file = __FILE__, size_t line = __LINE__)
    {
        super("SQL update '" ~ sql ~ "' affected " ~ text(actual) ~ " rows, not " ~ text(expected) ~ " as expected",
                null, file, line);
        this.expected = expected;
        this.actual = actual;
    }

    /// Return the number of rows that should have been affected.
    int getExpectedRowsAffected()
    {
        return expected;
    }

    /// Return the number of rows that have actually been affected.
    int getActualRowsAffected()
    {
        return actual;
    }

    /// Whether any row was updated.
    override bool wasDataUpdated() const pure nothrow @nogc
    {
        return actual > 0;
    }
}

/// Exception to be thrown when a LOB could not be retrieved. Deprecated since Spring 6.2 with the LOB support.
deprecated("since Spring 6.2") class LobRetrievalFailureException : DataRetrievalFailureException
{
    /// Constructor for `LobRetrievalFailureException`.
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, null, file, line);
    }

    /// Constructor for `LobRetrievalFailureException`, with an I/O root cause.
    this(string msg, IOException ex, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, ex, file, line);
    }
}

/// Exception thrown when we're not ignoring `SQLWarning`s. If a `SQLWarning` is reported, the operation completed,
/// so we will need to explicitly roll it back if we're not happy when looking at the warning.
class SQLWarningException : UncategorizedDataAccessException
{
    /// Constructor for `SQLWarningException`.
    this(string msg, SQLWarning ex, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, ex, file, line);
    }

    /// Return the underlying `SQLWarning`.
    SQLWarning getSQLWarning()
    {
        return cast(SQLWarning) getCause();
    }
}

/// Exception thrown when we can't classify an `SQLException` into one of our generic data access exceptions.
class UncategorizedSQLException : UncategorizedDataAccessException
{
    private string sql;

    /// Constructor for `UncategorizedSQLException`: the task, the offending SQL (or null), and the root cause.
    this(string task, string sql, SQLException ex, string file = __FILE__, size_t line = __LINE__)
    {
        super(uncategorizedMessage(task, sql, ex), ex, file, line);
        this.sql = sql;
    }

    /// Return the wrapped `SQLException`.
    SQLException getSQLException()
    {
        return cast(SQLException) getCause();
    }

    /// Return the SQL that led to the problem, or null if not known.
    string getSql()
    {
        return sql;
    }
}

private string uncategorizedMessage(string task, string sql, SQLException ex)
{
    const forSql = sql !is null ? " for SQL [" ~ sql ~ "]" : "";
    const state = "; SQL state [" ~ orNull(ex.getSQLState()) ~ "]; error code [" ~ text(ex.getErrorCode()) ~ "]; ";
    return task ~ "; uncategorized SQLException" ~ forSql ~ state ~ orNull(ex.getMessage());
}

/// Java's string concatenation of a null reference.
package(flint.jdbc) string orNull(string value) pure nothrow
{
    return value is null ? "null" : value;
}

/// Decimal text of an `int`.
package(flint.jdbc) string text(long value) pure nothrow
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
