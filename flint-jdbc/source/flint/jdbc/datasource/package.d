// Ported from spring-framework v7.1.0: spring-jdbc/src/main/java/org/springframework/jdbc/datasource/DataSourceTransactionManager.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: ConnectionHandle.java, SimpleConnectionHandle.java, ConnectionHolder.java, ConnectionProxy.java,
// SmartDataSource.java, JdbcTransactionObjectSupport.java, DataSourceUtils.java, AbstractDataSource.java,
// AbstractDriverBasedDataSource.java, DriverManagerDataSource.java, SimpleDriverDataSource.java and
// DelegatingDataSource.java.

/++
`org.springframework.jdbc.datasource`: obtaining JDBC connections from a `DataSource`, binding them to the current
transaction, and `DataSourceTransactionManager`, the `PlatformTransactionManager` for a single JDBC `DataSource`
(ADR-030).

Transaction state lives in `TransactionSynchronizationManager`, which is per fiber, so each request handled on a
reactor fiber sees only its own bound connection. Java's `Properties` are `string[string]`, as in
`flint.java.sql.Driver.connect`. `DriverManagerDataSource.setDriverClassName` loads nothing, since drivers register
when their module loads; Java's class loading is excluded as `jvm-runtime`.
+/
module flint.jdbc.datasource;

import core.atomic : atomicLoad, atomicStore;
import flint.beans.factory : InitializingBean;
import flint.core : causeOf;
import flint.engine.aot.objects : objectEquals, objectToString;
import flint.java.lang : IllegalArgumentException, IllegalStateException, RuntimeException,
    UnsupportedOperationException;
import flint.java.sql : Connection, Driver, DriverManager, SQLException,
    SQLFeatureNotSupportedException, Savepoint, Statement;
import flint.javax.sql : DataSource;
import flint.jdbc : CannotGetJdbcConnectionException;
import flint.slf4j : Logger, LoggerFactory;
import flint.transaction : CannotCreateTransactionException, NestedTransactionNotSupportedException,
    SavepointManager, TransactionDefinition, TransactionSystemException, TransactionUsageException;
import flint.transaction.support : AbstractPlatformTransactionManager, DefaultTransactionStatus,
    ResourceHolderSupport, ResourceTransactionManager,
    SmartTransactionObject,
    TransactionSynchronization, TransactionSynchronizationManager, TransactionSynchronizationUtils;
import std.typecons : Nullable;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Connection handles and holders

/// Simple interface to be implemented by handles for a JDBC `Connection`.
interface ConnectionHandle
{
    /// Fetch the JDBC `Connection` that this handle refers to.
    Connection getConnection();

    /// Release the JDBC `Connection` that this handle refers to. Default: nothing, assuming that the lifecycle of
    /// the connection is managed externally.
    void releaseConnection(Connection con);

    /// The Java default bodies.
    mixin template Defaults()
    {
        /// Default: nothing.
        void releaseConnection(Connection)
        {
        }
    }
}

/// Simple implementation of the `ConnectionHandle` interface, containing a given JDBC `Connection`.
class SimpleConnectionHandle : ConnectionHandle
{
    private Connection connection;

    /// Create a new `SimpleConnectionHandle` for the given `Connection`.
    this(Connection connection)
    {
        if (connection is null)
            throw new IllegalArgumentException("Connection must not be null");
        this.connection = connection;
    }

    mixin ConnectionHandle.Defaults;

    /// Return the specified `Connection` as-is.
    override Connection getConnection()
    {
        return connection;
    }

    override string toString()
    {
        return "SimpleConnectionHandle: " ~ objectToString(cast(Object) connection);
    }
}

/++
Resource holder wrapping a JDBC `Connection`. `DataSourceTransactionManager` binds instances of this class to the
current fiber, for a specific `DataSource`. Inherits rollback-only support for nested JDBC transactions and reference
count functionality from the base class. This is an SPI class, not intended to be used by applications.
+/
class ConnectionHolder : ResourceHolderSupport
{
    /// Prefix for savepoint names.
    enum string SAVEPOINT_NAME_PREFIX = "SAVEPOINT_";

    private ConnectionHandle connectionHandle;
    private Connection currentConnection;
    private bool transactionActive;
    private Nullable!bool savepointsSupported;
    private int savepointCounter;

    /// Create a new `ConnectionHolder` for the given `ConnectionHandle`.
    this(ConnectionHandle connectionHandle)
    {
        if (connectionHandle is null)
            throw new IllegalArgumentException("ConnectionHandle must not be null");
        this.connectionHandle = connectionHandle;
    }

    /// Create a new `ConnectionHolder` for the given JDBC `Connection`, wrapping it with a `SimpleConnectionHandle`,
    /// assuming that there is no ongoing transaction.
    this(Connection connection)
    {
        connectionHandle = new SimpleConnectionHandle(connection);
    }

    /// Create a new `ConnectionHolder` for the given JDBC `Connection`, wrapping it with a `SimpleConnectionHandle`.
    /// `transactionActive` tells whether the given `Connection` is involved in an ongoing transaction.
    this(Connection connection, bool transactionActive)
    {
        this(connection);
        this.transactionActive = transactionActive;
    }

    /// Return the `ConnectionHandle` held by this `ConnectionHolder`.
    ConnectionHandle getConnectionHandle()
    {
        return connectionHandle;
    }

    /// Return whether this holder currently has a `Connection`.
    protected bool hasConnection()
    {
        return connectionHandle !is null;
    }

    /// Set whether this holder represents an active, JDBC-managed transaction.
    protected void setTransactionActive(bool transactionActive)
    {
        this.transactionActive = transactionActive;
    }

    /// Return whether this holder represents an active, JDBC-managed transaction.
    protected bool isTransactionActive()
    {
        return transactionActive;
    }

    /// Override the existing `Connection` handle with the given `Connection`; reset the handle if given null. Used
    /// for releasing the `Connection` on suspend (with a null argument) and setting a fresh one on resume.
    protected void setConnection(Connection connection)
    {
        if (currentConnection !is null)
        {
            if (connectionHandle !is null)
                connectionHandle.releaseConnection(currentConnection);
            currentConnection = null;
        }
        connectionHandle = connection !is null ? new SimpleConnectionHandle(connection) : null;
    }

    /// Return the current `Connection` held by this `ConnectionHolder`. This will be the same `Connection` until
    /// `released` gets called, which resets the held `Connection`, fetching a new one on demand.
    Connection getConnection()
    {
        if (connectionHandle is null)
            throw new IllegalStateException("Active Connection is required");
        if (currentConnection is null)
            currentConnection = connectionHandle.getConnection();
        return currentConnection;
    }

