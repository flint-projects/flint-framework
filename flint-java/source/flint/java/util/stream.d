/++
`java.util.stream` (rulebook R10): a lazy, sequential `Stream!T` with Java's method names, and `Collectors`.

Elements are pulled one at a time through a delegate, so intermediate operations run lazily and short-circuiting
terminals (`findFirst`, `anyMatch`, `limit`) evaluate only what they need, in Java's order. Parallel streams are not
offered: `parallel()` returns the same sequential stream.
+/
module flint.java.util.stream;

import flint.java.lang : IllegalStateException, valueOf;
import flint.java.util : ArrayList, Collection, Comparator, HashMap, Iterator, LinkedHashMap,
    LinkedHashSet, List, Map, NoSuchElementException, Optional, Set, compareNatural, stableSort;

@safe:

/// Java's `Stream`: a lazy sequence of elements with aggregate operations.
final class Stream(T)
{
    private bool delegate(out T) @safe pull;
    private bool consumed;

    private this(bool delegate(out T) @safe pull) pure nothrow @nogc
    {
        this.pull = pull;
    }

    /// A stream of a copy of `items`.
    static Stream!T ofArray(T[] items)
    {
        size_t position;
        return new Stream!T((out T next) {
            if (position >= items.length)
                return false;
            next = items[position++];
            return true;
        });
    }

    /// A stream of `items`.
    static Stream!T of(T[] items...)
    {
        return ofArray(items.dup);
    }

    /// The empty stream.
    static Stream!T empty()
    {
        return new Stream!T((out T next) => false);
    }

    /// `a`'s elements, then `b`'s.
    static Stream!T concat(Stream!T a, Stream!T b)
    {
        auto first = a.take(), second = b.take();
        bool onSecond;
        return new Stream!T((out T next) {
            if (!onSecond)
            {
                if (first(next))
                    return true;
                onSecond = true;
            }
            return second(next);
        });
    }

    /// `seed`, `next(seed)`, `next(next(seed))`, ...: an infinite stream; bound it with `limit`.
    static Stream!T iterate(T seed, T delegate(T) @safe next)
    {
        bool started;
        T current = seed;
        return new Stream!T((out T element) {
            if (started)
                current = next(current);
            started = true;
            element = current;
            return true;
        });
    }

    private bool delegate(out T) @safe take()
    {
        if (consumed)
            throw new IllegalStateException("stream has already been operated upon or closed");
        consumed = true;
        return pull;
    }

    /// The elements matching `predicate`.
    Stream!T filter(bool delegate(T) @safe predicate)
    {
        auto source = take();
        return new Stream!T((out T next) {
            while (source(next))
                if (predicate(next))
                    return true;
            return false;
        });
    }

    /// Each element transformed by `mapper`.
    Stream!R map(R)(R delegate(T) @safe mapper)
    {
        auto source = take();
        return new Stream!R((out R next) {
            T element;
            if (!source(element))
                return false;
            next = mapper(element);
            return true;
        });
    }

    /// The elements of the stream `mapper` returns for each element, in order.
    Stream!R flatMap(R)(Stream!R delegate(T) @safe mapper)
    {
        auto source = take();
        bool delegate(out R) @safe inner;
        return new Stream!R((out R next) {
            for (;;)
            {
                if (inner !is null && inner(next))
                    return true;
                T element;
                if (!source(element))
                    return false;
                inner = mapper(element).take();
            }
        });
    }

    /// Java's `mapToInt`: each element as an `int`.
    Stream!int mapToInt(int delegate(T) @safe mapper)
    {
        return map!int(mapper);
    }

    /// Java's `mapToLong`: each element as a `long`.
    Stream!long mapToLong(long delegate(T) @safe mapper)
    {
        return map!long(mapper);
    }

    /// The elements without duplicates, keeping the first occurrence.
    Stream!T distinct()
    {
        auto source = take();
        static if (!__traits(compiles, { bool[T] probe; probe[T.init] = true; }))
        {
            // A mutable array cannot key an associative array (Java's List<Object[]>): compare by value.
            T[] seen;
            return new Stream!T((out T next) {
                while (source(next))
                {
                    bool duplicate;
                    foreach (previous; seen)
                        if (previous == next)
                        {
                            duplicate = true;
                            break;
                        }
                    if (duplicate)
                        continue;
                    seen ~= next;
                    return true;
                }
                return false;
            });
        }
        else
        {
            bool[T] seen;
            return new Stream!T((out T next) {
                while (source(next))
                {
                    if (next in seen)
                        continue;
                    seen[next] = true;
                    return true;
                }
                return false;
            });
        }
    }

    /// The elements in natural order (stable).
    Stream!T sorted()
    {
        auto items = toArray();
        stableSort(items, (T a, T b) => compareNatural(a, b));
        return ofArray(items);
    }

    /// The elements ordered by `comparator` (stable).
    Stream!T sorted(Comparator!T comparator)
    {
        auto items = toArray();
        stableSort(items, &comparator.compare);
        return ofArray(items);
    }

