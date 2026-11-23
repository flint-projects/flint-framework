/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/RowMapperTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: hand-written `BlackHole` fakes that count `close` calls and log bound parameters
replace the Mockito mocks; `@BeforeEach` becomes `setUp`, which returns the fixture, and the two `@AfterEach`
methods become `verifyClosed` and `verifyResults`, called at the end of each test. `SingleConnectionDataSource`
(not in flint.jdbc.datasource) becomes a fake `DataSource` that hands out the one connection, and `TestBean` a
private class with a name and an age. Java's deprecated `query(sql, Object[], RowMapper)` is the `Object...` form
`query(sql, rowMapper, args...)`; as upstream, that test does not verify the bound arguments.
+/
module flint.jdbc.row_mapper_tests;

import flint.engine.aot.any : Any;
import flint.java.sql : Connection, PreparedStatement, ResultSet, Statement, Types;
import flint.java.util : List;
import flint.javax.sql : DataSource;
import flint.jdbc.core : JdbcTemplate, RowMapper, preparedStatementCreator, preparedStatementSetter, rowMapper;
import flint.jdbc.support : SQLStateSQLExceptionTranslator;
import std.typecons : BlackHole;

@safe:

private final class TestBean
{
    private string name;
    private int age;

    this(string name, int age)
    {
        this.name = name;
        this.age = age;
    }

    string getName()
    {
        return name;
    }

    int getAge()
    {
        return age;
    }
}

/// `next()` answers true, true, false; `getString(1)` "tb1", "tb2"; `getInt(2)` 1, 2.
private final class FakeResultSet : BlackHole!ResultSet
{
    int closed;
    private int row;

    override bool next()
    {
        return ++row <= 2;
    }

    override string getString(int column)
    {
        assert(column == 1);
        return row == 1 ? "tb1" : "tb2";
    }

    override int getInt(int column)
    {
        assert(column == 2);
        return row;
    }

    override void close()
    {
        ++closed;
    }
}

/// Serves as both the `Statement` and the `PreparedStatement` mock.
private final class FakeStatement : BlackHole!PreparedStatement
{
    int closed;
    string[] setStrings;
    private FakeResultSet resultSet;

    this(FakeResultSet resultSet)
    {
        this.resultSet = resultSet;
    }

    override ResultSet executeQuery(string)
    {
        return resultSet;
    }

    override ResultSet executeQuery()
    {
        return resultSet;
    }

    override void setString(int index, string value)
    {
        import flint.engine.aot.text : decimal;

        setStrings ~= decimal(index) ~ "," ~ value;
    }

    override void close()
    {
        ++closed;
    }
}

private final class FakeConnection : BlackHole!Connection
{
    private FakeStatement statement, preparedStatement;

    this(FakeStatement statement, FakeStatement preparedStatement)
    {
        this.statement = statement;
        this.preparedStatement = preparedStatement;
    }

    override Statement createStatement()
    {
        return statement;
    }

    override PreparedStatement prepareStatement(string)
    {
        return preparedStatement;
    }
}

/// `SingleConnectionDataSource(connection, false)`: the one connection for every request.
private final class SingleConnectionDataSource : BlackHole!DataSource
{
    private Connection connection;

    this(Connection connection)
    {
        this.connection = connection;
    }

    override Connection getConnection()
    {
        return connection;
    }
}

private struct Fixture
{
    FakeConnection connection;
    FakeStatement statement;
    FakeStatement preparedStatement;
    FakeResultSet resultSet;
    JdbcTemplate template_;
    RowMapper!TestBean testRowMapper;
    List!TestBean result;
}

private Fixture setUp()
{
    Fixture f;
    f.resultSet = new FakeResultSet;
    f.statement = new FakeStatement(f.resultSet);
    f.preparedStatement = new FakeStatement(f.resultSet);
    f.connection = new FakeConnection(f.statement, f.preparedStatement);
    f.testRowMapper = rowMapper((ResultSet rs, int) => new TestBean(rs.getString(1), rs.getInt(2)));
    f.template_ = new JdbcTemplate();
    f.template_.setDataSource(new SingleConnectionDataSource(f.connection));
    f.template_.setExceptionTranslator(new SQLStateSQLExceptionTranslator());
    f.template_.afterPropertiesSet();
    return f;
}

private void verifyClosed(ref Fixture f)
{
    assert(f.resultSet.closed == 1, "resultSet.close()");
}

private void verifyResults(ref Fixture f)
{
    assert(f.result !is null);
    assert(f.result.size() == 2);
    auto testBean1 = f.result.get(0);
    auto testBean2 = f.result.get(1);
    assert(testBean1.getName() == "tb1");
    assert(testBean2.getName() == "tb2");
    assert(testBean1.getAge() == 1);
    assert(testBean2.getAge() == 2);
}

private void afterEach(ref Fixture f)
{
    verifyClosed(f);
    verifyResults(f);
}

@("RowMapperTests.staticQueryWithRowMapper")
unittest
{
    auto f = setUp();
    f.result = f.template_.query("some SQL", f.testRowMapper);
    assert(f.statement.closed == 1, "statement.close()");
    afterEach(f);
}

@("RowMapperTests.preparedStatementCreatorWithRowMapper")
unittest
{
    auto f = setUp();
    PreparedStatement ps = f.preparedStatement;
    f.result = f.template_.query(preparedStatementCreator((Connection con) => ps), f.testRowMapper);
    assert(f.preparedStatement.closed == 1, "preparedStatement.close()");
    afterEach(f);
}

@("RowMapperTests.preparedStatementSetterWithRowMapper")
unittest
{
    auto f = setUp();
    f.result = f.template_.query("some SQL", preparedStatementSetter((PreparedStatement ps) {
            ps.setString(1, "test");
        }), f.testRowMapper);
    assert(f.preparedStatement.setStrings == ["1,test"]);
    assert(f.preparedStatement.closed == 1, "preparedStatement.close()");
    afterEach(f);
}

@("RowMapperTests.queryWithArgsAndRowMapper")
unittest
{
    auto f = setUp();
    f.result = f.template_.query("some SQL", f.testRowMapper, "test1", "test2");
    afterEach(f);
}

@("RowMapperTests.queryWithArgsAndTypesAndRowMapper")
unittest
{
    auto f = setUp();
    f.result = f.template_.query("some SQL", [Any.of("test1"), Any.of("test2")], [
        Types.VARCHAR, Types.VARCHAR
    ], f.testRowMapper);
    assert(f.preparedStatement.setStrings == ["1,test1", "2,test2"]);
    assert(f.preparedStatement.closed == 1, "preparedStatement.close()");
    afterEach(f);
}
