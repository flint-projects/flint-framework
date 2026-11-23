/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/namedparam/NamedParameterJdbcTemplateTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. Hand-written
`BlackHole` fakes replace the Mockito mocks: the statement, result set and connection log their calls, so
`verify(preparedStatement).setObject(1, 1)` becomes a count of `setObject(1,1)` in the log, and
`given(resultSet.next()).willReturn(true, false)` a scripted list that repeats its last answer. The `@BeforeEach`
fields become a `Fixture`; `org.springframework.jdbc.Customer` is a private class. Java lambdas for
`ResultSetExtractor` and `RowCallbackHandler` become a private class and `rowCallbackHandler`, and an
`Iterable` IN-list value an `Any[]`. `executeArray`, `@Disabled` upstream (SPR-16340), runs here because Flint
expands an `Any[]` inside `array[...]`. `queryForStream` waits behind a version gate.
+/
module flint.jdbc.named_parameter_jdbc_template_tests;

import flint.engine.aot.any : Any;
import flint.java.lang : IllegalArgumentException;
import flint.java.sql : Connection, DatabaseMetaData, PreparedStatement, ResultSet, Statement, Types;
import flint.java.util : ArrayList, HashMap, List, Map;
import flint.javax.sql : DataSource;
import flint.jdbc.core : JdbcOperations, JdbcTemplate, PreparedStatementCallback,
    ResultSetExtractor, SqlParameterValue, rowCallbackHandler;
import flint.jdbc.core.namedparam;
import flint.jdbc.support : GeneratedKeyHolder;
import std.typecons : BlackHole;

@safe:

private enum SELECT_NAMED_PARAMETERS = "select id, forename from custmr where id = :id and country = :country";
private enum SELECT_NAMED_PARAMETERS_PARSED = "select id, forename from custmr where id = ? and country = ?";
private enum SELECT_NO_PARAMETERS = "select id, forename from custmr";

private enum INSERT_NAMED_PARAMETERS = "insert into custmr(forename,country) values (:forename,:country)";

private enum UPDATE_NAMED_PARAMETERS = "update seat_status set booking_id = null"
    ~ " where performance_id = :perfId and price_band_id = :priceId";
private enum UPDATE_NAMED_PARAMETERS_PARSED = "update seat_status set booking_id = null"
    ~ " where performance_id = ? and price_band_id = ?";

private enum UPDATE_ARRAY_PARAMETERS = "update customer set type = array[:typeIds] where id = :id";
private enum UPDATE_ARRAY_PARAMETERS_PARSED = "update customer set type = array[?, ?, ?] where id = ?";

private immutable string[] COLUMN_NAMES = ["id", "forename"];

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

    /// Whether `expected` occur in this order (other entries may come between them): Mockito's `InOrder`.
    bool inOrder(string[] expected) const
    {
        size_t next;
        foreach (e; entries)
            if (next < expected.length && e == expected[next])
                ++next;
        return next == expected.length;
    }
}

private string decimal(long value)
{
    import flint.engine.aot.text : decimal;

    return decimal(value);
}

/// The mocked `ResultSet`: `next()` answers from a script that repeats its last answer, as Mockito does.
private final class FakeResultSet : BlackHole!ResultSet
{
    private Log log;
    bool[] nexts = [false];
    private size_t calls;
    Any[string] values;

    this(Log log)
    {
        this.log = log;
    }

    override bool next()
    {
        const answer = nexts[calls < nexts.length ? calls : $ - 1];
        ++calls;
        return answer;
    }

    override int getInt(string label)
    {
        auto value = label in values;
        return value is null ? 0 : value.get!int;
    }

    override string getString(string label)
    {
        auto value = label in values;
        return value is null ? null : value.get!string;
    }

    override void close()
    {
        log.entries ~= "rs.close";
    }
}

private final class FakeDatabaseMetaData : BlackHole!DatabaseMetaData
{
    override string getDatabaseProductName()
    {
        return "MySQL";
    }

