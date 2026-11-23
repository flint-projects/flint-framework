// Ported from spring-framework v7.1.0: spring-jdbc/src/test/java/org/springframework/jdbc/datasource/DataSourceTransactionManagerTests.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.

/++
`DataSourceTransactionManagerTests`, with hand-written fakes in place of Mockito: a `FakeConnection` logs each call,
so `verify(con).commit()` becomes a count of "commit" in its log and `InOrder` becomes an ordered-subsequence check.
The cases for `LazyConnectionDataSourceProxy`, `TransactionAwareDataSourceProxy` and statement timeouts follow with
those classes and `JdbcTemplate`.
+/
module flint.jdbc.datasource_transaction_manager_test;

import flint.java.lang : RuntimeException;
import flint.java.sql : Connection, DatabaseMetaData, SQLException, Savepoint, Statement;
import flint.javax.sql : DataSource;
import flint.dao : ConcurrencyFailureException, DataAccessException;
import flint.jdbc.datasource;
import flint.jdbc.support : JdbcTransactionManager, SQLExceptionTranslator;
import flint.transaction : CannotCreateTransactionException, IllegalTransactionStateException,
    TransactionDefinition, TransactionStatus, TransactionSystemException, UnexpectedRollbackException;
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
    private FakeConnection connection;

    this(FakeConnection connection)
    {
        this.connection = connection;
    }

    override int executeUpdate(string sql)
    {
        connection.log ~= "stmt.executeUpdate(" ~ sql ~ ")";
        return 0;
    }

    override void close()
    {
        connection.log ~= "stmt.close";
    }
}

/// A connection that logs every call the transaction manager makes.
private final class FakeConnection : BlackHole!Connection
{
    string name;
    string[] log;
    bool autoCommit;
    bool readOnly;
    int isolation = Connection.TRANSACTION_READ_COMMITTED;
    bool failGetAutoCommit, failSetReadOnly, failCommit, failRollback;
    string failState;
    FakeSavepoint savepoint;

    this(string name = "con")
    {
        this.name = name;
        savepoint = new FakeSavepoint;
    }

    override bool getAutoCommit()
    {
        log ~= "getAutoCommit";
        if (failGetAutoCommit)
            throw new SQLException("Cannot begin");
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
        if (failCommit)
            throw new SQLException("Cannot commit", failState);
    }

