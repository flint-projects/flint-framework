/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/simple/TableMetaDataContextTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. Hand-written
`BlackHole` fakes of `flint.java.sql` replace the Mockito mocks: a `ScriptedResultSet` serves rows by column label,
the `DatabaseMetaData` fake answers `getTables`/`getColumns` only for the stubbed arguments, and `verify` becomes
`next`/`close` counts. `processMetaData` takes the declared columns as a `string[]` (Java's `List<String>`), the
`java.util.Date` parameter is a `flint.java.time.LocalDate`, and `isInstanceOf` checks what the `Any` holds.
+/
module flint.jdbc.table_meta_data_context_tests;

import flint.dao : InvalidDataAccessApiUsageException;
import flint.engine.aot.any : Any;
import flint.java.sql : Connection, DatabaseMetaData, ResultSet, Types;
import flint.java.time : LocalDate;
import flint.javax.sql : DataSource;
import flint.jdbc.core : SqlParameterValue;
import flint.jdbc.core.metadata : TableMetaDataContext;
import flint.jdbc.core.namedparam : MapSqlParameterSource;
import std.typecons : BlackHole;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fakes

/// A result set over scripted rows, read by column label; a label the script lacks reads as Mockito's default.
private final class ScriptedResultSet : BlackHole!ResultSet
{
    private string[] labels;
    private Any[][] rows;
    private size_t position;
    int closed;
    int nextCalls;

    this(string[] labels, Any[][] rows)
    {
        this.labels = labels;
        this.rows = rows;
    }

    override bool next()
    {
        ++nextCalls;
        return ++position <= rows.length;
    }

    override void close()
    {
        ++closed;
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
}

/// Database meta-data that answers `getTables`/`getColumns` only for the stubbed arguments.
private final class FakeDatabaseMetaData : BlackHole!DatabaseMetaData
{
    string productName;
    string productVersion;
    string userName;
    bool lowerCase;
    string[3] tablesArgs;
    ResultSet tables;
    string[3] columnsArgs;
    ResultSet columns;

    override string getDatabaseProductName()
    {
        return productName;
    }

    override string getDatabaseProductVersion()
    {
        return productVersion;
    }

    override string getUserName()
    {
        return userName;
    }

    override bool storesLowerCaseIdentifiers()
    {
        return lowerCase;
    }

    override ResultSet getTables(string catalog, string schemaPattern, string tableNamePattern, string[] types)
    {
        const string[3] args = [catalog, schemaPattern, tableNamePattern];
        return args == tablesArgs && types is null ? tables : null;
    }

    override ResultSet getColumns(string catalog, string schemaPattern, string tableNamePattern,
            string columnNamePattern)
    {
        const string[3] args = [catalog, schemaPattern, tableNamePattern];
        return args == columnsArgs && columnNamePattern is null ? columns : null;
    }
}

private final class FakeConnection : BlackHole!Connection
{
    FakeDatabaseMetaData metaData;

    override DatabaseMetaData getMetaData()
    {
        return metaData;
    }
}

private final class FakeDataSource : BlackHole!DataSource
{
    FakeConnection connection;

    override Connection getConnection()
    {
        return connection;
    }
}

private struct Fixture
{
    FakeDataSource dataSource;
    FakeConnection connection;
    FakeDatabaseMetaData databaseMetaData;
    TableMetaDataContext context;
}

/// `@BeforeEach setUp`, with the test class's fields.
private Fixture setUp()
{
    Fixture f;
    f.databaseMetaData = new FakeDatabaseMetaData;
    f.connection = new FakeConnection;
    f.connection.metaData = f.databaseMetaData;
    f.dataSource = new FakeDataSource;
    f.dataSource.connection = f.connection;
    f.context = new TableMetaDataContext;
    return f;
}

/// The table rows of `getTables`: one table in the given schema.
private ScriptedResultSet tableResultSet(string schema, string table)
{
    return new ScriptedResultSet(["TABLE_SCHEM", "TABLE_NAME", "TABLE_TYPE"], [
        [Any.of(schema), Any.of(table), Any.of("TABLE")]
    ]);
}

/// The column rows of `getColumns`: `COLUMN_NAME`, `DATA_TYPE` and `NULLABLE` per column.
private ScriptedResultSet columnsResultSet(string[] names, int[] types, bool[] nullable)
{
    Any[][] rows;
    foreach (i, name; names)
        rows ~= [Any.of(name), Any.of(types[i]), Any.of(nullable[i])];
    return new ScriptedResultSet(["COLUMN_NAME", "DATA_TYPE", "NULLABLE"], rows);
}

private void initializeTwoColumnCustomersTable(ref Fixture f)
{
    f.databaseMetaData.productName = "MyDB";
    f.databaseMetaData.productVersion = "1.0";
    f.databaseMetaData.userName = "me";
    f.databaseMetaData.lowerCase = true;
    f.databaseMetaData.tablesArgs = [null, null, "customers"];
    f.databaseMetaData.tables = tableResultSet("me", "customers");
    f.databaseMetaData.columnsArgs = [null, "me", "customers"];
    f.databaseMetaData.columns = columnsResultSet(["id", "name"], [Types.INTEGER, Types.VARCHAR], [
        false, true
    ]);
}

private E expectThrows(E : Throwable)(scope void delegate() @safe action)
{
    try
        action();
    catch (E ex)
        return ex;
    assert(false, "expected " ~ E.stringof);
}

private bool isParameterValue(Any value)
{
    return !value.isNull && cast(SqlParameterValue) value.asObject() !is null;
}

// ---------------------------------------------------------------------------------------------------------------
// TableMetaDataContextTests

@("TableMetaDataContextTests.matchInParametersAndSqlTypeInfoWrapping")
unittest
{
    auto f = setUp();
    enum TABLE = "customers";
    enum USER = "me";

    auto metaDataResultSet = tableResultSet(USER, TABLE);
    auto columns = columnsResultSet(["id", "name", "customersince", "version"], [
        Types.INTEGER, Types.VARCHAR, Types.DATE, Types.NUMERIC
    ], [false, true, true, false]);

    f.databaseMetaData.productName = "MyDB";
    f.databaseMetaData.productName = "1.0";
    f.databaseMetaData.userName = USER;
    f.databaseMetaData.lowerCase = true;
    f.databaseMetaData.tablesArgs = [null, null, TABLE];
    f.databaseMetaData.tables = metaDataResultSet;
    f.databaseMetaData.columnsArgs = [null, USER, TABLE];
    f.databaseMetaData.columns = columns;

    auto map = new MapSqlParameterSource;
    map.addValue("id", 1);
    map.addValue("name", "Sven");
    map.addValue("customersince", LocalDate.now());
    map.addValue("version", 0);
    map.registerSqlType("customersince", Types.DATE);
    map.registerSqlType("version", Types.NUMERIC);

    f.context.setTableName(TABLE);
    f.context.processMetaData(f.dataSource, [], []);

    auto values = f.context.matchInParameterValuesWithInsertColumns(map);

    assert(values.size() == 4, "wrong number of parameters: ");
    assert(values.get(0).holds!int, "id not wrapped with type info");
    assert(values.get(1).holds!string && !values.get(1).isNull, "name not wrapped with type info");
    assert(isParameterValue(values.get(2)), "date wrapped with type info");
    assert(isParameterValue(values.get(3)), "version wrapped with type info");
    assert(metaDataResultSet.nextCalls >= 1);
    assert(columns.nextCalls >= 1);
    assert(metaDataResultSet.closed == 1);
    assert(columns.closed == 1);
}

@("TableMetaDataContextTests.tableWithSingleColumnGeneratedKey")
unittest
{
    auto f = setUp();
    enum TABLE = "customers";
    enum USER = "me";

    auto metaDataResultSet = tableResultSet(USER, TABLE);
    auto columns = columnsResultSet(["id"], [Types.INTEGER], [false]);

    f.databaseMetaData.productName = "MyDB";
    f.databaseMetaData.productName = "1.0";
    f.databaseMetaData.userName = USER;
    f.databaseMetaData.lowerCase = true;
    f.databaseMetaData.tablesArgs = [null, null, TABLE];
    f.databaseMetaData.tables = metaDataResultSet;
    f.databaseMetaData.columnsArgs = [null, USER, TABLE];
    f.databaseMetaData.columns = columns;

    auto map = new MapSqlParameterSource;
    string[] keyCols = ["id"];
    f.context.setTableName(TABLE);
    f.context.processMetaData(f.dataSource, [], keyCols);
    auto values = f.context.matchInParameterValuesWithInsertColumns(map);
    const insertString = f.context.createInsertString(keyCols);

    assert(values.size() == 0, "wrong number of parameters: ");
    assert(insertString == "INSERT INTO customers () VALUES()", "empty insert not generated correctly");
    assert(metaDataResultSet.nextCalls >= 1);
    assert(columns.nextCalls >= 1);
    assert(metaDataResultSet.closed == 1);
    assert(columns.closed == 1);
}

@("TableMetaDataContextTests.overlappingDeclaredAndGeneratedKeyColumnsAreRejected")  // gh-37014
unittest
{
    auto f = setUp();
    initializeTwoColumnCustomersTable(f);
    f.context.setTableName("customers");

    const ex = expectThrows!InvalidDataAccessApiUsageException({
        f.context.processMetaData(f.dataSource, ["id", "name"], ["id"]);
    });
    assert(ex.msg == "Declared columns [id] must not overlap with generated key columns", ex.msg);
}

@("TableMetaDataContextTests.overlappingDeclaredAndGeneratedKeyColumnsAreRejectedRegardlessOfCase")  // gh-37014
unittest
{
    auto f = setUp();
    initializeTwoColumnCustomersTable(f);
    f.context.setTableName("customers");

    const ex = expectThrows!InvalidDataAccessApiUsageException({
        f.context.processMetaData(f.dataSource, ["ID", "name"], ["id"]);
    });
    assert(ex.msg == "Declared columns [ID] must not overlap with generated key columns", ex.msg);
}

@("TableMetaDataContextTests.declaredColumnsWithoutOverlapAreUsedAsIs")  // gh-37014
unittest
{
    auto f = setUp();
    initializeTwoColumnCustomersTable(f);
    auto map = new MapSqlParameterSource;
    map.addValue("name", "Sven");
    string[] keyCols = ["id"];
    f.context.setTableName("customers");
    f.context.processMetaData(f.dataSource, ["name"], keyCols);
    auto values = f.context.matchInParameterValuesWithInsertColumns(map);
    const insertString = f.context.createInsertString(keyCols);

    assert(insertString == "INSERT INTO customers (name) VALUES(?)", insertString);
    assert(values.size() == 1 && values.get(0).get!string == "Sven");
}
