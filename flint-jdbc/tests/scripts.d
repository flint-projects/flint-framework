// Ported from spring-framework v7.1.0: spring-jdbc/src/test/java/org/springframework/jdbc/datasource/init/ScriptUtilsTests.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: ResourceDatabasePopulatorTests.java and CompositeDatabasePopulatorTests.java.

/++
`ScriptUtilsTests`, `ResourceDatabasePopulatorTests` and `CompositeDatabasePopulatorTests`. The upstream `.sql`
fixtures are in `tests/scripts`, read with string imports into `ByteArrayResource`s. The populator runs against a
recording connection in place of Mockito and an embedded H2.
+/
module flint.jdbc.scripts_test;

import flint.core.io : ByteArrayResource, Resource;
import flint.java.sql : Connection, SQLException, Statement;
import flint.jdbc.datasource.init;
import std.typecons : BlackHole;

@safe:

private Resource script(string name)()
{
    return new ByteArrayResource(cast(immutable(ubyte)[]) import(name), "class path resource [" ~ name ~ "]");
}

private Resource text(string content)
{
    return new ByteArrayResource(cast(immutable(ubyte)[]) content, "inline script");
}

private string[] split(string script, string separator)
{
    string[] statements;
    ScriptUtils.splitSqlScript(null, script, separator, [ScriptUtils.DEFAULT_COMMENT_PREFIX],
            ScriptUtils.DEFAULT_BLOCK_COMMENT_START_DELIMITER,
            ScriptUtils.DEFAULT_BLOCK_COMMENT_END_DELIMITER, statements);
    return statements;
}

private string read(Resource resource)
{
    return ScriptUtils.readScript(resource, ScriptUtils.DEFAULT_STATEMENT_SEPARATOR,
            ScriptUtils.DEFAULT_COMMENT_PREFIXES, ScriptUtils.DEFAULT_BLOCK_COMMENT_END_DELIMITER);
}

@("splitSqlScriptDelimitedWithSemicolon")
unittest
{
    enum raw1 = "insert into customer (id, name)\nvalues (1, 'Rod ; Johnson'), (2, 'Adrian \n Collier')";
    enum raw2 = "insert into orders(id, order_date, customer_id)\nvalues (1, '2008-01-02', 2)";
    enum raw3 = "insert into orders(id, order_date, customer_id) values (1, '2008-01-02', 2)";
    assert(split(raw1 ~ ";" ~ raw2 ~ ";" ~ raw3,
            ";") == [
        "insert into customer (id, name) values (1, 'Rod ; Johnson'), (2, 'Adrian \n Collier')",
        "insert into orders(id, order_date, customer_id) values (1, '2008-01-02', 2)", raw3
    ]);
}

@("splitSqlScriptDelimitedWithNewLine, and with the default delimiter specified")
unittest
{
    enum s1 = "insert into customer (id, name) values (1, 'Rod ; Johnson'), (2, 'Adrian \n Collier')";
    enum s2 = "insert into orders(id, order_date, customer_id) values (1, '2008-01-02', 2)";
    assert(split(s1 ~ "\n" ~ s2 ~ "\n" ~ s2, "\n") == [s1, s2, s2]);
    assert(split("do something\ndo something else", ";") == ["do something do something else"],
            "stripped but not split statements");
}

@("splitScriptWithSingleQuotesNestedInsideDoubleQuotes")
unittest
{
    enum s1 = "select '1' as \"Dogbert's owner's\" from dual";
    enum s2 = "select '2' as \"Dilbert's\" from dual";
    assert(split(s1 ~ ";" ~ s2, ";") == [s1, s2]);
}

@("readAndSplitScriptWithMultipleNewlinesAsSeparator")
unittest
{
    assert(split(read(script!"db-test-data-multi-newline.sql"),
            "\n\n") == [
        "insert into T_TEST (NAME) values ('Keith')", "insert into T_TEST (NAME) values ('Dave')"
    ]);
}

