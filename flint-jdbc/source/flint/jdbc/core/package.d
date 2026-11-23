// Ported from spring-framework v7.1.0: spring-jdbc/src/main/java/org/springframework/jdbc/core/JdbcTemplate.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: JdbcOperations.java, RowMapper.java, ResultSetExtractor.java, RowCallbackHandler.java,
// PreparedStatementCreator.java, PreparedStatementSetter.java, BatchPreparedStatementSetter.java,
// InterruptibleBatchPreparedStatementSetter.java, ParameterizedPreparedStatementSetter.java,
// StatementCallback.java, ConnectionCallback.java, PreparedStatementCallback.java, SqlProvider.java,
// ParameterDisposer.java, SqlTypeValue.java, SqlParameterValue.java, StatementCreatorUtils.java,
// ArgumentPreparedStatementSetter.java, ArgumentTypePreparedStatementSetter.java,
// RowMapperResultSetExtractor.java, SingleColumnRowMapper.java, ColumnMapRowMapper.java and
// RowCountCallbackHandler.java.

/++
`org.springframework.jdbc.core`: `JdbcTemplate`, the central class of Spring's JDBC core, and its callback
interfaces (ADR-030).

$(UL
    $(LI Generic callbacks are interface templates: `RowMapper!T`, `ResultSetExtractor!T`, `StatementCallback!T`.
        Every method that takes one also takes a D delegate with the same parameter and return types (R9), so
        `jdbcTemplate.query(sql, (rs, rowNum) => new Customer(...), "Josh")` reads as the Java lambda does.)
    $(LI `Object...` arguments are an `(Args...)` façade that builds an `Any[]` (R7). The overloads that take
        `Object[] args` take `Any[]`.)
    $(LI `Class<T>` parameters are template parameters (R4): `queryForObject!long(sql)`,
        `queryForList!string(sql, args)`.)
    $(LI The generic methods of `JdbcOperations` are final templates over a few virtual erased forms, which take
        delegates (`execute(scope void delegate(Statement) @safe)`), so a subclass or a fake overrides those.)
    $(LI Lists are `flint.java.util.List!T` and row maps `Map!(string, Any)` (R10).)
)

Callable statements, `SqlRowSet` and `queryForStream` are deferred to Phase 2, as `flint.java.sql` has no
`CallableStatement` and the driver's result sets are materialized. `execute(ConnectionCallback)` hands the
callback the transactional connection itself rather than a close-suppressing proxy, since Flint has no runtime
proxies: the callback must not close it.
+/
module flint.jdbc.core;

import flint.dao : DataAccessException, InvalidDataAccessApiUsageException;
import flint.dao.support : DataAccessUtils;
import flint.engine.aot.any : Any;
import flint.engine.aot.objects : objectToString;
import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.java.sql : BatchUpdateException, Connection, PreparedStatement, ResultSet,
    ResultSetMetaData, SQLException, SQLWarning, Statement, Types;
import flint.java.util : ArrayList, LinkedHashMap, List, Map;
import flint.javax.sql : DataSource;
import flint.jdbc : IncorrectResultSetColumnCountException, SQLWarningException, UncategorizedSQLException;
import flint.jdbc.datasource : DataSourceUtils;
import flint.jdbc.support : JdbcAccessor, JdbcUtils, KeyHolder;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Callback interfaces

/// An interface used by `JdbcTemplate` for mapping rows of a `ResultSet` on a per-row basis.
interface RowMapper(T)
{
    /// Implementations must implement this method to map each row of data in the `ResultSet`. This method should
    /// not call `next()` on the `ResultSet`; it is only supposed to map values of the current row.
    T mapRow(ResultSet rs, int rowNum);
}

/// Callback interface used by `JdbcTemplate`'s query methods. Implementations of this interface perform the actual
/// work of extracting results from a `ResultSet`, without worrying about exception handling.
interface ResultSetExtractor(T)
{
    /// Implementations must implement this method to process the entire `ResultSet`.
    T extractData(ResultSet rs);
}

/// An interface used by `JdbcTemplate` for processing rows of a `ResultSet` on a per-row basis.
interface RowCallbackHandler
{
    /// Implementations must implement this method to process each row of data in the `ResultSet`. This method
    /// should not call `next()` on the `ResultSet`; it is only supposed to extract values of the current row.
    void processRow(ResultSet rs);
}

/// One of the two central callback interfaces used by the `JdbcTemplate` class. This interface creates a
/// `PreparedStatement` given a connection, provided by the `JdbcTemplate` class.
interface PreparedStatementCreator
{
    /// Create a statement in this connection. Allows implementations to use `PreparedStatement`s.
    PreparedStatement createPreparedStatement(Connection con);
}

/// General callback interface used by the `JdbcTemplate` class. This interface sets values on a
/// `PreparedStatement` provided by the `JdbcTemplate` class, for each of a number of updates in a batch using the
/// same SQL.
interface PreparedStatementSetter
{
    /// Set parameter values on the given `PreparedStatement`.
    void setValues(PreparedStatement ps);
}

/// Batch update callback interface used by the `JdbcTemplate` class. This interface sets values on a
/// `PreparedStatement` provided by the `JdbcTemplate` class, for each of a number of updates in a batch using the
/// same SQL.
interface BatchPreparedStatementSetter
{
    /// Set parameter values on the given `PreparedStatement`; `i` is the index of the statement in the batch.
    void setValues(PreparedStatement ps, int i);

    /// Return the size of the batch.
    int getBatchSize();
}

/// Extension of the `BatchPreparedStatementSetter` interface, adding a batch exhaustion check.
interface InterruptibleBatchPreparedStatementSetter : BatchPreparedStatementSetter
{
    /// Return whether the batch is complete, that is, whether there were no additional values added during the
    /// last `setValues` call.
    bool isBatchExhausted(int i);
}

/// Parameterized callback interface used by the `JdbcTemplate` class for batch updates.
interface ParameterizedPreparedStatementSetter(T)
{
    /// Set parameter values on the given `PreparedStatement`, from the argument object.
    void setValues(PreparedStatement ps, T argument);
}

/// Generic callback interface for code that operates on a JDBC `Statement`.
interface StatementCallback(T)
{
    /// Gets called by `JdbcTemplate.execute` with an active JDBC `Statement`.
    T doInStatement(Statement stmt);
}

/// Generic callback interface for code that operates on a JDBC `Connection`.
interface ConnectionCallback(T)
{
    /// Gets called by `JdbcTemplate.execute` with an active JDBC `Connection`.
    T doInConnection(Connection con);
}

/// Generic callback interface for code that operates on a `PreparedStatement`.
interface PreparedStatementCallback(T)
{
    /// Gets called by `JdbcTemplate.execute` with an active JDBC `PreparedStatement`.
    T doInPreparedStatement(PreparedStatement ps);
}

/// Interface to be implemented by objects that can provide SQL strings.
interface SqlProvider
{
    /// Return the SQL string for this object, that is, typically the SQL used for creating statements.
    string getSql();
}

/// Interface to be implemented by objects that can close resources allocated by parameters like `SqlLobValue`
/// objects.
interface ParameterDisposer
{
    /// Close the resources allocated by parameters that the implementing object holds.
    void cleanupParameters();
}

/// Interface to be implemented for setting values for more complex database-specific types not supported by the
/// standard `setObject` method.
interface SqlTypeValue
{
    /// Constant that indicates an unknown (or unspecified) SQL type.
    enum int TYPE_UNKNOWN = JdbcUtils.TYPE_UNKNOWN;

    /// Set the type value on the given `PreparedStatement`.
    void setTypeValue(PreparedStatement ps, int paramIndex, int sqlType, string typeName);
}

// ---------------------------------------------------------------------------------------------------------------
// Delegate adapters (R9)

private final class DelegateRowMapper(T) : RowMapper!T
{
    private T delegate(ResultSet, int) @safe mapper;

    this(T delegate(ResultSet, int) @safe mapper)
    {
        this.mapper = mapper;
    }

    override T mapRow(ResultSet rs, int rowNum)
    {
        return mapper(rs, rowNum);
    }
}

private final class DelegateRowCallbackHandler : RowCallbackHandler
{
    private void delegate(ResultSet) @safe handler;

