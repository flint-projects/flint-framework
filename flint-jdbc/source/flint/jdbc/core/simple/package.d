// Ported from spring-framework v7.1.0: spring-jdbc/src/main/java/org/springframework/jdbc/core/simple/JdbcClient.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: DefaultJdbcClient.java.

/++
`org.springframework.jdbc.core.simple`: `JdbcClient`, the fluent facade over `JdbcTemplate` and
`NamedParameterJdbcTemplate` (ADR-030).

```d
auto names = client.sql("SELECT name FROM owners WHERE city = :city").param("city", "Madison")
    .query!string().list();
```

Parameters are `Any` (R7); `Class<T>` is a template parameter (R4): `query!T()` maps a single column for a scalar or
string `T`, and an object through its Flint AOT descriptor once `SimplePropertyRowMapper` lands, which is not yet the
case. Callbacks also accept delegates (R9). `rowSet()` and `stream()` are deferred to Phase 2 with their
`JdbcTemplate` counterparts. `SimpleJdbcInsert` follows with table metadata.
+/
module flint.jdbc.core.simple;

import flint.dao.support : DataAccessUtils;
import flint.engine.aot.any : Any;
import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.java.sql : ResultSet;
import flint.java.util : ArrayList, LinkedHashSet, List, Map, Optional, Set;
import flint.javax.sql : DataSource;
import flint.jdbc.core : ColumnMapRowMapper, JdbcOperations, JdbcTemplate, PreparedStatementCreator,
    PreparedStatementCreatorFactory, ResultSetExtractor, ResultSetReader,
    RowCallbackHandler, RowMapper, RowMapperResultSetExtractor,
    SingleColumnRowMapper, SqlParameterValue, rowCallbackHandler, rowMapper;
import flint.jdbc.core.namedparam : MapSqlParameterSource, NamedParameterJdbcOperations,
    NamedParameterJdbcTemplate, SqlParameterSource;
import flint.jdbc.support : JdbcAccessor, KeyHolder;

@safe:

/++
A fluent `JdbcClient` with common JDBC query and update operations, supporting JDBC-style positional as well as
Spring-style named parameters with a convenient unified facade for JDBC `PreparedStatement` execution.
+/
interface JdbcClient
{
    /// The starting point for any JDBC operation: a custom provided SQL statement.
    StatementSpec sql(string sql);

    /// Create a `JdbcClient` for the given `DataSource`.
    static JdbcClient create(DataSource dataSource)
    {
        return new DefaultJdbcClient(dataSource);
    }

    /// Create a `JdbcClient` for the given `JdbcOperations` delegate, typically a `JdbcTemplate`.
    static JdbcClient create(JdbcOperations jdbcTemplate)
    {
        return new DefaultJdbcClient(jdbcTemplate);
    }

    /// Create a `JdbcClient` for the given `NamedParameterJdbcOperations` delegate, typically a
    /// `NamedParameterJdbcTemplate`.
    static JdbcClient create(NamedParameterJdbcOperations jdbcTemplate)
    {
        return new DefaultJdbcClient(jdbcTemplate);
    }

    /// A statement specification for parameter bindings and query/update execution.
    interface StatementSpec
    {
        /// Apply the given fetch size to any subsequent query statement.
        StatementSpec withFetchSize(int fetchSize);

        /// Apply the given maximum number of rows to any subsequent query statement.
        StatementSpec withMaxRows(int maxRows);

        /// Apply the given query timeout to any subsequent query statement.
        StatementSpec withQueryTimeout(int queryTimeout);

        /// Bind a positional JDBC statement parameter for "?" placeholder resolution by implicit order of
        /// parameter value registration.
        StatementSpec param(Any value);

        /// Bind a positional JDBC statement parameter for "?" placeholder resolution by explicit JDBC index.
        StatementSpec param(int jdbcIndex, Any value);

        /// ditto, with an SQL type from `flint.java.sql.Types`.
        StatementSpec param(int jdbcIndex, Any value, int sqlType);