    override void rollback()
    {
        log ~= "rollback";
        if (failRollback)
            throw new SQLException("Cannot rollback", failState);
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
        if (value && failSetReadOnly)
            throw new SQLException("read-only not supported");
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
        return new FakeStatement(this);
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

/// A data source handing out its connections in turn, repeating the last.
private final class FakeDataSource : BlackHole!DataSource
{
    FakeConnection[] connections;
    size_t handedOut;

    this(FakeConnection[] connections...)
    {
        this.connections = connections.dup;
    }

    override Connection getConnection()
    {
        scope (exit)
            ++handedOut;
        return handedOut < connections.length ? connections[handedOut] : connections[$ - 1];
    }
}

private final class TestTransactionSynchronization : TransactionSynchronization
{
    bool beforeCommitCalled, beforeCompletionCalled, afterCommitCalled, afterCompletionCalled;
    int expectedStatus;

    this(int expectedStatus)
    {
        this.expectedStatus = expectedStatus;
    }

    override void beforeCommit(bool)
    {
        beforeCommitCalled = true;
    }

    override void beforeCompletion()
    {
        beforeCompletionCalled = true;
    }

    override void afterCommit()
    {
        afterCommitCalled = true;
    }

    override void afterCompletion(int status)
    {
        assert(status == expectedStatus);
        afterCompletionCalled = true;
    }
}

private final class TestSavepointSynchronization : TransactionSynchronization
{
    bool savepointCalled, savepointRollbackCalled;

    override void savepoint(Object)
    {
        savepointCalled = true;
    }

    override void savepointRollback(Object)
    {
        savepointRollbackCalled = true;
    }
}

/// The per-test fixture: Spring's `@BeforeEach` and `@AfterEach`.
private struct Fixture
{
    FakeConnection con;
    FakeDataSource ds;
    DataSourceTransactionManager tm;

    static Fixture create(bool jdbc = false)
    {
        Fixture fixture;
        fixture.con = new FakeConnection;
        fixture.ds = new FakeDataSource(fixture.con);
        fixture.tm = jdbc ? new JdbcTransactionManager(fixture.ds) : new DataSourceTransactionManager(fixture.ds);
        return fixture;
    }

    bool bound()
    {
        return TransactionSynchronizationManager.hasResource(cast(Object) ds);
    }
}

/// Spring's `verifyTransactionSynchronizationManagerState`.
private void verifyClean()
{
    assert(TransactionSynchronizationManager.getResourceMap().length == 0);
    assert(!TransactionSynchronizationManager.isSynchronizationActive());
    assert(!TransactionSynchronizationManager.isCurrentTransactionReadOnly());
    assert(!TransactionSynchronizationManager.isActualTransactionActive());
}

private void expectThrows(E : Throwable)(scope void delegate() @safe action, string what = E.stringof)
{
    try
        action();
    catch (E)
        return;
    assert(false, "expected " ~ what);
}

// ---------------------------------------------------------------------------------------------------------------
// Commit and rollback

private void assertTransactionCommitRestoringAutoCommit(bool autoCommit)
{
    auto f = Fixture.create();
    f.con.autoCommit = autoCommit;
    auto tt = new TransactionTemplate(f.tm);
    assert(!f.bound() && !TransactionSynchronizationManager.isSynchronizationActive());

    tt.executeWithoutResult((TransactionStatus status) {
        assert(f.bound());
        assert(TransactionSynchronizationManager.isSynchronizationActive());
        assert(status.isNewTransaction());
        assert(!TransactionSynchronizationManager.isCurrentTransactionReadOnly());
        assert(TransactionSynchronizationManager.isActualTransactionActive());
        auto tCon = DataSourceUtils.getConnection(f.ds);
        assert(tCon is f.con);
        tCon.getWarnings();
        tCon.clearWarnings();
    });

    assert(!f.bound() && !TransactionSynchronizationManager.isSynchronizationActive());
    if (autoCommit)
        assert(f.con.inOrder("setAutoCommit(false)", "commit", "setAutoCommit(true)"));
    assert(f.con.count("commit") == 1 && f.con.count("close") == 1);
    verifyClean();
}

@("transactionCommitWithAutoCommitTrue")
unittest
{
    assertTransactionCommitRestoringAutoCommit(true);
}

@("transactionCommitWithAutoCommitFalse")
unittest
{
    assertTransactionCommitRestoringAutoCommit(false);
}

private void assertTransactionRollbackRestoringAutoCommit(bool autoCommit)
{
    auto f = Fixture.create();
    f.con.autoCommit = autoCommit;
    auto tt = new TransactionTemplate(f.tm);
    auto ex = new RuntimeException("Application exception");
    try
    {
        tt.executeWithoutResult((TransactionStatus status) {
            assert(f.bound() && TransactionSynchronizationManager.isSynchronizationActive());
            assert(status.isNewTransaction());
            DataSourceUtils.getConnection(f.ds);
            throw ex;
        });
        assert(false, "expected RuntimeException");
    }
    catch (RuntimeException thrown)
        assert(thrown is ex);

    assert(!f.bound() && !TransactionSynchronizationManager.isSynchronizationActive());
    if (autoCommit)
        assert(f.con.inOrder("setAutoCommit(false)", "rollback", "setAutoCommit(true)"));
    assert(f.con.count("rollback") == 1 && f.con.count("close") == 1);
    verifyClean();
}

@("transactionRollbackWithAutoCommitTrue")
unittest
{
    assertTransactionRollbackRestoringAutoCommit(true);
}

@("transactionRollbackWithAutoCommitFalse")
unittest
{
    assertTransactionRollbackRestoringAutoCommit(false);
}

@("transactionRollbackOnly")
unittest
{
    auto f = Fixture.create();
    f.tm.setTransactionSynchronization(AbstractPlatformTransactionManager.SYNCHRONIZATION_NEVER);
    auto tt = new TransactionTemplate(f.tm);
    assert(!f.bound());

    auto conHolder = new ConnectionHolder(f.con, true);
    TransactionSynchronizationManager.bindResource(cast(Object) f.ds, conHolder);
    auto ex = new RuntimeException("Application exception");
    try
    {
        tt.executeWithoutResult((TransactionStatus status) {
            assert(f.bound());
            assert(!TransactionSynchronizationManager.isSynchronizationActive());
            assert(!status.isNewTransaction());
            throw ex;
        });
        assert(false, "Should have thrown RuntimeException");
    }
    catch (RuntimeException ex2)
    {
        assert(!TransactionSynchronizationManager.isSynchronizationActive());
        assert(ex2 is ex, "Correct exception thrown");
    }
    finally
        TransactionSynchronizationManager.unbindResource(cast(Object) f.ds);
    assert(!f.bound());
    verifyClean();
}

private void assertParticipatingTransactionWithRollbackOnly(bool failEarly)
{
    auto f = Fixture.create();
    if (failEarly)
        f.tm.setFailEarlyOnGlobalRollbackOnly(true);
    assert(!f.bound() && !TransactionSynchronizationManager.isSynchronizationActive());

    auto ts = f.tm.getTransaction(new DefaultTransactionDefinition);
    auto synch = new TestTransactionSynchronization(TransactionSynchronization.STATUS_ROLLED_BACK);
    TransactionSynchronizationManager.registerSynchronization(synch);

    bool outerTransactionBoundaryReached;
    try
    {
        assert(ts.isNewTransaction());
        auto tt = new TransactionTemplate(f.tm);
        tt.executeWithoutResult((TransactionStatus status1) {
            assert(!status1.isNewTransaction() && !status1.isRollbackOnly());
            tt.executeWithoutResult((TransactionStatus status2) {
                assert(f.bound() && TransactionSynchronizationManager.isSynchronizationActive());
                assert(!status2.isNewTransaction());
                status2.setRollbackOnly();
            });
            assert(!status1.isNewTransaction() && status1.isRollbackOnly());
        });
        outerTransactionBoundaryReached = true;
        f.tm.commit(ts);
        assert(false, "Should have thrown UnexpectedRollbackException");
    }
    catch (UnexpectedRollbackException)
    {
        if (!outerTransactionBoundaryReached)
            f.tm.rollback(ts);
        assert(outerTransactionBoundaryReached == !failEarly);
    }

    assert(!f.bound());
    assert(!synch.beforeCommitCalled && synch.beforeCompletionCalled);
    assert(!synch.afterCommitCalled && synch.afterCompletionCalled);
    assert(f.con.count("rollback") == 1 && f.con.count("close") == 1);
    verifyClean();
}

@("participatingTransactionWithRollbackOnly")
unittest
{
    assertParticipatingTransactionWithRollbackOnly(false);
}

@("participatingTransactionWithRollbackOnlyAndFailEarly")
unittest
{
    assertParticipatingTransactionWithRollbackOnly(true);
}

@("participatingTransactionWithIncompatibleIsolationLevel")
unittest
{
    auto f = Fixture.create();
    f.tm.setValidateExistingTransaction(true);
    expectThrows!IllegalTransactionStateException({
        auto tt = new TransactionTemplate(f.tm);
        auto tt2 = new TransactionTemplate(f.tm);
        tt2.setIsolationLevel(TransactionDefinition.ISOLATION_SERIALIZABLE);
        tt.executeWithoutResult((TransactionStatus status) {
            assert(!status.isRollbackOnly());
            tt2.executeWithoutResult((TransactionStatus inner) { inner.setRollbackOnly(); });
            assert(status.isRollbackOnly());
        });
    });
    assert(!f.bound());
    assert(f.con.count("rollback") == 1 && f.con.count("close") == 1);
    verifyClean();
}

@("participatingTransactionWithIncompatibleReadOnly")
unittest
{
    auto f = Fixture.create();
    f.con.failSetReadOnly = true;
    f.tm.setValidateExistingTransaction(true);
    expectThrows!IllegalTransactionStateException({
        auto tt = new TransactionTemplate(f.tm);
        tt.setReadOnly(true);
        auto tt2 = new TransactionTemplate(f.tm);
        tt2.setReadOnly(false);
        tt.executeWithoutResult((TransactionStatus status) {
            assert(!status.isRollbackOnly());
            tt2.executeWithoutResult((TransactionStatus inner) { inner.setRollbackOnly(); });
            assert(status.isRollbackOnly());
        });
    });
    assert(!f.bound());
    assert(f.con.count("rollback") == 1 && f.con.count("close") == 1);
    verifyClean();
}

// ---------------------------------------------------------------------------------------------------------------
// Propagation

@("propagationRequiresNewWithExistingTransaction")
unittest
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    tt.executeWithoutResult((TransactionStatus status) {
        assert(status.isNewTransaction());
        assert(TransactionSynchronizationManager.isSynchronizationActive());
        assert(TransactionSynchronizationManager.isActualTransactionActive());
        tt.executeWithoutResult((TransactionStatus status2) {
            assert(f.bound() && TransactionSynchronizationManager.isSynchronizationActive());
            assert(status2.isNewTransaction());
            assert(TransactionSynchronizationManager.isActualTransactionActive());
            status2.setRollbackOnly();
        });
        assert(status.isNewTransaction());
        assert(TransactionSynchronizationManager.isActualTransactionActive());
    });
    assert(!f.bound());
    assert(f.con.count("rollback") == 1 && f.con.count("commit") == 1 && f.con.count("close") == 2);
    verifyClean();
}

@("propagationRequiresNewWithExistingTransactionAndUnrelatedDataSource")
unittest
{
    auto f = Fixture.create();
    auto con2 = new FakeConnection("con2");
    auto ds2 = new FakeDataSource(con2);
    auto tm2 = new DataSourceTransactionManager(ds2);
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    auto tt2 = new TransactionTemplate(tm2);
    tt2.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    tt.executeWithoutResult((TransactionStatus status) {
        assert(status.isNewTransaction());
        tt2.executeWithoutResult((TransactionStatus status2) {
            assert(f.bound() && TransactionSynchronizationManager.hasResource(cast(Object) ds2));
            assert(status2.isNewTransaction());
            status2.setRollbackOnly();
        });
        assert(status.isNewTransaction());
    });
    assert(!f.bound() && !TransactionSynchronizationManager.hasResource(cast(Object) ds2));
    assert(f.con.count("commit") == 1 && f.con.count("close") == 1);
    assert(con2.count("rollback") == 1 && con2.count("close") == 1);
    verifyClean();
}

@("propagationNotSupportedWithExistingTransaction")
unittest
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    tt.executeWithoutResult((TransactionStatus status) {
        assert(status.hasTransaction() && status.isNewTransaction() && !status.isNested());
        assert(TransactionSynchronizationManager.isActualTransactionActive());
        tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_NOT_SUPPORTED);
        tt.executeWithoutResult((TransactionStatus status2) {
            assert(!f.bound() && TransactionSynchronizationManager.isSynchronizationActive());
            assert(!status2.hasTransaction() && !status2.isNewTransaction() && !status2.isNested());
            assert(!status2.isReadOnly());
            assert(!TransactionSynchronizationManager.isActualTransactionActive());
            status2.setRollbackOnly();
        });
        assert(status.isNewTransaction());
        assert(TransactionSynchronizationManager.isActualTransactionActive());
    });
    assert(!f.bound());
    assert(f.con.count("commit") == 1 && f.con.count("close") == 1);
    verifyClean();
}

