/++
`java.util.concurrent.atomic`: lock-free atomic values over `core.atomic` (clean-room from the Java SE
specification).
+/
module flint.java.util.concurrent.atomic;

import core.atomic : atomicExchange, atomicLoad, atomicOp, atomicStore, cas;

@safe:

/// `java.util.concurrent.atomic.AtomicLong`.
final class AtomicLong
{
    private shared long value;

    /// An atomic long starting at `initialValue`.
    this(long initialValue = 0) nothrow @nogc
    {
        atomicStore(value, initialValue);
    }

    /// Adds one and returns the new value.
    long incrementAndGet() nothrow @nogc
    {
        return atomicOp!"+="(value, 1);
    }

    /// Returns the value, then adds one.
    long getAndIncrement() nothrow @nogc
    {
        return atomicOp!"+="(value, 1) - 1;
    }

    /// The value.
    long get() nothrow @nogc
    {
        return atomicLoad(value);
    }

    /// Sets the value.
    void set(long newValue) nothrow @nogc
    {
        atomicStore(value, newValue);
    }

    /// Subtracts one and returns the new value.
    long decrementAndGet() nothrow @nogc
    {
        return atomicOp!"-="(value, 1);
    }

    /// Returns the value, then subtracts one.
    long getAndDecrement() nothrow @nogc
    {
        return atomicOp!"-="(value, 1) + 1;
    }

    /// Adds `delta` and returns the new value.
    long addAndGet(long delta) nothrow @nogc
    {
        return atomicOp!"+="(value, delta);
    }

    /// Returns the value, then adds `delta`.
    long getAndAdd(long delta) nothrow @nogc
    {
        return atomicOp!"+="(value, delta) - delta;
    }

    /// Sets `newValue` and returns the previous value.
    long getAndSet(long newValue) nothrow @nogc
    {
        return atomicExchange(&value, newValue);
    }

    /// Sets `newValue` when the value is `expectedValue`; whether it did.
    bool compareAndSet(long expectedValue, long newValue) nothrow @nogc
    {
        return cas(&value, expectedValue, newValue);
    }

    /// The decimal value.
    override string toString() const
    {
        import std.conv : to;

        return atomicLoad(value).to!string;
    }
}

/// `java.util.concurrent.atomic.AtomicInteger`.
final class AtomicInteger
{
    private shared int value;

    /// An atomic integer starting at `initialValue`.
    this(int initialValue = 0) nothrow @nogc
    {
        atomicStore(value, initialValue);
    }

    /// Adds one and returns the new value.
    int incrementAndGet() nothrow @nogc
    {
        return atomicOp!"+="(value, 1);
    }

    /// Returns the value, then adds one.
    int getAndIncrement() nothrow @nogc
    {
        return atomicOp!"+="(value, 1) - 1;
    }

    /// The value.
    int get() nothrow @nogc
    {
        return atomicLoad(value);
    }

    /// Sets the value.
    void set(int newValue) nothrow @nogc
    {
        atomicStore(value, newValue);
    }
}

/// `java.util.concurrent.atomic.AtomicBoolean`.
final class AtomicBoolean
{
    private shared bool value;

    /// An atomic boolean starting at `initialValue`.
    this(bool initialValue = false) nothrow @nogc
    {
        atomicStore(value, initialValue);
    }

    /// The value.
    bool get() nothrow @nogc
    {
        return atomicLoad(value);
    }

    /// Sets the value.
    void set(bool newValue) nothrow @nogc
    {
        atomicStore(value, newValue);
    }

    /// Sets `newValue` when the value is `expectedValue`; whether it did.
    bool compareAndSet(bool expectedValue, bool newValue) nothrow @nogc
    {
        return cas(&value, expectedValue, newValue);
    }

    /// Sets `newValue` and returns the previous value.
    bool getAndSet(bool newValue) nothrow @nogc
    {
        return atomicExchange(&value, newValue);
    }
}