        /// Bind a named statement parameter for ":x" placeholder resolution, with each "x" name matching a ":x"
        /// placeholder in the SQL statement.
        StatementSpec param(string name, Any value);

        /// ditto, with an SQL type.
        StatementSpec param(string name, Any value, int sqlType);

        /// Bind a list of positional parameters for "?" placeholder resolution.
        StatementSpec params(Any[] values);

        /// Bind named statement parameters for ":x" placeholder resolution.
        StatementSpec params(Map!(string, Any) paramMap);

        /// Bind named statement parameters for ":x" placeholder resolution from a `SqlParameterSource`.
        StatementSpec paramSource(SqlParameterSource namedParamSource);

        /// Proceed towards execution of a query, with several result options available in the returned query
        /// specification.
        ResultQuerySpec query();

        /// Execute a query with the provided SQL statement, processing each row with the given callback.
        void query(RowCallbackHandler rch);

        /// Erased form of `query(ResultSetExtractor)`: read the `ResultSet` with the given delegate.
        void query(ResultSetReader extractor);

        /// Execute the provided SQL statement as an update.
        int update();

        /// Execute the provided SQL statement as an update, retrieving the generated keys.
        int update(KeyHolder generatedKeyHolder);

        /// Execute the provided SQL statement as an update, retrieving the generated keys of the given columns.
        int update(KeyHolder generatedKeyHolder, string[] keyColumnNames...);

        /// Proceed towards execution of a batch update.
        BatchSpec batch();

        // Typed façades (R7, R9, R4).

        /// Bind a positional parameter, any D value (R7).
        StatementSpec param(T)(T value) if (!is(T == Any))
        {
            return param(toAny(value));
        }

        /// Bind a positional parameter by JDBC index, any D value (R7).
        StatementSpec param(T)(int jdbcIndex, T value) if (!is(T == Any))
        {
            return param(jdbcIndex, toAny(value));
        }

        /// Bind a named parameter, any D value (R7).
        StatementSpec param(T)(string name, T value) if (!is(T == Any))
        {
            return param(name, toAny(value));
        }

        /// Bind a named parameter with an SQL type, any D value (R7).
        StatementSpec param(T)(string name, T value, int sqlType) if (!is(T == Any))
        {
            return param(name, toAny(value), sqlType);
        }

        /// Bind positional parameters (Java's `Object...`, R7).
        StatementSpec params(Args...)(Args values)
                if (Args.length != 1 || (!is(Args[0] : Any[]) && !is(Args[0] : Map!(string, Any))))
        {
            auto array = new Any[Args.length];
            static foreach (index; 0 .. Args.length)
                array[index] = toAny(values[index]);
            return params(array);
        }

        /// Proceed towards execution of a mapped query, with several options available in the returned query
        /// specification.
        MappedQuerySpec!T query(T)(RowMapper!T rowMapper)
        {
            return new DefaultMappedQuerySpec!T(this, rowMapper);
        }

        /// ditto, with a delegate (R9).
        MappedQuerySpec!T query(T)(T delegate(ResultSet, int) @safe mapper)
        {
            return query(.rowMapper(mapper));
        }

        /// Proceed towards execution of a mapped query for `T` (Java's `Class<T>`, R4). A scalar or string `T` maps
        /// the single column.
        MappedQuerySpec!T query(T)() if (isSimple!T)
        {
            return query(new SingleColumnRowMapper!T);
        }

        /// Execute a query with the provided SQL statement, processing the entire `ResultSet` with the given
        /// extractor.
        T query(T)(ResultSetExtractor!T rse)
        {
            T result;
            bool extracted;
            query(ResultSetReader((ResultSet rs) { result = rse.extractData(rs); extracted = true; }));
            if (!extracted)
                throw new IllegalStateException("No result from ResultSetExtractor");
            return result;
        }

