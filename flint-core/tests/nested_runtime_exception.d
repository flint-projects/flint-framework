module flint.core.nested_runtime_exception_test;

import flint.core : NestedRuntimeException;
import flint.java.io : IOException;
import flint.java.lang : IllegalArgumentException, IllegalStateException, RuntimeException;

@safe:

private final class DataFailure : NestedRuntimeException
{
    this(string msg, Throwable cause = null)
    {
        super(msg, cause);
    }
}

private final class LockFailure : NestedRuntimeException
{
    this(string msg, Throwable cause = null)
    {
        super(msg, cause);
    }
}

@("a nested runtime exception keeps Java's message and cause, not D's collateral chain")
unittest
{
    auto cause = new IllegalStateException("socket closed");
    auto failure = new DataFailure("could not read row", cause);
    assert(failure.getMessage() == "could not read row");
    assert(failure.getCause() is cause);
    assert(failure.next is null);
    assert(new DataFailure("plain").getCause() is null);
}

@("getRootCause returns the innermost cause, or null; getMostSpecificCause falls back to the exception")
unittest
{
    auto root = new IllegalArgumentException("bad column");
    auto middle = new RuntimeException("statement failed", root);
    auto failure = new DataFailure("query failed", middle);
    assert(failure.getRootCause() is root);
    assert(failure.getMostSpecificCause() is root);

    auto alone = new DataFailure("no cause");
    assert(alone.getRootCause() is null);
    assert(alone.getMostSpecificCause() is alone);
}

@("contains finds the exception itself, a subclass, or a nested cause of the given type")
unittest
{
    auto root = new IllegalArgumentException("bad column");
    auto failure = new DataFailure("query failed", new LockFailure("lock", new RuntimeException("x", root)));
    assert(failure.contains!DataFailure());
    assert(failure.contains!NestedRuntimeException());
    assert(failure.contains!LockFailure());
    assert(failure.contains!IllegalArgumentException());
    assert(failure.contains!RuntimeException());
    assert(!failure.contains!IllegalStateException());
    assert(!failure.contains(null));
    assert(failure.contains(typeid(IllegalArgumentException)));
}

@("contains follows a checked cause one level, and stops at the end of the chain")
unittest
{
    // The walk sees a checked flint.java cause itself; past it, only RuntimeException causes are recorded.
    auto failure = new DataFailure("read failed", new IOException("disk"));
    assert(failure.contains!IOException());
    assert(!failure.contains!IllegalStateException());

    auto looping = new RuntimeException("loop");
    looping.initCause(new RuntimeException("inner"));
    auto outer = new DataFailure("outer", looping);
    assert(!outer.contains!IllegalStateException());
    assert(outer.getRootCause() !is null);
}
