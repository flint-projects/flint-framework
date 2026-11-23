/++
`java.util.function` (rulebook R9). The module is `function_` because `function` is a D keyword (deviation D-15).

Each functional interface stays an interface, and every Flint API that takes one also accepts a D delegate with the
same parameter and result types, so lambdas infer and no template is instantiated per call site. `of` adapts a
delegate to the interface; `asDelegate` goes the other way.
+/
module flint.java.util.function_;

@safe:

/// Java's `Supplier`: a source of results.
interface Supplier(T)
{
    /// A result.
    T get();

    /// The `get` method as a delegate.
    final T delegate() @safe asDelegate()
    {
        return &get;
    }

    /// A `Supplier` calling `dg`.
    static Supplier!T of(T delegate() @safe dg)
    {
        return new DelegateSupplier!(T)(dg);
    }
}

/// Java's `Function`: a one-argument function.
interface Function(T, R)
{
    /// Apply the function to `t`.
    R apply(T t);

    /// The `apply` method as a delegate.
    final R delegate(T) @safe asDelegate()
    {
        return &apply;
    }

    /// First this function, then `after`.
    Function!(T, V) andThen(V)(Function!(R, V) after)
    {
        auto self = this;
        return Function!(T, V).of((T t) => after.apply(self.apply(t)));
    }

    /// First `before`, then this function.
    Function!(V, R) compose(V)(Function!(V, T) before)
    {
        auto self = this;
        return Function!(V, R).of((V v) => self.apply(before.apply(v)));
    }

    /// A `Function` calling `dg`.
    static Function!(T, R) of(R delegate(T) @safe dg)
    {
        return new DelegateFunction!(T, R)(dg);
    }

    /// The identity function (when `T` and `R` are the same type).
    static if (is(T == R))
    {
        /// Java's `Function.identity()`.
        static Function!(T, T) identity()
        {
            return of((T t) => t);
        }
    }
}

/// Java's `BiFunction`: a two-argument function.
interface BiFunction(T, U, R)
{
    /// Apply the function.
    R apply(T t, U u);

    /// The `apply` method as a delegate.
    final R delegate(T, U) @safe asDelegate()
    {
        return &apply;
    }

    /// A `BiFunction` calling `dg`.
    static BiFunction!(T, U, R) of(R delegate(T, U) @safe dg)
    {
        return new DelegateBiFunction!(T, U, R)(dg);
    }
}

/// Java's `UnaryOperator`: a `Function` from a type to itself.
interface UnaryOperator(T) : Function!(T, T)
{
}

/// Java's `BinaryOperator`: a `BiFunction` of two values of a type to that type.
interface BinaryOperator(T) : BiFunction!(T, T, T)
{
}

/// Java's `Consumer`: an operation on one argument with no result.
interface Consumer(T)
{
    /// Perform the operation on `t`.
    void accept(T t);

    /// The `accept` method as a delegate.
    final void delegate(T) @safe asDelegate()
    {
        return &accept;
    }

    /// First this consumer, then `after`.
    final Consumer!T andThen(Consumer!T after)
    {
        auto self = this;
        return of((T t) { self.accept(t); after.accept(t); });
    }

    /// A `Consumer` calling `dg`.
    static Consumer!T of(void delegate(T) @safe dg)
    {
        return new DelegateConsumer!(T)(dg);
    }
}

/// Java's `BiConsumer`: an operation on two arguments with no result.
interface BiConsumer(T, U)
{
    /// Perform the operation.
    void accept(T t, U u);

    /// The `accept` method as a delegate.
    final void delegate(T, U) @safe asDelegate()
    {
        return &accept;
    }

    /// A `BiConsumer` calling `dg`.
    static BiConsumer!(T, U) of(void delegate(T, U) @safe dg)
    {
        return new DelegateBiConsumer!(T, U)(dg);
    }
}

/// Java's `Predicate`: a boolean-valued function of one argument.
interface Predicate(T)
{
    /// Whether `t` matches.
    bool test(T t);