        /// Execute a query, processing each row with a delegate (R9).
        final void query(void delegate(ResultSet) @safe rch)
        {
            query(rowCallbackHandler(rch));
        }
    }

    /// A specification for batch updates.
    interface BatchSpec
    {
        /// Add a batch entry with positional parameters.
        BatchSpec entry(Any[] values);

        /// Add a batch entry with named parameters.
        BatchSpec entry(Map!(string, Any) paramMap);

        /// Add a batch entry configured by a delegate (Java's `Consumer<BatchEntry>`, R9).
        BatchSpec entry(scope void delegate(BatchEntry) @safe entryConsumer);

        /// Add batch entries from parameter sources.
        BatchSpec entries(SqlParameterSource[] namedParamObjects...);

        /// Execute the batch update.
        int[] update();

        /// Execute the batch update, retrieving the generated keys.
        int[] update(KeyHolder generatedKeyHolder);

        /// Execute the batch update, retrieving the generated keys of the given columns.
        int[] update(KeyHolder generatedKeyHolder, string[] keyColumnNames...);
    }

    /// A batch entry for parameter bindings.
    interface BatchEntry
    {
        /// Bind a positional parameter by implicit order.
        BatchEntry param(Any value);

        /// Bind a positional parameter by explicit JDBC index.
        BatchEntry param(int jdbcIndex, Any value);

        /// ditto, with an SQL type.
        BatchEntry param(int jdbcIndex, Any value, int sqlType);

        /// Bind a named parameter.
        BatchEntry param(string name, Any value);

        /// ditto, with an SQL type.
        BatchEntry param(string name, Any value, int sqlType);

        /// Bind named parameters from a `SqlParameterSource`.
        BatchEntry paramSource(SqlParameterSource namedParamSource);

        /// Bind a positional parameter, any D value (R7).
        BatchEntry param(T)(T value) if (!is(T == Any))
        {
            return param(toAny(value));
        }

        /// Bind a named parameter, any D value (R7).
        BatchEntry param(T)(string name, T value) if (!is(T == Any))
        {
            return param(name, toAny(value));
        }
    }

    /// A specification for simple result queries.
    interface ResultQuerySpec
    {
        /// Retrieve the result as a list of rows, retaining the order from the original database result.
        List!(Map!(string, Any)) listOfRows();

        /// Retrieve a single row result. Throws `IncorrectResultSizeDataAccessException` if not exactly one row.
        Map!(string, Any) singleRow();

        /// Retrieve a single column result, retaining the order from the original database result.
        List!Any singleColumn();

        /// Retrieve a single value result. Throws if not exactly one row.
        Any singleValue();

        /// Retrieve a single value result, if available, as an `Optional` handle.
        Optional!Any optionalValue();

        /// The Java default bodies.
        mixin template Defaults()
        {
            /// Default: the required single result of `singleColumn()`.
            Any singleValue()
            {
                return DataAccessUtils.requiredSingleResult(singleColumn());
            }

            /// Default: the optional result of `singleColumn()`.
            Optional!Any optionalValue()
            {
                auto column = singleColumn().toArray();
                if (column.length > 1)
                    DataAccessUtils.requiredSingleResult(column);
                return column.length == 1 && !column[0].isNull ? Optional!Any.of(column[0]) : Optional!Any.empty();
            }
        }
    }

    /// A specification for RowMapper-mapped queries.
    interface MappedQuerySpec(T)
    {
        /// Retrieve the result as a pre-resolved list of mapped objects, retaining the order from the original
        /// database result.
        List!T list();

        /// Retrieve the result as an order-preserving set of mapped objects.
        Set!T set();

        /// Retrieve a single result as a required object instance. Throws `IncorrectResultSizeDataAccessException`
        /// if not exactly one row.
        T single();

        /// Retrieve a single result, if available, as an `Optional` handle.
        Optional!T optional();
    }
}

/// Whether `T` maps from a single column: Java's `BeanUtils.isSimpleProperty`.
private enum bool isSimple(T) = __traits(isArithmetic, T) || is(T : const(char)[]) || is(T == Any)
    || is(T : const(ubyte)[]);

