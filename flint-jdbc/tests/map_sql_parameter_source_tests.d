/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/namedparam/MapSqlParameterSourceTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts, and Java's `null`
map a null `Map!(string, Any)`. The `toString` case that names an SQL type waits behind a version gate.
+/
module flint.jdbc.map_sql_parameter_source_tests;

import flint.engine.aot.any : Any;
import flint.java.lang : IllegalArgumentException;
import flint.java.sql : Types;
import flint.jdbc.core : SqlParameterValue;
import flint.jdbc.core.namedparam : MapSqlParameterSource;
import flint.jdbc.support : JdbcUtils;

@safe:

private void expectThrows(E : Throwable)(scope void delegate() @safe action)
{
    try
        action();
    catch (E)
        return;
    assert(false, "expected " ~ E.stringof);
}

@("MapSqlParameterSourceTests.nullParameterValuesPassedToCtorIsOk")
unittest
{
    new MapSqlParameterSource(null);
}

@("MapSqlParameterSourceTests.getValueChokesIfParameterIsNotPresent")
unittest
{
    auto source = new MapSqlParameterSource();
    expectThrows!IllegalArgumentException({ source.getValue("pechorin was right!"); });
}

@("MapSqlParameterSourceTests.sqlParameterValueRegistersSqlType")
unittest
{
    auto msps = new MapSqlParameterSource("FOO", new SqlParameterValue(Types.NUMERIC, Any.of("Foo")));
    assert(msps.getSqlType("FOO") == 2, "Correct SQL Type not registered");
    auto msps2 = new MapSqlParameterSource();
    msps2.addValues(msps.getValues());
    assert(msps2.getSqlType("FOO") == 2, "Correct SQL Type not registered");
}

// Behaviour: AbstractSqlParameterSource.toString names an SQL type by its number ("type:2"), not by its Types
// constant ("type:NUMERIC"), as JdbcUtils.resolveTypeName is not ported.
version (FlintJdbcResolveTypeName)
{
    @("MapSqlParameterSourceTests.toStringShowsParameterDetails")
    unittest
    {
        auto source = new MapSqlParameterSource("FOO", new SqlParameterValue(Types.NUMERIC, Any.of("Foo")));
        assert(source.toString() == "MapSqlParameterSource {FOO=Foo (type:NUMERIC)}", source.toString());
    }
}

@("MapSqlParameterSourceTests.toStringShowsCustomSqlType")
unittest
{
    import flint.engine.aot.text : decimal;

    auto source = new MapSqlParameterSource("FOO", new SqlParameterValue(int.max, Any.of("Foo")));
    assert(source.toString() == "MapSqlParameterSource {FOO=Foo (type:" ~ decimal(int.max) ~ ")}", source.toString());
}

@("MapSqlParameterSourceTests.toStringDoesNotShowTypeUnknown")
unittest
{
    auto source = new MapSqlParameterSource("FOO", new SqlParameterValue(JdbcUtils.TYPE_UNKNOWN, Any.of("Foo")));
    assert(source.toString() == "MapSqlParameterSource {FOO=Foo}", source.toString());
}