    /// Return whether JDBC savepoints are supported. Caches the flag for the lifetime of this `ConnectionHolder`.
    bool supportsSavepoints()
    {
        if (savepointsSupported.isNull)
            savepointsSupported = getConnection().getMetaData().supportsSavepoints();
        return savepointsSupported.get;
    }

    /// Create a new JDBC `Savepoint` for the current `Connection`, using generated savepoint names that are unique
    /// for the `Connection`.
    Savepoint createSavepoint()
    {
        import std.conv : to;

        ++savepointCounter;
        return getConnection().setSavepoint(SAVEPOINT_NAME_PREFIX ~ savepointCounter.to!string);
    }

    /// Release the current `Connection` held by this `ConnectionHolder`, for `ConnectionHandle`s that expect
    /// "connection borrowing", where each returned `Connection` is only temporarily leased.
    override void released()
    {
        super.released();
        if (!isOpen() && currentConnection !is null)
        {
            if (connectionHandle !is null)
                connectionHandle.releaseConnection(currentConnection);
            currentConnection = null;
        }
    }

    override void clear()
    {
        super.clear();
        transactionActive = false;
        savepointsSupported.nullify();
        savepointCounter = 0;
    }
}

/// Subinterface of `Connection` to be implemented by `Connection` proxies. Allows access to the underlying target
/// `Connection`.
interface ConnectionProxy : Connection
{
    /// Return the target `Connection` of this proxy. This will typically be the native driver `Connection` or a
    /// wrapper from a connection pool.
    Connection getTargetConnection();
}

/// Extension of the `DataSource` interface, to be implemented by special `DataSource`s that return JDBC
/// `Connection`s in an unwrapped fashion. Classes using this interface can query whether the `Connection` should be
/// closed after an operation.
interface SmartDataSource : DataSource
{
    /// Should we close this `Connection`, obtained from this `DataSource`?
    bool shouldClose(Connection con);
}

// ---------------------------------------------------------------------------------------------------------------
// Transaction objects

/++
Convenient base class for JDBC-aware transaction objects. Can contain a `ConnectionHolder` with a JDBC `Connection`,
and implements the `SavepointManager` interface based on that `ConnectionHolder`. `DefaultTransactionStatus` delegates
to it, as it detects transaction objects that implement `SavepointManager`.
+/
abstract class JdbcTransactionObjectSupport : SavepointManager, SmartTransactionObject
{
    private ConnectionHolder connectionHolder;
    private Nullable!int previousIsolationLevel;
    private bool readOnly;
    private bool savepointAllowed;

    mixin SmartTransactionObject.Defaults;

    /// Set the `ConnectionHolder` for this transaction object.
    void setConnectionHolder(ConnectionHolder connectionHolder)
    {
        this.connectionHolder = connectionHolder;
    }

    /// Return the `ConnectionHolder` for this transaction object.
    ConnectionHolder getConnectionHolder()
    {
        if (connectionHolder is null)
            throw new IllegalStateException("No ConnectionHolder available");
        return connectionHolder;
    }

    /// Check whether this transaction object has a `ConnectionHolder`.
    bool hasConnectionHolder()
    {
        return connectionHolder !is null;
    }

    /// Set the previous isolation level to retain, if any.
    void setPreviousIsolationLevel(Nullable!int previousIsolationLevel)
    {
        this.previousIsolationLevel = previousIsolationLevel;
    }

    /// Return the retained previous isolation level, if any.
    Nullable!int getPreviousIsolationLevel()
    {
        return previousIsolationLevel;
    }

    /// Set the read-only status of this transaction. The default is false.
    void setReadOnly(bool readOnly)
    {
        this.readOnly = readOnly;
    }

    /// Return the read-only status of this transaction.
    bool isReadOnly()
    {
        return readOnly;
    }

    /// Set whether savepoints are allowed within this transaction. The default is false.
    void setSavepointAllowed(bool savepointAllowed)
    {
        this.savepointAllowed = savepointAllowed;
    }

    /// Return whether savepoints are allowed within this transaction.
    bool isSavepointAllowed()
    {
        return savepointAllowed;
    }

    /// This implementation creates a JDBC `Savepoint` and returns it.
    override Object createSavepoint()
    {
        auto conHolder = getConnectionHolderForSavepoint();
        try
        {
            if (!conHolder.supportsSavepoints())
                throw new NestedTransactionNotSupportedException(
                        "Cannot create a nested transaction because savepoints are not supported by your JDBC driver");
            if (conHolder.isRollbackOnly())
                throw new CannotCreateTransactionException(
                        "Cannot create savepoint for transaction which is already marked as rollback-only");
            return cast(Object) conHolder.createSavepoint();
        }
        catch (SQLException ex)
            throw new CannotCreateTransactionException("Could not create JDBC savepoint", ex);
    }

    /// This implementation rolls back to the given JDBC `Savepoint`.
    override void rollbackToSavepoint(Object savepoint)
    {
        auto conHolder = getConnectionHolderForSavepoint();
        try
        {
            conHolder.getConnection().rollback(cast(Savepoint) savepoint);
            conHolder.resetRollbackOnly();
        }
        catch (Exception ex)
            throw new TransactionSystemException("Could not roll back to JDBC savepoint", ex);
    }

    /// This implementation releases the given JDBC `Savepoint`.
    override void releaseSavepoint(Object savepoint)
    {
        auto conHolder = getConnectionHolderForSavepoint();
        try
            conHolder.getConnection().releaseSavepoint(cast(Savepoint) savepoint);
        catch (SQLFeatureNotSupportedException)
        {
            // typically on Oracle - ignore
        }
        catch (SQLException ex)
        {
            // Savepoint already released (HSQLDB, PostgreSQL, DB2) - ignore
            if (ex.getSQLState() == "3B001")
                return;
            // ignore Microsoft SQLServerException: This operation is not supported.
            const msg = ex.msg;
            if (msg is null || (!contains(msg, "not supported") && !contains(msg, "3B001")))
                throw new TransactionSystemException("Could not explicitly release JDBC savepoint", ex);
        }
        catch (Exception ex)
            throw new TransactionSystemException("Could not explicitly release JDBC savepoint", ex);
    }