private void splitScriptContainingComments(string script, string[] commentPrefixes...)
{
    string[] statements;
    ScriptUtils.splitSqlScript(null, script, ";", commentPrefixes.dup,
            ScriptUtils.DEFAULT_BLOCK_COMMENT_START_DELIMITER,
            ScriptUtils.DEFAULT_BLOCK_COMMENT_END_DELIMITER, statements);
    assert(statements == [
        "insert into customer (id, name) values (1, 'Rod; Johnson'), (2, 'Adrian Collier')",
        "insert into orders(id, order_date, customer_id) values (1, '2008-01-02', 2)",
        "insert into orders(id, order_date, customer_id) values (1, '2008-01-02', 2)",
        "INSERT INTO persons( person_id , name) VALUES( 1 , 'Name' )"
    ], statements[0]);
}

@("readAndSplitScriptContainingComments, with Windows line endings and with multiple prefixes")
unittest
{
    import std.array : replace;

    const withComments = read(script!"test-data-with-comments.sql");
    splitScriptContainingComments(withComments, "--");
    splitScriptContainingComments(withComments.replace("\n", "\r\n"), "--");
    splitScriptContainingComments(read(script!"test-data-with-multi-prefix-comments.sql"), "--", "#", "^");
}

@("readAndSplitScriptContainingCommentsWithLeadingTabs and multi-line (nested) comments")
unittest
{
    assert(split(read(script!"test-data-with-comments-and-leading-tabs.sql"),
            ";") == [
        "insert into customer (id, name) values (1, 'Sam Brannen')",
        "insert into orders(id, order_date, customer_id) values (1, '2013-06-08', 1)",
        "insert into orders(id, order_date, customer_id) values (2, '2013-06-08', 1)"
    ]);
    static immutable expected = [
        "INSERT INTO users(first_name, last_name) VALUES('Juergen', 'Hoeller')",
        "INSERT INTO users(first_name, last_name) VALUES( 'Sam' , 'Brannen' )"
    ];
    assert(split(read(script!"test-data-with-multi-line-comments.sql"), ";") == expected);
    assert(split(read(script!"test-data-with-multi-line-nested-comments.sql"), ";") == expected);
}

@("containsStatementSeparator: quotes, MySQL escapes and comments")
unittest
{
    static struct Case
    {
        string script, delimiter;
        bool expected;
    }

    enum Case[] cases = [
        Case("select 1\n select ';'", ";", false), Case("select 1\n select \";\"", ";", false),
        Case("select 1; select 2", ";", true), Case("select 1; select '\n'", "\n", false),
        Case("select 1; select \"\n\"", "\n", false), Case("select 1\n select 2", "\n", true),
        Case("select 1\n select 2", "\n\n", false), Case("select 1\n\n select 2", "\n\n", true),
        Case("insert into users(first, last)\n values('a\\\\', 'b;')", ";", false),
        Case("insert into users(first, last)\n values('Charles', 'd\\'Artagnan'); select 1", ";",
                true), Case("-- a;b;c\n insert into colors(color_num) values(42);", ";",
                true), Case("/* a;b;c */\n insert into colors(color_num) values(42);",
                ";", true), Case("-- a;b;c\n insert into colors(color_num) values(42)", ";", false),
        Case("/* a;b;c */\n insert into colors(color_num) values(42)",
                ";", false),
        Case("-- What\\'s your favorite color?\n insert into colors(color_num) values(42);", ";", true),
        Case("-- What's your favorite color?\n insert into colors(color_num) values(42);",
                ";", true),
        Case("/* What\\'s your favorite color? */\n insert into colors(color_num) values(42);",
                ";", true),
        Case("/* What's your favorite color? */\n insert into colors(color_num) values(42);", ";",
                true),
        Case("-- double \" quotes\n insert into colors(color_num) values(42);", ";", true),
        Case("-- double \\\" quotes\n insert into colors(color_num) values(42);", ";", true),
        Case("/* double \" quotes */\n insert into colors(color_num) values(42);", ";", true),
        Case("/* double \\\" quotes */\n insert into colors(color_num) values(42);", ";", true),
    ];
    foreach (c; cases)
        assert(ScriptUtils.containsStatementSeparator(null, c.script, c.delimiter, ["--"], "/*",
                "*/") == c.expected, c.script);
}

