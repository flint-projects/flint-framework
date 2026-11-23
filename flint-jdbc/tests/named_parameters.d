// Ported from spring-framework v7.1.0: spring-jdbc/src/test/java/org/springframework/jdbc/core/namedparam/NamedParameterUtilsTests.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: NamedParameterJdbcTemplateTests.java, MapSqlParameterSourceTests.java and
// BeanPropertySqlParameterSourceTests.java.

/++
`NamedParameterUtilsTests`, the core of `NamedParameterJdbcTemplateTests`, `MapSqlParameterSourceTests` and
`BeanPropertySqlParameterSourceTests`. A recording `PreparedStatement` replaces Mockito: each bind is logged as
`setObject(1,1)`, `setObject(1,1,3)` (with an SQL type) or `setString(2,UK)`.
+/
module flint.jdbc.named_parameters_test;

import flint.dao : InvalidDataAccessApiUsageException;
import flint.java.lang : IllegalArgumentException;
import flint.engine.aot.any : Any;
import flint.java.sql : Connection, PreparedStatement, ResultSet, ResultSetMetaData, Statement, Types;
import flint.java.util : HashMap, List, Map;
import flint.javax.sql : DataSource;
import flint.jdbc.core : JdbcTemplate, PreparedStatementCallback, ResultSetExtractor, SqlParameterValue;
import flint.jdbc.core.namedparam;
import flint.jdbc.support : GeneratedKeyHolder;
import std.array : join;
import std.typecons : BlackHole;

@safe:

