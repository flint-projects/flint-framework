/++
`SimpleJdbcInsert` with `usingGeneratedKeyColumns` and `executeAndReturnKey`, the path spring-petclinic-rest's JDBC
repositories take on PostgreSQL. No upstream test covers it, since `SimpleJdbcInsertTests` stops at the insert
string; these are Flint's own. `BlackHole` fakes of `flint.java.sql` stand in for the driver: the meta-data reports
PostgreSQL with `getGeneratedKeys` support, and the statement records each call and returns scripted keys.
+/
module flint.jdbc.simple_jdbc_insert_generated_keys_tests;

import flint.dao : DataIntegrityViolationException;
import flint.engine.aot.any : Any;
import flint.java.sql : Connection, DatabaseMetaData, PreparedStatement, ResultSet, ResultSetMetaData, Types;
import flint.java.util : LinkedHashMap;
import flint.javax.sql : DataSource;
import flint.jdbc.core.namedparam : MapSqlParameterSource;
import flint.jdbc.core.simple : SimpleJdbcInsert;
import std.typecons : BlackHole;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fakes

private final class Log
{
    string[] entries;
}

/// Rows read by column label (meta-data) or by index (generated keys).
private final class Rows : BlackHole!ResultSet
{
    private string[] labels;
    private Any[][] rows;
    private size_t position;

    this(string[] labels, Any[][] rows)
    {
        this.labels = labels;
        this.rows = rows;
    }

    override bool next()
    {
        return ++position <= rows.length;
    }

    private Any value(string label)
    {
        foreach (i, l; labels)
            if (l == label)
                return rows[position - 1][i];
        return Any.init;
    }

    override string getString(string label)
    {
        auto v = value(label);
        return v.isNull ? null : v.get!string;
    }

    override int getInt(string label)
    {
        auto v = value(label);
        return v.isNull ? 0 : v.get!int;
    }

    override bool getBoolean(string label)
    {
        auto v = value(label);
        return v.isNull ? false : v.get!bool;
    }

    override Any getObject(int column)
    {
        return rows[position - 1][column - 1];
    }

    override ResultSetMetaData getMetaData()
    {
        return new RowsMetaData(labels);
    }
}

private final class RowsMetaData : BlackHole!ResultSetMetaData
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
}

/// PostgreSQL's meta-data for `owners (id serial, first_name varchar)`.
private final class PostgresMetaData : BlackHole!DatabaseMetaData
{
    override string getDatabaseProductName()
    {
        return "PostgreSQL";
    }

    override string getUserName()
    {
        return "petclinic";
    }

    override bool storesLowerCaseIdentifiers()
    {
        return true;
    }

    override bool supportsGetGeneratedKeys()
    {
        return true;
    }

    override string getIdentifierQuoteString()
    {
        return "\"";
    }

    override ResultSet getTables(string catalog, string schemaPattern, string tableNamePattern, string[] types)
    {
        return new Rows(["TABLE_CAT", "TABLE_SCHEM", "TABLE_NAME"], [
            [Any.init, Any.of("public"), Any.of("owners")]
        ]);
    }

    override ResultSet getColumns(string catalog, string schemaPattern, string tableNamePattern,
            string columnNamePattern)
    {
        return new Rows(["COLUMN_NAME", "DATA_TYPE", "NULLABLE"], [
            [Any.of("id"), Any.of(Types.INTEGER), Any.of(false)],
            [Any.of("first_name"), Any.of(Types.VARCHAR), Any.of(true)]
        ]);
    }
}

private final class RecordingStatement : BlackHole!PreparedStatement
{
    private Log log;
    private Any[][] keys;
    private Connection connection;

    this(Log log, Any[][] keys, Connection connection)
    {
        this.log = log;
        this.keys = keys;
        this.connection = connection;
    }

    override Connection getConnection()
    {
        return connection;
    }

    override void setObject(int index, Any value)
    {
        log.entries ~= "setObject(" ~ value.toString() ~ ")";
    }

    override void setObject(int index, Any value, int sqlType)
    {
        log.entries ~= "setObject(" ~ value.toString() ~ ",type)";
    }

    override void setString(int index, string value)
    {
        log.entries ~= "setString(" ~ value ~ ")";
    }

    override int executeUpdate()
    {
        log.entries ~= "executeUpdate";
        return 1;
    }

