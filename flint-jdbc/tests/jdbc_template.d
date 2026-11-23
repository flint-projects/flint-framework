// Ported from spring-framework v7.1.0: spring-jdbc/src/test/java/org/springframework/jdbc/core/JdbcTemplateTests.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: JdbcTemplateQueryTests.java, RowMapperTests.java, SingleColumnRowMapperTests.java and
// support/KeyHolderTests.java.

/++
The core of `JdbcTemplateTests`, `JdbcTemplateQueryTests`, `RowMapperTests`, `SingleColumnRowMapperTests` and
`KeyHolderTests`. Hand-written fakes of `flint.java.sql` replace Mockito: a `FakeResultSet` serves scripted rows,
and statements and connections log their calls, so `verify(con).close()` becomes a count in the log. The
callable-statement, `SqlRowSet` and stream cases follow with those features (Phase 2).
+/
module flint.jdbc.jdbc_template_test;

import flint.dao : DataAccessException, IncorrectResultSizeDataAccessException, InvalidDataAccessApiUsageException;
import flint.engine.aot.any : Any;
import flint.java.sql : Connection, DatabaseMetaData, PreparedStatement, ResultSet,
    ResultSetMetaData, SQLException, Statement, Types;
import flint.java.util : ArrayList, LinkedHashMap, List, Map;
import flint.javax.sql : DataSource;
import flint.jdbc : BadSqlGrammarException, IncorrectResultSetColumnCountException, UncategorizedSQLException;
import flint.jdbc.core;
import flint.jdbc.datasource : DataSourceTransactionManager;
import flint.jdbc.support : GeneratedKeyHolder, KeyHolder;
import flint.transaction : TransactionStatus;
import flint.transaction.support : TransactionSynchronizationManager, TransactionTemplate;
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
}

private final class FakeMetaData : BlackHole!ResultSetMetaData
{
    private string[] labels;

    this(string[] labels)
    {
        this.labels = labels;
    }

    override int getColumnCount()
    {
        return cast(int) labels.length;
    }

    override string getColumnLabel(int column)
    {
        return labels[column - 1];
    }

    override string getColumnName(int column)
    {
        return labels[column - 1];
    }

    override int getColumnType(int)
    {
        return Types.VARCHAR;
    }
}

/// A result set over scripted rows.
private final class FakeResultSet : BlackHole!ResultSet
{
    private string[] labels;
    private Any[][] rows;
    private size_t position;
    private Log log;
    private bool lastNull;

    this(Log log, string[] labels, Any[][] rows)
    {
        this.log = log;
        this.labels = labels;
        this.rows = rows;
    }

    override bool next()
    {
        return ++position <= rows.length;
    }

    override void close()
    {
        log.entries ~= "rs.close";
    }

    override int findColumn(string label)
    {
        foreach (i, l; labels)
            if (l == label)
                return cast(int) i + 1;
        throw new SQLException("no column " ~ label);
    }

    override Any getObject(int column)
    {
        auto value = rows[position - 1][column - 1];
        lastNull = value.isNull;
        return value;
    }

    override Any getObject(string label)
    {
        return getObject(findColumn(label));
    }

    override string getString(int column)
    {
        auto value = getObject(column);
        return value.isNull ? null : value.get!string;
    }

    override string getString(string label)
    {
        return getString(findColumn(label));
    }

    override long getLong(int column)
    {
        auto value = getObject(column);
        return value.isNull ? 0 : value.get!long;
    }

    override long getLong(string label)
    {
        return getLong(findColumn(label));
    }

    override int getInt(int column)
    {
        return cast(int) getLong(column);
    }

    override bool wasNull()
    {
        return lastNull;
    }

    override ResultSetMetaData getMetaData()
    {
        return new FakeMetaData(labels);
    }
}

private final class FakeDatabaseMetaData : BlackHole!DatabaseMetaData
{
    bool batches = true;

    override bool supportsBatchUpdates()
    {
        return batches;
    }
}

/// A prepared statement that logs bound parameters and serves a scripted result.
private final class FakePreparedStatement : BlackHole!PreparedStatement
{
    private FakeConnection connection;
    string sql;
    Any[int] parameters;
    string[] boundRows;
    int updateCount = 1;
    SQLException failure;

    this(FakeConnection connection, string sql)
    {
        this.connection = connection;
        this.sql = sql;
    }