private Any toAny(T)(T value)
{
    static if (is(T == Any))
        return value;
    else static if (is(T == typeof(null)))
        return Any.init;
    else static if (is(T : Object))
        return value is null ? Any.init : Any.ofObject(value, typeid(value).name);
    else
        return Any.of(value);
}

private Any parameterValueAny(SqlParameterValue value)
{
    return Any.ofObject(value, typeid(SqlParameterValue).name);
}

/// A mapped query over a statement specification's erased `query(ResultSetReader)`.
private final class DefaultMappedQuerySpec(T) : JdbcClient.MappedQuerySpec!T
{
    private JdbcClient.StatementSpec statement;
    private RowMapper!T rowMapper;

    this(JdbcClient.StatementSpec statement, RowMapper!T rowMapper)
    {
        this.statement = statement;
        this.rowMapper = rowMapper;
    }

    override List!T list()
    {
        List!T result;
        // The statement's maxRows is applied by the driver (Statement.setMaxRows).
        auto extractor = new RowMapperResultSetExtractor!T(rowMapper, 0, -1);
        statement.query(ResultSetReader((ResultSet rs) { result = extractor.extractData(rs); }));
        return result;
    }

    override Set!T set()
    {
        auto result = new LinkedHashSet!T;
        foreach (element; list().toArray())
            result.add(element);
        return result;
    }

    override T single()
    {
        return DataAccessUtils.requiredSingleResult(list());
    }

    override Optional!T optional()
    {
        auto values = list().toArray();
        if (values.length > 1)
            DataAccessUtils.requiredSingleResult(values);
        static if (is(T == class) || is(T == interface))
            return values.length == 1 && values[0]!is null ? Optional!T.of(values[0]) : Optional!T.empty();
        else
            return values.length == 1 ? Optional!T.of(values[0]) : Optional!T.empty();
    }
}

/// The default implementation of `JdbcClient`, as created by the static factory methods.
final class DefaultJdbcClient : JdbcClient
{
    private NamedParameterJdbcOperations namedParamOps;

    /// Create a client for the given `DataSource`.
    this(DataSource dataSource)
    {
        this(new JdbcTemplate(dataSource));
    }

    /// Create a client for the given `JdbcOperations`.
    this(JdbcOperations jdbcTemplate)
    {
        this(new NamedParameterJdbcTemplate(jdbcTemplate));
    }

    /// Create a client for the given `NamedParameterJdbcOperations`.
    this(NamedParameterJdbcOperations jdbcTemplate)
    {
        if (jdbcTemplate is null)
            throw new IllegalArgumentException("NamedParameterJdbcTemplate must not be null");
        namedParamOps = jdbcTemplate;
    }

    override JdbcClient.StatementSpec sql(string sql)
    {
        return new DefaultStatementSpec(sql, namedParamOps);
    }
}

private final class DefaultStatementSpec : JdbcClient.StatementSpec
{
    private string sql;
    private JdbcOperations classicOps;
    private NamedParameterJdbcOperations namedParamOps;
    private JdbcTemplate customTemplate;
    private Any[] indexedParams;
    private MapSqlParameterSource namedParams;
    private SqlParameterSource namedParamSource;

    this(string sql, NamedParameterJdbcOperations namedParamOps)
    {
        this.sql = sql;
        classicOps = namedParamOps.getJdbcOperations();
        this.namedParamOps = namedParamOps;
        namedParams = new MapSqlParameterSource;
        namedParamSource = namedParams;
    }

