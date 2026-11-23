// Ported from spring-framework v7.1.0: spring-tx/src/main/java/org/springframework/dao/*.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.

/++
`org.springframework.dao`: Spring's technology-agnostic data access exception hierarchy. `JdbcTemplate`, the SQL
exception translators and every data access technology throw these, so callers catch one hierarchy whatever the
database (ADR-030, rule R8).

Each exception's cause is Java's (`getCause`). Where Java offers both a message-only and a message-and-cause
constructor, D has one constructor with an optional cause.
+/
module flint.dao;

import flint.core : NestedRuntimeException;

@safe:

/++
Root of the hierarchy of data access exceptions discussed in Expert One-On-One J2EE Design and Development.
Please see Chapter 9 of this book for detailed discussion of the motivation for this package. This exception
hierarchy aims to let user code find and handle the kind of error encountered without knowing the details of the
particular data access API in use (for example, JDBC). Thus, it is possible to react to an optimistic locking
failure without knowing that JDBC is being used. As this class is a runtime exception, there is no need for user
code to catch it or subclasses if any error is to be considered fatal (the usual case).
+/
abstract class DataAccessException : NestedRuntimeException
{
    /// Construct a `DataAccessException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Root of the hierarchy of data access exceptions that are considered non-transient - where a retry of the same
operation would fail unless the cause of the Exception is corrected.
+/
abstract class NonTransientDataAccessException : DataAccessException
{
    /// Construct a `NonTransientDataAccessException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Root of the hierarchy of data access exceptions that are considered transient - where a previously failed operation
might be able to succeed when the operation is retried without any intervention by application-level functionality.
+/
abstract class TransientDataAccessException : DataAccessException
{
    /// Construct a `TransientDataAccessException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Data access exception thrown when a previously failed operation might be able to succeed if the application performs
some recovery steps and retries the entire transaction or in the case of a distributed transaction, the transaction
branch. At a minimum, the recovery operation must include closing the current connection and getting a new
connection.
+/
class RecoverableDataAccessException : DataAccessException
{
    /// Construct a `RecoverableDataAccessException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Data access exception thrown when a resource fails completely and the failure is permanent.
+/
class NonTransientDataAccessResourceException : NonTransientDataAccessException
{
    /// Construct a `NonTransientDataAccessResourceException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Data access exception thrown when a resource fails completely: for example, if we can't connect to a database using
JDBC.
+/
class DataAccessResourceFailureException : NonTransientDataAccessResourceException
{
    /// Construct a `DataAccessResourceFailureException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Exception thrown when an attempt to execute an SQL statement fails to map the given data, typically but no limited
to an insert or update data results in violation of an integrity constraint. Note that this is not purely a
relational concept; integrity constraints such as unique primary keys are required by most database types. Serves as
a superclass for more specific exceptions, for example, `DuplicateKeyException`. However, it is generally
recommended to handle `DataIntegrityViolationException` itself instead of relying on specific exception subclasses.
+/
class DataIntegrityViolationException : NonTransientDataAccessException
{
    /// Construct a `DataIntegrityViolationException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Exception thrown when an attempt to insert or update data results in violation of a primary key or unique
constraint. Note that this is not necessarily a purely relational concept; unique primary keys are required by most
database types. Consider handling the general `DataIntegrityViolationException` instead, semantically including a
wider range of constraint violations.
+/
class DuplicateKeyException : DataIntegrityViolationException
{
    /// Construct a `DuplicateKeyException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Exception thrown if certain expected data could not be retrieved, for example, when looking up specific data via a
known identifier. This exception will be thrown either by O/R mapping tools or by DAO implementations.
+/
class DataRetrievalFailureException : NonTransientDataAccessException
{
    /// Construct a `DataRetrievalFailureException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Data access exception thrown when a result was not of the expected size, for example when expecting a single row but
getting 0 or more than 1 rows.
+/
class IncorrectResultSizeDataAccessException : DataRetrievalFailureException
{
    private int expectedSize;
    private int actualSize;

