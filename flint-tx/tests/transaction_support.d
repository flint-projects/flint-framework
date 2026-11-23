// Ported from spring-framework v7.1.0: spring-tx/src/test/java/org/springframework/transaction/support/TransactionSupportTests.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: TestTransactionManager.java and, from spring-tx/src/testFixtures,
// TestTransactionExecutionListener.java and MockCallbackPreferringTransactionManager.java.
module flint.transaction.transaction_support_test;

import flint.java.lang : IllegalArgumentException, RuntimeException, UnsupportedOperationException;
import flint.transaction;
import flint.transaction.support;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fixtures

/// `TestTransactionManager`: records which template methods ran.
private class TestTransactionManager : AbstractPlatformTransactionManager
{
    private static Object transactionObject()
    {
        static immutable string marker = "transaction";
        return new Marker(marker);
    }

    private Object transaction;
    private bool existingTransaction;
    private bool canCreateTransaction;
    // Java's fields share the names of the methods; D's cannot, so they take a trailing underscore.
    bool begin_;
    bool commit_;
    bool rollback_;
    bool rollbackOnly_;

    this(bool existingTransaction, bool canCreateTransaction)
    {
        this.existingTransaction = existingTransaction;
        this.canCreateTransaction = canCreateTransaction;
        transaction = transactionObject();
        setTransactionSynchronization(SYNCHRONIZATION_NEVER);
    }

    override protected Object doGetTransaction()
    {
        return transaction;
    }

    override protected bool isExistingTransaction(Object)
    {
        return existingTransaction;
    }

    override protected void doBegin(Object transaction, TransactionDefinition)
    {
        if (transaction !is this.transaction)
            throw new IllegalArgumentException("Not the same transaction object");
        if (!canCreateTransaction)
            throw new CannotCreateTransactionException("Cannot create transaction");
        begin_ = true;
    }

    override protected void doCommit(DefaultTransactionStatus status)
    {
        if (status.getTransaction() !is transaction)
            throw new IllegalArgumentException("Not the same transaction object");
        commit_ = true;
    }

    override protected void doRollback(DefaultTransactionStatus status)
    {
        if (status.getTransaction() !is transaction)
            throw new IllegalArgumentException("Not the same transaction object");
        rollback_ = true;
    }

    override protected void doSetRollbackOnly(DefaultTransactionStatus status)
    {
        if (status.getTransaction() !is transaction)
            throw new IllegalArgumentException("Not the same transaction object");
        rollbackOnly_ = true;
    }
}

private final class Marker
{
    string name;

    this(string name)
    {
        this.name = name;
    }
}

/// `TestTransactionExecutionListener`.
private final class TestTransactionExecutionListener : TransactionExecutionListener
{
    bool beforeBeginCalled;
    bool afterBeginCalled;
    Throwable beginFailure;
    bool beforeCommitCalled;
    bool afterCommitCalled;
    Throwable commitFailure;
    bool beforeRollbackCalled;
    bool afterRollbackCalled;
    Throwable rollbackFailure;

    override void beforeBegin(TransactionExecution)
    {
        beforeBeginCalled = true;
    }

    override void afterBegin(TransactionExecution, Throwable beginFailure)
    {
        afterBeginCalled = true;
        this.beginFailure = beginFailure;
    }

    override void beforeCommit(TransactionExecution)
    {
        beforeCommitCalled = true;
    }

    override void afterCommit(TransactionExecution, Throwable commitFailure)
    {
        afterCommitCalled = true;
        this.commitFailure = commitFailure;
    }

    override void beforeRollback(TransactionExecution)
    {
        beforeRollbackCalled = true;
    }

    override void afterRollback(TransactionExecution, Throwable rollbackFailure)
    {
        afterRollbackCalled = true;
        this.rollbackFailure = rollbackFailure;
    }
}

/// `MockCallbackPreferringTransactionManager`.
private final class MockCallbackPreferringTransactionManager : CallbackPreferringPlatformTransactionManager
{
    private TransactionDefinition definition;
    private TransactionStatus status;

    override void execute(TransactionDefinition definition, scope void delegate(TransactionStatus) @safe action)
    {
        this.definition = definition;
        status = new SimpleTransactionStatus();
        action(status);
    }

    TransactionDefinition getDefinition()
    {
        return definition;
    }

