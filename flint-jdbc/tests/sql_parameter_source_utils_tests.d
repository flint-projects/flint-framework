/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/namedparam/SqlParameterSourceUtilsTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. `createBatch` is a
template over its arguments (R4), so Java's mixed `List.of(map, bean, source)` is passed as three arguments;
`Map.of` is a `HashMap!(string, Any)` and Spring's `TestBean` fixture a private class with a `name` property.
+/
module flint.jdbc.sql_parameter_source_utils_tests;

import flint.engine.aot.any : Any;
import flint.java.util : HashMap, Map;
import flint.jdbc.core.namedparam : BeanPropertySqlParameterSource, MapSqlParameterSource,
    SqlParameterSource, SqlParameterSourceUtils;

@safe:

/// The part of `org.springframework.beans.testfixture.beans.TestBean` the cases use.
private final class TestBean
{
    private string name;

    this(string name)
    {
        this.name = name;
    }

    string getName()
    {
        return name;
    }

    void setName(string name)
    {
        this.name = name;
    }
}

@("SqlParameterSourceUtilsTests.createBatchWithMapBeanAndSqlParameterSource")
unittest
{
    auto source = new MapSqlParameterSource("name", "source");
    Map!(string, Any) map = new HashMap!(string, Any);
    map.put("name", Any.of("map"));
    SqlParameterSource[] batch = SqlParameterSourceUtils.createBatch(map, new TestBean("bean"), source);
    assert(batch.length == 3);
    assert(cast(MapSqlParameterSource) batch[0]!is null);
    assert(batch[0].getValue("name").get!string == "map");
    assert(cast(BeanPropertySqlParameterSource) batch[1]!is null);
    assert(batch[1].getValue("name").get!string == "bean");
    assert(cast(Object) batch[2] is source);
}

@("SqlParameterSourceUtilsTests.createBatchWithSqlParameterSourceVarargs")
unittest
{
    auto source = new MapSqlParameterSource("name", "source");
    SqlParameterSource[] batch = SqlParameterSourceUtils.createBatch(source);
    assert(batch.length == 1 && cast(Object) batch[0] is source);
}
