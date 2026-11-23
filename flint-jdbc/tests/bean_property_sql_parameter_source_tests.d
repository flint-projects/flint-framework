/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/namedparam/BeanPropertySqlParameterSourceTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. Spring's
`TestBean` fixture is a private class with the three properties the cases read (`name`, `age` and a null
`beanFactory`), and Java's `null` bean a null `TestBean`. The `toString` cases that name SQL types wait behind a
version gate.
+/
module flint.jdbc.bean_property_sql_parameter_source_tests;

import flint.java.lang : IllegalArgumentException;
import flint.java.sql : Types;
import flint.jdbc.core.namedparam : BeanPropertySqlParameterSource;
import std.algorithm.searching : canFind, endsWith, startsWith;

@safe:

/// The parts of `org.springframework.beans.testfixture.beans.TestBean` the cases use.
private final class TestBean
{
    private string name;
    private int age;
    private Object beanFactory;

    this()
    {
    }

    this(string name, int age)
    {
        this.name = name;
        this.age = age;
    }

    string getName()
    {
        return name;
    }

    void setName(string name)
    {
        this.name = name;
    }

    int getAge()
    {
        return age;
    }

    void setAge(int age)
    {
        this.age = age;
    }

    Object getBeanFactory()
    {
        return beanFactory;
    }

    void setBeanFactory(Object beanFactory)
    {
        this.beanFactory = beanFactory;
    }
}

private final class NoReadableProperties
{
    void setNoOp(string noOp)
    {
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

@("BeanPropertySqlParameterSourceTests.withNullBeanPassedToCtor")
unittest
{
    expectThrows!IllegalArgumentException({ new BeanPropertySqlParameterSource(cast(TestBean) null); });
}

@("BeanPropertySqlParameterSourceTests.getValueWhereTheUnderlyingBeanHasNoSuchProperty")
unittest
{
    auto source = new BeanPropertySqlParameterSource(new TestBean());
    expectThrows!IllegalArgumentException({ source.getValue("thisPropertyDoesNotExist"); });
}

@("BeanPropertySqlParameterSourceTests.successfulPropertyAccess")
unittest
{
    auto source = new BeanPropertySqlParameterSource(new TestBean("tb", 99));
    assert(source.getReadablePropertyNames().canFind("name"));
    assert(source.getReadablePropertyNames().canFind("age"));
    assert(source.getValue("name").get!string == "tb");
    assert(source.getValue("age").get!int == 99);
    assert(source.getSqlType("name") == Types.VARCHAR);
    assert(source.getSqlType("age") == Types.INTEGER);
}

@("BeanPropertySqlParameterSourceTests.successfulPropertyAccessWithOverriddenSqlType")
unittest
{
    auto source = new BeanPropertySqlParameterSource(new TestBean("tb", 99));
    source.registerSqlType("age", Types.NUMERIC);
    assert(source.getValue("name").get!string == "tb");
    assert(source.getValue("age").get!int == 99);
    assert(source.getSqlType("name") == Types.VARCHAR);
    assert(source.getSqlType("age") == Types.NUMERIC);
}

@("BeanPropertySqlParameterSourceTests.hasValueWhereTheUnderlyingBeanHasNoSuchProperty")
unittest
{
    auto source = new BeanPropertySqlParameterSource(new TestBean());
    assert(!source.hasValue("thisPropertyDoesNotExist"));
}

@("BeanPropertySqlParameterSourceTests.getValueWhereTheUnderlyingBeanPropertyIsNotReadable")
unittest
{
    auto source = new BeanPropertySqlParameterSource(new NoReadableProperties());
    expectThrows!IllegalArgumentException({ source.getValue("noOp"); });
}

@("BeanPropertySqlParameterSourceTests.hasValueWhereTheUnderlyingBeanPropertyIsNotReadable")
unittest
{
    auto source = new BeanPropertySqlParameterSource(new NoReadableProperties());
    assert(!source.hasValue("noOp"));
}

// Behaviour: AbstractSqlParameterSource.toString names an SQL type by its number ("type:12"), not by its Types
// constant ("type:VARCHAR"), as JdbcUtils.resolveTypeName is not ported.
version (FlintJdbcResolveTypeName)
{
    @("BeanPropertySqlParameterSourceTests.toStringShowsParameterDetails")
    unittest
    {
        auto source = new BeanPropertySqlParameterSource(new TestBean("tb", 99));
        const text = source.toString();
        assert(text.startsWith("BeanPropertySqlParameterSource {"), text);
        assert(text.canFind("name=tb (type:VARCHAR)"), text);
        assert(text.canFind("age=99 (type:INTEGER)"), text);
        assert(text.endsWith("}"), text);
    }

    @("BeanPropertySqlParameterSourceTests.toStringShowsCustomSqlType")
    unittest
    {
        import flint.engine.aot.text : decimal;

        auto source = new BeanPropertySqlParameterSource(new TestBean("tb", 99));
        source.registerSqlType("name", int.max);
        const text = source.toString();
        assert(text.startsWith("BeanPropertySqlParameterSource {"), text);
        assert(text.canFind("name=tb (type:" ~ decimal(int.max) ~ ")"), text);
        assert(text.canFind("age=99 (type:INTEGER)"), text);
        assert(text.endsWith("}"), text);
    }
}

@("BeanPropertySqlParameterSourceTests.toStringDoesNotShowTypeUnknown")
unittest
{
    auto source = new BeanPropertySqlParameterSource(new TestBean("tb", 99));
    const text = source.toString();
    assert(text.startsWith("BeanPropertySqlParameterSource {"), text);
    assert(text.canFind("beanFactory=null"), text);
    assert(!text.canFind("beanFactory=null (type:"), text);
    assert(text.endsWith("}"), text);
}