    private JdbcTemplate enforceCustomTemplate()
    {
        if (customTemplate is null)
        {
            auto original = cast(JdbcAccessor) classicOps;
            if (original is null)
            {
                const name = typeid(cast(Object) classicOps).name;
                throw new IllegalStateException(
                        "Needs to be bound to a JdbcAccessor for custom settings support: " ~ name);
            }
            customTemplate = new JdbcTemplate(original);
            classicOps = customTemplate;
            auto originalNamedParam = cast(NamedParameterJdbcTemplate) namedParamOps;
            namedParamOps = originalNamedParam !is null ? new NamedParameterJdbcTemplate(originalNamedParam,
                    customTemplate) : new NamedParameterJdbcTemplate(customTemplate);
        }
        return customTemplate;
    }

    override JdbcClient.StatementSpec withFetchSize(int fetchSize)
    {
        enforceCustomTemplate().setFetchSize(fetchSize);
        return this;
    }

    override JdbcClient.StatementSpec withMaxRows(int maxRows)
    {
        enforceCustomTemplate().setMaxRows(maxRows);
        return this;
    }

    override JdbcClient.StatementSpec withQueryTimeout(int queryTimeout)
    {
        enforceCustomTemplate().setQueryTimeout(queryTimeout);
        return this;
    }

    override JdbcClient.StatementSpec param(Any value)
    {
        validateIndexedParamValue(value);
        indexedParams ~= value;
        return this;
    }

    override JdbcClient.StatementSpec param(int jdbcIndex, Any value)
    {
        addIndexedParam(indexedParams, jdbcIndex, value);
        return this;
    }

    override JdbcClient.StatementSpec param(int jdbcIndex, Any value, int sqlType)
    {
        return param(jdbcIndex, parameterValueAny(new SqlParameterValue(sqlType, value)));
    }

    override JdbcClient.StatementSpec param(string name, Any value)
    {
        namedParams.addValue(name, value);
        return this;
    }

    override JdbcClient.StatementSpec param(string name, Any value, int sqlType)
    {
        namedParams.addValue(name, value, sqlType);
        return this;
    }

    override JdbcClient.StatementSpec params(Any[] values)
    {
        indexedParams ~= values;
        return this;
    }

    override JdbcClient.StatementSpec params(Map!(string, Any) paramMap)
    {
        namedParams.addValues(paramMap);
        return this;
    }

    override JdbcClient.StatementSpec paramSource(SqlParameterSource namedParamSource)
    {
        this.namedParamSource = namedParamSource;
        return this;
    }

    override JdbcClient.ResultQuerySpec query()
    {
        return new DefaultResultQuerySpec(this);
    }

    override void query(RowCallbackHandler rch)
    {
        if (useNamedParams())
            namedParamOps.query(sql, namedParamSource, rch);
        else
            classicOps.query(statementCreatorForIndexedParams(), rch);
    }

    override void query(ResultSetReader extractor)
    {
        if (useNamedParams())
            namedParamOps.query(sql, namedParamSource, extractor);
        else
            classicOps.query(statementCreatorForIndexedParams(), null, extractor);
    }

    override int update()
    {
        return useNamedParams() ? namedParamOps.update(sql,
                namedParamSource) : classicOps.update(statementCreatorForIndexedParams());
    }

    override int update(KeyHolder generatedKeyHolder)
    {
        return useNamedParams() ? namedParamOps.update(sql, namedParamSource,
                generatedKeyHolder) : classicOps.update(statementCreatorForIndexedParamsWithKeys(null),
                generatedKeyHolder);
    }

    override int update(KeyHolder generatedKeyHolder, string[] keyColumnNames...)
    {
        auto columns = keyColumnNames.dup;
        return useNamedParams() ? namedParamOps.update(sql, namedParamSource, generatedKeyHolder,
                columns) : classicOps.update(statementCreatorForIndexedParamsWithKeys(columns), generatedKeyHolder);
    }

    override JdbcClient.BatchSpec batch()
    {
        return new DefaultBatchSpec(this);
    }

    private bool useNamedParams()
    {
        const hasNamedParams = namedParams.hasValues() || namedParamSource !is namedParams;
        if (hasNamedParams && indexedParams.length)
            throw new IllegalStateException("Configure either named or indexed parameters, not both");
        if (namedParams.hasValues() && namedParamSource !is namedParams)
            throw new IllegalStateException(
                    "Configure either individual named parameters or a SqlParameterSource, not both");
        return hasNamedParams;
    }