    this(void delegate(ResultSet) @safe handler)
    {
        this.handler = handler;
    }

    override void processRow(ResultSet rs)
    {
        handler(rs);
    }
}

private final class DelegatePreparedStatementSetter : PreparedStatementSetter
{
    private void delegate(PreparedStatement) @safe setter;

    this(void delegate(PreparedStatement) @safe setter)
    {
        this.setter = setter;
    }

    override void setValues(PreparedStatement ps)
    {
        setter(ps);
    }
}

private final class DelegatePreparedStatementCreator : PreparedStatementCreator
{
    private PreparedStatement delegate(Connection) @safe creator;

    this(PreparedStatement delegate(Connection) @safe creator)
    {
        this.creator = creator;
    }

    override PreparedStatement createPreparedStatement(Connection con)
    {
        return creator(con);
    }
}

/// A `RowMapper` over a delegate (R9).
RowMapper!T rowMapper(T)(T delegate(ResultSet, int) @safe mapper)
{
    return new DelegateRowMapper!T(mapper);
}

/// A `RowCallbackHandler` over a delegate (R9).
RowCallbackHandler rowCallbackHandler(void delegate(ResultSet) @safe handler)
{
    return new DelegateRowCallbackHandler(handler);
}

/// A `PreparedStatementSetter` over a delegate (R9).
PreparedStatementSetter preparedStatementSetter(void delegate(PreparedStatement) @safe setter)
{
    return new DelegatePreparedStatementSetter(setter);
}

/// A `PreparedStatementCreator` over a delegate (R9).
PreparedStatementCreator preparedStatementCreator(PreparedStatement delegate(Connection) @safe creator)
{
    return new DelegatePreparedStatementCreator(creator);
}

/// The `Any[]` of a Java `Object...` argument list (R7). An argument that is already an `Any` is kept.
Any[] argumentArray(Args...)(Args args)
{
    auto values = new Any[Args.length];
    static foreach (index, Arg; Args)
    {
        static if (is(Arg == Any))
            values[index] = args[index];
        else static if (is(Arg == typeof(null)))
            values[index] = Any.init;
        else
            values[index] = Any.of(args[index]);
    }
    return values;
}

/// The erased form of a `ResultSetExtractor`: a delegate that reads a whole `ResultSet`.
alias ResultSetReader = void delegate(ResultSet) @safe;

private enum bool isCallbackArgument(T) = is(T : RowCallbackHandler) || is(T == void delegate(ResultSet) @safe);

// ---------------------------------------------------------------------------------------------------------------
// Parameter values

/++
Object to represent an SQL parameter value, including parameter meta-data such as the SQL type and the scale for
numeric values. Designed for use with `JdbcTemplate`'s operations that take an array of argument values: each such
argument value may be a `SqlParameterValue`, indicating the SQL type (and optionally the scale) instead of letting
the template guess a default type.
+/
class SqlParameterValue
{
    private int sqlType;
    private string typeName;
    private int scale = -1;
    private bool hasScale;
    private Any value;

    /// Create a new `SqlParameterValue`, supplying the SQL type.
    this(int sqlType, Any value)
    {
        this.sqlType = sqlType;
        this.value = value;
    }

    /// Create a new `SqlParameterValue`, supplying the SQL type and the type name.
    this(int sqlType, string typeName, Any value)
    {
        this.sqlType = sqlType;
        this.typeName = typeName;
        this.value = value;
    }

    /// Create a new `SqlParameterValue`, supplying the SQL type and the scale.
    this(int sqlType, int scale, Any value)
    {
        this.sqlType = sqlType;
        this.scale = scale;
        hasScale = true;
        this.value = value;
    }

    /// Return the value object that this parameter value holds.
    Any getValue()
    {
        return value;
    }

    /// Return the SQL type of the parameter.
    int getSqlType()
    {
        return sqlType;
    }

    /// Return the type name of the parameter, if any.
    string getTypeName()
    {
        return typeName;
    }

    /// Return the scale of the parameter, if any; -1 when none was given.
    int getScale()
    {
        return hasScale ? scale : -1;
    }
}

/++
Utility methods for `PreparedStatementSetter`/`Creator` and `CallableStatementCreator` implementations, providing
sophisticated parameter management (including support for LOB values). Used by `PreparedStatementCreatorFactory`
and `ArgumentTypePreparedStatementSetter`, and usable directly in custom setter and creator implementations.
+/
abstract class StatementCreatorUtils
{
    /// Derive a default SQL type from the given type name (R4: the D type of a value).
    static int javaTypeToSqlParameterType(string typeName)
    {
        switch (typeName)
        {
        case "bool":
            return Types.BOOLEAN;
        case "byte", "ubyte":
            return Types.TINYINT;
        case "short", "ushort":
            return Types.SMALLINT;
        case "int", "uint":
            return Types.INTEGER;
        case "long", "ulong":
            return Types.BIGINT;
        case "float":
            return Types.REAL;
        case "double":
            return Types.DOUBLE;
        case "string":
            return Types.VARCHAR;
        case "immutable(ubyte)[]", "ubyte[]", "const(ubyte)[]":
            return Types.VARBINARY;
        default:
            return SqlTypeValue.TYPE_UNKNOWN;
        }
    }

    /// Set the value for a parameter, taking its SQL type and scale from the given `SqlParameterValue`.
    static void setParameterValue(PreparedStatement ps, int paramIndex, SqlParameterValue param, Any inValue)
    {
        setParameterValueInternal(ps, paramIndex, param.getSqlType(), param.getTypeName(), inValue);
    }

    /// Set the value for a parameter, with the given SQL type, or `SqlTypeValue.TYPE_UNKNOWN` to let the value's
    /// type decide.
    static void setParameterValue(PreparedStatement ps, int paramIndex, int sqlType, Any inValue)
    {
        setParameterValueInternal(ps, paramIndex, sqlType, null, inValue);
    }

    /// Set the value for a parameter, with the given SQL type and type name.
    static void setParameterValue(PreparedStatement ps, int paramIndex, int sqlType, string typeName, Any inValue)
    {
        setParameterValueInternal(ps, paramIndex, sqlType, typeName, inValue);
    }

    private static void setParameterValueInternal(PreparedStatement ps, int paramIndex, int sqlType,
            string typeName, Any inValue)
    {
        auto sqlTypeToUse = sqlType;
        auto inValueToUse = inValue;
        // Override type info?
        if (auto object = inValue.isNull ? null : inValue.asObject())
        {
            if (auto parameterValue = cast(SqlParameterValue) object)
            {
                if (parameterValue.getSqlType() != SqlTypeValue.TYPE_UNKNOWN)
                    sqlTypeToUse = parameterValue.getSqlType();
                typeName = parameterValue.getTypeName() !is null ? parameterValue.getTypeName() : typeName;
                inValueToUse = parameterValue.getValue();
            }
        }
        if (inValueToUse.isNull)
            ps.setNull(paramIndex, sqlTypeToUse == SqlTypeValue.TYPE_UNKNOWN ? Types.NULL : sqlTypeToUse);
        else
            setValue(ps, paramIndex, sqlTypeToUse, typeName, inValueToUse);
    }

    private static void setValue(PreparedStatement ps, int paramIndex, int sqlType, string typeName, Any inValue)
    {
        if (auto object = inValue.asObject())
        {
            if (auto typeValue = cast(SqlTypeValue) object)
            {
                typeValue.setTypeValue(ps, paramIndex, sqlType, typeName);
                return;
            }
        }
        if (sqlType == Types.VARCHAR || sqlType == Types.LONGVARCHAR || sqlType == Types.CHAR
                || sqlType == Types.NVARCHAR || sqlType == Types.NCHAR)
        {
            ps.setString(paramIndex, inValue.holds!string ? inValue.get!string : inValue.toString());
            return;
        }
        // TYPE_UNKNOWN or another type: the value's own type decides, as setObject does on the JVM.
        ps.setObject(paramIndex, inValue);
    }

    /// Clean up all resources held by parameter values which were passed to an execute method. This is for example
    /// important for closing LOB values.
    static void cleanupParameters(Any[] paramValues)
    {
        foreach (value; paramValues)
        {
            if (value.isNull)
                continue;
            if (auto object = value.asObject())
            {
                if (auto parameterValue = cast(SqlParameterValue) object)
                    cleanupParameters([parameterValue.getValue()]);
                else if (auto disposer = cast(ParameterDisposer) object)
                    disposer.cleanupParameters();
            }
        }
    }
}

