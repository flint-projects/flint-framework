/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/simple/JdbcClientNamedParameterTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. Hand-written
`BlackHole` fakes replace the Mockito mocks: the connection, statement and result set log their calls, so
`verify(preparedStatement).setObject(1, 1)` becomes a count of `ps.setObject(1,1)` in the log and `InOrder` an
ordered-subsequence check; `given(resultSet.next()).willReturn(true, false)` is a script that repeats its last
answer, and a stubbed column (`getObject(1)` returning 11, then 12) answers every index getter. The `@BeforeEach`
fields become a `Fixture`; `org.springframework.jdbc.Customer` is a private class. Java lambdas for
`ResultSetExtractor` become an anonymous class, a `HashMap<String, Object>` of parameters a
`HashMap!(string, Any)`, and a `BatchEntry`'s typed `param("perfId", 1, Types.DECIMAL)` takes an `Any`, as
`BatchEntry` has no typed façade for it. `@ParameterizedTest` cases loop over their values. `stream()` and
`paramSource(Object)` wait behind version gates.
+/
module flint.jdbc.jdbc_client_named_parameter_tests;

import flint.engine.aot.any : Any;
import flint.java.sql : Connection, DatabaseMetaData, PreparedStatement, ResultSet, ResultSetMetaData, Types;
import flint.java.util : HashMap, List, Map, Set;
import flint.javax.sql : DataSource;
import flint.jdbc.core : ResultSetExtractor, SqlParameterValue;
import flint.jdbc.core.namedparam : MapSqlParameterSource;
import flint.jdbc.core.simple : JdbcClient;
import flint.jdbc.support : GeneratedKeyHolder, KeyHolder;
import std.typecons : BlackHole;

@safe:

private enum SELECT_NAMED_PARAMETERS = "select id, forename from custmr where id = :id and country = :country";
private enum SELECT_NAMED_PARAMETERS_PARSED = "select id, forename from custmr where id = ? and country = ?";
private enum SELECT_NO_PARAMETERS = "select id, forename from custmr";
private enum UPDATE_NAMED_PARAMETERS = "update seat_status set booking_id = null"
    ~ " where performance_id = :perfId and price_band_id = :priceId";
private enum UPDATE_NAMED_PARAMETERS_PARSED = "update seat_status set booking_id = null"
    ~ " where performance_id = ? and price_band_id = ?";
private enum INSERT_GENERATE_KEYS = "insert into show (name) values(:name)";
private enum INSERT_GENERATE_KEYS_PARSED = "insert into show (name) values(?)";

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

/// The mocked `ResultSet`: `next()` and each stubbed column follow a script; labelled values are constant.
private final class FakeResultSet : BlackHole!ResultSet
{
    private Log log;
    Script!bool nexts;
    Script!Any[int] columns;
    Any[string] values;
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