    private PreparedStatementCreator statementCreatorForIndexedParams()
    {
        return new PreparedStatementCreatorFactory(sql).newPreparedStatementCreator(indexedParams);
    }

    private PreparedStatementCreator statementCreatorForIndexedParamsWithKeys(string[] keyColumnNames)
    {
        auto pscf = new PreparedStatementCreatorFactory(sql);
        if (keyColumnNames !is null)
            pscf.setGeneratedKeysColumnNames(keyColumnNames);
        else
            pscf.setReturnGeneratedKeys(true);
        return pscf.newPreparedStatementCreator(indexedParams);
    }

    alias query = JdbcClient.StatementSpec.query;
    alias param = JdbcClient.StatementSpec.param;
    alias params = JdbcClient.StatementSpec.params;
}

private void addIndexedParam(ref Any[] indexedParams, int jdbcIndex, Any value)
{
    if (jdbcIndex < 1)
        throw new IllegalArgumentException("Invalid JDBC index: needs to start at 1");
    validateIndexedParamValue(value);
    const index = jdbcIndex - 1;
    if (index >= indexedParams.length)
        indexedParams.length = index + 1;
    indexedParams[index] = value;
}

private void validateIndexedParamValue(Any value)
{
    if (value.holds!(Any[]))
        throw new IllegalArgumentException("Invalid positional parameter value of type Iterable ("
                ~ value.typeName ~ "): Parameter expansion is only supported with named parameters.");
}

private final class DefaultResultQuerySpec : JdbcClient.ResultQuerySpec
{
    private DefaultStatementSpec statement;

    this(DefaultStatementSpec statement)
    {
        this.statement = statement;
    }

    mixin JdbcClient.ResultQuerySpec.Defaults;

    override List!(Map!(string, Any)) listOfRows()
    {
        return statement.query(new ColumnMapRowMapper).list();
    }

    override Map!(string, Any) singleRow()
    {
        return statement.query(new ColumnMapRowMapper).single();
    }

    override List!Any singleColumn()
    {
        return statement.query(new SingleColumnRowMapper!Any).list();
    }
}

private final class DefaultBatchSpec : JdbcClient.BatchSpec
{
    private DefaultStatementSpec statement;
    private Any[][] indexedBatch;
    private SqlParameterSource[] namedBatch;
    private bool decided, usingNamedParams;

    this(DefaultStatementSpec statement)
    {
        this.statement = statement;
    }

    override JdbcClient.BatchSpec entry(Any[] values)
    {
        auto entry = new DefaultBatchEntry;
        entry.indexedParams = values.dup;
        addEntry(entry);
        return this;
    }

    override JdbcClient.BatchSpec entry(Map!(string, Any) paramMap)
    {
        auto entry = new DefaultBatchEntry;
        entry.namedParams.addValues(paramMap);
        addEntry(entry);
        return this;
    }

    override JdbcClient.BatchSpec entry(scope void delegate(JdbcClient.BatchEntry) @safe entryConsumer)
    {
        auto entry = new DefaultBatchEntry;
        entryConsumer(entry);
        addEntry(entry);
        return this;
    }

    override JdbcClient.BatchSpec entries(SqlParameterSource[] namedParamObjects...)
    {
        foreach (source; namedParamObjects)
            addNamedEntry(source);
        return this;
    }

    private void addEntry(DefaultBatchEntry entry)
    {
        if (entry.useNamedParams())
            addNamedEntry(entry.namedParamSource);
        else
        {
            checkMode(false);
            indexedBatch ~= entry.indexedParams;
        }
    }

    private void addNamedEntry(SqlParameterSource source)
    {
        checkMode(true);
        namedBatch ~= source;
    }