@("propagationNeverWithExistingTransaction")
unittest
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    expectThrows!IllegalTransactionStateException({
        tt.executeWithoutResult((TransactionStatus status) {
            assert(status.hasTransaction() && status.isNewTransaction() && !status.isNested());
            tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_NEVER);
            tt.executeWithoutResult((TransactionStatus) {
                assert(false, "Should have thrown IllegalTransactionStateException");
            });
            assert(false, "Should have thrown IllegalTransactionStateException");
        });
    });
    assert(!f.bound());
    assert(f.con.count("rollback") == 1 && f.con.count("close") == 1);
    verifyClean();
}

@("propagationSupportsAndRequiresNew")
unittest
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_SUPPORTS);
    tt.executeWithoutResult((TransactionStatus status) {
        assert(TransactionSynchronizationManager.isSynchronizationActive());
        assert(!status.hasTransaction() && !status.isNewTransaction() && !status.isNested());
        auto tt2 = new TransactionTemplate(f.tm);
        tt2.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        tt2.executeWithoutResult((TransactionStatus status2) {
            assert(f.bound() && TransactionSynchronizationManager.isSynchronizationActive());
            assert(status2.hasTransaction() && status2.isNewTransaction() && !status2.isNested());
            assert(DataSourceUtils.getConnection(f.ds) is f.con);
            assert(DataSourceUtils.getConnection(f.ds) is f.con);
        });
    });
    assert(!f.bound());
    assert(f.con.count("commit") == 1 && f.con.count("close") == 1);
    verifyClean();
}