    TransactionStatus getStatus()
    {
        return status;
    }

    override TransactionStatus getTransaction(TransactionDefinition)
    {
        throw new UnsupportedOperationException();
    }

    override void commit(TransactionStatus)
    {
        throw new UnsupportedOperationException();
    }

    override void rollback(TransactionStatus)
    {
        throw new UnsupportedOperationException();
    }
}

/// `@AfterEach postConditions`.
private void postConditions()
{
    assert(TransactionSynchronizationManager.getResourceMap().length == 0);
    assert(!TransactionSynchronizationManager.isSynchronizationActive());
}

private void listenerCalls(TestTransactionExecutionListener tl, bool beforeBegin, bool afterBegin,
        bool beforeCommit, bool afterCommit, bool beforeRollback, bool afterRollback)
{
    assert(tl.beforeBeginCalled == beforeBegin, "beforeBegin");
    assert(tl.afterBeginCalled == afterBegin, "afterBegin");
    assert(tl.beforeCommitCalled == beforeCommit, "beforeCommit");
    assert(tl.afterCommitCalled == afterCommit, "afterCommit");
    assert(tl.beforeRollbackCalled == beforeRollback, "beforeRollback");
    assert(tl.afterRollbackCalled == afterRollback, "afterRollback");
}

private void managerCalls(TestTransactionManager tm, bool begin, bool commit, bool rollback, bool rollbackOnly)
{
    assert(tm.begin_ == begin, "begin");
    assert(tm.commit_ == commit, "commit");
    assert(tm.rollback_ == rollback, "rollback");
    assert(tm.rollbackOnly_ == rollbackOnly, "rollbackOnly");
}