    /// The `test` method as a delegate.
    final bool delegate(T) @safe asDelegate()
    {
        return &test;
    }

    /// Both this and `other`, short-circuiting.
    final Predicate!T and(Predicate!T other)
    {
        auto self = this;
        return of((T t) => self.test(t) && other.test(t));
    }

    /// This or `other`, short-circuiting.
    final Predicate!T or(Predicate!T other)
    {
        auto self = this;
        return of((T t) => self.test(t) || other.test(t));
    }

    /// The logical negation of this predicate.
    final Predicate!T negate()
    {
        auto self = this;
        return of((T t) => !self.test(t));
    }

    /// A `Predicate` calling `dg`.
    static Predicate!T of(bool delegate(T) @safe dg)
    {
        return new DelegatePredicate!(T)(dg);
    }

    /// Java's `Predicate.not(target)`.
    static Predicate!T not(Predicate!T target)
    {
        return target.negate();
    }
}

/// Java's `BiPredicate`: a boolean-valued function of two arguments.
interface BiPredicate(T, U)
{
    /// Whether `t` and `u` match.
    bool test(T t, U u);

    /// A `BiPredicate` calling `dg`.
    static BiPredicate!(T, U) of(bool delegate(T, U) @safe dg)
    {
        return new DelegateBiPredicate!(T, U)(dg);
    }
}

/// Java's `BooleanSupplier`.
interface BooleanSupplier
{
    /// A result.
    bool getAsBoolean();
}

/// Java's `IntFunction`.
interface IntFunction(R)
{
    /// Apply the function to `value`.
    R apply(int value);
}

/// Java's `ToIntFunction`.
interface ToIntFunction(T)
{
    /// Apply the function to `value`.
    int applyAsInt(T value);
}

/// Java's `ToLongFunction`.
interface ToLongFunction(T)
{
    /// Apply the function to `value`.
    long applyAsLong(T value);
}

private final class DelegateSupplier(T) : Supplier!(T)
{
    private T delegate() @safe dg;

    this(T delegate() @safe dg) pure nothrow @nogc
    {
        this.dg = dg;
    }

    T get()
    {
        return dg();
    }
}

private final class DelegateFunction(T, R) : Function!(T, R)
{
    private R delegate(T) @safe dg;

    this(R delegate(T) @safe dg) pure nothrow @nogc
    {
        this.dg = dg;
    }

    R apply(T t)
    {
        return dg(t);
    }
}

private final class DelegateBiFunction(T, U, R) : BiFunction!(T, U, R)
{
    private R delegate(T, U) @safe dg;

    this(R delegate(T, U) @safe dg) pure nothrow @nogc
    {
        this.dg = dg;
    }

    R apply(T t, U u)
    {
        return dg(t, u);
    }
}

private final class DelegateConsumer(T) : Consumer!(T)
{
    private void delegate(T) @safe dg;

    this(void delegate(T) @safe dg) pure nothrow @nogc
    {
        this.dg = dg;
    }

    void accept(T t)
    {
        dg(t);
    }
}

private final class DelegateBiConsumer(T, U) : BiConsumer!(T, U)
{
    private void delegate(T, U) @safe dg;

    this(void delegate(T, U) @safe dg) pure nothrow @nogc
    {
        this.dg = dg;
    }

    void accept(T t, U u)
    {
        dg(t, u);
    }
}

private final class DelegatePredicate(T) : Predicate!(T)
{
    private bool delegate(T) @safe dg;

    this(bool delegate(T) @safe dg) pure nothrow @nogc
    {
        this.dg = dg;
    }

    bool test(T t)
    {
        return dg(t);
    }
}

private final class DelegateBiPredicate(T, U) : BiPredicate!(T, U)
{
    private bool delegate(T, U) @safe dg;

    this(bool delegate(T, U) @safe dg) pure nothrow @nogc
    {
        this.dg = dg;
    }

    bool test(T t, U u)
    {
        return dg(t, u);
    }
}
