module flint.transaction.synchronization_manager_test;

import flint.conc : Deadline;
import flint.engine.reactor : Reactor, ReactorOptions, TaskContext, TaskDelegate;
import flint.java.lang : IllegalStateException;
import flint.transaction.support;

@safe:

private final class Key
{
}

private final class Holder : ResourceHolderSupport
{
}

private final class Log
{
    string[] entries;
}

private final class Recorder : TransactionSynchronization
{
    string name;
    int order;
    Log log;

    this(string name, int order, Log log)
    {
        this.name = name;
        this.order = order;
        this.log = log;
    }

    override int getOrder()
    {
        return order;
    }

    override void afterCompletion(int status)
    {
        log.entries ~= name;
    }
}

@("resources bind, unbind and refuse double binding; a void holder reads as unbound")
unittest
{
    auto key = new Key;
    auto holder = new Holder;
    assert(!TransactionSynchronizationManager.hasResource(key));
    TransactionSynchronizationManager.bindResource(key, holder);
    assert(TransactionSynchronizationManager.getResource(key) is holder);
    // As in Java, the refused binding has already replaced the value when the exception is thrown.
    auto replacement = new Holder;
    try
    {
        TransactionSynchronizationManager.bindResource(key, replacement);
        assert(false, "expected IllegalStateException");
    }
    catch (IllegalStateException)
    {
    }
    assert(TransactionSynchronizationManager.unbindResource(key) is replacement);
    assert(TransactionSynchronizationManager.unbindResourceIfPossible(key) is null);
    try
    {
        TransactionSynchronizationManager.unbindResource(key);
        assert(false, "expected IllegalStateException");
    }
    catch (IllegalStateException)
    {
    }

    TransactionSynchronizationManager.bindResource(key, holder);
    holder.unbound();
    assert(TransactionSynchronizationManager.getResource(key) is null, "a void holder is removed on access");
    assert(TransactionSynchronizationManager.getResourceMap().length == 0);
}

@("synchronizations run in getOrder order, registration order breaking ties, and clear resets the state")
unittest
{
    auto log = new Log;
    TransactionSynchronizationManager.initSynchronization();
    TransactionSynchronizationManager.registerSynchronization(new Recorder("late", 10, log));
    auto early = new Recorder("early", -5, log);
    TransactionSynchronizationManager.registerSynchronization(early);
    TransactionSynchronizationManager.registerSynchronization(early);
    TransactionSynchronizationManager.registerSynchronization(new Recorder("also-late", 10, log));
    TransactionSynchronizationManager.setCurrentTransactionName("checkout");
    TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
    TransactionSynchronizationManager.setActualTransactionActive(true);

    assert(TransactionSynchronizationManager.getSynchronizations().size() == 3);
    TransactionSynchronizationUtils.triggerAfterCompletion(TransactionSynchronization.STATUS_COMMITTED);
    assert(log.entries == ["early", "late", "also-late"]);
    assert(TransactionSynchronizationManager.getCurrentTransactionName() == "checkout");
    assert(TransactionSynchronizationManager.isCurrentTransactionReadOnly());

    TransactionSynchronizationManager.clear();
    assert(!TransactionSynchronizationManager.isSynchronizationActive());
    assert(TransactionSynchronizationManager.getCurrentTransactionName() is null);
    assert(!TransactionSynchronizationManager.isActualTransactionActive());
    try
    {
        TransactionSynchronizationManager.getSynchronizations();
        assert(false, "expected IllegalStateException");
    }
    catch (IllegalStateException)
    {
    }
}

@("bindSynchronizedResource unbinds at completion and restores a previous value")
unittest
{
    auto key = new Key;
    auto first = new Holder;
    auto second = new Holder;
    TransactionSynchronizationManager.bindResource(key, first);
    TransactionSynchronizationManager.initSynchronization();
    TransactionSynchronizationManager.bindSynchronizedResource(key, second);
    assert(TransactionSynchronizationManager.getResource(key) is second);
    TransactionSynchronizationUtils.triggerAfterCompletion(TransactionSynchronization.STATUS_ROLLED_BACK);
    assert(TransactionSynchronizationManager.getResource(key) is first);
    TransactionSynchronizationManager.clearSynchronization();
    TransactionSynchronizationManager.unbindResource(key);
}

private enum tasks = 200;

private final class Interleaving
{
    Key[tasks] keys;
    Holder[tasks] holders;
    uint finished;
    uint mismatches;

    this()
    {
        foreach (index; 0 .. tasks)
        {
            keys[index] = new Key;
            holders[index] = new Holder;
        }
    }

    /// The task body: transaction calls may throw, a reactor task may not.
    void step() nothrow
    {
        try
            run();
        catch (Exception)
            ++mismatches;
    }

    void run()
    {
        auto owner = Reactor.current();
        const self = cast(size_t) owner.currentTask().value.requestId;
        // A new task sees no transaction state left by another.
        if (TransactionSynchronizationManager.isSynchronizationActive()
                || TransactionSynchronizationManager.getResourceMap().length != 0)
            ++mismatches;
        TransactionSynchronizationManager.initSynchronization();
        TransactionSynchronizationManager.bindResource(keys[self], holders[self]);
        TransactionSynchronizationManager.setCurrentTransactionName("tx-" ~ cast(char)('a' + self % 26));
        cast(void) owner.yieldUntil(Deadline.afterMillis(1));
        // Every other task bound its own key while this one was suspended.
        if (TransactionSynchronizationManager.getResourceMap().length != 1
                || TransactionSynchronizationManager.getResource(
                    keys[self]) !is holders[self]
                || TransactionSynchronizationManager.getCurrentTransactionName() != "tx-" ~ cast(char)('a' + self % 26))
            ++mismatches;
        foreach (other; 0 .. tasks)
            if (other != self && TransactionSynchronizationManager.hasResource(keys[other]))
                ++mismatches;
        TransactionSynchronizationManager.unbindResource(keys[self]);
        TransactionSynchronizationManager.clear();
        if (++finished == tasks)
            owner.stop();
    }
}

@("TransactionSynchronizationManager keeps each interleaved reactor fiber's transaction state apart")
@system unittest
{
    ReactorOptions options;
    options.cores = 1;
    options.fiberPoolSize = tasks;
    options.mailboxCapacity = tasks;
    auto owner = Reactor.create(options);
    assert(owner.ok);
    auto fixture = new Interleaving;
    // Spring-style code allocates and throws, so the test adds the reactor's @nogc to its task delegate.
    auto task = cast(TaskDelegate)&fixture.step;
    foreach (index; 0 .. tasks)
        assert(owner.value.postStartup(0, task, TaskContext(index)).code == 0);
    assert(owner.value.run().code == 0);
    assert(fixture.finished == tasks);
    assert(fixture.mismatches == 0);
    // The test thread never ran a task: its own state is untouched.
    assert(!TransactionSynchronizationManager.isSynchronizationActive());
}
