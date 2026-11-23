// Ported from spring-framework v7.1.0: spring-tx/src/main/java/org/springframework/transaction/*.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.

/++
`org.springframework.transaction`: the transaction manager SPI (`PlatformTransactionManager`), the definition of a
transaction (`TransactionDefinition`), its status (`TransactionStatus`), execution listeners, and the
`TransactionException` hierarchy (ADR-030).

Interfaces whose methods have Java default bodies keep their D interface, so that interfaces such as
`TransactionAttribute` can still extend them; the default bodies are in each interface's `mixin template Defaults`
(rule R3). `TransactionExecutionListener` is implemented selectively, so it is an abstract class (deviation D-3).
`TransactionStatus` drops Java's `Flushable` supertype, which `flint.java.io` does not declare, and keeps `flush`.
The reactive transaction types arrive with Phase 2.
+/
module flint.transaction;

import flint.core : NestedRuntimeException;
import flint.java.lang : IllegalArgumentException, IllegalStateException, UnsupportedOperationException, javaToString;
import flint.java.util : Collection;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Definitions and status

/++
Interface that defines Spring-compliant transaction properties, based on the propagation behavior definitions
analogous to EJB CMT attributes. Every method has a default, so an implementation mixes in `Defaults` and overrides
what it changes.
+/
interface TransactionDefinition
{
    /// Support a current transaction; create a new one if none exists. The default setting.
    enum int PROPAGATION_REQUIRED = 0;
    /// Support a current transaction; execute non-transactionally if none exists.
    enum int PROPAGATION_SUPPORTS = 1;
    /// Support a current transaction; throw an exception if no current transaction exists.
    enum int PROPAGATION_MANDATORY = 2;
    /// Create a new transaction, suspending the current transaction if one exists.
    enum int PROPAGATION_REQUIRES_NEW = 3;
    /// Do not support a current transaction; rather always execute non-transactionally.
    enum int PROPAGATION_NOT_SUPPORTED = 4;
    /// Do not support a current transaction; throw an exception if a current transaction exists.
    enum int PROPAGATION_NEVER = 5;
    /// Execute within a nested transaction (a savepoint) if a current transaction exists, else behave like
    /// `PROPAGATION_REQUIRED`.
    enum int PROPAGATION_NESTED = 6;

    /// Use the default isolation level of the underlying datastore.
    enum int ISOLATION_DEFAULT = -1;
    /// Dirty reads, non-repeatable reads and phantom reads can occur. Same as `Connection.TRANSACTION_READ_UNCOMMITTED`.
    enum int ISOLATION_READ_UNCOMMITTED = 1;
    /// Dirty reads are prevented. Same as `Connection.TRANSACTION_READ_COMMITTED`.
    enum int ISOLATION_READ_COMMITTED = 2;
    /// Dirty reads and non-repeatable reads are prevented. Same as `Connection.TRANSACTION_REPEATABLE_READ`.
    enum int ISOLATION_REPEATABLE_READ = 4;
    /// Dirty reads, non-repeatable reads and phantom reads are prevented. Same as
    /// `Connection.TRANSACTION_SERIALIZABLE`.
    enum int ISOLATION_SERIALIZABLE = 8;

    /// Use the default timeout of the underlying transaction system, or none if timeouts are not supported.
    enum int TIMEOUT_DEFAULT = -1;

    /// The propagation behavior, one of the `PROPAGATION_` constants. Default: `PROPAGATION_REQUIRED`.
    int getPropagationBehavior();

    /// The isolation level, one of the `ISOLATION_` constants. Default: `ISOLATION_DEFAULT`.
    int getIsolationLevel();

    /// The transaction timeout in seconds. Default: `TIMEOUT_DEFAULT`.
    int getTimeout();

    /// Whether to optimize as a read-only transaction. Default: false.
    bool isReadOnly();

    /// The name of this transaction, or null. Default: null.
    string getName();

    /// A `TransactionDefinition` with defaults: `PROPAGATION_REQUIRED`, `ISOLATION_DEFAULT`, `TIMEOUT_DEFAULT`,
    /// not read-only, unnamed. Use it for customization purposes rather than a modifiable definition.
    static TransactionDefinition withDefaults() pure nothrow
    {
        return new StaticTransactionDefinition;
    }

    /// The Java default bodies.
    mixin template Defaults()
    {
        /// Default: `PROPAGATION_REQUIRED`.
        int getPropagationBehavior()
        {
            return TransactionDefinition.PROPAGATION_REQUIRED;
        }

        /// Default: `ISOLATION_DEFAULT`.
        int getIsolationLevel()
        {
            return TransactionDefinition.ISOLATION_DEFAULT;
        }

        /// Default: `TIMEOUT_DEFAULT`.
        int getTimeout()
        {
            return TransactionDefinition.TIMEOUT_DEFAULT;
        }

        /// Default: false.
        bool isReadOnly()
        {
            return false;
        }

        /// Default: null.
        string getName()
        {
            return null;
        }
    }
}

