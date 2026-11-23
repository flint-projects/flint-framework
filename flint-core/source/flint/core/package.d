// Ported from spring-framework v7.1.0: spring-core/src/main/java/org/springframework/core/NestedRuntimeException.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.

/++
`org.springframework.core`, as far as the Phase 1 data-access port needs it: `NestedRuntimeException`, the base of
Spring's `DataAccessException` and `TransactionException` hierarchies. framework-core owns this module.
+/
module flint.core;

import flint.java.lang : RuntimeException;

@safe:

/++
Handy class for wrapping runtime exceptions with a root cause. This class is `abstract` to force the programmer to
extend the class.

The cause is Java's (`getCause`), not D's collateral chain (`Throwable.next`).
+/
abstract class NestedRuntimeException : RuntimeException
{
    /// Construct a `NestedRuntimeException` with the specified detail message.
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, null, file, line);
    }

    /// Construct a `NestedRuntimeException` with the specified detail message and nested exception.
    this(string msg, Throwable cause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, cause, file, line);
    }

    /// Retrieve the innermost cause of this exception, if any; `null` if none.
    Throwable getRootCause() pure nothrow @nogc
    {
        return rootCauseOf(this);
    }

    /// Retrieve the most specific cause of this exception: either the innermost cause (root cause) or this
    /// exception itself. Differs from `getRootCause()` in that it falls back to the present exception.
    Throwable getMostSpecificCause() pure nothrow @nogc
    {
        auto rootCause = getRootCause();
        return rootCause !is null ? rootCause : this;
    }

    /// Check whether this exception contains an exception of the given type: either it is of the given class
    /// itself or it contains a nested cause of the given type (rule R4: `contains!DataAccessException()`).
    bool contains(T : Throwable)() pure nothrow @nogc
    {
        return contains(typeid(T));
    }

    /// The runtime form of `contains`, for a type token held in a variable. `null` contains nothing.
    bool contains(const TypeInfo_Class exType) pure nothrow @nogc
    {
        if (exType is null)
            return false;
        if (isInstance(exType, this))
            return true;
        Throwable cause = getCause();
        if (cause is this)
            return false;
        if (auto exception = cast(NestedRuntimeException) cause)
            return exception.contains(exType);
        while (cause !is null)
        {
            if (isInstance(exType, cause))
                return true;
            if (causeOf(cause) is cause)
                break;
            cause = causeOf(cause);
        }
        return false;
    }
}

/// Java's `Class.isInstance`: whether `value` is of class `type` or a subclass of it.
private bool isInstance(const TypeInfo_Class type, const Throwable value) pure nothrow @nogc
{
    return value !is null && (typeid(value) is type || type.isBaseOf(typeid(value)));
}

/// Java's `Throwable.getCause()` for any throwable. D throwables outside `flint.java` record no Java cause.
private Throwable causeOf(Throwable t) pure nothrow @nogc
{
    if (auto runtime = cast(RuntimeException) t)
        return runtime.getCause();
    return null;
}

/// `NestedExceptionUtils.getRootCause`: the innermost cause, `null` when there is none, stopping at a cycle.
private Throwable rootCauseOf(Throwable original) pure nothrow @nogc
{
    Throwable rootCause = null;
    Throwable cause = causeOf(original);
    while (cause !is null && cause !is rootCause)
    {
        rootCause = cause;
        cause = causeOf(cause);
    }
    return rootCause;
}
