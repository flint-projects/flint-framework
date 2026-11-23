/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/datasource/DataSourceTransactionManagerTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: only the tests that `datasource_transaction_manager.d` (module
`flint.jdbc.datasource_transaction_manager_test`) does not already cover by name; hand-written fakes replace Mockito,
as there: a `FakeConnection` logs each call, so `verify(con).commit()` counts "commit" in its log and `InOrder`
becomes an ordered-subsequence check. `TestTransactionSynchronization.afterCompletion` records `Exception`s only, so
a failed assertion inside it fails the test directly.
+/
module flint.jdbc.datasource_transaction_manager_upstream_tests;

import core.time : msecs;
import flint.java.lang : IllegalStateException;
import flint.java.sql : Connection, DatabaseMetaData, PreparedStatement, SQLException,
    SQLWarning, Savepoint, Statement;
import flint.javax.sql : DataSource;
import flint.dao : DataAccessResourceFailureException;
import flint.jdbc : UncategorizedSQLException;
import flint.jdbc.datasource;
import flint.transaction : CannotCreateTransactionException, TransactionDefinition,
    TransactionStatus, TransactionTimedOutException, UnexpectedRollbackException;
import flint.transaction.support;
import std.typecons : BlackHole;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fakes

private final class FakeSavepoint : BlackHole!Savepoint
{
}

private final class FakeMetaData : BlackHole!DatabaseMetaData
{
    override bool supportsSavepoints()
    {
        return true;
    }
}

private final class FakeStatement : BlackHole!Statement
{
}

private final class FakePreparedStatement : BlackHole!PreparedStatement
{
    private FakeConnection connection;

    this(FakeConnection connection)
    {
        this.connection = connection;
    }

    override void setQueryTimeout(int seconds)
    {
        import std.conv : to;

        connection.log ~= "ps.setQueryTimeout(" ~ seconds.to!string ~ ")";
    }
}

/// A connection that logs every call the transaction manager makes.
private final class FakeConnection : BlackHole!Connection
{
    string[] log;
    bool autoCommit;
    bool readOnly;
    int isolation = Connection.TRANSACTION_READ_COMMITTED;
    bool failGetWarnings;
    string catalog, schema;
    FakeSavepoint savepoint;

    this()
    {
        savepoint = new FakeSavepoint;
    }

    override bool getAutoCommit()
    {
        log ~= "getAutoCommit";
        return autoCommit;
    }

    override void setAutoCommit(bool value)
    {
        log ~= value ? "setAutoCommit(true)" : "setAutoCommit(false)";
        autoCommit = value;
    }

    override void commit()
    {
        log ~= "commit";
    }

    override void rollback()
    {
        log ~= "rollback";
    }

    override void rollback(Savepoint point)
    {
        log ~= point is savepoint ? "rollback(sp)" : "rollback(?)";
    }

    override void close()
    {
        log ~= "close";
    }

    override bool isReadOnly()
    {
        log ~= "isReadOnly";
        return readOnly;
    }

    override void setReadOnly(bool value)
    {
        log ~= value ? "setReadOnly(true)" : "setReadOnly(false)";
        readOnly = value;
    }

    override int getTransactionIsolation()
    {
        log ~= "getTransactionIsolation";
        return isolation;
    }

    override void setTransactionIsolation(int level)
    {
        import std.conv : to;

        log ~= "setTransactionIsolation(" ~ level.to!string ~ ")";
        isolation = level;
    }

    override Savepoint setSavepoint(string savepointName)
    {
        log ~= "setSavepoint(" ~ savepointName ~ ")";
        return savepoint;
    }

    override void releaseSavepoint(Savepoint point)
    {
        log ~= point is savepoint ? "releaseSavepoint(sp)" : "releaseSavepoint(?)";
    }

    override DatabaseMetaData getMetaData()
    {
        return new FakeMetaData;
    }

    override Statement createStatement()
    {
        log ~= "createStatement";
        return new FakeStatement;
    }

    override PreparedStatement prepareStatement(string sql)
    {
        log ~= "prepareStatement(" ~ sql ~ ")";
        return new FakePreparedStatement(this);
    }

    override SQLWarning getWarnings()
    {
        log ~= "getWarnings";
        if (failGetWarnings)
            throw new SQLException("getWarnings");
        return null;
    }

    override void clearWarnings()
    {
        log ~= "clearWarnings";
    }

    override void setCatalog(string value)
    {
        log ~= "setCatalog(" ~ value ~ ")";
        catalog = value;
    }

    override string getCatalog()
    {
        return catalog;
    }

    override void setSchema(string value)
    {
        log ~= "setSchema(" ~ value ~ ")";
        schema = value;
    }

    override string getSchema()
    {
        return schema;
    }