@("propagationSupportsAndRequiresNewWithEarlyAccess")
unittest
{
    auto con1 = new FakeConnection("con1");
    auto con2 = new FakeConnection("con2");
    auto ds = new FakeDataSource(con1, con2);
    auto tm = new DataSourceTransactionManager(ds);
    auto tt = new TransactionTemplate(tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_SUPPORTS);
    tt.executeWithoutResult((TransactionStatus status) {
        assert(TransactionSynchronizationManager.isSynchronizationActive());
        assert(DataSourceUtils.getConnection(ds) is con1);
        assert(DataSourceUtils.getConnection(ds) is con1);
        assert(!status.hasTransaction() && !status.isNewTransaction() && !status.isNested());
        auto tt2 = new TransactionTemplate(tm);
        tt2.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        tt2.executeWithoutResult((TransactionStatus status2) {
            assert(TransactionSynchronizationManager.hasResource(cast(Object) ds));
            assert(DataSourceUtils.getConnection(ds) is con2);
            assert(DataSourceUtils.getConnection(ds) is con2);
            assert(status2.hasTransaction() && status2.isNewTransaction() && !status2.isNested());
        });
        assert(DataSourceUtils.getConnection(ds) is con1);
    });
    assert(!TransactionSynchronizationManager.hasResource(cast(Object) ds));
    assert(con1.count("close") == 1);
    assert(con2.count("commit") == 1 && con2.count("close") == 1);
    verifyClean();
}