    /// The elements ordered by `compare` (stable).
    Stream!T sorted(int delegate(T, T) @safe compare)
    {
        auto items = toArray();
        stableSort(items, compare);
        return ofArray(items);
    }

    /// Each element, after calling `action` on it as it passes.
    Stream!T peek(void delegate(T) @safe action)
    {
        auto source = take();
        return new Stream!T((out T next) {
            if (!source(next))
                return false;
            action(next);
            return true;
        });
    }

    /// At most the first `maxSize` elements.
    Stream!T limit(long maxSize)
    {
        if (maxSize < 0)
            throw new IllegalArgumentException(valueOf(maxSize));
        auto source = take();
        long taken;
        return new Stream!T((out T next) {
            if (taken >= maxSize || !source(next))
                return false;
            taken++;
            return true;
        });
    }

    /// The elements after the first `n`.
    Stream!T skip(long n)
    {
        if (n < 0)
            throw new IllegalArgumentException(valueOf(n));
        auto source = take();
        long skipped;
        return new Stream!T((out T next) {
            while (skipped < n)
            {
                T ignored;
                if (!source(ignored))
                    return false;
                skipped++;
            }
            return source(next);
        });
    }

    /// The same stream: Flint streams are sequential.
    Stream!T parallel() pure nothrow @nogc
    {
        return this;
    }

    /// The same stream.
    Stream!T sequential() pure nothrow @nogc
    {
        return this;
    }

    /// Call `action` on each element.
    void forEach(void delegate(T) @safe action)
    {
        auto source = take();
        T next;
        while (source(next))
            action(next);
    }

    /// Call `action` on each element, in order.
    void forEachOrdered(void delegate(T) @safe action)
    {
        forEach(action);
    }

    /// The elements as a new D array.
    T[] toArray()
    {
        auto source = take();
        T[] result;
        T next;
        while (source(next))
            result ~= next;
        return result;
    }

    /// The elements as an unmodifiable list (Java 16's `Stream.toList`).
    List!T toList()
    {
        return List!T.of(toArray());
    }

    /// Collect the elements with a collector from `Collectors`.
    auto collect(C)(C collector)
    {
        return collector.apply(toArray());
    }

    /// How many elements.
    long count()
    {
        auto source = take();
        long n;
        T next;
        while (source(next))
            n++;
        return n;
    }

    /// The first element, or empty.
    Optional!T findFirst()
    {
        auto source = take();
        T next;
        return source(next) ? Optional!T.ofNullable(next) : Optional!T.empty();
    }

    /// Some element (the first: Flint streams are sequential), or empty.
    Optional!T findAny()
    {
        return findFirst();
    }

    /// Whether any element matches.
    bool anyMatch(bool delegate(T) @safe predicate)
    {
        auto source = take();
        T next;
        while (source(next))
            if (predicate(next))
                return true;
        return false;
    }

    /// Whether every element matches (true for an empty stream).
    bool allMatch(bool delegate(T) @safe predicate)
    {
        auto source = take();
        T next;
        while (source(next))
            if (!predicate(next))
                return false;
        return true;
    }

    /// Whether no element matches.
    bool noneMatch(bool delegate(T) @safe predicate)
    {
        return !anyMatch(predicate);
    }

    /// The least element under `comparator`, or empty.
    Optional!T min(Comparator!T comparator)
    {
        return reduce((T a, T b) => comparator.compare(b, a) < 0 ? b : a);
    }

    /// The greatest element under `comparator`, or empty.
    Optional!T max(Comparator!T comparator)
    {
        return reduce((T a, T b) => comparator.compare(b, a) > 0 ? b : a);
    }

    /// Fold the elements with `accumulator`, starting from `identity`.
    T reduce(T identity, T delegate(T, T) @safe accumulator)
    {
        auto source = take();
        T result = identity, next;
        while (source(next))
            result = accumulator(result, next);
        return result;
    }

    /// Fold the elements with `accumulator`; empty for an empty stream.
    Optional!T reduce(T delegate(T, T) @safe accumulator)
    {
        auto source = take();
        T result, next;
        if (!source(result))
            return Optional!T.empty();
        while (source(next))
            result = accumulator(result, next);
        return Optional!T.ofNullable(result);
    }

    static if (__traits(isArithmetic, T))
    {
        /// The sum of the elements (Java's `IntStream.sum`).
        T sum()
        {
            return reduce(cast(T) 0, (T a, T b) => cast(T)(a + b));
        }
    }

    /// An iterator over the remaining elements.
    Iterator!T iterator()
    {
        return new StreamIterator!T(take());
    }
}

private final class StreamIterator(T) : Iterator!T
{
    private bool delegate(out T) @safe source;
    private bool buffered, finished;
    private T buffer;

    this(bool delegate(out T) @safe source) pure nothrow @nogc
    {
        this.source = source;
    }