private string substitute(ParsedSql parsedSql)
{
    return NamedParameterUtils.substituteNamedParameters(parsedSql, null);
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

// ---------------------------------------------------------------------------------------------------------------
// NamedParameterUtilsTests

@("parseSql")
unittest
{
    auto parsedSql = NamedParameterUtils.parseSqlStatement("xxx :a yyyy :b :c :a zzzzz");
    assert(substitute(parsedSql) == "xxx ? yyyy ? ? ? zzzzz");
    assert(parsedSql.getParameterNames() == ["a", "b", "c", "a"]);
    assert(parsedSql.getTotalParameterCount() == 4 && parsedSql.getNamedParameterCount() == 3);

    auto parsedSql2 = NamedParameterUtils.parseSqlStatement("xxx &a yyyy ? zzzzz");
    assert(substitute(parsedSql2) == "xxx ? yyyy ? zzzzz");
    assert(parsedSql2.getParameterNames() == ["a"]);
    assert(parsedSql2.getTotalParameterCount() == 2 && parsedSql2.getNamedParameterCount() == 1);

    auto parsedSql3 = NamedParameterUtils.parseSqlStatement("xxx &ä+:ö\t:ü%10 yyyy ? zzzzz");
    assert(parsedSql3.getParameterNames() == ["ä", "ö", "ü"]);
}

@("substituteNamedParameters")
unittest
{
    auto namedParams = new MapSqlParameterSource;
    namedParams.addValue("a", "a").addValue("b", "b").addValue("c", "c");
    assert(NamedParameterUtils.substituteNamedParameters("xxx :a :b :c", namedParams) == "xxx ? ? ?");
    assert(NamedParameterUtils.substituteNamedParameters("xxx :a :b :c xx :a :a", namedParams) == "xxx ? ? ? xx ? ?");
}

@("a null named parameter is one placeholder, not an empty IN list")
unittest
{
    auto namedParams = new MapSqlParameterSource;
    namedParams.addValue("a", Any.init).addValue("id", 1);
    assert(NamedParameterUtils.substituteNamedParameters("UPDATE T SET A = :a WHERE ID = :id",
            namedParams) == "UPDATE T SET A = ? WHERE ID = ?");

    auto f = Fixture.create();
    f.namedParameterTemplate.update("UPDATE T SET A = :a WHERE ID = :id", namedParams);
    assert(f.log.entries[0] == "prepareStatement(UPDATE T SET A = ? WHERE ID = ?)");
}

@("java.time values map to DATE, TIME and TIMESTAMP, as StatementCreatorUtils.javaTypeToSqlTypeMap")
unittest
{
    import flint.java.sql : Types;
    import flint.jdbc.core : StatementCreatorUtils;

    assert(StatementCreatorUtils.javaTypeToSqlParameterType("flint.java.time.LocalDate") == Types.DATE);
    assert(StatementCreatorUtils.javaTypeToSqlParameterType("flint.java.time.LocalTime") == Types.TIME);
    assert(StatementCreatorUtils.javaTypeToSqlParameterType("flint.java.time.LocalDateTime") == Types.TIMESTAMP);
    assert(StatementCreatorUtils.javaTypeToSqlParameterType(
            "flint.java.time.OffsetDateTime") == Types.TIMESTAMP_WITH_TIMEZONE);
}

@("convertParamMapToArray")
unittest
{
    auto paramMap = new HashMap!(string, Any);
    paramMap.put("a", Any.of("a"));
    paramMap.put("b", Any.of("b"));
    paramMap.put("c", Any.of("c"));
    assert(NamedParameterUtils.buildValueArray("xxx :a :b :c", paramMap).length == 3);
    assert(NamedParameterUtils.buildValueArray("xxx :a :b :c xx :a :b", paramMap).length == 5);
    assert(NamedParameterUtils.buildValueArray("xxx :a :a :a xx :a :a", paramMap).length == 5);
    assert(NamedParameterUtils.buildValueArray("xxx :a :b :c xx :a :b", paramMap)[4].get!string == "b");
    expectThrows!InvalidDataAccessApiUsageException({
        NamedParameterUtils.buildValueArray("xxx :a :b ?", paramMap);
    });
}

@("convertTypeMapToArray and convertTypeMapToSqlParameterList")
unittest
{
    auto namedParams = new MapSqlParameterSource;
    namedParams.addValue("a", "a", 1).addValue("b", "b", 2).addValue("c", "c", 3, "SQL_TYPE");
    alias parse = NamedParameterUtils.parseSqlStatement;
    assert(NamedParameterUtils.buildSqlTypeArray(parse("xxx :a :b :c"), namedParams).length == 3);
    assert(NamedParameterUtils.buildSqlTypeArray(parse("xxx :a :a :a xx :a :a"), namedParams).length == 5);
    assert(NamedParameterUtils.buildSqlTypeArray(parse("xxx :a :b :c xx :a :b"), namedParams)[4] == 2);
    assert(NamedParameterUtils.buildSqlParameterList(parse("xxx :a :b :c xx :a :b"), namedParams).size() == 5);
    assert(NamedParameterUtils.buildSqlParameterList(parse("xxx :a :b :c xx :a :b"), namedParams)
            .get(4).getSqlType() == 2);
    assert(NamedParameterUtils.buildSqlParameterList(parse("xxx :a :b :c"), namedParams).get(2)
            .getTypeName() == "SQL_TYPE");
}

@("convertSqlParameterValueToArray")
unittest
{
    auto sqlParameterValue = new SqlParameterValue(2, Any.of("b"));
    auto paramMap = new HashMap!(string, Any);
    paramMap.put("a", Any.of("a"));
    paramMap.put("b", parameterValue(sqlParameterValue));
    paramMap.put("c", Any.of("c"));
    assert(NamedParameterUtils.buildValueArray("xxx :a :b :c xx :a :b", paramMap)[4].asObject() is sqlParameterValue);

    auto namedParams = new MapSqlParameterSource;
    namedParams.addValue("a", "a", 1).addValue("b", sqlParameterValue).addValue("c", "c", 3);
    auto values = NamedParameterUtils.buildValueArray(
            NamedParameterUtils.parseSqlStatement("xxx :a :b :c xx :a :b"), namedParams, null);
    assert(values[4].asObject() is sqlParameterValue);
}

@("buildValueArrayWithMissingParameterValue")
unittest
{
    expectThrows!InvalidDataAccessApiUsageException({
        NamedParameterUtils.buildValueArray("select count(0) from foo where id = :id", new HashMap!(string, Any));
    });
}

@("quotes, comments, Postgres casts and operators, escapes and brackets")
unittest
{
    enum quoted = "select 'first name' from artists where id = :id and quote = 'exsqueeze me?'";
    enum quotedExpected = "select 'first name' from artists where id = ? and quote = 'exsqueeze me?'";
    assert(NamedParameterUtils.substituteNamedParameters(quoted, new MapSqlParameterSource) == quotedExpected);
    assert(substitute(NamedParameterUtils.parseSqlStatement(quoted)) == quotedExpected);

    auto parsedSql1 = NamedParameterUtils.parseSqlStatement(
            "/*+ HINT */ xxx /* comment ? */ :a yyyy :b :c :a zzzzz -- :xx XX\n");
    assert(substitute(parsedSql1) == "/*+ HINT */ xxx /* comment ? */ ? yyyy ? ? ? zzzzz -- :xx XX\n");
    auto paramMap = new MapSqlParameterSource;
    paramMap.addValue("a", "a").addValue("b", "b").addValue("c", "c");
    string[] values;
    foreach (value; NamedParameterUtils.buildValueArray(parsedSql1, paramMap, null))
        values ~= value.get!string;
    assert(values == ["a", "b", "c", "a"]);
    assert(substitute(NamedParameterUtils.parseSqlStatement(
            "/*+ HINT */ xxx /* comment ? */ :a yyyy :b :c :a zzzzz /* :xx XX*"))
            == "/*+ HINT */ xxx /* comment ? */ ? yyyy ? ? ? zzzzz /* :xx XX*");

    assert(substitute(NamedParameterUtils.parseSqlStatement(
            "select 'first name' from artists where id = :id and birth_date=:birthDate::timestamp"))
            == "select 'first name' from artists where id = ? and birth_date=?::timestamp");
    enum containedSql = "select 'first name' from artists where info->'stat'->'albums' = ?? :album"
        ~ " and '[\"1\",\"2\",\"3\"]'::jsonb ?? '4'";
    auto contained = NamedParameterUtils.parseSqlStatement(containedSql);
    assert(contained.getTotalParameterCount() == 1);
    assert(substitute(contained) == "select 'first name' from artists where info->'stat'->'albums' = ?? ?"
            ~ " and '[\"1\",\"2\",\"3\"]'::jsonb ?? '4'");
    assert(NamedParameterUtils.parseSqlStatement("select '[\"3\", \"11\"]'::jsonb ?| '{1,3,11,12,17}'::text[]")
            .getTotalParameterCount() == 0);

    auto escaped = NamedParameterUtils.parseSqlStatement(
            "select '0\\:0' as a, foo from bar where baz < DATE(:p1 23\\:59\\:59) and baz = :p2");
    assert(escaped.getParameterNames() == ["p1", "p2"]);
    assert(substitute(escaped) == "select '0\\:0' as a, foo from bar where baz < DATE(? 23:59:59) and baz = ?");

    auto bracketed = NamedParameterUtils.parseSqlStatement("select foo from bar where baz = b:{p1}:{p2}z");
    assert(bracketed.getParameterNames() == ["p1", "p2"]);
    assert(substitute(bracketed) == "select foo from bar where baz = b??z");
    assert(NamedParameterUtils.parseSqlStatement("select foo from bar where baz = b:{}z")
            .getParameterNames().length == 0);
    assert(substitute(NamedParameterUtils.parseSqlStatement(
            "select foo from bar where baz = b:{p}z")) == "select foo from bar where baz = b?z");

    assert(substitute(NamedParameterUtils.parseSqlStatement("xxx & yyyy")) == "xxx & yyyy");
    assert(NamedParameterUtils.substituteNamedParameters("x := 1", new MapSqlParameterSource) == "x := 1");
    foreach (sql; [
        "SELECT ':foo'':doo', :xxx FROM DUAL", "SELECT /*:doo*/':foo', :xxx FROM DUAL",
        "SELECT ':foo'/*:doo*/, :xxx FROM DUAL", "SELECT \":foo\"\":doo\", :xxx FROM DUAL",
        "SELECT `:foo``:doo`, :xxx FROM DUAL"
    ])
    {
        auto parsed = NamedParameterUtils.parseSqlStatement(sql);
        assert(parsed.getTotalParameterCount() == 1 && parsed.getParameterNames() == ["xxx"], sql);
    }
    auto array = NamedParameterUtils.parseSqlStatement("SELECT ARRAY[:ext]");
    assert(array.getParameterNames() == ["ext"] && substitute(array) == "SELECT ARRAY[?]");
    assert(NamedParameterUtils.parseSqlStatement("insert into foos (id) values (:headers[id])")
            .getParameterNames() == ["headers[id]"]);
    auto backticks = NamedParameterUtils.parseSqlStatement("select * from `tb&user` where id = :id");
    assert(backticks.getParameterNames() == ["id"] && substitute(backticks) == "select * from `tb&user` where id = ?");
}

@("an Any[] value is an IN-list, expanded to one placeholder per element")
unittest
{
    auto params = new MapSqlParameterSource;
    params.addValue("ids", [Any.of(1L), Any.of(2L), Any.of(3L)]).addValue("id", 1L);
    assert(NamedParameterUtils.substituteNamedParameters("update customer set type = array[:ids] where id = :id",
            params) == "update customer set type = array[?, ?, ?] where id = ?");
}

// ---------------------------------------------------------------------------------------------------------------
// Fakes for NamedParameterJdbcTemplateTests

private final class Log
{
    string[] entries;
}

private final class RecordingStatement : BlackHole!PreparedStatement
{
    Log log;
    ResultSet results;
    Connection connection;

    this(Log log, ResultSet results, Connection connection)
    {
        this.log = log;
        this.results = results;
        this.connection = connection;
    }

    override Connection getConnection()
    {
        return connection;
    }

    override void setObject(int index, Any value)
    {
        log.entries ~= "setObject(" ~ digit(index) ~ "," ~ value.toString() ~ ")";
    }

    override void setObject(int index, Any value, int sqlType)
    {
        log.entries ~= "setObject(" ~ digit(index) ~ "," ~ value.toString() ~ "," ~ digit(sqlType) ~ ")";
    }

    override void setString(int index, string value)
    {
        log.entries ~= "setString(" ~ digit(index) ~ "," ~ value ~ ")";
    }

    override int executeUpdate()
    {
        log.entries ~= "executeUpdate";
        return 1;
    }

    override ResultSet executeQuery()
    {
        log.entries ~= "executeQuery";
        return results;
    }

    override ResultSet executeQuery(string sql)
    {
        log.entries ~= "executeQuery(" ~ sql ~ ")";
        return results;
    }

    override ResultSet getGeneratedKeys()
    {
        return new Rows(["id"], [[Any.of(11L)]]);
    }

    override void close()
    {
        log.entries ~= "ps.close";
    }
}

private final class RowsMeta : BlackHole!ResultSetMetaData
{
    string[] labels;

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

private final class Rows : BlackHole!ResultSet
{
    string[] labels;
    Any[][] rows;
    size_t position;

    this(string[] labels, Any[][] rows)
    {
        this.labels = labels;
        this.rows = rows;
    }

    override bool next()
    {
        return ++position <= rows.length;
    }

    override Any getObject(int column)
    {
        return rows[position - 1][column - 1];
    }

    override int getInt(string label)
    {
        foreach (i, l; labels)
            if (l == label)
                return cast(int) rows[position - 1][i].get!long;
        assert(false, label);
    }

    override string getString(string label)
    {
        foreach (i, l; labels)
            if (l == label)
                return rows[position - 1][i].get!string;
        assert(false, label);
    }

    override ResultSetMetaData getMetaData()
    {
        return new RowsMeta(labels);
    }

    override string getString(int column)
    {
        auto value = getObject(column);
        return value.isNull ? null : value.get!string;
    }

    override long getLong(int column)
    {
        auto value = getObject(column);
        return value.isNull ? 0 : value.get!long;
    }

    override int getInt(int column)
    {
        return cast(int) getLong(column);
    }

    override double getDouble(int column)
    {
        auto value = getObject(column);
        return value.isNull ? 0 : value.get!double;
    }

    override int findColumn(string label)
    {
        foreach (i, l; labels)
            if (l == label)
                return cast(int) i + 1;
        throw new imported!"flint.java.sql".SQLException("no column " ~ label);
    }
}

private final class RecordingConnection : BlackHole!Connection
{
    Log log;
    ResultSet results;

    this(Log log)
    {
        this.log = log;
    }

    override Statement createStatement()
    {
        return new RecordingStatement(log, results, this);
    }

    override PreparedStatement prepareStatement(string sql)
    {
        log.entries ~= "prepareStatement(" ~ sql ~ ")";
        return new RecordingStatement(log, results, this);
    }

    override PreparedStatement prepareStatement(string sql, int autoGeneratedKeys)
    {
        log.entries ~= "prepareStatement(" ~ sql ~ "," ~ digit(autoGeneratedKeys) ~ ")";
        return new RecordingStatement(log, results, this);
    }

    override void close()
    {
        log.entries ~= "con.close";
    }
}

private final class OneConnection : BlackHole!DataSource
{
    RecordingConnection connection;

    this(RecordingConnection connection)
    {
        this.connection = connection;
    }

    override Connection getConnection()
    {
        return connection;
    }
}

private string digit(long value)
{
    import flint.engine.aot.text : decimal;

    return decimal(value);
}

private struct Fixture
{
    Log log;
    RecordingConnection connection;
    NamedParameterJdbcTemplate namedParameterTemplate;
    Map!(string, Any) params;

    static Fixture create()
    {
        Fixture f;
        f.log = new Log;
        f.connection = new RecordingConnection(f.log);
        f.namedParameterTemplate = new NamedParameterJdbcTemplate(new OneConnection(f.connection));
        f.params = new HashMap!(string, Any);
        return f;
    }
}

private enum SELECT_NAMED_PARAMETERS = "select id, forename from custmr where id = :id and country = :country";
private enum SELECT_NAMED_PARAMETERS_PARSED = "select id, forename from custmr where id = ? and country = ?";
private enum UPDATE_NAMED_PARAMETERS = "update seat_status set booking_id = null"
    ~ " where performance_id = :perfId and price_band_id = :priceId";
private enum UPDATE_NAMED_PARAMETERS_PARSED = "update seat_status set booking_id = null"
    ~ " where performance_id = ? and price_band_id = ?";

private final class ResultCallback : PreparedStatementCallback!string
{
    override string doInPreparedStatement(PreparedStatement ps)
    {
        ps.executeUpdate();
        return "result";
    }
}

// ---------------------------------------------------------------------------------------------------------------
// NamedParameterJdbcTemplateTests

@("nullDataSourceProvidedToCtor and templateConfiguration")
unittest
{
    expectThrows!Exception({ new NamedParameterJdbcTemplate(cast(DataSource) null); });
    auto f = Fixture.create();
    assert(f.namedParameterTemplate.getJdbcTemplate() is f.namedParameterTemplate.getJdbcOperations());
}

@("execute and executeWithTypedParameters")
unittest
{
    auto f = Fixture.create();
    f.params.put("perfId", Any.of(1));
    f.params.put("priceId", Any.of(1));
    assert(f.namedParameterTemplate.execute(UPDATE_NAMED_PARAMETERS, f.params, new ResultCallback) == "result");
    assert(f.log.entries == [
        "prepareStatement(" ~ UPDATE_NAMED_PARAMETERS_PARSED ~ ")", "setObject(1,1)",
        "setObject(2,1)", "executeUpdate", "ps.close", "con.close"
    ], f.log.entries[1 .. $].join(" | "));

    auto g = Fixture.create();
    g.params.put("perfId", parameterValue(new SqlParameterValue(Types.DECIMAL, Any.of(1))));
    g.params.put("priceId", parameterValue(new SqlParameterValue(Types.INTEGER, Any.of(1))));
    g.namedParameterTemplate.execute(UPDATE_NAMED_PARAMETERS, g.params, new ResultCallback);
    assert(g.log.entries[1 .. 3] == ["setObject(1,1,3)", "setObject(2,1,4)"]);
}

@("queryWithRowMapper: typed and string parameters, mapped rows")
unittest
{
    auto f = Fixture.create();
    f.connection.results = new Rows(["id", "forename"], [[Any.of(1L), Any.of("rod")]]);
    f.params.put("id", parameterValue(new SqlParameterValue(Types.DECIMAL, Any.of(1))));
    f.params.put("country", Any.of("UK"));
    auto customers = f.namedParameterTemplate.query(SELECT_NAMED_PARAMETERS, f.params,
            (ResultSet rs, int) => rs.getString("forename") ~ "#" ~ digit(rs.getInt("id")));
    assert(customers.toArray() == ["rod#1"]);
    assert(f.log.entries == [
        "prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")", "setObject(1,1,3)",
        "setString(2,UK)", "executeQuery", "ps.close", "con.close"
    ], f.log.entries.join(" | "));
}

@("queryWithResultSetExtractor, queryForObject with a type, and a missing parameter")
unittest
{
    auto f = Fixture.create();
    f.connection.results = new Rows(["id", "forename"], [[Any.of(1L), Any.of("rod")]]);
    final class First : ResultSetExtractor!string
    {
        override string extractData(ResultSet rs)
        {
            return rs.next() ? rs.getString("forename") : null;
        }
    }

    auto source = new MapSqlParameterSource("id", 1).addValue("country", "UK");
    assert(f.namedParameterTemplate.query(SELECT_NAMED_PARAMETERS, source, new First) == "rod");

    auto g = Fixture.create();
    g.connection.results = new Rows(["n"], [[Any.of(7L)]]);
    assert(g.namedParameterTemplate.queryForObject!long("select n from t where id = :id",
            new MapSqlParameterSource("id", 3)) == 7);

    auto h = Fixture.create();
    expectThrows!InvalidDataAccessApiUsageException({
        h.namedParameterTemplate.update("update t set x = :x where id = :id", new MapSqlParameterSource("x", 1));
    });
}

@("updateWithKeyHolder and batchUpdateWithSqlParameterSource")
unittest
{
    auto f = Fixture.create();
    auto keyHolder = new GeneratedKeyHolder;
    auto source = new MapSqlParameterSource("forename", "rod").addValue("country", "UK");
    assert(f.namedParameterTemplate.update("insert into custmr(forename,country) values (:forename,:country)",
            source, keyHolder) == 1);
    assert(keyHolder.getKey().get!long == 11);
    assert(f.log.entries[0] == "prepareStatement(insert into custmr(forename,country) values (?,?),1)");

    auto g = Fixture.create();
    SqlParameterSource[] batch = [
        new MapSqlParameterSource("id", 100).addValue("country", "UK"),
        new MapSqlParameterSource("id", 200).addValue("country", "FR")
    ];
    g.namedParameterTemplate.batchUpdate("update custmr set country = :country where id = :id", batch);
    assert(g.log.entries[0] == "prepareStatement(update custmr set country = ? where id = ?)");
}

// ---------------------------------------------------------------------------------------------------------------
// MapSqlParameterSourceTests and BeanPropertySqlParameterSourceTests

@("MapSqlParameterSource: missing values, SqlParameterValue types and toString")
unittest
{
    auto source = new MapSqlParameterSource;
    expectThrows!Exception({ source.getValue("pechorin was right!"); });
    source.addValue("FirstName", "Rick").addValue("Age", 53, Types.INTEGER);
    assert(source.hasValue("FirstName") && !source.hasValue("firstName"));
    assert(source.getSqlType("Age") == Types.INTEGER);
    source.addValue("Salary", new SqlParameterValue(Types.DECIMAL, Any.of(5000)));
    assert(source.getSqlType("Salary") == Types.DECIMAL);
    assert(source.toString() == "MapSqlParameterSource {FirstName=Rick, Age=53 (type:4), Salary=5000 (type:3)}",
            source.toString());
}

/// A bean, as `BeanPropertySqlParameterSourceTests` uses `TestBean`.
class TestBean
{
    private string name;
    private int age;

    /// A bean with a name and an age.
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

@("BeanPropertySqlParameterSource: readable properties, SQL types from property types, and unknown names")
unittest
{
    auto source = new BeanPropertySqlParameterSource(new TestBean("tb", 99));
    assert(source.hasValue("name") && source.hasValue("age") && !source.hasValue("noOp"));
    assert(source.getValue("name").get!string == "tb");
    assert(source.getValue("age").get!int == 99);
    assert(source.getSqlType("name") == Types.VARCHAR && source.getSqlType("age") == Types.INTEGER);
    source.registerSqlType("age", Types.NUMERIC);
    assert(source.getSqlType("age") == Types.NUMERIC);
    expectThrows!Exception({ source.getValue("noOp"); });
    const names = source.getReadablePropertyNames();
    assert(names.length == 2);
}

// ---------------------------------------------------------------------------------------------------------------
// JdbcClientIndexedParameterTests and JdbcClientNamedParameterTests

private enum SELECT_INDEXED_PARAMETERS = "select id, forename from custmr where id = ? and country = ?";

@("JdbcClient: queryWithResultSetExtractor with indexed parameters, one typed")
unittest
{
    import flint.jdbc.core.simple : JdbcClient;

    auto f = Fixture.create();
    f.connection.results = new Rows(["id", "forename"], [[Any.of(1L), Any.of("rod")]]);
    auto client = JdbcClient.create(f.namedParameterTemplate);
    final class Extract : ResultSetExtractor!string
    {
        override string extractData(ResultSet rs)
        {
            rs.next();
            return rs.getString("forename") ~ "#" ~ digit(rs.getInt("id"));
        }
    }

    const customer = client.sql(SELECT_INDEXED_PARAMETERS)
        .params([parameterValue(new SqlParameterValue(Types.DECIMAL, Any.of(1))), Any.of("UK")]).query(new Extract);
    assert(customer == "rod#1");
    assert(f.log.entries == [
        "prepareStatement(" ~ SELECT_INDEXED_PARAMETERS ~ ")", "setObject(1,1,3)", "setString(2,UK)",
        "executeQuery", "ps.close", "con.close"
    ], "verify");
}

@("JdbcClient: named parameters, mapped lists, single values and updates")
unittest
{
    import flint.dao : IncorrectResultSizeDataAccessException;
    import flint.jdbc.core.simple : JdbcClient;

    auto f = Fixture.create();
    auto client = JdbcClient.create(f.namedParameterTemplate);
    f.connection.results = new Rows(["id", "forename"], [
        [Any.of(1L), Any.of("rod")], [Any.of(2L), Any.of("juergen")]
    ]);
    auto names = client.sql(SELECT_NAMED_PARAMETERS).param("id", 1).param("country", "UK")
        .query((ResultSet rs, int) => rs.getString("forename")).list();
    assert(names.toArray() == ["rod", "juergen"]);
    assert(f.log.entries[0] == "prepareStatement(" ~ SELECT_NAMED_PARAMETERS_PARSED ~ ")");
    assert(f.log.entries[1 .. 3] == ["setObject(1,1)", "setString(2,UK)"]);

    f.connection.results = new Rows(["n"], [[Any.of(7L)]]);
    assert(client.sql("select n from t where id = ?").param(3).query!long().single() == 7);

    f.connection.results = new Rows(["n"], [[Any.of(7L)], [Any.of(8L)]]);
    expectThrows!IncorrectResultSizeDataAccessException({
        client.sql("select n from t").query!long().single();
    });

    f.connection.results = new Rows(["n"], []);
    assert(client.sql("select n from t").query!long().optional().isEmpty());

    f.connection.results = new Rows(["n"], [[Any.of(9L)]]);
    assert(client.sql("select n from t").query().singleValue().get!long == 9);

    assert(client.sql("update t set x = :x where id = :id").param("x", 1).param("id", 2).update() == 1);
    expectThrows!Exception({
        client.sql("update t set x = ? where id = :id").param(1).param("id", 2).update();
    });
}

@("JdbcClient: an IN-list value is a named-parameter feature only")
unittest
{
    import flint.jdbc.core.simple : JdbcClient;

    auto f = Fixture.create();
    auto client = JdbcClient.create(f.namedParameterTemplate);
    expectThrows!IllegalArgumentException({
        client.sql("select * from t where id in (?)").param([Any.of(1L), Any.of(2L)]);
    });
}

// ---------------------------------------------------------------------------------------------------------------
// BeanPropertyRowMapperTests and DataClassRowMapperTests

/// A bean with setters, as `BeanPropertyRowMapperTests` maps `Person`.
class Person
{
    private string name;
    private long age;
    private double balance;

    string getName()
    {
        return name;
    }

    void setName(string name)
    {
        this.name = name;
    }

    long getAge()
    {
        return age;
    }

    void setAge(long age)
    {
        this.age = age;
    }

    double getBalance()
    {
        return balance;
    }

    void setBalance(double balance)
    {
        this.balance = balance;
    }
}

/// A data class, mapped through its constructor.
class ConstructorPerson
{
    private string name;
    private long age;

    /// A person with a name and an age.
    this(string name, long age)
    {
        this.name = name;
        this.age = age;
    }

    string getName()
    {
        return name;
    }

    long getAge()
    {
        return age;
    }
}

@("BeanPropertyRowMapper: lower-case and underscored column names map to setters; null into a primitive fails")
unittest
{
    import flint.dao : TypeMismatchDataAccessException;
    import flint.jdbc.core : BeanPropertyRowMapper;

    auto f = Fixture.create();
    auto template_ = f.namedParameterTemplate.getJdbcTemplate();
    f.connection.results = new Rows(["NAME", "age", "balance"], [
        [Any.of("Bubba"), Any.of(22L), Any.of(1234.56)]
    ]);
    auto people = template_.query("select name, age, balance from people", new BeanPropertyRowMapper!Person);
    auto person = people.get(0);
    assert(person.getName() == "Bubba" && person.getAge() == 22 && person.getBalance() == 1234.56);

    f.connection.results = new Rows(["name", "age"], [[Any.of("Bubba"), Any.init]]);
    expectThrows!TypeMismatchDataAccessException({
        template_.query("select name, age from people", new BeanPropertyRowMapper!Person);
    });
    f.connection.results = new Rows(["name", "age"], [[Any.of("Bubba"), Any.init]]);
    auto lenient = new BeanPropertyRowMapper!Person;
    lenient.setPrimitivesDefaultedForNullValue(true);
    assert(template_.query("select name, age from people", lenient).get(0).getAge() == 0);

    f.connection.results = new Rows(["name"], [[Any.of("Bubba")]]);
    expectThrows!InvalidDataAccessApiUsageException({
        template_.query("select name from people", new BeanPropertyRowMapper!Person(true));
    });
}

/// A bean with a `java.time` property, as petclinic-rest's `Pet.birthDate`.
class Dated
{
    import flint.java.time : LocalDate;

    private LocalDate birthDate;

    LocalDate getBirthDate()
    {
        return birthDate;
    }

    void setBirthDate(LocalDate birthDate)
    {
        this.birthDate = birthDate;
    }
}

@("BeanPropertyRowMapper: a DATE column's ISO text maps to a LocalDate property")
unittest
{
    import flint.java.time : LocalDate;
    import flint.jdbc.core : BeanPropertyRowMapper;

    auto f = Fixture.create();
    auto template_ = f.namedParameterTemplate.getJdbcTemplate();
    f.connection.results = new Rows(["birth_date"], [[Any.of("2010-09-07")]]);
    auto rows = template_.query("select birth_date from pets", new BeanPropertyRowMapper!Dated);
    assert(rows.get(0).getBirthDate() == LocalDate.of(2010, 9, 7));
}

/// A bean whose setters are partly inherited, as petclinic-rest's `Owner : Person : BaseEntity`.
class Employee : Person
{
    private string title;

    string getTitle()
    {
        return title;
    }

    void setTitle(string title)
    {
        this.title = title;
    }
}

@("BeanPropertyRowMapper: setters declared by a base class map too")
unittest
{
    import flint.jdbc.core : BeanPropertyRowMapper;

    auto f = Fixture.create();
    auto template_ = f.namedParameterTemplate.getJdbcTemplate();
    f.connection.results = new Rows(["name", "age", "title"], [
        [Any.of("Bubba"), Any.of(22L), Any.of("cook")]
    ]);
    auto rows = template_.query("select name, age, title from employees", new BeanPropertyRowMapper!Employee);
    auto employee = rows.get(0);
    assert(employee.getName() == "Bubba" && employee.getAge() == 22 && employee.getTitle() == "cook");
}

@("BeanPropertySqlParameterSource: getters declared by a base class are readable")
unittest
{
    import flint.jdbc.core.namedparam : BeanPropertySqlParameterSource;

    auto employee = new Employee;
    employee.setName("Bubba");
    employee.setTitle("cook");
    auto source = new BeanPropertySqlParameterSource(employee);
    assert(source.hasValue("name") && source.getValue("name").get!string == "Bubba");
    assert(source.getValue("title").get!string == "cook");
}

@("DataClassRowMapper: constructor parameters by column name")
unittest
{
    import flint.jdbc.core : DataClassRowMapper;

    import flint.engine.aot.descriptor : ConstructorDescriptor, ParameterDescriptor, descriptorOf;

    // The canonical constructor, as Flint AOT records it in the generated descriptor.
    auto descriptor = descriptorOf!ConstructorPerson();
    descriptor.constructors = [
        ConstructorDescriptor([
            ParameterDescriptor("name", "string"), ParameterDescriptor("age", "long")
        ], null,
        (scope Any[] args) @safe => Any.ofObject(new ConstructorPerson(args[0].get!string,
                args[1].get!long), typeid(ConstructorPerson).name))
    ];
    auto f = Fixture.create();
    f.connection.results = new Rows(["AGE", "name"], [[Any.of(22L), Any.of("Bubba")]]);
    auto person = f.namedParameterTemplate.getJdbcTemplate().queryForObject("select age, name from people",
            new DataClassRowMapper!ConstructorPerson(descriptor));
    assert(person.getName() == "Bubba" && person.getAge() == 22);
}