@("transactionWithPropagationSupports, transactionWithPropagationNotSupported and transactionWithPropagationNever")
unittest
{
    foreach (propagation; [
        TransactionDefinition.PROPAGATION_SUPPORTS,
        TransactionDefinition.PROPAGATION_NOT_SUPPORTED, TransactionDefinition.PROPAGATION_NEVER
    ])
    {
        auto f = Fixture.create();
        auto tt = new TransactionTemplate(f.tm);
        tt.setPropagationBehavior(propagation);
        tt.executeWithoutResult((TransactionStatus status) {
            assert(!f.bound());
            assert(!status.isNewTransaction());
            assert(!TransactionSynchronizationManager.isCurrentTransactionReadOnly());
            assert(!TransactionSynchronizationManager.isActualTransactionActive());
        });
        assert(!f.bound());
        assert(f.con.log.length == 0, "no connection is touched without a transaction");
        verifyClean();
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Isolation and read-only

private void assertTransactionReadOnly(ref Fixture f, int isolationLevel)
{
    auto tt = new TransactionTemplate(f.tm);
    tt.setIsolationLevel(isolationLevel);
    tt.setReadOnly(true);
    tt.executeWithoutResult((TransactionStatus) {
        assert(TransactionSynchronizationManager.isCurrentTransactionReadOnly());
        assert(TransactionSynchronizationManager.isActualTransactionActive());
    });
    assert(!f.bound());
}

@("transactionWithIsolationAndReadOnly")
unittest
{
    auto f = Fixture.create();
    f.con.isolation = Connection.TRANSACTION_READ_UNCOMMITTED;
    f.con.autoCommit = true;
    assertTransactionReadOnly(f, TransactionDefinition.ISOLATION_REPEATABLE_READ);
    assert(f.con.log == [
        "isReadOnly", "setReadOnly(true)", "getTransactionIsolation", "setTransactionIsolation(4)",
        "getAutoCommit", "setAutoCommit(false)", "commit", "setAutoCommit(true)",
        "setTransactionIsolation(1)", "setReadOnly(false)", "close"
    ], "verifyNoMoreInteractions");
    verifyClean();
}

@("transactionWithDefaultReadOnly")
unittest
{
    auto f = Fixture.create();
    f.con.autoCommit = true;
    f.con.readOnly = true;
    assertTransactionReadOnly(f, TransactionDefinition.ISOLATION_DEFAULT);
    assert(f.con.log == [
        "isReadOnly", "getAutoCommit", "setAutoCommit(false)", "commit", "setAutoCommit(true)",
        "close"
    ], "verifyNoMoreInteractions");
    verifyClean();
}

@("transactionWithEnforceReadOnly")
unittest
{
    auto f = Fixture.create();
    f.tm.setEnforceReadOnly(true);
    f.con.autoCommit = true;
    assertTransactionReadOnly(f, TransactionDefinition.ISOLATION_DEFAULT);
    assert(f.con.log == [
        "isReadOnly", "setReadOnly(true)", "getAutoCommit", "setAutoCommit(false)", "createStatement",
        "stmt.executeUpdate(SET TRANSACTION READ ONLY)", "stmt.close", "commit",
        "setAutoCommit(true)", "setReadOnly(false)", "close"
    ], "verifyNoMoreInteractions");
    verifyClean();
}

// ---------------------------------------------------------------------------------------------------------------
// Failures

@("transactionWithExceptionOnBegin")
unittest
{
    auto f = Fixture.create();
    f.con.failGetAutoCommit = true;
    auto tt = new TransactionTemplate(f.tm);
    expectThrows!CannotCreateTransactionException({ tt.executeWithoutResult((TransactionStatus) {}); });
    assert(!f.bound());
    assert(f.con.count("close") == 1);
    verifyClean();
}

@("transactionWithExceptionOnCommit")
unittest
{
    auto f = Fixture.create();
    f.con.failCommit = true;
    auto tt = new TransactionTemplate(f.tm);
    expectThrows!TransactionSystemException({ tt.executeWithoutResult((TransactionStatus) {}); });
    assert(!f.bound());
    assert(f.con.count("close") == 1);
    verifyClean();
}

@("transactionWithExceptionOnCommitAndRollbackOnCommitFailure")
unittest
{
    auto f = Fixture.create();
    f.con.failCommit = true;
    f.tm.setRollbackOnCommitFailure(true);
    auto tt = new TransactionTemplate(f.tm);
    expectThrows!TransactionSystemException({ tt.executeWithoutResult((TransactionStatus) {}); });
    assert(!f.bound());
    assert(f.con.count("rollback") == 1 && f.con.count("close") == 1);
    verifyClean();
}

@("transactionWithExceptionOnRollback")
unittest
{
    auto f = Fixture.create();
    f.con.autoCommit = true;
    f.con.failRollback = true;
    auto tt = new TransactionTemplate(f.tm);
    expectThrows!TransactionSystemException({
        tt.executeWithoutResult((TransactionStatus status) {
            assert(status.getTransactionName().length == 0);
            assert(status.hasTransaction() && status.isNewTransaction() && !status.isNested());
            assert(!status.hasSavepoint() && !status.isReadOnly() && !status.isRollbackOnly());
            status.setRollbackOnly();
            assert(status.isRollbackOnly() && !status.isCompleted());
        });
    });
    assert(!f.bound());
    assert(f.con.inOrder("setAutoCommit(false)", "rollback", "setAutoCommit(true)"));
    assert(f.con.count("close") == 1);
    verifyClean();
}

// ---------------------------------------------------------------------------------------------------------------
// Nested transactions and savepoints

private void assertExistingTransactionWithPropagationNested(int count)
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_NESTED);
    tt.executeWithoutResult((TransactionStatus status) {
        assert(status.hasTransaction() && status.isNewTransaction() && !status.isNested() && !status.hasSavepoint());
        auto synch = new TestSavepointSynchronization;
        TransactionSynchronizationManager.registerSynchronization(synch);
        foreach (i; 0 .. count)
        {
            tt.executeWithoutResult((TransactionStatus status2) {
                assert(f.bound() && TransactionSynchronizationManager.isSynchronizationActive());
                assert(status2.hasTransaction() && !status2.isNewTransaction());
                assert(status2.isNested() && status2.hasSavepoint());
                assert(synch.savepointCalled);
            });
            assert(!synch.savepointRollbackCalled);
            synch.savepointCalled = false;
        }
        assert(status.hasTransaction() && status.isNewTransaction() && !status.isNested() && !status.hasSavepoint());
    });
    assert(!f.bound());
    foreach (i; 1 .. count + 1)
    {
        import std.conv : to;

        assert(f.con.count("setSavepoint(SAVEPOINT_" ~ i.to!string ~ ")") == 1);
    }
    assert(f.con.count("releaseSavepoint(sp)") == count);
    assert(f.con.count("commit") == 1 && f.con.count("close") == 1);
    verifyClean();
}

