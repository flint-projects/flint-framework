/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/simple/SimpleJdbcInsertTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. Hand-written
`BlackHole` fakes of `flint.java.sql` replace the Mockito mocks: a `ScriptedResultSet` serves rows by column label
(an absent label reads as Mockito's default), the `DatabaseMetaData` fake answers `getTables`/`getColumns` only for
the stubbed arguments, and `verify(...).close()` becomes a close count. The `@BeforeEach` stubbing is `setUp` and the
`@AfterEach` check `verifyClosed`; `Collections.emptyMap()` is an empty `LinkedHashMap!(string, Any)`.
+/
module flint.jdbc.simple_jdbc_insert_tests;

import flint.dao : InvalidDataAccessApiUsageException;
import flint.engine.aot.any : Any;
import flint.java.sql : Connection, DatabaseMetaData, ResultSet, SQLException, Types;
import flint.java.util : LinkedHashMap;
import flint.javax.sql : DataSource;
import flint.jdbc.core.simple : SimpleJdbcInsert;
import std.typecons : BlackHole;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fakes

/// A result set over scripted rows, read by column label. A label the script lacks reads as Mockito's default
/// answer (null, 0 or false); `failAt` makes one `getString` call throw.
private final class ScriptedResultSet : BlackHole!ResultSet
{
    private string[] labels;
    private Any[][] rows;
    private size_t position;
    int closed;
    int nextCalls;
    /// The `getString` call (1-based, over all labels) that throws `failure`; 0 for none.
    int failAt;
    SQLException failure;
    private int getStringCalls;

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
        if (++getStringCalls == failAt)
            throw failure;
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

/// Database meta-data that answers `getTables`/`getColumns` only for the stubbed arguments, as Mockito's
/// `given(databaseMetaData.getTables(null, null, "x", null))` does.
private final class FakeDatabaseMetaData : BlackHole!DatabaseMetaData
{
    string productName;
    string productVersion;
    string userName;
    bool lowerCase;
    string quoteString;
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

    override string getIdentifierQuoteString()
    {
        return quoteString;
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
    int closed;

    override DatabaseMetaData getMetaData()
    {
        return metaData;
    }

    override void close()
    {
        ++closed;
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
    FakeConnection connection;
    FakeDatabaseMetaData databaseMetaData;
    FakeDataSource dataSource;
}

/// `@BeforeEach setUp`: the connection hands out the meta-data, the data source the connection.
private Fixture setUp()
{
    Fixture f;
    f.databaseMetaData = new FakeDatabaseMetaData;
    f.connection = new FakeConnection;
    f.connection.metaData = f.databaseMetaData;
    f.dataSource = new FakeDataSource;
    f.dataSource.connection = f.connection;
    return f;
}

/// `@AfterEach verifyClosed`: `verify(connection).close()`.
private void verifyClosed(ref Fixture f)
{
    assert(f.connection.closed == 1, "connection.close() once");
}

private E expectThrows(E : Throwable)(scope void delegate() @safe action)
{
    try
        action();
    catch (E ex)
        return ex;
    assert(false, "expected " ~ E.stringof);
}

private bool startsWith(string text, string prefix)
{
    return text.length >= prefix.length && text[0 .. prefix.length] == prefix;
}

// ---------------------------------------------------------------------------------------------------------------
// SimpleJdbcInsertTests

@("SimpleJdbcInsertTests.missingTableName")
unittest
{
    auto f = setUp();
    auto insert = new SimpleJdbcInsert(f.dataSource);

    const ex = expectThrows!InvalidDataAccessApiUsageException({ insert.compile(); });
    assert(ex.msg == "Table name is required", ex.msg);

    // Appease the @AfterEach checks.
    f.connection.close();
    verifyClosed(f);
}

@("SimpleJdbcInsertTests.usingQuotedIdentifiersWithoutSupplyingColumnNames")  // gh-24013 and gh-31208
unittest
{
    auto f = setUp();
    auto insert = new SimpleJdbcInsert(f.dataSource).withTableName("my_table").usingQuotedIdentifiers();

    const ex = expectThrows!InvalidDataAccessApiUsageException({ insert.compile(); });
    assert(ex.msg == "Explicit column names must be provided when using quoted identifiers", ex.msg);

    // Appease the @AfterEach checks.
    f.connection.close();
    verifyClosed(f);
}

/// This test does not test any functionality but rather only that configuration methods can be chained without
/// compiler errors.
@("SimpleJdbcInsertTests.methodChaining")  // gh-31177
unittest
{
    auto f = setUp();
    auto insert = new SimpleJdbcInsert(f.dataSource).withCatalogName("my_catalog").withSchemaName("my_schema")
        .withTableName("my_table").usingColumns("col1", "col2").usingGeneratedKeyColumns("id")
        .usingQuotedIdentifiers().withoutTableColumnMetaDataAccess().includeSynonymsForTableColumnMetaData();

    assert(insert !is null);

    // Satisfy the @AfterEach mock verification.
    f.connection.close();
    verifyClosed(f);
}

@("SimpleJdbcInsertTests.noSuchTable")
unittest
{
    auto f = setUp();
    auto resultSet = new ScriptedResultSet([], []);

    f.databaseMetaData.productName = "MyDB";
    f.databaseMetaData.productVersion = "1.0";
    f.databaseMetaData.userName = "me";
    f.databaseMetaData.lowerCase = true;
    f.databaseMetaData.tablesArgs = [null, null, "x"];
    f.databaseMetaData.tables = resultSet;

    auto insert = new SimpleJdbcInsert(f.dataSource).withTableName("x");
    // Shouldn't succeed in inserting into table which doesn't exist
    const ex = expectThrows!InvalidDataAccessApiUsageException({
        insert.execute(new LinkedHashMap!(string, Any));
    });
    assert(ex.msg.startsWith("Unable to locate columns for table 'x' so an insert statement can't be generated"),
            ex.msg);

    assert(resultSet.closed == 1);
    verifyClosed(f);
}

@("SimpleJdbcInsertTests.retrieveColumnNamesFromMetadata")  // gh-26486
unittest
{
    auto f = setUp();
    auto tableResultSet = new ScriptedResultSet([], [[]]);

    f.databaseMetaData.userName = "me";
    f.databaseMetaData.tablesArgs = [null, null, "me"];
    f.databaseMetaData.tables = tableResultSet;

    auto columnResultSet = new ScriptedResultSet(["COLUMN_NAME", "DATA_TYPE", "NULLABLE"],
            [
                [Any.of("col1"), Any.of(Types.VARCHAR), Any.of(false)],
                [Any.of("col2"), Any.of(Types.VARCHAR), Any.of(false)]
    ]);
    f.databaseMetaData.columnsArgs = [null, "me", null];
    f.databaseMetaData.columns = columnResultSet;

    auto insert = new SimpleJdbcInsert(f.dataSource).withTableName("me");
    insert.compile();
    assert(insert.getInsertString() == "INSERT INTO me (col1, col2) VALUES(?, ?)", insert.getInsertString());

    assert(columnResultSet.closed == 1);
    assert(tableResultSet.closed == 1);
    verifyClosed(f);
}

@("SimpleJdbcInsertTests.exceptionThrownWhileRetrievingColumnNamesFromMetadata")  // gh-26486
unittest
{
    auto f = setUp();
    auto tableResultSet = new ScriptedResultSet([], [[]]);

    f.databaseMetaData.userName = "me";
    f.databaseMetaData.tablesArgs = [null, null, "me"];
    f.databaseMetaData.tables = tableResultSet;

    // two rows --> simulates processing of two columns
    auto columnResultSet = new ScriptedResultSet(["COLUMN_NAME", "DATA_TYPE", "NULLABLE"],
            [
                [Any.of("col1"), Any.of(Types.VARCHAR), Any.of(false)],
                [Any.of("col2"), Any.of(Types.VARCHAR), Any.of(false)]
    ]);
    // Return a column name the first time; second time, simulate an error while retrieving metadata.
    columnResultSet.failAt = 2;
    columnResultSet.failure = new SQLException("error with col2");
    f.databaseMetaData.columnsArgs = [null, "me", null];
    f.databaseMetaData.columns = columnResultSet;

    auto insert = new SimpleJdbcInsert(f.dataSource).withTableName("me");

    const ex = expectThrows!InvalidDataAccessApiUsageException({ insert.compile(); });
    assert(ex.msg == "Unable to locate columns for table 'me' so an insert statement can't be generated. "
            ~ "Consider specifying explicit column names -- for example, via SimpleJdbcInsert#usingColumns().", ex.msg);

    assert(columnResultSet.closed == 1);
    assert(tableResultSet.closed == 1);
    verifyClosed(f);
}

@("SimpleJdbcInsertTests.usingColumns")
unittest
{
    auto f = setUp();
    auto insert = new SimpleJdbcInsert(f.dataSource).withTableName("my_table").usingColumns("col1", "col2");

    insert.compile();

    assert(insert.getInsertString() == "INSERT INTO my_table (col1, col2) VALUES(?, ?)", insert.getInsertString());
    verifyClosed(f);
}

@("SimpleJdbcInsertTests.usingColumnsAndQuotedIdentifiers")  // gh-24013
unittest
{
    auto f = setUp();
    auto insert = new SimpleJdbcInsert(f.dataSource).withTableName("my_table").usingColumns("col1",
            "col2").usingQuotedIdentifiers();

    f.databaseMetaData.quoteString = "`";

    insert.compile();
    const insertString = insert.getInsertString();
    assert(insertString == "INSERT INTO `my_table` (`col1`, `col2`) VALUES(?, ?)", insertString);
    verifyClosed(f);
}

@("SimpleJdbcInsertTests.usingColumnsAndQuotedIdentifiersWithSchemaName")  // gh-24013
unittest
{
    auto f = setUp();
    auto insert = new SimpleJdbcInsert(f.dataSource).withSchemaName("my_schema")
        .withTableName("my_table").usingColumns("col1", "col2").usingQuotedIdentifiers();

    f.databaseMetaData.quoteString = "`";

    insert.compile();
    assert(insert.getInsertString() == "INSERT INTO `my_schema`.`my_table` (`col1`, `col2`) VALUES(?, ?)",
            insert.getInsertString());
    verifyClosed(f);
}

@("SimpleJdbcInsertTests.usingSchema")
unittest
{
    auto f = setUp();
    auto insert = new SimpleJdbcInsert(f.dataSource).withTableName("my_table")
        .withSchemaName("my_schema").usingColumns("col1", "col2");

    insert.compile();

    assert(insert.getInsertString() == "INSERT INTO my_schema.my_table (col1, col2) VALUES(?, ?)",
            insert.getInsertString());
    verifyClosed(f);
}

@("SimpleJdbcInsertTests.usingCatalog")
unittest
{
    auto f = setUp();
    auto insert = new SimpleJdbcInsert(f.dataSource).withTableName("my_table")
        .withCatalogName("my_catalog").usingColumns("col1", "col2");

    insert.compile();

    assert(insert.getInsertString() == "INSERT INTO my_catalog.my_table (col1, col2) VALUES(?, ?)",
            insert.getInsertString());
    verifyClosed(f);
}

@("SimpleJdbcInsertTests.usingSchemaAndCatalog")
unittest
{
    auto f = setUp();
    auto insert = new SimpleJdbcInsert(f.dataSource).withTableName("my_table")
        .withSchemaName("my_schema").withCatalogName("my_catalog").usingColumns("col1", "col2");

    insert.compile();

    assert(insert.getInsertString() == "INSERT INTO my_catalog.my_schema.my_table (col1, col2) VALUES(?, ?)",
            insert.getInsertString());
    verifyClosed(f);
}