private void throwsIllegalArgument(scope void delegate() @safe action)
{
    try
    {
        action();
        assert(false, "expected IllegalArgumentException");
    }
    catch (IllegalArgumentException)
    {
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Tests

@("TransactionSupportTests.noExistingTransaction")
unittest
{
    PlatformTransactionManager tm = new TestTransactionManager(false, true);
    auto status1 = cast(DefaultTransactionStatus) tm.getTransaction(
            new DefaultTransactionDefinition(TransactionDefinition.PROPAGATION_SUPPORTS));
    assert(!status1.hasTransaction(), "Must not have transaction");
    auto status2 = cast(DefaultTransactionStatus) tm.getTransaction(
            new DefaultTransactionDefinition(TransactionDefinition.PROPAGATION_REQUIRED));
    assert(status2.hasTransaction(), "Must have transaction");
    assert(status2.isNewTransaction(), "Must be new transaction");
    try
    {
        tm.getTransaction(new DefaultTransactionDefinition(TransactionDefinition.PROPAGATION_MANDATORY));
        assert(false, "expected IllegalTransactionStateException");
    }
    catch (IllegalTransactionStateException)
    {
    }
    postConditions();
}

@("TransactionSupportTests.existingTransaction")
unittest
{
    PlatformTransactionManager tm = new TestTransactionManager(true, true);
    foreach (propagation; [
        TransactionDefinition.PROPAGATION_SUPPORTS, TransactionDefinition.PROPAGATION_REQUIRED,
        TransactionDefinition.PROPAGATION_MANDATORY
    ])
    {
        auto status = cast(DefaultTransactionStatus) tm.getTransaction(new DefaultTransactionDefinition(propagation));
        assert(status.getTransaction() !is null, "Must have transaction");
        assert(!status.isNewTransaction(), "Must not be new transaction");
    }
    postConditions();
}

@("TransactionSupportTests.commitWithoutExistingTransaction")
unittest
{
    auto tm = new TestTransactionManager(false, true);
    auto tl = new TestTransactionExecutionListener;
    tm.addListener(tl);
    auto status = tm.getTransaction(null);
    tm.commit(status);
    managerCalls(tm, true, true, false, false);
    listenerCalls(tl, true, true, true, true, false, false);
    postConditions();
}

@("TransactionSupportTests.rollbackWithoutExistingTransaction")
unittest
{
    auto tm = new TestTransactionManager(false, true);
    auto tl = new TestTransactionExecutionListener;
    tm.addListener(tl);
    auto status = tm.getTransaction(null);
    tm.rollback(status);
    managerCalls(tm, true, false, true, false);
    listenerCalls(tl, true, true, false, false, true, true);
    postConditions();
}

@("TransactionSupportTests.rollbackOnlyWithoutExistingTransaction")
unittest
{
    auto tm = new TestTransactionManager(false, true);
    auto tl = new TestTransactionExecutionListener;
    tm.addListener(tl);
    auto status = tm.getTransaction(null);
    status.setRollbackOnly();
    tm.commit(status);
    managerCalls(tm, true, false, true, false);
    listenerCalls(tl, true, true, false, false, true, true);
    postConditions();
}

@("TransactionSupportTests.commitWithExistingTransaction")
unittest
{
    auto tm = new TestTransactionManager(true, true);
    auto tl = new TestTransactionExecutionListener;
    tm.addListener(tl);
    auto status = tm.getTransaction(null);
    tm.commit(status);
    managerCalls(tm, false, false, false, false);
    listenerCalls(tl, false, false, false, false, false, false);
    postConditions();
}

@("TransactionSupportTests.rollbackWithExistingTransaction")
unittest
{
    auto tm = new TestTransactionManager(true, true);
    auto tl = new TestTransactionExecutionListener;
    tm.addListener(tl);
    auto status = tm.getTransaction(null);
    tm.rollback(status);
    managerCalls(tm, false, false, false, true);
    listenerCalls(tl, false, false, false, false, false, false);
    postConditions();
}

@("TransactionSupportTests.rollbackOnlyWithExistingTransaction")
unittest
{
    auto tm = new TestTransactionManager(true, true);
    auto tl = new TestTransactionExecutionListener;
    tm.addListener(tl);
    auto status = tm.getTransaction(null);
    status.setRollbackOnly();
    tm.commit(status);
    managerCalls(tm, false, false, false, true);
    listenerCalls(tl, false, false, false, false, false, false);
    postConditions();
}

deprecated private final class EmptyCallback : TransactionCallbackWithoutResult
{
    override protected void doInTransactionWithoutResult(TransactionStatus)
    {
    }
}

deprecated private final class ThrowingCallback : TransactionCallbackWithoutResult
{
    RuntimeException ex;

    this(RuntimeException ex)
    {
        this.ex = ex;
    }

    override protected void doInTransactionWithoutResult(TransactionStatus)
    {
        throw ex;
    }
}

@("TransactionSupportTests.transactionTemplate")
deprecated unittest
{
    auto tm = new TestTransactionManager(false, true);
    auto template_ = new TransactionTemplate(tm);
    template_.execute!Object(new EmptyCallback);
    managerCalls(tm, true, true, false, false);
    postConditions();
}

@("TransactionSupportTests.transactionTemplateWithCallbackPreference")
deprecated unittest
{
    auto ptm = new MockCallbackPreferringTransactionManager;
    auto template_ = new TransactionTemplate(ptm);
    template_.execute!Object(new EmptyCallback);
    assert(ptm.getDefinition() is template_);
    assert(!ptm.getStatus().isRollbackOnly());
    postConditions();
}

@("TransactionSupportTests.transactionTemplateWithException")
deprecated unittest
{
    auto tm = new TestTransactionManager(false, true);
    auto template_ = new TransactionTemplate(tm);
    auto ex = new RuntimeException("Some application exception");
    try
    {
        template_.execute!Object(new ThrowingCallback(ex));
        assert(false, "expected RuntimeException");
    }
    catch (RuntimeException caught)
        assert(caught is ex);
    managerCalls(tm, true, false, true, false);
    postConditions();
}

private final class RollbackFailingManager : TestTransactionManager
{
    TransactionSystemException tex;

    this(TransactionSystemException tex)
    {
        super(false, true);
        this.tex = tex;
    }

    override protected void doRollback(DefaultTransactionStatus status)
    {
        super.doRollback(status);
        throw tex;
    }
}

@("TransactionSupportTests.transactionTemplateWithRollbackException")
unittest
{
    auto tex = new TransactionSystemException("system exception");
    auto tm = new RollbackFailingManager(tex);
    auto template_ = new TransactionTemplate(tm);
    auto ex = new RuntimeException("Some application exception");
    try
    {
        template_.executeWithoutResult((TransactionStatus) { throw ex; });
        assert(false, "expected TransactionSystemException");
    }
    catch (RuntimeException caught)
        assert(caught is tex);
    assert(tex.getApplicationException() is ex);
    managerCalls(tm, true, false, true, false);
    postConditions();
}

@("TransactionSupportTests.transactionTemplateWithError")
@system unittest
{
    import std.exception : assertThrown;

    // A D Error is not caught by the template, but still rolls the transaction back on its way out.
    auto tm = new TestTransactionManager(false, true);
    auto template_ = new TransactionTemplate(tm);
    assertThrown!Error(template_.executeWithoutResult((TransactionStatus) @trusted {
            throw new Error("Some application error");
        }));
    managerCalls(tm, true, false, true, false);
    postConditions();
}

@("TransactionSupportTests.transactionTemplateEquality")
unittest
{
    auto tm1 = new TestTransactionManager(false, true);
    auto tm2 = new TestTransactionManager(false, true);
    auto template1 = new TransactionTemplate(tm1);
    auto template2 = new TransactionTemplate(tm2);
    auto template3 = new TransactionTemplate(tm2);
    assert(template2 != template1);
    assert(template3 != template1);
    assert(template3 == template2);
    postConditions();
}

// AbstractPlatformTransactionManagerConfigurationTests

private enum string[int] synchronizationConstants = [
    AbstractPlatformTransactionManager.SYNCHRONIZATION_ALWAYS: "SYNCHRONIZATION_ALWAYS",
    AbstractPlatformTransactionManager.SYNCHRONIZATION_ON_ACTUAL_TRANSACTION: "SYNCHRONIZATION_ON_ACTUAL_TRANSACTION",
    AbstractPlatformTransactionManager.SYNCHRONIZATION_NEVER: "SYNCHRONIZATION_NEVER",
];

@("TransactionSupportTests.AbstractPlatformTransactionManagerConfigurationTests."
        ~ "setTransactionSynchronizationNameToUnsupportedValues")
unittest
{
    auto tm = new TestTransactionManager(false, true);
    throwsIllegalArgument(() { tm.setTransactionSynchronizationName(null); });
    throwsIllegalArgument(() { tm.setTransactionSynchronizationName("   "); });
    throwsIllegalArgument(() { tm.setTransactionSynchronizationName("bogus"); });
}

@("TransactionSupportTests.AbstractPlatformTransactionManagerConfigurationTests."
        ~ "setTransactionSynchronizationNameToAllSupportedValues")
unittest
{
    // Java reflects over the public constants; D lists them.
    auto tm = new TestTransactionManager(false, true);
    bool[int] uniqueValues;
    foreach (expected, name; synchronizationConstants)
    {
        tm.setTransactionSynchronizationName(name);
        assert(tm.getTransactionSynchronization() == expected);
        uniqueValues[tm.getTransactionSynchronization()] = true;
    }
    assert(uniqueValues.length == 3);
}

@("TransactionSupportTests.AbstractPlatformTransactionManagerConfigurationTests." ~ "setTransactionSynchronization")
unittest
{
    auto tm = new TestTransactionManager(false, true);
    tm.setTransactionSynchronization(AbstractPlatformTransactionManager.SYNCHRONIZATION_ON_ACTUAL_TRANSACTION);
    assert(tm.getTransactionSynchronization() == AbstractPlatformTransactionManager
            .SYNCHRONIZATION_ON_ACTUAL_TRANSACTION);
}

// TransactionTemplateConfigurationTests

private immutable string[] propagationConstantNames = [
    "PROPAGATION_REQUIRED", "PROPAGATION_SUPPORTS", "PROPAGATION_MANDATORY",
    "PROPAGATION_REQUIRES_NEW", "PROPAGATION_NOT_SUPPORTED", "PROPAGATION_NEVER", "PROPAGATION_NESTED"
];
private immutable int[string] isolationConstantValues;

shared static this()
{
    isolationConstantValues = [
        "ISOLATION_DEFAULT": TransactionDefinition.ISOLATION_DEFAULT,
        "ISOLATION_READ_UNCOMMITTED": TransactionDefinition.ISOLATION_READ_UNCOMMITTED,
        "ISOLATION_READ_COMMITTED": TransactionDefinition.ISOLATION_READ_COMMITTED,
        "ISOLATION_REPEATABLE_READ": TransactionDefinition.ISOLATION_REPEATABLE_READ,
        "ISOLATION_SERIALIZABLE": TransactionDefinition.ISOLATION_SERIALIZABLE,
    ];
}

@("TransactionSupportTests.TransactionTemplateConfigurationTests." ~ "setTransactionManager")
unittest
{
    auto template_ = new TransactionTemplate;
    auto tm = new TestTransactionManager(false, true);
    template_.setTransactionManager(tm);
    assert(template_.getTransactionManager() is tm, "correct transaction manager set");
}

@("TransactionSupportTests.TransactionTemplateConfigurationTests." ~ "setPropagationBehaviorNameToUnsupportedValues")
unittest
{
    auto template_ = new TransactionTemplate;
    throwsIllegalArgument(() { template_.setPropagationBehaviorName(null); });
    throwsIllegalArgument(() { template_.setPropagationBehaviorName("   "); });
    throwsIllegalArgument(() { template_.setPropagationBehaviorName("bogus"); });
    throwsIllegalArgument(() { template_.setPropagationBehaviorName("ISOLATION_SERIALIZABLE"); });
}

@("TransactionSupportTests.TransactionTemplateConfigurationTests." ~ "setPropagationBehaviorNameToAllSupportedValues")
unittest
{
    auto template_ = new TransactionTemplate;
    bool[int] uniqueValues;
    foreach (expected, name; propagationConstantNames)
    {
        template_.setPropagationBehaviorName(name);
        assert(template_.getPropagationBehavior() == expected);
        uniqueValues[template_.getPropagationBehavior()] = true;
    }
    assert(uniqueValues.length == propagationConstantNames.length);
}

@("TransactionSupportTests.TransactionTemplateConfigurationTests." ~ "setPropagationBehavior")
unittest
{
    auto template_ = new TransactionTemplate;
    throwsIllegalArgument(() { template_.setPropagationBehavior(999); });
    throwsIllegalArgument(() {
        template_.setPropagationBehavior(TransactionDefinition.ISOLATION_SERIALIZABLE);
    });
    template_.setPropagationBehavior(TransactionDefinition.PROPAGATION_MANDATORY);
    assert(template_.getPropagationBehavior() == TransactionDefinition.PROPAGATION_MANDATORY);
}

@("TransactionSupportTests.TransactionTemplateConfigurationTests." ~ "setIsolationLevelNameToUnsupportedValues")
unittest
{
    auto template_ = new TransactionTemplate;
    throwsIllegalArgument(() { template_.setIsolationLevelName(null); });
    throwsIllegalArgument(() { template_.setIsolationLevelName("   "); });
    throwsIllegalArgument(() { template_.setIsolationLevelName("bogus"); });
    throwsIllegalArgument(() { template_.setIsolationLevelName("PROPAGATION_MANDATORY"); });
}

@("TransactionSupportTests.TransactionTemplateConfigurationTests." ~ "setIsolationLevelNameToAllSupportedValues")
unittest
{
    auto template_ = new TransactionTemplate;
    bool[int] uniqueValues;
    foreach (name, expected; isolationConstantValues)
    {
        template_.setIsolationLevelName(name);
        assert(template_.getIsolationLevel() == expected);
        uniqueValues[template_.getIsolationLevel()] = true;
    }
    assert(uniqueValues.length == isolationConstantValues.length);
}

@("TransactionSupportTests.TransactionTemplateConfigurationTests." ~ "setIsolationLevel")
unittest
{
    auto template_ = new TransactionTemplate;
    throwsIllegalArgument(() { template_.setIsolationLevel(999); });
    template_.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
    assert(template_.getIsolationLevel() == TransactionDefinition.ISOLATION_REPEATABLE_READ);
}

private final class DescribedTemplate : TransactionTemplate
{
    string description()
    {
        return getDefinitionDescription();
    }
}

@("TransactionSupportTests.TransactionTemplateConfigurationTests." ~ "getDefinitionDescription")
unittest
{
    auto template_ = new DescribedTemplate;
    assert(template_.description() == "PROPAGATION_REQUIRED,ISOLATION_DEFAULT");
    template_.setPropagationBehavior(TransactionDefinition.PROPAGATION_MANDATORY);
    template_.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
    template_.setReadOnly(true);
    template_.setTimeout(42);
    assert(template_.description() == "PROPAGATION_MANDATORY,ISOLATION_REPEATABLE_READ,timeout_42,readOnly");
}
