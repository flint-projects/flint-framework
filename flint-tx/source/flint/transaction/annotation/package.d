// Ported from spring-framework v7.1.0: spring-tx/src/main/java/org/springframework/transaction/annotation/Propagation.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.

/++
`org.springframework.transaction.annotation`: the `Propagation` and `Isolation` enums `@Transactional` uses. An
annotation module is a leaf (rule R2), so the values are the `TransactionDefinition` constants written out, and
Java's `value()` is a free function called through UFCS: `Propagation.REQUIRES_NEW.value()`.

`@Transactional` follows once `flint.core.annotation` (`AliasFor`, `ClassRef`) is in `flint:core`.
Ported from Propagation.java and Isolation.java.
+/
module flint.transaction.annotation;

@safe:

/// Enumeration that represents transaction propagation behaviors for use with the `Transactional` annotation,
/// corresponding to the `TransactionDefinition` interface.
enum Propagation : int
{
    /// Support a current transaction, create a new one if none exists. The default setting.
    REQUIRED = 0,
    /// Support a current transaction, execute non-transactionally if none exists.
    SUPPORTS = 1,
    /// Support a current transaction, throw an exception if none exists.
    MANDATORY = 2,
    /// Create a new transaction, and suspend the current transaction if one exists.
    REQUIRES_NEW = 3,
    /// Execute non-transactionally, suspend the current transaction if one exists.
    NOT_SUPPORTED = 4,
    /// Execute non-transactionally, throw an exception if a transaction exists.
    NEVER = 5,
    /// Execute within a nested transaction if a current transaction exists, behave like `REQUIRED` otherwise.
    NESTED = 6,
}

/// Enumeration that represents transaction isolation levels for use with the `Transactional` annotation,
/// corresponding to the `TransactionDefinition` interface.
enum Isolation : int
{
    /// Use the default isolation level of the underlying datastore.
    DEFAULT = -1,
    /// A constant indicating that dirty reads, non-repeatable reads, and phantom reads can occur.
    READ_UNCOMMITTED = 1,
    /// A constant indicating that dirty reads are prevented; non-repeatable reads and phantom reads can occur.
    READ_COMMITTED = 2,
    /// A constant indicating that dirty reads and non-repeatable reads are prevented; phantom reads can occur.
    REPEATABLE_READ = 4,
    /// A constant indicating that dirty reads, non-repeatable reads, and phantom reads are prevented.
    SERIALIZABLE = 8,
}

/// The `TransactionDefinition` propagation constant of `propagation`.
int value(Propagation propagation) pure nothrow @nogc
{
    return cast(int) propagation;
}

/// The `TransactionDefinition` isolation constant of `isolation`.
int value(Isolation isolation) pure nothrow @nogc
{
    return cast(int) isolation;
}
