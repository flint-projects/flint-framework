/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/simple/JdbcClientQueryTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. Hand-written
`BlackHole` fakes replace the Mockito mocks: the connection, statement and result set log their calls, so
`verify(preparedStatement).setObject(1, 3)` becomes a count of `ps.setObject(1,3)` in the log;
`given(resultSet.next()).willReturn(true, false)` is a script that repeats its last answer, and a stubbed column
(`getObject(1)` returning 11, then 12, or `getInt(1)` returning 22) answers every index getter, since Flint's
`SingleColumnRowMapper` reads `getObject` where Spring's reads `getInt`. `Class<T>` arguments are template
arguments (`query!int()`), a Java `List` parameter value an `Any[]` (and a list of `Object[]` an `Any[]` of
`Any[]`), and the `Object` results of `singleValue()` and row maps are `Any`. `rowSet()`, `paramSource(Object)`
and `query(Class)` for a record or field holder wait behind version gates.
+/
module flint.jdbc.jdbc_client_query_tests;

import flint.engine.aot.any : Any;
import flint.java.lang : IllegalArgumentException;
import flint.java.sql : Connection, PreparedStatement, ResultSet, ResultSetMetaData, Types;
import flint.java.util : List, Map, Optional;
import flint.javax.sql : DataSource;
import flint.jdbc.core.simple : JdbcClient;
import std.typecons : BlackHole;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fakes

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

    /// Whether `expected` occur in this order, other entries possibly between them: Mockito's `InOrder`.
    bool inOrder(scope const string[] expected) const
    {
        size_t next;
        foreach (e; entries)
            if (next < expected.length && e == expected[next])
                ++next;
        return next == expected.length;
    }

    string joined() const
    {
        import std.array : join;

        return entries.join(" | ");
    }
}

private string decimal(long value)
{
    import flint.engine.aot.text : decimal;

    return decimal(value);
}

/// A Mockito answer script: each call takes the next answer, and the last one repeats.
private struct Script(T)
{
    T[] answers;
    private size_t calls;

    T next()
    {
        if (answers.length == 0)
            return T.init;
        auto answer = answers[calls < answers.length ? calls : $ - 1];
        ++calls;
        return answer;
    }
}

private final class FakeResultSetMetaData : BlackHole!ResultSetMetaData
{
    int columnCount;
    string[int] labels;

    override int getColumnCount()
    {
        return columnCount;
    }

    override string getColumnLabel(int column)
    {
        return labels.get(column, null);
    }
}

/// The mocked `ResultSet`: `next()` and each stubbed column follow a script.
private final class FakeResultSet : BlackHole!ResultSet
{
    private Log log;
    Script!bool nexts;
    Script!Any[int] columns;
    int[string] columnIndexes;
    ResultSetMetaData metaData;

    this(Log log)
    {
        this.log = log;
    }

    override bool next()
    {
        return nexts.next();
    }

    override Any getObject(int column)
    {
        auto script = column in columns;
        return script is null ? Any.init : script.next();
    }

    override int getInt(int column)
    {
        const value = getObject(column);
        return value.isNull ? 0 : value.get!int;
    }

    override long getLong(int column)
    {
        const value = getObject(column);
        return value.isNull ? 0 : value.get!long;
    }

    override int findColumn(string label)
    {
        return columnIndexes.get(label, 0);
    }

    override ResultSetMetaData getMetaData()
    {
        return metaData;
    }

    override void close()
    {
        log.entries ~= "rs.close";
    }
}

/// The mocked `PreparedStatement`: binds are logged as `ps.setObject(1,1)`, `ps.setObject(1,1,3)` (with an SQL
/// type) and `ps.setString(2,UK)`.
private final class FakePreparedStatement : BlackHole!PreparedStatement
{
    private FakeConnection connection;
    this(FakeConnection connection)
    {
        this.connection = connection;
    }

    private void record(string entry)
    {
        connection.log.entries ~= entry;
    }

    override void setObject(int index, Any value)
    {
        record("ps.setObject(" ~ decimal(index) ~ "," ~ value.toString() ~ ")");
    }