    override ResultSet getGeneratedKeys()
    {
        return new Rows(["id"], keys);
    }

    override void close()
    {
        log.entries ~= "ps.close";
    }
}

private final class FakeConnection : BlackHole!Connection
{
    private Log log;
    private Any[][] keys;
    private PostgresMetaData metaData;

    this(Log log, Any[][] keys)
    {
        this.log = log;
        this.keys = keys;
        metaData = new PostgresMetaData;
    }

    override DatabaseMetaData getMetaData()
    {
        return metaData;
    }

    override PreparedStatement prepareStatement(string sql, string[] columnNames)
    {
        string names;
        foreach (i, name; columnNames)
            names ~= (i == 0 ? "" : ",") ~ name;
        log.entries ~= "prepareStatement(" ~ sql ~ ";[" ~ names ~ "])";
        return new RecordingStatement(log, keys, this);
    }

    override PreparedStatement prepareStatement(string sql, int autoGeneratedKeys)
    {
        log.entries ~= "prepareStatement(" ~ sql ~ ";RETURN_GENERATED_KEYS)";
        return new RecordingStatement(log, keys, this);
    }

    override void close()
    {
        log.entries ~= "con.close";
    }
}

private final class FakeDataSource : BlackHole!DataSource
{
    private Log log;
    private Any[][] keys;

    this(Log log, Any[][] keys)
    {
        this.log = log;
        this.keys = keys;
    }

    override Connection getConnection()
    {
        return new FakeConnection(log, keys);
    }
}

private bool contains(string[] entries, string entry)
{
    foreach (e; entries)
        if (e == entry)
            return true;
    return false;
}

// ---------------------------------------------------------------------------------------------------------------
// Tests

@("SimpleJdbcInsert: usingGeneratedKeyColumns leaves the key column out and asks the driver for it by name")
unittest
{
    auto log = new Log;
    auto insert = new SimpleJdbcInsert(new FakeDataSource(log, [[Any.of(7)]])).withTableName("owners")
        .usingGeneratedKeyColumns("id");
    auto key = insert.executeAndReturnKey(new MapSqlParameterSource("first_name", "George"));

    assert(insert.getInsertString() == "INSERT INTO owners (first_name) VALUES(?)", insert.getInsertString());
    assert(key.get!int == 7, key.toString());
    assert(log.entries.contains("prepareStatement(INSERT INTO owners (first_name) VALUES(?);[id])"), log.entries[0]);
    assert(log.entries.contains("executeUpdate"));
    assert(log.entries.contains("ps.close"));
    assert(log.entries.contains("con.close"));
}

@("SimpleJdbcInsert: executeAndReturnKey with a Map binds the values in insert-column order")
unittest
{
    auto log = new Log;
    auto insert = new SimpleJdbcInsert(new FakeDataSource(log, [[Any.of(12L)]])).withTableName("owners")
        .usingGeneratedKeyColumns("id");
    auto args = new LinkedHashMap!(string, Any);
    args.put("first_name", Any.of("Betty"));
    auto key = insert.executeAndReturnKey(args);

    assert(key.get!long == 12, key.toString());
    size_t prepared = size_t.max, bound = size_t.max, executed = size_t.max;
    foreach (i, entry; log.entries)
    {
        if (entry.length > 16 && entry[0 .. 16] == "prepareStatement")
            prepared = i;
        else if (entry == "setString(Betty)" || entry == "setObject(Betty,type)" || entry == "setObject(Betty)")
            bound = i;
        else if (entry == "executeUpdate")
            executed = i;
    }
    assert(prepared < bound && bound < executed, "prepare, bind, execute");
}

@("SimpleJdbcInsert: executeAndReturnKey without a generated key throws DataIntegrityViolationException")
unittest
{
    auto log = new Log;
    auto insert = new SimpleJdbcInsert(new FakeDataSource(log, [])).withTableName("owners")
        .usingGeneratedKeyColumns("id");
    try
    {
        insert.executeAndReturnKey(new MapSqlParameterSource("first_name", "Jean"));
        assert(false, "expected DataIntegrityViolationException");
    }
    catch (DataIntegrityViolationException ex)
        assert(ex.msg == "Unable to retrieve the generated key for the insert: "
                ~ "INSERT INTO owners (first_name) VALUES(?)", ex.msg);
}
