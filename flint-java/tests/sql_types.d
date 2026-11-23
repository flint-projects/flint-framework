module flint.java.sql_types_test;

import flint.engine.aot.any : Any;
import flint.java.lang : IllegalStateException;
import flint.java.sql : BatchUpdateException, Connection, DatabaseMetaData, Driver, DriverManager,
    PreparedStatement, ResultSet, ResultSetMetaData,
    Savepoint, SQLDataException, SQLException,
    SQLIntegrityConstraintViolationException, SQLNonTransientException, SQLSyntaxErrorException, SQLTimeoutException,
    SQLTransactionRollbackException, SQLTransientException, SQLWarning, Statement, Types, Wrapper;
import flint.java.util : Properties;
import flint.javax.sql : DataSource;

@safe:

@("SQLException keeps reason, SQLSTATE, vendor code, cause and the next-exception chain")
unittest
{
    auto cause = new IllegalStateException("socket closed");
    auto first = new SQLException("duplicate key", "23505", 2067, cause);
    assert(first.getMessage() == "duplicate key");
    assert(first.getSQLState() == "23505" && first.getErrorCode() == 2067);
    assert(first.getCause() is cause);
    assert(first.getNextException() is null);

    auto second = new SQLException("second");
    auto third = new SQLException("third");
    first.setNextException(second);
    first.setNextException(third);
    assert(first.getNextException() is second && second.getNextException() is third);

    auto plain = new SQLException();
    assert(plain.getMessage() is null && plain.getSQLState() is null && plain.getErrorCode() == 0);
    assert(new SQLException("x", "42000", cause).getCause() is cause);
    assert(new SQLException(cause).getMessage() == "flint.java.lang.IllegalStateException: socket closed");
    assert(first.toString() == "flint.java.sql.SQLException: duplicate key");
}

@("the JDBC 4 subclasses classify failures as Spring's subclass translator expects")
unittest
{
    SQLException violation = new SQLIntegrityConstraintViolationException("dup", "23505", 1555);
    assert(cast(SQLNonTransientException) violation !is null);
    assert(violation.getSQLState() == "23505" && violation.getErrorCode() == 1555);
    assert(cast(SQLNonTransientException) new SQLSyntaxErrorException("bad", "42601") !is null);
    assert(cast(SQLNonTransientException) new SQLDataException("range", "22003") !is null);
    assert(cast(SQLTransientException) new SQLTransactionRollbackException("deadlock", "40P01") !is null);
    assert(cast(SQLTransientException) new SQLTimeoutException("slow") !is null);
    SQLException syntax = new SQLSyntaxErrorException("bad");
    assert(cast(SQLTransientException) syntax is null);
}

@("SQLWarning chains warnings, and BatchUpdateException keeps the counts that ran")
unittest
{
    auto warning = new SQLWarning("truncated", "01004");
    auto next = new SQLWarning("rounded");
    warning.setNextWarning(next);
    assert(warning.getNextWarning() is next);
    assert(next.getNextWarning() is null);

    auto batch = new BatchUpdateException("row 3 failed", "23505", 0, [1, 1, cast(long) int.max + 5]);
    assert(batch.getUpdateCounts() == [1, 1, int.max]);
    assert(batch.getLargeUpdateCounts() == [1, 1, cast(long) int.max + 5]);
    assert(batch.getSQLState() == "23505");
}

@("Types keeps the JDBC codes")
unittest
{
    static assert(Types.INTEGER == 4 && Types.BIGINT == -5 && Types.VARCHAR == 12 && Types.BOOLEAN == 16);
    static assert(Types.NULL == 0 && Types.OTHER == 1111 && Types.TIMESTAMP == 93 && Types.BLOB == 2004);
    static assert(Connection.TRANSACTION_READ_COMMITTED == 2 && Connection.TRANSACTION_SERIALIZABLE == 8);
    static assert(Statement.RETURN_GENERATED_KEYS == 1 && Statement.EXECUTE_FAILED == -3);
    static assert(ResultSet.TYPE_FORWARD_ONLY == 1003 && ResultSet.CONCUR_READ_ONLY == 1007);
}

// A fake driver whose connections only report their URL and credentials.
private final class FakeConnection : Wrapper
{
    string url;
    string user;

    this(string url, string user)
    {
        this.url = url;
        this.user = user;
    }

    Object unwrap(const TypeInfo_Class iface)
    {
        if (iface is typeid(FakeConnection) || iface.isBaseOf(typeid(FakeConnection)))
            return this;
        throw new SQLException("not a wrapper for " ~ iface.name);
    }