    /// The `ConnectionHolder` to create savepoints on; throws when savepoints are not allowed or no JDBC
    /// transaction is exposed.
    protected ConnectionHolder getConnectionHolderForSavepoint()
    {
        if (!isSavepointAllowed())
            throw new NestedTransactionNotSupportedException("Transaction manager does not allow nested transactions");
        if (!hasConnectionHolder())
        {
            enum message = "Cannot create nested transaction when not exposing a JDBC transaction";
            throw new TransactionUsageException(message);
        }
        return getConnectionHolder();
    }
}

// ---------------------------------------------------------------------------------------------------------------
// DataSourceUtils

/++
Helper class that provides static methods for obtaining JDBC `Connection`s from a `DataSource`. Includes special
support for Spring-managed transactional `Connection`s, for example managed by `DataSourceTransactionManager`. Used
internally by `JdbcTemplate` and `DataSourceTransactionManager`; can also be used directly in application code.
+/
abstract class DataSourceUtils
{
    /// Order value for `TransactionSynchronization` objects that clean up JDBC `Connection`s.
    enum int CONNECTION_SYNCHRONIZATION_ORDER = 1000;

    private static Logger logger()
    {
        return LoggerFactory.getLogger("org.springframework.jdbc.datasource.DataSourceUtils");
    }

    /++
    Obtain a `Connection` from the given `DataSource`. Translates `SQLException`s into Spring's unchecked
    `CannotGetJdbcConnectionException`. Is aware of a corresponding `Connection` bound to the current fiber, for
    example when using `DataSourceTransactionManager`, and binds a `Connection` to the fiber if transaction
    synchronization is active.
    +/
    static Connection getConnection(DataSource dataSource)
    {
        try
            return doGetConnection(dataSource);
        catch (SQLException ex)
            throw new CannotGetJdbcConnectionException("Failed to obtain JDBC Connection", ex);
        catch (IllegalStateException ex)
            throw new CannotGetJdbcConnectionException("Failed to obtain JDBC Connection", ex);
    }

    /// Actually obtain a JDBC `Connection` from the given `DataSource`. Same as `getConnection`, but throwing the
    /// original `SQLException`.
    static Connection doGetConnection(DataSource dataSource)
    {
        if (dataSource is null)
            throw new IllegalArgumentException("No DataSource specified");
        auto conHolder = cast(ConnectionHolder) TransactionSynchronizationManager.getResource(cast(Object) dataSource);
        if (conHolder !is null && (conHolder.hasConnection() || conHolder.isSynchronizedWithTransaction()))
        {
            conHolder.requested();
            if (!conHolder.hasConnection())
            {
                logger().debug_("Fetching resumed JDBC Connection from DataSource");
                conHolder.setConnection(fetchConnection(dataSource));
            }
            return conHolder.getConnection();
        }
        // Else we either got no holder or an empty fiber-bound holder here.
        logger().debug_("Fetching JDBC Connection from DataSource");
        auto con = fetchConnection(dataSource);
        if (TransactionSynchronizationManager.isSynchronizationActive())
        {
            try
            {
                // Use same Connection for further JDBC actions within the transaction.
                // The fiber-bound object will get removed by synchronization at transaction completion.
                auto holderToUse = conHolder;
                if (holderToUse is null)
                    holderToUse = new ConnectionHolder(con);
                else
                    holderToUse.setConnection(con);
                holderToUse.requested();
                TransactionSynchronizationManager.registerSynchronization(new ConnectionSynchronization(holderToUse,
                        dataSource));
                holderToUse.setSynchronizedWithTransaction(true);
                if (holderToUse !is conHolder)
                    TransactionSynchronizationManager.bindResource(cast(Object) dataSource, holderToUse);
            }
            catch (RuntimeException ex)
            {
                // Unexpected exception from external delegation call -> close Connection and rethrow.
                releaseConnection(con, dataSource);
                throw ex;
            }
        }
        return con;
    }

    private static Connection fetchConnection(DataSource dataSource)
    {
        auto con = dataSource.getConnection();
        if (con is null)
            throw new IllegalStateException(
                    "DataSource returned null from getConnection(): " ~ objectToString(cast(Object) dataSource));
        return con;
    }

    /// Prepare the given `Connection` with the given transaction semantics. Returns the previous isolation level,
    /// if any.
    static Nullable!int prepareConnectionForTransaction(Connection con, TransactionDefinition definition)
    {
        return prepareConnectionForTransaction(con, definition !is null ? definition.getIsolationLevel()
                : TransactionDefinition.ISOLATION_DEFAULT, definition !is null && definition.isReadOnly());
    }

    package static Nullable!int prepareConnectionForTransaction(Connection con, int isolationLevel, bool setReadOnly)
    {
        import std.conv : to;

        if (con is null)
            throw new IllegalArgumentException("No Connection specified");
        const debugEnabled = logger().isDebugEnabled();
        // Set read-only flag.
        if (setReadOnly)
        {
            if (debugEnabled)
                logger().debug_("Setting JDBC Connection [" ~ describe(con) ~ "] read-only");
            setReadOnlyIfPossible(con);
        }
        // Apply specific isolation level, if any.
        Nullable!int previousIsolationLevel;
        if (isolationLevel != TransactionDefinition.ISOLATION_DEFAULT)
        {
            if (debugEnabled)
                logger().debug_("Changing isolation level of JDBC Connection [" ~ describe(
                        con) ~ "] to " ~ isolationLevel.to!string);
            const currentIsolation = con.getTransactionIsolation();
            if (currentIsolation != isolationLevel)
            {
                previousIsolationLevel = currentIsolation;
                con.setTransactionIsolation(isolationLevel);
            }
        }
        return previousIsolationLevel;
    }

    package static void setReadOnlyIfPossible(Connection con)
    {
        try
            con.setReadOnly(true);
        catch (Exception ex)
        {
            for (Throwable exToCheck = ex; exToCheck !is null; exToCheck = javaCause(exToCheck))
            {
                // Assume it's a connection timeout that would otherwise get lost: for example, from JDBC 4.0
                if (contains(simpleName(exToCheck), "Timeout"))
                    throw ex;
            }
            // "read-only not supported" SQLException -> ignore, it's just a hint anyway
            logger().debug_("Could not set JDBC Connection read-only", ex);
        }
    }