/// The `TransactionDefinition` of all defaults that `withDefaults` returns.
private final class StaticTransactionDefinition : TransactionDefinition
{
    mixin TransactionDefinition.Defaults;
}

/// Common representation of the current state of a transaction. Every method has a default (`Defaults`).
interface TransactionExecution
{
    /// The defined name of this transaction, possibly empty. Default: an empty string.
    string getTransactionName();

    /// Whether this transaction manages an actual transaction resource. Default: true.
    bool hasTransaction();

    /// Whether the transaction is new rather than participating in an existing one. Default: true.
    bool isNewTransaction();

    /// Whether the transaction is nested within another, as with a savepoint. Default: false.
    bool isNested();

    /// Whether the transaction is declared read-only. Default: false.
    bool isReadOnly();

    /// Mark the transaction rollback-only. Default: throws `UnsupportedOperationException`.
    void setRollbackOnly();

    /// Whether the transaction has been marked rollback-only. Default: false.
    bool isRollbackOnly();

    /// Whether the transaction has completed, by commit or rollback. Default: false.
    bool isCompleted();

    /// The Java default bodies.
    mixin template Defaults()
    {
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

        /// Default: throws `UnsupportedOperationException`.
        void setRollbackOnly()
        {
            throw new UnsupportedOperationException("setRollbackOnly not supported");
        }

        /// Default: false.
        bool isRollbackOnly()
        {
            return false;
        }

        /// Default: false.
        bool isCompleted()
        {
            return false;
        }
    }
}

/// Interface that specifies an API to programmatically manage transaction savepoints in a generic fashion.
interface SavepointManager
{
    /// Create a new savepoint and return a handle to it. Throws `NestedTransactionNotSupportedException` if the
    /// underlying transaction does not support savepoints.
    Object createSavepoint();

    /// Roll back to the given savepoint. The savepoint is not released automatically.
    void rollbackToSavepoint(Object savepoint);

    /// Explicitly release the given savepoint.
    void releaseSavepoint(Object savepoint);
}

/// Representation of an ongoing transaction: status and savepoint management for transactional code.
interface TransactionStatus : TransactionExecution, SavepointManager
{
    /// Whether this transaction internally carries a savepoint. Default: false.
    bool hasSavepoint();

    /// Flush the underlying session to the datastore, if applicable. Default: nothing.
    void flush();