@("existingTransactionWithPropagationNested")
unittest
{
    assertExistingTransactionWithPropagationNested(1);
}

@("existingTransactionWithPropagationNestedTwice")
unittest
{
    assertExistingTransactionWithPropagationNested(2);
}

@("existingTransactionWithPropagationNestedAndRollback")
unittest
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_NESTED);
    tt.executeWithoutResult((TransactionStatus status) {
        assert(status.hasTransaction() && status.isNewTransaction() && !status.isNested() && !status.hasSavepoint());
        auto synch = new TestSavepointSynchronization;
        TransactionSynchronizationManager.registerSynchronization(synch);
        tt.executeWithoutResult((TransactionStatus status2) {
            assert(status2.hasTransaction() && !status2.isNewTransaction());
            assert(status2.isNested() && status2.hasSavepoint());
            assert(synch.savepointCalled && !synch.savepointRollbackCalled);
            status2.setRollbackOnly();
        });
        assert(synch.savepointRollbackCalled);
        assert(status.hasTransaction() && status.isNewTransaction() && !status.isNested() && !status.hasSavepoint());
    });
    assert(!f.bound());
    assert(f.con.count("setSavepoint(SAVEPOINT_1)") == 1);
    assert(f.con.count("rollback(sp)") == 1 && f.con.count("releaseSavepoint(sp)") == 1);
    assert(f.con.count("commit") == 1 && f.con.count("close") == 1);
    verifyClean();
}

