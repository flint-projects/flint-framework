module flint.transaction.transaction_core_test;

import flint.java.lang : IllegalStateException, RuntimeException, UnsupportedOperationException;
import flint.java.util : ArrayList, Collection;
import flint.transaction;
import flint.transaction.annotation : Isolation, Propagation, value;

@safe:

@("TransactionDefinition.withDefaults and the Defaults mixin give Spring's defaults")
unittest
{
    auto definition = TransactionDefinition.withDefaults();
    assert(definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);
    assert(definition.getIsolationLevel() == TransactionDefinition.ISOLATION_DEFAULT);
    assert(definition.getTimeout() == TransactionDefinition.TIMEOUT_DEFAULT);
    assert(!definition.isReadOnly() && definition.getName() is null);
}

private final class Execution : TransactionStatus
{
    mixin TransactionStatus.Defaults;

    Object createSavepoint()
    {
        return null;
    }

    void rollbackToSavepoint(Object)
    {
    }

    void releaseSavepoint(Object)
    {
    }
}

@("TransactionStatus defaults: a new, unnested, non-rollback-only transaction without savepoints")
unittest
{
    TransactionStatus status = new Execution;
    assert(status.getTransactionName() == "" && status.hasTransaction() && status.isNewTransaction());
    assert(!status.isNested() && !status.isReadOnly() && !status.isRollbackOnly() && !status.isCompleted());
    assert(!status.hasSavepoint());
    status.flush();
    try
    {
        status.setRollbackOnly();
        assert(false, "expected UnsupportedOperationException");
    }
    catch (UnsupportedOperationException ex)
        assert(ex.getMessage() == "setRollbackOnly not supported");
}

private final class Listener : TransactionExecutionListener
{
    int begins;

    override void afterBegin(TransactionExecution transaction, Throwable beginFailure)
    {
        ++begins;
    }
}

private final class Manager : ConfigurableTransactionManager
{
    mixin ConfigurableTransactionManager.Defaults;
    private Collection!TransactionExecutionListener listeners;

    this()
    {
        listeners = new ArrayList!TransactionExecutionListener;
    }

    void setTransactionExecutionListeners(Collection!TransactionExecutionListener listeners)
    {
        this.listeners = listeners;
    }

    Collection!TransactionExecutionListener getTransactionExecutionListeners()
    {
        return listeners;
    }
}

@("listeners override only what they need, and addListener registers them")
unittest
{
    auto listener = new Listener;
    listener.beforeBegin(null);
    listener.afterBegin(null, null);
    assert(listener.begins == 1);
    auto manager = new Manager;
    manager.addListener(listener);
    assert(manager.getTransactionExecutionListeners().size() == 1);
}

@("the propagation and isolation enums keep the TransactionDefinition constants")
unittest
{
    static assert(Propagation.REQUIRED.value() == TransactionDefinition.PROPAGATION_REQUIRED);
    static assert(Propagation.SUPPORTS.value() == TransactionDefinition.PROPAGATION_SUPPORTS);
    static assert(Propagation.MANDATORY.value() == TransactionDefinition.PROPAGATION_MANDATORY);
    static assert(Propagation.REQUIRES_NEW.value() == TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    static assert(Propagation.NOT_SUPPORTED.value() == TransactionDefinition.PROPAGATION_NOT_SUPPORTED);
    static assert(Propagation.NEVER.value() == TransactionDefinition.PROPAGATION_NEVER);
    static assert(Propagation.NESTED.value() == TransactionDefinition.PROPAGATION_NESTED);
    static assert(Isolation.DEFAULT.value() == TransactionDefinition.ISOLATION_DEFAULT);
    static assert(Isolation.READ_UNCOMMITTED.value() == TransactionDefinition.ISOLATION_READ_UNCOMMITTED);
    static assert(Isolation.READ_COMMITTED.value() == TransactionDefinition.ISOLATION_READ_COMMITTED);
    static assert(Isolation.REPEATABLE_READ.value() == TransactionDefinition.ISOLATION_REPEATABLE_READ);
    static assert(Isolation.SERIALIZABLE.value() == TransactionDefinition.ISOLATION_SERIALIZABLE);
}

@("transaction exceptions keep Spring's hierarchy, sizes and states")
unittest
{
    static assert(is(IllegalTransactionStateException : TransactionUsageException));
    static assert(is(NestedTransactionNotSupportedException : CannotCreateTransactionException));
    static assert(is(TransactionSuspensionNotSupportedException : CannotCreateTransactionException));
    static assert(is(TransactionUsageException : TransactionException));
    static assert(__traits(isAbstractClass, TransactionException));

    assert(new InvalidTimeoutException("bad timeout", -5).getTimeout() == -5);
    auto heuristic = new HeuristicCompletionException(HeuristicCompletionException.STATE_MIXED, null);
    assert(heuristic.getMessage() == "Heuristic completion: outcome state is mixed");
    assert(heuristic.getOutcomeState() == HeuristicCompletionException.STATE_MIXED);
    assert(HeuristicCompletionException.getStateString(42) == "unknown");
}

@("TransactionSystemException keeps the application exception that a rollback failure overrode")
unittest
{
    auto rollbackFailure = new IllegalStateException("connection lost");
    auto system = new TransactionSystemException("Could not roll back", rollbackFailure);
    assert(system.getOriginalException() is rollbackFailure);
    auto application = new RuntimeException("application failure");
    system.initApplicationException(application);
    assert(system.getApplicationException() is application && system.getOriginalException() is application);
    assert(system.contains!RuntimeException() && system.contains!IllegalStateException());
    assert(system.contains(typeid(RuntimeException)));
    try
    {
        system.initApplicationException(new RuntimeException("second"));
        assert(false, "expected IllegalStateException");
    }
    catch (IllegalStateException ex)
        assert(ex.getMessage() == "Already holding an application exception: flint.java.lang.RuntimeException: "
                ~ "application failure");
}