    override void setObject(int index, Any value, int sqlType)
    {
        record("ps.setObject(" ~ decimal(index) ~ "," ~ value.toString() ~ "," ~ decimal(sqlType) ~ ")");
    }

    override void setString(int index, string value)
    {
        record("ps.setString(" ~ decimal(index) ~ "," ~ value ~ ")");
    }

    override void setNull(int index, int sqlType)
    {
        record("ps.setNull(" ~ decimal(index) ~ "," ~ decimal(sqlType) ~ ")");
    }

    override ResultSet executeQuery()
    {
        record("ps.executeQuery");
        return connection.resultSet;
    }

    override Connection getConnection()
    {
        return connection;
    }

    override void close()
    {
        record("ps.close");
    }
}

private final class FakeConnection : BlackHole!Connection
{
    Log log;
    FakePreparedStatement preparedStatement;
    FakeResultSet resultSet;

    this()
    {
        log = new Log;
        preparedStatement = new FakePreparedStatement(this);
        resultSet = new FakeResultSet(log);
    }

    override PreparedStatement prepareStatement(string sql)
    {
        log.entries ~= "con.prepareStatement(" ~ sql ~ ")";
        return preparedStatement;
    }

    override void close()
    {
        log.entries ~= "con.close";
    }
}

private final class FakeDataSource : BlackHole!DataSource
{
    private FakeConnection connection;

    this(FakeConnection connection)
    {
        this.connection = connection;
    }

    override Connection getConnection()
    {
        return connection;
    }
}

/// The `@BeforeEach` fields and stubbing.
private struct Fixture
{
    FakeConnection connection;
    FakeDataSource dataSource;
    FakePreparedStatement preparedStatement;
    FakeResultSet resultSet;
    FakeResultSetMetaData resultSetMetaData;
    JdbcClient client;

    static Fixture setup()
    {
        Fixture f;
        f.connection = new FakeConnection;
        f.dataSource = new FakeDataSource(f.connection);
        f.preparedStatement = f.connection.preparedStatement;
        f.resultSet = f.connection.resultSet;
        f.resultSetMetaData = new FakeResultSetMetaData;
        f.resultSet.metaData = f.resultSetMetaData;
        f.resultSetMetaData.columnCount = 1;
        f.resultSetMetaData.labels[1] = "age";
        f.client = JdbcClient.create(f.dataSource);
        return f;
    }

    /// `verify(mock).call()`: exactly once.
    void verify(string entry)
    {
        assert(connection.log.count(entry) == 1, entry ~ " in " ~ connection.log.joined());
    }

    /// `given(resultSet.next()).willReturn(nexts)` and `given(resultSet.getObject(1)).willReturn(values)`; an
    /// empty `values` leaves the column unstubbed.
    void stub(bool[] nexts, Any[] values...)
    {
        resultSet.nexts = Script!bool(nexts);
        if (values.length)
            resultSet.columns[1] = Script!Any(values.dup);
    }

    /// The closing verifications of every case.
    void verifyClosed()
    {
        verify("rs.close");
        verify("ps.close");
        verify("con.close");
    }
}

private void expectThrows(E : Throwable)(scope void delegate() @safe action)
{
    try
        action();
    catch (E)
        return;
    assert(false, "expected " ~ E.stringof);
}

// ---------------------------------------------------------------------------------------------------------------
// JdbcClientQueryTests: indexed parameters

// Gap: JdbcClient.ResultQuerySpec has no rowSet(), as Flint has no SqlRowSet yet.
version (FlintJdbcSqlRowSet)
{
    @("JdbcClientQueryTests.queryForRowSetWithIndexedParam")
    unittest
    {
        import flint.jdbc.support.rowset : SqlRowSet;

        auto f = Fixture.setup();
        f.stub([true, true, false], Any.of(11), Any.of(12));
        SqlRowSet rowSet = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID < ?").param(3).query().rowSet();
        assert(rowSet.next());
        assert(rowSet.getInt("age") == 11, "First row is Integer");
        assert(rowSet.next());
        assert(rowSet.getInt("age") == 12, "Second row is Integer");
        f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID < ?)");
        f.verify("ps.setObject(1,3)");
        f.verifyClosed();
    }
}