@("existingTransactionWithManualSavepoint")
unittest
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_NESTED);
    tt.executeWithoutResult((TransactionStatus status) {
        assert(status.hasTransaction() && status.isNewTransaction() && !status.isNested() && !status.hasSavepoint());
        auto synch = new TestSavepointSynchronization;
        TransactionSynchronizationManager.registerSynchronization(synch);
        auto savepoint = status.createSavepoint();
        assert(synch.savepointCalled);
        status.releaseSavepoint(savepoint);
        assert(!synch.savepointRollbackCalled);
    });
    assert(!f.bound());
    assert(f.con.count("releaseSavepoint(sp)") == 1);
    assert(f.con.count("commit") == 1 && f.con.count("close") == 1);
    assert(f.ds.handedOut == 1);
    verifyClean();
}

@("existingTransactionWithManualSavepointAndRollback")
unittest
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_NESTED);
    tt.executeWithoutResult((TransactionStatus status) {
        auto synch = new TestSavepointSynchronization;
        TransactionSynchronizationManager.registerSynchronization(synch);
        auto savepoint = status.createSavepoint();
        assert(synch.savepointCalled && !synch.savepointRollbackCalled);
        status.rollbackToSavepoint(savepoint);
        assert(synch.savepointRollbackCalled);
    });
    assert(!f.bound());
    assert(f.con.count("rollback(sp)") == 1);
    assert(f.con.count("commit") == 1 && f.con.count("close") == 1);
    verifyClean();
}

@("transactionWithPropagationNested")
unittest
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_NESTED);
    tt.executeWithoutResult((TransactionStatus status) {
        assert(status.getTransactionName().length == 0);
        assert(status.hasTransaction() && status.isNewTransaction() && !status.isNested());
        assert(!status.hasSavepoint() && !status.isReadOnly() && !status.isRollbackOnly() && !status.isCompleted());
    });
    assert(!f.bound());
    assert(f.con.count("commit") == 1 && f.con.count("close") == 1);
    verifyClean();
}

@("transactionWithPropagationNestedAndRollback")
unittest
{
    auto f = Fixture.create();
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_NESTED);
    tt.executeWithoutResult((TransactionStatus status) {
        assert(status.getTransactionName().length == 0);
        assert(status.hasTransaction() && status.isNewTransaction() && !status.isNested());
        assert(!status.hasSavepoint() && !status.isReadOnly() && !status.isRollbackOnly());
        status.setRollbackOnly();
        assert(status.isRollbackOnly() && !status.isCompleted());
    });
    assert(!f.bound());
    assert(f.con.count("rollback") == 1 && f.con.count("close") == 1);
    verifyClean();
}

// ---------------------------------------------------------------------------------------------------------------
// DataSourceUtils (DataSourceUtilsTests)

@("DataSourceUtils.getConnection translates SQLException and a null connection")
unittest
{
    import flint.jdbc : CannotGetJdbcConnectionException;

    final class Failing : BlackHole!DataSource
    {
        bool returnNull;

        override Connection getConnection()
        {
            if (returnNull)
                return null;
            throw new SQLException("no connection");
        }
    }

    auto failing = new Failing;
    expectThrows!CannotGetJdbcConnectionException({ DataSourceUtils.getConnection(failing); });
    failing.returnNull = true;
    expectThrows!CannotGetJdbcConnectionException({ DataSourceUtils.getConnection(failing); });
    assert(!TransactionSynchronizationManager.hasResource(cast(Object) failing));
    verifyClean();
}