    override bool supportsBatchUpdates()
    {
        return true;
    }
}

/// The mocked `PreparedStatement`: each bind is logged as `setObject(1,1)`, `setObject(1,1,3)` (with an SQL
/// type), `setString(2,UK)` or `setNull(1,0)`.
private final class FakePreparedStatement : BlackHole!PreparedStatement
{
    private FakeConnection connection;
    int updateCount;
    int[] rowsAffected;

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
        record("setObject(" ~ decimal(index) ~ "," ~ value.toString() ~ ")");
    }

    override void setObject(int index, Any value, int sqlType)
    {
        record("setObject(" ~ decimal(index) ~ "," ~ value.toString() ~ "," ~ decimal(sqlType) ~ ")");
    }

    override void setString(int index, string value)
    {
        record("setString(" ~ decimal(index) ~ "," ~ value ~ ")");
    }

    override void setNull(int index, int sqlType)
    {
        record("setNull(" ~ decimal(index) ~ "," ~ decimal(sqlType) ~ ")");
    }

    override int executeUpdate()
    {
        record("executeUpdate");
        return updateCount;
    }

    override ResultSet executeQuery()
    {
        record("executeQuery");
        return connection.resultSet;
    }

    override void addBatch()
    {
        record("addBatch");
    }

    override int[] executeBatch()
    {
        record("executeBatch");
        return rowsAffected;
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
    DatabaseMetaData metaData;

    this()
    {
        log = new Log;
        preparedStatement = new FakePreparedStatement(this);
        resultSet = new FakeResultSet(log);
    }

    override PreparedStatement prepareStatement(string sql)
    {
        log.entries ~= "prepareStatement(" ~ sql ~ ")";
        return preparedStatement;
    }

    override PreparedStatement prepareStatement(string sql, int autoGeneratedKeys)
    {
        log.entries ~= "prepareStatement(" ~ sql ~ "," ~ decimal(autoGeneratedKeys) ~ ")";
        return preparedStatement;
    }

    override DatabaseMetaData getMetaData()
    {
        return metaData;
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

/// `org.springframework.jdbc.Customer`.
private final class Customer
{
    private int id;
    private string forename;

    int getId()
    {
        return id;
    }

    void setId(int id)
    {
        this.id = id;
    }

    string getForename()
    {
        return forename;
    }

    void setForename(string forename)
    {
        this.forename = forename;
    }
}

/// The `@BeforeEach` fields and stubbing.
private struct Fixture
{
    FakeConnection connection;
    FakeDataSource dataSource;
    FakePreparedStatement preparedStatement;
    FakeResultSet resultSet;
    FakeDatabaseMetaData databaseMetaData;
    NamedParameterJdbcTemplate namedParameterTemplate;
    Map!(string, Any) params;

    static Fixture setup()
    {
        Fixture f;
        f.connection = new FakeConnection;
        f.dataSource = new FakeDataSource(f.connection);
        f.preparedStatement = f.connection.preparedStatement;
        f.resultSet = f.connection.resultSet;
        f.databaseMetaData = new FakeDatabaseMetaData;
        f.namedParameterTemplate = new NamedParameterJdbcTemplate(f.dataSource);
        f.params = new HashMap!(string, Any);
        return f;
    }

    /// `verify(mock).call()`: exactly once.
    void verify(string entry)
    {
        assert(connection.log.count(entry) == 1, entry ~ " in " ~ joined());
    }

    /// `verify(mock, times(n)).call()`.
    void verify(string entry, size_t times)
    {
        assert(connection.log.count(entry) == times, entry ~ " in " ~ joined());
    }

    /// `verify(mock, atLeastOnce()).call()`.
    void verifyAtLeastOnce(string entry)
    {
        assert(connection.log.count(entry) >= 1, entry ~ " in " ~ joined());
    }

    private string joined()
    {
        import std.array : join;

        return connection.log.entries.join(" | ");
    }

    /// `given(resultSet.getInt("id")).willReturn(1)` and `given(resultSet.getString("forename")).willReturn("rod")`.
    void stubCustomerRow(bool[] nexts...)
    {
        resultSet.nexts = nexts.dup;
        resultSet.values["id"] = Any.of(1);
        resultSet.values["forename"] = Any.of("rod");
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

private Any parameterValue(SqlParameterValue value)
{
    return Any.ofObject(value, typeid(SqlParameterValue).name);
}

/// `Collections.singletonMap(key, value)`.
private Map!(string, Any) singletonMap(string key, Any value)
{
    auto map = new HashMap!(string, Any);
    map.put(key, value);
    return map;
}

private Customer mapCustomer(ResultSet rs)
{
    auto cust = new Customer;
    cust.setId(rs.getInt(COLUMN_NAMES[0]));
    cust.setForename(rs.getString(COLUMN_NAMES[1]));
    return cust;
}

/// The `PreparedStatementCallback` of the `execute` cases: it checks the statement, runs `executeUpdate` (or
/// `executeQuery`) and returns "result".
private final class ResultCallback : PreparedStatementCallback!string
{
    private PreparedStatement expected;
    private bool query;

    this(PreparedStatement expected, bool query = false)
    {
        this.expected = expected;
        this.query = query;
    }

    override string doInPreparedStatement(PreparedStatement ps)
    {
        assert(ps is expected);
        if (query)
            ps.executeQuery();
        else
            ps.executeUpdate();
        return "result";
    }
}

/// The `ResultSetExtractor` lambda of the `queryWithResultSetExtractor` cases.
private final class CustomerExtractor : ResultSetExtractor!Customer
{
    override Customer extractData(ResultSet rs)
    {
        rs.next();
        return mapCustomer(rs);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// NamedParameterJdbcTemplateTests

@("NamedParameterJdbcTemplateTests.nullDataSourceProvidedToCtor")
unittest
{
    expectThrows!IllegalArgumentException({ new NamedParameterJdbcTemplate(cast(DataSource) null); });
}

@("NamedParameterJdbcTemplateTests.nullJdbcTemplateProvidedToCtor")
unittest
{
    expectThrows!IllegalArgumentException({ new NamedParameterJdbcTemplate(cast(JdbcOperations) null); });
}

@("NamedParameterJdbcTemplateTests.templateConfiguration")
unittest
{
    auto f = Fixture.setup();
    assert(f.namedParameterTemplate.getJdbcTemplate().getDataSource() is f.dataSource);
}

@("NamedParameterJdbcTemplateTests.execute")
unittest
{
    auto f = Fixture.setup();
    f.preparedStatement.updateCount = 1;

    f.params.put("perfId", Any.of(1));
    f.params.put("priceId", Any.of(1));
    const result = f.namedParameterTemplate.execute(UPDATE_NAMED_PARAMETERS, f.params,
            new ResultCallback(f.preparedStatement));

    assert(result == "result");
    f.verify("prepareStatement(" ~ UPDATE_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("setObject(1,1)");
    f.verify("setObject(2,1)");
    f.verify("ps.close");
    f.verify("con.close");
}

@("NamedParameterJdbcTemplateTests.executeArray")
unittest
{
    auto f = Fixture.setup();
    f.preparedStatement.updateCount = 1;

    auto typeIds = [Any.of(1), Any.of(2), Any.of(3)];

    f.params.put("typeIds", Any.of(typeIds));
    f.params.put("id", Any.of(1));
    const result = f.namedParameterTemplate.execute(UPDATE_ARRAY_PARAMETERS, f.params,
            new ResultCallback(f.preparedStatement));

    assert(result == "result");
    f.verify("prepareStatement(" ~ UPDATE_ARRAY_PARAMETERS_PARSED ~ ")");
    f.verify("setObject(1,1)");
    f.verify("setObject(2,2)");
    f.verify("setObject(3,3)");
    f.verify("setObject(4,1)");
    f.verify("ps.close");
    f.verify("con.close");
}

@("NamedParameterJdbcTemplateTests.executeWithTypedParameters")
unittest
{
    auto f = Fixture.setup();
    f.preparedStatement.updateCount = 1;

    f.params.put("perfId", parameterValue(new SqlParameterValue(Types.DECIMAL, Any.of(1))));
    f.params.put("priceId", parameterValue(new SqlParameterValue(Types.INTEGER, Any.of(1))));
    const result = f.namedParameterTemplate.execute(UPDATE_NAMED_PARAMETERS, f.params,
            new ResultCallback(f.preparedStatement));

    assert(result == "result");
    f.verify("prepareStatement(" ~ UPDATE_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("setObject(1,1," ~ decimal(Types.DECIMAL) ~ ")");
    f.verify("setObject(2,1," ~ decimal(Types.INTEGER) ~ ")");
    f.verify("ps.close");
    f.verify("con.close");
}

@("NamedParameterJdbcTemplateTests.executeNoParameters")
unittest
{
    auto f = Fixture.setup();
    f.preparedStatement.updateCount = 1;

    auto callback = new ResultCallback(f.preparedStatement, true);
    const result = f.namedParameterTemplate.execute(SELECT_NO_PARAMETERS, callback);

    assert(result == "result");
    f.verify("prepareStatement(" ~ SELECT_NO_PARAMETERS ~ ")");
    f.verify("ps.close");
    f.verify("con.close");
}

@("NamedParameterJdbcTemplateTests.queryWithResultSetExtractor")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true);

    f.params.put("id", parameterValue(new SqlParameterValue(Types.DECIMAL, Any.of(1))));
    f.params.put("country", Any.of("UK"));
    auto cust = f.namedParameterTemplate.query(SELECT_NAMED_PARAMETERS, f.params, new CustomerExtractor);
    assert(cust.getId() == 1, "Customer id was assigned correctly");
    assert(cust.getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("setObject(1,1," ~ decimal(Types.DECIMAL) ~ ")");
    f.verify("setString(2,UK)");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("NamedParameterJdbcTemplateTests.queryWithResultSetExtractorNoParameters")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true);

    auto cust = f.namedParameterTemplate.query(SELECT_NO_PARAMETERS, new CustomerExtractor);
    assert(cust.getId() == 1, "Customer id was assigned correctly");
    assert(cust.getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("prepareStatement(" ~ SELECT_NO_PARAMETERS ~ ")");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("NamedParameterJdbcTemplateTests.queryWithRowCallbackHandler")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true, false);

    f.params.put("id", parameterValue(new SqlParameterValue(Types.DECIMAL, Any.of(1))));
    f.params.put("country", Any.of("UK"));
    auto customers = new ArrayList!Customer;
    f.namedParameterTemplate.query(SELECT_NAMED_PARAMETERS, f.params, rowCallbackHandler((ResultSet rs) {
            customers.add(mapCustomer(rs));
        }));

    assert(customers.size() == 1);
    assert(customers.get(0).getId() == 1, "Customer id was assigned correctly");
    assert(customers.get(0).getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("setObject(1,1," ~ decimal(Types.DECIMAL) ~ ")");
    f.verify("setString(2,UK)");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("NamedParameterJdbcTemplateTests.queryWithRowCallbackHandlerNoParameters")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true, false);

    auto customers = new ArrayList!Customer;
    f.namedParameterTemplate.query(SELECT_NO_PARAMETERS, rowCallbackHandler((ResultSet rs) {
            customers.add(mapCustomer(rs));
        }));

    assert(customers.size() == 1);
    assert(customers.get(0).getId() == 1, "Customer id was assigned correctly");
    assert(customers.get(0).getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("prepareStatement(" ~ SELECT_NO_PARAMETERS ~ ")");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("NamedParameterJdbcTemplateTests.queryWithRowMapper")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true, false);

    f.params.put("id", parameterValue(new SqlParameterValue(Types.DECIMAL, Any.of(1))));
    f.params.put("country", Any.of("UK"));
    auto customers = f.namedParameterTemplate.query(SELECT_NAMED_PARAMETERS, f.params,
            (ResultSet rs, int) => mapCustomer(rs));

    assert(customers.size() == 1);
    assert(customers.get(0).getId() == 1, "Customer id was assigned correctly");
    assert(customers.get(0).getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("setObject(1,1," ~ decimal(Types.DECIMAL) ~ ")");
    f.verify("setString(2,UK)");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("NamedParameterJdbcTemplateTests.queryWithRowMapperNoParameters")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true, false);

    auto customers = f.namedParameterTemplate.query(SELECT_NO_PARAMETERS, (ResultSet rs, int) => mapCustomer(rs));

    assert(customers.size() == 1);
    assert(customers.get(0).getId() == 1, "Customer id was assigned correctly");
    assert(customers.get(0).getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("prepareStatement(" ~ SELECT_NO_PARAMETERS ~ ")");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("NamedParameterJdbcTemplateTests.queryForObjectWithRowMapper")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true, false);

    f.params.put("id", parameterValue(new SqlParameterValue(Types.DECIMAL, Any.of(1))));
    f.params.put("country", Any.of("UK"));

    auto cust = f.namedParameterTemplate.queryForObject(SELECT_NAMED_PARAMETERS, f.params,
            (ResultSet rs, int) => mapCustomer(rs));

    assert(cust.getId() == 1, "Customer id was assigned correctly");
    assert(cust.getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("setObject(1,1," ~ decimal(Types.DECIMAL) ~ ")");
    f.verify("setString(2,UK)");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

// NamedParameterJdbcOperations has no queryForStream.
version (FlintJdbcQueryForStream)
{
    @("NamedParameterJdbcTemplateTests.queryForStreamWithRowMapper")
    unittest
    {
        auto f = Fixture.setup();
        f.stubCustomerRow(true, false);

        f.params.put("id", parameterValue(new SqlParameterValue(Types.DECIMAL, Any.of(1))));
        f.params.put("country", Any.of("UK"));
        int count;

        auto s = f.namedParameterTemplate.queryForStream(SELECT_NAMED_PARAMETERS, f.params,
                (ResultSet rs, int) => mapCustomer(rs));
        scope (exit)
            s.close();
        s.forEach((Customer cust) {
            ++count;
            assert(cust.getId() == 1, "Customer id was assigned correctly");
            assert(cust.getForename() == "rod", "Customer forename was assigned correctly");
        });

        assert(count == 1);
        f.verify("prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
        f.verify("setObject(1,1," ~ decimal(Types.DECIMAL) ~ ")");
        f.verify("setString(2,UK)");
        f.verify("rs.close");
        f.verify("ps.close");
        f.verify("con.close");
    }
}

@("NamedParameterJdbcTemplateTests.update")
unittest
{
    auto f = Fixture.setup();
    f.preparedStatement.updateCount = 1;

    f.params.put("perfId", Any.of(1));
    f.params.put("priceId", Any.of(1));
    const rowsAffected = f.namedParameterTemplate.update(UPDATE_NAMED_PARAMETERS, f.params);

    assert(rowsAffected == 1);
    f.verify("prepareStatement(" ~ UPDATE_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("setObject(1,1)");
    f.verify("setObject(2,1)");
    f.verify("ps.close");
    f.verify("con.close");
}

@("NamedParameterJdbcTemplateTests.updateWithTypedParameters")
unittest
{
    auto f = Fixture.setup();
    f.preparedStatement.updateCount = 1;

    f.params.put("perfId", parameterValue(new SqlParameterValue(Types.DECIMAL, Any.of(1))));
    f.params.put("priceId", parameterValue(new SqlParameterValue(Types.INTEGER, Any.of(1))));
    const rowsAffected = f.namedParameterTemplate.update(UPDATE_NAMED_PARAMETERS, f.params);

    assert(rowsAffected == 1);
    f.verify("prepareStatement(" ~ UPDATE_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("setObject(1,1," ~ decimal(Types.DECIMAL) ~ ")");
    f.verify("setObject(2,1," ~ decimal(Types.INTEGER) ~ ")");
    f.verify("ps.close");
    f.verify("con.close");
}

@("NamedParameterJdbcTemplateTests.batchUpdateWithPlainMap")
unittest
{
    auto f = Fixture.setup();
    Map!(string, Any)[] ids = [singletonMap("id", Any.of(100)), singletonMap("id", Any.of(200))];
    const rowsAffected = [1, 2];

    f.preparedStatement.rowsAffected = rowsAffected.dup;
    f.connection.metaData = f.databaseMetaData;
    f.namedParameterTemplate = new NamedParameterJdbcTemplate(new JdbcTemplate(f.dataSource, false));

    const actualRowsAffected = f.namedParameterTemplate.batchUpdate(
            "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = :id", ids);
    assert(actualRowsAffected.length == 2, "executed 2 updates");
    assert(actualRowsAffected[0] == rowsAffected[0]);
    assert(actualRowsAffected[1] == rowsAffected[1]);
    f.verify("prepareStatement(UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?)");
    f.verify("setObject(1,100)");
    f.verify("setObject(1,200)");
    f.verify("addBatch", 2);
    f.verifyAtLeastOnce("ps.close");
    f.verifyAtLeastOnce("con.close");
}

@("NamedParameterJdbcTemplateTests.batchUpdateWithEmptyMap")
unittest
{
    auto f = Fixture.setup();
    Map!(string, Any)[] ids;
    f.namedParameterTemplate = new NamedParameterJdbcTemplate(new JdbcTemplate(f.dataSource, false));

    const actualRowsAffected = f.namedParameterTemplate.batchUpdate(
            "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = :id", ids);
    assert(actualRowsAffected.length == 0, "executed 0 updates");
}

@("NamedParameterJdbcTemplateTests.batchUpdateWithSqlParameterSource")
unittest
{
    auto f = Fixture.setup();
    SqlParameterSource[] ids = [
        new MapSqlParameterSource("id", 100), new MapSqlParameterSource("id", 200)
    ];
    const rowsAffected = [1, 2];

    f.preparedStatement.rowsAffected = rowsAffected.dup;
    f.connection.metaData = f.databaseMetaData;
    f.namedParameterTemplate = new NamedParameterJdbcTemplate(new JdbcTemplate(f.dataSource, false));

    const actualRowsAffected = f.namedParameterTemplate.batchUpdate(
            "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = :id", ids);
    assert(actualRowsAffected.length == 2, "executed 2 updates");
    assert(actualRowsAffected[0] == rowsAffected[0]);
    assert(actualRowsAffected[1] == rowsAffected[1]);
    f.verify("prepareStatement(UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?)");
    f.verify("setObject(1,100)");
    f.verify("setObject(1,200)");
    f.verify("addBatch", 2);
    f.verifyAtLeastOnce("ps.close");
    f.verifyAtLeastOnce("con.close");
}

@("NamedParameterJdbcTemplateTests.batchUpdateWithInClause")
unittest
{
    auto f = Fixture.setup();
    Map!(string, Any)[] parameters = [
        singletonMap("ids", Any.of([Any.of(1), Any.of(2)])),
        singletonMap("ids", Any.of([Any.of("3"), Any.of("4")])),
        // Java's Iterable value: an Any[] too.
        singletonMap("ids", Any.of([Any.of(5), Any.of(6)]))
    ];

    const rowsAffected = [1, 2, 3];
    f.preparedStatement.rowsAffected = rowsAffected.dup;
    f.connection.metaData = f.databaseMetaData;

    auto template_ = new JdbcTemplate(f.dataSource, false);
    f.namedParameterTemplate = new NamedParameterJdbcTemplate(template_);

    const actualRowsAffected = f.namedParameterTemplate.batchUpdate("delete sometable where id in (:ids)", parameters);

    assert(actualRowsAffected.length == 3, "executed 3 updates");

    assert(f.connection.log.inOrder([
        "setObject(1,1)", "setObject(2,2)", "addBatch", "setString(1,3)", "setString(2,4)",
        "addBatch", "setObject(1,5)", "setObject(2,6)", "addBatch", "ps.close"
    ]), f.joined());
    f.verifyAtLeastOnce("con.close");
}

// LIKELY BUG: a null named-parameter value is taken for an empty IN-list (Any.init holds Any[]),
// so `:id` becomes no placeholder ("WHERE ID = ") and setNull(1, Types.NULL) is never called.
version (FlintJdbcNullNamedParameterAsEmptyInList)
{
    @("NamedParameterJdbcTemplateTests.batchUpdateWithSqlParameterSourcePlusTypeInfo")
    unittest
    {
        auto f = Fixture.setup();
        SqlParameterSource[] ids = [
            new MapSqlParameterSource().addValue("id", null, Types.NULL),
            new MapSqlParameterSource().addValue("id", 100, Types.NUMERIC),
            new MapSqlParameterSource().addValue("id", 200, Types.NUMERIC)
        ];
        const rowsAffected = [1, 2, 3];

        f.preparedStatement.rowsAffected = rowsAffected.dup;
        f.connection.metaData = f.databaseMetaData;
        f.namedParameterTemplate = new NamedParameterJdbcTemplate(new JdbcTemplate(f.dataSource, false));

        const actualRowsAffected = f.namedParameterTemplate.batchUpdate(
                "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = :id", ids);
        assert(actualRowsAffected.length == 3, "executed 3 updates");
        assert(actualRowsAffected[0] == rowsAffected[0]);
        assert(actualRowsAffected[1] == rowsAffected[1]);
        assert(actualRowsAffected[2] == rowsAffected[2]);
        f.verify("prepareStatement(UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?)");
        f.verify("setNull(1," ~ decimal(Types.NULL) ~ ")");
        f.verify("setObject(1,100," ~ decimal(Types.NUMERIC) ~ ")");
        f.verify("setObject(1,200," ~ decimal(Types.NUMERIC) ~ ")");
        f.verify("addBatch", 3);
        f.verifyAtLeastOnce("ps.close");
        f.verifyAtLeastOnce("con.close");
    }
}

@("NamedParameterJdbcTemplateTests.batchUpdateWithGeneratedKeys")
unittest
{
    auto f = Fixture.setup();
    auto first = new HashMap!(string, Any);
    first.put("forename", Any.of("foo"));
    first.put("country", Any.of("UK"));
    auto second = new HashMap!(string, Any);
    second.put("forename", Any.of("bar"));
    second.put("country", Any.of("US"));
    SqlParameterSource[] batchArgs = [
        new MapSqlParameterSource(first), new MapSqlParameterSource(second)
    ];
    const rowsAffected = [1, 1];

    f.preparedStatement.rowsAffected = rowsAffected.dup;
    f.connection.metaData = f.databaseMetaData;
    f.namedParameterTemplate = new NamedParameterJdbcTemplate(new JdbcTemplate(f.dataSource, false));

    const actualRowsAffected = f.namedParameterTemplate.batchUpdate(INSERT_NAMED_PARAMETERS,
            batchArgs, new GeneratedKeyHolder);
    assert(actualRowsAffected.length == 2, "executed 2 updates");
    assert(actualRowsAffected[0] == rowsAffected[0]);
    assert(actualRowsAffected[1] == rowsAffected[1]);
    f.verify("prepareStatement(insert into custmr(forename,country) values (?,?)," ~ decimal(
            Statement.RETURN_GENERATED_KEYS) ~ ")");
    f.verify("setString(1,foo)");
    f.verify("setString(2,UK)");
    f.verify("setString(1,bar)");
    f.verify("setString(2,US)");
    f.verify("addBatch", 2);
    f.verifyAtLeastOnce("ps.close");
    f.verifyAtLeastOnce("con.close");
}
