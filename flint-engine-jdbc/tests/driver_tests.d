module flint.engine.jdbc.driver_tests;

import flint.engine.aot.any : Any;
import flint.engine.jdbc;
import flint.engine.sql : EngineDriver = Driver;
import flint.java.sql;
import std.process : environment;

@safe:

@("numberParameters rewrites ? markers outside literals, identifiers, comments and dollar quotes")
unittest
{
    size_t count;
    const rewritten = numberParameters("select * from t where a = ? and b = ?", count);
    assert(rewritten == "select * from t where a = $1 and b = $2");
    assert(count == 2);
    assert(numberParameters("select '?', \"q?\", 'it''s ?' from t where x = ?",
            count) == "select '?', \"q?\", 'it''s ?' from t where x = $1");
    assert(count == 1);
    assert(numberParameters("select 1 -- ok?\n, ? /* why? */, $$a?b$$",
            count) == "select 1 -- ok?\n, $1 /* why? */, $$a?b$$");
    assert(count == 1);
    assert(numberParameters("select 1", count) == "select 1" && count == 0);
}

@("parseUrl maps JDBC URLs to engine settings and rejects other drivers")
unittest
{
    const sqlite = parseUrl("jdbc:sqlite:/var/data/app.db", null);
    assert(sqlite.driver == EngineDriver.sqlite && sqlite.connectionString == "/var/data/app.db");
    assert(parseUrl("jdbc:sqlite::memory:", null).connectionString == "file:flint-memory?mode=memory&cache=shared");

    const pg = parseUrl("jdbc:postgresql://db.example:6543/shop?sslmode=disable", [
        "user": "app",
        "password": "it's"
    ]);
    assert(pg.driver == EngineDriver.postgres);
    assert(pg.connectionString
            == "host='db.example' port='6543' dbname='shop' user='app' password='it\\'s' sslmode='disable'",
            pg.connectionString);
    assert(parseUrl("jdbc:postgresql:shop", null).connectionString == "host='localhost' dbname='shop'");
    assert(parseUrl("jdbc:postgresql://[::1]:5432/x", null).connectionString == "host='[::1]' port='5432' dbname='x'");
    try
    {
        parseUrl("jdbc:mysql://localhost/x", null);
        assert(false, "expected SQLException");
    }
    catch (SQLException ex)
        assert(ex.getSQLState() == "08001");
}

@("FlintDriver is registered with DriverManager and accepts only its URLs")
unittest
{
    assert(DriverManager.getDriver("jdbc:sqlite::memory:") !is null);
    auto driver = new FlintDriver;
    assert(driver.acceptsURL("jdbc:postgresql://localhost/x"));
    assert(!driver.acceptsURL("jdbc:h2:mem:x"));
    assert(driver.connect("jdbc:h2:mem:x", null) is null, "Driver.connect returns null for a URL it does not accept");
}

version (FlintNativeSqlite)
{
    @("JDBC on SQLite: statements, rows, keys, transactions, savepoints and SQLSTATE subclasses")
    unittest
    {
        auto connection = DriverManager.getConnection("jdbc:sqlite:file:flint-jdbc-driver?mode=memory&cache=shared");
        scope (exit)
            connection.close();
        exercise(connection, "jdbc_customers");
        assert(connection.getMetaData().getDatabaseProductName() == "SQLite");
    }

    @("FlintDataSource pools engine leases and applies its connection defaults")
    unittest
    {
        auto source = new FlintDataSource("jdbc:sqlite:file:flint-jdbc-pool?mode=memory&cache=shared");
        source.setMaximumPoolSize(2);
        source.setAutoCommit(false);
        scope (exit)
            source.close();
        auto first = source.getConnection();
        auto second = source.getConnection();
        assert(!first.getAutoCommit() && !second.getAutoCommit());
        first.createStatement().executeUpdate("CREATE TABLE pooled (id INTEGER PRIMARY KEY)");
        first.commit();
        first.close();
        second.close();
        auto third = source.getConnection();
        auto rows = third.createStatement().executeQuery("SELECT count(*) AS n FROM pooled");
        assert(rows.next() && rows.getInt("n") == 0);
        third.close();
        try
        {
            source.setJdbcUrl("jdbc:sqlite::memory:");
            assert(false, "a started pool's configuration is fixed");
        }
        catch (Exception)
        {
        }
    }
}

@("JDBC on PostgreSQL, when FLINT_JDBC_PG_TEST_URL names a server")
unittest
{
    const url = environment.get("FLINT_JDBC_PG_TEST_URL");
    if (url.length == 0)
        return;
    auto connection = DriverManager.getConnection(url, environment.get("FLINT_JDBC_PG_TEST_USER"),
            environment.get("FLINT_JDBC_PG_TEST_PASSWORD"));
    scope (exit)
        connection.close();
    exercise(connection, "jdbc_customers");
    assert(connection.getMetaData().getDatabaseProductName() == "PostgreSQL");
}