@("DataSourceUtils binds a synchronized connection outside a transaction and releases it at completion")
unittest
{
    auto f = Fixture.create();
    TransactionSynchronizationManager.initSynchronization();
    auto con = DataSourceUtils.getConnection(f.ds);
    assert(con is f.con && f.bound());
    assert(DataSourceUtils.isConnectionTransactional(con, f.ds));
    DataSourceUtils.releaseConnection(con, f.ds);
    assert(f.con.count("close") == 0, "a synchronized connection stays open until completion");
    TransactionSynchronizationUtils.triggerBeforeCompletion();
    TransactionSynchronizationUtils.triggerAfterCompletion(TransactionSynchronization.STATUS_UNKNOWN);
    TransactionSynchronizationManager.clearSynchronization();
    assert(f.con.count("close") == 1 && !f.bound());
    verifyClean();
}

// ---------------------------------------------------------------------------------------------------------------
// JdbcTransactionManager (JdbcTransactionManagerTests)

private final class ConcurrencyTranslator : SQLExceptionTranslator
{
    override DataAccessException translate(string task, string, SQLException)
    {
        return new ConcurrencyFailureException(task);
    }
}

private void assertCommitFailure(E : Throwable)(string state, bool customTranslator, bool rollback)
{
    auto f = Fixture.create(true);
    if (rollback)
    {
        f.con.autoCommit = true;
        f.con.failRollback = true;
    }
    else
        f.con.failCommit = true;
    f.con.failState = state;
    if (customTranslator)
        (cast(JdbcTransactionManager) f.tm).setExceptionTranslator(new ConcurrencyTranslator);
    auto tt = new TransactionTemplate(f.tm);
    expectThrows!E({
        tt.executeWithoutResult((TransactionStatus status) {
            if (rollback)
                status.setRollbackOnly();
        });
    });
    assert(!f.bound());
    if (rollback)
        assert(f.con.inOrder("setAutoCommit(false)", "rollback", "setAutoCommit(true)"));
    assert(f.con.count("close") == 1);
    verifyClean();
}

@("JdbcTransactionManager: transactionWithExceptionOnCommit stays a plain TransactionSystemException")
unittest
{
    assertCommitFailure!TransactionSystemException(null, false, false);
}

@("JdbcTransactionManager: transactionWithDataAccessExceptionOnCommit")
unittest
{
    assertCommitFailure!ConcurrencyFailureException(null, true, false);
}

@("JdbcTransactionManager: transactionWithDataAccessExceptionOnCommitFromLazyExceptionTranslator")
unittest
{
    assertCommitFailure!ConcurrencyFailureException("40", false, false);
}

@("JdbcTransactionManager: transactionWithExceptionOnRollback stays a plain TransactionSystemException")
unittest
{
    assertCommitFailure!TransactionSystemException(null, false, true);
}

@("JdbcTransactionManager: transactionWithDataAccessExceptionOnRollback")
unittest
{
    assertCommitFailure!ConcurrencyFailureException(null, true, true);
}

@("JdbcTransactionManager: transactionWithDataAccessExceptionOnRollbackFromLazyExceptionTranslator")
unittest
{
    assertCommitFailure!ConcurrencyFailureException("40", false, true);
}

@("JdbcTransactionManager runs the inherited cases: commit, nested savepoints and REQUIRES_NEW")
unittest
{
    auto f = Fixture.create(true);
    f.con.autoCommit = true;
    auto tt = new TransactionTemplate(f.tm);
    tt.setPropagationBehavior(TransactionDefinition.PROPAGATION_NESTED);
    tt.executeWithoutResult((TransactionStatus outer) {
        assert(outer.isNewTransaction());
        tt.executeWithoutResult((TransactionStatus inner) { assert(inner.hasSavepoint()); });
        auto requiresNew = new TransactionTemplate(f.tm);
        requiresNew.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        requiresNew.executeWithoutResult((TransactionStatus inner) {
            assert(inner.isNewTransaction());
        });
    });
    assert(f.con.count("releaseSavepoint(sp)") == 1 && f.con.count("commit") == 2 && f.con.count("close") == 2);
    verifyClean();
}