    /// Reset the given `Connection` after a transaction, regarding read-only flag and isolation level.
    static void resetConnectionAfterTransaction(Connection con, Nullable!int previousIsolationLevel, bool resetReadOnly)
    {
        import std.conv : to;

        if (con is null)
            throw new IllegalArgumentException("No Connection specified");
        const debugEnabled = logger().isDebugEnabled();
        try
        {
            // Reset transaction isolation to previous value, if changed for the transaction.
            if (!previousIsolationLevel.isNull)
            {
                if (debugEnabled)
                    logger().debug_("Resetting isolation level of JDBC Connection [" ~ describe(
                            con) ~ "] to " ~ previousIsolationLevel.get.to!string);
                con.setTransactionIsolation(previousIsolationLevel.get);
            }
            // Reset read-only flag if we originally switched it to true on transaction begin.
            if (resetReadOnly)
            {
                if (debugEnabled)
                    logger().debug_("Resetting read-only flag of JDBC Connection [" ~ describe(con) ~ "]");
                con.setReadOnly(false);
            }
        }
        catch (Exception ex)
            logger().debug_("Could not reset JDBC Connection after transaction", ex);
    }

    /// Reset the given `Connection` after a transaction, resetting the read-only flag whenever it is set.
    deprecated("since 5.1.11: pass resetReadOnly") static void resetConnectionAfterTransaction(
            Connection con, Nullable!int previousIsolationLevel)
    {
        if (con is null)
            throw new IllegalArgumentException("No Connection specified");
        try
        {
            bool readOnly;
            try
                readOnly = con.isReadOnly();
            catch (SQLException ex)
                throw ex;
            resetConnectionAfterTransaction(con, previousIsolationLevel, readOnly);
        }
        catch (Exception ex)
            logger().debug_("Could not reset JDBC Connection after transaction", ex);
    }

    /// Determine whether the given JDBC `Connection` is transactional, that is, bound to the current fiber by
    /// Spring's transaction facilities.
    static bool isConnectionTransactional(Connection con, DataSource dataSource)
    {
        if (dataSource is null)
            return false;
        auto conHolder = cast(ConnectionHolder) TransactionSynchronizationManager.getResource(cast(Object) dataSource);
        return conHolder !is null && connectionEquals(conHolder, con);
    }

    /// Apply the current transaction timeout, if any, to the given JDBC `Statement` object.
    static void applyTransactionTimeout(Statement stmt, DataSource dataSource)
    {
        applyTimeout(stmt, dataSource, -1);
    }

    /// Apply the specified timeout, overridden by the current transaction timeout, if any, to the given JDBC
    /// `Statement` object.
    static void applyTimeout(Statement stmt, DataSource dataSource, int timeout)
    {
        if (stmt is null)
            throw new IllegalArgumentException("No Statement specified");
        ConnectionHolder holder;
        if (dataSource !is null)
            holder = cast(ConnectionHolder) TransactionSynchronizationManager.getResource(cast(Object) dataSource);
        if (holder !is null && holder.hasTimeout()) // Remaining transaction timeout overrides specified value.
            stmt.setQueryTimeout(holder.getTimeToLiveInSeconds());
        else if (timeout >= 0) // No current transaction timeout -> apply specified value.
            stmt.setQueryTimeout(timeout);
    }

    /// Close the given `Connection`, obtained from the given `DataSource`, if it is not managed externally (that
    /// is, not bound to the fiber).
    static void releaseConnection(Connection con, DataSource dataSource)
    {
        try
            doReleaseConnection(con, dataSource);
        catch (SQLException ex)
            logger().debug_("Could not close JDBC Connection", ex);
        catch (Exception ex)
            logger().debug_("Unexpected exception on closing JDBC Connection", ex);
    }

    /// Actually close the given `Connection`. Same as `releaseConnection`, but throwing the original
    /// `SQLException`.
    static void doReleaseConnection(Connection con, DataSource dataSource)
    {
        if (con is null)
            return;
        if (dataSource !is null)
        {
            auto conHolder = cast(ConnectionHolder) TransactionSynchronizationManager.getResource(
                    cast(Object) dataSource);
            if (conHolder !is null && connectionEquals(conHolder, con))
            {
                // It's the transactional Connection: Don't close it.
                conHolder.released();
                return;
            }
        }
        doCloseConnection(con, dataSource);
    }

    /// Close the `Connection`, unless a `SmartDataSource` doesn't want us to.
    static void doCloseConnection(Connection con, DataSource dataSource)
    {
        auto smartDataSource = cast(SmartDataSource) dataSource;
        if (smartDataSource is null || smartDataSource.shouldClose(con))
            con.close();
    }

    private static bool connectionEquals(ConnectionHolder conHolder, Connection passedInCon)
    {
        if (!conHolder.hasConnection())
            return false;
        auto heldCon = conHolder.getConnection();
        // Explicitly check for identity too: for Connection handles that do not implement "equals" properly.
        return heldCon is passedInCon || objectEquals(cast(Object) heldCon, cast(Object) passedInCon)
            || objectEquals(cast(Object) getTargetConnection(heldCon), cast(Object) passedInCon);
    }

    /// Return the innermost target `Connection` of the given `Connection`. If the given `Connection` is a proxy, it
    /// will be unwrapped until a non-proxy `Connection` is found. Otherwise, the passed-in `Connection` is returned.
    static Connection getTargetConnection(Connection con)
    {
        auto conToUse = con;
        for (auto proxy = cast(ConnectionProxy) conToUse; proxy !is null; proxy = cast(ConnectionProxy) conToUse)
        {
            const previous = conToUse;
            conToUse = proxy.getTargetConnection();
            if (conToUse is previous)
                break;
        }
        return conToUse;
    }

    private static int getConnectionSynchronizationOrder(DataSource dataSource)
    {
        int order = CONNECTION_SYNCHRONIZATION_ORDER;
        for (auto delegating = cast(DelegatingDataSource) dataSource; delegating !is null; delegating = cast(
                DelegatingDataSource) delegating.getTargetDataSource())
            --order;
        return order;
    }

    /// Callback for resource cleanup at the end of a non-native JDBC transaction.
    private static final class ConnectionSynchronization : TransactionSynchronization
    {
        private ConnectionHolder connectionHolder;
        private DataSource dataSource;
        private int order;
        private bool holderActive = true;

        this(ConnectionHolder connectionHolder, DataSource dataSource)
        {
            this.connectionHolder = connectionHolder;
            this.dataSource = dataSource;
            order = getConnectionSynchronizationOrder(dataSource);
        }

        override int getOrder()
        {
            return order;
        }

        override void suspend()
        {
            if (!holderActive)
                return;
            TransactionSynchronizationManager.unbindResource(cast(Object) dataSource);
            if (connectionHolder.hasConnection() && !connectionHolder.isOpen())
            {
                // Release Connection on suspend if the application doesn't keep a handle to it anymore. We will
                // fetch a fresh Connection if the application accesses the ConnectionHolder again after resume,
                // assuming that it will participate in the same transaction.
                releaseConnection(connectionHolder.getConnection(), dataSource);
                connectionHolder.setConnection(null);
            }
        }