    private string row()
    {
        import std.conv : to;

        string text;
        foreach (i; 1 .. cast(int) parameters.length + 1)
            text ~= (i > 1 ? "," : "") ~ (i in parameters ? parameters[i].toString() : "?");
        return text;
    }

    override void setObject(int index, Any value)
    {
        parameters[index] = value;
    }

    override void setNull(int index, int)
    {
        parameters[index] = Any.init;
    }

    override void setString(int index, string value)
    {
        parameters[index] = Any.of(value);
    }

    override ResultSet executeQuery()
    {
        connection.log.entries ~= "ps.executeQuery(" ~ row() ~ ")";
        if (failure !is null)
            throw failure;
        return connection.nextResult();
    }

    override int executeUpdate()
    {
        connection.log.entries ~= "ps.executeUpdate(" ~ row() ~ ")";
        if (failure !is null)
            throw failure;
        return updateCount;
    }

    override void addBatch()
    {
        boundRows ~= row();
        parameters = null;
    }

    override int[] executeBatch()
    {
        connection.log.entries ~= "ps.executeBatch";
        auto counts = new int[boundRows.length];
        counts[] = 1;
        return counts;
    }

    override ResultSet getGeneratedKeys()
    {
        return new FakeResultSet(connection.log, ["id"], [[Any.of(42L)]]);
    }

    override Connection getConnection()
    {
        return connection;
    }

    override void setMaxRows(int max)
    {
        connection.log.entries ~= "ps.setMaxRows";
    }

    override void close()
    {
        connection.log.entries ~= "ps.close";
    }
}

private final class FakeStatement : BlackHole!Statement
{
    private FakeConnection connection;
    string[] batch;
    SQLException failure;

    this(FakeConnection connection)
    {
        this.connection = connection;
    }

    override bool execute(string sql)
    {
        connection.log.entries ~= "stmt.execute(" ~ sql ~ ")";
        if (failure !is null)
            throw failure;
        return false;
    }

    override ResultSet executeQuery(string sql)
    {
        connection.log.entries ~= "stmt.executeQuery(" ~ sql ~ ")";
        if (failure !is null)
            throw failure;
        return connection.nextResult();
    }

    override int executeUpdate(string sql)
    {
        connection.log.entries ~= "stmt.executeUpdate(" ~ sql ~ ")";
        return 4;
    }

    override void addBatch(string sql)
    {
        batch ~= sql;
    }

    override int[] executeBatch()
    {
        connection.log.entries ~= "stmt.executeBatch";
        auto counts = new int[batch.length];
        counts[] = 1;
        return counts;
    }

    override Connection getConnection()
    {
        return connection;
    }

    override void close()
    {
        connection.log.entries ~= "stmt.close";
    }
}

private final class FakeConnection : BlackHole!Connection
{
    Log log;
    FakeResultSet[] results;
    FakePreparedStatement lastPrepared;
    SQLException failure;
    FakeDatabaseMetaData metaData;
    bool autoCommit = true;

    this()
    {
        log = new Log;
        metaData = new FakeDatabaseMetaData;
    }

    void serve(string[] labels, Any[][] rows)
    {
        results ~= new FakeResultSet(log, labels, rows);
    }

    ResultSet nextResult()
    {
        assert(results.length > 0, "no result set served");
        auto rs = results[0];
        results = results[1 .. $];
        return rs;
    }

    override Statement createStatement()
    {
        auto stmt = new FakeStatement(this);
        stmt.failure = failure;
        return stmt;
    }

    override PreparedStatement prepareStatement(string sql)
    {
        log.entries ~= "prepareStatement(" ~ sql ~ ")";
        lastPrepared = new FakePreparedStatement(this, sql);
        lastPrepared.failure = failure;
        return lastPrepared;
    }

    override DatabaseMetaData getMetaData()
    {
        return metaData;
    }

    override bool getAutoCommit()
    {
        return autoCommit;
    }

    override void setAutoCommit(bool value)
    {
        autoCommit = value;
    }

    override void commit()
    {
        log.entries ~= "commit";
    }

    override void rollback()
    {
        log.entries ~= "rollback";
    }

    override void close()
    {
        log.entries ~= "con.close";
    }
}

private final class FakeDataSource : BlackHole!DataSource
{
    FakeConnection connection;
    int handedOut;

    this(FakeConnection connection)
    {
        this.connection = connection;
    }

