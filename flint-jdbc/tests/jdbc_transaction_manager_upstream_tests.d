/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/support/JdbcTransactionManagerTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: only the test that `datasource_transaction_manager.d` (module
`flint.jdbc.datasource_transaction_manager_test`, the "JdbcTransactionManager: ..." cases) does not already cover by
name; a hand-written `FakeConnection` that logs its calls replaces the Mockito mock.
+/
module flint.jdbc.jdbc_transaction_manager_upstream_tests;

import flint.java.sql : Connection, SQLException;
import flint.javax.sql : DataSource;
import flint.jdbc.support : JdbcTransactionManager;
import flint.transaction : TransactionStatus, TransactionSystemException;
import flint.transaction.support : TransactionSynchronizationManager, TransactionTemplate;
import std.typecons : BlackHole;

@safe:

/// A connection that logs the calls the transaction manager makes, and fails to commit.
private final class FakeConnection : BlackHole!Connection
{
    string[] log;

    override bool getAutoCommit()
    {
        log ~= "getAutoCommit";
        return false;
    }

    override void commit()
    {
        log ~= "commit";
        throw new SQLException("Cannot commit");
    }

    override void rollback()
    {
        log ~= "rollback";
    }

    override void close()
    {
        log ~= "close";
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
}

private final class FakeDataSource : BlackHole!DataSource
{
    FakeConnection con;

    this(FakeConnection con)
    {
        this.con = con;
    }

    override Connection getConnection()
    {
        return con;
    }
}

/// Spring's `@AfterEach verifyTransactionSynchronizationManagerState`.
private void verifyTransactionSynchronizationManagerState()
{
    assert(TransactionSynchronizationManager.getResourceMap().length == 0);
    assert(!TransactionSynchronizationManager.isSynchronizationActive());
    assert(!TransactionSynchronizationManager.isCurrentTransactionReadOnly());
    assert(!TransactionSynchronizationManager.isActualTransactionActive());
}

@("JdbcTransactionManagerTests.transactionWithExceptionOnCommitAndRollbackOnCommitFailure")
unittest
{
    auto con = new FakeConnection;
    auto ds = new FakeDataSource(con);
    auto tm = new JdbcTransactionManager(ds);

    tm.setRollbackOnCommitFailure(true);
    auto tt = new TransactionTemplate(tm);

    // plain TransactionSystemException
    bool thrown;
    try
        tt.executeWithoutResult((TransactionStatus) {
            // something transactional
        });
    catch (TransactionSystemException)
        thrown = true;
    assert(thrown, "expected TransactionSystemException");

    assert(!TransactionSynchronizationManager.hasResource(cast(Object) ds));
    assert(con.count("rollback") == 1);
    assert(con.count("close") == 1);
    verifyTransactionSynchronizationManagerState();
}