    /// The number of times `call` was logged.
    size_t count(string call) const
    {
        size_t n;
        foreach (entry; log)
            if (entry == call)
                ++n;
        return n;
    }

    /// Whether `calls` appear in the log in this order, possibly with other calls between them.
    bool inOrder(scope string[] calls...) const
    {
        size_t next;
        foreach (entry; log)
            if (next < calls.length && entry == calls[next])
                ++next;
        return next == calls.length;
    }
}

/// A data source handing out its connections in turn, repeating the last; or failing with `failure`.
private final class FakeDataSource : BlackHole!DataSource
{
    FakeConnection[] connections;
    size_t handedOut;
    SQLException failure;

    this(FakeConnection[] connections...)
    {
        this.connections = connections.dup;
    }

    override Connection getConnection()
    {
        if (failure !is null)
            throw failure;
        scope (exit)
            ++handedOut;
        return handedOut < connections.length ? connections[handedOut] : connections[$ - 1];
    }
}

/// Spring's `TestTransactionSynchronization`; `onAfterCompletion` stands in for overriding `doAfterCompletion`.
private final class TestTransactionSynchronization : TransactionSynchronization
{
    private DataSource dataSource;
    private int status;
    bool beforeCommitCalled, beforeCompletionCalled, afterCommitCalled, afterCompletionCalled;
    Exception afterCompletionException;
    void delegate() @safe onAfterCompletion;

    this(DataSource dataSource, int status)
    {
        this.dataSource = dataSource;
        this.status = status;
    }

    override void beforeCommit(bool)
    {
        assert(status == TransactionSynchronization.STATUS_COMMITTED, "Should never be called");
        assert(!beforeCommitCalled);
        beforeCommitCalled = true;
    }

    override void beforeCompletion()
    {
        assert(!beforeCompletionCalled);
        beforeCompletionCalled = true;
    }

    override void afterCommit()
    {
        assert(status == TransactionSynchronization.STATUS_COMMITTED, "Should never be called");
        assert(!afterCommitCalled);
        afterCommitCalled = true;
    }

    override void afterCompletion(int completionStatus)
    {
        try
            doAfterCompletion(completionStatus);
        catch (Exception ex)
            afterCompletionException = ex;
    }

    private void doAfterCompletion(int completionStatus)
    {
        assert(!afterCompletionCalled);
        afterCompletionCalled = true;
        assert(completionStatus == status);
        assert(TransactionSynchronizationManager.hasResource(cast(Object) dataSource));
        if (onAfterCompletion !is null)
            onAfterCompletion();
    }
}

/// An empty `TransactionSynchronization`: Java's `new TransactionSynchronization() {}`.
private final class EmptySynchronization : TransactionSynchronization
{
}

private final class TestSavepointSynchronization : TransactionSynchronization
{
    bool savepointCalled, savepointRollbackCalled;

    override void savepoint(Object)
    {
        assert(!savepointCalled);
        savepointCalled = true;
    }

    override void savepointRollback(Object)
    {
        assert(!savepointRollbackCalled);
        savepointRollbackCalled = true;
    }
}

/// The per-test fixture: Spring's `@BeforeEach`.
private struct Fixture
{
    FakeConnection con;
    FakeDataSource ds;
    DataSourceTransactionManager tm;

    static Fixture create()
    {
        Fixture fixture;
        fixture.con = new FakeConnection;
        fixture.ds = new FakeDataSource(fixture.con);
        fixture.tm = new DataSourceTransactionManager(fixture.ds);
        return fixture;
    }
}

private bool hasResource(DataSource ds)
{
    return TransactionSynchronizationManager.hasResource(cast(Object) ds);
}