    bool hasNext()
    {
        if (!buffered && !finished)
        {
            buffered = source(buffer);
            finished = !buffered;
        }
        return buffered;
    }

    T next()
    {
        if (!hasNext())
            throw new NoSuchElementException();
        buffered = false;
        return buffer;
    }

    void remove()
    {
        import flint.java.lang : UnsupportedOperationException;

        throw new UnsupportedOperationException("remove");
    }
}

private import flint.java.lang : IllegalArgumentException;

/// Java's `Collectors`: the common terminal reductions for `Stream.collect`.
struct Collectors
{
    /// The elements as a mutable `ArrayList`.
    static ToList toList() pure nothrow @nogc
    {
        return ToList.init;
    }

    /// The elements as an unmodifiable list.
    static ToUnmodifiableList toUnmodifiableList() pure nothrow @nogc
    {
        return ToUnmodifiableList.init;
    }

    /// The elements as a mutable `HashSet` (insertion order).
    static ToSet toSet() pure nothrow @nogc
    {
        return ToSet.init;
    }

    /// The elements as strings, concatenated with `delimiter`, between `prefix` and `suffix`.
    static Joining joining(string delimiter = "", string prefix = "", string suffix = "") pure nothrow @nogc
    {
        return Joining(delimiter, prefix, suffix);
    }

    /// The number of elements.
    static Counting counting() pure nothrow @nogc
    {
        return Counting.init;
    }

    /// A map from `keyMapper`'s result to `valueMapper`'s. A duplicate key throws `IllegalStateException`.
    static ToMap!(KF, VF) toMap(KF, VF)(KF keyMapper, VF valueMapper)
    {
        return ToMap!(KF, VF)(keyMapper, valueMapper);
    }

    /// The elements grouped into lists by `classifier`'s result, in first-seen order.
    static GroupingBy!F groupingBy(F)(F classifier)
    {
        return GroupingBy!F(classifier);
    }
}

/// `Collectors.toList()`.
struct ToList
{
    /// Collect `items`.
    List!E apply(E)(E[] items)
    {
        return new ArrayList!E(items);
    }
}

/// `Collectors.toUnmodifiableList()`.
struct ToUnmodifiableList
{
    /// Collect `items`.
    List!E apply(E)(E[] items)
    {
        return List!E.of(items);
    }
}

/// `Collectors.toSet()`.
struct ToSet
{
    /// Collect `items`.
    Set!E apply(E)(E[] items)
    {
        return new LinkedHashSet!E(items);
    }
}

/// `Collectors.joining(...)`.
struct Joining
{
    /// Between elements.
    string delimiter;
    /// Before the first element.
    string prefix;
    /// After the last element.
    string suffix;

    /// Collect `items`.
    string apply(E)(E[] items)
    {
        string result = prefix;
        foreach (i, e; items)
        {
            if (i)
                result ~= delimiter;
            result ~= valueOf(e);
        }
        return result ~ suffix;
    }
}

/// `Collectors.counting()`.
struct Counting
{
    /// Collect `items`.
    long apply(E)(E[] items)
    {
        return cast(long) items.length;
    }
}

/// `Collectors.toMap(keyMapper, valueMapper)`.
struct ToMap(KF, VF)
{
    /// Computes each key.
    KF keyMapper;
    /// Computes each value.
    VF valueMapper;

    /// Collect `items`.
    auto apply(E)(E[] items)
    {
        alias K = typeof(keyMapper(E.init));
        alias V = typeof(valueMapper(E.init));
        Map!(K, V) result = new HashMap!(K, V)();
        foreach (e; items)
        {
            auto key = keyMapper(e);
            auto value = valueMapper(e);
            if (result.containsKey(key))
                throw duplicateKey(valueOf(key), valueOf(result.get(key)), valueOf(value));
            result.put(key, value);
        }
        return result;
    }
}

private IllegalStateException duplicateKey(string key, string existing, string added)
{
    return new IllegalStateException(
            "Duplicate key " ~ key ~ " (attempted merging values " ~ existing ~ " and " ~ added ~ ")");
}

/// `Collectors.groupingBy(classifier)`.
struct GroupingBy(F)
{
    /// Computes each element's group.
    F classifier;

    /// Collect `items`.
    auto apply(E)(E[] items)
    {
        alias K = typeof(classifier(E.init));
        Map!(K, List!E) result = new LinkedHashMap!(K, List!E)();
        foreach (e; items)
        {
            auto key = classifier(e);
            auto group = result.get(key);
            if (group is null)
            {
                group = new ArrayList!E();
                result.put(key, group);
            }
            group.add(e);
        }
        return result;
    }
}

/// Collections of `T` as streams, for code that holds a D array: `stream(items).filter(...)`.
Stream!T stream(T)(T[] items)
{
    return Stream!T.ofArray(items);
}

/// The elements of `collection` as a stream.
Stream!T stream(T)(Collection!T collection)
{
    return collection.stream();
}