    /// Construct with the expected result size; the actual size is unknown (-1).
    this(int expectedSize, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        this("Incorrect result size: expected " ~ decimal(expectedSize), expectedSize, -1, null, file, line);
    }

    /// Construct with the expected and the actual result size.
    this(int expectedSize, int actualSize, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        this("Incorrect result size: expected " ~ decimal(expectedSize) ~ ", actual " ~ decimal(actualSize),
                expectedSize, actualSize, null, file, line);
    }

    /// Construct with a message, the expected result size and, optionally, the root cause; the actual size is -1.
    this(string msg, int expectedSize, Throwable ex = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        this(msg, expectedSize, -1, ex, file, line);
    }

    /// Construct with a message, the expected and actual result size and, optionally, the root cause.
    this(string msg, int expectedSize, int actualSize, Throwable ex = null, string file = __FILE__,
            size_t line = __LINE__) pure nothrow
    {
        super(msg, ex, file, line);
        this.expectedSize = expectedSize;
        this.actualSize = actualSize;
    }

    /// The expected result size.
    int getExpectedSize() const pure nothrow @nogc
    {
        return expectedSize;
    }

    /// The actual result size, or -1 if unknown.
    int getActualSize() const pure nothrow @nogc
    {
        return actualSize;
    }
}

/++
Data access exception thrown when a result was expected to have at least one row (or element) but zero rows (or
elements) were actually returned.
+/
class EmptyResultDataAccessException : IncorrectResultSizeDataAccessException
{
    /// Construct with the expected result size; the actual size is 0.
    this(int expectedSize, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(expectedSize, 0, file, line);
    }

    /// Construct with a message, the expected result size and, optionally, the root cause.
    this(string msg, int expectedSize, Throwable ex = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, expectedSize, 0, ex, file, line);
    }
}

/++
Exception thrown on incorrect usage of the API, such as failing to "compile" a query object that needed compilation
before execution. This represents a problem in our Java data access framework, not the underlying data access
infrastructure.
+/
class InvalidDataAccessApiUsageException : NonTransientDataAccessException
{
    /// Construct a `InvalidDataAccessApiUsageException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Root for exceptions thrown when we use a data access resource incorrectly. Thrown for example on specifying bad SQL
when using a RDBMS. Resource-specific subclasses are supplied by concrete data access packages.
+/
class InvalidDataAccessResourceUsageException : NonTransientDataAccessException
{
    /// Construct a `InvalidDataAccessResourceUsageException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Data access exception thrown when something unintended appears to have happened with an update, but the transaction
hasn't already been rolled back. Thrown, for example, when we wanted to update 1 row in an RDBMS but actually
updated 3.
+/
class IncorrectUpdateSemanticsDataAccessException : InvalidDataAccessResourceUsageException
{
    /// Construct with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }

    /// Return whether data was updated. If this method returns false, there is nothing to roll back. The default
    /// implementation always returns true; subclasses override it.
    bool wasDataUpdated() const pure nothrow @nogc
    {
        return true;
    }
}

/++
Exception thrown on mismatch between Java type and database type: for example on an attempt to set an object of the
wrong type in an RDBMS column.
+/
class TypeMismatchDataAccessException : InvalidDataAccessResourceUsageException
{
    /// Construct a `TypeMismatchDataAccessException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Exception thrown when the underlying resource denied a permission to access a specific element, such as a specific
database table.
+/
class PermissionDeniedDataAccessException : NonTransientDataAccessException
{
    /// Construct a `PermissionDeniedDataAccessException` with the specified detail message and the root cause.
    this(string msg, Throwable cause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Normal superclass when we can't distinguish anything more specific than "something went wrong with the underlying
resource": for example, an SQLException from JDBC we can't pinpoint more precisely.
+/
abstract class UncategorizedDataAccessException : NonTransientDataAccessException
{
    /// Construct a `UncategorizedDataAccessException` with the specified detail message and the root cause.
    this(string msg, Throwable cause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Exception thrown when we couldn't clean up after a data access operation, but the actual operation went OK. For
example, this exception or a subclass might be thrown if a JDBC Connection couldn't be closed after it had been used
successfully. Note that data access code might perform resources cleanup in a `finally` block and therefore log
cleanup failure rather than rethrow it, to keep the original data access exception, if any.

Deprecated since Spring 6.0.3: in favor of custom exception handling or a NonTransientDataAccessException.
+/
deprecated("since Spring 6.0.3") class CleanupFailureDataAccessException : NonTransientDataAccessException
{
    /// Construct a `CleanupFailureDataAccessException` with the specified detail message and the root cause.
    this(string msg, Throwable cause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Exception thrown on various data access concurrency failures. This exception provides subclasses for specific types
of failure, in particular optimistic locking versus pessimistic locking.
+/
class ConcurrencyFailureException : TransientDataAccessException
{
    /// Construct a `ConcurrencyFailureException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Exception thrown on an optimistic locking violation. This exception will be thrown either by O/R mapping tools or by
custom DAO implementations. Optimistic locking failure is typically not detected by the database itself.
+/
class OptimisticLockingFailureException : ConcurrencyFailureException
{
    /// Construct a `OptimisticLockingFailureException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Exception thrown on a pessimistic locking violation. Thrown by Spring's SQLException translation mechanism if a
corresponding database error is encountered. Serves as a superclass for more specific exceptions, for example,
`CannotAcquireLockException`. However, it is generally recommended to handle `PessimisticLockingFailureException`
itself instead of relying on specific exception subclasses.
+/
class PessimisticLockingFailureException : ConcurrencyFailureException
{
    /// Construct a `PessimisticLockingFailureException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Exception thrown on failure to acquire a lock during an update, for example during a "select for update" statement.
Consider handling the general `PessimisticLockingFailureException` instead, semantically including a wider range of
locking-related failures.
+/
class CannotAcquireLockException : PessimisticLockingFailureException
{
    /// Construct a `CannotAcquireLockException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Exception thrown on failure to complete a transaction in serialized mode due to update conflicts. Consider handling
the general `PessimisticLockingFailureException` instead, semantically including a wider range of locking-related
failures.

Deprecated since Spring 6.0.3: in favor of PessimisticLockingFailureException/CannotAcquireLockException.
+/
deprecated("since Spring 6.0.3") class CannotSerializeTransactionException : PessimisticLockingFailureException
{
    /// Construct a `CannotSerializeTransactionException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Generic exception thrown when the current process was a deadlock loser, and its transaction rolled back. Consider
handling the general `PessimisticLockingFailureException` instead, semantically including a wider range of locking-
related failures.

Deprecated since Spring 6.0.3: in favor of PessimisticLockingFailureException/CannotAcquireLockException.
+/
deprecated("since Spring 6.0.3") class DeadlockLoserDataAccessException : PessimisticLockingFailureException
{
    /// Construct a `DeadlockLoserDataAccessException` with the specified detail message and the root cause.
    this(string msg, Throwable cause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Exception to be thrown on a query timeout. This could have different causes depending on the database API in use but
most likely thrown after the database interrupts or stops the processing of a query before it has completed. This
exception can be thrown by user code trapping the native database exception or by exception translation.
+/
class QueryTimeoutException : TransientDataAccessException
{
    /// Construct a `QueryTimeoutException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/++
Data access exception thrown when a resource fails temporarily and the operation can be retried.
+/
class TransientDataAccessResourceException : TransientDataAccessException
{
    /// Construct a `TransientDataAccessResourceException` with the specified detail message and, optionally, the root cause.
    this(string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }
}

/// Decimal text of `value`, for exception messages built in `pure nothrow` constructors.
private string decimal(long value) pure nothrow
{
    if (value == 0)
        return "0";
    char[20] digits;
    size_t start = digits.length;
    const negative = value < 0;
    ulong magnitude = negative ? -(cast(ulong) value) : cast(ulong) value;
    while (magnitude != 0)
    {
        digits[--start] = cast(char)('0' + magnitude % 10);
        magnitude /= 10;
    }
    return (negative ? "-" : "") ~ digits[start .. $].idup;
}