    private void checkMode(bool named)
    {
        if (decided && usingNamedParams != named)
            throw new IllegalStateException(
                    "Configure either named or indexed parameters for each batch entry, " ~ "not a mix of both");
        decided = true;
        usingNamedParams = named;
    }

    override int[] update()
    {
        return usingNamedParams ? statement.namedParamOps.batchUpdate(statement.sql,
                namedBatch) : statement.classicOps.batchUpdate(statement.sql, indexedBatch);
    }

    override int[] update(KeyHolder generatedKeyHolder)
    {
        return doUpdate(generatedKeyHolder, null);
    }

    override int[] update(KeyHolder generatedKeyHolder, string[] keyColumnNames...)
    {
        return doUpdate(generatedKeyHolder, keyColumnNames.dup);
    }

    private int[] doUpdate(KeyHolder generatedKeyHolder, string[] keyColumnNames)
    {
        if (usingNamedParams)
            return keyColumnNames !is null ? statement.namedParamOps.batchUpdate(statement.sql,
                    namedBatch, generatedKeyHolder,
                    keyColumnNames) : statement.namedParamOps.batchUpdate(statement.sql,
                    namedBatch, generatedKeyHolder);
        if (indexedBatch.length == 0)
            return [];
        auto pscf = new PreparedStatementCreatorFactory(statement.sql);
        if (keyColumnNames !is null)
            pscf.setGeneratedKeysColumnNames(keyColumnNames);
        else
            pscf.setReturnGeneratedKeys(true);
        auto rows = indexedBatch;
        return statement.classicOps.batchUpdate(pscf.newPreparedStatementCreator(rows[0]),
                new IndexedBatchSetter(pscf, rows), generatedKeyHolder);
    }
}

private final class IndexedBatchSetter : imported!"flint.jdbc.core".BatchPreparedStatementSetter
{
    private PreparedStatementCreatorFactory pscf;
    private Any[][] rows;

    this(PreparedStatementCreatorFactory pscf, Any[][] rows)
    {
        this.pscf = pscf;
        this.rows = rows;
    }

    override void setValues(imported!"flint.java.sql".PreparedStatement ps, int i)
    {
        // rows[0] is already set by pscf.newPreparedStatementCreator().
        if (i > 0)
            pscf.newPreparedStatementSetter(rows[i]).setValues(ps);
    }

    override int getBatchSize()
    {
        return cast(int) rows.length;
    }
}

private final class DefaultBatchEntry : JdbcClient.BatchEntry
{
    private Any[] indexedParams;
    private MapSqlParameterSource namedParams;
    private SqlParameterSource namedParamSource;

    this()
    {
        namedParams = new MapSqlParameterSource;
        namedParamSource = namedParams;
    }

    override JdbcClient.BatchEntry param(Any value)
    {
        validateIndexedParamValue(value);
        indexedParams ~= value;
        return this;
    }

    override JdbcClient.BatchEntry param(int jdbcIndex, Any value)
    {
        addIndexedParam(indexedParams, jdbcIndex, value);
        return this;
    }

    override JdbcClient.BatchEntry param(int jdbcIndex, Any value, int sqlType)
    {
        return param(jdbcIndex, parameterValueAny(new SqlParameterValue(sqlType, value)));
    }

    override JdbcClient.BatchEntry param(string name, Any value)
    {
        namedParams.addValue(name, value);
        return this;
    }

    override JdbcClient.BatchEntry param(string name, Any value, int sqlType)
    {
        namedParams.addValue(name, value, sqlType);
        return this;
    }

    override JdbcClient.BatchEntry paramSource(SqlParameterSource namedParamSource)
    {
        this.namedParamSource = namedParamSource;
        return this;
    }

    bool useNamedParams()
    {
        const hasNamedParams = namedParams.hasValues() || namedParamSource !is namedParams;
        if (hasNamedParams && indexedParams.length)
            throw new IllegalStateException("Configure either named or indexed parameters, not both");
        return hasNamedParams;
    }

    alias param = JdbcClient.BatchEntry.param;
}