    /// The Java default bodies of `TransactionStatus` and `TransactionExecution`.
    mixin template Defaults()
    {
        mixin TransactionExecution.Defaults;

        /// Default: false.
        bool hasSavepoint()
        {
            return false;
        }

        /// Default: nothing.
        void flush()
        {
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Transaction managers

/// Marker interface for Spring transaction manager implementations, traditional or reactive.
interface TransactionManager
{
}

/// The central interface in Spring's imperative transaction infrastructure.
interface PlatformTransactionManager : TransactionManager
{
    /// Return a currently active transaction or create a new one, according to the specified propagation
    /// behavior; a null `definition` means the defaults.
    TransactionStatus getTransaction(TransactionDefinition definition);

    /// Commit the given transaction, with regard to its status: roll back instead if it was marked
    /// rollback-only.
    void commit(TransactionStatus status);

    /// Perform a rollback of the given transaction.
    void rollback(TransactionStatus status);
}

/// Callback interface for stateless listening to transaction creation and completion steps in a transaction
/// manager. Every method does nothing by default (deviation D-3: an abstract class).
abstract class TransactionExecutionListener
{
    /// Callback before the transaction begins.
    void beforeBegin(TransactionExecution)
    {
    }

    /// Callback after the transaction began, or failed to; `beginFailure` is the failure, or null.
    void afterBegin(TransactionExecution, Throwable)
    {
    }

    /// Callback before the transaction commits.
    void beforeCommit(TransactionExecution)
    {
    }

    /// Callback after the transaction committed, or failed to; `commitFailure` is the failure, or null.
    void afterCommit(TransactionExecution, Throwable)
    {
    }

    /// Callback before the transaction rolls back.
    void beforeRollback(TransactionExecution)
    {
    }

    /// Callback after the transaction rolled back, or failed to; `rollbackFailure` is the failure, or null.
    void afterRollback(TransactionExecution, Throwable)
    {
    }
}

/// Common configuration interface for transaction manager implementations with options for execution listeners.
interface ConfigurableTransactionManager : TransactionManager
{
    /// Specify the execution listeners for transactions of this manager.
    void setTransactionExecutionListeners(Collection!TransactionExecutionListener listeners);

    /// Return the registered execution listeners, as a mutable collection.
    Collection!TransactionExecutionListener getTransactionExecutionListeners();

    /// Conveniently register the given listener. Default: adds it to `getTransactionExecutionListeners()`.
    void addListener(TransactionExecutionListener listener);

    /// The Java default body.
    mixin template Defaults()
    {
        /// Default: adds `listener` to `getTransactionExecutionListeners()`.
        void addListener(TransactionExecutionListener listener)
        {
            getTransactionExecutionListeners().add(listener);
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Exceptions (R8)

/// Superclass for all transaction exceptions.
abstract class TransactionException : NestedRuntimeException
{
    /// Construct a `TransactionException` with the specified message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/// Exception thrown when a transaction can't be created using an underlying transaction API such as JTA.
class CannotCreateTransactionException : TransactionException
{
    /// Construct with the specified message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/// Superclass for exceptions caused by inappropriate usage of a Spring transaction API.
class TransactionUsageException : TransactionException
{
    /// Construct with the specified message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/// Exception thrown when the existence or non-existence of a transaction amounts to an illegal state according
/// to the transaction propagation behavior that applies.
class IllegalTransactionStateException : TransactionUsageException
{
    /// Construct with the specified message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/// Exception that gets thrown when an invalid isolation level is specified, for example an unknown isolation
/// level.
class InvalidIsolationLevelException : TransactionUsageException
{
    /// Construct with the specified message.
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, null, file, line);
    }
}

/// Exception that gets thrown when an invalid timeout is specified, that is, the specified timeout valid is out
/// of range or the transaction manager implementation doesn't support timeouts.
class InvalidTimeoutException : TransactionUsageException
{
    private int timeout;

    /// Construct with the specified message and the invalid timeout value.
    this(string msg, int timeout, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, null, file, line);
        this.timeout = timeout;
    }

    /// Return the invalid timeout value.
    int getTimeout() const pure nothrow @nogc
    {
        return timeout;
    }
}

/// Exception thrown when attempting to work with a nested transaction but nested transactions are not supported
/// by the underlying backend.
class NestedTransactionNotSupportedException : CannotCreateTransactionException
{
    /// Construct with the specified message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/// Exception thrown when an operation is attempted that relies on an existing transaction (such as setting
/// rollback status) and there is no existing transaction. This represents an illegal usage of the transaction API.
class NoTransactionException : TransactionUsageException
{
    /// Construct with the specified message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/// Exception thrown when attempting to suspend an existing transaction but transaction suspension is not
/// supported by the underlying backend.
class TransactionSuspensionNotSupportedException : CannotCreateTransactionException
{
    /// Construct with the specified message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/// Exception thrown when a general transaction system error is encountered, like on commit or rollback.
class TransactionSystemException : TransactionException
{
    private Throwable applicationException;

    /// Construct with the specified message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }

    /// Set an application exception that was thrown before this transaction exception, preserving the original
    /// exception despite the overriding `TransactionSystemException`.
    void initApplicationException(Throwable ex)
    {
        if (ex is null)
            throw new IllegalArgumentException("Application exception must not be null");
        if (applicationException !is null)
            throw new IllegalStateException(
                    "Already holding an application exception: " ~ javaToString(applicationException));
        applicationException = ex;
    }

    /// Return the application exception that was thrown before this transaction exception, if any.
    final Throwable getApplicationException() pure nothrow @nogc
    {
        return applicationException;
    }

    /// Return the exception that was the first to be thrown within the failed transaction: the application
    /// exception, if any, or the `TransactionSystemException`'s own cause.
    Throwable getOriginalException() pure nothrow @nogc
    {
        return applicationException !is null ? applicationException : getCause();
    }

    /// `contains` with a type parameter (R4), declared again because the override below hides the inherited one.
    bool contains(T : Throwable)() pure nothrow @nogc
    {
        return contains(typeid(T));
    }

    /// Also matches the application exception.
    override bool contains(const TypeInfo_Class exType) pure nothrow @nogc
    {
        if (super.contains(exType))
            return true;
        return exType !is null && applicationException !is null
            && (typeid(applicationException) is exType || exType.isBaseOf(typeid(applicationException)));
    }
}

/// Exception to be thrown when a transaction has timed out.
class TransactionTimedOutException : TransactionException
{
    /// Construct with the specified message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/// Thrown when an attempt to commit a transaction resulted in an unexpected rollback.
class UnexpectedRollbackException : TransactionException
{
    /// Construct with the specified message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/// Exception that represents a transaction failure caused by a heuristic decision on the side of the transaction
/// coordinator.
class HeuristicCompletionException : TransactionException
{
    /// Unknown outcome state.
    enum int STATE_UNKNOWN = 0;
    /// Committed outcome state.
    enum int STATE_COMMITTED = 1;
    /// Rolled back outcome state.
    enum int STATE_ROLLED_BACK = 2;
    /// Mixed outcome state.
    enum int STATE_MIXED = 3;

    private int outcomeState;

    /// The text for an outcome state.
    static string getStateString(int state) pure nothrow @nogc
    {
        switch (state)
        {
        case STATE_COMMITTED:
            return "committed";
        case STATE_ROLLED_BACK:
            return "rolled back";
        case STATE_MIXED:
            return "mixed";
        default:
            return "unknown";
        }
    }

    /// Constructor for `HeuristicCompletionException`.
    this(int outcomeState, Throwable cause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super("Heuristic completion: outcome state is " ~ getStateString(outcomeState), cause, file, line);
        this.outcomeState = outcomeState;
    }

    /// Return the outcome state of the transaction state, as one of the constants in this class.
    int getOutcomeState() const pure nothrow @nogc
    {
        return outcomeState;
    }
}