/// Spring's `@AfterEach verifyTransactionSynchronizationManagerState`.
private void verifyTransactionSynchronizationManagerState()
{
    assert(TransactionSynchronizationManager.getResourceMap().length == 0);
    assert(!TransactionSynchronizationManager.isSynchronizationActive());
    assert(!TransactionSynchronizationManager.isCurrentTransactionReadOnly());
    assert(!TransactionSynchronizationManager.isActualTransactionActive());
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

// ---------------------------------------------------------------------------------------------------------------
// Commit and rollback through a LazyConnectionDataSourceProxy

version (FlintLazyConnectionDataSourceProxy)
{
    // Gap: flint.jdbc.datasource has no LazyConnectionDataSourceProxy.
    private void assertTransactionCommitRestoringAutoCommit(bool autoCommit, bool lazyConn, bool createStatement)
    {
        auto f = Fixture.create();
        f.con.autoCommit = autoCommit;
        if (lazyConn)
            f.con.failGetWarnings = true;
        DataSource dsToUse = lazyConn ? new LazyConnectionDataSourceProxy(f.ds) : f.ds;
        f.tm = new DataSourceTransactionManager(dsToUse);
        auto tt = new TransactionTemplate(f.tm);
        assert(!hasResource(dsToUse));
        assert(!TransactionSynchronizationManager.isSynchronizationActive());

        tt.executeWithoutResult((TransactionStatus status) {
            assert(hasResource(dsToUse));
            assert(TransactionSynchronizationManager.isSynchronizationActive());
            assert(status.isNewTransaction());
            assert(!TransactionSynchronizationManager.isCurrentTransactionReadOnly());
            assert(TransactionSynchronizationManager.isActualTransactionActive());
            auto tCon = DataSourceUtils.getConnection(dsToUse);
            try
            {
                if (createStatement)
                    tCon.createStatement();
                else
                {
                    tCon.getWarnings();
                    tCon.clearWarnings();
                }
            }
            catch (SQLException ex)
                throw new UncategorizedSQLException("", "", ex);
        });

        assert(!hasResource(dsToUse));
        assert(!TransactionSynchronizationManager.isSynchronizationActive());
        if (autoCommit && (!lazyConn || createStatement))
            assert(f.con.inOrder("setAutoCommit(false)", "commit", "setAutoCommit(true)"));
        assert(f.con.count("close") == (createStatement ? 2 : 1));
        verifyTransactionSynchronizationManagerState();
    }

    @("DataSourceTransactionManagerTests.transactionCommitWithAutoCommitTrueAndLazyConnection")
    unittest
    {
        assertTransactionCommitRestoringAutoCommit(true, true, false);
    }

    @("DataSourceTransactionManagerTests.transactionCommitWithAutoCommitFalseAndLazyConnection")
    unittest
    {
        assertTransactionCommitRestoringAutoCommit(false, true, false);
    }

    @("DataSourceTransactionManagerTests.transactionCommitWithAutoCommitTrueAndLazyConnectionAndStatementCreated")
    unittest
    {
        assertTransactionCommitRestoringAutoCommit(true, true, true);
    }

    @("DataSourceTransactionManagerTests.transactionCommitWithAutoCommitFalseAndLazyConnectionAndStatementCreated")
    unittest
    {
        assertTransactionCommitRestoringAutoCommit(false, true, true);
    }

    private void assertTransactionRollbackRestoringAutoCommit(bool autoCommit, bool lazyConn, bool createStatement)
    {
        import flint.java.lang : RuntimeException;

        auto f = Fixture.create();
        f.con.autoCommit = autoCommit;
        DataSource dsToUse = lazyConn ? new LazyConnectionDataSourceProxy(f.ds) : f.ds;
        f.tm = new DataSourceTransactionManager(dsToUse);
        auto tt = new TransactionTemplate(f.tm);
        assert(!hasResource(dsToUse));
        assert(!TransactionSynchronizationManager.isSynchronizationActive());

        auto ex = new RuntimeException("Application exception");
        const thrown = expectThrows!RuntimeException({
            tt.executeWithoutResult((TransactionStatus status) {
                assert(hasResource(dsToUse));
                assert(TransactionSynchronizationManager.isSynchronizationActive());
                assert(status.isNewTransaction());
                auto con = DataSourceUtils.getConnection(dsToUse);
                if (createStatement)
                {
                    try
                        con.createStatement();
                    catch (SQLException sqlException)
                        throw new UncategorizedSQLException("", "", sqlException);
                }
                throw ex;
            });
        });
        assert(thrown is ex);

        assert(!hasResource(f.ds));
        assert(!TransactionSynchronizationManager.isSynchronizationActive());
        if (autoCommit && (!lazyConn || createStatement))
            assert(f.con.inOrder("setAutoCommit(false)", "rollback", "setAutoCommit(true)"));
        assert(f.con.count("close") == (createStatement ? 2 : 1));
        verifyTransactionSynchronizationManagerState();
    }

    @("DataSourceTransactionManagerTests.transactionRollbackWithAutoCommitTrueAndLazyConnection")
    unittest
    {
        assertTransactionRollbackRestoringAutoCommit(true, true, false);
    }

    @("DataSourceTransactionManagerTests.transactionRollbackWithAutoCommitFalseAndLazyConnection")
    unittest
    {
        assertTransactionRollbackRestoringAutoCommit(false, true, false);
    }

    @("DataSourceTransactionManagerTests.transactionRollbackWithAutoCommitTrueAndLazyConnectionAndCreateStatement")
    unittest
    {
        assertTransactionRollbackRestoringAutoCommit(true, true, true);
    }

    @("DataSourceTransactionManagerTests.transactionRollbackWithAutoCommitFalseAndLazyConnectionAndCreateStatement")
    unittest
    {
        assertTransactionRollbackRestoringAutoCommit(false, true, true);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Participating transactions and synchronizations

@("DataSourceTransactionManagerTests.participatingTransactionWithTransactionStartedFromSynch")
unittest
{
    auto f = Fixture.create();
    assert(!hasResource(f.ds));
    assert(!TransactionSynchronizationManager.isSynchronizationActive());

    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);

    auto synch = new TestTransactionSynchronization(f.ds, TransactionSynchronization.STATUS_COMMITTED);
    synch.onAfterCompletion = () {
        tt.executeWithoutResult((TransactionStatus) {});
        TransactionSynchronizationManager.registerSynchronization(new EmptySynchronization);
    };

    tt.executeWithoutResult((TransactionStatus) {
        TransactionSynchronizationManager.registerSynchronization(synch);
    });

    assert(!hasResource(f.ds));
    assert(synch.beforeCommitCalled);
    assert(synch.beforeCompletionCalled);
    assert(synch.afterCommitCalled);
    assert(synch.afterCompletionCalled);
    assert(cast(IllegalStateException) synch.afterCompletionException !is null);
    assert(f.con.count("commit") == 2);
    assert(f.con.count("close") == 2);
    verifyTransactionSynchronizationManagerState();
}

@("DataSourceTransactionManagerTests.participatingTransactionWithDifferentConnectionObtainedFromSynch")
unittest
{
    auto f = Fixture.create();
    auto con2 = new FakeConnection;
    auto ds2 = new FakeDataSource(con2);

    assert(!hasResource(f.ds));
    assert(!TransactionSynchronizationManager.isSynchronizationActive());

    auto tt = new TransactionTemplate(f.tm);

    auto synch = new TestTransactionSynchronization(f.ds, TransactionSynchronization.STATUS_COMMITTED);
    synch.onAfterCompletion = () {
        auto con = DataSourceUtils.getConnection(ds2);
        DataSourceUtils.releaseConnection(con, ds2);
    };

    tt.executeWithoutResult((TransactionStatus) {
        TransactionSynchronizationManager.registerSynchronization(synch);
    });

    assert(!hasResource(f.ds));
    assert(synch.beforeCommitCalled);
    assert(synch.beforeCompletionCalled);
    assert(synch.afterCommitCalled);
    assert(synch.afterCompletionCalled);
    assert(synch.afterCompletionException is null);
    assert(f.con.count("commit") == 1);
    assert(f.con.count("close") == 1);
    assert(con2.count("close") == 1);
    verifyTransactionSynchronizationManagerState();
}

@("DataSourceTransactionManagerTests.participatingTransactionWithRollbackOnlyAndInnerSynch")
unittest
{
    auto f = Fixture.create();
    f.tm.setTransactionSynchronization(DataSourceTransactionManager.SYNCHRONIZATION_NEVER);
    auto tm2 = new DataSourceTransactionManager(f.ds);
    // tm has no synch enabled (used at outer level), tm2 has synch enabled (inner level)

    assert(!hasResource(f.ds));
    assert(!TransactionSynchronizationManager.isSynchronizationActive());

    auto ts = f.tm.getTransaction(new DefaultTransactionDefinition);
    auto synch = new TestTransactionSynchronization(f.ds, TransactionSynchronization.STATUS_UNKNOWN);

    expectThrows!UnexpectedRollbackException({
        assert(ts.isNewTransaction());
        auto tt = new TransactionTemplate(tm2);
        tt.executeWithoutResult((TransactionStatus status) {
            assert(!status.isNewTransaction());
            assert(!status.isRollbackOnly());
            tt.executeWithoutResult((TransactionStatus status2) {
                assert(hasResource(f.ds));
                assert(TransactionSynchronizationManager.isSynchronizationActive());
                assert(!status2.isNewTransaction());
                status2.setRollbackOnly();
            });
            assert(!status.isNewTransaction());
            assert(status.isRollbackOnly());
            TransactionSynchronizationManager.registerSynchronization(synch);
        });

        f.tm.commit(ts);
    });

    assert(!hasResource(f.ds));
    assert(!synch.beforeCommitCalled);
    assert(synch.beforeCompletionCalled);
    assert(!synch.afterCommitCalled);
    assert(synch.afterCompletionCalled);
    assert(f.con.count("rollback") == 1);
    assert(f.con.count("close") == 1);
    verifyTransactionSynchronizationManagerState();
}

@("DataSourceTransactionManagerTests.propagationRequiresNewWithExistingTransactionAndUnrelatedFailingDataSource")
unittest
{
    auto f = Fixture.create();
    auto ds2 = new FakeDataSource(new FakeConnection);
    auto failure = new SQLException();
    ds2.failure = failure;

    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);

    auto tm2 = new DataSourceTransactionManager(ds2);
    tm2.setTransactionSynchronization(DataSourceTransactionManager.SYNCHRONIZATION_NEVER);
    auto tt2 = new TransactionTemplate(tm2);
    tt2.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);

    assert(!hasResource(f.ds));
    assert(!hasResource(ds2));
    assert(!TransactionSynchronizationManager.isSynchronizationActive());

    auto thrown = expectThrows!CannotCreateTransactionException({
        tt.executeWithoutResult((TransactionStatus status) {
            assert(TransactionSynchronizationManager.isSynchronizationActive());
            assert(status.hasTransaction());
            assert(status.isNewTransaction());
            assert(!status.isNested());
            assert(!status.isReadOnly());
            assert(!TransactionSynchronizationManager.isCurrentTransactionReadOnly());
            assert(TransactionSynchronizationManager.isActualTransactionActive());
            tt2.executeWithoutResult((TransactionStatus status2) { status2.setRollbackOnly(); });
        });
    });
    assert(thrown.getCause() is failure);

    assert(!hasResource(f.ds));
    assert(!hasResource(ds2));
    assert(f.con.count("rollback") == 1);
    assert(f.con.count("close") == 1);
    verifyTransactionSynchronizationManagerState();
}