    bool isWrapperFor(const TypeInfo_Class iface)
    {
        return iface is typeid(FakeConnection) || iface.isBaseOf(typeid(FakeConnection));
    }
}

private abstract class FakeDriver : Driver
{
    abstract string prefix();

    Connection connect(string url, Properties info)
    {
        if (!acceptsURL(url))
            return null;
        if (url.length > prefix.length && url[prefix.length .. $] == "fail")
            throw new SQLException("refused", "28000");
        // Report the credentials the driver received through the exception, so no Connection is needed.
        if (url.length > prefix.length && url[prefix.length .. $] == "whoami")
            throw new SQLException("user=" ~ info.getProperty("user",
                    "") ~ " password=" ~ info.getProperty("password", ""));
        return null;
    }

    bool acceptsURL(string url)
    {
        return url.length >= prefix.length && url[0 .. prefix.length] == prefix;
    }

    int getMajorVersion()
    {
        return 1;
    }

    int getMinorVersion()
    {
        return 0;
    }

    bool jdbcCompliant()
    {
        return false;
    }
}

private final class AlphaDriver : FakeDriver
{
    override string prefix()
    {
        return "jdbc:alpha:";
    }
}

private final class BetaDriver : FakeDriver
{
    override string prefix()
    {
        return "jdbc:beta:";
    }
}

private Driver alpha()
{
    return new AlphaDriver;
}

private Driver beta()
{
    return new BetaDriver;
}

@("DriverManager finds the registered driver for a URL and reports a missing or refusing one")
unittest
{
    DriverManager.registerDriver(&alpha);
    DriverManager.registerDriver(&beta);
    DriverManager.registerDriver(&alpha); // a second registration keeps one entry
    scope (exit)
    {
        DriverManager.deregisterDriver(&alpha);
        DriverManager.deregisterDriver(&beta);
    }
    assert(DriverManager.getDrivers().length == 2);
    assert(cast(BetaDriver) DriverManager.getDriver("jdbc:beta:x") !is null);

    // Every driver returned null: no connection, so the URL is reported as unsupported.
    try
    {
        DriverManager.getConnection("jdbc:alpha:db", "sa", "secret");
        assert(false, "expected SQLException");
    }
    catch (SQLException ex)
        assert(ex.getSQLState() == "08001" && ex.getMessage() == "No suitable driver found for jdbc:alpha:db");

    // The user and password reach the driver as connection properties.
    try
    {
        DriverManager.getConnection("jdbc:alpha:whoami", "sa", "secret");
        assert(false, "expected SQLException");
    }
    catch (SQLException ex)
        assert(ex.getMessage() == "user=sa password=secret");

    // A driver's own failure wins over "no suitable driver".
    try
    {
        DriverManager.getConnection("jdbc:beta:fail");
        assert(false, "expected SQLException");
    }
    catch (SQLException ex)
        assert(ex.getMessage() == "refused" && ex.getSQLState() == "28000");

    try
    {
        DriverManager.getDriver("jdbc:gamma:x");
        assert(false, "expected SQLException");
    }
    catch (SQLException ex)
        assert(ex.getSQLState() == "08001");

    DriverManager.deregisterDriver(&beta);
    assert(DriverManager.getDrivers().length == 1);
}

@("Wrapper.unwrap takes a type parameter as well as a type token")
unittest
{
    auto connection = new FakeConnection("jdbc:alpha:db", "sa");
    Wrapper wrapper = connection;
    assert(wrapper.unwrap!FakeConnection() is connection);
    assert(wrapper.isWrapperFor(typeid(FakeConnection)));
    assert(!wrapper.isWrapperFor(typeid(SQLException)));
    try
    {
        wrapper.unwrap(typeid(SQLException));
        assert(false, "expected SQLException");
    }
    catch (SQLException ex)
        assert(ex.getMessage() == "not a wrapper for flint.java.sql.SQLException");
}

@("the JDBC interfaces compose as JDBC's do")
unittest
{
    static assert(is(PreparedStatement : Statement) && is(Statement : Wrapper));
    static assert(is(DataSource : Wrapper));
    static assert(__traits(compiles, (ResultSet rs) => rs.getObject!long(1)));
    static assert(__traits(compiles, (ResultSet rs) => rs.getObject!string("first_name")));
    static assert(__traits(compiles, (Connection c) => c.rollback(cast(Savepoint) null)));
    static assert(__traits(compiles, (ResultSetMetaData m) => m.getColumnLabel(1)));
    static assert(__traits(compiles, (DatabaseMetaData m) => m.supportsSavepoints()));
    static assert(__traits(compiles, (PreparedStatement ps) => ps.setObject(1, Any.of(42L))));
}