/// Simple adapter for `PreparedStatementSetter` that applies a given array of arguments.
class ArgumentPreparedStatementSetter : PreparedStatementSetter, ParameterDisposer
{
    private Any[] args;

    /// Create a new `ArgumentPreparedStatementSetter` for the given arguments.
    this(Any[] args)
    {
        this.args = args;
    }

    override void setValues(PreparedStatement ps)
    {
        foreach (index, arg; args)
            doSetValue(ps, cast(int) index + 1, arg);
    }

    /// Set the value for the prepared statement's specified parameter position using the passed in value. This
    /// method can be overridden by subclasses if needed.
    protected void doSetValue(PreparedStatement ps, int parameterPosition, Any argValue)
    {
        if (auto object = argValue.isNull ? null : argValue.asObject())
        {
            if (auto paramValue = cast(SqlParameterValue) object)
            {
                StatementCreatorUtils.setParameterValue(ps, parameterPosition, paramValue, paramValue.getValue());
                return;
            }
        }
        StatementCreatorUtils.setParameterValue(ps, parameterPosition, SqlTypeValue.TYPE_UNKNOWN, argValue);
    }

    override void cleanupParameters()
    {
        StatementCreatorUtils.cleanupParameters(args);
    }
}

/// Simple adapter for `PreparedStatementSetter` that applies given arrays of arguments and JDBC argument types.
class ArgumentTypePreparedStatementSetter : PreparedStatementSetter, ParameterDisposer
{
    private Any[] args;
    private int[] argTypes;

    /// Create a new `ArgumentTypePreparedStatementSetter` for the given arguments and their `Types` constants.
    this(Any[] args, int[] argTypes)
    {
        if ((args !is null && argTypes is null) || (args is null && argTypes !is null) || (args !is null
                && args.length != argTypes.length))
            throw new InvalidDataAccessApiUsageException("args and argTypes parameters must match");
        this.args = args;
        this.argTypes = argTypes;
    }

    override void setValues(PreparedStatement ps)
    {
        foreach (index, arg; args)
            doSetValue(ps, cast(int) index + 1, argTypes[index], arg);
    }

    /// Set the value for the prepared statement's specified parameter position using the passed in value and type.
    /// This method can be overridden by subclasses if needed.
    protected void doSetValue(PreparedStatement ps, int parameterPosition, int argType, Any argValue)
    {
        StatementCreatorUtils.setParameterValue(ps, parameterPosition, argType, argValue);
    }

