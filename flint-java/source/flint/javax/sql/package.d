/++
`javax.sql` as Spring's JDBC support exposes it: `DataSource`, the factory of connections that `JdbcTemplate`,
`DataSourceUtils` and `DataSourceTransactionManager` take (ADR-030, rulebook R1). Written clean-room from the
Java SE 21 API specification. Connection pools, XA and row sets arrive with the packages that need them.
+/
module flint.javax.sql;

import flint.java.sql : Connection, Wrapper;

@safe:

/// The methods common to `DataSource` and the pooled and XA data sources.
interface CommonDataSource
{
    /// The seconds to wait while connecting; zero means the system default or no limit.
    void setLoginTimeout(int seconds);
    /// ditto
    int getLoginTimeout();
}

/// A factory for connections to the database it represents: the preferred alternative to `DriverManager`.
interface DataSource : CommonDataSource, Wrapper
{
    /// A connection, with the data source's own credentials.
    Connection getConnection();

    /// A connection as `username` with `password`.
    Connection getConnection(string username, string password);
}
