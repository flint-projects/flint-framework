/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/datasource/DelegatingDataSourceTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: a recording `DataSource` fake replaces the Mockito mock, and `Class` arguments are
`TypeInfo_Class`es (R4). `datasources.d` (module `flint.jdbc.datasources_test`) has an overlapping combined test.
+/
module flint.jdbc.delegating_data_source_tests;

import flint.java.sql : Connection;
import flint.javax.sql : DataSource;
import flint.jdbc.datasource : DelegatingDataSource;
import std.typecons : BlackHole, Rebindable;

@safe:

public interface ExampleWrapper
{
}

private final class FakeConnection : BlackHole!Connection
{
}

private final class FakeExampleWrapper : ExampleWrapper
{
}

/// The delegate: answers what a test stubs and records what the `DelegatingDataSource` passes on.
private final class FakeDataSource : BlackHole!DataSource
{
    Connection connection;
    string expectedUsername, expectedPassword;
    int loginTimeout;
    int setLoginTimeoutCalls;
    Object wrapper;
    Rebindable!(const TypeInfo_Class) expectedIface;
    bool wrapperFor;

    version (FlintDataSourceLogWriter)
    {
        import flint.java.io : PrintWriter;

        PrintWriter logWriter;

        override PrintWriter getLogWriter()
        {
            return logWriter;
        }

        override void setLogWriter(PrintWriter writer)
        {
            logWriter = writer;
        }
    }

    override Connection getConnection()
    {
        return connection;
    }

    override Connection getConnection(string username, string password)
    {
        return username == expectedUsername && password == expectedPassword ? connection : null;
    }

    override int getLoginTimeout()
    {
        return loginTimeout;
    }

    override void setLoginTimeout(int seconds)
    {
        ++setLoginTimeoutCalls;
        loginTimeout = seconds;
    }

    override Object unwrap(const TypeInfo_Class iface)
    {
        return iface is expectedIface ? wrapper : null;
    }

    override bool isWrapperFor(const TypeInfo_Class iface)
    {
        return iface is expectedIface && wrapperFor;
    }
}

private class DelegatingDataSourceWithWrapper : DelegatingDataSource, ExampleWrapper
{
}

/// Spring's fields: the mock delegate and the `DelegatingDataSource` around it.
private struct Fixture
{
    FakeDataSource delegate_;
    DelegatingDataSource dataSource;

    static Fixture create()
    {
        Fixture fixture;
        fixture.delegate_ = new FakeDataSource;
        fixture.dataSource = new DelegatingDataSource(fixture.delegate_);
        return fixture;
    }
}

@("DelegatingDataSourceTests.shouldDelegateGetConnection")
unittest
{
    auto f = Fixture.create();
    auto connection = new FakeConnection;
    f.delegate_.connection = connection;
    assert(f.dataSource.getConnection() is connection);
}

@("DelegatingDataSourceTests.shouldDelegateGetConnectionWithUsernameAndPassword")
unittest
{
    auto f = Fixture.create();
    auto connection = new FakeConnection;
    const username = "username";
    const password = "password";
    f.delegate_.connection = connection;
    f.delegate_.expectedUsername = username;
    f.delegate_.expectedPassword = password;
    assert(f.dataSource.getConnection(username, password) is connection);
}

version (FlintDataSourceLogWriter)
{
    // Gap: flint.javax.sql.CommonDataSource has no getLogWriter/setLogWriter (no java.io.PrintWriter).
    @("DelegatingDataSourceTests.shouldDelegateGetLogWriter")
    unittest
    {
        import flint.java.io : ByteArrayOutputStream, PrintWriter;

        auto f = Fixture.create();
        auto writer = new PrintWriter(new ByteArrayOutputStream);
        f.delegate_.logWriter = writer;
        assert(f.dataSource.getLogWriter() is writer);
    }

    @("DelegatingDataSourceTests.shouldDelegateSetLogWriter")
    unittest
    {
        import flint.java.io : ByteArrayOutputStream, PrintWriter;

        auto f = Fixture.create();
        auto writer = new PrintWriter(new ByteArrayOutputStream);
        f.dataSource.setLogWriter(writer);
        assert(f.delegate_.logWriter is writer);
    }
}

@("DelegatingDataSourceTests.shouldDelegateGetLoginTimeout")
unittest
{
    auto f = Fixture.create();
    const timeout = 123;
    f.delegate_.loginTimeout = timeout;
    assert(f.dataSource.getLoginTimeout() == timeout);
}

@("DelegatingDataSourceTests.shouldDelegateSetLoginTimeoutWithSeconds")
unittest
{
    auto f = Fixture.create();
    const timeout = 123;
    f.dataSource.setLoginTimeout(timeout);
    assert(f.delegate_.setLoginTimeoutCalls == 1 && f.delegate_.loginTimeout == timeout);
}

@("DelegatingDataSourceTests.shouldDelegateUnwrapWithoutImplementing")
unittest
{
    auto f = Fixture.create();
    auto wrapper = new FakeExampleWrapper;
    f.delegate_.expectedIface = typeid(ExampleWrapper).info;
    f.delegate_.wrapper = wrapper;
    assert(f.dataSource.unwrap(typeid(ExampleWrapper).info) is wrapper);
}

@("DelegatingDataSourceTests.shouldDelegateUnwrapImplementing")
unittest
{
    auto f = Fixture.create();
    f.dataSource = new DelegatingDataSourceWithWrapper;
    assert(f.dataSource.unwrap(typeid(ExampleWrapper).info) is f.dataSource);
}

@("DelegatingDataSourceTests.shouldDelegateIsWrapperForWithoutImplementing")
unittest
{
    auto f = Fixture.create();
    f.delegate_.expectedIface = typeid(ExampleWrapper).info;
    f.delegate_.wrapperFor = true;
    assert(f.dataSource.isWrapperFor(typeid(ExampleWrapper).info));
}

@("DelegatingDataSourceTests.shouldDelegateIsWrapperForImplementing")
unittest
{
    auto f = Fixture.create();
    f.dataSource = new DelegatingDataSourceWithWrapper;
    assert(f.dataSource.isWrapperFor(typeid(ExampleWrapper).info));
}