@("JdbcClientQueryTests.queryForListWithIndexedParam")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, true, false], Any.of(11), Any.of(12));
    List!(Map!(string, Any)) li = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID < ?").param(3).query().listOfRows();
    assert(li.size() == 2, "All rows returned");
    assert(li.get(0).get("age").get!int == 11, "First row is Integer");
    assert(li.get(1).get("age").get!int == 12, "Second row is Integer");
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID < ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForListWithIndexedParamAndEmptyResult")
unittest
{
    auto f = Fixture.setup();
    f.stub([false]);
    List!(Map!(string, Any)) li = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID < ?").param(3).query().listOfRows();
    assert(li.size() == 0, "All rows returned");
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID < ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForListWithIndexedParamAndSingleRow")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(11));
    List!(Map!(string, Any)) li = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID < ?").param(3).query().listOfRows();
    assert(li.size() == 1, "All rows returned");
    assert(li.get(0).get("age").get!int == 11, "First row is Integer");
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID < ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForMapWithIndexedParamAndSingleRow")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(11));
    Map!(string, Any) map = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID < ?").param(1, 3).query().singleRow();
    assert(map.get("age").get!int == 11, "Row is Integer");
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID < ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForListWithIndexedParamAndSingleColumn")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(11));
    List!Any li = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID < ?").param(1, 3).query().singleColumn();
    assert(li.size() == 1 && li.get(0).get!int == 11);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID < ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForIntegerWithIndexedParamAndSingleValue")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    const value = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = ?").param(1, 3).query().singleValue().get!int;
    assert(value == 22);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForIntegerWithIndexedParamAndOptionalValue")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    Optional!Any value = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = ?").param(1, 3).query().optionalValue();
    assert(value.isPresent() && value.get().get!int == 22);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForIntegerWithIndexedParamAndNonExistingValue")
unittest
{
    auto f = Fixture.setup();
    f.stub([false]);
    Optional!Any value = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = ?").param(1, 3).query().optionalValue();
    assert(value.isEmpty());
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForIntegerWithIndexedParamAndRowMapper")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    const value = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = ?").param(1, 3)
        .query((ResultSet rs, int rowNum) => rs.getInt(1)).single();
    assert(value == 22);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForOptionalWithIndexedParamAndRowMapper")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    Optional!int value = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = ?").param(1, 3)
        .query((ResultSet rs, int rowNum) => rs.getInt(1)).optional();
    assert(value.isPresent() && value.get() == 22);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForIntegerWithIndexedParam")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    const value = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = ?").param(1, 3).query!int().single();
    assert(value == 22);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForIntWithIndexedParam")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    const int i = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = ?").param(1, 3).query!int().single();
    assert(i == 22, "Return of an int");
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForObjectWithIndexedParamAndList")
unittest
{
    auto f = Fixture.setup();
    expectThrows!IllegalArgumentException({
        f.client.sql("SELECT AGE FROM CUSTMR WHERE ID IN (?)").param([Any.of(3), Any.of(4)]).query().singleValue();
    });
}

// ---------------------------------------------------------------------------------------------------------------
// JdbcClientQueryTests: named parameters

version (FlintJdbcSqlRowSet)
{
    @("JdbcClientQueryTests.queryForRowSetWithNamedParam")
    unittest
    {
        import flint.jdbc.support.rowset : SqlRowSet;

        auto f = Fixture.setup();
        f.stub([true, true, false], Any.of(11), Any.of(12));
        SqlRowSet rowSet = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID < :id").param("id", 3).query().rowSet();
        assert(rowSet.next());
        assert(rowSet.getInt("age") == 11, "First row is Integer");
        assert(rowSet.next());
        assert(rowSet.getInt("age") == 12, "Second row is Integer");
        f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID < ?)");
        f.verify("ps.setObject(1,3)");
        f.verifyClosed();
    }
}

