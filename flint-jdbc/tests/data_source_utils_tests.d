/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/datasource/DataSourceUtilsTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: hand-written `DataSource` fakes replace the Mockito mocks.
`datasource_transaction_manager.d` (module `flint.jdbc.datasource_transaction_manager_test`) has an overlapping
combined test of `DataSourceUtils.getConnection`.
+/
module flint.jdbc.data_source_utils_tests;

import flint.java.lang : IllegalStateException;
import flint.java.sql : Connection, SQLException;
import flint.javax.sql : DataSource;
import flint.jdbc : CannotGetJdbcConnectionException;
import flint.jdbc.datasource : DataSourceUtils;
import std.algorithm.searching : startsWith;
import std.typecons : BlackHole;

@safe:

/// A data source whose `getConnection` returns null, or throws `failure` when one is set.
private final class FakeDataSource : BlackHole!DataSource
{
    SQLException failure;

    override Connection getConnection()
    {
        if (failure !is null)
            throw failure;
        return null;
    }
}

/// Run `action`, which must throw an `E`, and return it.
private E expectThrows(E : Throwable)(scope void delegate() @safe action)
{
    try
        action();
    catch (E ex)
        return ex;
    assert(false, "expected " ~ E.stringof);
}

@("DataSourceUtilsTests.connectionNotAcquiredExceptionIsPropagated")
unittest
{
    auto dataSource = new FakeDataSource;
    auto thrown = expectThrows!CannotGetJdbcConnectionException({
        DataSourceUtils.getConnection(dataSource);
    });
    assert(thrown.msg.startsWith("Failed to obtain JDBC Connection"));
    assert(cast(IllegalStateException) thrown.getCause() !is null);
}

@("DataSourceUtilsTests.connectionSQLExceptionIsPropagated")
unittest
{
    auto dataSource = new FakeDataSource;
    dataSource.failure = new SQLException("my dummy exception");
    auto thrown = expectThrows!CannotGetJdbcConnectionException({
        DataSourceUtils.getConnection(dataSource);
    });
    assert(thrown.msg.startsWith("Failed to obtain JDBC Connection"));
    auto cause = cast(SQLException) thrown.getCause();
    assert(cause !is null);
    assert(cause.msg == "my dummy exception");
}