    override Connection getConnection()
    {
        ++handedOut;
        return connection;
    }
}

private final class Customer
{
    long id;
    string firstName, lastName;

    this(long id, string firstName, string lastName)
    {
        this.id = id;
        this.firstName = firstName;
        this.lastName = lastName;
    }

    override string toString() const
    {
        import std.conv : to;

        return "Customer[id=" ~ id.to!string ~ ", firstName='" ~ firstName ~ "', lastName='" ~ lastName ~ "']";
    }
}

private struct Fixture
{
    FakeConnection con;
    FakeDataSource ds;
    JdbcTemplate template_;

    static Fixture create()
    {
        Fixture f;
        f.con = new FakeConnection;
        f.ds = new FakeDataSource(f.con);
        f.template_ = new JdbcTemplate(f.ds);
        return f;
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
// The gs-relational-data-access calls

@("JdbcTemplate: execute, batchUpdate(sql, rows) and query(sql, lambda, args) as gs-relational-data-access uses them")
unittest
{
    auto f = Fixture.create();
    f.template_.execute("DROP TABLE IF EXISTS customers");
    f.template_.execute(
            "CREATE TABLE customers(id INTEGER PRIMARY KEY, first_name VARCHAR(255), last_name VARCHAR(255))");
    const counts = f.template_.batchUpdate("INSERT INTO customers(first_name, last_name) VALUES (?,?)",
            [["John", "Woo"], ["Jeff", "Dean"], ["Josh", "Bloch"], ["Josh", "Long"]]);
    assert(counts == [1, 1, 1, 1]);
    assert(f.con.lastPrepared.boundRows == ["John,Woo", "Jeff,Dean", "Josh,Bloch", "Josh,Long"]);

    f.con.serve(["id", "first_name", "last_name"], [
        [Any.of(3L), Any.of("Josh"), Any.of("Bloch")], [Any.of(4L), Any.of("Josh"), Any.of("Long")]
    ]);
    auto customers = f.template_.query("SELECT id, first_name, last_name FROM customers WHERE first_name = ?",
            (rs, rowNum) => new Customer(rs.getLong("id"), rs.getString("first_name"), rs.getString("last_name")),
            "Josh");
    string[] printed;
    customers.forEach((Customer customer) { printed ~= customer.toString(); });
    assert(printed == [
        "Customer[id=3, firstName='Josh', lastName='Bloch']",
        "Customer[id=4, firstName='Josh', lastName='Long']"
    ]);
    assert(f.con.log.count("ps.executeQuery(Josh)") == 1);
    assert(f.con.log.count("con.close") == 4, "each operation releases its connection");
    assert(f.con.log.count("stmt.close") == 2 && f.con.log.count("ps.close") == 2 && f.con.log.count("rs.close") == 1);
}

// ---------------------------------------------------------------------------------------------------------------
// JdbcTemplateTests

@("testUpdateCount and update(sql, args...) bind their arguments and release the connection")
unittest
{
    auto f = Fixture.create();
    assert(f.template_.update("UPDATE seat_status SET booking_id = NULL") == 4);
    assert(f.template_.update("UPDATE seat_status SET booking_id = NULL WHERE seat = ? AND booking_id = ?", 1, 2) == 1);
    assert(f.con.log.count("ps.executeUpdate(1,2)") == 1);
    assert(f.con.log.count("con.close") == 2 && f.con.log.count("ps.close") == 1);
}

@("testBatchUpdate of static SQL statements uses JDBC batching when the driver supports it")
unittest
{
    auto f = Fixture.create();
    const counts = f.template_.batchUpdate("UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = 1",
            "UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = 2");
    assert(counts == [1, 1]);
    assert(f.con.log.count("stmt.executeBatch") == 1 && f.con.log.count("stmt.close") == 1);
    assert(f.con.log.count("con.close") == 1);
}

@("testBatchUpdateWithPreparedStatement and a driver without batch support")
unittest
{
    auto f = Fixture.create();
    f.con.metaData.batches = false;
    final class Setter : BatchPreparedStatementSetter
    {
        override void setValues(PreparedStatement ps, int i)
        {
            ps.setObject(1, Any.of(cast(long)(i + 100)));
        }

        override int getBatchSize()
        {
            return 2;
        }
    }

    const counts = f.template_.batchUpdate("UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?", new Setter);
    assert(counts == [1, 1]);
    assert(f.con.log.count("ps.executeUpdate(100)") == 1 && f.con.log.count("ps.executeUpdate(101)") == 1);
}

@("testBatchUpdateWithListOfObjectArrays and SqlParameterValue arguments")
unittest
{
    auto f = Fixture.create();
    Any[][] rows = [[Any.of(100L), Any.of(1L)], [Any.of(200L), Any.of(2L)]];
    assert(f.template_.batchUpdate("UPDATE NOSUCHTABLE SET DATE_DISPATCHED = SYSDATE WHERE ID = ?", rows) == [
        1, 1
    ]);
    assert(f.con.lastPrepared.boundRows == ["100,1", "200,2"]);
    assert(f.template_.batchUpdate("UPDATE X", cast(Any[][]) null).length == 0, "an empty batch issues nothing");

    Any[][] typed = [
        [Any.ofObject(new SqlParameterValue(Types.VARCHAR, Any.of(7L)), "SqlParameterValue")]
    ];
    f.template_.batchUpdate("UPDATE X SET Y = ?", typed);
    assert(f.con.lastPrepared.boundRows == ["7"], "a VARCHAR parameter value is bound as text");
}

@("SQLException translation: a 42xxx state is BadSqlGrammarException; the connection is still released")
unittest
{
    auto f = Fixture.create();
    f.con.failure = new SQLException("bad SQL", "42000");
    expectThrows!BadSqlGrammarException({ f.template_.queryForList("SELECT * FROM missing"); });
    expectThrows!BadSqlGrammarException({ f.template_.update("UPDATE missing SET x = ?", 1); });
    assert(f.con.log.count("con.close") == 2 && f.con.log.count("ps.close") == 1 && f.con.log.count("stmt.close") == 1);

    f.con.failure = new SQLException("odd", "XX123");
    expectThrows!UncategorizedSQLException({ f.template_.execute("SELECT 1"); });
}

@("testUpdateReturningGeneratedKeys stores the keys in the KeyHolder")
unittest
{
    auto f = Fixture.create();
    auto keyHolder = new GeneratedKeyHolder;
    const rows = f.template_.update(preparedStatementCreator((Connection con) {
            auto ps = con.prepareStatement("INSERT INTO customers(first_name) VALUES (?)");
            ps.setString(1, "Rod");
            return ps;
        }), keyHolder);
    assert(rows == 1);
    assert(keyHolder.getKey().get!long == 42);
    assert(keyHolder.getKeyAs!long() == 42);
    assert(keyHolder.getKeys().get("id").get!long == 42);
}

@("JdbcTemplate joins the current transaction: one connection, kept open until commit")
unittest
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(new DataSourceTransactionManager(f.ds));
    tt.executeWithoutResult((TransactionStatus status) {
        f.template_.update("INSERT INTO x VALUES (?)", 1);
        f.template_.update("INSERT INTO x VALUES (?)", 2);
        assert(f.con.log.count("con.close") == 0, "the transactional connection stays open");
        assert(status.isNewTransaction());
    });
    assert(f.ds.handedOut == 1);
    assert(f.con.log.count("commit") == 1 && f.con.log.count("con.close") == 1);
    assert(TransactionSynchronizationManager.getResourceMap().length == 0);
}

// ---------------------------------------------------------------------------------------------------------------
// JdbcTemplateQueryTests

@("testQueryForList and testQueryForMap return one map per row, keyed by column label")
unittest
{
    auto f = Fixture.create();
    f.con.serve(["age"], [[Any.of(11L)], [Any.of(12L)]]);
    auto list = f.template_.queryForList("SELECT AGE FROM CUSTMR WHERE ID < 3");
    assert(list.size() == 2 && list.get(0).get("age").get!long == 11 && list.get(1).get("age").get!long == 12);

    f.con.serve(["age"], [[Any.of(11L)]]);
    auto map = f.template_.queryForMap("SELECT AGE FROM CUSTMR WHERE ID < ?", 3);
    assert(map.get("age").get!long == 11);
    assert(f.con.log.count("ps.executeQuery(3)") == 1);
}

@("testQueryForObjectThrowsIncorrectResultSizeForMoreThanOneRow and for no row")
unittest
{
    auto f = Fixture.create();
    f.con.serve(["name"], [[Any.of("rod")], [Any.of("juergen")]]);
    expectThrows!IncorrectResultSizeDataAccessException({
        f.template_.queryForObject!string("SELECT NAME FROM CUSTMR");
    });
    f.con.serve(["name"], []);
    expectThrows!IncorrectResultSizeDataAccessException({
        f.template_.queryForObject!string("SELECT NAME FROM CUSTMR WHERE ID = ?", 99);
    });
}

@("testQueryForObjectWithRowMapper, testQueryForObjectWithLong and testQueryForListWithString")
unittest
{
    auto f = Fixture.create();
    f.con.serve(["id"], [[Any.of(22L)]]);
    enum sql = "SELECT AGE FROM CUSTMR WHERE ID = 3";
    const value = f.template_.queryForObject(sql, (ResultSet rs, int) => rs.getInt(1));
    assert(value == 22);

    f.con.serve(["age"], [[Any.of(22L)]]);
    assert(f.template_.queryForObject!long("SELECT AGE FROM CUSTMR WHERE ID = ?", 3) == 22);

    f.con.serve(["name"], [[Any.of("rod")], [Any.of("juergen")]]);
    auto names = f.template_.queryForList!string("SELECT NAME FROM CUSTMR WHERE ID < ?", 3);
    assert(names.toArray() == ["rod", "juergen"]);
}

@("query with RowCallbackHandler, ResultSetExtractor and maxRows")
unittest
{
    auto f = Fixture.create();
    f.con.serve(["n"], [[Any.of(1L)], [Any.of(2L)], [Any.of(3L)]]);
    long sum;
    f.template_.query("SELECT n FROM t WHERE n > ?", (ResultSet rs) { sum += rs.getLong(1); }, 0);
    assert(sum == 6);

    f.con.serve(["n"], [[Any.of(1L)], [Any.of(2L)], [Any.of(3L)]]);
    final class Counter : ResultSetExtractor!int
    {
        override int extractData(ResultSet rs)
        {
            int n;
            while (rs.next())
                ++n;
            return n;
        }
    }

    assert(f.template_.query("SELECT n FROM t", new Counter) == 3);

    f.con.serve(["n"], [[Any.of(1L)], [Any.of(2L)], [Any.of(3L)]]);
    f.template_.setMaxRows(2);
    auto limited = f.template_.query("SELECT n FROM t", (ResultSet rs, int) => rs.getLong(1));
    assert(limited.size() == 2);
}

// ---------------------------------------------------------------------------------------------------------------
// RowMapperTests and SingleColumnRowMapperTests

@("SingleColumnRowMapperTests: more than one column is IncorrectResultSetColumnCountException")
unittest
{
    auto f = Fixture.create();
    f.con.serve(["a", "b"], [[Any.of(1L), Any.of(2L)]]);
    expectThrows!IncorrectResultSetColumnCountException({
        f.template_.queryForList!long("SELECT a, b FROM t");
    });
}

@("RowMapperTests: a RowMapper object maps each row with its index")
unittest
{
    auto f = Fixture.create();
    f.con.serve(["name"], [[Any.of("Bubba")], [Any.of("Bubba Jr.")]]);
    final class NameMapper : RowMapper!string
    {
        override string mapRow(ResultSet rs, int rowNum)
        {
            import std.conv : to;

            return rs.getString(1) ~ "#" ~ rowNum.to!string;
        }
    }

    auto names = f.template_.query("SELECT name FROM people", new NameMapper);
    assert(names.toArray() == ["Bubba#0", "Bubba Jr.#1"]);
}

// ---------------------------------------------------------------------------------------------------------------
// KeyHolderTests

@("KeyHolderTests: single key, no key list, multiple keys and multiple rows")
unittest
{
    auto kh = new GeneratedKeyHolder;
    assert(kh.getKey().isNull && kh.getKeys() is null);

    auto row = new LinkedHashMap!(string, Any);
    row.put("key", Any.of(1L));
    kh.getKeyList().add(row);
    assert(kh.getKey().get!long == 1 && kh.getKeyAs!long() == 1);
    expectThrows!DataAccessException({ kh.getKeyAs!string(); });

    row.put("seq", Any.of(2L));
    expectThrows!InvalidDataAccessApiUsageException({ kh.getKey(); });
    assert(kh.getKeys().size() == 2);

    auto second = new LinkedHashMap!(string, Any);
    second.put("key", Any.of(3L));
    kh.getKeyList().add(second);
    expectThrows!InvalidDataAccessApiUsageException({ kh.getKeys(); });
}