        override void resume()
        {
            if (holderActive)
                TransactionSynchronizationManager.bindResource(cast(Object) dataSource, connectionHolder);
        }

        override void beforeCompletion()
        {
            // Release Connection early if the holder is not open anymore (that is, not used by another resource
            // that has its own cleanup via transaction synchronization).
            if (connectionHolder.isOpen())
                return;
            TransactionSynchronizationManager.unbindResource(cast(Object) dataSource);
            holderActive = false;
            if (connectionHolder.hasConnection())
                releaseConnection(connectionHolder.getConnection(), dataSource);
        }

        override void afterCompletion(int)
        {
            // If we haven't closed the Connection in beforeCompletion, close it now.
            if (holderActive)
            {
                TransactionSynchronizationManager.unbindResourceIfPossible(cast(Object) dataSource);
                holderActive = false;
                if (connectionHolder.hasConnection())
                {
                    releaseConnection(connectionHolder.getConnection(), dataSource);
                    // Reset the ConnectionHolder: It might remain bound to the fiber.
                    connectionHolder.setConnection(null);
                }
            }
            connectionHolder.reset();
        }
    }
}

/// Java's `getCause()`, for SQL exceptions as well as Flint's runtime exceptions.
private Throwable javaCause(Throwable t)
{
    if (auto sql = cast(SQLException) t)
        return sql.getCause();
    return causeOf(t);
}

/// Java's `getClass().getSimpleName()`.
private string simpleName(Throwable t)
{
    const name = typeid(t).name;
    foreach_reverse (index, ch; name)
        if (ch == '.')
            return name[index + 1 .. $];
    return name;
}

private string describe(Connection con)
{
    return objectToString(cast(Object) con);
}

private bool contains(string text, string needle) pure nothrow @nogc
{
    if (needle.length > text.length)
        return false;
    foreach (start; 0 .. text.length - needle.length + 1)
        if (text[start .. start + needle.length] == needle)
            return true;
    return false;
}

// ---------------------------------------------------------------------------------------------------------------
// DataSourceTransactionManager

/++
`PlatformTransactionManager` implementation for a single JDBC `DataSource`. It binds a JDBC `Connection` from the
specified `DataSource` to the current fiber, potentially allowing for one fiber-bound `Connection` per `DataSource`.

Application code is required to retrieve the JDBC `Connection` via `DataSourceUtils.getConnection(DataSource)`
instead of `DataSource.getConnection()`. `JdbcTemplate` does this implicitly. Supports custom isolation levels and
timeouts that get applied as appropriate JDBC statement timeouts, and nested transactions through JDBC savepoints.
+/
class DataSourceTransactionManager : AbstractPlatformTransactionManager, ResourceTransactionManager, InitializingBean
{
    private DataSource dataSource;
    private bool enforceReadOnly;
    // Java's volatile Boolean: -1 unknown, 0 false, 1 true.
    private shared byte defaultReadOnly = -1;

    /// Create a new `DataSourceTransactionManager` instance. A `DataSource` has to be set to be able to use it.
    this()
    {
        setNestedTransactionAllowed(true);
    }

    /// Create a new `DataSourceTransactionManager` instance for the given `DataSource`.
    this(DataSource dataSource)
    {
        this();
        // Java's setDataSource and afterPropertiesSet, without virtual calls in a constructor.
        this.dataSource = dataSource;
        if (dataSource is null)
            throw new IllegalArgumentException("Property 'dataSource' is required");
    }

    /// Set the JDBC `DataSource` that this instance should manage transactions for.
    void setDataSource(DataSource dataSource)
    {
        this.dataSource = dataSource;
    }

    /// Return the JDBC `DataSource` that this instance manages transactions for.
    DataSource getDataSource()
    {
        return dataSource;
    }

    /// Obtain the `DataSource` for actual use; throws `IllegalStateException` when none is set.
    protected DataSource obtainDataSource()
    {
        auto source = getDataSource();
        if (source is null)
            throw new IllegalStateException("No DataSource set");
        return source;
    }

    /// Specify whether to enforce the read-only nature of a transaction (as indicated by
    /// `TransactionDefinition.isReadOnly()`) through an explicit statement on the transactional connection:
    /// "SET TRANSACTION READ ONLY" as understood by Oracle, MySQL and Postgres.
    void setEnforceReadOnly(bool enforceReadOnly)
    {
        this.enforceReadOnly = enforceReadOnly;
    }

    /// Return whether to enforce the read-only nature of a transaction through an explicit statement on the
    /// transactional connection.
    bool isEnforceReadOnly()
    {
        return enforceReadOnly;
    }

    override void afterPropertiesSet()
    {
        if (getDataSource() is null)
            throw new IllegalArgumentException("Property 'dataSource' is required");
    }

    override Object getResourceFactory()
    {
        return cast(Object) obtainDataSource();
    }

    protected override Object doGetTransaction()
    {
        auto txObject = new DataSourceTransactionObject;
        txObject.setSavepointAllowed(isNestedTransactionAllowed());
        auto conHolder = cast(ConnectionHolder) TransactionSynchronizationManager.getResource(
                cast(Object) obtainDataSource());
        txObject.setConnectionHolder(conHolder, false);
        return txObject;
    }

    protected override bool isExistingTransaction(Object transaction)
    {
        auto txObject = cast(DataSourceTransactionObject) transaction;
        return txObject.hasConnectionHolder() && txObject.getConnectionHolder().isTransactionActive();
    }

    protected override void doBegin(Object transaction, TransactionDefinition definition)
    {
        auto txObject = cast(DataSourceTransactionObject) transaction;
        Connection con;
        try
        {
            if (!txObject.hasConnectionHolder() || txObject.getConnectionHolder().isSynchronizedWithTransaction())
            {
                auto newCon = obtainDataSource().getConnection();
                if (logger.isDebugEnabled())
                    logger.debug_("Acquired Connection [" ~ describe(newCon) ~ "] for JDBC transaction");
                if (definition.isReadOnly())
                    checkDefaultReadOnly(newCon);
                txObject.setConnectionHolder(new ConnectionHolder(newCon), true);
            }
            txObject.getConnectionHolder().setSynchronizedWithTransaction(true);
            con = txObject.getConnectionHolder().getConnection();
            beginOn(txObject, con, definition);
        }
        catch (Exception ex)
        {
            if (txObject.isNewConnectionHolder())
            {
                DataSourceUtils.releaseConnection(con, obtainDataSource());
                txObject.setConnectionHolder(null, false);
            }
            throw new CannotCreateTransactionException("Could not open JDBC Connection for transaction", ex);
        }
    }