@("an unterminated block comment is a ScriptParseException")
unittest
{
    try
    {
        split("select 1; /* unterminated", ";");
        assert(false, "expected ScriptParseException");
    }
    catch (ScriptParseException ex)
        assert(ex.msg == "Failed to parse SQL script from resource [<unknown>]: "
                ~ "Missing block comment end delimiter: */", ex.msg);
}

// ---------------------------------------------------------------------------------------------------------------
// Populators against a recording connection

private final class Recording : BlackHole!Statement
{
    string[]* log;
    string failOn;

    this(string[]* log, string failOn)
    {
        this.log = log;
        this.failOn = failOn;
    }

    override bool execute(string sql)
    {
        *log ~= sql;
        if (failOn.length && sql.length >= failOn.length && sql[0 .. failOn.length] == failOn)
            throw new SQLException("failed: " ~ sql, "42000");
        return false;
    }

    override int getUpdateCount()
    {
        return -1;
    }
}

private final class RecordingConnection : BlackHole!Connection
{
    string[] log;
    string failOn;

    override Statement createStatement()
    {
        return new Recording(&log, failOn);
    }
}

@("ResourceDatabasePopulator runs each script's statements in order; a failed DROP may be ignored")
unittest
{
    auto connection = new RecordingConnection;
    auto populator = new ResourceDatabasePopulator(script!"users-schema.sql", script!"users-data-with-comments.sql");
    populator.populate(connection);
    assert(connection.log == [
        "DROP TABLE users IF EXISTS",
        "CREATE TABLE users ( id INTEGER GENERATED BY DEFAULT AS IDENTITY(START WITH 0) PRIMARY KEY, "
        ~ "first_name VARCHAR(50) NOT NULL, last_name VARCHAR(50) NOT NULL )",
        "INSERT INTO users(first_name, last_name) VALUES('Juergen', 'Hoeller')",
        "INSERT INTO users(first_name, last_name) VALUES( 'Sam' , 'Brannen' )"
    ], connection.log[1]);

    auto failing = new RecordingConnection;
    failing.failOn = "DROP";
    try
    {
        populator.populate(failing);
        assert(false, "expected ScriptStatementFailedException");
    }
    catch (ScriptStatementFailedException ex)
        assert(ex.msg == "Failed to execute SQL script statement #1 of "
                ~ "Byte array resource [class path resource [users-schema.sql]]: DROP TABLE users IF EXISTS", ex.msg);
    populator.setIgnoreFailedDrops(true);
    auto ignoring = new RecordingConnection;
    ignoring.failOn = "DROP";
    populator.populate(ignoring);
    assert(ignoring.log.length == 4);
}

@("ResourceDatabasePopulator: EOF separator, continueOnError, and CompositeDatabasePopulator ordering")
unittest
{
    auto connection = new RecordingConnection;
    auto populator = new ResourceDatabasePopulator(text("select 1; select 2"));
    populator.setSeparator(ScriptUtils.EOF_STATEMENT_SEPARATOR);
    populator.populate(connection);
    assert(connection.log == ["select 1; select 2"]);

    auto failing = new RecordingConnection;
    failing.failOn = "bad";
    auto lenient = new ResourceDatabasePopulator(true, false, null, text("bad 1; good 2"));
    lenient.populate(failing);
    assert(failing.log == ["bad 1", "good 2"]);

    auto composite = new CompositeDatabasePopulator(new ResourceDatabasePopulator(text("a;")),
            new ResourceDatabasePopulator(text("b;")));
    auto both = new RecordingConnection;
    composite.populate(both);
    assert(both.log == ["a", "b"]);
}