/// The behaviour both engines share.
private void exercise(Connection connection, string table)
{
    auto statement = connection.createStatement();
    statement.execute("DROP TABLE IF EXISTS " ~ table);
    assert(!statement.execute("CREATE TABLE " ~ table
            ~ " (id INTEGER PRIMARY KEY, first_name VARCHAR(255) UNIQUE NOT NULL, score DOUBLE PRECISION, note TEXT)"));

    // Prepared inserts, a batch among them.
    auto insert = connection.prepareStatement(
            "INSERT INTO " ~ table ~ " (id, first_name, score, note) VALUES (?, ?, ?, ?)");
    insert.setInt(1, 1);
    insert.setString(2, "John");
    insert.setDouble(3, 1.5);
    insert.setNull(4, Types.VARCHAR);
    assert(insert.executeUpdate() == 1);
    foreach (index, name; ["Jeff", "Josh", "Hannah"])
    {
        insert.setInt(1, cast(int) index + 2);
        insert.setString(2, name);
        insert.setObject(3, Any.of(cast(long) index));
        insert.setString(4, "it's " ~ name);
        insert.addBatch();
    }
    assert(insert.executeBatch() == [1, 1, 1]);

    // Rows: typed getters, labels, nulls and metadata.
    auto query = connection.prepareStatement(
            "SELECT id, first_name, score, note FROM " ~ table ~ " WHERE id >= ? ORDER BY id");
    query.setLong(1, 1);
    auto rows = query.executeQuery();
    assert(rows.next());
    assert(rows.getInt(1) == 1 && rows.getString("FIRST_NAME") == "John" && rows.getDouble("score") == 1.5);
    assert(rows.getString("note") is null && rows.wasNull());
    assert(rows.getObject("id").get!long == 1);
    auto meta = rows.getMetaData();
    assert(meta.getColumnCount() == 4 && meta.getColumnLabel(2) == "first_name");
    string[] names;
    do
        names ~= rows.getString(2);
    while (rows.next());
    assert(names == ["John", "Jeff", "Josh", "Hannah"]);
    assert(!rows.next());
    try
    {
        rows.findColumn("missing");
        assert(false, "expected SQLException");
    }
    catch (SQLException)
    {
    }

    // maxRows truncates.
    query.setMaxRows(2);
    rows = query.executeQuery();
    int seen;
    while (rows.next())
        ++seen;
    assert(seen == 2);

    // Generated keys.
    auto keyed = connection.prepareStatement("INSERT INTO " ~ table ~ " (id, first_name) VALUES (?, ?)", [
        "id"
    ]);
    keyed.setInt(1, 42);
    keyed.setString(2, "Keyed");
    assert(keyed.executeUpdate() == 1);
    auto keys = keyed.getGeneratedKeys();
    assert(keys.next() && keys.getLong(1) == 42);

    // SQLSTATE subclasses.
    insert.setInt(1, 99);
    insert.setString(2, "John");
    insert.setNull(3, Types.DOUBLE);
    insert.setNull(4, Types.VARCHAR);
    try
    {
        insert.executeUpdate();
        assert(false, "expected a unique violation");
    }
    catch (SQLIntegrityConstraintViolationException ex)
        assert(ex.getSQLState() == "23505", ex.getSQLState());
    try
    {
        statement.executeQuery("SELEC 1");
        assert(false, "expected a syntax error");
    }
    catch (SQLSyntaxErrorException ex)
        assert(ex.getSQLState()[0 .. 2] == "42");

    // Manual commit: rollback discards, commit keeps, savepoints undo part of a transaction.
    connection.setAutoCommit(false);
    statement.executeUpdate("DELETE FROM " ~ table ~ " WHERE id = 1");
    connection.rollback();
    assert(count(connection, table) == 5);
    statement.executeUpdate("DELETE FROM " ~ table ~ " WHERE id = 1");
    auto savepoint = connection.setSavepoint();
    statement.executeUpdate("DELETE FROM " ~ table ~ " WHERE id = 2");
    connection.rollback(savepoint);
    connection.commit();
    connection.setAutoCommit(true);
    assert(count(connection, table) == 4);
    try
    {
        connection.commit();
        assert(false, "commit in auto-commit mode");
    }
    catch (SQLException)
    {
    }

    statement.execute("DROP TABLE " ~ table);
    statement.close();
    try
    {
        statement.executeQuery("SELECT 1");
        assert(false, "a closed statement refuses work");
    }
    catch (SQLException)
    {
    }
}

private long count(Connection connection, string table)
{
    auto rows = connection.createStatement().executeQuery("SELECT count(*) FROM " ~ table);
    assert(rows.next());
    return rows.getLong(1);
}
