/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/JdbcTemplateTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: this file holds the `JdbcTemplateTests` cases that jdbc_template.d does not already
cover (`updateCount`, `batchUpdate`, `batchUpdateWithPreparedStatement` and `batchUpdateWithListOfObjectArrays` live
there). Hand-written `BlackHole` fakes replace the Mockito mocks: they log each call, so `verify(ps).close()` becomes
a count in the log, and scripted values stand in for `given(...).willReturn(...)` (the last value repeats, as
Mockito's does). `@BeforeEach setup` becomes `setup`, which returns the wired fixture. Java's `Object...` and
`Object[]` arguments are `Any` values; `query(sql, Object[], rch)` is `query(sql, rch, Any[])`, and a
`SqlParameterValue` argument is an `Any` holding the object. `ConnectionCallback` lambdas are classes. Cases that
need `CallableStatement`, `SingleConnectionDataSource`, `SQLErrorCodeSQLExceptionTranslator`,
`AbstractInterruptibleBatchPreparedStatementSetter`, `AggregatedBatchUpdateException`, `queryForStream` or
`setObject` with a scale wait behind version gates, as do the behaviours that differ from Spring.
+/
module flint.jdbc.jdbc_template_upstream_tests;

import flint.dao : DataAccessException, InvalidDataAccessApiUsageException;
import flint.engine.aot.any : Any;
import flint.java.lang : RuntimeException;
import flint.java.sql : BatchUpdateException, Connection, DatabaseMetaData, PreparedStatement,
    ResultSet, ResultSetMetaData, SQLException, SQLWarning, Statement, Types;
import flint.java.util : List, Map;
import flint.javax.sql : DataSource;
import flint.jdbc : BadSqlGrammarException, CannotGetJdbcConnectionException, SQLWarningException,
    UncategorizedSQLException;
import flint.jdbc.core;
import flint.jdbc.support : GeneratedKeyHolder, KeyHolder, SQLStateSQLExceptionTranslator;
import std.conv : to;
import std.typecons : BlackHole, Nullable, nullable;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fakes

/// The calls the fakes saw, in order.
private final class Log
{
    string[] entries;

    size_t count(string entry) const
    {
        size_t n;
        foreach (e; entries)
            if (e == entry)
                ++n;
        return n;
    }

    size_t countPrefix(string prefix) const
    {
        size_t n;
        foreach (e; entries)
            if (e.length >= prefix.length && e[0 .. prefix.length] == prefix)
                ++n;
        return n;
    }
}

/// Mockito's `willReturn(a, b, c)`: each call takes the next value; the last one repeats.
private struct Script(T)
{
    T[] values;
    private size_t taken;

    T next()
    {
        if (values.length == 0)
            return T.init;
        if (taken < values.length)
            return values[taken++];
        return values[$ - 1];
    }
}

private Script!T script(T)(T[] values...)
{
    return Script!T(values.dup);
}

private final class MockResultSetMetaData : BlackHole!ResultSetMetaData
{
    private string[] labels;

    this(string[] labels...)
    {
        this.labels = labels.dup;
    }

    override int getColumnCount()
    {
        return cast(int) labels.length;
    }

    override string getColumnLabel(int column)
    {
        return labels[column - 1];
    }
}

private final class MockResultSet : BlackHole!ResultSet
{
    private Log log;
    private string name;
    Script!bool nextResults;
    Script!string strings;
    Script!Any[int] objects;
    ResultSetMetaData metaData;
    SQLException closeFailure;

    this(Log log, string name)
    {
        this.log = log;
        this.name = name;
    }

    override bool next()
    {
        return nextResults.next();
    }

    override string getString(int)
    {
        return strings.next();
    }

    override Any getObject(int column)
    {
        if (auto values = column in objects)
            return values.next();
        return Any.init;
    }

    override ResultSetMetaData getMetaData()
    {
        return metaData;
    }

    override void close()
    {
        log.entries ~= name ~ ".close";
        if (closeFailure !is null)
            throw closeFailure;
    }
}

/// A `Statement` or `PreparedStatement` mock: `name` ("stmt" or "ps") prefixes its log entries.
private final class MockStatement : BlackHole!PreparedStatement
{
    private Log log;
    private string name;
    Connection connection;
    ResultSet resultSet;
    Script!int updateCounts;
    SQLException updateFailure;
    int[][] batchResults;
    SQLException batchFailure;
    private size_t batches;
    bool[string] executeResults;
    Script!int updateCount;
    SQLWarning warnings;
    Script!ResultSet generatedKeys;
    SQLException closeFailure;

    this(Log log, string name)
    {
        this.log = log;
        this.name = name;
    }

    private void record(string call)
    {
        log.entries ~= name ~ "." ~ call;
    }

    override Connection getConnection()
    {
        return connection;
    }

    override void setInt(int index, int value)
    {
        record("setInt(" ~ index.to!string ~ "," ~ value.to!string ~ ")");
    }

    override void setString(int index, string value)
    {
        record("setString(" ~ index.to!string ~ "," ~ value ~ ")");
    }

    override void setObject(int index, Any value)
    {
        record("setObject(" ~ index.to!string ~ "," ~ value.toString() ~ ")");
    }

    override void setObject(int index, Any value, int sqlType)
    {
        record("setObject(" ~ index.to!string ~ "," ~ value.toString() ~ "," ~ sqlType.to!string ~ ")");
    }

    override void setNull(int index, int sqlType)
    {
        record("setNull(" ~ index.to!string ~ "," ~ sqlType.to!string ~ ")");
    }

    override void setFetchSize(int rows)
    {
        record("setFetchSize(" ~ rows.to!string ~ ")");
    }

    override void setMaxRows(int max)
    {
        record("setMaxRows(" ~ max.to!string ~ ")");
    }

    override void setQueryTimeout(int seconds)
    {
        record("setQueryTimeout(" ~ seconds.to!string ~ ")");
    }

    override ResultSet executeQuery()
    {
        record("executeQuery");
        return resultSet;
    }

    override ResultSet executeQuery(string sql)
    {
        record("executeQuery(" ~ sql ~ ")");
        return resultSet;
    }

    override int executeUpdate()
    {
        record("executeUpdate");
        if (updateFailure !is null)
            throw updateFailure;
        return updateCounts.next();
    }

    override int executeUpdate(string sql)
    {
        record("executeUpdate(" ~ sql ~ ")");
        if (updateFailure !is null)
            throw updateFailure;
        return updateCounts.next();
    }

    override bool execute(string sql)
    {
        record("execute(" ~ sql ~ ")");
        return executeResults.get(sql, false);
    }

    override int getUpdateCount()
    {
        return updateCount.next();
    }

    override void addBatch()
    {
        record("addBatch");
    }

    override void addBatch(string sql)
    {
        record("addBatch(" ~ sql ~ ")");
    }

    override int[] executeBatch()
    {
        record("executeBatch");
        const call = batches++;
        if (call < batchResults.length)
            return batchResults[call];
        if (batchFailure !is null)
            throw batchFailure;
        return batchResults.length ? batchResults[$ - 1] : null;
    }

    override SQLWarning getWarnings()
    {
        return warnings;
    }

    override ResultSet getGeneratedKeys()
    {
        return generatedKeys.next();
    }

    override void close()
    {
        record("close");
        if (closeFailure !is null)
            throw closeFailure;
    }
}

private final class MockDatabaseMetaData : BlackHole!DatabaseMetaData
{
    private string productName;
    private bool batchUpdates;

    this(string productName, bool batchUpdates)
    {
        this.productName = productName;
        this.batchUpdates = batchUpdates;
    }

    override string getDatabaseProductName()
    {
        return productName;
    }

    override bool supportsBatchUpdates()
    {
        return batchUpdates;
    }
}

private final class MockConnection : BlackHole!Connection
{
    private Log log;
    Statement createdStatement;
    PreparedStatement preparedStatement;
    DatabaseMetaData metaData;
    Exception closeFailure;

    this(Log log)
    {
        this.log = log;
    }

    override Statement createStatement()
    {
        return createdStatement;
    }

    override PreparedStatement prepareStatement(string sql)
    {
        log.entries ~= "con.prepareStatement(" ~ sql ~ ")";
        return preparedStatement;
    }

    override DatabaseMetaData getMetaData()
    {
        return metaData;
    }

    version (FlintJdbcCallableStatement)
    {
        MockCallableStatement callableStatement;

        override imported!"flint.java.sql".CallableStatement prepareCall(string sql)
        {
            log.entries ~= "con.prepareCall(" ~ sql ~ ")";
            return callableStatement;
        }
    }

    override void close()
    {
        log.entries ~= "con.close";
        if (closeFailure !is null)
            throw closeFailure;
    }
}

// flint.java.sql has no CallableStatement.
version (FlintJdbcCallableStatement)
{
    private final class MockCallableStatement : BlackHole!(imported!"flint.java.sql".CallableStatement)
    {
        private Log log;
        private string name;
        ResultSet resultSet;
        bool executeResult;
        Script!int updateCount;
        Script!Any[int] objects;

        this(Log log, string name)
        {
            this.log = log;
            this.name = name;
        }

        override bool execute()
        {
            return executeResult;
        }

        override ResultSet getResultSet()
        {
            return resultSet;
        }

        override int getUpdateCount()
        {
            return updateCount.next();
        }

        override Any getObject(int column)
        {
            if (auto values = column in objects)
                return values.next();
            return Any.init;
        }

        override void close()
        {
            log.entries ~= name ~ ".close";
        }
    }
}

private final class MockDataSource : BlackHole!DataSource
{
    Connection connection;
    SQLException failure;

    override Connection getConnection()
    {
        if (failure !is null)
            throw failure;
        return connection;
    }
}

/// The mocks of `JdbcTemplateTests`, wired as its `@BeforeEach setup` stubs them.
private final class Fixture
{
    Log log;
    MockDataSource dataSource;
    MockConnection connection;
    MockStatement statement;
    MockStatement preparedStatement;
    MockResultSet resultSet;
    JdbcTemplate template_;

    this()
    {
        log = new Log;
        dataSource = new MockDataSource;
        connection = new MockConnection(log);
        statement = new MockStatement(log, "stmt");
        preparedStatement = new MockStatement(log, "ps");
        resultSet = new MockResultSet(log, "rs");
        template_ = new JdbcTemplate(dataSource);

        dataSource.connection = connection;
        connection.preparedStatement = preparedStatement;
        statement.connection = connection;
        statement.resultSet = resultSet;
        preparedStatement.resultSet = resultSet;
        preparedStatement.connection = connection;
    }

    size_t count(string entry) const
    {
        return log.count(entry);
    }

    void mockDatabaseMetaData(bool supportsBatchUpdates)
    {
        connection.metaData = new MockDatabaseMetaData("MySQL", supportsBatchUpdates);
    }
}

private Fixture setup()
{
    return new Fixture;
}

private E expectThrows(E : Exception)(scope void delegate() @safe action)
{
    try
        action();
    catch (E ex)
        return ex;
    assert(false, "expected " ~ E.stringof);
}

/// A `PreparedStatementCreator` that binds an id, as upstream's `Dispatcher`.
private final class Dispatcher : PreparedStatementCreator, SqlProvider
{
    private int id;
    private string sql;

    this(int id, string sql)
    {
        this.id = id;
        this.sql = sql;
    }

    override PreparedStatement createPreparedStatement(Connection connection)
    {
        auto ps = connection.prepareStatement(sql);
        ps.setInt(1, id);
        return ps;
    }

    override string getSql()
    {
        return sql;
    }
}

/// A `BatchPreparedStatementSetter` that binds `ids[i]` with `setInt`.
private final class IdSetter : BatchPreparedStatementSetter
{
    private int[] ids;

    this(int[] ids)
    {
        this.ids = ids;
    }

    override void setValues(PreparedStatement ps, int i)
    {
        ps.setInt(1, ids[i]);
    }

    override int getBatchSize()
    {
        return cast(int) ids.length;
    }
}

private Any parameterValue(SqlParameterValue value)
{
    return Any.ofObject(value, typeid(SqlParameterValue).name);
}

// ---------------------------------------------------------------------------------------------------------------
// Tests

@("JdbcTemplateTests.beanProperties")
unittest
{
    auto f = setup();
    assert(f.template_.getDataSource() is f.dataSource, "datasource ok");
    assert(f.template_.isIgnoreWarnings(), "ignores warnings by default");
    f.template_.setIgnoreWarnings(false);
    assert(!f.template_.isIgnoreWarnings(), "can set NOT to ignore warnings");
}

@("JdbcTemplateTests.bogusUpdate")
unittest
{
    auto f = setup();
    enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?";
    enum idParam = 6666;

    // It's because Integers aren't canonical
    auto sqlException = new SQLException("bad update");
    f.preparedStatement.updateFailure = sqlException;

    auto d = new Dispatcher(idParam, sql);
    const ex = expectThrows!UncategorizedSQLException({ f.template_.update(d); });
    assert(ex.getCause() is sqlException);
    assert(f.count("ps.setInt(1,6666)") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") >= 1);
}

private alias JdbcTemplateCallback = void delegate(JdbcTemplate template_, string sql, RowCallbackHandler rch) @safe;

private final class StringHandler : RowCallbackHandler
{
    private string[] list;

    override void processRow(ResultSet rs)
    {
        list ~= rs.getString(1);
    }

    string[] getStrings()
    {
        return list;
    }
}

private enum Nullable!int none = Nullable!int.init;

private void doTestStrings(Nullable!int fetchSize, Nullable!int maxRows, Nullable!int queryTimeout,
        Any argument, scope JdbcTemplateCallback jdbcTemplateCallback)
{
    auto f = setup();
    enum sql = "SELECT FORENAME FROM CUSTMR";
    const string[] results = ["rod", "gary", " portia"];

    f.resultSet.nextResults = script(true, true, true, false);
    f.resultSet.strings = script(results.dup);
    f.connection.createdStatement = f.preparedStatement;

    auto sh = new StringHandler;
    auto template_ = new JdbcTemplate;
    template_.setDataSource(f.dataSource);
    if (!fetchSize.isNull)
        template_.setFetchSize(fetchSize.get);
    if (!maxRows.isNull)
        template_.setMaxRows(maxRows.get);
    if (!queryTimeout.isNull)
        template_.setQueryTimeout(queryTimeout.get);
    jdbcTemplateCallback(template_, sql, sh);

    // Match
    const forenames = sh.getStrings();
    assert(forenames.length == results.length, "same length");
    foreach (i, forename; forenames)
        assert(forename == results[i], "Row " ~ i.to!string ~ " matches");

    if (!fetchSize.isNull)
        assert(f.count("ps.setFetchSize(" ~ fetchSize.get.to!string ~ ")") == 1);
    if (!maxRows.isNull)
        assert(f.count("ps.setMaxRows(" ~ maxRows.get.to!string ~ ")") == 1);
    if (!queryTimeout.isNull)
        assert(f.count("ps.setQueryTimeout(" ~ queryTimeout.get.to!string ~ ")") == 1);
    if (!argument.isNull)
        assert(f.count("ps.setObject(1," ~ argument.toString() ~ ")") == 1);
    assert(f.count("rs.close") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") == 1);
}

@("JdbcTemplateTests.stringsWithStaticSql")
unittest
{
    doTestStrings(none, none, none, Any.init, (template_, sql, rch) { template_.query(sql, rch); });
}

@("JdbcTemplateTests.stringsWithStaticSqlAndFetchSizeAndMaxRows")
unittest
{
    doTestStrings(nullable(10), nullable(20), nullable(30), Any.init, (template_, sql, rch) {
        template_.query(sql, rch);
    });
}

@("JdbcTemplateTests.stringsWithEmptyPreparedStatementSetter")
unittest
{
    doTestStrings(none, none, none, Any.init, (template_, sql, rch) {
        template_.query(sql, cast(PreparedStatementSetter) null, rch);
    });
}

@("JdbcTemplateTests.stringsWithPreparedStatementSetter")
unittest
{
    enum argument = 99;
    doTestStrings(none, none, none, Any.of(argument), (template_, sql, rch) {
        template_.query(sql, preparedStatementSetter((PreparedStatement ps) {
                ps.setObject(1, Any.of(argument));
            }), rch);
    });
}

@("JdbcTemplateTests.stringsWithEmptyPreparedStatementArgs")
unittest
{
    doTestStrings(none, none, none, Any.init, (template_, sql, rch) {
        template_.query(sql, rch, cast(Any[]) null);
    });
}

@("JdbcTemplateTests.stringsWithPreparedStatementArgs")
unittest
{
    enum argument = 99;
    doTestStrings(none, none, none, Any.of(argument), (template_, sql, rch) {
        template_.query(sql, rch, [Any.of(argument)]);
    });
}

// flint.jdbc.datasource has no SingleConnectionDataSource.
version (FlintJdbcSingleConnectionDataSource)
{
    @("JdbcTemplateTests.leaveConnectionOpenOnRequest")
    unittest
    {
        import flint.jdbc.datasource : SingleConnectionDataSource;

        auto f = setup();
        enum sql = "SELECT ID, FORENAME FROM CUSTMR WHERE ID < 3";

        f.resultSet.nextResults = script(false);
        f.connection.createdStatement = f.preparedStatement;
        // if close is called entire test will fail
        f.connection.closeFailure = new RuntimeException();

        auto scf = new SingleConnectionDataSource(f.dataSource.getConnection(), false);
        f.template_ = new JdbcTemplate(scf, false);
        auto rcch = new RowCountCallbackHandler;
        f.template_.query(sql, rcch);

        assert(f.count("rs.close") == 1);
        assert(f.count("ps.close") == 1);
    }
}

// execute(ConnectionCallback) hands the callback the connection itself, not a ConnectionProxy (no runtime proxies).
version (FlintJdbcConnectionCallbackProxy)
{
    @("JdbcTemplateTests.connectionCallback")
    unittest
    {
        import flint.jdbc.datasource : ConnectionProxy;

        auto f = setup();
        final class Callback : ConnectionCallback!string
        {
            override string doInConnection(Connection con)
            {
                auto proxy = cast(ConnectionProxy) con;
                assert(proxy !is null, "a ConnectionProxy");
                assert(proxy.getTargetConnection() is f.connection);
                return "test";
            }
        }

        const result = f.template_.execute(new Callback);
        assert(result == "test");
    }
}

@("JdbcTemplateTests.connectionCallbackWithStatementSettings")
unittest
{
    auto f = setup();
    final class Callback : ConnectionCallback!string
    {
        override string doInConnection(Connection con)
        {
            auto ps = con.prepareStatement("some SQL");
            ps.setFetchSize(10);
            ps.setMaxRows(20);
            ps.close();
            return "test";
        }
    }

    const result = f.template_.execute(new Callback);
    assert(result == "test");
    assert(f.count("ps.setFetchSize(10)") == 1);
    assert(f.count("ps.setMaxRows(20)") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") == 1);
}

@("JdbcTemplateTests.closeConnectionOnRequest")
unittest
{
    auto f = setup();
    enum sql = "SELECT ID, FORENAME FROM CUSTMR WHERE ID < 3";

    f.resultSet.nextResults = script(false);
    f.connection.createdStatement = f.preparedStatement;

    auto rcch = new RowCountCallbackHandler;
    f.template_.query(sql, rcch);

    assert(f.count("rs.close") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") == 1);
}

/// Test that we see a runtime exception come back.
@("JdbcTemplateTests.exceptionComesBack")
unittest
{
    auto f = setup();
    enum sql = "SELECT ID FROM CUSTMR";
    auto runtimeException = new RuntimeException("Expected");

    f.resultSet.nextResults = script(true);
    f.connection.createdStatement = f.preparedStatement;

    const ex = expectThrows!RuntimeException({
        f.template_.query(sql, rowCallbackHandler((ResultSet) { throw runtimeException; }));
    });
    assert(ex.msg == runtimeException.msg);
    assert(f.count("rs.close") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") == 1);
}

/// Test update with static SQL.
@("JdbcTemplateTests.sqlUpdate")
unittest
{
    auto f = setup();
    enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = 4";
    enum rowsAffected = 33;

    f.statement.updateCounts = script(rowsAffected);
    f.connection.createdStatement = f.statement;

    const actualRowsAffected = f.template_.update(sql);
    assert(actualRowsAffected == rowsAffected, "Actual rows affected is correct");
    assert(f.count("stmt.executeUpdate(" ~ sql ~ ")") == 1);
    assert(f.count("stmt.close") == 1);
    assert(f.count("con.close") == 1);
}

/// Test update with dynamic SQL.
@("JdbcTemplateTests.sqlUpdateWithArguments")
unittest
{
    auto f = setup();
    enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ? and PR = ?";
    enum rowsAffected = 33;
    f.preparedStatement.updateCounts = script(rowsAffected);

    const actualRowsAffected = f.template_.update(sql, 4,
            parameterValue(new SqlParameterValue(Types.NUMERIC, 2, Any.of(1.4142f))));
    assert(actualRowsAffected == rowsAffected, "Actual rows affected is correct");
    assert(f.count("ps.setObject(1,4)") == 1);
    // flint.java.sql's PreparedStatement has no setObject(int, Object, int, int): the scale is not passed on.
    version (FlintJdbcSetObjectScale)
        assert(f.count("ps.setObject(2," ~ Any.of(1.4142f).toString() ~ ",2,2)") == 1);
    else
        assert(f.count("ps.setObject(2," ~ Any.of(1.4142f).toString() ~ ",2)") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") == 1);
}

@("JdbcTemplateTests.sqlUpdateEncountersSqlException")
unittest
{
    auto f = setup();
    auto sqlException = new SQLException("bad update");
    enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = 4";

    f.statement.updateFailure = sqlException;
    f.connection.createdStatement = f.statement;

    const ex = expectThrows!DataAccessException({ f.template_.update(sql); });
    assert(ex.getCause() is sqlException);
    assert(f.count("stmt.close") == 1);
    assert(f.count("con.close") >= 1);
}

@("JdbcTemplateTests.sqlUpdateWithThreadConnection")
unittest
{
    auto f = setup();
    enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = 4";
    enum rowsAffected = 33;

    f.statement.updateCounts = script(rowsAffected);
    f.connection.createdStatement = f.statement;

    const actualRowsAffected = f.template_.update(sql);
    assert(actualRowsAffected == rowsAffected, "Actual rows affected is correct");

    assert(f.count("stmt.close") == 1);
    assert(f.count("con.close") == 1);
}

// batchUpdate(String...) translates a BatchUpdateException with a null SQL, not the failed statements ("B; D").
version (FlintJdbcBatchFailureSql)
{
    @("JdbcTemplateTests.batchUpdateWithBatchFailure")
    unittest
    {
        auto f = setup();
        const string[] sql = ["A", "B", "C", "D"];
        f.statement.batchFailure = new BatchUpdateException([
            1L, Statement.EXECUTE_FAILED, 1, Statement.EXECUTE_FAILED
        ]);
        f.mockDatabaseMetaData(true);
        f.connection.createdStatement = f.statement;

        auto template_ = new JdbcTemplate(f.dataSource, false);
        try
            template_.batchUpdate(sql.dup);
        catch (UncategorizedSQLException ex)
            assert(ex.getSql() == "B; D", ex.getSql());
    }
}

@("JdbcTemplateTests.batchUpdateWithNoBatchSupport")
unittest
{
    auto f = setup();
    const string[] sql = [
        "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = 1",
        "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = 2"
    ];

    f.statement.executeResults[sql[0]] = false;
    f.statement.updateCount = script(1, 1);
    f.statement.executeResults[sql[1]] = false;

    f.mockDatabaseMetaData(false);
    f.connection.createdStatement = f.statement;

    auto template_ = new JdbcTemplate(f.dataSource, false);

    const actualRowsAffected = template_.batchUpdate(sql.dup);
    assert(actualRowsAffected.length == 2, "executed 2 updates");

    assert(f.log.countPrefix("stmt.addBatch(") == 0);
    assert(f.count("stmt.close") == 1);
    assert(f.count("con.close") >= 1);
}

@("JdbcTemplateTests.batchUpdateWithNoBatchSupportAndSelect")
unittest
{
    auto f = setup();
    const string[] sql = [
        "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = 1", "SELECT * FROM NOSUCHTABLE"
    ];

    f.statement.executeResults[sql[0]] = false;
    f.statement.updateCount = script(1);
    f.statement.executeResults[sql[1]] = true;
    f.mockDatabaseMetaData(false);
    f.connection.createdStatement = f.statement;

    auto template_ = new JdbcTemplate(f.dataSource, false);
    expectThrows!InvalidDataAccessApiUsageException({ template_.batchUpdate(sql.dup); });
    assert(f.log.countPrefix("stmt.addBatch(") == 0);
    assert(f.count("stmt.close") == 1);
    assert(f.count("con.close") >= 1);
}

@("JdbcTemplateTests.batchUpdateWithPreparedStatementWithEmptyData")
unittest
{
    auto f = setup();
    enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?";
    int[] ids;
    f.preparedStatement.batchResults = [[]];
    f.mockDatabaseMetaData(true);

    auto setter = new IdSetter(ids);
    auto template_ = new JdbcTemplate(f.dataSource, false);

    const actualRowsAffected = template_.batchUpdate(sql, setter);
    assert(actualRowsAffected.length == 0, "executed 0 updates");

    assert(f.count("ps.executeBatch") == 0);
}

@("JdbcTemplateTests.interruptibleBatchUpdate")
unittest
{
    auto f = setup();
    enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?";
    const int[] ids = [100, 200];
    const int[] rowsAffected = [1, 2];

    f.preparedStatement.batchResults = [rowsAffected.dup];
    f.mockDatabaseMetaData(true);

    final class Setter : InterruptibleBatchPreparedStatementSetter
    {
        override void setValues(PreparedStatement ps, int i)
        {
            if (i < ids.length)
                ps.setInt(1, ids[i]);
        }

        override int getBatchSize()
        {
            return 1000;
        }

        override bool isBatchExhausted(int i)
        {
            return i >= ids.length;
        }
    }

    auto template_ = new JdbcTemplate(f.dataSource, false);

    const actualRowsAffected = template_.batchUpdate(sql, new Setter);
    assert(actualRowsAffected.length == 2, "executed 2 updates");
    assert(actualRowsAffected[0] == rowsAffected[0]);
    assert(actualRowsAffected[1] == rowsAffected[1]);

    assert(f.count("ps.addBatch") == 2);
    assert(f.count("ps.setInt(1,100)") == 1);
    assert(f.count("ps.setInt(1,200)") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") >= 1);
}

// flint.jdbc.core has no AbstractInterruptibleBatchPreparedStatementSetter (core.support).
version (FlintJdbcAbstractInterruptibleBatchSetter)
{
    @("JdbcTemplateTests.interruptibleBatchUpdateWithBaseClass")
    unittest
    {
        import flint.jdbc.core.support : AbstractInterruptibleBatchPreparedStatementSetter;

        auto f = setup();
        enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?";
        const int[] ids = [100, 200];
        const int[] rowsAffected = [1, 2];

        f.preparedStatement.batchResults = [rowsAffected.dup];
        f.mockDatabaseMetaData(true);

        final class Setter : AbstractInterruptibleBatchPreparedStatementSetter
        {
            protected override bool setValuesIfAvailable(PreparedStatement ps, int i)
            {
                if (i < ids.length)
                {
                    ps.setInt(1, ids[i]);
                    return true;
                }
                return false;
            }
        }

        auto template_ = new JdbcTemplate(f.dataSource, false);

        const actualRowsAffected = template_.batchUpdate(sql, new Setter);
        assert(actualRowsAffected.length == 2, "executed 2 updates");
        assert(actualRowsAffected[0] == rowsAffected[0]);
        assert(actualRowsAffected[1] == rowsAffected[1]);

        assert(f.count("ps.addBatch") == 2);
        assert(f.count("ps.setInt(1,100)") == 1);
        assert(f.count("ps.setInt(1,200)") == 1);
        assert(f.count("ps.close") == 1);
        assert(f.count("con.close") >= 1);
    }

    @("JdbcTemplateTests.interruptibleBatchUpdateWithBaseClassAndNoBatchSupport")
    unittest
    {
        import flint.jdbc.core.support : AbstractInterruptibleBatchPreparedStatementSetter;

        auto f = setup();
        enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?";
        const int[] ids = [100, 200];
        const int[] rowsAffected = [1, 2];

        f.preparedStatement.updateCounts = script!int(rowsAffected[0], rowsAffected[1]);
        f.mockDatabaseMetaData(false);

        final class Setter : AbstractInterruptibleBatchPreparedStatementSetter
        {
            protected override bool setValuesIfAvailable(PreparedStatement ps, int i)
            {
                if (i < ids.length)
                {
                    ps.setInt(1, ids[i]);
                    return true;
                }
                return false;
            }
        }

        auto template_ = new JdbcTemplate(f.dataSource, false);

        const actualRowsAffected = template_.batchUpdate(sql, new Setter);
        assert(actualRowsAffected.length == 2, "executed 2 updates");
        assert(actualRowsAffected[0] == rowsAffected[0]);
        assert(actualRowsAffected[1] == rowsAffected[1]);

        assert(f.count("ps.addBatch") == 0);
        assert(f.count("ps.setInt(1,100)") == 1);
        assert(f.count("ps.setInt(1,200)") == 1);
        assert(f.count("ps.close") == 1);
        assert(f.count("con.close") >= 1);
    }
}

@("JdbcTemplateTests.batchUpdateWithPreparedStatementAndNoBatchSupport")
unittest
{
    auto f = setup();
    enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?";
    const int[] ids = [100, 200];
    const int[] rowsAffected = [1, 2];

    f.preparedStatement.updateCounts = script!int(rowsAffected[0], rowsAffected[1]);

    auto setter = new IdSetter(ids.dup);

    const actualRowsAffected = f.template_.batchUpdate(sql, setter);
    assert(actualRowsAffected.length == 2, "executed 2 updates");
    assert(actualRowsAffected[0] == rowsAffected[0]);
    assert(actualRowsAffected[1] == rowsAffected[1]);

    assert(f.count("ps.addBatch") == 0);
    assert(f.count("ps.setInt(1,100)") == 1);
    assert(f.count("ps.setInt(1,200)") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") == 1);
}

@("JdbcTemplateTests.batchUpdateFails")
unittest
{
    auto f = setup();
    enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?";
    const int[] ids = [100, 200];
    auto sqlException = new SQLException();

    f.preparedStatement.batchFailure = sqlException;
    f.mockDatabaseMetaData(true);

    auto setter = new IdSetter(ids.dup);

    const ex = expectThrows!DataAccessException({ f.template_.batchUpdate(sql, setter); });
    assert(ex.getCause() is sqlException);
    assert(f.count("ps.addBatch") == 2);
    assert(f.count("ps.setInt(1,100)") == 1);
    assert(f.count("ps.setInt(1,200)") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") >= 1);
}

@("JdbcTemplateTests.batchUpdateWithEmptyList")
unittest
{
    auto f = setup();
    enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?";
    auto template_ = new JdbcTemplate(f.dataSource, false);

    const actualRowsAffected = template_.batchUpdate(sql, cast(Any[][]) null);
    assert(actualRowsAffected.length == 0, "executed 0 updates");
}

@("JdbcTemplateTests.batchUpdateWithListOfObjectArraysPlusTypeInfo")
unittest
{
    auto f = setup();
    enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?";
    Any[][] ids = [[Any.of(100)], [Any.of(200)]];
    int[] sqlTypes = [Types.NUMERIC];
    const int[] rowsAffected = [1, 2];

    f.preparedStatement.batchResults = [rowsAffected.dup];
    f.mockDatabaseMetaData(true);
    f.template_ = new JdbcTemplate(f.dataSource, false);

    const actualRowsAffected = f.template_.batchUpdate(sql, ids, sqlTypes);
    assert(actualRowsAffected.length == 2, "executed 2 updates");
    assert(actualRowsAffected[0] == rowsAffected[0]);
    assert(actualRowsAffected[1] == rowsAffected[1]);
    assert(f.count("ps.addBatch") == 2);
    assert(f.count("ps.setObject(1,100," ~ Types.NUMERIC.to!string ~ ")") == 1);
    assert(f.count("ps.setObject(1,200," ~ Types.NUMERIC.to!string ~ ")") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") >= 1);
}

/// Upstream's `(ps, argument) -> ps.setInt(1, argument)`.
private final class IntSetter : ParameterizedPreparedStatementSetter!int
{
    override void setValues(PreparedStatement ps, int argument)
    {
        ps.setInt(1, argument);
    }
}

// deprecated: upstream's @SuppressWarnings("deprecation") for batchUpdate(sql, Collection, batchSize, setter).
@("JdbcTemplateTests.batchUpdateWithCollectionOfObjects")
deprecated unittest
{
    import flint.java.util : ArrayList;

    auto f = setup();
    enum sql = "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?";
    List!int ids = new ArrayList!int;
    foreach (id; [100, 200, 300])
        ids.add(id);
    const int[] rowsAffected1 = [1, 2];
    const int[] rowsAffected2 = [3];

    f.preparedStatement.batchResults = [rowsAffected1.dup, rowsAffected2.dup];
    f.mockDatabaseMetaData(true);

    ParameterizedPreparedStatementSetter!int setter = new IntSetter;
    auto template_ = new JdbcTemplate(f.dataSource, false);

    const actualRowsAffected = template_.batchUpdate(sql, ids, 2, setter);
    assert(actualRowsAffected[0].length == 2, "executed 2 updates");
    assert(actualRowsAffected[0][0] == rowsAffected1[0]);
    assert(actualRowsAffected[0][1] == rowsAffected1[1]);
    assert(actualRowsAffected[1][0] == rowsAffected2[0]);

    assert(f.count("ps.addBatch") == 3);
    assert(f.count("ps.setInt(1,100)") == 1);
    assert(f.count("ps.setInt(1,200)") == 1);
    assert(f.count("ps.setInt(1,300)") == 1);
    // Each chunk of batchUpdate(sql, Collection, batchSize, setter) prepares (and closes) its own statement, on
    // its own connection outside a transaction, where Spring runs every chunk on one PreparedStatement.
    version (FlintJdbcChunkedBatchOneStatement)
        assert(f.count("ps.close") == 1, f.count("ps.close").to!string);
    assert(f.count("con.close") >= 1);
}

// flint.jdbc.core has no AggregatedBatchUpdateException: a failing chunk's BatchUpdateException is the cause.
version (FlintJdbcAggregatedBatchUpdateException)
{
    @("JdbcTemplateTests.batchUpdateWithBatchFailingHasUpdateCounts")
    deprecated unittest
    {
        test3BatchesOf2ItemsFailing((Exception exception) {
            auto ex = cast(AggregatedBatchUpdateException) exception.getCause();
            assert(ex !is null);
            assert(ex.getSuccessfulUpdateCounts().length == 1);
            assert(ex.getSuccessfulUpdateCounts()[0] == [1, 1]);
            assert(ex.getUpdateCounts() == [-3, -3]);
        });
    }

    @("JdbcTemplateTests.batchUpdateWithBatchFailingMatchesOriginalException")
    deprecated unittest
    {
        test3BatchesOf2ItemsFailing((Exception exception) {
            auto ex = cast(AggregatedBatchUpdateException) exception.getCause();
            assert(ex !is null);
            auto originalException = ex.getOriginalException();
            assert(ex.msg == originalException.msg);
            assert(ex.getCause() is originalException.getCause());
            assert(ex.getSQLState() == originalException.getSQLState());
            assert(ex.getErrorCode() == originalException.getErrorCode());
            assert(ex.getNextException() is originalException.getNextException());
        });
    }

    private deprecated void test3BatchesOf2ItemsFailing(scope void delegate(Exception) @safe exception)
    {
        import flint.dao : DuplicateKeyException;
        import flint.java.util : ArrayList;

        auto f = setup();
        enum sql = "INSERT INTO NOSUCHTABLE values (?)";
        List!int ids = new ArrayList!int;
        foreach (id; [1, 2, 3, 2, 4, 5])
            ids.add(id);
        const int[] rowsAffected = [1, 1];

        f.preparedStatement.batchResults = [rowsAffected.dup];
        f.preparedStatement.batchFailure = new BatchUpdateException(
                "duplicate key value violates unique constraint \"NOSUCHTABLE_pkey\""
                ~ " Detail: Key (id)=(2) already exists.", "23505", 0, [-3L, -3L]);
        f.mockDatabaseMetaData(true);

        ParameterizedPreparedStatementSetter!int setter = new IntSetter;
        auto template_ = new JdbcTemplate(f.dataSource, false);

        auto ex = expectThrows!DuplicateKeyException({ template_.batchUpdate(sql, ids, 2, setter); });
        exception(ex);
        assert(f.count("ps.addBatch") == 4);
        assert(f.count("ps.setInt(1,1)") == 1);
        assert(f.count("ps.setInt(1,2)") == 2);
        assert(f.count("ps.setInt(1,3)") == 1);
        assert(f.count("ps.executeBatch") == 2);
        assert(f.count("ps.close") == 1);
        assert(f.count("con.close") >= 1);
    }
}

@("JdbcTemplateTests.couldNotGetConnectionForOperationOrExceptionTranslator")
unittest
{
    auto f = setup();
    auto sqlException = new SQLException("foo", "07xxx");
    f.dataSource.failure = sqlException;
    auto template_ = new JdbcTemplate(f.dataSource, false);
    auto rcch = new RowCountCallbackHandler;

    const ex = expectThrows!CannotGetJdbcConnectionException({
        template_.query("SELECT ID, FORENAME FROM CUSTMR WHERE ID < 3", rcch);
    });
    assert(ex.getCause() is sqlException);
}

@("JdbcTemplateTests.couldNotGetConnectionForOperationWithLazyExceptionTranslator")
unittest
{
    auto f = setup();
    auto sqlException = new SQLException("foo", "07xxx");
    f.dataSource.failure = sqlException;
    f.template_ = new JdbcTemplate;
    f.template_.setDataSource(f.dataSource);
    f.template_.afterPropertiesSet();
    auto rcch = new RowCountCallbackHandler;

    const ex = expectThrows!CannotGetJdbcConnectionException({
        f.template_.query("SELECT ID, FORENAME FROM CUSTMR WHERE ID < 3", rcch);
    });
    assert(ex.getCause() is sqlException);
}

// flint.jdbc.support has no SQLErrorCodeSQLExceptionTranslator (Flint ships no sql-error-codes files).
version (FlintJdbcErrorCodeTranslator)
{
    @("JdbcTemplateTests.couldNotGetConnectionInOperationWithExceptionTranslatorInitializedViaBeanProperty")
    unittest
    {
        import flint.jdbc.support : SQLErrorCodeSQLExceptionTranslator;

        // This will get a connection.
        doTestCouldNotGetConnectionInOperationWithExceptionTranslatorInitialized((JdbcTemplate template_) {
            template_.setExceptionTranslator(new SQLErrorCodeSQLExceptionTranslator(template_.getDataSource()));
        });
    }
}

@("JdbcTemplateTests.couldNotGetConnectionInOperationWithExceptionTranslatorInitializedInAfterPropertiesSet")
unittest
{
    // This will cause creation of default SQL translator.
    doTestCouldNotGetConnectionInOperationWithExceptionTranslatorInitialized((JdbcTemplate template_) {
        template_.afterPropertiesSet();
    });
}

/// Upstream's `beanProperty` flag is the initialization step itself: the bean property or `afterPropertiesSet()`.
private void doTestCouldNotGetConnectionInOperationWithExceptionTranslatorInitialized(
        scope void delegate(JdbcTemplate) @safe initialize)
{
    auto f = setup();
    auto sqlException = new SQLException("foo", "07xxx");
    f.dataSource.failure = sqlException;
    f.template_ = new JdbcTemplate;
    f.template_.setDataSource(f.dataSource);
    f.template_.setLazyInit(false);
    initialize(f.template_);
    auto rcch = new RowCountCallbackHandler;
    const ex = expectThrows!CannotGetJdbcConnectionException({
        f.template_.query("SELECT ID, FORENAME FROM CUSTMR WHERE ID < 3", rcch);
    });
    assert(ex.getCause() is sqlException);
}

@("JdbcTemplateTests.preparedStatementSetterSucceeds")
unittest
{
    auto f = setup();
    enum sql = "UPDATE FOO SET NAME=? WHERE ID = 1";
    enum name = "Gary";
    enum expectedRowsUpdated = 1;

    f.preparedStatement.updateCounts = script(expectedRowsUpdated);

    auto pss = preparedStatementSetter((PreparedStatement ps) { ps.setString(1, name); });
    const actualRowsUpdated = new JdbcTemplate(f.dataSource).update(sql, pss);
    assert(expectedRowsUpdated == actualRowsUpdated, "updated correct # of rows");
    assert(f.count("ps.setString(1,Gary)") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") == 1);
}

@("JdbcTemplateTests.preparedStatementSetterFails")
unittest
{
    auto f = setup();
    enum sql = "UPDATE FOO SET NAME=? WHERE ID = 1";
    enum name = "Gary";
    auto sqlException = new SQLException();
    f.preparedStatement.updateFailure = sqlException;

    auto pss = preparedStatementSetter((PreparedStatement ps) { ps.setString(1, name); });
    const ex = expectThrows!DataAccessException({ new JdbcTemplate(f.dataSource).update(sql, pss); });
    assert(ex.getCause() is sqlException);
    assert(f.count("ps.setString(1,Gary)") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") >= 1);
}

@("JdbcTemplateTests.couldNotClose")
unittest
{
    auto f = setup();
    auto sqlException = new SQLException("bar");
    f.connection.createdStatement = f.statement;
    f.resultSet.nextResults = script(false);
    f.resultSet.closeFailure = sqlException;
    f.statement.closeFailure = sqlException;
    f.connection.closeFailure = sqlException;

    auto rcch = new RowCountCallbackHandler;
    f.template_.query("SELECT ID, FORENAME FROM CUSTMR WHERE ID < 3", rcch);
    assert(f.count("con.close") == 1);
}

/// Mock objects allow us to produce warnings at will
@("JdbcTemplateTests.fatalWarning")
unittest
{
    auto f = setup();
    enum sql = "SELECT forename from custmr";
    auto warnings = new SQLWarning("My warning");

    f.resultSet.nextResults = script(false);
    f.preparedStatement.warnings = warnings;
    f.connection.createdStatement = f.preparedStatement;

    auto t = new JdbcTemplate(f.dataSource);
    t.setIgnoreWarnings(false);

    final class Extractor : ResultSetExtractor!byte
    {
        override byte extractData(ResultSet rs)
        {
            return rs.getByte(1);
        }
    }

    const ex = expectThrows!SQLWarningException({ t.query(sql, new Extractor); });
    assert(ex.getCause() is warnings);
    assert(f.count("rs.close") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") == 1);
}

@("JdbcTemplateTests.ignoredWarning")
unittest
{
    auto f = setup();
    enum sql = "SELECT forename from custmr";
    auto warnings = new SQLWarning("My warning");

    f.resultSet.nextResults = script(false);
    f.connection.createdStatement = f.preparedStatement;
    f.preparedStatement.warnings = warnings;

    // Too long: truncation

    f.template_.setIgnoreWarnings(true);
    auto rch = rowCallbackHandler((ResultSet rs) { rs.getByte(1); });
    f.template_.query(sql, rch);

    assert(f.count("rs.close") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") == 1);
}

// flint.jdbc.support has no SQLErrorCodeSQLExceptionTranslator (Flint ships no sql-error-codes files).
version (FlintJdbcErrorCodeTranslator)
{
    @("JdbcTemplateTests.sqlErrorCodeTranslation")
    unittest
    {
        import flint.jdbc.support : SQLErrorCodeSQLExceptionTranslator;

        auto f = setup();
        auto sqlException = new SQLException("I have a known problem", "99999", 1054);
        enum sql = "SELECT ID FROM CUSTOMER";

        f.resultSet.nextResults = script(true);
        f.mockDatabaseMetaData(false);
        f.connection.createdStatement = f.preparedStatement;

        f.template_.setExceptionTranslator(new SQLErrorCodeSQLExceptionTranslator(f.dataSource));

        const ex = expectThrows!BadSqlGrammarException({
            f.template_.query(sql, rowCallbackHandler((ResultSet rs) { throw sqlException; }));
        });
        assert(ex.getCause() is sqlException);
        assert(f.count("rs.close") == 1);
        assert(f.count("ps.close") == 1);
        assert(f.count("con.close") >= 1);
    }

    @("JdbcTemplateTests.sqlErrorCodeTranslationWithSpecifiedDatabaseName")
    unittest
    {
        import flint.jdbc.support : SQLErrorCodeSQLExceptionTranslator;

        auto f = setup();
        auto sqlException = new SQLException("I have a known problem", "99999", 1054);
        enum sql = "SELECT ID FROM CUSTOMER";

        f.resultSet.nextResults = script(true);
        f.connection.createdStatement = f.preparedStatement;

        f.template_.setExceptionTranslator(new SQLErrorCodeSQLExceptionTranslator("MySQL"));

        const ex = expectThrows!BadSqlGrammarException({
            f.template_.query(sql, rowCallbackHandler((ResultSet rs) { throw sqlException; }));
        });
        assert(ex.getCause() is sqlException);
        assert(f.count("rs.close") == 1);
        assert(f.count("ps.close") == 1);
        assert(f.count("con.close") == 1);
    }
}

/++
Test that we see an SQLException translated using Error Code. If we provide the SQLExceptionTranslator, we shouldn't
use a connection to get the metadata
+/
@("JdbcTemplateTests.useCustomExceptionTranslator")
unittest
{
    auto f = setup();
    // Bad SQL state
    auto sqlException = new SQLException("I have a known problem", "07000", 1054);
    enum sql = "SELECT ID FROM CUSTOMER";

    f.resultSet.nextResults = script(true);
    f.connection.createdStatement = f.preparedStatement;

    auto template_ = new JdbcTemplate;
    template_.setDataSource(f.dataSource);
    // Set custom exception translator
    template_.setExceptionTranslator(new SQLStateSQLExceptionTranslator);
    template_.afterPropertiesSet();

    const ex = expectThrows!BadSqlGrammarException({
        template_.query(sql, rowCallbackHandler((ResultSet rs) { throw sqlException; }));
    });
    assert(ex.getCause() is sqlException);
    assert(f.count("rs.close") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") == 1);
}

/// Upstream's `rs -> { throw new InvalidDataAccessApiUsageException(""); }`.
private final class ThrowingExtractor : ResultSetExtractor!Object
{
    override Object extractData(ResultSet)
    {
        throw new InvalidDataAccessApiUsageException("");
    }
}

@("JdbcTemplateTests.staticResultSetClosed")
unittest
{
    auto f = setup();
    auto resultSet2 = new MockResultSet(f.log, "rs2");
    f.preparedStatement = new MockStatement(f.log, "ps"); // reset(this.preparedStatement)
    f.connection.preparedStatement = f.preparedStatement;
    f.preparedStatement.resultSet = resultSet2;
    f.connection.createdStatement = f.statement;

    expectThrows!InvalidDataAccessApiUsageException({
        f.template_.query("my query", new ThrowingExtractor);
    });
    expectThrows!InvalidDataAccessApiUsageException({
        f.template_.query(preparedStatementCreator((Connection con) => con.prepareStatement("my query")),
            new ThrowingExtractor);
    });

    assert(f.count("rs.close") == 1);
    assert(f.count("rs2.close") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") >= 1);
}

// flint.java.sql has no CallableStatement, so JdbcTemplate has no call() and flint.jdbc.core no SqlReturnResultSet
// or SqlOutParameter.
version (FlintJdbcCallableStatement)
{
    @("JdbcTemplateTests.executeClosed")
    unittest
    {
        import flint.java.util : Collections;

        auto f = setup();
        auto callableStatement = new MockCallableStatement(f.log, "cs");
        f.connection.callableStatement = callableStatement;
        callableStatement.resultSet = f.resultSet;
        f.resultSet.nextResults = script(true);
        callableStatement.executeResult = true;
        callableStatement.updateCount = script(-1);

        SqlParameter param = new SqlReturnResultSet("", rowCallbackHandler((ResultSet rs) {
                throw new InvalidDataAccessApiUsageException("");
            }));

        expectThrows!InvalidDataAccessApiUsageException({
            f.template_.call((Connection conn) => conn.prepareCall("my query"), Collections.singletonList(param));
        });
        assert(f.count("rs.close") == 1);
        assert(f.count("cs.close") == 1);
        assert(f.count("con.close") == 1);
    }

    @("JdbcTemplateTests.caseInsensitiveResultsMap")
    unittest
    {
        import flint.java.util : Collections;

        auto f = setup();
        auto callableStatement = new MockCallableStatement(f.log, "cs");
        f.connection.callableStatement = callableStatement;
        callableStatement.executeResult = false;
        callableStatement.updateCount = script(-1);
        callableStatement.objects[1] = script(Any.of("X"));

        assert(!f.template_.isResultsMapCaseInsensitive(), "default should have been NOT case insensitive");

        f.template_.setResultsMapCaseInsensitive(true);
        assert(f.template_.isResultsMapCaseInsensitive(), "now it should have been set to case insensitive");

        auto out_ = f.template_.call((Connection conn) => conn.prepareCall("my query"),
                Collections.singletonList!SqlParameter(new SqlOutParameter("a", 12)));

        assert(!out_.get("A").isNull, "we should have gotten the result with upper case");
        assert(!out_.get("a").isNull, "we should have gotten the result with lower case");
        assert(f.count("cs.close") == 1);
        assert(f.count("con.close") == 1);
    }
}

// ColumnMapRowMapper keys a case-sensitive LinkedHashMap with put, not Spring's LinkedCaseInsensitiveMap with
// putIfAbsent: columns "x" and "X" give two entries.
version (FlintJdbcCaseInsensitiveColumnMap)
{
    @("JdbcTemplateTests.equallyNamedColumn")
    unittest
    {
        auto f = setup();
        f.connection.createdStatement = f.statement;

        f.resultSet.metaData = new MockResultSetMetaData("x", "X");

        f.resultSet.nextResults = script(true, false);
        f.resultSet.objects[1] = script(Any.of("first value"));
        f.resultSet.objects[2] = script(Any.of("second value"));

        auto map = f.template_.queryForMap("my query");
        assert(map.size() == 1, map.size().to!string);
        assert(map.get("x").get!string == "first value");
    }
}

@("JdbcTemplateTests.batchUpdateReturnsGeneratedKeys_whenDatabaseSupportsBatchUpdates")
unittest
{
    auto f = setup();
    const int[] rowsAffected = [1, 2];
    f.preparedStatement.batchResults = [rowsAffected.dup];
    f.connection.metaData = new MockDatabaseMetaData(null, true);
    auto generatedKeysResultSet = new MockResultSet(f.log, "keys");
    generatedKeysResultSet.metaData = new MockResultSetMetaData("someId");
    generatedKeysResultSet.objects[1] = script(Any.of(123), Any.of(456));
    generatedKeysResultSet.nextResults = script(true, true, false);
    f.preparedStatement.generatedKeys = script!ResultSet(generatedKeysResultSet);

    const int[] values = [100, 200];
    final class Setter : BatchPreparedStatementSetter
    {
        override void setValues(PreparedStatement ps, int i)
        {
            ps.setObject(i, Any.of(values[i]));
        }

        override int getBatchSize()
        {
            return 2;
        }
    }

    KeyHolder keyHolder = new GeneratedKeyHolder;
    f.template_.batchUpdate(preparedStatementCreator((Connection con) => con.prepareStatement("")),
            new Setter, keyHolder);

    assertSomeIds(keyHolder.getKeyList(), [123, 456]);
}

@("JdbcTemplateTests.batchUpdateReturnsGeneratedKeys_whenDatabaseDoesNotSupportBatchUpdates")
unittest
{
    auto f = setup();
    const int[] rowsAffected = [1, 2];
    f.preparedStatement.batchResults = [rowsAffected.dup];
    f.connection.metaData = new MockDatabaseMetaData(null, false);
    auto rsmd = new MockResultSetMetaData("someId");
    auto generatedKeysResultSet1 = new MockResultSet(f.log, "keys1");
    generatedKeysResultSet1.metaData = rsmd;
    generatedKeysResultSet1.objects[1] = script(Any.of(123));
    generatedKeysResultSet1.nextResults = script(true, false);
    auto generatedKeysResultSet2 = new MockResultSet(f.log, "keys2");
    generatedKeysResultSet2.metaData = rsmd;
    generatedKeysResultSet2.objects[1] = script(Any.of(456));
    generatedKeysResultSet2.nextResults = script(true, false);
    f.preparedStatement.generatedKeys = script!ResultSet(generatedKeysResultSet1, generatedKeysResultSet2);

    const int[] values = [100, 200];
    final class Setter : BatchPreparedStatementSetter
    {
        override void setValues(PreparedStatement ps, int i)
        {
            ps.setObject(i, Any.of(values[i]));
        }

        override int getBatchSize()
        {
            return 2;
        }
    }

    KeyHolder keyHolder = new GeneratedKeyHolder;
    f.template_.batchUpdate(preparedStatementCreator((Connection con) => con.prepareStatement("")),
            new Setter, keyHolder);

    assertSomeIds(keyHolder.getKeyList(), [123, 456]);
}

/// `assertThat(keyList).containsExactly(singletonMap("someId", id), ...)`.
private void assertSomeIds(List!(Map!(string, Any)) keyList, const int[] ids)
{
    assert(keyList.size() == ids.length, keyList.size().to!string);
    foreach (i, id; ids)
    {
        auto keys = keyList.get(cast(int) i);
        assert(keys.size() == 1);
        assert(keys.get("someId").get!int == id);
    }
}

@("JdbcTemplateTests.skipFurtherRowsOnceMaxRowsHasBeenReachedForRowMapper")
unittest
{
    testDiscardFurtherRowsOnceMaxRowsHasBeenReached((JdbcTemplate template_, string sql) {
        return template_.query(sql, (ResultSet rs, int rowNum) => rs.getString(1)).toArray();
    });
}

@("JdbcTemplateTests.discardFurtherRowsOnceMaxRowsHasBeenReachedForRowCallbackHandler")
unittest
{
    testDiscardFurtherRowsOnceMaxRowsHasBeenReached((JdbcTemplate template_, string sql) {
        string[] list;
        template_.query(sql, rowCallbackHandler((ResultSet rs) { list ~= rs.getString(1); }));
        return list;
    });
}

// JdbcTemplate has no queryForStream.
version (FlintJdbcQueryForStream)
{
    @("JdbcTemplateTests.discardFurtherRowsOnceMaxRowsHasBeenReachedForStream")
    unittest
    {
        testDiscardFurtherRowsOnceMaxRowsHasBeenReached((JdbcTemplate template_, string sql) {
            auto stream = template_.queryForStream(sql, (ResultSet rs, int rowNum) => rs.getString(1));
            scope (exit)
                stream.close();
            return stream.toList().toArray();
        });
    }
}

/// Upstream's `BiFunction<JdbcTemplate, String, List<String>>`.
private alias QueryFunction = string[]delegate(JdbcTemplate template_, string sql) @safe;

private void testDiscardFurtherRowsOnceMaxRowsHasBeenReached(scope QueryFunction function_)
{
    auto f = setup();
    enum sql = "SELECT FORENAME FROM CUSTMR";
    const string[] results = ["rod", "gary", " portia"];
    enum maxRows = 2;

    f.resultSet.nextResults = script(true, true, true, false);
    f.resultSet.strings = script(results.dup);
    f.connection.createdStatement = f.preparedStatement;

    auto template_ = new JdbcTemplate;
    template_.setDataSource(f.dataSource);
    template_.setMaxRows(maxRows);

    assert(function_(template_, sql).length == maxRows, "same length");

    assert(f.count("rs.close") == 1);
    assert(f.count("ps.close") == 1);
    assert(f.count("con.close") == 1);
}