    /// The part of `doBegin` that prepares the connection and binds the holder.
    private void beginOn(DataSourceTransactionObject txObject, Connection con, TransactionDefinition definition)
    {
        const previousIsolationLevel = DataSourceUtils.prepareConnectionForTransaction(con,
                definition.getIsolationLevel(), definition.isReadOnly() && !isDefaultReadOnly());
        txObject.setPreviousIsolationLevel(previousIsolationLevel);
        txObject.setReadOnly(definition.isReadOnly());
        // Switch to manual commit if necessary. This is very expensive in some JDBC drivers, so we don't want to do
        // it unnecessarily (for example if we've explicitly configured the connection pool to set it already).
        if (con.getAutoCommit())
        {
            txObject.setMustRestoreAutoCommit(true);
            if (logger.isDebugEnabled())
                logger.debug_("Switching JDBC Connection [" ~ describe(con) ~ "] to manual commit");
            con.setAutoCommit(false);
        }
        prepareTransactionalConnection(con, definition);
        txObject.getConnectionHolder().setTransactionActive(true);
        const timeout = determineTimeout(definition);
        if (timeout != TransactionDefinition.TIMEOUT_DEFAULT)
            txObject.getConnectionHolder().setTimeoutInSeconds(timeout);
        // Bind the connection holder to the fiber.
        if (txObject.isNewConnectionHolder())
            TransactionSynchronizationManager.bindResource(cast(Object) obtainDataSource(),
                    txObject.getConnectionHolder());
    }

    protected override Object doSuspend(Object transaction)
    {
        auto txObject = cast(DataSourceTransactionObject) transaction;
        txObject.setConnectionHolder(null);
        return TransactionSynchronizationManager.unbindResource(cast(Object) obtainDataSource());
    }

    protected override void doResume(Object, Object suspendedResources)
    {
        TransactionSynchronizationManager.bindResource(cast(Object) obtainDataSource(), suspendedResources);
    }

    protected override void doCommit(DefaultTransactionStatus status)
    {
        auto txObject = cast(DataSourceTransactionObject) status.getTransaction();
        auto con = txObject.getConnectionHolder().getConnection();
        if (status.isDebug())
            logger.debug_("Committing JDBC transaction on Connection [" ~ describe(con) ~ "]");
        try
            con.commit();
        catch (SQLException ex)
            throw translateException("JDBC commit", ex);
    }

    protected override void doRollback(DefaultTransactionStatus status)
    {
        auto txObject = cast(DataSourceTransactionObject) status.getTransaction();
        auto con = txObject.getConnectionHolder().getConnection();
        if (status.isDebug())
            logger.debug_("Rolling back JDBC transaction on Connection [" ~ describe(con) ~ "]");
        try
            con.rollback();
        catch (SQLException ex)
            throw translateException("JDBC rollback", ex);
    }

    protected override void doSetRollbackOnly(DefaultTransactionStatus status)
    {
        auto txObject = cast(DataSourceTransactionObject) status.getTransaction();
        if (status.isDebug())
            logger.debug_("Setting JDBC transaction [" ~ describe(txObject.getConnectionHolder()
                    .getConnection()) ~ "] rollback-only");
        txObject.setRollbackOnly();
    }

    protected override void doCleanupAfterCompletion(Object transaction)
    {
        auto txObject = cast(DataSourceTransactionObject) transaction;
        // Remove the connection holder from the fiber, if exposed.
        if (txObject.isNewConnectionHolder())
            TransactionSynchronizationManager.unbindResource(cast(Object) obtainDataSource());
        // Reset connection.
        auto con = txObject.getConnectionHolder().getConnection();
        try
        {
            if (txObject.isMustRestoreAutoCommit())
                con.setAutoCommit(true);
            DataSourceUtils.resetConnectionAfterTransaction(con,
                    txObject.getPreviousIsolationLevel(), txObject.isReadOnly() && !isDefaultReadOnly());
        }
        catch (Exception ex)
            logger.debug_("Could not reset JDBC Connection after transaction", ex);
        if (txObject.isNewConnectionHolder())
        {
            if (logger.isDebugEnabled())
                logger.debug_("Releasing JDBC Connection [" ~ describe(con) ~ "] after transaction");
            DataSourceUtils.releaseConnection(con, dataSource);
        }
        txObject.getConnectionHolder().clear();
    }

    private void checkDefaultReadOnly(Connection newCon)
    {
        if (atomicLoad(defaultReadOnly) >= 0)
            return;
        try
            atomicStore(defaultReadOnly, cast(byte)(newCon.isReadOnly() ? 1 : 0));
        catch (Exception ex)
        {
            logger.debug_("Could not determine default JDBC Connection isReadOnly - assuming false", ex);
            atomicStore(defaultReadOnly, cast(byte) 0);
        }
    }

    private bool isDefaultReadOnly()
    {
        return atomicLoad(defaultReadOnly) == 1;
    }

    /// Prepare the transactional `Connection` right after transaction begin. The default implementation executes a
    /// "SET TRANSACTION READ ONLY" statement if the `enforceReadOnly` flag is set to true and the transaction
    /// definition indicates a read-only transaction.
    protected void prepareTransactionalConnection(Connection con, TransactionDefinition definition)
    {
        if (isEnforceReadOnly() && definition.isReadOnly())
        {
            auto stmt = con.createStatement();
            scope (exit)
                stmt.close();
            stmt.executeUpdate("SET TRANSACTION READ ONLY");
        }
    }

    /// Translate the given JDBC commit/rollback exception to a common Spring exception to propagate from the
    /// `commit`/`rollback` call. The default implementation throws a `TransactionSystemException`.
    protected RuntimeException translateException(string task, SQLException ex)
    {
        return new TransactionSystemException(task ~ " failed", ex);
    }

    /// DataSource transaction object, representing a `ConnectionHolder`. Used as transaction object by
    /// `DataSourceTransactionManager`.
    private static final class DataSourceTransactionObject : JdbcTransactionObjectSupport
    {
        private bool newConnectionHolder;
        private bool mustRestoreAutoCommit;

        alias setConnectionHolder = JdbcTransactionObjectSupport.setConnectionHolder;

        void setConnectionHolder(ConnectionHolder connectionHolder, bool newConnectionHolder)
        {
            super.setConnectionHolder(connectionHolder);
            this.newConnectionHolder = newConnectionHolder;
        }