@("JdbcClientQueryTests.queryForListWithNamedParam")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, true, false], Any.of(11), Any.of(12));
    List!(Map!(string, Any)) li = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID < :id").param("id",
            3).query().listOfRows();
    assert(li.size() == 2, "All rows returned");
    assert(li.get(0).get("age").get!int == 11, "First row is Integer");
    assert(li.get(1).get("age").get!int == 12, "Second row is Integer");
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID < ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForListWithNamedParamAndEmptyResult")
unittest
{
    auto f = Fixture.setup();
    f.stub([false]);
    List!(Map!(string, Any)) li = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID < :id").param("id",
            3).query().listOfRows();
    assert(li.size() == 0, "All rows returned");
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID < ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForListWithNamedParamAndSingleRow")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(11));
    List!(Map!(string, Any)) li = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID < :id").param("id",
            3).query().listOfRows();
    assert(li.size() == 1, "All rows returned");
    assert(li.get(0).get("age").get!int == 11, "First row is Integer");
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID < ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForMapWithNamedParamAndSingleRow")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(11));
    Map!(string, Any) map = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID < :id").param("id", 3).query().singleRow();
    assert(map.get("age").get!int == 11, "Row is Integer");
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID < ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForListWithNamedParamAndSingleColumn")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(11));
    List!Any li = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID < :id").param("id", 3).query().singleColumn();
    assert(li.size() == 1 && li.get(0).get!int == 11);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID < ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForIntegerWithNamedParamAndSingleValue")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    const value = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = :id").param("id", 3).query().singleValue().get!int;
    assert(value == 22);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForIntegerWithNamedParamAndRowMapper")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    const value = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = :id").param("id", 3)
        .query((ResultSet rs, int rowNum) => rs.getInt(1)).single();
    assert(value == 22);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForOptionalWithNamedParamAndRowMapper")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    Optional!int value = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = :id").param("id", 3)
        .query((ResultSet rs, int rowNum) => rs.getInt(1)).optional();
    assert(value.isPresent() && value.get() == 22);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForIntegerWithNamedParam")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    const value = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = :id").param("id", 3).query!int().single();
    assert(value == 22);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForIntegerWithNamedParamAndList")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    const value = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID IN (:ids)").param("ids",
            [Any.of(3), Any.of(4)]).query!int().single();
    assert(value == 22);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID IN (?, ?))");
    f.verify("ps.setObject(1,3)");
    f.verify("ps.setObject(2,4)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForIntegerWithNamedParamAndListOfExpressionLists")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    Any[] l1;
    l1 ~= Any.of([Any.of(3), Any.of("Rod")]);
    l1 ~= Any.of([Any.of(4), Any.of("Juergen")]);
    const value = f.client.sql("SELECT AGE FROM CUSTMR WHERE (ID, NAME) IN (:multiExpressionList)")
        .param("multiExpressionList", l1).query!int().single();
    assert(value == 22);
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE (ID, NAME) IN ((?, ?), (?, ?)))");
    f.verify("ps.setObject(1,3)");
    f.verify("ps.setString(2,Rod)");
    f.verify("ps.setObject(3,4)");
    f.verify("ps.setString(4,Juergen)");
    f.verifyClosed();
}

@("JdbcClientQueryTests.queryForIntWithNamedParam")
unittest
{
    auto f = Fixture.setup();
    f.stub([true, false], Any.of(22));
    const int i = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = :id").param("id", 3).query!int().single();
    assert(i == 22, "Return of an int");
    f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
    f.verify("ps.setObject(1,3)");
    f.verifyClosed();
}