    override ResultSetMetaData getMetaData()
    {
        return metaData;
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

/// The mocked `PreparedStatement`: binds are logged as `ps.setObject(1,1)`, `ps.setObject(1,1,3)` (with an SQL
/// type) and `ps.setString(2,UK)`.
private final class FakePreparedStatement : BlackHole!PreparedStatement
{
    private FakeConnection connection;
    int updateCount;
    int[] batchCounts;
    ResultSet generatedKeys;

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

    override int executeUpdate()
    {
        record("ps.executeUpdate");
        return updateCount;
    }

    override void addBatch()
    {
        record("ps.addBatch");
    }

    override int[] executeBatch()
    {
        record("ps.executeBatch");
        return batchCounts;
    }

    override ResultSet getGeneratedKeys()
    {
        return generatedKeys;
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
        log.entries ~= "con.prepareStatement(" ~ sql ~ ")";
        return preparedStatement;
    }

    override PreparedStatement prepareStatement(string sql, int autoGeneratedKeys)
    {
        log.entries ~= "con.prepareStatement(" ~ sql ~ "," ~ decimal(autoGeneratedKeys) ~ ")";
        return preparedStatement;
    }

    override PreparedStatement prepareStatement(string sql, string[] columnNames)
    {
        import std.array : join;

        log.entries ~= "con.prepareStatement(" ~ sql ~ ",[" ~ columnNames.join(",") ~ "])";
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
    FakeResultSetMetaData resultSetMetaData;
    FakeDatabaseMetaData databaseMetaData;
    JdbcClient client;
    Map!(string, Any) params;
    MapSqlParameterSource paramSource;

    static Fixture setup()
    {
        Fixture f;
        f.connection = new FakeConnection;
        f.dataSource = new FakeDataSource(f.connection);
        f.preparedStatement = f.connection.preparedStatement;
        f.resultSet = f.connection.resultSet;
        f.resultSetMetaData = new FakeResultSetMetaData;
        f.databaseMetaData = new FakeDatabaseMetaData;
        f.client = JdbcClient.create(f.dataSource);
        f.params = new HashMap!(string, Any);
        f.paramSource = new MapSqlParameterSource;
        return f;
    }

    /// `verify(mock).call()`: exactly once.
    void verify(string entry)
    {
        assert(connection.log.count(entry) == 1, entry ~ " in " ~ connection.log.joined());
    }

    /// `InOrder.verify` of each entry in turn.
    void verifyInOrder(string[] entries)
    {
        assert(connection.log.inOrder(entries), connection.log.joined());
    }

    /// `given(resultSet.next()).willReturn(nexts)`, `given(resultSet.getInt("id")).willReturn(1)` and
    /// `given(resultSet.getString("forename")).willReturn("rod")`.
    void stubCustomerRow(bool[] nexts...)
    {
        resultSet.nexts = Script!bool(nexts.dup);
        resultSet.values["id"] = Any.of(1);
        resultSet.values["forename"] = Any.of("rod");
    }

    /// The batch cases' stubbing: `connection.getMetaData()` and `executeBatch()`, or `executeUpdate()`.
    void stubBatch(bool supportsBatchUpdates, int[] counts...)
    {
        if (supportsBatchUpdates)
        {
            connection.metaData = databaseMetaData;
            preparedStatement.batchCounts = counts.dup;
        }
        else
            preparedStatement.updateCount = 1;
    }

    /// The generated-keys cases' stubbing of an "id" key column answering `keys`, with `nexts`.
    void stubGeneratedKeys(bool[] nexts, Any[] keys...)
    {
        resultSetMetaData.columnCount = 1;
        resultSetMetaData.labels[1] = "id";
        resultSet.metaData = resultSetMetaData;
        resultSet.nexts = Script!bool(nexts);
        resultSet.columns[1] = Script!Any(keys.dup);
        preparedStatement.generatedKeys = resultSet;
    }
}

private Any parameterValue(SqlParameterValue value)
{
    return Any.ofObject(value, typeid(SqlParameterValue).name);
}

private Any typed(int sqlType, int value)
{
    return parameterValue(new SqlParameterValue(sqlType, Any.of(value)));
}

private Customer mapCustomer(ResultSet rs)
{
    auto cust = new Customer;
    cust.setId(rs.getInt(COLUMN_NAMES[0]));
    cust.setForename(rs.getString(COLUMN_NAMES[1]));
    return cust;
}

/// The extractor lambda of the `ResultSetExtractor` cases.
private final class CustomerExtractor : ResultSetExtractor!Customer
{
    override Customer extractData(ResultSet rs)
    {
        rs.next();
        return mapCustomer(rs);
    }
}

/// `assertThat(generatedKeyHolder.getKeyList()).containsExactly(Map.of("id", k1), ...)`.
private void assertKeyList(KeyHolder generatedKeyHolder, int[] keys...)
{
    auto keyList = generatedKeyHolder.getKeyList();
    assert(keyList.size() == keys.length);
    foreach (i, key; keys)
    {
        Map!(string, Any) row = keyList.get(cast(int) i);
        assert(row.size() == 1 && row.get("id").get!int == key);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// ---------------------------------------------------------------------------------------------------------------
// JdbcClientNamedParameterTests

@("JdbcClientNamedParameterTests.queryWithResultSetExtractor")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true);

    f.params.put("id", typed(Types.DECIMAL, 1));
    f.params.put("country", Any.of("UK"));
    auto cust = f.client.sql(SELECT_NAMED_PARAMETERS).params(f.params).query(new CustomerExtractor);

    assert(cust.getId() == 1, "Customer id was assigned correctly");
    assert(cust.getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("con.prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("ps.setObject(1,1,3)");
    f.verify("ps.setString(2,UK)");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("JdbcClientNamedParameterTests.queryWithResultSetExtractorParameterSource")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true);

    f.paramSource.addValue("id", new SqlParameterValue(Types.DECIMAL, Any.of(1)));
    f.paramSource.addValue("country", "UK");
    auto cust = f.client.sql(SELECT_NAMED_PARAMETERS).paramSource(f.paramSource).query(new CustomerExtractor);

    assert(cust.getId() == 1, "Customer id was assigned correctly");
    assert(cust.getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("con.prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("ps.setObject(1,1,3)");
    f.verify("ps.setString(2,UK)");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("JdbcClientNamedParameterTests.queryWithResultSetExtractorNoParameters")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true);

    auto cust = f.client.sql(SELECT_NO_PARAMETERS).query(new CustomerExtractor);

    assert(cust.getId() == 1, "Customer id was assigned correctly");
    assert(cust.getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("con.prepareStatement(" ~ SELECT_NO_PARAMETERS ~ ")");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("JdbcClientNamedParameterTests.queryWithRowCallbackHandler")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true, false);

    f.params.put("id", typed(Types.DECIMAL, 1));
    f.params.put("country", Any.of("UK"));
    Customer[] customers;
    f.client.sql(SELECT_NAMED_PARAMETERS).params(f.params).query((ResultSet rs) {
        customers ~= mapCustomer(rs);
    });

    assert(customers.length == 1);
    assert(customers[0].getId() == 1, "Customer id was assigned correctly");
    assert(customers[0].getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("con.prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("ps.setObject(1,1,3)");
    f.verify("ps.setString(2,UK)");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("JdbcClientNamedParameterTests.queryWithRowCallbackHandlerParameterSource")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true, false);

    f.paramSource.addValue("id", new SqlParameterValue(Types.DECIMAL, Any.of(1)));
    f.paramSource.addValue("country", "UK");
    Customer[] customers;
    f.client.sql(SELECT_NAMED_PARAMETERS).paramSource(f.paramSource).query((ResultSet rs) {
        customers ~= mapCustomer(rs);
    });

    assert(customers.length == 1);
    assert(customers[0].getId() == 1, "Customer id was assigned correctly");
    assert(customers[0].getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("con.prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("ps.setObject(1,1,3)");
    f.verify("ps.setString(2,UK)");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("JdbcClientNamedParameterTests.queryWithRowCallbackHandlerNoParameters")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true, false);

    Customer[] customers;
    f.client.sql(SELECT_NO_PARAMETERS).query((ResultSet rs) { customers ~= mapCustomer(rs); });

    assert(customers.length == 1);
    assert(customers[0].getId() == 1, "Customer id was assigned correctly");
    assert(customers[0].getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("con.prepareStatement(" ~ SELECT_NO_PARAMETERS ~ ")");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("JdbcClientNamedParameterTests.queryWithRowMapper")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true, false);

    f.params.put("id", typed(Types.DECIMAL, 1));
    f.params.put("country", Any.of("UK"));
    List!Customer customers = f.client.sql(SELECT_NAMED_PARAMETERS).params(f.params)
        .query((ResultSet rs, int rownum) => mapCustomer(rs)).list();

    assert(customers.size() == 1);
    auto cust = customers.get(0);
    assert(cust.getId() == 1, "Customer id was assigned correctly");
    assert(cust.getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("con.prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("ps.setObject(1,1,3)");
    f.verify("ps.setString(2,UK)");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("JdbcClientNamedParameterTests.queryWithRowMapperNoParameters")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true, false);

    Set!Customer customers = f.client.sql(SELECT_NO_PARAMETERS).query((ResultSet rs, int rownum) => mapCustomer(rs))
        .set();

    assert(customers.size() == 1);
    auto cust = customers.toArray()[0];
    assert(cust.getId() == 1, "Customer id was assigned correctly");
    assert(cust.getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("con.prepareStatement(" ~ SELECT_NO_PARAMETERS ~ ")");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("JdbcClientNamedParameterTests.queryForObjectWithRowMapper")
unittest
{
    auto f = Fixture.setup();
    f.stubCustomerRow(true, false);

    f.params.put("id", typed(Types.DECIMAL, 1));
    f.params.put("country", Any.of("UK"));
    auto cust = f.client.sql(SELECT_NAMED_PARAMETERS).params(f.params).query((ResultSet rs,
            int rownum) => mapCustomer(rs)).single();

    assert(cust.getId() == 1, "Customer id was assigned correctly");
    assert(cust.getForename() == "rod", "Customer forename was assigned correctly");
    f.verify("con.prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("ps.setObject(1,1,3)");
    f.verify("ps.setString(2,UK)");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

// Gap: JdbcClient.MappedQuerySpec has no stream(), as JdbcTemplate has no queryForStream.
version (FlintJdbcQueryForStream)
{
    @("JdbcClientNamedParameterTests.queryForStreamWithRowMapper")
    unittest
    {
        auto f = Fixture.setup();
        f.stubCustomerRow(true, false);

        f.params.put("id", typed(Types.DECIMAL, 1));
        f.params.put("country", Any.of("UK"));
        int count;

        {
            auto s = f.client.sql(SELECT_NAMED_PARAMETERS).params(f.params).query((ResultSet rs,
                    int rownum) => mapCustomer(rs)).stream();
            scope (exit)
                s.close();
            s.forEach((Customer cust) {
                ++count;
                assert(cust.getId() == 1, "Customer id was assigned correctly");
                assert(cust.getForename() == "rod", "Customer forename was assigned correctly");
            });
        }

        assert(count == 1);
        f.verify("con.prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
        f.verify("ps.setObject(1,1,3)");
        f.verify("ps.setString(2,UK)");
        f.verify("rs.close");
        f.verify("ps.close");
        f.verify("con.close");
    }
}

@("JdbcClientNamedParameterTests.update")
unittest
{
    auto f = Fixture.setup();
    f.preparedStatement.updateCount = 1;

    f.params.put("perfId", Any.of(1));
    f.params.put("priceId", Any.of(1));
    const rowsAffected = f.client.sql(UPDATE_NAMED_PARAMETERS).params(f.params).update();

    assert(rowsAffected == 1);
    f.verify("con.prepareStatement(" ~ UPDATE_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("ps.setObject(1,1)");
    f.verify("ps.setObject(2,1)");
    f.verify("ps.close");
    f.verify("con.close");
}

// Gap: StatementSpec.paramSource takes a SqlParameterSource only, not any Object (gh-37501): a parameter source
// held as an Object, or a bean, record or field holder wrapped in a SimplePropertySqlParameterSource.
version (FlintJdbcClientParamSourceObject)
{
    @("JdbcClientNamedParameterTests.updateWithParameterSourceSuppliedAsObject")
    unittest
    {
        auto f = Fixture.setup();
        f.preparedStatement.updateCount = 1;

        Object namedParamObject = new MapSqlParameterSource("perfId", 1).addValue("priceId", 2);
        const rowsAffected = f.client.sql(UPDATE_NAMED_PARAMETERS).paramSource(namedParamObject).update();

        assert(rowsAffected == 1);
        f.verify("con.prepareStatement(" ~ UPDATE_NAMED_PARAMETERS_PARSED ~ ")");
        f.verify("ps.setObject(1,1)");
        f.verify("ps.setObject(2,2)");
        f.verify("ps.close");
        f.verify("con.close");
    }
}

@("JdbcClientNamedParameterTests.batchUpdateSingleRow")
unittest
{
    foreach (supportsBatchUpdates; [true, false])
    {
        auto f = Fixture.setup();
        f.stubBatch(supportsBatchUpdates, 1);

        const rowsAffected = f.client.sql(UPDATE_NAMED_PARAMETERS).batch().entry((JdbcClient.BatchEntry entry) {
            entry.param("perfId", 1).param("priceId", 1);
        }).update();

        assert(rowsAffected == [1]);
        string[] expected = [
            "con.prepareStatement(" ~ UPDATE_NAMED_PARAMETERS_PARSED ~ ")", "ps.setObject(1,1)",
            "ps.setObject(2,1)"
        ];
        if (supportsBatchUpdates)
            expected ~= "ps.addBatch";
        f.verifyInOrder(expected ~ ["ps.close", "con.close"]);
    }
}

@("JdbcClientNamedParameterTests.batchUpdateMultipleRows")
unittest
{
    foreach (supportsBatchUpdates; [true, false])
    {
        auto f = Fixture.setup();
        f.stubBatch(supportsBatchUpdates, 1, 1);

        const rowsAffected = f.client.sql(UPDATE_NAMED_PARAMETERS).batch().entry((JdbcClient.BatchEntry entry) {
            entry.param("perfId", 1).param("priceId", 1);
        }).entry((JdbcClient.BatchEntry entry) { entry.param("perfId", 2).param("priceId", 2); }).update();

        assert(rowsAffected == [1, 1]);
        string[] expected = [
            "con.prepareStatement(" ~ UPDATE_NAMED_PARAMETERS_PARSED ~ ")", "ps.setObject(1,1)",
            "ps.setObject(2,1)"
        ];
        if (supportsBatchUpdates)
            expected ~= "ps.addBatch";
        expected ~= ["ps.setObject(1,2)", "ps.setObject(2,2)"];
        if (supportsBatchUpdates)
            expected ~= "ps.addBatch";
        f.verifyInOrder(expected ~ ["ps.close", "con.close"]);
    }
}

@("JdbcClientNamedParameterTests.updateWithTypedParameters")
unittest
{
    auto f = Fixture.setup();
    f.preparedStatement.updateCount = 1;

    f.params.put("perfId", typed(Types.DECIMAL, 1));
    f.params.put("priceId", typed(Types.INTEGER, 1));
    const rowsAffected = f.client.sql(UPDATE_NAMED_PARAMETERS).params(f.params).update();

    assert(rowsAffected == 1);
    f.verify("con.prepareStatement(" ~ UPDATE_NAMED_PARAMETERS_PARSED ~ ")");
    f.verify("ps.setObject(1,1,3)");
    f.verify("ps.setObject(2,1,4)");
    f.verify("ps.close");
    f.verify("con.close");
}

@("JdbcClientNamedParameterTests.batchUpdateWithTypedParameters")
unittest
{
    foreach (supportsBatchUpdates; [true, false])
    {
        auto f = Fixture.setup();
        f.stubBatch(supportsBatchUpdates, 1, 1);

        const rowsAffected = f.client.sql(UPDATE_NAMED_PARAMETERS).batch().entry((JdbcClient.BatchEntry entry) {
            entry.param("perfId", new SqlParameterValue(Types.DECIMAL, Any.of(1))).param("priceId",
                new SqlParameterValue(Types.INTEGER, Any.of(1)));
        }).entry((JdbcClient.BatchEntry entry) {
            entry.param("perfId", new SqlParameterValue(Types.DECIMAL, Any.of(2))).param("priceId",
                new SqlParameterValue(Types.INTEGER, Any.of(2)));
        }).update();

        assert(rowsAffected == [1, 1]);
        string[] expected = [
            "con.prepareStatement(" ~ UPDATE_NAMED_PARAMETERS_PARSED ~ ")", "ps.setObject(1,1,3)",
            "ps.setObject(2,1,4)"
        ];
        if (supportsBatchUpdates)
            expected ~= "ps.addBatch";
        expected ~= ["ps.setObject(1,2,3)", "ps.setObject(2,2,4)"];
        if (supportsBatchUpdates)
            expected ~= "ps.addBatch";
        f.verifyInOrder(expected ~ ["ps.close", "con.close"]);
    }
}

@("JdbcClientNamedParameterTests.batchUpdateWithParametersAndSqlType")
unittest
{
    foreach (supportsBatchUpdates; [true, false])
    {
        auto f = Fixture.setup();
        f.stubBatch(supportsBatchUpdates, 1, 1);

        const rowsAffected = f.client.sql(UPDATE_NAMED_PARAMETERS).batch().entry((JdbcClient.BatchEntry entry) {
            entry.param("perfId", Any.of(1), Types.DECIMAL).param("priceId", Any.of(1), Types.INTEGER);
        }).entry((JdbcClient.BatchEntry entry) {
            entry.param("perfId", Any.of(2), Types.DECIMAL).param("priceId", Any.of(2), Types.INTEGER);
        }).update();

        assert(rowsAffected == [1, 1]);
        string[] expected = [
            "con.prepareStatement(" ~ UPDATE_NAMED_PARAMETERS_PARSED ~ ")", "ps.setObject(1,1,3)",
            "ps.setObject(2,1,4)"
        ];
        if (supportsBatchUpdates)
            expected ~= "ps.addBatch";
        expected ~= ["ps.setObject(1,2,3)", "ps.setObject(2,2,4)"];
        if (supportsBatchUpdates)
            expected ~= "ps.addBatch";
        f.verifyInOrder(expected ~ ["ps.close", "con.close"]);
    }
}

@("JdbcClientNamedParameterTests.updateWithGeneratedKeys")
unittest
{
    auto f = Fixture.setup();
    f.stubGeneratedKeys([true, false], Any.of(11));
    f.preparedStatement.updateCount = 1;

    KeyHolder generatedKeyHolder = new GeneratedKeyHolder();
    const rowsAffected = f.client.sql(INSERT_GENERATE_KEYS).param("name", "rod").update(generatedKeyHolder);

    assert(rowsAffected == 1);
    assertKeyList(generatedKeyHolder, 11);
    assert(generatedKeyHolder.getKey().get!int == 11);
    f.verify("con.prepareStatement(" ~ INSERT_GENERATE_KEYS_PARSED ~ ",1)");
    f.verify("ps.setString(1,rod)");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("JdbcClientNamedParameterTests.batchUpdateWithGeneratedKeys")
unittest
{
    foreach (supportsBatchUpdates; [true, false])
    {
        auto f = Fixture.setup();
        f.stubBatch(supportsBatchUpdates, 1, 1);
        f.stubGeneratedKeys([true, true, false], Any.of(11), Any.of(12));

        KeyHolder generatedKeyHolder = new GeneratedKeyHolder();
        const rowsAffected = f.client.sql(INSERT_GENERATE_KEYS).batch().entry((JdbcClient.BatchEntry entry) {
            entry.param("name", "rod");
        }).entry((JdbcClient.BatchEntry entry) { entry.param("name", "johnson"); }).update(generatedKeyHolder);

        assert(rowsAffected == [1, 1]);
        assertKeyList(generatedKeyHolder, 11, 12);
        string[] expected = [
            "con.prepareStatement(" ~ INSERT_GENERATE_KEYS_PARSED ~ ",1)", "ps.setString(1,rod)"
        ];
        expected ~= supportsBatchUpdates ? "ps.addBatch" : "rs.close";
        expected ~= "ps.setString(1,johnson)";
        if (supportsBatchUpdates)
            expected ~= "ps.addBatch";
        f.verifyInOrder(expected ~ ["rs.close", "ps.close", "con.close"]);
    }
}

@("JdbcClientNamedParameterTests.updateWithGeneratedKeysAndKeyColumnNames")
unittest
{
    auto f = Fixture.setup();
    f.stubGeneratedKeys([true, false], Any.of(11));
    f.preparedStatement.updateCount = 1;

    KeyHolder generatedKeyHolder = new GeneratedKeyHolder();
    const rowsAffected = f.client.sql(INSERT_GENERATE_KEYS).param("name", "rod").update(generatedKeyHolder, "id");

    assert(rowsAffected == 1);
    assertKeyList(generatedKeyHolder, 11);
    assert(generatedKeyHolder.getKey().get!int == 11);
    f.verify("con.prepareStatement(" ~ INSERT_GENERATE_KEYS_PARSED ~ ",[id])");
    f.verify("ps.setString(1,rod)");
    f.verify("rs.close");
    f.verify("ps.close");
    f.verify("con.close");
}

@("JdbcClientNamedParameterTests.batchUpdateWithGeneratedKeysAndKeyColumnNames")
unittest
{
    foreach (supportsBatchUpdates; [true, false])
    {
        auto f = Fixture.setup();
        f.stubBatch(supportsBatchUpdates, 1, 1);
        f.stubGeneratedKeys([true, true, false], Any.of(11), Any.of(12));

        KeyHolder generatedKeyHolder = new GeneratedKeyHolder();
        const rowsAffected = f.client.sql(INSERT_GENERATE_KEYS).batch().entry((JdbcClient.BatchEntry entry) {
            entry.param("name", "rod");
        }).entry((JdbcClient.BatchEntry entry) { entry.param("name", "johnson"); }).update(generatedKeyHolder, "id");

        assert(rowsAffected == [1, 1]);
        assertKeyList(generatedKeyHolder, 11, 12);
        string[] expected = [
            "con.prepareStatement(" ~ INSERT_GENERATE_KEYS_PARSED ~ ",[id])", "ps.setString(1,rod)"
        ];
        expected ~= supportsBatchUpdates ? "ps.addBatch" : "rs.close";
        expected ~= "ps.setString(1,johnson)";
        if (supportsBatchUpdates)
            expected ~= "ps.addBatch";
        f.verifyInOrder(expected ~ ["rs.close", "ps.close", "con.close"]);
    }
}
