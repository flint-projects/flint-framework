// Ported from spring-framework v7.1.0: spring-tx/src/main/java/org/springframework/transaction/annotation/Transactional.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.

/++
`org.springframework.transaction.annotation`: `@Transactional` and the `Propagation` and `Isolation` enums it uses.
An annotation module is a leaf (rule R2): it imports only `flint.core.annotation`, so the enum values are the
`TransactionDefinition` constants written out, and Java's `value()` is a free function called through UFCS:
`Propagation.REQUIRES_NEW.value()`.

Flint AOT applies `@Transactional` through a proxy subclass whose advice chain holds `TransactionInterceptor`
(aot-contract section 7). `Class`-valued attributes are `ClassRef`s: `rollbackFor: [classOf!IOException]`.
Also ported from Propagation.java and Isolation.java.
+/
module flint.transaction.annotation;

import flint.core.annotation : AliasFor, ClassRef;

@safe:

/++
Describes a transaction attribute on an individual method or on a class. When this annotation is declared at the
class level, it applies as a default to all methods of the declaring class and its subclasses. Method-level
declarations override class-level ones.

Rollback rules: by default, a transaction rolls back on `RuntimeException` and `Error` but not on checked exceptions
(other D `Exception`s). `rollbackFor`, `rollbackForClassName`, `noRollbackFor` and `noRollbackForClassName` add rules;
the rule closest to the thrown exception's class wins.
+/
struct Transactional
{
    /// Alias for `transactionManager`.
    @AliasFor("transactionManager") string value;
    /// A qualifier value for the specified transaction: the bean name or qualifier of the `TransactionManager`.
    @AliasFor("value") string transactionManager;
    /// Defines zero (0) or more transaction labels, for descriptive purposes or custom transaction managers.
    string[] label;
    /// The transaction propagation type. Defaults to `Propagation.REQUIRED`.
    Propagation propagation = Propagation.REQUIRED;
    /// The transaction isolation level. Defaults to `Isolation.DEFAULT`.
    Isolation isolation = Isolation.DEFAULT;
    /// The timeout for this transaction, in seconds. Defaults to the transaction system's default (-1).
    int timeout = -1;
    /// The timeout as a String value, such as a placeholder.
    string timeoutString;
    /// A flag that can be set to true if the transaction is effectively read-only.
    bool readOnly;
    /// Exception types that must cause a rollback (Java's `Class<? extends Throwable>[]`).
    ClassRef[] rollbackFor;
    /// Exception name patterns that must cause a rollback.
    string[] rollbackForClassName;
    /// Exception types that must not cause a rollback.
    ClassRef[] noRollbackFor;
    /// Exception name patterns that must not cause a rollback.
    string[] noRollbackForClassName;
}

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