// Gap: StatementSpec.paramSource takes a SqlParameterSource only, not any Object: a bean, record or field holder
// is not wrapped in a SimplePropertySqlParameterSource.
version (FlintJdbcClientParamSourceObject)
{
    private final class ParameterBean
    {
        private const int id;

        this(int id)
        {
            this.id = id;
        }

        int getId()
        {
            return id;
        }
    }

    private final class ParameterCollectionBean
    {
        private Any[] ids;

        this(int[] ids...)
        {
            foreach (id; ids)
                this.ids ~= Any.of(id);
        }

        Any[] getIds()
        {
            return ids;
        }
    }

    /// `record ParameterRecord(int id)`.
    private struct ParameterRecord
    {
        int id;
    }

    private final class ParameterFieldHolder
    {
        this(int id)
        {
            this.id = id;
        }

        int id;
    }

    @("JdbcClientQueryTests.queryForLongWithParamBean")
    unittest
    {
        auto f = Fixture.setup();
        f.stub([true, false], Any.of(87L));
        const long l = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = :id")
            .paramSource(new ParameterBean(3)).query!long().single();
        assert(l == 87, "Return of a long");
        f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
        f.verify("ps.setObject(1,3,4)");
        f.verifyClosed();
    }

    @("JdbcClientQueryTests.queryForLongWithParamBeanWithCollection")
    unittest
    {
        auto f = Fixture.setup();
        f.stub([true, false], Any.of(87L));
        const long l = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID IN (:ids)")
            .paramSource(new ParameterCollectionBean(3, 5)).query!long().single();
        assert(l == 87, "Return of a long");
        f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID IN (?, ?))");
        f.verify("ps.setObject(1,3)");
        f.verify("ps.setObject(2,5)");
        f.verifyClosed();
    }

    @("JdbcClientQueryTests.queryForLongWithParamRecord")
    unittest
    {
        auto f = Fixture.setup();
        f.stub([true, false], Any.of(87L));
        const long l = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = :id")
            .paramSource(ParameterRecord(3)).query!long().single();
        assert(l == 87, "Return of a long");
        f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
        f.verify("ps.setObject(1,3,4)");
        f.verifyClosed();
    }

    @("JdbcClientQueryTests.queryForLongWithParamFieldHolder")
    unittest
    {
        auto f = Fixture.setup();
        f.stub([true, false], Any.of(87L));
        const long l = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = :id")
            .paramSource(new ParameterFieldHolder(3)).query!long().single();
        assert(l == 87, "Return of a long");
        f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
        f.verify("ps.setObject(1,3,4)");
        f.verifyClosed();
    }
}

// Gap: StatementSpec.query!T() maps a simple T only (no SimplePropertyRowMapper for records and field holders), and
// JdbcClient.create takes no ConversionService.
version (FlintJdbcClientMappedClass)
{
    /// `record AgeRecord(int age)`.
    private struct AgeRecord
    {
        int age;
    }

    private final class AgeFieldHolder
    {
        import std.bigint : BigInt;

        BigInt age;
    }

    @("JdbcClientQueryTests.queryForMappedRecordWithNamedParam")
    unittest
    {
        auto f = Fixture.setup();
        f.resultSet.columnIndexes["age"] = 1;
        f.stub([true, false], Any.of(22));
        AgeRecord value = f.client.sql("SELECT AGE FROM CUSTMR WHERE ID = :id").param("id", 3)
            .query!AgeRecord().single();
        assert(value.age == 22);
        f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
        f.verify("ps.setObject(1,3)");
        f.verifyClosed();
    }

    @("JdbcClientQueryTests.queryForMappedFieldHolderWithNamedParam")
    unittest
    {
        import flint.core.convert.converter : Converter;
        import flint.core.convert.support : GenericConversionService;
        import flint.jdbc.core.namedparam : NamedParameterJdbcTemplate;
        import std.bigint : BigInt;

        auto f = Fixture.setup();
        // Spring stubs getObject(1, BigInteger.class) to throw SQLFeatureNotSupportedException, so the mapper
        // falls back to getObject(1) and the conversion service.
        f.stub([true, false], Any.of("big22"));
        auto conversionService = new GenericConversionService();
        conversionService.addConverter(new class Converter!(string, BigInt)
            {
            override BigInt convert(string source)
            {
                return BigInt(source[3 .. $]);}
            }
);
            auto client = JdbcClient.create(new NamedParameterJdbcTemplate(f.dataSource), conversionService);
            AgeFieldHolder value = client.sql("SELECT AGE FROM CUSTMR WHERE ID = :id").param("id",
                3).query!AgeFieldHolder().single();
            assert(value.age == BigInt(22));
            f.verify("con.prepareStatement(SELECT AGE FROM CUSTMR WHERE ID = ?)");
            f.verify("ps.setObject(1,3)");
            f.verifyClosed();
        }
    }