    override void cleanupParameters()
    {
        StatementCreatorUtils.cleanupParameters(args);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Row mappers and extractors

/++
Adapter implementation of the `ResultSetExtractor` interface that delegates to a `RowMapper` which is supposed to
create an object for each row. Each object is added to the results list of this `ResultSetExtractor`.
+/
class RowMapperResultSetExtractor(T) : ResultSetExtractor!(List!T)
{
    private RowMapper!T rowMapper;
    private int rowsExpected;
    private int maxRows;

    /// Create a new `RowMapperResultSetExtractor`.
    this(RowMapper!T rowMapper)
    {
        this(rowMapper, 0, -1);
    }

    /// Create a new `RowMapperResultSetExtractor`; `rowsExpected` sizes the result list.
    this(RowMapper!T rowMapper, int rowsExpected)
    {
        this(rowMapper, rowsExpected, -1);
    }

    /// Create a new `RowMapperResultSetExtractor`; `maxRows` limits the rows read, -1 for no limit.
    this(RowMapper!T rowMapper, int rowsExpected, int maxRows)
    {
        if (rowMapper is null)
            throw new IllegalArgumentException("RowMapper must not be null");
        this.rowMapper = rowMapper;
        this.rowsExpected = rowsExpected;
        this.maxRows = maxRows;
    }

    override List!T extractData(ResultSet rs)
    {
        auto results = new ArrayList!T;
        int rowNum;
        while ((maxRows == -1 || rowNum < maxRows) && rs.next())
            results.add(rowMapper.mapRow(rs, rowNum++));
        return results;
    }
}

/++
`RowMapper` implementation that converts a single column into a single result value per row. Expects to operate on
a `ResultSet` that just contains a single column. The type of the result value for each row is `T` (R4).
+/
class SingleColumnRowMapper(T) : RowMapper!T
{
    /// Create a new `SingleColumnRowMapper`.
    this()
    {
    }

    /// Extract a value for the single column in the current row. Validates that there is only one column selected,
    /// then delegates to `getColumnValue()`.
    override T mapRow(ResultSet rs, int rowNum)
    {
        auto rsmd = rs.getMetaData();
        const nrOfColumns = rsmd.getColumnCount();
        if (nrOfColumns != 1)
            throw new IncorrectResultSetColumnCountException(1, nrOfColumns);
        return getColumnValue(rs, 1);
    }

    /// Retrieve a JDBC object value for the specified column, converted to `T`.
    protected T getColumnValue(ResultSet rs, int index)
    {
        return JdbcUtils.getResultSetValue!T(rs, index);
    }

    /// Static factory method to create a new `SingleColumnRowMapper`.
    static SingleColumnRowMapper!T newInstance()
    {
        return new SingleColumnRowMapper!T;
    }
}

/++
`RowMapper` implementation that creates a `Map` for each row, representing all columns as key-value pairs: one
entry for each column, with the column name as key. The map preserves the column order. Spring's map is a
`LinkedCaseInsensitiveMap`; Flint's is a `LinkedHashMap` keyed by the column label as the driver reports it.
+/
class ColumnMapRowMapper : RowMapper!(Map!(string, Any))
{
    override Map!(string, Any) mapRow(ResultSet rs, int rowNum)
    {
        auto rsmd = rs.getMetaData();
        const columnCount = rsmd.getColumnCount();
        auto mapOfColumnValues = createColumnMap(columnCount);
        foreach (i; 1 .. columnCount + 1)
            mapOfColumnValues.put(getColumnKey(JdbcUtils.lookupColumnName(rsmd, i)), getColumnValue(rs, i));
        return mapOfColumnValues;
    }

    /// Create a `Map` instance to be used as column map.
    protected Map!(string, Any) createColumnMap(int)
    {
        return new LinkedHashMap!(string, Any);
    }

    /// Determine the key to use for the given column in the column map.
    protected string getColumnKey(string columnName)
    {
        return columnName;
    }

    /// Retrieve a JDBC object value for the specified column.
    protected Any getColumnValue(ResultSet rs, int index)
    {
        return JdbcUtils.getResultSetValue(rs, index);
    }
}

/++
Implementation of `RowCallbackHandler`. Convenient superclass for callback handlers. An instance can only be used
once. It counts the rows and records the column names and SQL types of the result set.
+/
class RowCountCallbackHandler : RowCallbackHandler
{
    private int rowCount;
    private int columnCount;
    private int[] columnTypes;
    private string[] columnNames;

    override final void processRow(ResultSet rs)
    {
        if (rowCount == 0)
        {
            auto rsmd = rs.getMetaData();
            columnCount = rsmd.getColumnCount();
            columnTypes = new int[columnCount];
            columnNames = new string[columnCount];
            foreach (i; 0 .. columnCount)
            {
                columnTypes[i] = rsmd.getColumnType(i + 1);
                columnNames[i] = JdbcUtils.lookupColumnName(rsmd, i + 1);
            }
        }
        processRow(rs, rowCount++);
    }

    /// Subclasses may override this to perform custom extraction or processing. This class's implementation does
    /// nothing.
    protected void processRow(ResultSet, int)
    {
    }

    /// Return the types of the columns as `Types` constants. Valid after `processRow` has been invoked once.
    final int[] getColumnTypes()
    {
        return columnTypes;
    }

    /// Return the names of the columns. Valid after `processRow` has been invoked once.
    final string[] getColumnNames()
    {
        return columnNames;
    }

    /// Return the row count of this `ResultSet`. Only valid after processing is complete.
    final int getRowCount()
    {
        return rowCount;
    }

    /// Return the number of columns in this result set. Valid once we've seen the first row, so subclasses can use
    /// it during processing.
    final int getColumnCount()
    {
        return columnCount;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// JdbcOperations

/++
Interface specifying a basic set of JDBC operations. Implemented by `JdbcTemplate`. Not often used directly, but a
useful option to enhance testability, as it can easily be mocked or stubbed.

The generic operations are final templates (R4) over the virtual erased forms that take delegates.
+/
interface JdbcOperations
{
    // Erased forms: the virtual primitives of the generic operations.

    /// Execute a JDBC data access operation, implemented as a delegate working on a JDBC `Connection`.
    void execute(scope void delegate(Connection) @safe action);

    /// Execute a JDBC data access operation, implemented as a delegate working on a JDBC `Statement`.
    void execute(scope void delegate(Statement) @safe action);

    /// Execute a JDBC data access operation on the `PreparedStatement` that `psc` creates.
    void execute(PreparedStatementCreator psc, scope void delegate(PreparedStatement) @safe action);

    /// Execute a JDBC data access operation on a `PreparedStatement` for `sql`.
    void execute(string sql, scope void delegate(PreparedStatement) @safe action);

    /// Execute a static query, reading its `ResultSet` with the given delegate.
    void query(string sql, scope void delegate(ResultSet) @safe extractor);

    /// Query using a prepared statement, reading the `ResultSet` with the given delegate.
    void query(PreparedStatementCreator psc, PreparedStatementSetter pss, scope ResultSetReader extractor);

    // Non-generic operations.

    /// Issue a single SQL execute, typically a DDL statement.
    void execute(string sql);

    /// Execute a query given static SQL, reading the `ResultSet` on a per-row basis with a `RowCallbackHandler`.
    void query(string sql, RowCallbackHandler rch);

    /// Query using a prepared statement, reading the `ResultSet` on a per-row basis with a `RowCallbackHandler`.
    void query(PreparedStatementCreator psc, RowCallbackHandler rch);

    /// Query given SQL to create a prepared statement from SQL and a `PreparedStatementSetter` implementation
    /// that knows how to bind values to the query, reading the `ResultSet` on a per-row basis.
    void query(string sql, PreparedStatementSetter pss, RowCallbackHandler rch);

    /// Query given SQL to create a prepared statement from SQL and a list of arguments to bind to the query,
    /// reading the `ResultSet` on a per-row basis.
    void query(string sql, Any[] args, int[] argTypes, RowCallbackHandler rch);

    /// Query given SQL and arguments, reading the `ResultSet` on a per-row basis (the core of the
    /// `Object...` form).
    void query(string sql, RowCallbackHandler rch, Any[] args);

    /// Execute a query for a result map, given static SQL.
    Map!(string, Any) queryForMap(string sql);

    /// Query given SQL to create a prepared statement from SQL and a list of arguments to bind to the query,
    /// expecting a result map.
    Map!(string, Any) queryForMap(string sql, Any[] args, int[] argTypes);

    /// Query given SQL and arguments, expecting a result map (the core of the `Object...` form).
    Map!(string, Any) queryForMap(string sql, Any[] args);

    /// Execute a query for a result list, given static SQL: one map per row.
    List!(Map!(string, Any)) queryForList(string sql);

    /// Query given SQL to create a prepared statement from SQL and a list of arguments to bind to the query,
    /// expecting a result list of maps.
    List!(Map!(string, Any)) queryForList(string sql, Any[] args, int[] argTypes);

    /// Query given SQL and arguments, expecting a result list of maps (Java's `Object...` form, R7).
    List!(Map!(string, Any)) queryForList(string sql, Any[] args);

    /// Issue a single SQL update operation (such as an insert, update or delete statement).
    int update(string sql);

    /// Issue a single SQL update operation using a `PreparedStatementCreator` to provide SQL and any required
    /// parameters.
    int update(PreparedStatementCreator psc);

    /// Issue an update statement using a `PreparedStatementCreator` to provide SQL and any required parameters.
    /// Generated keys will be put into the given `KeyHolder`.
    int update(PreparedStatementCreator psc, KeyHolder generatedKeyHolder);

    /// Issue an update statement using a `PreparedStatementSetter` to set bind parameters, with given SQL.
    int update(string sql, PreparedStatementSetter pss);

    /// Issue a single SQL update operation via a prepared statement, binding the given arguments.
    int update(string sql, Any[] args, int[] argTypes);

    /// Issue a single SQL update operation via a prepared statement, binding the given arguments (the core of the
    /// `Object...` form).
    int update(string sql, Any[] args);

    /// Issue multiple SQL updates on a single JDBC `Statement` using batching.
    int[] batchUpdate(string[] sql...);

    /// Issue multiple update statements on a single `PreparedStatement`, using batch updates and a
    /// `BatchPreparedStatementSetter` to set values.
    int[] batchUpdate(string sql, BatchPreparedStatementSetter pss);

    /// Issue multiple update statements on a single `PreparedStatement`, using batch updates, and storing the
    /// generated keys in the given `KeyHolder`.
    int[] batchUpdate(PreparedStatementCreator psc, BatchPreparedStatementSetter pss, KeyHolder generatedKeyHolder);

    /// Execute a batch using the supplied SQL statement with the batch of supplied arguments: one `Any[]` per
    /// statement (Java's `List<Object[]>`, R10).
    int[] batchUpdate(string sql, Any[][] batchArgs);

    /// Execute a batch using the supplied SQL statement with the batch of supplied arguments and their types.
    int[] batchUpdate(string sql, Any[][] batchArgs, int[] argTypes);

    // Generic operations (R4): final templates over the erased forms.

    /// Execute a JDBC data access operation, implemented as callback action working on a JDBC `Connection`.
    T execute(T)(ConnectionCallback!T action)
    {
        T result;
        execute((Connection con) { result = action.doInConnection(con); });
        return result;
    }

    /// Execute a JDBC data access operation, implemented as callback action working on a JDBC `Statement`.
    T execute(T)(StatementCallback!T action)
    {
        T result;
        execute((Statement stmt) { result = action.doInStatement(stmt); });
        return result;
    }

    /// Execute a JDBC data access operation, implemented as callback action working on a JDBC
    /// `PreparedStatement`.
    T execute(T)(PreparedStatementCreator psc, PreparedStatementCallback!T action)
    {
        T result;
        execute(psc, (PreparedStatement ps) { result = action.doInPreparedStatement(ps); });
        return result;
    }

    /// Execute a JDBC data access operation, implemented as callback action working on a JDBC
    /// `PreparedStatement` for `sql`.
    T execute(T)(string sql, PreparedStatementCallback!T action)
    {
        T result;
        execute(sql, (PreparedStatement ps) { result = action.doInPreparedStatement(ps); });
        return result;
    }

    /// Execute a query given static SQL, reading the `ResultSet` with a `ResultSetExtractor`.
    T query(T)(string sql, ResultSetExtractor!T rse)
    {
        T result;
        query(sql, (ResultSet rs) { result = rse.extractData(rs); });
        return result;
    }

    /// Query using a prepared statement, reading the `ResultSet` with a `ResultSetExtractor`.
    T query(T)(PreparedStatementCreator psc, ResultSetExtractor!T rse)
    {
        T result;
        query(psc, null, (ResultSet rs) { result = rse.extractData(rs); });
        return result;
    }

    /// Query using a prepared statement for `sql` and a `PreparedStatementSetter`, reading the `ResultSet` with a
    /// `ResultSetExtractor`.
    T query(T)(string sql, PreparedStatementSetter pss, ResultSetExtractor!T rse)
    {
        T result;
        query(simplePreparedStatementCreator(sql), pss, (ResultSet rs) {
            result = rse.extractData(rs);
        });
        return result;
    }

    /// Query given SQL and typed arguments, reading the `ResultSet` with a `ResultSetExtractor`.
    T query(T)(string sql, Any[] args, int[] argTypes, ResultSetExtractor!T rse)
    {
        return query(sql, new ArgumentTypePreparedStatementSetter(args, argTypes), rse);
    }

    /// Query given SQL and arguments, reading the `ResultSet` with a `ResultSetExtractor`.
    T query(T, Args...)(string sql, ResultSetExtractor!T rse, Args args)
    {
        return query(sql, new ArgumentPreparedStatementSetter(argumentArray(args)), rse);
    }

    /// Execute a query given static SQL, mapping each row to a result object via a `RowMapper`.
    List!T query(T)(string sql, RowMapper!T rowMapper)
    {
        return query(sql, new RowMapperResultSetExtractor!T(rowMapper, 0, rowLimit(this)));
    }

    /// Query using a prepared statement, mapping each row to a result object via a `RowMapper`.
    List!T query(T)(PreparedStatementCreator psc, RowMapper!T rowMapper)
    {
        return query(psc, new RowMapperResultSetExtractor!T(rowMapper, 0, rowLimit(this)));
    }

    /// Query given SQL and a `PreparedStatementSetter`, mapping each row to a result object via a `RowMapper`.
    List!T query(T)(string sql, PreparedStatementSetter pss, RowMapper!T rowMapper)
    {
        return query(sql, pss, new RowMapperResultSetExtractor!T(rowMapper, 0, rowLimit(this)));
    }

    /// Query given SQL and typed arguments, mapping each row to a result object via a `RowMapper`.
    List!T query(T)(string sql, Any[] args, int[] argTypes, RowMapper!T rowMapper)
    {
        return query(sql, args, argTypes, new RowMapperResultSetExtractor!T(rowMapper, 0, rowLimit(this)));
    }

    /// Query given SQL and arguments, mapping each row to a result object via a `RowMapper`.
    List!T query(T, Args...)(string sql, RowMapper!T rowMapper, Args args)
    {
        return query(sql, new ArgumentPreparedStatementSetter(argumentArray(args)),
                new RowMapperResultSetExtractor!T(rowMapper, 0, rowLimit(this)));
    }

    /// Query given SQL and arguments, mapping each row with a delegate (R9).
    List!T query(T, Args...)(string sql, T delegate(ResultSet, int) @safe rowMapper, Args args)
    {
        return query(sql, .rowMapper(rowMapper), args);
    }

    /// Query given SQL and arguments, processing each row with a delegate (R9).
    void query(Args...)(string sql, void delegate(ResultSet) @safe rch, Args args)
    {
        query(sql, rowCallbackHandler(rch), argumentArray(args));
    }

    /// Query given SQL and arguments, reading the `ResultSet` on a per-row basis (Java's `Object...` form).
    void query(Args...)(string sql, RowCallbackHandler rch, Args args) if (Args.length > 0)
    {
        query(sql, rch, argumentArray(args));
    }

    /// Execute a query given static SQL, mapping a single result row to a result object via a `RowMapper`.
    /// Throws `IncorrectResultSizeDataAccessException` if the query does not return exactly one row.
    T queryForObject(T)(string sql, RowMapper!T rowMapper)
    {
        return DataAccessUtils.nullableSingleResult(query(sql, rowMapper));
    }

    /// Query given SQL and typed arguments, mapping a single result row via a `RowMapper`.
    T queryForObject(T)(string sql, Any[] args, int[] argTypes, RowMapper!T rowMapper)
    {
        return DataAccessUtils.nullableSingleResult(query(sql, args, argTypes,
                new RowMapperResultSetExtractor!T(rowMapper, 1)));
    }

    /// Query given SQL and arguments, mapping a single result row via a `RowMapper`.
    T queryForObject(T, Args...)(string sql, RowMapper!T rowMapper, Args args)
    {
        return DataAccessUtils.nullableSingleResult(query(sql,
                new ArgumentPreparedStatementSetter(argumentArray(args)),
                new RowMapperResultSetExtractor!T(rowMapper, 1)));
    }

    /// Query given SQL and arguments, mapping a single result row with a delegate (R9).
    T queryForObject(T, Args...)(string sql, T delegate(ResultSet, int) @safe rowMapper, Args args)
    {
        return queryForObject(sql, .rowMapper(rowMapper), args);
    }

    /// Query given SQL and arguments for a single result object of type `T` (Java's `Class<T> requiredType`, R4).
    T queryForObject(T, Args...)(string sql, Args args)
            if (Args.length == 0 || !is(Args[0] : RowMapper!T))
    {
        return queryForObject(sql, new SingleColumnRowMapper!T, args);
    }

    /// Query given SQL and typed arguments for a single result object of type `T` (R4).
    T queryForObject(T)(string sql, Any[] args, int[] argTypes)
    {
        return queryForObject(sql, args, argTypes, new SingleColumnRowMapper!T);
    }

    /// Query given SQL and arguments for a result map (Java's `Object...` form).
    Map!(string, Any) queryForMap(Args...)(string sql, Args args) if (Args.length > 0)
    {
        return queryForMap(sql, argumentArray(args));
    }

    /// Query given SQL and arguments for a result list of `T` values (Java's `Class<T> elementType`, R4).
    List!T queryForList(T, Args...)(string sql, Args args)
    {
        return query(sql, new ArgumentPreparedStatementSetter(argumentArray(args)),
                new RowMapperResultSetExtractor!T(new SingleColumnRowMapper!T, 0, rowLimit(this)));
    }

    /// Query given SQL and typed arguments for a result list of `T` values (R4).
    List!T queryForList(T)(string sql, Any[] args, int[] argTypes)
    {
        return query(sql, args, argTypes, new SingleColumnRowMapper!T);
    }

    /// Issue a single SQL update operation via a prepared statement, binding the given arguments (Java's
    /// `Object...` form).
    int update(Args...)(string sql, Args args)
            if (Args.length > 0 && !is(Args[0] : PreparedStatementSetter))
    {
        return update(sql, argumentArray(args));
    }

    /// Execute a batch using the supplied SQL statement with the batch of supplied arguments, given as rows of D
    /// values (R10): `batchUpdate(sql, [["John", "Woo"], ["Jeff", "Dean"]])`.
    int[] batchUpdate(E)(string sql, E[][] batchArgs) if (!is(E == Any))
    {
        auto rows = new Any[][batchArgs.length];
        foreach (i, row; batchArgs)
        {
            rows[i] = new Any[row.length];
            foreach (index, value; row)
                rows[i][index] = Any.of(value);
        }
        return batchUpdate(sql, rows);
    }

    /// Execute multiple batches using the supplied SQL statement with the collection of supplied arguments.
    deprecated("since 7.1") int[][] batchUpdate(T)(string sql, List!T batchArgs, int batchSize,
            ParameterizedPreparedStatementSetter!T pss)
    {
        auto items = batchArgs.toArray();
        int[][] result;
        for (size_t start = 0; start < items.length; start += batchSize)
        {
            auto chunk = items[start .. start + batchSize < items.length ? start + batchSize : items.length];
            result ~= batchUpdate(sql, new ChunkSetter!T(chunk, pss));
        }
        return result;
    }
}

private final class ChunkSetter(T) : BatchPreparedStatementSetter
{
    private T[] items;
    private ParameterizedPreparedStatementSetter!T pss;

    this(T[] items, ParameterizedPreparedStatementSetter!T pss)
    {
        this.items = items;
        this.pss = pss;
    }

    override void setValues(PreparedStatement ps, int i)
    {
        pss.setValues(ps, items[i]);
    }

    override int getBatchSize()
    {
        return cast(int) items.length;
    }
}

/// The row limit of a `JdbcTemplate`'s generic queries: its `maxRows`, which Spring passes to
/// `RowMapperResultSetExtractor` in case the driver ignores `Statement.setMaxRows`; -1 for other implementations.
private int rowLimit(JdbcOperations operations)
{
    auto template_ = cast(JdbcTemplate) operations;
    return template_ !is null ? template_.getMaxRows() : -1;
}

/// A `PreparedStatementCreator` for plain SQL.
private PreparedStatementCreator simplePreparedStatementCreator(string sql)
{
    return new SimplePreparedStatementCreator(sql);
}

private final class SimplePreparedStatementCreator : PreparedStatementCreator, SqlProvider
{
    private string sql;

    this(string sql)
    {
        if (sql is null)
            throw new IllegalArgumentException("SQL must not be null");
        this.sql = sql;
    }

    override PreparedStatement createPreparedStatement(Connection con)
    {
        return con.prepareStatement(sql);
    }

    override string getSql()
    {
        return sql;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// JdbcTemplate

/++
This is the central delegate in the JDBC core package. It simplifies the use of JDBC and helps to avoid common
errors. It executes core JDBC workflow, leaving application code to provide SQL and extract results. This class
executes SQL queries or updates, initiating iteration over `ResultSet`s and catching JDBC exceptions and translating
them to the common `flint.dao` exception hierarchy.

Code using this class need only implement callback interfaces, or pass delegates (R9), giving them a clearly defined
contract. Connections come from `DataSourceUtils`, so a template participates in the current fiber's transaction.
+/
class JdbcTemplate : JdbcAccessor, JdbcOperations
{
    private bool ignoreWarnings = true;
    private int fetchSize = -1;
    private int maxRows = -1;
    private int queryTimeout = -1;
    private bool skipResultsProcessing;
    private bool skipUndeclaredResults;
    private bool resultsMapCaseInsensitive;

    /// Construct a new `JdbcTemplate` for bean usage. The `DataSource` has to be set before using the instance.
    this()
    {
    }

    /// Construct a new `JdbcTemplate`, given a `DataSource` to obtain connections from.
    this(DataSource dataSource)
    {
        this(dataSource, true);
    }

    /// Construct a new `JdbcTemplate`, given a `DataSource` to obtain connections from. `lazyInit` decides whether
    /// to lazily initialize the `SQLExceptionTranslator`.
    this(DataSource dataSource, bool lazyInit)
    {
        // Java's setters and afterPropertiesSet, without virtual calls in a constructor.
        if (dataSource is null)
            throw new IllegalArgumentException("Property 'dataSource' is required");
        JdbcAccessor.setDataSource(dataSource);
        JdbcAccessor.setLazyInit(lazyInit);
        if (!lazyInit)
            JdbcAccessor.getExceptionTranslator();
    }

    /// Copy constructor for a derived `JdbcTemplate`, taking over the configuration of `original`.
    this(JdbcAccessor original)
    {
        JdbcAccessor.setDataSource(original.getDataSource());
        JdbcAccessor.setExceptionTranslator(original.getExceptionTranslator());
        JdbcAccessor.setLazyInit(original.isLazyInit());
        if (auto originalTemplate = cast(JdbcTemplate) original)
        {
            ignoreWarnings = originalTemplate.ignoreWarnings;
            fetchSize = originalTemplate.fetchSize;
            maxRows = originalTemplate.maxRows;
            queryTimeout = originalTemplate.queryTimeout;
            skipResultsProcessing = originalTemplate.skipResultsProcessing;
            skipUndeclaredResults = originalTemplate.skipUndeclaredResults;
            resultsMapCaseInsensitive = originalTemplate.resultsMapCaseInsensitive;
        }
    }

    /// Set whether we want to ignore JDBC statement warnings (`SQLWarning`). Default is true; if false, warnings
    /// throw `SQLWarningException`.
    void setIgnoreWarnings(bool ignoreWarnings)
    {
        this.ignoreWarnings = ignoreWarnings;
    }

    /// Return whether we ignore `SQLWarning`s.
    bool isIgnoreWarnings()
    {
        return ignoreWarnings;
    }

    /// Set the fetch size for this `JdbcTemplate`. Default is -1, indicating to use the JDBC driver's default.
    void setFetchSize(int fetchSize)
    {
        this.fetchSize = fetchSize;
    }

    /// Return the fetch size specified for this `JdbcTemplate`.
    int getFetchSize()
    {
        return fetchSize;
    }

    /// Set the maximum number of rows for this `JdbcTemplate`. Default is -1, indicating to use the JDBC driver's
    /// default (no limit).
    void setMaxRows(int maxRows)
    {
        this.maxRows = maxRows;
    }

    /// Return the maximum number of rows specified for this `JdbcTemplate`.
    int getMaxRows()
    {
        return maxRows;
    }

    /// Set the query timeout in seconds for statements that this `JdbcTemplate` executes. Default is -1. Any
    /// timeout specified here is overridden by the remaining transaction timeout when executing within a
    /// transaction that has a timeout specified at the transaction level.
    void setQueryTimeout(int queryTimeout)
    {
        this.queryTimeout = queryTimeout;
    }

    /// Return the query timeout in seconds for statements that this `JdbcTemplate` executes.
    int getQueryTimeout()
    {
        return queryTimeout;
    }

    /// Set whether results processing should be skipped. Can be used to optimize callable statement processing.
    void setSkipResultsProcessing(bool skipResultsProcessing)
    {
        this.skipResultsProcessing = skipResultsProcessing;
    }

    /// Return whether results processing should be skipped.
    bool isSkipResultsProcessing()
    {
        return skipResultsProcessing;
    }

    /// Set whether undeclared results should be skipped.
    void setSkipUndeclaredResults(bool skipUndeclaredResults)
    {
        this.skipUndeclaredResults = skipUndeclaredResults;
    }

    /// Return whether undeclared results should be skipped.
    bool isSkipUndeclaredResults()
    {
        return skipUndeclaredResults;
    }

    /// Set whether execution of a callable statement will return the results in a case-insensitive map.
    void setResultsMapCaseInsensitive(bool resultsMapCaseInsensitive)
    {
        this.resultsMapCaseInsensitive = resultsMapCaseInsensitive;
    }

    /// Return whether execution of a callable statement will return the results in a case-insensitive map.
    bool isResultsMapCaseInsensitive()
    {
        return resultsMapCaseInsensitive;
    }

    //-------------------------------------------------------------------------
    // Methods dealing with a plain Connection

    override void execute(scope void delegate(Connection) @safe action)
    {
        auto con = DataSourceUtils.getConnection(obtainDataSource());
        scope (exit)
            DataSourceUtils.releaseConnection(con, getDataSource());
        try
            action(createConnectionProxy(con));
        catch (SQLException ex)
            throw translateException("ConnectionCallback", null, ex);
    }

    /// Return the connection handed to `ConnectionCallback`s. Spring returns a close-suppressing proxy; Flint has
    /// no runtime proxies and returns the connection itself.
    protected Connection createConnectionProxy(Connection con)
    {
        return con;
    }

    //-------------------------------------------------------------------------
    // Methods dealing with static SQL (Statement)

    override void execute(scope void delegate(Statement) @safe action)
    {
        executeStatement(action, null, "StatementCallback");
    }

    private void executeStatement(scope void delegate(Statement) @safe action, string sql, string task)
    {
        auto con = DataSourceUtils.getConnection(obtainDataSource());
        Statement stmt;
        scope (exit)
        {
            JdbcUtils.closeStatement(stmt);
            DataSourceUtils.releaseConnection(con, getDataSource());
        }
        try
        {
            stmt = con.createStatement();
            applyStatementSettings(stmt);
            action(stmt);
            handleWarnings(stmt);
        }
        catch (SQLException ex)
        {
            if (stmt !is null)
                handleWarnings(stmt, ex);
            throw translateException(task, sql, ex);
        }
    }

    override void execute(string sql)
    {
        if (logger.isDebugEnabled())
            logger.debug_("Executing SQL statement [" ~ sql ~ "]");
        executeStatement((Statement stmt) { stmt.execute(sql); }, sql, "StatementCallback");
    }

    override void query(string sql, scope void delegate(ResultSet) @safe extractor)
    {
        if (sql is null)
            throw new IllegalArgumentException("SQL must not be null");
        if (logger.isDebugEnabled())
            logger.debug_("Executing SQL query [" ~ sql ~ "]");
        executeStatement((Statement stmt) {
            ResultSet rs;
            scope (exit)
                JdbcUtils.closeResultSet(rs);
            rs = stmt.executeQuery(sql);
            extractor(rs);
        }, sql, "StatementCallback");
    }

    override void query(string sql, RowCallbackHandler rch)
    {
        query(sql, (ResultSet rs) { processRows(rs, rch); });
    }

    private void processRows(ResultSet rs, RowCallbackHandler rch)
    {
        int processed;
        while (rs.next() && (maxRows == -1 || (processed++) < maxRows))
            rch.processRow(rs);
    }

    override Map!(string, Any) queryForMap(string sql)
    {
        return result(queryForObject(sql, getColumnMapRowMapper()));
    }

    override List!(Map!(string, Any)) queryForList(string sql)
    {
        return query(sql, getColumnMapRowMapper());
    }

    override int update(string sql)
    {
        if (sql is null)
            throw new IllegalArgumentException("SQL must not be null");
        if (logger.isDebugEnabled())
            logger.debug_("Executing SQL update [" ~ sql ~ "]");
        int rows;
        executeStatement((Statement stmt) {
            rows = stmt.executeUpdate(sql);
            if (logger.isTraceEnabled())
                logger.trace("SQL update affected " ~ decimal(rows) ~ " rows");
        }, sql, "StatementCallback");
        return rows;
    }

    override int[] batchUpdate(string[] sql...)
    {
        if (sql.length == 0)
            throw new IllegalArgumentException("SQL array must not be empty");
        if (logger.isDebugEnabled())
            logger.debug_("Executing SQL batch update of " ~ decimal(cast(int) sql.length) ~ " statements");
        auto statements = sql.dup;
        auto rowsAffected = new int[statements.length];
        string currSql;
        try
            executeStatement((Statement stmt) {
                if (JdbcUtils.supportsBatchUpdates(stmt.getConnection()))
                {
                    foreach (sqlStmt; statements)
                    {
                        currSql ~= (currSql.length ? "; " : "") ~ sqlStmt;
                        stmt.addBatch(sqlStmt);
                    }
                    try
                        rowsAffected = stmt.executeBatch();
                    catch (BatchUpdateException ex)
                    {
                        currSql = null;
                        foreach (i, count; ex.getLargeUpdateCounts())
                            if (count == Statement.EXECUTE_FAILED && i < statements.length)
                                currSql ~= (currSql.length ? "; " : "") ~ statements[i];
                        throw ex;
                    }
                }
                else
                {
                    foreach (i, sqlStmt; statements)
                    {
                        currSql = sqlStmt;
                        if (!stmt.execute(sqlStmt))
                            rowsAffected[i] = stmt.getUpdateCount();
                        else
                            throw new InvalidDataAccessApiUsageException("Invalid batch SQL statement: " ~ sqlStmt);
                    }
                }
            }, null, "StatementCallback");
        catch (UncategorizedSQLException ex)
            throw ex;
        return rowsAffected;
    }

    //-------------------------------------------------------------------------
    // Methods dealing with prepared statements

    override void execute(PreparedStatementCreator psc, scope void delegate(PreparedStatement) @safe action)
    {
        if (psc is null)
            throw new IllegalArgumentException("PreparedStatementCreator must not be null");
        if (logger.isDebugEnabled())
        {
            const sql = getSql(cast(Object) psc);
            logger.debug_("Executing prepared SQL statement" ~ (sql !is null ? " [" ~ sql ~ "]" : ""));
        }
        auto con = DataSourceUtils.getConnection(obtainDataSource());
        PreparedStatement ps;
        scope (exit)
        {
            if (auto parameterDisposer = cast(ParameterDisposer) psc)
                parameterDisposer.cleanupParameters();
            JdbcUtils.closeStatement(ps);
            DataSourceUtils.releaseConnection(con, getDataSource());
        }
        try
        {
            ps = psc.createPreparedStatement(con);
            applyStatementSettings(ps);
            action(ps);
            handleWarnings(ps);
        }
        catch (SQLException ex)
        {
            if (ps !is null)
                handleWarnings(ps, ex);
            throw translateException("PreparedStatementCallback", getSql(cast(Object) psc), ex);
        }
    }

    override void execute(string sql, scope void delegate(PreparedStatement) @safe action)
    {
        execute(simplePreparedStatementCreator(sql), action);
    }

    override void query(PreparedStatementCreator psc, PreparedStatementSetter pss,
            scope void delegate(ResultSet) @safe extractor)
    {
        logger.debug_("Executing prepared SQL query");
        execute(psc, (PreparedStatement ps) {
            ResultSet rs;
            scope (exit)
            {
                JdbcUtils.closeResultSet(rs);
                if (auto parameterDisposer = cast(ParameterDisposer) pss)
                    parameterDisposer.cleanupParameters();
            }
            if (pss !is null)
                pss.setValues(ps);
            rs = ps.executeQuery();
            extractor(rs);
        });
    }

    override void query(PreparedStatementCreator psc, RowCallbackHandler rch)
    {
        query(psc, null, (ResultSet rs) { processRows(rs, rch); });
    }

    override void query(string sql, PreparedStatementSetter pss, RowCallbackHandler rch)
    {
        query(simplePreparedStatementCreator(sql), pss, (ResultSet rs) { processRows(rs, rch); });
    }

    override void query(string sql, Any[] args, int[] argTypes, RowCallbackHandler rch)
    {
        query(sql, newArgTypePreparedStatementSetter(args, argTypes), rch);
    }

    override void query(string sql, RowCallbackHandler rch, Any[] args)
    {
        query(sql, newArgPreparedStatementSetter(args), rch);
    }

    override Map!(string, Any) queryForMap(string sql, Any[] args, int[] argTypes)
    {
        return result(queryForObject(sql, args, argTypes, getColumnMapRowMapper()));
    }

    override Map!(string, Any) queryForMap(string sql, Any[] args)
    {
        return result(DataAccessUtils.nullableSingleResult(query(sql, newArgPreparedStatementSetter(args),
                new RowMapperResultSetExtractor!(Map!(string, Any))(getColumnMapRowMapper(), 1))));
    }

    override List!(Map!(string, Any)) queryForList(string sql, Any[] args, int[] argTypes)
    {
        return query(sql, args, argTypes, getColumnMapRowMapper());
    }

    override List!(Map!(string, Any)) queryForList(string sql, Any[] args)
    {
        return query(sql, newArgPreparedStatementSetter(args), getColumnMapRowMapper());
    }

    /// Issue an update using a `PreparedStatementCreator` and an optional `PreparedStatementSetter`.
    protected int update(PreparedStatementCreator psc, PreparedStatementSetter pss)
    {
        logger.debug_("Executing prepared SQL update");
        int rows;
        execute(psc, (PreparedStatement ps) {
            scope (exit)
            {
                if (auto parameterDisposer = cast(ParameterDisposer) pss)
                    parameterDisposer.cleanupParameters();
            }
            if (pss !is null)
                pss.setValues(ps);
            rows = ps.executeUpdate();
            if (logger.isTraceEnabled())
                logger.trace("SQL update affected " ~ decimal(rows) ~ " rows");
        });
        return rows;
    }

    override int update(PreparedStatementCreator psc)
    {
        return update(psc, cast(PreparedStatementSetter) null);
    }

    override int update(PreparedStatementCreator psc, KeyHolder generatedKeyHolder)
    {
        if (generatedKeyHolder is null)
            throw new IllegalArgumentException("KeyHolder must not be null");
        logger.debug_("Executing SQL update and returning generated keys");
        int rows;
        execute(psc, (PreparedStatement ps) {
            rows = ps.executeUpdate();
            generatedKeyHolder.getKeyList().clear();
            storeGeneratedKeys(generatedKeyHolder, ps, 1);
            if (logger.isTraceEnabled())
                logger.trace("SQL update affected " ~ decimal(rows) ~ " rows and returned " ~ decimal(
                    generatedKeyHolder.getKeyList().size()) ~ " keys");
        });
        return rows;
    }

    override int update(string sql, PreparedStatementSetter pss)
    {
        return update(simplePreparedStatementCreator(sql), pss);
    }

    override int update(string sql, Any[] args, int[] argTypes)
    {
        return update(sql, newArgTypePreparedStatementSetter(args, argTypes));
    }

    override int update(string sql, Any[] args)
    {
        return update(sql, newArgPreparedStatementSetter(args));
    }

    override int[] batchUpdate(PreparedStatementCreator psc, BatchPreparedStatementSetter pss,
            KeyHolder generatedKeyHolder)
    {
        int[] counts;
        execute(psc, (PreparedStatement ps) { counts = runBatch(ps, pss, generatedKeyHolder); });
        return counts;
    }

    override int[] batchUpdate(string sql, BatchPreparedStatementSetter pss)
    {
        if (logger.isDebugEnabled())
            logger.debug_("Executing SQL batch update [" ~ sql ~ "]");
        if (pss.getBatchSize() == 0)
            return [];
        int[] counts;
        execute(sql, (PreparedStatement ps) { counts = runBatch(ps, pss, null); });
        return counts;
    }

    override int[] batchUpdate(string sql, Any[][] batchArgs)
    {
        return batchUpdate(sql, batchArgs, []);
    }

    override int[] batchUpdate(string sql, Any[][] batchArgs, int[] argTypes)
    {
        if (batchArgs.length == 0)
            return [];
        return batchUpdate(sql, new ArgsBatchSetter(batchArgs, argTypes));
    }

    /// Run a batch on `ps`: Spring's `getPreparedStatementCallback`.
    private int[] runBatch(PreparedStatement ps, BatchPreparedStatementSetter pss, KeyHolder generatedKeyHolder)
    {
        scope (exit)
        {
            if (auto parameterDisposer = cast(ParameterDisposer) pss)
                parameterDisposer.cleanupParameters();
        }
        const batchSize = pss.getBatchSize();
        auto ipss = cast(InterruptibleBatchPreparedStatementSetter) pss;
        if (generatedKeyHolder !is null)
            generatedKeyHolder.getKeyList().clear();
        if (JdbcUtils.supportsBatchUpdates(ps.getConnection()))
        {
            foreach (i; 0 .. batchSize)
            {
                pss.setValues(ps, i);
                if (ipss !is null && ipss.isBatchExhausted(i))
                    break;
                ps.addBatch();
            }
            auto results = ps.executeBatch();
            if (generatedKeyHolder !is null)
                storeGeneratedKeys(generatedKeyHolder, ps, batchSize);
            return results;
        }
        int[] rowsAffected;
        foreach (i; 0 .. batchSize)
        {
            pss.setValues(ps, i);
            if (ipss !is null && ipss.isBatchExhausted(i))
                break;
            rowsAffected ~= ps.executeUpdate();
            if (generatedKeyHolder !is null)
                storeGeneratedKeys(generatedKeyHolder, ps, 1);
        }
        return rowsAffected;
    }

    private void storeGeneratedKeys(KeyHolder generatedKeyHolder, PreparedStatement ps, int rowsExpected)
    {
        auto generatedKeys = generatedKeyHolder.getKeyList();
        auto keys = ps.getGeneratedKeys();
        if (keys is null)
            return;
        scope (exit)
            JdbcUtils.closeResultSet(keys);
        auto rse = new RowMapperResultSetExtractor!(Map!(string, Any))(getColumnMapRowMapper(), rowsExpected);
        foreach (key; rse.extractData(keys).toArray())
            generatedKeys.add(key);
    }

    //-------------------------------------------------------------------------
    // Implementation hooks and helper methods

    /// Create a new `RowMapper` for reading columns as key-value pairs.
    protected RowMapper!(Map!(string, Any)) getColumnMapRowMapper()
    {
        return new ColumnMapRowMapper;
    }

    /// Create a new `RowMapper` for reading result objects from a single column (R4).
    protected RowMapper!T getSingleColumnRowMapper(T)()
    {
        return new SingleColumnRowMapper!T;
    }

    /// Create a `Map` instance to be used as the results map.
    protected Map!(string, Any) createResultsMap()
    {
        return new LinkedHashMap!(string, Any);
    }

    /// Prepare the given JDBC `Statement` (or `PreparedStatement`), applying statement settings such as fetch
    /// size, max rows, and query timeout.
    protected void applyStatementSettings(Statement stmt)
    {
        if (fetchSize != -1)
            stmt.setFetchSize(fetchSize);
        if (maxRows != -1)
            stmt.setMaxRows(maxRows);
        DataSourceUtils.applyTimeout(stmt, getDataSource(), queryTimeout);
    }

    /// Create a new arg-based `PreparedStatementSetter` using the args passed in.
    protected PreparedStatementSetter newArgPreparedStatementSetter(Any[] args)
    {
        return new ArgumentPreparedStatementSetter(args);
    }

    /// Create a new arg-type-based `PreparedStatementSetter` using the args and types passed in.
    protected PreparedStatementSetter newArgTypePreparedStatementSetter(Any[] args, int[] argTypes)
    {
        return new ArgumentTypePreparedStatementSetter(args, argTypes);
    }

    /// Handle warnings before propagating a primary `SQLException` from executing the given statement.
    protected void handleWarnings(Statement stmt, SQLException ex)
    {
        try
            handleWarnings(stmt);
        catch (SQLWarningException nonIgnoredWarning)
            ex.setNextException(nonIgnoredWarning.getSQLWarning());
        catch (SQLException warningsEx)
            logger.debug_("Failed to retrieve warnings", warningsEx);
        catch (Exception warningsEx)
            logger.debug_("Failed to process warnings", warningsEx);
    }

    /// Handle the warnings for the given JDBC `Statement`, if any. Throws `SQLWarningException` if not ignoring
    /// warnings.
    protected void handleWarnings(Statement stmt)
    {
        if (isIgnoreWarnings())
        {
            if (logger.isDebugEnabled())
            {
                for (auto warningToLog = stmt.getWarnings(); warningToLog !is null; warningToLog = warningToLog
                        .getNextWarning())
                {
                    const code = decimal(warningToLog.getErrorCode());
                    logger.debug_("SQLWarning ignored: SQL state '" ~ warningToLog.getSQLState()
                            ~ "', error code '" ~ code ~ "', message [" ~ warningToLog.msg ~ "]");
                }
            }
        }
        else
            handleWarnings(stmt.getWarnings());
    }

    /// Throw an `SQLWarningException` if encountering an actual warning.
    protected void handleWarnings(SQLWarning warning)
    {
        if (warning !is null)
            throw new SQLWarningException("Warning not ignored", warning);
    }

    /// Translate the given `SQLException` into a generic `DataAccessException`.
    protected DataAccessException translateException(string task, string sql, SQLException ex)
    {
        auto dae = getExceptionTranslator().translate(task, sql, ex);
        return dae !is null ? dae : new UncategorizedSQLException(task, sql, ex);
    }

    private static string getSql(Object obj)
    {
        auto provider = cast(SqlProvider) obj;
        return provider !is null ? provider.getSql() : null;
    }

    private static T result(T)(T value)
    {
        if (value is null)
            throw new IllegalStateException("No result");
        return value;
    }

    // The generic operations of JdbcOperations, visible beside this class's overrides.
    alias execute = JdbcOperations.execute;
    alias query = JdbcOperations.query;
    alias queryForObject = JdbcOperations.queryForObject;
    alias queryForMap = JdbcOperations.queryForMap;

    /// `JdbcOperations.queryForList!T`, declared here so that explicit instantiation finds it beside this class's
    /// overrides.
    List!T queryForList(T, Args...)(string sql, Args args)
    {
        return query(sql, newArgPreparedStatementSetter(argumentArray(args)),
                new RowMapperResultSetExtractor!T(new SingleColumnRowMapper!T, 0, maxRows));
    }

    /// ditto
    List!T queryForList(T)(string sql, Any[] args, int[] argTypes)
    {
        return query(sql, newArgTypePreparedStatementSetter(args, argTypes),
                new RowMapperResultSetExtractor!T(new SingleColumnRowMapper!T, 0, maxRows));
    }

    alias update = JdbcOperations.update;
    alias batchUpdate = JdbcOperations.batchUpdate;
}

/// The setter of `batchUpdate(String, List<Object[]>, int[])`.
private final class ArgsBatchSetter : BatchPreparedStatementSetter
{
    private Any[][] rows;
    private int[] argTypes;

    this(Any[][] batchArgs, int[] argTypes)
    {
        rows = batchArgs;
        this.argTypes = argTypes;
    }

    override void setValues(PreparedStatement ps, int i)
    {
        foreach (index, value; rows[i])
        {
            const colIndex = cast(int) index + 1;
            if (auto object = value.isNull ? null : value.asObject())
            {
                if (auto paramValue = cast(SqlParameterValue) object)
                {
                    StatementCreatorUtils.setParameterValue(ps, colIndex, paramValue, paramValue.getValue());
                    continue;
                }
            }
            const colType = argTypes.length < colIndex ? SqlTypeValue.TYPE_UNKNOWN : argTypes[colIndex - 1];
            StatementCreatorUtils.setParameterValue(ps, colIndex, colType, value);
        }
    }

    override int getBatchSize()
    {
        return cast(int) rows.length;
    }
}

private string decimal(long value)
{
    import flint.engine.aot.text : decimal;

    return decimal(value);
}
