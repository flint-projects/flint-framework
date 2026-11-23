// Ported from spring-framework v7.1.0: spring-tx/src/main/java/org/springframework/transaction/support/*.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.

/++
`org.springframework.transaction.support`: the machinery behind every Spring transaction manager. It holds
`AbstractPlatformTransactionManager` with its propagation workflow, `TransactionTemplate`,
`TransactionSynchronizationManager`, resource holders and transaction statuses (ADR-030).

$(UL
    $(LI `TransactionSynchronizationManager` keeps its state in a `FiberLocal`, so a request's transaction follows
        its task fiber and never another task sharing the worker thread. Off a fiber the state is per thread, as in
        Java (ADR-030 section 4).)
    $(LI Generic interface methods (`TransactionOperations.execute`) are a `final` template over an erased virtual
        method taking a delegate (R9), because D interfaces cannot have virtual templates.)
    $(LI `TransactionSynchronization` is implemented selectively, so it is an abstract class (deviation D-3). It
        declares `getOrder` itself until `flint.core.Ordered` lands.)
    $(LI A rollback on failure covers `Exception`s. D `Error`s are unrecoverable and skip it.)
    $(LI Logging goes through `flint.slf4j`, the SLF4J API that Spring's commons-logging bridge would reach.)
    $(LI `ResourceHolderSupport` keeps its deadline as epoch milliseconds, because `flint.java.util` has no
        `Date`.)
    $(LI `SimpleTransactionScope` and `TransactionSynchronizationAdapter` arrive with the bean scopes they need.)
)
+/
module flint.transaction.support;

import flint.engine.aot.objects : objectEquals, objectToHash, objectToString;
import flint.engine.reactor : FiberLocal;
import flint.java.lang : IllegalArgumentException, IllegalStateException, RuntimeException,
    javaToString, stringHashCode;
import flint.java.util : ArrayList, Collection, Collections, List;
import flint.slf4j : Logger, LoggerFactory;
import flint.transaction : ConfigurableTransactionManager, IllegalTransactionStateException,
    InvalidTimeoutException, NestedTransactionNotSupportedException,
    PlatformTransactionManager, SavepointManager, TransactionDefinition,
    TransactionException,
    TransactionExecutionListener,
    TransactionStatus,
    TransactionSuspensionNotSupportedException,
    TransactionSystemException, TransactionTimedOutException, TransactionUsageException, UnexpectedRollbackException;
import std.typecons : Nullable;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Synchronization

/++
Interface for transaction synchronization callbacks, invoked by `AbstractPlatformTransactionManager`. Every callback
does nothing by default (deviation D-3: an abstract class); an implementation overrides what it needs.
+/
abstract class TransactionSynchronization
{
    /// Completion status in case of proper commit.
    enum int STATUS_COMMITTED = 0;
    /// Completion status in case of proper rollback.
    enum int STATUS_ROLLED_BACK = 1;
    /// Completion status in case of heuristic mixed completion or system errors.
    enum int STATUS_UNKNOWN = 2;

    /// Useful constant for the highest precedence value (`Ordered.HIGHEST_PRECEDENCE`).
    enum int HIGHEST_PRECEDENCE = int.min;
    /// Useful constant for the lowest precedence value (`Ordered.LOWEST_PRECEDENCE`).
    enum int LOWEST_PRECEDENCE = int.max;

    /// The execution order of this synchronization: lower values run first. Default: `LOWEST_PRECEDENCE`.
    int getOrder()
    {
        return LOWEST_PRECEDENCE;
    }

    /// Suspend this synchronization: unbind resources from `TransactionSynchronizationManager` if managing any.
    void suspend()
    {
    }

    /// Resume this synchronization: rebind resources to `TransactionSynchronizationManager` if managing any.
    void resume()
    {
    }

    /// Flush the underlying session to the datastore, if applicable.
    void flush()
    {
    }

    /// Invoked on creation of a new savepoint, either when a nested transaction is started or a savepoint is
    /// created manually through `TransactionStatus`.
    void savepoint(Object)
    {
    }

    /// Invoked in case of a rollback to the previously created savepoint.
    void savepointRollback(Object)
    {
    }

    /// Invoked before transaction commit (before `beforeCompletion`). An exception here makes the transaction roll
    /// back. `readOnly` is whether the transaction is defined as read-only.
    void beforeCommit(bool)
    {
    }

    /// Invoked before transaction commit or rollback, before `afterCommit` and `afterCompletion`.
    void beforeCompletion()
    {
    }

    /// Invoked after transaction commit; the transaction is already committed.
    void afterCommit()
    {
    }

    /// Invoked after transaction commit or rollback, with one of the `STATUS_` constants.
    void afterCompletion(int)
    {
    }
}

/// Generic interface to be implemented by resource holders. Allows Spring's transaction infrastructure to
/// introspect and reset the holder when necessary.
interface ResourceHolder
{
    /// Reset the transactional state of this holder.
    void reset();

    /// Notify this holder that it has been unbound from transaction synchronization.
    void unbound();

    /// Determine whether this holder is considered as 'void', that is, as a leftover from a previous thread.
    bool isVoid();
}

/// The per-fiber state of `TransactionSynchronizationManager`.
private final class TransactionState
{
    Object[Object] resources;
    TransactionSynchronization[] synchronizations;
    bool synchronizationActive;
    string currentTransactionName;
    bool currentTransactionReadOnly;
    Nullable!int currentTransactionIsolationLevel;
    bool actualTransactionActive;

    bool empty() const pure nothrow @nogc
    {
        return resources.length == 0 && !synchronizationActive && currentTransactionName is null
            && !currentTransactionReadOnly && currentTransactionIsolationLevel.isNull && !actualTransactionActive;
    }
}

private shared FiberLocal!TransactionState transactionState;

/++
Central delegate that manages resources and transaction synchronizations per task, as Java's does per thread. Used by
resource management code but not by typical application code.

Resource management code checks for a bound resource, such as a JDBC connection, with `getResource`. Transaction
synchronization must be activated and deactivated by a transaction manager with `initSynchronization` and
`clearSynchronization`; `AbstractPlatformTransactionManager` does this automatically.
+/
abstract class TransactionSynchronizationManager
{
    private static TransactionState state(bool create)
    {
        auto current = transactionState.get();
        if (current is null && create)
        {
            current = new TransactionState;
            const stored = transactionState.set(current);
            if (stored.code != 0)
                throw new IllegalStateException("Could not store the transaction state: " ~ stored.message);
        }
        return current;
    }

    private static void release(TransactionState current)
    {
        if (current !is null && current.empty)
            transactionState.remove();
    }

    // -----------------------------------------------------------------------------------------------------------
    // Management of transaction-associated resource handles

    /// Return all resources that are bound to the current task, as a copy.
    static Object[Object] getResourceMap()
    {
        auto current = state(false);
        return current is null ? null : current.resources.dup;
    }

    /// Check if there is a resource for the given key bound to the current task.
    static bool hasResource(Object key)
    {
        return doGetResource(TransactionSynchronizationUtils.unwrapResourceIfNecessary(key)) !is null;
    }

    /// Retrieve a resource for the given key that is bound to the current task, or null.
    static Object getResource(Object key)
    {
        return doGetResource(TransactionSynchronizationUtils.unwrapResourceIfNecessary(key));
    }

    private static Object doGetResource(Object actualKey)
    {
        auto current = state(false);
        if (current is null)
            return null;
        auto found = actualKey in current.resources;
        if (found is null)
            return null;
        Object value = *found;
        // Transparently remove ResourceHolder that was marked as void...
        if (auto resourceHolder = cast(ResourceHolder) value)
        {
            if (resourceHolder.isVoid())
            {
                current.resources.remove(actualKey);
                release(current);
                value = null;
            }
        }
        return value;
    }

    /// Bind the given resource for the given key to the current task. Throws `IllegalStateException` if there is
    /// already a value bound.
    static void bindResource(Object key, Object value)
    {
        Object actualKey = TransactionSynchronizationUtils.unwrapResourceIfNecessary(key);
        Object oldValue = doBindResource(actualKey, value);
        if (oldValue !is null)
            throw new IllegalStateException("Already value [" ~ describe(
                    oldValue) ~ "] for key [" ~ describe(actualKey) ~ "] bound to thread");
    }

    /// Bind the given resource for the given key to the current task, synchronizing it with the current
    /// transaction for automatic unbinding after transaction completion. Throws `IllegalStateException` if
    /// transaction synchronization is not active.
    static void bindSynchronizedResource(Object key, Object value)
    {
        if (!isSynchronizationActive())
            throw new IllegalStateException("Transaction synchronization is not active");
        Object actualKey = TransactionSynchronizationUtils.unwrapResourceIfNecessary(key);
        Object oldValue = doBindResource(actualKey, value);
        registerSynchronization(new SynchronizedResource(actualKey, value, oldValue));
    }

    private static Object doBindResource(Object actualKey, Object value)
    {
        if (value is null)
            throw new IllegalArgumentException("Value must not be null");
        auto current = state(true);
        auto found = actualKey in current.resources;
        Object oldValue = found is null ? null : *found;
        current.resources[actualKey] = value;
        // Transparently suppress a ResourceHolder that was marked as void...
        if (auto resourceHolder = cast(ResourceHolder) oldValue)
        {
            if (resourceHolder.isVoid())
                oldValue = null;
        }
        return oldValue;
    }

    /// Unbind a resource for the given key from the current task. Throws `IllegalStateException` if there is no
    /// value bound.
    static Object unbindResource(Object key)
    {
        Object actualKey = TransactionSynchronizationUtils.unwrapResourceIfNecessary(key);
        Object value = doUnbindResource(actualKey);
        if (value is null)
            throw new IllegalStateException("No value for key [" ~ describe(actualKey) ~ "] bound to thread");
        return value;
    }

    /// Unbind a resource for the given key from the current task; the previously bound value, or null.
    static Object unbindResourceIfPossible(Object key)
    {
        return doUnbindResource(TransactionSynchronizationUtils.unwrapResourceIfNecessary(key));
    }

    private static Object doUnbindResource(Object actualKey)
    {
        auto current = state(false);
        if (current is null)
            return null;
        auto found = actualKey in current.resources;
        if (found is null)
            return null;
        Object value = *found;
        current.resources.remove(actualKey);
        release(current);
        // Transparently suppress a ResourceHolder that was marked as void...
        if (auto resourceHolder = cast(ResourceHolder) value)
        {
            if (resourceHolder.isVoid())
                value = null;
        }
        return value;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Management of transaction synchronizations

    /// Return if transaction synchronization is active for the current task.
    static bool isSynchronizationActive()
    {
        auto current = state(false);
        return current !is null && current.synchronizationActive;
    }

    /// Activate transaction synchronization for the current task. Throws `IllegalStateException` if
    /// synchronization is already active.
    static void initSynchronization()
    {
        if (isSynchronizationActive())
            throw new IllegalStateException("Cannot activate transaction synchronization - already active");
        auto current = state(true);
        current.synchronizationActive = true;
        current.synchronizations = null;
    }

    /// Register a new transaction synchronization for the current task. Throws `IllegalStateException` if
    /// transaction synchronization is not active. Registering the same instance twice keeps one entry.
    static void registerSynchronization(TransactionSynchronization synchronization)
    {
        if (synchronization is null)
            throw new IllegalArgumentException("TransactionSynchronization must not be null");
        auto current = state(false);
        if (current is null || !current.synchronizationActive)
            throw new IllegalStateException("Transaction synchronization is not active");
        foreach (registered; current.synchronizations)
            if (registered is synchronization)
                return;
        current.synchronizations ~= synchronization;
    }

    /// Return an unmodifiable snapshot list of all registered synchronizations for the current task, sorted by
    /// `getOrder`. Throws `IllegalStateException` if synchronization is not active.
    static List!TransactionSynchronization getSynchronizations()
    {
        auto current = state(false);
        if (current is null || !current.synchronizationActive)
            throw new IllegalStateException("Transaction synchronization is not active");
        auto sorted = new ArrayList!TransactionSynchronization;
        foreach (synchronization; sortedByOrder(current.synchronizations))
            sorted.add(synchronization);
        return Collections.unmodifiableList!TransactionSynchronization(sorted);
    }

    /// Deactivate transaction synchronization for the current task. Throws `IllegalStateException` if
    /// synchronization is not active.
    static void clearSynchronization()
    {
        if (!isSynchronizationActive())
            throw new IllegalStateException("Cannot deactivate transaction synchronization - not active");
        auto current = state(false);
        current.synchronizationActive = false;
        current.synchronizations = null;
        release(current);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Exposure of transaction characteristics

    /// Expose the name of the current transaction, if any; null resets it.
    static void setCurrentTransactionName(string name)
    {
        if (name is null && state(false) is null)
            return;
        auto current = state(true);
        current.currentTransactionName = name;
        release(current);
    }

    /// Return the name of the current transaction, or null if none set.
    static string getCurrentTransactionName()
    {
        auto current = state(false);
        return current is null ? null : current.currentTransactionName;
    }

    /// Expose a read-only flag for the current transaction.
    static void setCurrentTransactionReadOnly(bool readOnly)
    {
        if (!readOnly && state(false) is null)
            return;
        auto current = state(true);
        current.currentTransactionReadOnly = readOnly;
        release(current);
    }

    /// Return whether the current transaction is marked as read-only.
    static bool isCurrentTransactionReadOnly()
    {
        auto current = state(false);
        return current !is null && current.currentTransactionReadOnly;
    }

    /// Expose an isolation level for the current transaction; null resets it.
    static void setCurrentTransactionIsolationLevel(Nullable!int isolationLevel)
    {
        if (isolationLevel.isNull && state(false) is null)
            return;
        auto current = state(true);
        current.currentTransactionIsolationLevel = isolationLevel;
        release(current);
    }

    /// Return the isolation level for the current transaction, if any.
    static Nullable!int getCurrentTransactionIsolationLevel()
    {
        auto current = state(false);
        return current is null ? Nullable!int.init : current.currentTransactionIsolationLevel;
    }

    /// Expose whether there currently is an actual transaction active.
    static void setActualTransactionActive(bool active)
    {
        if (!active && state(false) is null)
            return;
        auto current = state(true);
        current.actualTransactionActive = active;
        release(current);
    }

    /// Return whether there currently is an actual transaction active.
    static bool isActualTransactionActive()
    {
        auto current = state(false);
        return current !is null && current.actualTransactionActive;
    }

    /// Clear the entire transaction synchronization state for the current task: registered synchronizations and
    /// the transaction characteristics. Bound resources stay.
    static void clear()
    {
        auto current = state(false);
        if (current is null)
            return;
        current.synchronizationActive = false;
        current.synchronizations = null;
        current.currentTransactionName = null;
        current.currentTransactionReadOnly = false;
        current.currentTransactionIsolationLevel.nullify();
        current.actualTransactionActive = false;
        release(current);
    }
}

/// The synchronization `bindSynchronizedResource` registers.
private final class SynchronizedResource : TransactionSynchronization
{
    private Object actualKey;
    private Object value;
    private Object oldValue;

    this(Object actualKey, Object value, Object oldValue)
    {
        this.actualKey = actualKey;
        this.value = value;
        this.oldValue = oldValue;
    }

    override void suspend()
    {
        TransactionSynchronizationManager.doUnbindResource(actualKey);
    }

    override void resume()
    {
        auto existingValue = TransactionSynchronizationManager.doBindResource(actualKey, value);
        if (existingValue !is null)
            throw new IllegalStateException("Unexpected value [" ~ describe(
                    existingValue) ~ "] for key [" ~ describe(actualKey) ~ "] bound on resume");
    }

    override void afterCompletion(int)
    {
        TransactionSynchronizationManager.doUnbindResource(actualKey);
        if (oldValue !is null)
            TransactionSynchronizationManager.doBindResource(actualKey, oldValue);
    }
}

/// `OrderComparator.sort` for synchronizations: stable, lower orders first.
private TransactionSynchronization[] sortedByOrder(TransactionSynchronization[] synchronizations)
{
    auto sorted = synchronizations.dup;
    // Insertion sort keeps registration order for equal orders, as Java's stable List.sort does.
    foreach (i; 1 .. sorted.length)
    {
        auto item = sorted[i];
        const order = item.getOrder();
        size_t j = i;
        while (j > 0 && sorted[j - 1].getOrder() > order)
        {
            sorted[j] = sorted[j - 1];
            --j;
        }
        sorted[j] = item;
    }
    return sorted;
}

private string describe(Object value)
{
    if (value is null)
        return "null";
    if (auto throwable = cast(Throwable) value)
        return javaToString(throwable);
    return objectToString(value);
}

/// Utility methods for triggering specific `TransactionSynchronization` callback methods on all currently
/// registered synchronizations.
abstract class TransactionSynchronizationUtils
{
    /// Check whether the given resource transaction manager refers to the given (underlying) resource factory.
    static bool sameResourceFactory(ResourceTransactionManager tm, Object resourceFactory)
    {
        return objectEquals(unwrapResourceIfNecessary(tm.getResourceFactory()),
                unwrapResourceIfNecessary(resourceFactory));
    }

    /// Unwrap the given resource handle if necessary; otherwise return the given handle as-is. Throws
    /// `IllegalArgumentException` for null. Infrastructure and scoped proxies are unwrapped once
    /// `flint.core.InfrastructureProxy` and AOP's `ScopedObject` exist.
    static Object unwrapResourceIfNecessary(Object resource)
    {
        if (resource is null)
            throw new IllegalArgumentException("Resource must not be null");
        return resource;
    }

    /// Trigger `flush` callbacks on all currently registered synchronizations.
    static void triggerFlush()
    {
        if (!TransactionSynchronizationManager.isSynchronizationActive())
            return;
        foreach (synchronization; synchronizationArray())
            synchronization.flush();
    }

    package(flint.transaction) static void triggerSavepoint(Object savepoint)
    {
        if (!TransactionSynchronizationManager.isSynchronizationActive())
            return;
        foreach (synchronization; synchronizationArray())
            synchronization.savepoint(savepoint);
    }

    package(flint.transaction) static void triggerSavepointRollback(Object savepoint)
    {
        if (!TransactionSynchronizationManager.isSynchronizationActive())
            return;
        foreach (synchronization; synchronizationArray())
            synchronization.savepointRollback(savepoint);
    }

    /// Trigger `beforeCommit` callbacks on all currently registered synchronizations.
    static void triggerBeforeCommit(bool readOnly)
    {
        foreach (synchronization; synchronizationArray())
            synchronization.beforeCommit(readOnly);
    }

    /// Trigger `beforeCompletion` callbacks on all currently registered synchronizations; exceptions are logged.
    static void triggerBeforeCompletion()
    {
        foreach (synchronization; synchronizationArray())
        {
            try
                synchronization.beforeCompletion();
            catch (Exception ex)
                logger().error("TransactionSynchronization.beforeCompletion threw exception", ex);
        }
    }

    /// Trigger `afterCommit` callbacks on all currently registered synchronizations.
    static void triggerAfterCommit()
    {
        invokeAfterCommit(TransactionSynchronizationManager.getSynchronizations());
    }

    /// Actually invoke the `afterCommit` methods of the given synchronizations.
    static void invokeAfterCommit(List!TransactionSynchronization synchronizations)
    {
        if (synchronizations is null)
            return;
        foreach (synchronization; synchronizations.toArray())
            synchronization.afterCommit();
    }

    /// Trigger `afterCompletion` callbacks on all currently registered synchronizations.
    static void triggerAfterCompletion(int completionStatus)
    {
        invokeAfterCompletion(TransactionSynchronizationManager.getSynchronizations(), completionStatus);
    }

    /// Actually invoke the `afterCompletion` methods of the given synchronizations; exceptions are logged.
    static void invokeAfterCompletion(List!TransactionSynchronization synchronizations, int completionStatus)
    {
        if (synchronizations is null)
            return;
        foreach (synchronization; synchronizations.toArray())
        {
            try
                synchronization.afterCompletion(completionStatus);
            catch (Exception ex)
                logger().error("TransactionSynchronization.afterCompletion threw exception", ex);
        }
    }

    private static TransactionSynchronization[] synchronizationArray()
    {
        return TransactionSynchronizationManager.getSynchronizations().toArray();
    }

    private static Logger logger()
    {
        return LoggerFactory.getLogger("org.springframework.transaction.support.TransactionSynchronizationUtils");
    }
}

/// Convenient base class for resource holders. Features rollback-only support for participating transactions,
/// and can expire after a certain number of seconds or milliseconds in order to determine a transactional timeout.
abstract class ResourceHolderSupport : ResourceHolder
{
    private bool synchronizedWithTransaction;
    private bool rollbackOnly;
    private long deadline;
    private bool hasDeadline;
    private int referenceCount;
    private bool isVoid_;

    /// Mark the resource as synchronized with a transaction.
    void setSynchronizedWithTransaction(bool synchronizedWithTransaction)
    {
        this.synchronizedWithTransaction = synchronizedWithTransaction;
    }

    /// Return whether the resource is synchronized with a transaction.
    bool isSynchronizedWithTransaction()
    {
        return synchronizedWithTransaction;
    }

    /// Mark the resource transaction as rollback-only.
    void setRollbackOnly()
    {
        rollbackOnly = true;
    }

    /// Reset the rollback-only status for this resource transaction.
    void resetRollbackOnly()
    {
        rollbackOnly = false;
    }

    /// Return whether the resource transaction is marked as rollback-only.
    bool isRollbackOnly()
    {
        return rollbackOnly;
    }

    /// Set the timeout for this object in seconds.
    void setTimeoutInSeconds(int seconds)
    {
        setTimeoutInMillis(seconds * 1000L);
    }

    /// Set the timeout for this object in milliseconds.
    void setTimeoutInMillis(long millis)
    {
        deadline = currentTimeMillis() + millis;
        hasDeadline = true;
    }

    /// Return whether this object has an associated timeout.
    bool hasTimeout()
    {
        return hasDeadline;
    }

    /// Return the expiration deadline of this object, as epoch milliseconds (Java returns a `Date`), or 0 if none.
    long getDeadline()
    {
        return hasDeadline ? deadline : 0;
    }

    /// Return the time to live for this object in seconds, rounded up. Throws `TransactionTimedOutException` if
    /// the deadline has already been reached.
    int getTimeToLiveInSeconds()
    {
        const diff = cast(double) getTimeToLiveInMillis() / 1000;
        int secs = cast(int) diff;
        if (secs < diff)
            ++secs;
        checkTransactionTimeout(secs <= 0);
        return secs;
    }

    /// Return the time to live for this object in milliseconds. Throws `TransactionTimedOutException` if the
    /// deadline has already been reached, and `IllegalStateException` if no timeout is set.
    long getTimeToLiveInMillis()
    {
        if (!hasDeadline)
            throw new IllegalStateException("No timeout specified for this resource holder");
        const timeToLive = deadline - currentTimeMillis();
        checkTransactionTimeout(timeToLive <= 0);
        return timeToLive;
    }

    private void checkTransactionTimeout(bool deadlineReached)
    {
        if (deadlineReached)
        {
            setRollbackOnly();
            throw new TransactionTimedOutException("Transaction timed out: deadline was " ~ decimalText(deadline));
        }
    }

    /// Increase the reference count by one because the holder has been requested (a resource has been fetched).
    void requested()
    {
        ++referenceCount;
    }

    /// Decrease the reference count by one because the holder has been released.
    void released()
    {
        --referenceCount;
    }

    /// Return whether there are still open references to this holder.
    bool isOpen()
    {
        return referenceCount > 0;
    }

    /// Clear the transactional state of this resource holder.
    void clear()
    {
        synchronizedWithTransaction = false;
        rollbackOnly = false;
        hasDeadline = false;
        deadline = 0;
    }

    /// Reset this resource holder: transactional state as well as reference count.
    override void reset()
    {
        clear();
        referenceCount = 0;
    }

    /// Mark this holder void, as a leftover after unbinding.
    override void unbound()
    {
        isVoid_ = true;
    }

    /// Whether this holder is void.
    override bool isVoid()
    {
        return isVoid_;
    }
}

/// `System.currentTimeMillis()`.
private long currentTimeMillis()
{
    import std.datetime.systime : Clock;

    // Standard time counts hectonanoseconds from year 1; the Unix epoch is 621,355,968,000,000,000 of them later.
    return (Clock.currStdTime - 621_355_968_000_000_000L) / 10_000;
}

private string decimalText(long value)
{
    import std.conv : to;

    return value.to!string;
}

/++
`TransactionSynchronization` implementation that manages a `ResourceHolder` bound through
`TransactionSynchronizationManager`. `H` is the resource holder type and `K` the resource key type.
+/
abstract class ResourceHolderSynchronization(H : ResourceHolder, K) : TransactionSynchronization
{
    private H resourceHolder;
    private K resourceKey;
    private bool holderActive = true;

    /// Create a new `ResourceHolderSynchronization` for the given holder and its key.
    this(H resourceHolder, K resourceKey)
    {
        this.resourceHolder = resourceHolder;
        this.resourceKey = resourceKey;
    }

    override void suspend()
    {
        if (holderActive)
            TransactionSynchronizationManager.unbindResource(keyObject());
    }

    override void resume()
    {
        if (holderActive)
            TransactionSynchronizationManager.bindResource(keyObject(), resourceHolder);
    }

    override void flush()
    {
        flushResource(resourceHolder);
    }

    override void beforeCompletion()
    {
        if (shouldUnbindAtCompletion())
        {
            TransactionSynchronizationManager.unbindResource(keyObject());
            holderActive = false;
            if (shouldReleaseBeforeCompletion())
                releaseResource(resourceHolder, resourceKey);
        }
    }

    override void afterCommit()
    {
        if (!shouldReleaseBeforeCompletion())
            processResourceAfterCommit(resourceHolder);
    }

    override void afterCompletion(int status)
    {
        if (shouldUnbindAtCompletion())
        {
            bool releaseNecessary = false;
            if (holderActive)
            {
                // The resource holder might not be bound anymore, since afterCompletion might run elsewhere.
                holderActive = false;
                TransactionSynchronizationManager.unbindResourceIfPossible(keyObject());
                resourceHolder.unbound();
                releaseNecessary = true;
            }
            else
                releaseNecessary = shouldReleaseAfterCompletion(resourceHolder);
            if (releaseNecessary)
                releaseResource(resourceHolder, resourceKey);
        }
        else
        {
            // Probably a pre-bound resource...
            cleanupResource(resourceHolder, resourceKey, status == STATUS_COMMITTED);
        }
        resourceHolder.reset();
    }

    /// Return whether this holder should be unbound at completion (or should rather be left bound to the task
    /// after the transaction). Default: true.
    protected bool shouldUnbindAtCompletion()
    {
        return true;
    }

    /// Return whether this holder's resource should be released before transaction completion (true) or rather
    /// after transaction completion (false). Default: true.
    protected bool shouldReleaseBeforeCompletion()
    {
        return true;
    }

    /// Return whether this holder's resource should be released after transaction completion. Default:
    /// `!shouldReleaseBeforeCompletion()`.
    protected bool shouldReleaseAfterCompletion(H)
    {
        return !shouldReleaseBeforeCompletion();
    }

    /// Flush callback for the given resource holder.
    protected void flushResource(H)
    {
    }

    /// After-commit callback for the given resource holder. Only called when the resource hasn't been released
    /// yet (`shouldReleaseBeforeCompletion()` false).
    protected void processResourceAfterCommit(H)
    {
    }

    /// Release the given resource (after it has been unbound from the task).
    protected void releaseResource(H, K)
    {
    }

    /// Perform a cleanup on the given resource (which is left bound to the task).
    protected void cleanupResource(H, K, bool)
    {
    }

    private Object keyObject()
    {
        static if (is(K : Object))
            return resourceKey;
        else
            static assert(false, "ResourceHolderSynchronization keys are objects");
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Definitions and statuses

/++
Default implementation of the `TransactionDefinition` interface, offering bean-style configuration and sensible
default values (`PROPAGATION_REQUIRED`, `ISOLATION_DEFAULT`, `TIMEOUT_DEFAULT`, `readOnly = false`).
+/
class DefaultTransactionDefinition : TransactionDefinition
{
    import flint.java.lang : JavaObject;

    /// Prefix for the propagation constant names.
    enum string PREFIX_PROPAGATION = "PROPAGATION_";
    /// Prefix for the isolation constant names.
    enum string PREFIX_ISOLATION = "ISOLATION_";
    /// Prefix for transaction timeout values in description strings.
    enum string PREFIX_TIMEOUT = "timeout_";
    /// Marker for read-only transactions in description strings.
    enum string READ_ONLY_MARKER = "readOnly";

    private int propagationBehavior = PROPAGATION_REQUIRED;
    private int isolationLevel = ISOLATION_DEFAULT;
    private int timeout = TIMEOUT_DEFAULT;
    private bool readOnly;
    private string name;

    /// Create a new `DefaultTransactionDefinition` with default settings.
    this()
    {
    }

    /// Copy constructor.
    this(TransactionDefinition other)
    {
        propagationBehavior = other.getPropagationBehavior();
        isolationLevel = other.getIsolationLevel();
        timeout = other.getTimeout();
        readOnly = other.isReadOnly();
        name = other.getName();
    }

    /// Create a new `DefaultTransactionDefinition` with the given propagation behavior.
    this(int propagationBehavior)
    {
        this.propagationBehavior = propagationBehavior;
    }

    /// Set the propagation behavior by the name of the corresponding constant in `TransactionDefinition`, such as
    /// "PROPAGATION_REQUIRED". Throws `IllegalArgumentException` for an unknown name.
    final void setPropagationBehaviorName(string constantName)
    {
        if (!hasText(constantName))
            throw new IllegalArgumentException("'constantName' must not be null or blank");
        const behavior = propagationConstant(constantName);
        if (behavior == int.min)
            throw new IllegalArgumentException("Only propagation behavior constants allowed");
        propagationBehavior = behavior;
    }

    /// Set the propagation behavior, one of the `PROPAGATION_` constants. Throws `IllegalArgumentException` for
    /// any other value.
    final void setPropagationBehavior(int propagationBehavior)
    {
        if (propagationBehavior < PROPAGATION_REQUIRED || propagationBehavior > PROPAGATION_NESTED)
            throw new IllegalArgumentException("Only values of propagation constants allowed");
        this.propagationBehavior = propagationBehavior;
    }

    final override int getPropagationBehavior()
    {
        return propagationBehavior;
    }

    /// Set the isolation level by the name of the corresponding constant in `TransactionDefinition`, such as
    /// "ISOLATION_DEFAULT". Throws `IllegalArgumentException` for an unknown name.
    final void setIsolationLevelName(string constantName)
    {
        if (!hasText(constantName))
            throw new IllegalArgumentException("'constantName' must not be null or blank");
        const level = isolationConstant(constantName);
        if (level == int.min)
            throw new IllegalArgumentException("Only isolation constants allowed");
        isolationLevel = level;
    }

    /// Set the isolation level, one of the `ISOLATION_` constants. Throws `IllegalArgumentException` for any
    /// other value.
    final void setIsolationLevel(int isolationLevel)
    {
        if (isolationName(isolationLevel) is null)
            throw new IllegalArgumentException("Only values of isolation constants allowed");
        this.isolationLevel = isolationLevel;
    }

    final override int getIsolationLevel()
    {
        return isolationLevel;
    }

    /// Set the timeout to apply, as number of seconds; `TIMEOUT_DEFAULT` (-1) uses the transaction system's.
    final void setTimeout(int timeout)
    {
        if (timeout < TIMEOUT_DEFAULT)
            throw new IllegalArgumentException("Timeout must be a non-negative integer or TIMEOUT_DEFAULT");
        this.timeout = timeout;
    }

    final override int getTimeout()
    {
        return timeout;
    }

    /// Set whether to optimize as read-only transaction.
    final void setReadOnly(bool readOnly)
    {
        this.readOnly = readOnly;
    }

    final override bool isReadOnly()
    {
        return readOnly;
    }

    /// Set the name of this transaction.
    final void setName(string name)
    {
        this.name = name;
    }

    final override string getName()
    {
        return name;
    }

    /// This implementation compares the `toString()` results.
    bool equals(Object other)
    {
        if (other is this)
            return true;
        auto definition = cast(TransactionDefinition) other;
        return definition !is null && toString() == objectToString(other);
    }

    /// This implementation returns the hash code of the `toString()` result.
    int hashCode()
    {
        return stringHashCode(toString());
    }

    mixin JavaObject;

    /// Return an identifying description for this transaction definition, such as
    /// "PROPAGATION_REQUIRED,ISOLATION_DEFAULT,timeout_10,readOnly".
    override string toString()
    {
        return getDefinitionDescription();
    }

    /// Return an identifying description for this transaction definition.
    protected final string getDefinitionDescription()
    {
        auto result = getPropagationBehaviorName(propagationBehavior) ~ "," ~ getIsolationLevelName(isolationLevel);
        if (timeout != TIMEOUT_DEFAULT)
            result ~= "," ~ PREFIX_TIMEOUT ~ decimalText(timeout);
        if (readOnly)
            result ~= "," ~ READ_ONLY_MARKER;
        return result;
    }

    private static string getPropagationBehaviorName(int propagationBehavior)
    {
        if (propagationBehavior < PROPAGATION_REQUIRED || propagationBehavior > PROPAGATION_NESTED)
            throw new IllegalArgumentException("Unsupported propagation behavior: " ~ decimalText(propagationBehavior));
        return propagationNames[propagationBehavior];
    }

    package(flint.transaction) static string getIsolationLevelName(int isolationLevel)
    {
        auto found = isolationName(isolationLevel);
        if (found is null)
            throw new IllegalArgumentException("Unsupported isolation level: " ~ decimalText(isolationLevel));
        return found;
    }
}

private immutable string[] propagationNames = [
    "PROPAGATION_REQUIRED", "PROPAGATION_SUPPORTS", "PROPAGATION_MANDATORY",
    "PROPAGATION_REQUIRES_NEW", "PROPAGATION_NOT_SUPPORTED", "PROPAGATION_NEVER", "PROPAGATION_NESTED"
];

private int propagationConstant(string name)
{
    foreach (index, candidate; propagationNames)
        if (candidate == name)
            return cast(int) index;
    return int.min;
}

private string isolationName(int level)
{
    switch (level)
    {
    case TransactionDefinition.ISOLATION_DEFAULT:
        return "ISOLATION_DEFAULT";
    case TransactionDefinition.ISOLATION_READ_UNCOMMITTED:
        return "ISOLATION_READ_UNCOMMITTED";
    case TransactionDefinition.ISOLATION_READ_COMMITTED:
        return "ISOLATION_READ_COMMITTED";
    case TransactionDefinition.ISOLATION_REPEATABLE_READ:
        return "ISOLATION_REPEATABLE_READ";
    case TransactionDefinition.ISOLATION_SERIALIZABLE:
        return "ISOLATION_SERIALIZABLE";
    default:
        return null;
    }
}

private int isolationConstant(string name)
{
    foreach (level; [-1, 1, 2, 4, 8])
        if (isolationName(level) == name)
            return level;
    return int.min;
}

private bool hasText(string text)
{
    foreach (ch; text)
        if (ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r' && ch != '\f' && ch != '\v')
            return true;
    return false;
}

/// `TransactionDefinition` implementation that delegates all calls to a given target `TransactionDefinition`.
abstract class DelegatingTransactionDefinition : TransactionDefinition
{
    private TransactionDefinition targetDefinition;

    /// Create a `DelegatingTransactionDefinition` for the given target definition.
    this(TransactionDefinition targetDefinition)
    {
        if (targetDefinition is null)
            throw new IllegalArgumentException("Target definition must not be null");
        this.targetDefinition = targetDefinition;
    }

    override int getPropagationBehavior()
    {
        return targetDefinition.getPropagationBehavior();
    }

    override int getIsolationLevel()
    {
        return targetDefinition.getIsolationLevel();
    }

    override int getTimeout()
    {
        return targetDefinition.getTimeout();
    }

    override bool isReadOnly()
    {
        return targetDefinition.isReadOnly();
    }

    override string getName()
    {
        return targetDefinition.getName();
    }

    /// Delegates to the target definition.
    override bool opEquals(Object other)
    {
        return objectEquals(cast(Object) targetDefinition, other);
    }

    /// Delegates to the target definition.
    override size_t toHash() nothrow
    {
        return objectToHash(cast(Object) targetDefinition);
    }

    /// Delegates to the target definition.
    override string toString()
    {
        return objectToString(cast(Object) targetDefinition);
    }
}

/// Extended `TransactionDefinition` interface that indicates a resource transaction and in particular whether the
/// transactional resource is ready for local optimizations.
interface ResourceTransactionDefinition : TransactionDefinition
{
    /// Determine whether the transactional resource is ready for local optimizations.
    bool isLocalResource();
}

/// Interface to be implemented by transaction objects that are able to return an internal rollback-only marker,
/// typically from another transaction that has participated and marked it as rollback-only. Every method has a
/// default (`Defaults`). Java's `Flushable` supertype is dropped; `flush` stays.
interface SmartTransactionObject
{
    /// Return whether the transaction is internally marked as rollback-only. Default: false.
    bool isRollbackOnly();

    /// Flush the underlying sessions to the datastore, if applicable. Default: nothing.
    void flush();

    /// The Java default bodies.
    mixin template Defaults()
    {
        /// Default: false.
        bool isRollbackOnly()
        {
            return false;
        }

        /// Default: nothing.
        void flush()
        {
        }
    }
}

/++
Abstract base implementation of the `TransactionStatus` interface. Pre-implements the handling of local rollback-only
and completed flags, and delegation to an underlying `SavepointManager`; supports holding a savepoint.
+/
abstract class AbstractTransactionStatus : TransactionStatus
{
    private bool rollbackOnly;
    private bool completed;
    private Object savepoint_;

    /// Default: an empty string.
    string getTransactionName()
    {
        return "";
    }

    /// Default: true.
    bool hasTransaction()
    {
        return true;
    }

    /// Default: true.
    bool isNewTransaction()
    {
        return true;
    }

    /// Default: false.
    bool isNested()
    {
        return false;
    }

    /// Default: false.
    bool isReadOnly()
    {
        return false;
    }

    /// Default: nothing.
    void flush()
    {
    }

    /// Mark this transaction rollback-only. Throws `IllegalStateException` once completed.
    void setRollbackOnly()
    {
        if (completed)
            throw new IllegalStateException("Transaction completed");
        rollbackOnly = true;
    }

    /// Determine the rollback-only flag via checking both the local rollback-only flag of this
    /// `TransactionStatus` and the global rollback-only flag of the underlying transaction, if any.
    bool isRollbackOnly()
    {
        return isLocalRollbackOnly() || isGlobalRollbackOnly();
    }

    /// Determine the rollback-only flag via checking this `TransactionStatus`.
    bool isLocalRollbackOnly()
    {
        return rollbackOnly;
    }

    /// Template method for determining the global rollback-only flag of the underlying transaction. Default:
    /// false.
    bool isGlobalRollbackOnly()
    {
        return false;
    }

    /// Mark this transaction as completed, that is, committed or rolled back.
    void setCompleted()
    {
        completed = true;
    }

    /// Whether `setCompleted` was called.
    bool isCompleted()
    {
        return completed;
    }

    /// Whether a savepoint is held.
    bool hasSavepoint()
    {
        return savepoint_ !is null;
    }

    /// Set a savepoint for this transaction. Useful for `PROPAGATION_NESTED`.
    protected void setSavepoint(Object savepoint)
    {
        savepoint_ = savepoint;
    }

    /// Get the savepoint for this transaction, if any.
    protected Object getSavepoint()
    {
        return savepoint_;
    }

    /// Create a savepoint and hold it for the transaction.
    void createAndHoldSavepoint()
    {
        Object savepoint = getSavepointManager().createSavepoint();
        TransactionSynchronizationUtils.triggerSavepoint(savepoint);
        setSavepoint(savepoint);
    }

    /// Roll back to the savepoint that is held for the transaction and release the savepoint right afterwards.
    void rollbackToHeldSavepoint()
    {
        Object savepoint = getSavepoint();
        if (savepoint is null)
            throw new TransactionUsageException(
                    "Cannot roll back to savepoint - no savepoint associated with current transaction");
        TransactionSynchronizationUtils.triggerSavepointRollback(savepoint);
        getSavepointManager().rollbackToSavepoint(savepoint);
        getSavepointManager().releaseSavepoint(savepoint);
        setSavepoint(null);
    }

    /// Release the savepoint that is held for the transaction.
    void releaseHeldSavepoint()
    {
        Object savepoint = getSavepoint();
        if (savepoint is null)
            throw new TransactionUsageException(
                    "Cannot release savepoint - no savepoint associated with current transaction");
        getSavepointManager().releaseSavepoint(savepoint);
        setSavepoint(null);
    }

    /// This implementation delegates to a `SavepointManager` for the underlying transaction, if possible.
    Object createSavepoint()
    {
        Object savepoint = getSavepointManager().createSavepoint();
        TransactionSynchronizationUtils.triggerSavepoint(savepoint);
        return savepoint;
    }

    /// This implementation delegates to a `SavepointManager` for the underlying transaction, if possible.
    void rollbackToSavepoint(Object savepoint)
    {
        TransactionSynchronizationUtils.triggerSavepointRollback(savepoint);
        getSavepointManager().rollbackToSavepoint(savepoint);
    }

    /// This implementation delegates to a `SavepointManager` for the underlying transaction, if possible.
    void releaseSavepoint(Object savepoint)
    {
        getSavepointManager().releaseSavepoint(savepoint);
    }

    /// Return a `SavepointManager` for the underlying transaction, if possible. Default: throws
    /// `NestedTransactionNotSupportedException`.
    protected SavepointManager getSavepointManager()
    {
        throw new NestedTransactionNotSupportedException("This transaction does not support savepoints");
    }
}

/// Default implementation of the `TransactionStatus` interface, used by `AbstractPlatformTransactionManager`.
class DefaultTransactionStatus : AbstractTransactionStatus
{
    private string transactionName;
    private Object transaction;
    private bool newTransaction;
    private bool newSynchronization;
    private bool nested;
    private bool readOnly;
    private bool debug_;
    private Object suspendedResources;

    /// Create a new `DefaultTransactionStatus` instance.
    this(string transactionName, Object transaction, bool newTransaction, bool newSynchronization,
            bool nested, bool readOnly, bool debug_, Object suspendedResources)
    {
        this.transactionName = transactionName;
        this.transaction = transaction;
        this.newTransaction = newTransaction;
        this.newSynchronization = newSynchronization;
        this.nested = nested;
        this.readOnly = readOnly;
        this.debug_ = debug_;
        this.suspendedResources = suspendedResources;
    }

    override string getTransactionName()
    {
        return transactionName !is null ? transactionName : "";
    }

    /// Return the underlying transaction object. Throws `IllegalStateException` if none is active.
    Object getTransaction()
    {
        if (transaction is null)
            throw new IllegalStateException("No transaction active");
        return transaction;
    }

    override bool hasTransaction()
    {
        return transaction !is null;
    }

    override bool isNewTransaction()
    {
        return hasTransaction() && newTransaction;
    }

    /// Return if a new transaction synchronization has been opened for this transaction.
    bool isNewSynchronization()
    {
        return newSynchronization;
    }

    override bool isNested()
    {
        return nested;
    }

    override bool isReadOnly()
    {
        return readOnly;
    }

    /// Return whether the progress of this transaction is debugged.
    bool isDebug()
    {
        return debug_;
    }

    /// Return the holder for resources that have been suspended for this transaction, if any.
    Object getSuspendedResources()
    {
        return suspendedResources;
    }

    /// Determine the rollback-only flag via checking the transaction object, provided that the latter implements
    /// the `SmartTransactionObject` interface.
    override bool isGlobalRollbackOnly()
    {
        auto smartTransactionObject = cast(SmartTransactionObject) transaction;
        return smartTransactionObject !is null && smartTransactionObject.isRollbackOnly();
    }

    /// This implementation exposes the `SavepointManager` interface of the underlying transaction object, if any.
    override protected SavepointManager getSavepointManager()
    {
        auto savepointManager = cast(SavepointManager) transaction;
        if (savepointManager is null)
            throw new NestedTransactionNotSupportedException(
                    "Transaction object [" ~ describe(transaction) ~ "] does not support savepoints");
        return savepointManager;
    }

    /// Return whether the underlying transaction implements the `SavepointManager` interface.
    bool isTransactionSavepointManager()
    {
        return cast(SavepointManager) transaction !is null;
    }

    /// Delegate the flushing to the transaction object, provided that the latter implements the
    /// `SmartTransactionObject` interface.
    override void flush()
    {
        if (auto smartTransactionObject = cast(SmartTransactionObject) transaction)
            smartTransactionObject.flush();
    }
}

/// A simple `TransactionStatus` implementation. Derives from `AbstractTransactionStatus` and adds an explicit
/// "newTransaction" flag.
class SimpleTransactionStatus : AbstractTransactionStatus
{
    private bool newTransaction;

    /// Create a new `SimpleTransactionStatus` instance, indicating a new transaction.
    this()
    {
        this(true);
    }

    /// Create a new `SimpleTransactionStatus` instance.
    this(bool newTransaction)
    {
        this.newTransaction = newTransaction;
    }

    override bool isNewTransaction()
    {
        return newTransaction;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Programmatic transactions

/// Callback interface for transactional code (R9: `TransactionOperations` also takes a delegate).
interface TransactionCallback(T)
{
    /// Gets called by `TransactionTemplate.execute` within a transactional context. A runtime exception thrown
    /// here causes a rollback.
    T doInTransaction(TransactionStatus status);
}

/// Simple convenience class for `TransactionCallback` implementation. Allows for implementing a
/// `doInTransaction` version without result, without the need for a return statement. Deprecated since Spring
/// 7.0 in favor of `TransactionOperations.executeWithoutResult` with a delegate.
deprecated("since Spring 7.0") abstract class TransactionCallbackWithoutResult : TransactionCallback!Object
{
    /// Runs `doInTransactionWithoutResult` and returns null.
    final override Object doInTransaction(TransactionStatus status)
    {
        doInTransactionWithoutResult(status);
        return null;
    }

    /// Gets called by `TransactionTemplate.execute` within a transactional context.
    protected abstract void doInTransactionWithoutResult(TransactionStatus status);
}

/// The delegate form of a transaction callback: Java's `TransactionCallback<T>` lambda (R9).
alias TransactionDelegate(T) = T delegate(TransactionStatus) @safe;

/++
Interface specifying basic transaction execution operations. Implemented by `TransactionTemplate`.

D interfaces cannot hold virtual templates, so the virtual method is `executeWithoutResult` and `execute!T` is a
`final` template over it (R9).
+/
interface TransactionOperations
{
    /// Execute the action within a transaction. A runtime exception thrown by the action causes a rollback.
    void executeWithoutResult(scope void delegate(TransactionStatus) @safe action);

    /// Execute the action within a transaction and return its result.
    T execute(T)(scope TransactionDelegate!T action)
    {
        static if (is(T == void))
            executeWithoutResult((TransactionStatus status) @safe { action(status); });
        else
        {
            T result;
            executeWithoutResult((TransactionStatus status) @safe { result = action(status); });
            return result;
        }
    }

    /// ditto
    T execute(T)(TransactionCallback!T action)
    {
        return execute!T((TransactionStatus status) @safe => action.doInTransaction(status));
    }

    /// Return an implementation of `TransactionOperations` that executes a callback without an actual
    /// transaction.
    static TransactionOperations withoutTransaction()
    {
        return new WithoutTransactionOperations;
    }
}

/// A `TransactionOperations` implementation which executes a given callback without an actual transaction.
private final class WithoutTransactionOperations : TransactionOperations
{
    override void executeWithoutResult(scope void delegate(TransactionStatus) @safe action)
    {
        action(new SimpleTransactionStatus(false));
    }
}

/// Extension of the `PlatformTransactionManager` interface, exposing a method for executing a given callback
/// within a transaction. The virtual method takes a delegate; `execute!T` is the typed form (R9).
interface CallbackPreferringPlatformTransactionManager : PlatformTransactionManager
{
    /// Execute the action within a transaction; a null `definition` means the defaults.
    void execute(TransactionDefinition definition, scope void delegate(TransactionStatus) @safe action);

    /// Execute the callback within a transaction and return its result.
    T execute(T)(TransactionDefinition definition, scope TransactionDelegate!T callback)
    {
        static if (is(T == void))
            execute(definition, (TransactionStatus status) @safe { callback(status); });
        else
        {
            T result;
            execute(definition, (TransactionStatus status) @safe { result = callback(status); });
            return result;
        }
    }
}

/// Extension of the `PlatformTransactionManager` interface, indicating a native resource transaction manager,
/// operating on a single target resource.
interface ResourceTransactionManager : PlatformTransactionManager
{
    /// Return the resource factory that this transaction manager operates on, for example a JDBC `DataSource`.
    Object getResourceFactory();
}

/++
Template class that simplifies programmatic transaction demarcation and transaction exception handling.

The central method is `execute`, supporting transactional code that implements the `TransactionCallback` interface
or is a delegate (R9). This template handles the transaction lifecycle and possible exceptions such that neither the
callback implementation nor the calling code needs to explicitly handle transactions.
+/
class TransactionTemplate : DefaultTransactionDefinition, TransactionOperations
{
    /// Logger available to subclasses.
    protected Logger logger;

    private PlatformTransactionManager transactionManager;

    /// Construct a new `TransactionTemplate` for bean usage. The transaction manager must be set before any
    /// `execute` call.
    this()
    {
        logger = LoggerFactory.getLogger(typeid(this).name);
    }

    /// Construct a new `TransactionTemplate` using the given transaction manager.
    this(PlatformTransactionManager transactionManager)
    {
        this();
        this.transactionManager = transactionManager;
    }

    /// Construct a new `TransactionTemplate` using the given transaction manager, taking its default settings
    /// from the given transaction definition.
    this(PlatformTransactionManager transactionManager, TransactionDefinition transactionDefinition)
    {
        super(transactionDefinition);
        logger = LoggerFactory.getLogger(typeid(this).name);
        this.transactionManager = transactionManager;
    }

    /// Set the transaction management strategy to be used.
    void setTransactionManager(PlatformTransactionManager transactionManager)
    {
        this.transactionManager = transactionManager;
    }

    /// Return the transaction management strategy to be used.
    PlatformTransactionManager getTransactionManager()
    {
        return transactionManager;
    }

    /// Check that a transaction manager is set (Java's `InitializingBean.afterPropertiesSet`).
    void afterPropertiesSet()
    {
        if (transactionManager is null)
            throw new IllegalArgumentException("Property 'transactionManager' is required");
    }

    /// Execute the action within a transaction: commit when it returns, roll back when it throws.
    override void executeWithoutResult(scope void delegate(TransactionStatus) @safe action)
    {
        if (transactionManager is null)
            throw new IllegalStateException("No PlatformTransactionManager set");
        if (auto cpptm = cast(CallbackPreferringPlatformTransactionManager) transactionManager)
        {
            cpptm.execute(this, action);
            return;
        }
        TransactionStatus status = transactionManager.getTransaction(this);
        bool rolledBack = false;
        // A D Error, which is not caught, still rolls back on its way out, as Java's catch of Error does.
        scope (failure)
        {
            if (!rolledBack)
            {
                rolledBack = true;
                rollbackQuietly(status);
            }
        }
        try
            action(status);
        catch (Exception ex)
        {
            // Transactional code threw application exception -> rollback
            rolledBack = true;
            rollbackOnException(status, ex);
            throw ex;
        }
        transactionManager.commit(status);
    }

    private void rollbackQuietly(TransactionStatus status) nothrow
    {
        try
            transactionManager.rollback(status);
        catch (Exception rollbackEx)
        {
            try
                logger.error("Error overridden by rollback exception", rollbackEx);
            catch (Exception)
            {
                // Nothing more can be reported while an Error propagates.
            }
        }
    }

    private void rollbackOnException(TransactionStatus status, Exception ex)
    {
        logger.debug_("Initiating transaction rollback on application exception", ex);
        try
            transactionManager.rollback(status);
        catch (TransactionSystemException ex2)
        {
            logger.error("Application exception overridden by rollback exception", ex);
            ex2.initApplicationException(ex);
            throw ex2;
        }
        catch (Exception ex2)
        {
            logger.error("Application exception overridden by rollback exception", ex);
            throw ex2;
        }
    }

    /// Equal to another definition with the same settings and, for a template, the same transaction manager.
    override bool equals(Object other)
    {
        if (other is this)
            return true;
        if (!super.equals(other))
            return false;
        auto template_ = cast(TransactionTemplate) other;
        return template_ is null || getTransactionManager() is template_.getTransactionManager();
    }
}

// ---------------------------------------------------------------------------------------------------------------
// AbstractPlatformTransactionManager

/++
Abstract base class that implements Spring's standard transaction workflow, serving as basis for concrete platform
transaction managers like `DataSourceTransactionManager`.

It determines whether there is an existing transaction, applies the propagation behavior, suspends and resumes
transactions where necessary, checks the rollback-only flag on commit, applies the appropriate modification on
rollback, and triggers registered synchronization callbacks (if transaction synchronization is active). Subclasses
implement the template methods for specific states of the transaction: `doGetTransaction`, `isExistingTransaction`,
`doBegin`, `doSuspend`, `doResume`, `doCommit`, `doRollback`, `doSetRollbackOnly` and `doCleanupAfterCompletion`.
+/
abstract class AbstractPlatformTransactionManager : PlatformTransactionManager, ConfigurableTransactionManager
{
    /// Always activate transaction synchronization, even for "empty" transactions that result from
    /// `PROPAGATION_SUPPORTS` with no existing backend transaction.
    enum int SYNCHRONIZATION_ALWAYS = 0;
    /// Activate transaction synchronization only for actual transactions.
    enum int SYNCHRONIZATION_ON_ACTUAL_TRANSACTION = 1;
    /// Never activate transaction synchronization, not even for actual transactions.
    enum int SYNCHRONIZATION_NEVER = 2;

    /// Logger available to subclasses.
    protected Logger logger;

    private int transactionSynchronization = SYNCHRONIZATION_ALWAYS;
    private int defaultTimeout = TransactionDefinition.TIMEOUT_DEFAULT;
    private bool nestedTransactionAllowed;
    private bool validateExistingTransaction;
    private bool globalRollbackOnParticipationFailure = true;
    private bool failEarlyOnGlobalRollbackOnly;
    private bool rollbackOnCommitFailure;
    private Collection!TransactionExecutionListener transactionExecutionListeners;

    ///
    this()
    {
        logger = LoggerFactory.getLogger(typeid(this).name);
        transactionExecutionListeners = new ArrayList!TransactionExecutionListener;
    }

    /// Set the transaction synchronization by the name of the corresponding constant in this class, such as
    /// "SYNCHRONIZATION_ALWAYS".
    final void setTransactionSynchronizationName(string constantName)
    {
        if (!hasText(constantName))
            throw new IllegalArgumentException("'constantName' must not be null or blank");
        static immutable string[] names = [
            "SYNCHRONIZATION_ALWAYS", "SYNCHRONIZATION_ON_ACTUAL_TRANSACTION", "SYNCHRONIZATION_NEVER"
        ];
        foreach (index, candidate; names)
        {
            if (candidate == constantName)
            {
                transactionSynchronization = cast(int) index;
                return;
            }
        }
        throw new IllegalArgumentException("Only transaction synchronization constants allowed");
    }

    /// Set when this transaction manager should activate the task-bound transaction synchronization support.
    /// Default is `SYNCHRONIZATION_ALWAYS`.
    final void setTransactionSynchronization(int transactionSynchronization)
    {
        this.transactionSynchronization = transactionSynchronization;
    }

    /// Return if this transaction manager should activate the task-bound transaction synchronization support.
    final int getTransactionSynchronization()
    {
        return transactionSynchronization;
    }

    /// Specify the default timeout that this transaction manager should apply if there is no timeout specified at
    /// the transaction level, in seconds. Throws `InvalidTimeoutException` below `TIMEOUT_DEFAULT`.
    final void setDefaultTimeout(int defaultTimeout)
    {
        if (defaultTimeout < TransactionDefinition.TIMEOUT_DEFAULT)
            throw new InvalidTimeoutException("Invalid default timeout", defaultTimeout);
        this.defaultTimeout = defaultTimeout;
    }

    /// Return the default timeout that this transaction manager should apply if there is no timeout specified at
    /// the transaction level, in seconds.
    final int getDefaultTimeout()
    {
        return defaultTimeout;
    }

    /// Set whether nested transactions are allowed. Default is false.
    final void setNestedTransactionAllowed(bool nestedTransactionAllowed)
    {
        this.nestedTransactionAllowed = nestedTransactionAllowed;
    }

    /// Return whether nested transactions are allowed.
    final bool isNestedTransactionAllowed()
    {
        return nestedTransactionAllowed;
    }

    /// Set whether existing transactions should be validated before participating in them. Default is false.
    final void setValidateExistingTransaction(bool validateExistingTransaction)
    {
        this.validateExistingTransaction = validateExistingTransaction;
    }

    /// Return whether existing transactions should be validated before participating in them.
    final bool isValidateExistingTransaction()
    {
        return validateExistingTransaction;
    }

    /// Set whether to globally mark an existing transaction as rollback-only after a participating transaction
    /// failed. Default is true.
    final void setGlobalRollbackOnParticipationFailure(bool globalRollbackOnParticipationFailure)
    {
        this.globalRollbackOnParticipationFailure = globalRollbackOnParticipationFailure;
    }

    /// Return whether to globally mark an existing transaction as rollback-only after a participating transaction
    /// failed.
    final bool isGlobalRollbackOnParticipationFailure()
    {
        return globalRollbackOnParticipationFailure;
    }

    /// Set whether to fail early in case of the transaction being globally marked as rollback-only. Default is
    /// false.
    final void setFailEarlyOnGlobalRollbackOnly(bool failEarlyOnGlobalRollbackOnly)
    {
        this.failEarlyOnGlobalRollbackOnly = failEarlyOnGlobalRollbackOnly;
    }

    /// Return whether to fail early in case of the transaction being globally marked as rollback-only.
    final bool isFailEarlyOnGlobalRollbackOnly()
    {
        return failEarlyOnGlobalRollbackOnly;
    }

    /// Set whether `doRollback` should be performed on failure of the `doCommit` call. Default is false.
    final void setRollbackOnCommitFailure(bool rollbackOnCommitFailure)
    {
        this.rollbackOnCommitFailure = rollbackOnCommitFailure;
    }

    /// Return whether `doRollback` should be performed on failure of the `doCommit` call.
    final bool isRollbackOnCommitFailure()
    {
        return rollbackOnCommitFailure;
    }

    final override void setTransactionExecutionListeners(Collection!TransactionExecutionListener listeners)
    {
        transactionExecutionListeners = listeners;
    }

    final override Collection!TransactionExecutionListener getTransactionExecutionListeners()
    {
        return transactionExecutionListeners;
    }

    mixin ConfigurableTransactionManager.Defaults;

    // -----------------------------------------------------------------------------------------------------------
    // Implementation of PlatformTransactionManager

    /// This implementation handles propagation behavior. Delegates to `doGetTransaction`,
    /// `isExistingTransaction` and `doBegin`.
    final override TransactionStatus getTransaction(TransactionDefinition definition)
    {
        // Use defaults if no transaction definition given.
        TransactionDefinition def = definition !is null ? definition : TransactionDefinition.withDefaults();
        Object transaction = doGetTransaction();
        const debugEnabled = logger.isDebugEnabled();

        if (isExistingTransaction(transaction))
        {
            // Existing transaction found -> check propagation behavior to find out how to behave.
            return handleExistingTransaction(def, transaction, debugEnabled);
        }

        // Check definition settings for new transaction.
        if (def.getTimeout() < TransactionDefinition.TIMEOUT_DEFAULT)
            throw new InvalidTimeoutException("Invalid transaction timeout", def.getTimeout());

        // No existing transaction found -> check propagation behavior to find out how to proceed.
        const propagation = def.getPropagationBehavior();
        if (propagation == TransactionDefinition.PROPAGATION_MANDATORY)
            throw new IllegalTransactionStateException(
                    "No existing transaction found for transaction marked with propagation 'mandatory'");
        if (propagation == TransactionDefinition.PROPAGATION_REQUIRED
                || propagation == TransactionDefinition.PROPAGATION_REQUIRES_NEW
                || propagation == TransactionDefinition.PROPAGATION_NESTED)
        {
            SuspendedResourcesHolder suspendedResources = suspend(null);
            if (debugEnabled)
            {
                const description = describe(cast(Object) def);
                logger.debug_("Creating new transaction with name [" ~ nameOf(def) ~ "]: " ~ description);
            }
            try
                return startTransaction(def, transaction, false, debugEnabled, suspendedResources);
            catch (Exception ex)
            {
                resume(null, suspendedResources);
                throw ex;
            }
        }
        // Create "empty" transaction: no actual transaction, but potentially synchronization.
        if (def.getIsolationLevel() != TransactionDefinition.ISOLATION_DEFAULT && logger.isWarnEnabled())
            logger.warn("Custom isolation level specified but no actual transaction initiated; "
                    ~ "isolation level will effectively be ignored: " ~ describe(cast(Object) def));
        const newSynchronization = getTransactionSynchronization() == SYNCHRONIZATION_ALWAYS;
        return prepareTransactionStatus(def, null, true, newSynchronization, debugEnabled, null);
    }

    /// Create a `TransactionStatus` for an existing transaction.
    private TransactionStatus handleExistingTransaction(TransactionDefinition definition,
            Object transaction, bool debugEnabled)
    {
        const propagation = definition.getPropagationBehavior();
        if (propagation == TransactionDefinition.PROPAGATION_NEVER)
            throw new IllegalTransactionStateException(
                    "Existing transaction found for transaction marked with propagation 'never'");
        if (propagation == TransactionDefinition.PROPAGATION_NOT_SUPPORTED)
            return suspendForNonTransactional(definition, transaction, debugEnabled);
        if (propagation == TransactionDefinition.PROPAGATION_REQUIRES_NEW)
            return startRequiresNew(definition, transaction, debugEnabled);
        if (propagation == TransactionDefinition.PROPAGATION_NESTED)
            return startNested(definition, transaction, debugEnabled);

        // PROPAGATION_REQUIRED, PROPAGATION_SUPPORTS, PROPAGATION_MANDATORY: regular participation in existing
        // transaction.
        if (debugEnabled)
            logger.debug_("Participating in existing transaction");
        if (isValidateExistingTransaction())
            validateParticipation(definition);
        const newSynchronization = getTransactionSynchronization() != SYNCHRONIZATION_NEVER;
        return prepareTransactionStatus(definition, transaction, false, newSynchronization, debugEnabled, null);
    }

    /// `PROPAGATION_NOT_SUPPORTED` within an existing transaction: suspend it.
    private TransactionStatus suspendForNonTransactional(TransactionDefinition definition,
            Object transaction, bool debugEnabled)
    {
        if (debugEnabled)
            logger.debug_("Suspending current transaction");
        Object suspendedResources = suspend(transaction);
        const newSynchronization = getTransactionSynchronization() == SYNCHRONIZATION_ALWAYS;
        return prepareTransactionStatus(definition, null, false, newSynchronization, debugEnabled, suspendedResources);
    }

    /// `PROPAGATION_REQUIRES_NEW` within an existing transaction: suspend it and start a new one.
    private TransactionStatus startRequiresNew(TransactionDefinition definition, Object transaction, bool debugEnabled)
    {
        if (debugEnabled)
            logger.debug_("Suspending current transaction, creating new transaction with name [" ~ nameOf(
                    definition) ~ "]");
        SuspendedResourcesHolder suspendedResources = suspend(transaction);
        try
            return startTransaction(definition, transaction, false, debugEnabled, suspendedResources);
        catch (Exception beginEx)
        {
            resumeAfterBeginException(transaction, suspendedResources, beginEx);
            throw beginEx;
        }
    }

    /// `PROPAGATION_NESTED` within an existing transaction: a savepoint, or a nested begin.
    private TransactionStatus startNested(TransactionDefinition definition, Object transaction, bool debugEnabled)
    {
        if (!isNestedTransactionAllowed())
            throw new NestedTransactionNotSupportedException(
                    "Transaction manager does not allow nested transactions by default - "
                    ~ "specify 'nestedTransactionAllowed' property with value 'true'");
        if (debugEnabled)
            logger.debug_("Creating nested transaction with name [" ~ nameOf(definition) ~ "]");
        if (!useSavepointForNestedTransaction())
        {
            // Nested transaction through nested begin and commit/rollback calls.
            return startTransaction(definition, transaction, true, debugEnabled, null);
        }
        // Create savepoint within existing Spring-managed transaction, through the SavepointManager API
        // implemented by TransactionStatus. Usually uses JDBC savepoints. Never activates Spring
        // synchronization.
        DefaultTransactionStatus status = newTransactionStatus(definition, transaction, false,
                false, true, debugEnabled, null);
        foreach (listener; listeners())
            listener.beforeBegin(status);
        try
            status.createAndHoldSavepoint();
        catch (Exception ex)
        {
            foreach (listener; listeners())
                listener.afterBegin(status, ex);
            throw ex;
        }
        foreach (listener; listeners())
            listener.afterBegin(status, null);
        return status;
    }

    /// `validateExistingTransaction`: the participating definition must match the existing transaction.
    private void validateParticipation(TransactionDefinition definition)
    {
        if (definition.getIsolationLevel() != TransactionDefinition.ISOLATION_DEFAULT)
        {
            auto currentIsolationLevel = TransactionSynchronizationManager.getCurrentTransactionIsolationLevel();
            if (currentIsolationLevel.isNull || currentIsolationLevel.get != definition.getIsolationLevel())
                throw new IllegalTransactionStateException(
                        "Participating transaction with definition [" ~ describe(cast(Object) definition)
                        ~ "] specifies isolation level which is incompatible with existing transaction: " ~ (
                            currentIsolationLevel.isNull
                            ? "(unknown)" : DefaultTransactionDefinition.getIsolationLevelName(
                            currentIsolationLevel.get)));
        }
        if (!definition.isReadOnly() && TransactionSynchronizationManager.isCurrentTransactionReadOnly())
            throw new IllegalTransactionStateException("Participating transaction with definition [" ~ describe(
                    cast(Object) definition) ~ "] is not marked as read-only but existing transaction is");
    }

    /// Start a new transaction.
    private TransactionStatus startTransaction(TransactionDefinition definition, Object transaction,
            bool nested, bool debugEnabled, SuspendedResourcesHolder suspendedResources)
    {
        const newSynchronization = getTransactionSynchronization() != SYNCHRONIZATION_NEVER;
        DefaultTransactionStatus status = newTransactionStatus(definition, transaction, true,
                newSynchronization, nested, debugEnabled, suspendedResources);
        foreach (listener; listeners())
            listener.beforeBegin(status);
        try
            doBegin(transaction, definition);
        catch (Exception ex)
        {
            foreach (listener; listeners())
                listener.afterBegin(status, ex);
            throw ex;
        }
        prepareSynchronization(status, definition);
        foreach (listener; listeners())
            listener.afterBegin(status, null);
        return status;
    }

    /// Create a new `TransactionStatus` for the given arguments, also initializing transaction synchronization
    /// as appropriate.
    private DefaultTransactionStatus prepareTransactionStatus(TransactionDefinition definition,
            Object transaction, bool newTransaction, bool newSynchronization, bool debug_, Object suspendedResources)
    {
        DefaultTransactionStatus status = newTransactionStatus(definition, transaction,
                newTransaction, newSynchronization, false, debug_, suspendedResources);
        prepareSynchronization(status, definition);
        return status;
    }

    /// Create a `TransactionStatus` instance for the given arguments.
    private DefaultTransactionStatus newTransactionStatus(TransactionDefinition definition, Object transaction,
            bool newTransaction, bool newSynchronization, bool nested, bool debug_, Object suspendedResources)
    {
        const actualNewSynchronization = newSynchronization
            && !TransactionSynchronizationManager.isSynchronizationActive();
        return new DefaultTransactionStatus(definition.getName(), transaction, newTransaction,
                actualNewSynchronization, nested, definition.isReadOnly(), debug_, suspendedResources);
    }

    /// Initialize transaction synchronization as appropriate.
    protected void prepareSynchronization(DefaultTransactionStatus status, TransactionDefinition definition)
    {
        if (status.isNewSynchronization())
        {
            TransactionSynchronizationManager.setActualTransactionActive(status.hasTransaction());
            TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(
                    definition.getIsolationLevel() != TransactionDefinition.ISOLATION_DEFAULT
                    ? Nullable!int(definition.getIsolationLevel()) : Nullable!int.init);
            TransactionSynchronizationManager.setCurrentTransactionReadOnly(definition.isReadOnly());
            TransactionSynchronizationManager.setCurrentTransactionName(definition.getName());
            TransactionSynchronizationManager.initSynchronization();
        }
    }

    /// Determine the actual timeout to use for the given definition. Falls back to this manager's default timeout
    /// if the transaction definition doesn't specify a non-default value.
    protected int determineTimeout(TransactionDefinition definition)
    {
        if (definition.getTimeout() != TransactionDefinition.TIMEOUT_DEFAULT)
            return definition.getTimeout();
        return getDefaultTimeout();
    }

    /// Suspend the given transaction. Suspends transaction synchronization first, then delegates to the
    /// `doSuspend` template method. Returns null if neither a transaction nor synchronization is active.
    protected final SuspendedResourcesHolder suspend(Object transaction)
    {
        if (TransactionSynchronizationManager.isSynchronizationActive())
        {
            auto suspendedSynchronizations = doSuspendSynchronization();
            try
            {
                Object suspendedResources = null;
                if (transaction !is null)
                    suspendedResources = doSuspend(transaction);
                const name = TransactionSynchronizationManager.getCurrentTransactionName();
                TransactionSynchronizationManager.setCurrentTransactionName(null);
                const readOnly = TransactionSynchronizationManager.isCurrentTransactionReadOnly();
                TransactionSynchronizationManager.setCurrentTransactionReadOnly(false);
                auto isolationLevel = TransactionSynchronizationManager.getCurrentTransactionIsolationLevel();
                TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(Nullable!int.init);
                const wasActive = TransactionSynchronizationManager.isActualTransactionActive();
                TransactionSynchronizationManager.setActualTransactionActive(false);
                return new SuspendedResourcesHolder(suspendedResources, suspendedSynchronizations,
                        name, readOnly, isolationLevel, wasActive);
            }
            catch (Exception ex)
            {
                // doSuspend failed - original transaction is still active...
                doResumeSynchronization(suspendedSynchronizations);
                throw ex;
            }
        }
        if (transaction !is null)
        {
            // Transaction active but no synchronization active.
            Object suspendedResources = doSuspend(transaction);
            return new SuspendedResourcesHolder(suspendedResources);
        }
        // Neither transaction nor synchronization active.
        return null;
    }

    /// Resume the given transaction. Delegates to the `doResume` template method first, then resuming transaction
    /// synchronization.
    protected final void resume(Object transaction, SuspendedResourcesHolder resourcesHolder)
    {
        if (resourcesHolder is null)
            return;
        Object suspendedResources = resourcesHolder.suspendedResources;
        if (suspendedResources !is null)
            doResume(transaction, suspendedResources);
        auto suspendedSynchronizations = resourcesHolder.suspendedSynchronizations;
        if (suspendedSynchronizations !is null)
        {
            TransactionSynchronizationManager.setActualTransactionActive(resourcesHolder.wasActive);
            TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(resourcesHolder.isolationLevel);
            TransactionSynchronizationManager.setCurrentTransactionReadOnly(resourcesHolder.readOnly);
            TransactionSynchronizationManager.setCurrentTransactionName(resourcesHolder.name);
            doResumeSynchronization(suspendedSynchronizations);
        }
    }

    /// Resume outer transaction after inner transaction begin failed.
    private void resumeAfterBeginException(Object transaction,
            SuspendedResourcesHolder suspendedResources, Exception beginEx)
    {
        try
            resume(transaction, suspendedResources);
        catch (Exception resumeEx)
        {
            logger.error("Inner transaction begin exception overridden by outer transaction resume exception", beginEx);
            throw resumeEx;
        }
    }

    /// Suspend all current synchronizations and deactivate transaction synchronization for the current task.
    private List!TransactionSynchronization doSuspendSynchronization()
    {
        auto suspendedSynchronizations = TransactionSynchronizationManager.getSynchronizations();
        foreach (synchronization; suspendedSynchronizations.toArray())
            synchronization.suspend();
        TransactionSynchronizationManager.clearSynchronization();
        return suspendedSynchronizations;
    }

    /// Reactivate transaction synchronization for the current task and resume all given synchronizations.
    private void doResumeSynchronization(List!TransactionSynchronization suspendedSynchronizations)
    {
        TransactionSynchronizationManager.initSynchronization();
        foreach (synchronization; suspendedSynchronizations.toArray())
        {
            synchronization.resume();
            TransactionSynchronizationManager.registerSynchronization(synchronization);
        }
    }

    /// This implementation of commit handles participating in existing transactions and programmatic rollback
    /// requests. Delegates to `isRollbackOnly`, `doCommit` and `rollback`.
    final override void commit(TransactionStatus status)
    {
        if (status.isCompleted())
            throw new IllegalTransactionStateException(
                    "Transaction is already completed - do not call commit or rollback more than once per transaction");
        auto defStatus = defaultStatus(status);
        if (defStatus.isLocalRollbackOnly())
        {
            if (defStatus.isDebug())
                logger.debug_("Transactional code has requested rollback");
            processRollback(defStatus, false);
            return;
        }
        if (!shouldCommitOnGlobalRollbackOnly() && defStatus.isGlobalRollbackOnly())
        {
            if (defStatus.isDebug())
                logger.debug_("Global transaction is marked as rollback-only but transactional code requested commit");
            processRollback(defStatus, true);
            return;
        }
        processCommit(defStatus);
    }

    /// Process an actual commit. Rollback-only flags have already been checked and applied.
    private void processCommit(DefaultTransactionStatus status)
    {
        scope (exit)
            cleanupAfterCompletion(status);
        bool beforeCompletionInvoked = false;
        bool commitListenerInvoked = false;
        try
        {
            prepareForCommit(status);
            triggerBeforeCommit(status);
            triggerBeforeCompletion(status);
            beforeCompletionInvoked = true;
            commitOrRelease(status, commitListenerInvoked);
        }
        catch (UnexpectedRollbackException ex)
        {
            triggerAfterCompletion(status, TransactionSynchronization.STATUS_ROLLED_BACK);
            foreach (listener; listeners())
                listener.afterRollback(status, null);
            throw ex;
        }
        catch (TransactionException ex)
        {
            afterCommitFailure(status, ex, commitListenerInvoked);
            throw ex;
        }
        catch (Exception ex)
        {
            if (!beforeCompletionInvoked)
                triggerBeforeCompletion(status);
            doRollbackOnCommitException(status, ex);
            throw ex;
        }

        // Trigger afterCommit callbacks, with an exception thrown there propagated to callers but the transaction
        // still considered as committed.
        scope (exit)
        {
            triggerAfterCompletion(status, TransactionSynchronization.STATUS_COMMITTED);
            if (commitListenerInvoked)
                foreach (listener; listeners())
                    listener.afterCommit(status, null);
        }
        triggerAfterCommit(status);
    }

    /// The core of `processCommit`: release the savepoint or commit, then report an unexpected rollback.
    private void commitOrRelease(DefaultTransactionStatus status, ref bool commitListenerInvoked)
    {
        bool unexpectedRollback = false;
        if (status.hasSavepoint())
        {
            if (status.isDebug())
                logger.debug_("Releasing transaction savepoint");
            unexpectedRollback = status.isGlobalRollbackOnly();
            foreach (listener; listeners())
                listener.beforeCommit(status);
            commitListenerInvoked = true;
            status.releaseHeldSavepoint();
        }
        else if (status.isNewTransaction())
        {
            if (status.isDebug())
                logger.debug_("Initiating transaction commit");
            unexpectedRollback = status.isGlobalRollbackOnly();
            foreach (listener; listeners())
                listener.beforeCommit(status);
            commitListenerInvoked = true;
            doCommit(status);
        }
        else if (isFailEarlyOnGlobalRollbackOnly())
            unexpectedRollback = status.isGlobalRollbackOnly();

        // Throw UnexpectedRollbackException if we have a global rollback-only marker but still didn't get a
        // corresponding exception from commit.
        if (unexpectedRollback)
            throw new UnexpectedRollbackException(
                    "Transaction silently rolled back because it has been marked as rollback-only");
    }

    /// A `TransactionException` from the commit: roll back if configured, else report an unknown outcome.
    private void afterCommitFailure(DefaultTransactionStatus status, TransactionException ex,
            bool commitListenerInvoked)
    {
        if (isRollbackOnCommitFailure())
        {
            doRollbackOnCommitException(status, ex);
            return;
        }
        triggerAfterCompletion(status, TransactionSynchronization.STATUS_UNKNOWN);
        if (commitListenerInvoked)
            foreach (listener; listeners())
                listener.afterCommit(status, ex);
    }

    /// This implementation of rollback handles participating in existing transactions. Delegates to `doRollback`
    /// and `doSetRollbackOnly`.
    final override void rollback(TransactionStatus status)
    {
        if (status.isCompleted())
            throw new IllegalTransactionStateException(
                    "Transaction is already completed - do not call commit or rollback more than once per transaction");
        processRollback(defaultStatus(status), false);
    }

    /// Process an actual rollback. The completed flag has already been checked.
    private void processRollback(DefaultTransactionStatus status, bool unexpected)
    {
        scope (exit)
            cleanupAfterCompletion(status);
        bool unexpectedRollback = unexpected;
        bool rollbackListenerInvoked = false;
        try
        {
            triggerBeforeCompletion(status);
            if (status.hasSavepoint())
            {
                if (status.isDebug())
                    logger.debug_("Rolling back transaction to savepoint");
                foreach (listener; listeners())
                    listener.beforeRollback(status);
                rollbackListenerInvoked = true;
                status.rollbackToHeldSavepoint();
            }
            else if (status.isNewTransaction())
            {
                if (status.isDebug())
                    logger.debug_("Initiating transaction rollback");
                foreach (listener; listeners())
                    listener.beforeRollback(status);
                rollbackListenerInvoked = true;
                doRollback(status);
            }
            else
                unexpectedRollback = rollbackParticipating(status, unexpectedRollback);
        }
        catch (Exception ex)
        {
            triggerAfterCompletion(status, TransactionSynchronization.STATUS_UNKNOWN);
            if (rollbackListenerInvoked)
                foreach (listener; listeners())
                    listener.afterRollback(status, ex);
            throw ex;
        }

        triggerAfterCompletion(status, TransactionSynchronization.STATUS_ROLLED_BACK);
        if (rollbackListenerInvoked)
            foreach (listener; listeners())
                listener.afterRollback(status, null);

        // Raise UnexpectedRollbackException if we had a global rollback-only marker
        if (unexpectedRollback)
        {
            enum message = "Transaction rolled back because it has been marked as rollback-only";
            throw new UnexpectedRollbackException(message);
        }
    }

    /// Rollback of a transaction that participates in a larger one: mark the larger one rollback-only. Returns
    /// whether an unexpected rollback still has to be reported.
    private bool rollbackParticipating(DefaultTransactionStatus status, bool unexpectedRollback)
    {
        if (status.hasTransaction())
        {
            if (status.isLocalRollbackOnly() || isGlobalRollbackOnParticipationFailure())
            {
                if (status.isDebug())
                    logger.debug_("Participating transaction failed - marking existing transaction as rollback-only");
                doSetRollbackOnly(status);
            }
            else if (status.isDebug())
                logger.debug_("Participating transaction failed - letting transaction originator decide on rollback");
        }
        else
            logger.debug_("Should roll back transaction but cannot - no transaction available");
        // Unexpected rollback only matters here if we're asked to fail early
        return isFailEarlyOnGlobalRollbackOnly() ? unexpectedRollback : false;
    }

    /// Invoke `doRollback`, handling rollback exceptions properly.
    private void doRollbackOnCommitException(DefaultTransactionStatus status, Exception ex)
    {
        try
        {
            if (status.isNewTransaction())
            {
                if (status.isDebug())
                    logger.debug_("Initiating transaction rollback after commit exception", ex);
                doRollback(status);
            }
            else if (status.hasTransaction() && isGlobalRollbackOnParticipationFailure())
            {
                if (status.isDebug())
                    logger.debug_("Marking existing transaction as rollback-only after commit exception", ex);
                doSetRollbackOnly(status);
            }
        }
        catch (Exception rbex)
        {
            logger.error("Commit exception overridden by rollback exception", ex);
            triggerAfterCompletion(status, TransactionSynchronization.STATUS_UNKNOWN);
            foreach (listener; listeners())
                listener.afterRollback(status, rbex);
            throw rbex;
        }
        triggerAfterCompletion(status, TransactionSynchronization.STATUS_ROLLED_BACK);
        foreach (listener; listeners())
            listener.afterRollback(status, null);
    }

    /// Trigger `beforeCommit` callbacks.
    protected final void triggerBeforeCommit(DefaultTransactionStatus status)
    {
        if (status.isNewSynchronization())
            TransactionSynchronizationUtils.triggerBeforeCommit(status.isReadOnly());
    }

    /// Trigger `beforeCompletion` callbacks.
    protected final void triggerBeforeCompletion(DefaultTransactionStatus status)
    {
        if (status.isNewSynchronization())
            TransactionSynchronizationUtils.triggerBeforeCompletion();
    }

    private void triggerAfterCommit(DefaultTransactionStatus status)
    {
        if (status.isNewSynchronization())
            TransactionSynchronizationUtils.triggerAfterCommit();
    }

    private void triggerAfterCompletion(DefaultTransactionStatus status, int completionStatus)
    {
        if (!status.isNewSynchronization())
            return;
        auto synchronizations = TransactionSynchronizationManager.getSynchronizations();
        TransactionSynchronizationManager.clearSynchronization();
        if (!status.hasTransaction() || status.isNewTransaction())
        {
            // No transaction or new transaction for the current scope -> invoke the afterCompletion callbacks
            // immediately
            invokeAfterCompletion(synchronizations, completionStatus);
        }
        else if (!synchronizations.isEmpty())
        {
            // Existing transaction that we participate in, controlled outside the scope of this transaction
            // manager -> try to register an afterCompletion callback with the existing transaction.
            registerAfterCompletionWithExistingTransaction(status.getTransaction(), synchronizations);
        }
    }

    /// Actually invoke the `afterCompletion` methods of the given synchronizations.
    protected final void invokeAfterCompletion(List!TransactionSynchronization synchronizations, int completionStatus)
    {
        TransactionSynchronizationUtils.invokeAfterCompletion(synchronizations, completionStatus);
    }

    /// Clean up after completion, clearing synchronization if necessary, and invoking `doCleanupAfterCompletion`.
    private void cleanupAfterCompletion(DefaultTransactionStatus status)
    {
        status.setCompleted();
        if (status.isNewSynchronization())
            TransactionSynchronizationManager.clear();
        if (status.isNewTransaction())
            doCleanupAfterCompletion(status.getTransaction());
        if (status.getSuspendedResources() !is null)
        {
            if (status.isDebug())
                logger.debug_("Resuming suspended transaction after completion of inner transaction");
            Object transaction = status.hasTransaction() ? status.getTransaction() : null;
            resume(transaction, cast(SuspendedResourcesHolder) status.getSuspendedResources());
        }
    }

    // -----------------------------------------------------------------------------------------------------------
    // Template methods to be implemented in subclasses

    /// Return a transaction object for the current transaction state.
    protected abstract Object doGetTransaction();

    /// Check if the given transaction object indicates an existing transaction. Default: false.
    protected bool isExistingTransaction(Object)
    {
        return false;
    }

    /// Return whether to use a savepoint for a nested transaction. Default: true.
    protected bool useSavepointForNestedTransaction()
    {
        return true;
    }

    /// Begin a new transaction with semantics according to the given transaction definition.
    protected abstract void doBegin(Object transaction, TransactionDefinition definition);

    /// Suspend the resources of the current transaction. Default: throws
    /// `TransactionSuspensionNotSupportedException`.
    protected Object doSuspend(Object)
    {
        throw new TransactionSuspensionNotSupportedException("Transaction manager [" ~ typeid(this)
                .name ~ "] does not support transaction suspension");
    }

    /// Resume the resources of the current transaction. Default: throws
    /// `TransactionSuspensionNotSupportedException`.
    protected void doResume(Object, Object)
    {
        throw new TransactionSuspensionNotSupportedException("Transaction manager [" ~ typeid(this)
                .name ~ "] does not support transaction suspension");
    }

    /// Return whether to call `doCommit` on a transaction that has been marked as rollback-only in a global
    /// fashion. Default: false.
    protected bool shouldCommitOnGlobalRollbackOnly()
    {
        return false;
    }

    /// Make preparations for commit, to be performed before the `beforeCommit` synchronization callbacks occur.
    protected void prepareForCommit(DefaultTransactionStatus)
    {
    }

    /// Perform an actual commit of the given transaction.
    protected abstract void doCommit(DefaultTransactionStatus status);

    /// Perform an actual rollback of the given transaction.
    protected abstract void doRollback(DefaultTransactionStatus status);

    /// Set the given transaction rollback-only. Only called on rollback if the current transaction participates
    /// in an existing one. Default: throws `IllegalTransactionStateException`.
    protected void doSetRollbackOnly(DefaultTransactionStatus)
    {
        throw new IllegalTransactionStateException(
                "Participating in existing transactions is not supported - when 'isExistingTransaction' "
                ~ "returns true, appropriate 'doSetRollbackOnly' behavior must be provided");
    }

    /// Register the given list of transaction synchronizations with the existing transaction. Default: invokes
    /// the after-completion callbacks immediately, with outcome status "unknown".
    protected void registerAfterCompletionWithExistingTransaction(Object,
            List!TransactionSynchronization synchronizations)
    {
        logger.debug_("Cannot register Spring after-completion synchronization with existing transaction - "
                ~ "processing Spring after-completion callbacks immediately, with outcome status 'unknown'");
        invokeAfterCompletion(synchronizations, TransactionSynchronization.STATUS_UNKNOWN);
    }

    /// Clean up resources after transaction completion. Called after `doCommit` and `doRollback` execution, on
    /// any outcome.
    protected void doCleanupAfterCompletion(Object)
    {
    }

    private TransactionExecutionListener[] listeners()
    {
        return transactionExecutionListeners.toArray();
    }

    private static DefaultTransactionStatus defaultStatus(TransactionStatus status)
    {
        auto defStatus = cast(DefaultTransactionStatus) status;
        if (defStatus is null)
            throw new IllegalTransactionStateException("Transaction status is not a DefaultTransactionStatus");
        return defStatus;
    }

    private static string nameOf(TransactionDefinition definition)
    {
        auto name = definition.getName();
        return name is null ? "null" : name;
    }

    /// Holder for suspended resources. Used internally by `suspend` and `resume`.
    protected static final class SuspendedResourcesHolder
    {
        private Object suspendedResources;
        private List!TransactionSynchronization suspendedSynchronizations;
        private string name;
        private bool readOnly;
        private Nullable!int isolationLevel;
        private bool wasActive;

        private this(Object suspendedResources)
        {
            this.suspendedResources = suspendedResources;
        }

        private this(Object suspendedResources, List!TransactionSynchronization suspendedSynchronizations,
                string name, bool readOnly, Nullable!int isolationLevel, bool wasActive)
        {
            this.suspendedResources = suspendedResources;
            this.suspendedSynchronizations = suspendedSynchronizations;
            this.name = name;
            this.readOnly = readOnly;
            this.isolationLevel = isolationLevel;
            this.wasActive = wasActive;
        }
    }
}