// ---------------------------------------------------------------------------------------------------------------
// LazyConnectionDataSourceProxy and read-only data sources

version (FlintLazyConnectionDataSourceProxy)
{
    // Gap: flint.jdbc.datasource has no LazyConnectionDataSourceProxy (and flint.java.sql.Connection has no
    // setHoldability/getHoldability).
    private void assertTransactionReadOnly(ref Fixture f, int isolationLevel, bool withStatement)
    {
        auto tt = new TransactionTemplate(f.tm);
        tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        tt.setIsolationLevel(isolationLevel);
        tt.setReadOnly(true);
        tt.setName("my-transaction");

        assert(!hasResource(f.ds));

        auto tm = f.tm;
        tt.executeWithoutResult((TransactionStatus status) {
            // something transactional
            assert(status.getTransactionName() == "my-transaction");
            assert(status.hasTransaction());
            assert(status.isNewTransaction());
            assert(!status.isNested());
            assert(!status.hasSavepoint());
            assert(status.isReadOnly());
            assert(TransactionSynchronizationManager.isCurrentTransactionReadOnly());
            assert(TransactionSynchronizationManager.isActualTransactionActive());
            assert(!status.isRollbackOnly());
            assert(!status.isCompleted());
            if (withStatement)
            {
                try
                    DataSourceUtils.getConnection(tm.getDataSource()).createStatement();
                catch (SQLException ex)
                    throw new IllegalStateException(ex.msg, ex);
            }
        });

        assert(!hasResource(f.ds));
    }

    private final class CatalogSettingDataSource : DelegatingDataSource
    {
        this(DataSource target)
        {
            super(target);
        }

        override Connection getConnection()
        {
            import flint.java.sql : ResultSet;

            auto con = super.getConnection();
            con.setCatalog("myCatalog");
            con.setSchema("mySchema");
            con.setHoldability(ResultSet.HOLD_CURSORS_OVER_COMMIT);
            return con;
        }
    }

    @("DataSourceTransactionManagerTests.transactionWithLazyConnectionDataSourceAndStatement")
    unittest
    {
        import flint.java.sql : ResultSet;

        auto f = Fixture.create();
        auto dsProxy = new LazyConnectionDataSourceProxy;
        dsProxy.setTargetDataSource(f.ds);
        dsProxy.setDefaultAutoCommit(true);
        dsProxy.setDefaultTransactionIsolation(Connection.TRANSACTION_READ_COMMITTED);
        dsProxy.afterPropertiesSet();

        auto dsAdapter = new CatalogSettingDataSource(dsProxy);
        f.tm = new DataSourceTransactionManager(dsAdapter);

        {
            auto con = dsAdapter.getConnection();
            scope (exit)
                con.close();
            assert(!con.isReadOnly());
            assert(con.getCatalog() == "myCatalog");
            assert(con.getSchema() == "mySchema");
            assert(con.getHoldability() == ResultSet.HOLD_CURSORS_OVER_COMMIT);
        }
        assertTransactionReadOnly(f, TransactionDefinition.ISOLATION_SERIALIZABLE, true);

        assert(f.con.log == [
            "setCatalog(myCatalog)", "setSchema(mySchema)", "setHoldability(1)",
            "setReadOnly(true)", "setTransactionIsolation(8)", "setAutoCommit(false)",
            "createStatement", "commit", "setAutoCommit(true)", "setTransactionIsolation(2)",
            "setReadOnly(false)", "close"
        ], "verifyNoMoreInteractions");
        verifyTransactionSynchronizationManagerState();
    }

    @("DataSourceTransactionManagerTests.transactionWithLazyConnectionDataSourceNoStatement")
    unittest
    {
        auto f = Fixture.create();
        auto dsProxy = new LazyConnectionDataSourceProxy;
        dsProxy.setTargetDataSource(f.ds);
        dsProxy.setDefaultAutoCommit(true);
        dsProxy.setDefaultTransactionIsolation(Connection.TRANSACTION_READ_COMMITTED);
        dsProxy.afterPropertiesSet();
        f.tm = new DataSourceTransactionManager(dsProxy);

        {
            auto con = dsProxy.getConnection();
            scope (exit)
                con.close();
            assert(!con.isReadOnly());
        }
        assertTransactionReadOnly(f, TransactionDefinition.ISOLATION_SERIALIZABLE, false);

        assert(f.con.log.length == 0, "verifyNoMoreInteractions");
        verifyTransactionSynchronizationManagerState();
    }

    @("DataSourceTransactionManagerTests.transactionWithReadOnlyDataSourceAndStatement")
    unittest
    {
        auto f = Fixture.create();
        auto dsProxy = new LazyConnectionDataSourceProxy;
        dsProxy.setReadOnlyDataSource(f.ds);
        dsProxy.setDefaultAutoCommit(false);
        dsProxy.setDefaultTransactionIsolation(Connection.TRANSACTION_READ_COMMITTED);
        dsProxy.afterPropertiesSet();
        f.tm = new DataSourceTransactionManager(dsProxy);

        {
            auto con = dsProxy.getConnection();
            scope (exit)
                con.close();
            assert(con.isReadOnly());
        }
        assertTransactionReadOnly(f, TransactionDefinition.ISOLATION_SERIALIZABLE, true);

        assert(f.con.log == [
            "setTransactionIsolation(8)", "createStatement", "commit", "setTransactionIsolation(2)",
            "close"
        ], "verifyNoMoreInteractions");
        verifyTransactionSynchronizationManagerState();
    }

    @("DataSourceTransactionManagerTests.transactionWithReadOnlyDataSourceNoStatement")
    unittest
    {
        auto f = Fixture.create();
        auto dsProxy = new LazyConnectionDataSourceProxy;
        dsProxy.setReadOnlyDataSource(f.ds);
        dsProxy.setDefaultAutoCommit(false);
        dsProxy.setDefaultTransactionIsolation(Connection.TRANSACTION_READ_COMMITTED);
        dsProxy.afterPropertiesSet();
        f.tm = new DataSourceTransactionManager(dsProxy);

        {
            auto con = dsProxy.getConnection();
            scope (exit)
                con.close();
            assert(con.isReadOnly());
        }
        assertTransactionReadOnly(f, TransactionDefinition.ISOLATION_SERIALIZABLE, false);

        assert(f.con.log.length == 0, "verifyNoMoreInteractions");
        verifyTransactionSynchronizationManagerState();
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Timeouts

@("DataSourceTransactionManagerTests.transactionWithTimeout")
unittest
{
    import core.thread : Thread;

    foreach (timeout; [1, 10])
    {
        import std.conv : to;

        auto f = Fixture.create();
        f.con.autoCommit = true;

        auto tt = new TransactionTemplate(f.tm);
        tt.setTimeout(timeout);
        assert(!hasResource(f.ds));

        try
        {
            tt.executeWithoutResult((TransactionStatus) {
                Thread.sleep(1500.msecs);
                try
                {
                    auto con = DataSourceUtils.getConnection(f.ds);
                    auto ps2 = con.prepareStatement("some SQL statement");
                    DataSourceUtils.applyTransactionTimeout(ps2, f.ds);
                }
                catch (SQLException ex)
                    throw new DataAccessResourceFailureException("", ex);
            });
            assert(timeout > 1, "Should have thrown TransactionTimedOutException");
        }
        catch (TransactionTimedOutException ex)
        {
            if (timeout > 1)
                throw ex;
        }

        assert(!hasResource(f.ds));
        if (timeout > 1)
        {
            assert(f.con.count("ps.setQueryTimeout(" ~ (timeout - 1).to!string ~ ")") == 1);
            assert(f.con.count("commit") == 1);
        }
        else
            assert(f.con.count("rollback") == 1);
        assert(f.con.inOrder("setAutoCommit(false)", "setAutoCommit(true)"));
        assert(f.con.count("close") == 1);
        verifyTransactionSynchronizationManagerState();
    }
}

// ---------------------------------------------------------------------------------------------------------------
// TransactionAwareDataSourceProxy

version (FlintTransactionAwareDataSourceProxy)
{
    // Gap: flint.jdbc.datasource has no TransactionAwareDataSourceProxy.
    @("DataSourceTransactionManagerTests.transactionAwareDataSourceProxy")
    unittest
    {
        auto f = Fixture.create();
        f.con.autoCommit = true;
        f.con.failGetWarnings = true;

        auto tt = new TransactionTemplate(f.tm);
        assert(!hasResource(f.ds));
        tt.executeWithoutResult((TransactionStatus) {
            // something transactional
            assert(DataSourceUtils.getConnection(f.ds) is f.con);
            auto dsProxy = new TransactionAwareDataSourceProxy(f.ds);
            try
            {
                auto tCon = dsProxy.getConnection();
                tCon.getWarnings();
                tCon.clearWarnings();
                assert((cast(ConnectionProxy) tCon).getTargetConnection() is f.con);
                // should be ignored
                tCon.close();
            }
            catch (SQLException ex)
                throw new UncategorizedSQLException("", "", ex);
        });

        assert(!hasResource(f.ds));
        assert(f.con.inOrder("setAutoCommit(false)", "commit", "setAutoCommit(true)"));
        assert(f.con.count("close") == 1);
        verifyTransactionSynchronizationManagerState();
    }

    @("DataSourceTransactionManagerTests.transactionAwareDataSourceProxyWithLazyFalse")
    unittest
    {
        auto f = Fixture.create();
        f.con.autoCommit = true;
        f.con.failGetWarnings = true;

        auto tt = new TransactionTemplate(f.tm);
        assert(!hasResource(f.ds));
        tt.executeWithoutResult((TransactionStatus) {
            // something transactional
            assert(DataSourceUtils.getConnection(f.ds) is f.con);
            auto dsProxy = new TransactionAwareDataSourceProxy(f.ds);
            dsProxy.setLazyTransactionalConnections(false);
            try
            {
                auto tCon = dsProxy.getConnection();
                expectThrows!SQLException({ tCon.getWarnings(); });
                tCon.clearWarnings();
                assert((cast(ConnectionProxy) tCon).getTargetConnection() is f.con);
                // should be ignored
                tCon.close();
            }
            catch (SQLException ex)
                throw new UncategorizedSQLException("", "", ex);
        });

        assert(!hasResource(f.ds));
        assert(f.con.inOrder("setAutoCommit(false)", "commit", "setAutoCommit(true)"));
        assert(f.con.count("close") == 1);
        verifyTransactionSynchronizationManagerState();
    }

    @("DataSourceTransactionManagerTests.transactionAwareDataSourceProxyWithEarlyConnection")
    unittest
    {
        auto early = new FakeConnection;
        auto con = new FakeConnection;
        auto ds = new FakeDataSource(early, con);
        auto tm = new DataSourceTransactionManager(ds);
        con.autoCommit = true;
        con.failGetWarnings = true;

        auto dsProxy = new TransactionAwareDataSourceProxy(ds);
        dsProxy.setLazyTransactionalConnections(false);
        auto tCon = dsProxy.getConnection();

        auto tt = new TransactionTemplate(tm);
        assert(!hasResource(ds));
        tt.executeWithoutResult((TransactionStatus) {
            // something transactional
            assert(DataSourceUtils.getConnection(ds) is con);
            try
                // should close the early Connection obtained before the transaction
                tCon.close();
            catch (SQLException ex)
                throw new UncategorizedSQLException("", "", ex);
        });

        assert(!hasResource(ds));

        assert(con.inOrder("setAutoCommit(false)", "commit", "setAutoCommit(true)"));
        assert(con.count("close") == 1);
        verifyTransactionSynchronizationManagerState();
    }

    private void assertTransactionAwareDataSourceProxyWithSuspension(bool reobtain)
    {
        auto f = Fixture.create();
        f.con.autoCommit = true;

        auto tt = new TransactionTemplate(f.tm);
        tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        assert(!hasResource(f.ds));

        tt.executeWithoutResult((TransactionStatus) {
            // something transactional
            assert(DataSourceUtils.getConnection(f.ds) is f.con);
            auto dsProxy = new TransactionAwareDataSourceProxy(f.ds);
            if (reobtain)
                dsProxy.setReobtainTransactionalConnections(true);
            void useProxy()
            {
                try
                {
                    assert((cast(ConnectionProxy) dsProxy.getConnection()).getTargetConnection() is f.con);
                    // should be ignored
                    dsProxy.getConnection().close();
                }
                catch (SQLException ex)
                    throw new UncategorizedSQLException("", "", ex);
            }

            useProxy();
            tt.executeWithoutResult((TransactionStatus) {
                // something transactional
                assert(DataSourceUtils.getConnection(f.ds) is f.con);
                useProxy();
            });
            useProxy();
        });

        assert(!hasResource(f.ds));
        assert(f.con.inOrder("setAutoCommit(false)", "commit", "setAutoCommit(true)"));
        assert(f.con.count("close") == 2);
        verifyTransactionSynchronizationManagerState();
    }

    @("DataSourceTransactionManagerTests.transactionAwareDataSourceProxyWithSuspension")
    unittest
    {
        assertTransactionAwareDataSourceProxyWithSuspension(false);
    }

    @("DataSourceTransactionManagerTests.transactionAwareDataSourceProxyWithSuspensionAndReobtaining")
    unittest
    {
        assertTransactionAwareDataSourceProxyWithSuspension(true);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Nested transactions with an inner REQUIRED participant

@("DataSourceTransactionManagerTests.existingTransactionWithPropagationNestedAndRequiredRollback")
unittest
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_NESTED);
    assert(!hasResource(f.ds));
    assert(!TransactionSynchronizationManager.isSynchronizationActive());

    tt.executeWithoutResult((TransactionStatus status) {
        assert(status.hasTransaction());
        assert(status.isNewTransaction());
        assert(!status.isNested());
        assert(!status.hasSavepoint());
        auto synch = new TestSavepointSynchronization;
        TransactionSynchronizationManager.registerSynchronization(synch);
        expectThrows!IllegalStateException({
            tt.executeWithoutResult((TransactionStatus status2) {
                assert(hasResource(f.ds));
                assert(TransactionSynchronizationManager.isSynchronizationActive());
                assert(status2.hasTransaction());
                assert(!status2.isNewTransaction());
                assert(status2.isNested());
                assert(status2.hasSavepoint());
                assert(synch.savepointCalled);
                assert(!synch.savepointRollbackCalled);
                auto ntt = new TransactionTemplate(f.tm);
                ntt.executeWithoutResult((TransactionStatus status3) {
                    assert(hasResource(f.ds));
                    assert(TransactionSynchronizationManager.isSynchronizationActive());
                    assert(status3.hasTransaction());
                    assert(!status3.isNewTransaction());
                    assert(!status3.isNested());
                    assert(!status3.hasSavepoint());
                    throw new IllegalStateException();
                });
            });
        });
        assert(synch.savepointRollbackCalled);
        assert(status.hasTransaction());
        assert(status.isNewTransaction());
        assert(!status.isNested());
        assert(!status.hasSavepoint());
    });

    assert(!hasResource(f.ds));
    assert(f.con.count("rollback(sp)") == 1);
    assert(f.con.count("releaseSavepoint(sp)") == 1);
    assert(f.con.count("commit") == 1);
    assert(f.con.count("close") == 1);
    verifyTransactionSynchronizationManagerState();
}

@("DataSourceTransactionManagerTests.existingTransactionWithPropagationNestedAndRequiredRollbackOnly")
unittest
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_NESTED);
    assert(!hasResource(f.ds));
    assert(!TransactionSynchronizationManager.isSynchronizationActive());

    tt.executeWithoutResult((TransactionStatus status1) {
        assert(status1.hasTransaction());
        assert(status1.isNewTransaction());
        assert(!status1.isNested());
        assert(!status1.hasSavepoint());
        auto synch = new TestSavepointSynchronization;
        TransactionSynchronizationManager.registerSynchronization(synch);
        expectThrows!UnexpectedRollbackException({
            tt.executeWithoutResult((TransactionStatus status2) {
                assert(hasResource(f.ds));
                assert(TransactionSynchronizationManager.isSynchronizationActive());
                assert(status2.hasTransaction());
                assert(!status2.isNewTransaction());
                assert(status2.isNested());
                assert(status2.hasSavepoint());
                assert(synch.savepointCalled);
                assert(!synch.savepointRollbackCalled);
                auto ntt = new TransactionTemplate(f.tm);
                ntt.executeWithoutResult((TransactionStatus status3) {
                    assert(hasResource(f.ds));
                    assert(TransactionSynchronizationManager.isSynchronizationActive());
                    assert(status3.hasTransaction());
                    assert(!status3.isNewTransaction());
                    assert(!status3.isNested());
                    assert(!status3.hasSavepoint());
                    status3.setRollbackOnly();
                });
            });
        });
        assert(synch.savepointRollbackCalled);
        assert(status1.hasTransaction());
        assert(status1.isNewTransaction());
        assert(!status1.isNested());
        assert(!status1.hasSavepoint());
    });

    assert(!hasResource(f.ds));
    assert(f.con.count("rollback(sp)") == 1);
    assert(f.con.count("releaseSavepoint(sp)") == 1);
    assert(f.con.count("commit") == 1);
    assert(f.con.count("close") == 1);
    verifyTransactionSynchronizationManagerState();
}
