// Ported from spring-framework v7.1.0: spring-jdbc/src/test/java/org/springframework/jdbc/datasource/DriverManagerDataSourceTests.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: DelegatingDataSourceTests.java.

/// `DriverManagerDataSourceTests` and `DelegatingDataSourceTests`. The log-writer cases are dropped with
/// `PrintWriter`, which `flint.javax.sql.DataSource` does not carry.
module flint.jdbc.datasources_test;

import flint.java.lang : IllegalStateException;
import flint.java.sql : Connection, Driver, DriverManager;
import flint.java.util : Properties;
import flint.javax.sql : DataSource;
import flint.jdbc.datasource;
import std.typecons : BlackHole;

@safe:

private final class FakeConnection : BlackHole!Connection
{
}

/// Java's `new Properties()` with `setProperty` calls.
private Properties properties(string[string] entries)
{
    auto props = new Properties;
    foreach (key, value; entries)
        props.setProperty(key, value);
    return props;
}

private string[string] entries(Properties props)
{
    string[string] result;
    foreach (name; props.stringPropertyNames().toArray())
        result[name] = props.getProperty(name);
    return result;
}

/// A `DriverManagerDataSource` that checks what it would pass to `DriverManager`.
private final class TestDriverManagerDataSource : DriverManagerDataSource
{
    string expectedUrl;
    string[string] expectedProps;
    Connection connection;

    this(string expectedUrl, string[string] expectedProps, Connection connection)
    {
        this.expectedUrl = expectedUrl;
        this.expectedProps = expectedProps;
        this.connection = connection;
    }

    protected override Connection getConnectionFromDriverManager(string url, Properties props)
    {
        assert(url == expectedUrl);
        assert(entries(props) == expectedProps, "connection properties");
        return connection;
    }
}

@("DriverManagerDataSourceTests.standardUsage")
unittest
{
    auto connection = new FakeConnection;
    auto ds = new TestDriverManagerDataSource("url", ["user": "uname", "password": "pwd"], connection);
    ds.setUrl("url");
    ds.setUsername("uname");
    ds.setPassword("pwd");
    assert(ds.getConnection() is connection);
    assert(ds.getUrl() == "url" && ds.getPassword() == "pwd" && ds.getUsername() == "uname");
}

@("DriverManagerDataSourceTests.usageWithConnectionProperties")
unittest
{
    auto connection = new FakeConnection;
    auto props = ["myProp": "myValue", "yourProp": "yourValue", "user": "uname", "password": "pwd"];
    auto ds = new TestDriverManagerDataSource("url", props.dup, connection);
    ds.setUrl("url");
    ds.setConnectionProperties(properties(props));
    assert(ds.getConnection() is connection);
    assert(ds.getUrl() == "url");
}

@("DriverManagerDataSourceTests.usageWithConnectionPropertiesAndUserCredentials")
unittest
{
    auto connection = new FakeConnection;
    auto ds = new TestDriverManagerDataSource("url", [
        "myProp": "myValue",
        "yourProp": "yourValue",
        "user": "uname",
        "password": "pwd"
    ], connection);
    ds.setUrl("url");
    ds.setUsername("uname");
    ds.setPassword("pwd");
    auto connProps = properties(["myProp": "myValue", "yourProp": "yourValue"]);
    connProps.setProperty("user", "uname2");
    connProps.setProperty("password", "pwd2");
    ds.setConnectionProperties(connProps);
    assert(ds.getConnection() is connection);
    assert(ds.getUrl() == "url" && ds.getPassword() == "pwd" && ds.getUsername() == "uname");
}

@("DriverManagerDataSourceTests.invalidClassName: an unknown driver class is an IllegalStateException")
unittest
{
    auto ds = new DriverManagerDataSource;
    try
    {
        ds.setDriverClassName("foobar");
        assert(false, "expected IllegalStateException");
    }
    catch (IllegalStateException)
    {
    }
}

private final class NamedDriver : BlackHole!Driver
{
}

@("setDriverClassName accepts a registered driver's class name, and setUrl trims")
unittest
{
    static Driver supply()
    {
        return new NamedDriver;
    }

    DriverManager.registerDriver(&supply);
    scope (exit)
        DriverManager.deregisterDriver(&supply);
    auto ds = new DriverManagerDataSource;
    ds.setDriverClassName(" " ~ typeid(NamedDriver).name ~ " ");
    ds.setUrl("  jdbc:x:y \n");
    assert(ds.getUrl() == "jdbc:x:y");
}

private interface ExampleWrapper
{
}

private final class DelegatingDataSourceWithWrapper : DelegatingDataSource, ExampleWrapper
{
}

/// A delegate data source that records what was delegated to it.
private final class Delegate : BlackHole!DataSource
{
    Connection connection;
    string lastUser, lastPassword;
    int loginTimeout;
    Object wrapped;

    override Connection getConnection()
    {
        return connection;
    }

    override Connection getConnection(string username, string password)
    {
        lastUser = username;
        lastPassword = password;
        return connection;
    }

    override int getLoginTimeout()
    {
        return loginTimeout;
    }

    override void setLoginTimeout(int seconds)
    {
        loginTimeout = seconds;
    }

    override Object unwrap(const TypeInfo_Class)
    {
        return wrapped;
    }

    override bool isWrapperFor(const TypeInfo_Class iface)
    {
        return iface is ExampleWrapper.classinfo;
    }
}

@("DelegatingDataSourceTests: connections, login timeouts and unwrapping delegate to the target")
unittest
{
    auto target = new Delegate;
    target.connection = new FakeConnection;
    auto dataSource = new DelegatingDataSource(target);
    assert(dataSource.getConnection() is target.connection);
    assert(dataSource.getConnection("username", "password") is target.connection);
    assert(target.lastUser == "username" && target.lastPassword == "password");

    target.loginTimeout = 123;
    assert(dataSource.getLoginTimeout() == 123);
    dataSource.setLoginTimeout(77);
    assert(target.loginTimeout == 77);

    target.wrapped = new Object;
    assert(dataSource.unwrap(ExampleWrapper.classinfo) is target.wrapped, "shouldDelegateUnwrapWithoutImplementing");
    assert(dataSource.isWrapperFor(ExampleWrapper.classinfo), "shouldDelegateIsWrapperForWithoutImplementing");

    auto implementing = new DelegatingDataSourceWithWrapper;
    implementing.setTargetDataSource(new Delegate);
    assert(implementing.unwrap(ExampleWrapper.classinfo) is implementing, "shouldDelegateUnwrapImplementing");
    assert(implementing.isWrapperFor(ExampleWrapper.classinfo), "shouldDelegateIsWrapperForImplementing");
}

@("DelegatingDataSource requires its target, and DataSourceUtils orders synchronizations by delegation depth")
unittest
{
    auto empty = new DelegatingDataSource;
    try
    {
        empty.afterPropertiesSet();
        assert(false, "expected IllegalArgumentException");
    }
    catch (Exception)
    {
    }
    try
    {
        empty.getConnection();
        assert(false, "expected IllegalStateException");
    }
    catch (IllegalStateException)
    {
    }
}