        bool isNewConnectionHolder()
        {
            return newConnectionHolder;
        }

        void setMustRestoreAutoCommit(bool mustRestoreAutoCommit)
        {
            this.mustRestoreAutoCommit = mustRestoreAutoCommit;
        }

        bool isMustRestoreAutoCommit()
        {
            return mustRestoreAutoCommit;
        }

        void setRollbackOnly()
        {
            getConnectionHolder().setRollbackOnly();
        }

        override bool isRollbackOnly()
        {
            return getConnectionHolder().isRollbackOnly();
        }

        override void flush()
        {
            TransactionSynchronizationUtils.triggerFlush();
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// DataSource implementations

/// Abstract base class for Spring's `DataSource` implementations, taking care of the padding.
abstract class AbstractDataSource : DataSource
{
    /// Logger available to subclasses.
    protected Logger logger;

    ///
    this()
    {
        logger = LoggerFactory.getLogger(typeid(this).name);
    }

    /// Returns 0, indicating the default system timeout is to be used.
    override int getLoginTimeout()
    {
        return 0;
    }

    /// Setting a login timeout is not supported.
    override void setLoginTimeout(int)
    {
        throw new UnsupportedOperationException("setLoginTimeout");
    }

    override Object unwrap(const TypeInfo_Class iface)
    {
        if (isWrapperFor(iface))
            return this;
        throw new SQLException("DataSource of type [" ~ typeid(this).name
                ~ "] cannot be unwrapped as [" ~ iface.name ~ "]");
    }

    override bool isWrapperFor(const TypeInfo_Class iface)
    {
        return isInstance(iface, this);
    }
}

/// Java's `Class.isInstance`.
private bool isInstance(const TypeInfo_Class iface, Object object)
{
    for (auto type = typeid(object); type !is null; type = type.base)
    {
        if (type is iface)
            return true;
        foreach (implemented; type.interfaces)
            if (implemented.classinfo is iface || implementsInterface(implemented.classinfo, iface))
                return true;
    }
    return false;
}

private bool implementsInterface(const TypeInfo_Class type, const TypeInfo_Class iface)
{
    foreach (implemented; type.interfaces)
        if (implemented.classinfo is iface || implementsInterface(implemented.classinfo, iface))
            return true;
    return false;
}

/++
Abstract base class for JDBC `DataSource` implementations that operate on a JDBC `Driver`. Allows for specifying a
default user and password, and for passing connection properties to the driver.
+/
abstract class AbstractDriverBasedDataSource : AbstractDataSource
{
    private string url;
    private string username;
    private string password;
    private string catalog;
    private string schema;
    private string[string] connectionProperties;

    /// Set the JDBC URL to use for connecting through the `Driver`.
    void setUrl(string url)
    {
        this.url = url !is null ? trim(url) : null;
    }

    /// Return the JDBC URL to use for connecting through the `Driver`.
    string getUrl()
    {
        return url;
    }

    /// Set the JDBC username to use for connecting through the `Driver`.
    void setUsername(string username)
    {
        this.username = username;
    }

    /// Return the JDBC username to use for connecting through the `Driver`.
    string getUsername()
    {
        return username;
    }

    /// Set the JDBC password to use for connecting through the `Driver`.
    void setPassword(string password)
    {
        this.password = password;
    }

    /// Return the JDBC password to use for connecting through the `Driver`.
    string getPassword()
    {
        return password;
    }

    /// Specify a database catalog to be applied to each `Connection`.
    void setCatalog(string catalog)
    {
        this.catalog = catalog;
    }

    /// Return the database catalog to be applied to each `Connection`, if any.
    string getCatalog()
    {
        return catalog;
    }

    /// Specify a database schema to be applied to each `Connection`.
    void setSchema(string schema)
    {
        this.schema = schema;
    }

    /// Return the database schema to be applied to each `Connection`, if any.
    string getSchema()
    {
        return schema;
    }

    /// Specify arbitrary connection properties as key/value pairs, to be passed to the `Driver`. Can also contain
    /// "user" and "password" properties; explicit `username` and `password` override those.
    void setConnectionProperties(string[string] connectionProperties)
    {
        this.connectionProperties = connectionProperties;
    }

    /// Return the connection properties to be passed to the `Driver`, if any.
    string[string] getConnectionProperties()
    {
        return connectionProperties;
    }

    /// This implementation delegates to `getConnectionFromDriver`, using the default username and password of this
    /// `DataSource`.
    override Connection getConnection()
    {
        return getConnectionFromDriver(getUsername(), getPassword());
    }

    /// This implementation delegates to `getConnectionFromDriver`, using the given username and password.
    override Connection getConnection(string username, string password)
    {
        return getConnectionFromDriver(username, password);
    }

    /// Build properties for the `Driver`, including the given username and password (if any), and obtain a
    /// corresponding `Connection`.
    protected Connection getConnectionFromDriver(string username, string password)
    {
        string[string] mergedProps;
        foreach (key, value; getConnectionProperties())
            mergedProps[key] = value;
        if (username !is null)
            mergedProps["user"] = username;
        if (password !is null)
            mergedProps["password"] = password;
        auto con = getConnectionFromDriver(mergedProps);
        if (catalog !is null)
            con.setCatalog(catalog);
        if (schema !is null)
            con.setSchema(schema);
        return con;
    }

    /// Obtain a `Connection` using the given properties.
    protected abstract Connection getConnectionFromDriver(string[string] props);
}

/++
Simple implementation of the standard JDBC `DataSource` interface, configuring a plain old JDBC `DriverManager` via
bean properties, and returning a new `Connection` from every `getConnection` call. This class is not an actual
connection pool; it does not actually pool `Connection`s. Use `FlintDataSource` (flint.engine.jdbc) for a pool.
+/
class DriverManagerDataSource : AbstractDriverBasedDataSource
{
    /// Constructor for bean-style configuration.
    this()
    {
    }

    /// Create a new `DriverManagerDataSource` with the given JDBC URL, not specifying a username or password for
    /// JDBC access.
    this(string url)
    {
        this.url = url !is null ? trim(url) : null;
    }

    /// Create a new `DriverManagerDataSource` with the given standard `DriverManager` parameters.
    this(string url, string username, string password)
    {
        this.url = url !is null ? trim(url) : null;
        this.username = username;
        this.password = password;
    }

    /// Create a new `DriverManagerDataSource` with the given JDBC URL and connection properties.
    this(string url, string[string] conProps)
    {
        this.url = url !is null ? trim(url) : null;
        connectionProperties = conProps;
    }

    /++
    Set the JDBC driver class name. Flint drivers register with `DriverManager` when their module loads, so nothing is
    loaded here: the name must be the D class name of a registered driver, or the Java driver class of a URL scheme
    that the Flint driver serves (`org.postgresql.Driver`, `org.sqlite.JDBC`), as Boot configurations name them.
    Throws `IllegalStateException` for any other name, as Java's does when the class cannot be loaded.
    +/
    void setDriverClassName(string driverClassName)
    {
        if (driverClassName is null || trim(driverClassName).length == 0)
            throw new IllegalArgumentException("Property 'driverClassName' must not be empty");
        const driverClassNameToUse = trim(driverClassName);
        if (!isKnownDriver(driverClassNameToUse))
            throw new IllegalStateException("Could not load JDBC driver class [" ~ driverClassNameToUse ~ "]");
        if (logger.isDebugEnabled())
            logger.debug_("Loaded JDBC driver: " ~ driverClassNameToUse);
    }

    private static bool isKnownDriver(string name)
    {
        // The Java driver classes stand for the URL schemes they serve.
        const probe = name == "org.postgresql.Driver" ? "jdbc:postgresql://localhost/" : name == "org.sqlite.JDBC"
            ? "jdbc:sqlite::memory:" : null;
        foreach (driver; DriverManager.getDrivers())
            if (probe !is null ? driver.acceptsURL(probe) : typeid(cast(Object) driver).name == name)
                return true;
        return false;
    }

    protected override Connection getConnectionFromDriver(string[string] props)
    {
        const url = getUrl();
        if (url is null)
            throw new IllegalStateException("'url' not set");
        if (logger.isDebugEnabled())
            logger.debug_("Creating new JDBC DriverManager Connection to [" ~ url ~ "]");
        return getConnectionFromDriverManager(url, props);
    }

    /// Get a `Connection` from the `DriverManager`, using the given properties.
    protected Connection getConnectionFromDriverManager(string url, string[string] props)
    {
        return DriverManager.getConnection(url, props);
    }

    // Unhide the inherited overloads that this class's override would otherwise hide.
    alias getConnectionFromDriver = AbstractDriverBasedDataSource.getConnectionFromDriver;
}

/++
Simple implementation of the standard JDBC `DataSource` interface, configuring a plain old JDBC `Driver` via bean
properties, and returning a new `Connection` from every `getConnection` call. Not a connection pool.
+/
class SimpleDriverDataSource : AbstractDriverBasedDataSource
{
    private Driver driver;

    /// Constructor for bean-style configuration.
    this()
    {
    }

    /// Create a new `SimpleDriverDataSource` with the given standard `Driver` parameters.
    this(Driver driver, string url)
    {
        this.driver = driver;
        this.url = url !is null ? trim(url) : null;
    }

    /// Create a new `SimpleDriverDataSource` with the given standard `Driver` parameters.
    this(Driver driver, string url, string username, string password)
    {
        this.driver = driver;
        this.url = url !is null ? trim(url) : null;
        this.username = username;
        this.password = password;
    }

    /// Create a new `SimpleDriverDataSource` with the given standard `Driver` parameters.
    this(Driver driver, string url, string[string] conProps)
    {
        this.driver = driver;
        this.url = url !is null ? trim(url) : null;
        connectionProperties = conProps;
    }

    /// Specify the JDBC `Driver` implementation class to use (R4: a template parameter).
    void setDriverClass(D : Driver)()
    {
        driver = new D;
    }

    /// Specify the JDBC `Driver` instance to use.
    void setDriver(Driver driver)
    {
        this.driver = driver;
    }

    /// Return the JDBC `Driver` instance to use.
    Driver getDriver()
    {
        return driver;
    }

    protected override Connection getConnectionFromDriver(string[string] props)
    {
        auto driverToUse = getDriver();
        if (driverToUse is null)
            throw new IllegalStateException("Driver has not been set");
        const url = getUrl();
        if (logger.isDebugEnabled())
            logger.debug_("Creating new JDBC Driver Connection to [" ~ url ~ "]");
        return driverToUse.connect(url, props);
    }

    alias getConnectionFromDriver = AbstractDriverBasedDataSource.getConnectionFromDriver;
}

/// JDBC `DataSource` implementation that delegates all calls to a given target `DataSource`. Meant to be
/// subclassed, with subclasses overriding only those methods that should not simply delegate to the target.
class DelegatingDataSource : DataSource, InitializingBean
{
    private DataSource targetDataSource;

    /// Create a new `DelegatingDataSource`.
    this()
    {
    }

    /// Create a new `DelegatingDataSource` for the given target.
    this(DataSource targetDataSource)
    {
        this.targetDataSource = targetDataSource;
    }

    /// Set the target `DataSource` that this `DataSource` should delegate to.
    void setTargetDataSource(DataSource targetDataSource)
    {
        this.targetDataSource = targetDataSource;
    }

    /// Return the target `DataSource` that this `DataSource` should delegate to.
    DataSource getTargetDataSource()
    {
        return targetDataSource;
    }

    /// Obtain the target `DataSource` for actual use; throws `IllegalStateException` when none is set.
    protected DataSource obtainTargetDataSource()
    {
        auto target = getTargetDataSource();
        if (target is null)
            throw new IllegalStateException("No 'targetDataSource' set");
        return target;
    }

    override void afterPropertiesSet()
    {
        if (getTargetDataSource() is null)
            throw new IllegalArgumentException("Property 'targetDataSource' is required");
    }

    override Connection getConnection()
    {
        return obtainTargetDataSource().getConnection();
    }

    override Connection getConnection(string username, string password)
    {
        return obtainTargetDataSource().getConnection(username, password);
    }

    override int getLoginTimeout()
    {
        return obtainTargetDataSource().getLoginTimeout();
    }

    override void setLoginTimeout(int seconds)
    {
        obtainTargetDataSource().setLoginTimeout(seconds);
    }

    override Object unwrap(const TypeInfo_Class iface)
    {
        if (isInstance(iface, this))
            return this;
        return obtainTargetDataSource().unwrap(iface);
    }

    override bool isWrapperFor(const TypeInfo_Class iface)
    {
        return isInstance(iface, this) || obtainTargetDataSource().isWrapperFor(iface);
    }
}

private string trim(string text) pure nothrow @nogc
{
    static bool blank(char ch) pure nothrow @nogc
    {
        return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
    }

    size_t start, end = text.length;
    while (start < end && blank(text[start]))
        ++start;
    while (end > start && blank(text[end - 1]))
        --end;
    return text[start .. end];
}
