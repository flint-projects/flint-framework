/++
`java.util` as Spring's APIs expose it (rulebook R5, R10, R11).

$(UL
    $(LI `Optional!T` is a struct with Java's methods (R5).)
    $(LI `Collection!T`, `List!T`, `Set!T` and `Map!(K, V)` are interfaces with Java's methods, implemented by
        `ArrayList`, `HashSet`, `LinkedHashSet`, `HashMap` and `LinkedHashMap` (R10). Every collection also
        implements the erased, non-template `RawCollection` or `RawMap`, so descriptor-driven engines (message
        conversion, validation, binding) walk them without a template instance per element type
        (ADR-030 section 5).)
    $(LI Element equality is D's `==`, which `mixin JavaObject` maps to `equals` (R11); hashing is `toHash`.)
)

Deviations, listed in the rulebook: `HashMap` and `HashSet` iterate in insertion order (Java leaves the order
unspecified), `keySet`, `values` and `entrySet` return snapshots rather than live views, and `Map.get` of a missing
key returns `V.init` (null for references and strings). `List!int` names its index removal `removeAt`, because
`remove(int)` would collide with `remove(T)`.
+/
module flint.java.util;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : TypeKind;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : ClassCastException, IllegalArgumentException, IndexOutOfBoundsException, Iterable,
    NullPointerException, RuntimeException, UnsupportedOperationException, javaEquals, javaHashCode, valueOf;
import flint.java.util.stream : Stream;
public import flint.java.util.date : Date;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Exceptions

/// Thrown when an element is requested and there is none: `Optional.get`, `Iterator.next` at the end.
class NoSuchElementException : RuntimeException
{
    /// `message`, and optionally a `cause`.
    this(string message = null, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}

/// Thrown when a collection changes while it is being iterated.
class ConcurrentModificationException : RuntimeException
{
    /// `message`, and optionally a `cause`.
    this(string message = null, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Objects

/// Java's `Objects`: null-safe helpers.
struct Objects
{
    /// Whether `a` and `b` are both null or equal.
    static bool equals(A, B)(A a, B b)
    {
        static if ((is(A == class) || is(A == interface)) && (is(B == class) || is(B == interface)))
            return javaEquals(cast(Object) a, cast(Object) b);
        else
            return a == b;
    }

    /// `hashCode()` of `o`, or 0 for null.
    static int hashCode(T)(T o)
    {
        return javaHashCode(o);
    }

    /// Java's `Objects.hash(values...)`: `31 * h + hashCode(v)` over the values, starting from 1.
    static int hash(Args...)(Args values)
    {
        int h = 1;
        foreach (v; values)
            h = 31 * h + javaHashCode(v);
        return h;
    }

    /// `o`; throws `NullPointerException` with `message` when it is null.
    static T requireNonNull(T)(T o, string message = null)
    {
        if (isNull(o))
            throw new NullPointerException(message);
        return o;
    }

    /// `o`, or `defaultObject` when `o` is null.
    static T requireNonNullElse(T)(T o, T defaultObject)
    {
        return isNull(o) ? requireNonNull(defaultObject, "defaultObj") : o;
    }

    /// Whether `o` is null.
    static bool isNull(T)(T o)
    {
        static if (is(T == class) || is(T == interface) || is(T == E[], E) || is(T : const(char)[]) || is(T == U*, U))
            return o is null;
        else
            return false;
    }

    /// Whether `o` is not null.
    static bool nonNull(T)(T o)
    {
        return !isNull(o);
    }

    /// `String.valueOf(o)`, or `nullDefault` when `o` is null.
    static string toString(T)(T o, string nullDefault = "null")
    {
        return isNull(o) ? nullDefault : valueOf(o);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Optional (R5)

/// Java's `Optional`: a value that may be absent.
struct Optional(T)
{
    /// Descriptor hooks: an optional of `T` (flint.engine.aot.descriptor).
    alias __flintElementType = T;

    private T value_;
    private bool present_;

    /// Descriptor builder hook (`flint.engine.aot.descriptor`): the value, or nothing.
    static T[] __flintUnwrap(Optional self)
    {
        return self.present_ ? [self.value_] : null;
    }

    /// Descriptor builder hook: `ofNullable(value)`, or empty.
    static Optional __flintWrap(T value, bool present)
    {
        return present ? ofNullable(value) : Optional.init;
    }

    /// An `Optional` holding `value`. Throws `NullPointerException` for a null reference.
    static Optional of(T value)
    {
        if (Objects.isNull(value))
            throw new NullPointerException();
        Optional result;
        result.value_ = value;
        result.present_ = true;
        return result;
    }

    /// An `Optional` holding `value`, or empty for a null reference.
    static Optional ofNullable(T value)
    {
        return Objects.isNull(value) ? Optional.init : of(value);
    }

    /// The empty `Optional`.
    static Optional empty() pure nothrow @nogc
    {
        return Optional.init;
    }

    /// Whether a value is present.
    bool isPresent() const pure nothrow @nogc
    {
        return present_;
    }

    /// Whether no value is present.
    bool isEmpty() const pure nothrow @nogc
    {
        return !present_;
    }

    /// The value. Throws `NoSuchElementException("No value present")` when empty.
    inout(T) get() inout
    {
        if (!present_)
            throw new NoSuchElementException("No value present");
        return value_;
    }

    /// The value, or `other` when empty.
    T orElse(T other)
    {
        return present_ ? value_ : other;
    }

    /// The value, or the result of `supplier` when empty.
    T orElseGet(T delegate() @safe supplier)
    {
        return present_ ? value_ : supplier();
    }

    /// The value. Throws `NoSuchElementException("No value present")` when empty.
    T orElseThrow()
    {
        return get();
    }

    /// The value; throws what `exceptionSupplier` returns when empty.
    T orElseThrow(E : Throwable)(E delegate() @safe exceptionSupplier)
    {
        if (!present_)
            throw exceptionSupplier();
        return value_;
    }

    /// Call `action` with the value when present.
    void ifPresent(void delegate(T) @safe action)
    {
        if (present_)
            action(value_);
    }

    /// Call `action` with the value when present, else `emptyAction`.
    void ifPresentOrElse(void delegate(T) @safe action, void delegate() @safe emptyAction)
    {
        if (present_)
            action(value_);
        else
            emptyAction();
    }

    /// This `Optional` when its value matches `predicate`, else empty.
    Optional filter(bool delegate(T) @safe predicate)
    {
        return present_ && predicate(value_) ? this : Optional.init;
    }

    /// The result of `mapper` on the value, as an `Optional` (empty when the result is null).
    Optional!R map(R)(R delegate(T) @safe mapper)
    {
        return present_ ? Optional!R.ofNullable(mapper(value_)) : Optional!R.init;
    }

    /// The `Optional` that `mapper` returns for the value; empty when this is empty.
    Optional!R flatMap(R)(Optional!R delegate(T) @safe mapper)
    {
        return present_ ? mapper(value_) : Optional!R.init;
    }

    /// This `Optional` when present, else the one `supplier` returns.
    Optional or(Optional delegate() @safe supplier)
    {
        return present_ ? this : supplier();
    }

    /// A stream of the value, or an empty stream.
    Stream!T stream()
    {
        return present_ ? Stream!T.of(value_) : Stream!T.empty();
    }

    /// Whether both are empty, or both hold equal values.
    bool opEquals(Optional other)
    {
        if (present_ != other.present_)
            return false;
        return !present_ || javaEquals(cast() value_, cast() other.value_);
    }

    /// Java's `Optional.equals`.
    bool equals(Optional other)
    {
        return opEquals(other);
    }

    /// The value's hash, or 0 when empty.
    size_t toHash() const nothrow
    {
        static if (is(T == class) || is(T == interface))
            return present_ ? 1 : 0; // a const reference cannot reach the @safe Object bridge
        else
        {
            try
                return present_ ? cast(uint) javaHashCode(value_) : 0;
            catch (Exception)
                return 0;
        }
    }

    /// `Optional[value]` or `Optional.empty`.
    string toString()
    {
        return present_ ? "Optional[" ~ valueOf(value_) ~ "]" : "Optional.empty";
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Erased views (ADR-030 section 5)

/// The erased view every collection offers, for descriptor-driven engines.
interface RawCollection
{
    /// How many elements.
    int size();
    /// Every element, boxed, in iteration order.
    Any[] toAnyArray();
    /// Add an element given as an `Any` holding the element type. Throws `UnsupportedOperationException` when the
    /// collection is unmodifiable.
    void addAny(Any element);
    /// Remove every element.
    void clear();
    /// The element type's canonical name.
    string elementTypeName();
    /// `TypeKind`-style shape: true for a set, false for a list.
    bool isSet();
}

/// The erased view every map offers, for descriptor-driven engines.
interface RawMap
{
    /// How many entries.
    int size();
    /// Every key, boxed, in iteration order.
    Any[] keysAsAny();
    /// The value for a boxed key; `Any.init` when absent.
    Any getAny(Any key);
    /// Put a boxed entry.
    void putAny(Any key, Any value);
    /// The key type's canonical name.
    string keyTypeName();
    /// The value type's canonical name.
    string valueTypeName();
}

// ---------------------------------------------------------------------------------------------------------------
// Iterator, Comparator

/// Java's `Iterator`.
interface Iterator(T)
{
    /// Whether another element follows.
    bool hasNext();
    /// The next element. Throws `NoSuchElementException` at the end.
    T next();
    /// Remove the element last returned. Throws `UnsupportedOperationException` unless supported.
    void remove();
}

/// Java's `Comparator`: an ordering of `T`.
interface Comparator(T)
{
    /// Negative, zero or positive as `a` orders before, with or after `b`.
    int compare(T a, T b);

    /// The `compare` method as a delegate.
    final int delegate(T, T) @safe asDelegate()
    {
        return &compare;
    }

    /// The reverse ordering.
    final Comparator!T reversed()
    {
        auto self = this;
        return of((T a, T b) => self.compare(b, a));
    }

    /// This ordering, then `other` for ties.
    final Comparator!T thenComparing(Comparator!T other)
    {
        auto self = this;
        return of((T a, T b) {
            const first = self.compare(a, b);
            return first != 0 ? first : other.compare(a, b);
        });
    }

    /// This ordering, then the natural ordering of `keyExtractor`'s result for ties.
    Comparator!T thenComparing(U)(U delegate(T) @safe keyExtractor)
    {
        return thenComparing(comparing!U(keyExtractor));
    }

    /// A `Comparator` calling `dg`.
    static Comparator!T of(int delegate(T, T) @safe dg)
    {
        return new DelegateComparator!T(dg);
    }

    /// The natural ordering: `compareTo` when `T` declares it, else `<`.
    static Comparator!T naturalOrder()
    {
        return of((T a, T b) => compareNatural(a, b));
    }

    /// The reverse of the natural ordering.
    static Comparator!T reverseOrder()
    {
        return of((T a, T b) => compareNatural(b, a));
    }

    /// Order by the natural ordering of `keyExtractor`'s result.
    static Comparator!T comparing(U)(U delegate(T) @safe keyExtractor)
    {
        return of((T a, T b) => compareNatural(keyExtractor(a), keyExtractor(b)));
    }

    /// Order by `keyExtractor`'s result under `keyComparator`.
    static Comparator!T comparing(U)(U delegate(T) @safe keyExtractor, Comparator!U keyComparator)
    {
        return of((T a, T b) => keyComparator.compare(keyExtractor(a), keyExtractor(b)));
    }

    /// Order by an `int` key.
    static Comparator!T comparingInt(int delegate(T) @safe keyExtractor)
    {
        return of((T a, T b) => compareNatural(keyExtractor(a), keyExtractor(b)));
    }

    /// Nulls first, then `comparator`.
    static Comparator!T nullsFirst(Comparator!T comparator)
    {
        return of((T a, T b) => compareNulls(a, b, comparator, -1));
    }

    /// Nulls last, then `comparator`.
    static Comparator!T nullsLast(Comparator!T comparator)
    {
        return of((T a, T b) => compareNulls(a, b, comparator, 1));
    }
}

private final class DelegateComparator(T) : Comparator!T
{
    private int delegate(T, T) @safe dg;

    this(int delegate(T, T) @safe dg) pure nothrow @nogc
    {
        this.dg = dg;
    }

    int compare(T a, T b)
    {
        return dg(a, b);
    }
}

private int compareNulls(T)(T a, T b, Comparator!T comparator, int nullOrder)
{
    const aNull = Objects.isNull(a), bNull = Objects.isNull(b);
    if (aNull || bNull)
        return aNull == bNull ? 0 : (aNull ? nullOrder : -nullOrder);
    return comparator is null ? 0 : comparator.compare(a, b);
}

/// The natural ordering of two values: `compareTo` when declared, else `<`. Strings compare by UTF-8 bytes, which
/// orders as code points (rulebook R14: Java compares UTF-16 units, which differs only around U+E000-U+FFFF against
/// supplementary characters).
int compareNatural(T)(T a, T b)
{
    static if (__traits(hasMember, T, "compareTo"))
        return a.compareTo(b);
    else static if (__traits(compiles, ()@safe { T x, y; return x < y; }))
        return a < b ? -1 : (b < a ? 1 : 0);
    else
        throw new ClassCastException("class " ~ typeNameOf!T ~ " cannot be cast to class java.lang.Comparable");
}

/// A stable merge sort (Java's `List.sort` is stable).
void stableSort(T)(T[] items, scope int delegate(T, T) @safe compare)
{
    if (items.length < 2)
        return;
    auto buffer = new T[items.length];
    mergeSort(items, buffer, compare);
}

private void mergeSort(T)(T[] items, T[] buffer, scope int delegate(T, T) @safe compare)
{
    if (items.length < 2)
        return;
    if (items.length <= 8)
    {
        foreach (i; 1 .. items.length)
        {
            auto current = items[i];
            size_t j = i;
            while (j > 0 && compare(items[j - 1], current) > 0)
            {
                items[j] = items[j - 1];
                j--;
            }
            items[j] = current;
        }
        return;
    }
    const middle = items.length / 2;
    mergeSort(items[0 .. middle], buffer[0 .. middle], compare);
    mergeSort(items[middle .. $], buffer[middle .. items.length], compare);
    size_t left, right = middle, output;
    while (left < middle && right < items.length)
        buffer[output++] = compare(items[right], items[left]) < 0 ? items[right++] : items[left++];
    while (left < middle)
        buffer[output++] = items[left++];
    while (right < items.length)
        buffer[output++] = items[right++];
    items[] = buffer[0 .. items.length];
}

// ---------------------------------------------------------------------------------------------------------------
// Collection, List, Set (R10)

/// Java's `Collection`.
interface Collection(T) : Iterable!T, RawCollection
{
    /// Descriptor hooks: a collection of `T`.
    alias __flintElementType = T;

    /// Whether there are no elements.
    bool isEmpty();
    /// Whether an element equals `o`.
    bool contains(T o);
    /// Whether every element of `c` is contained.
    bool containsAll(Collection!T c);
    /// Add `e`; whether the collection changed.
    bool add(T e);
    /// Remove one element equal to `o`; whether the collection changed.
    bool remove(T o);
    /// Add every element of `c`; whether the collection changed.
    bool addAll(Collection!T c);
    /// Remove every element contained in `c`; whether the collection changed.
    bool removeAll(Collection!T c);
    /// Keep only elements contained in `c`; whether the collection changed.
    bool retainAll(Collection!T c);
    /// Remove every element matching `filter`; whether the collection changed.
    bool removeIf(bool delegate(T) @safe filter);
    /// The elements, in iteration order, as a new D array.
    T[] toArray();
    /// A sequential stream of the elements.
    Stream!T stream();
    /// Java's `equals` (declared so it can be called through the interface).
    bool equals(Object o);
    /// Java's `hashCode`.
    int hashCode();
    /// `[a, b, c]`.
    string toString();
}

/// Java's `List`: an ordered collection with positional access.
interface List(T) : Collection!T
{
    /// The element at `index`. Throws `IndexOutOfBoundsException`.
    T get(int index);
    /// Replace the element at `index`; the previous element.
    T set(int index, T element);
    /// Insert `element` at `index`.
    void add(int index, T element);
    /// Remove the element at `index`; the removed element.
    T removeAt(int index);
    /// The first index of an element equal to `o`, or -1.
    int indexOf(T o);
    /// The last index of an element equal to `o`, or -1.
    int lastIndexOf(T o);
    /// The elements from `fromIndex` (inclusive) to `toIndex` (exclusive), as a new list.
    List!T subList(int fromIndex, int toIndex);
    /// Sort in place with `c` (stable); null sorts by the natural ordering.
    void sort(Comparator!T c);
    /// The first element. Throws `NoSuchElementException` when empty.
    T getFirst();
    /// The last element. Throws `NoSuchElementException` when empty.
    T getLast();

    static if (!is(T : int))
    {
        /// Java's `List.remove(int index)`.
        final T remove(int index)
        {
            return removeAt(index);
        }
    }

    // Bring Collection's remove(T) into the same overload set.
    alias remove = Collection!T.remove;
    alias add = Collection!T.add;

    /// Descriptor builder hook (`flint.engine.aot.descriptor`): the elements.
    static T[] __flintElements(List!T self)
    {
        return self is null ? null : self.toArray();
    }

    /// Descriptor builder hook: a new mutable list of `items`.
    static List!T __flintFromElements(T[] items)
    {
        return new ArrayList!T(items);
    }

    /// An unmodifiable list of `elements`.
    static List!T of(T[] elements...)
    {
        return new ImmutableList!T(elements.dup);
    }

    /// An unmodifiable copy of `c`.
    static List!T copyOf(Collection!T c)
    {
        return new ImmutableList!T(c.toArray());
    }
}

/// Java's `Set`: a collection without duplicates.
interface Set(T) : Collection!T
{
    /// Descriptor builder hook (`flint.engine.aot.descriptor`): the elements.
    static T[] __flintElements(Set!T self)
    {
        return self is null ? null : self.toArray();
    }

    /// Descriptor builder hook: a new mutable set of `items`.
    static Set!T __flintFromElements(T[] items)
    {
        return new LinkedHashSet!T(items);
    }

    /// An unmodifiable set of `elements`. Throws `IllegalArgumentException` on a duplicate, as Java does.
    static Set!T of(T[] elements...)
    {
        auto result = new LinkedHashSet!T();
        foreach (e; elements)
            if (!result.add(e))
                throw new IllegalArgumentException("duplicate element: " ~ valueOf(e));
        result.freeze();
        return result;
    }

    /// An unmodifiable copy of `c`, without duplicates.
    static Set!T copyOf(Collection!T c)
    {
        auto result = new LinkedHashSet!T(c);
        result.freeze();
        return result;
    }
}

/// Java's `AbstractCollection`: everything but storage, iteration and `size`.
abstract class AbstractCollection(T) : Collection!T
{
    /// Java's `iterator`.
    abstract Iterator!T iterator();
    /// Java's `size`.
    abstract int size();

    /// Java's `isEmpty`.
    bool isEmpty()
    {
        return size() == 0;
    }

    /// Java's `contains`.
    bool contains(T o)
    {
        for (auto it = iterator(); it.hasNext();)
            if (javaEquals(it.next(), o))
                return true;
        return false;
    }

    /// Java's `containsAll`.
    bool containsAll(Collection!T c)
    {
        for (auto it = c.iterator(); it.hasNext();)
            if (!contains(it.next()))
                return false;
        return true;
    }

    /// Java's `add`.
    bool add(T)
    {
        throw new UnsupportedOperationException();
    }

    /// Java's `remove`.
    bool remove(T o)
    {
        for (auto it = iterator(); it.hasNext();)
            if (javaEquals(it.next(), o))
            {
                it.remove();
                return true;
            }
        return false;
    }

    /// Java's `addAll`.
    bool addAll(Collection!T c)
    {
        bool changed;
        foreach (e; c.toArray())
            changed |= add(e);
        return changed;
    }

    /// Java's `removeAll`.
    bool removeAll(Collection!T c)
    {
        return removeIf((T e) => c.contains(e));
    }

    /// Java's `retainAll`.
    bool retainAll(Collection!T c)
    {
        return removeIf((T e) => !c.contains(e));
    }

    /// Java's `removeIf`.
    bool removeIf(bool delegate(T) @safe filter)
    {
        bool changed;
        for (auto it = iterator(); it.hasNext();)
            if (filter(it.next()))
            {
                it.remove();
                changed = true;
            }
        return changed;
    }

    /// Java's `clear`.
    void clear()
    {
        for (auto it = iterator(); it.hasNext();)
        {
            it.next();
            it.remove();
        }
    }

    /// Java's `toArray`.
    T[] toArray()
    {
        T[] result;
        result.reserve(size());
        for (auto it = iterator(); it.hasNext();)
            result ~= it.next();
        return result;
    }

    /// Java's `stream`.
    Stream!T stream()
    {
        return Stream!T.ofArray(toArray());
    }

    /// Java's `forEach`.
    void forEach(void delegate(T) @safe action)
    {
        for (auto it = iterator(); it.hasNext();)
            action(it.next());
    }

    /// Java's `opApply`.
    int opApply(scope int delegate(T) @safe dg)
    {
        for (auto it = iterator(); it.hasNext();)
            if (const result = dg(it.next()))
                return result;
        return 0;
    }

    /// Java's `toAnyArray`.
    Any[] toAnyArray()
    {
        Any[] result;
        result.reserve(size());
        for (auto it = iterator(); it.hasNext();)
            result ~= Any.of(it.next());
        return result;
    }

    /// Java's `addAny`.
    void addAny(Any element)
    {
        add(element.get!T);
    }

    /// Java's `elementTypeName`.
    string elementTypeName()
    {
        return typeNameOf!T;
    }

    /// Java's `isSet`.
    bool isSet()
    {
        return false;
    }

    /// `[a, b, c]`, each element as `String.valueOf` renders it.
    override string toString()
    {
        string result = "[";
        bool first = true;
        for (auto it = iterator(); it.hasNext();)
        {
            auto e = it.next();
            if (!first)
                result ~= ", ";
            first = false;
            static if (is(T == class) || is(T == interface))
                result ~= (cast(Object) e) is this ? "(this Collection)" : valueOf(e);
            else
                result ~= valueOf(e);
        }
        return result ~ "]";
    }
}

/// Java's `AbstractList`: positional defaults, Java's `equals` and `hashCode`.
abstract class AbstractList(T) : AbstractCollection!T, List!T
{
    /// Java's `get`.
    abstract T get(int index);

    /// Java's `set`.
    T set(int, T)
    {
        throw new UnsupportedOperationException();
    }

    /// Java's `add`.
    void add(int, T)
    {
        throw new UnsupportedOperationException();
    }

    override bool add(T e)
    {
        add(size(), e);
        return true;
    }

    /// Java's `removeAt`.
    T removeAt(int)
    {
        throw new UnsupportedOperationException();
    }

    alias remove = AbstractCollection!T.remove;
    static if (!is(T : int))
        alias remove = List!T.remove;

    /// Java's `indexOf`.
    int indexOf(T o)
    {
        foreach (i; 0 .. size())
            if (javaEquals(get(i), o))
                return i;
        return -1;
    }

    /// Java's `lastIndexOf`.
    int lastIndexOf(T o)
    {
        for (int i = size() - 1; i >= 0; i--)
            if (javaEquals(get(i), o))
                return i;
        return -1;
    }

    override bool contains(T o)
    {
        return indexOf(o) >= 0;
    }

    /// Java's `subList`.
    List!T subList(int fromIndex, int toIndex)
    {
        if (fromIndex < 0 || toIndex > size() || fromIndex > toIndex)
            throw new IndexOutOfBoundsException("fromIndex: " ~ valueOf(
                    fromIndex) ~ ", toIndex: " ~ valueOf(toIndex) ~ ", size: " ~ valueOf(size()));
        auto result = new ArrayList!T();
        foreach (i; fromIndex .. toIndex)
            result.add(get(i));
        return result;
    }

    /// Java's `sort`.
    void sort(Comparator!T c)
    {
        auto items = toArray();
        if (c is null)
            stableSort(items, (T a, T b) => compareNatural(a, b));
        else
            stableSort(items, &c.compare);
        foreach (i, e; items)
            set(cast(int) i, e);
    }

    T getFirst()
    {
        if (size() == 0)
            throw new NoSuchElementException();
        return get(0);
    }

    T getLast()
    {
        if (size() == 0)
            throw new NoSuchElementException();
        return get(size() - 1);
    }

    override Iterator!T iterator()
    {
        return new ListIterator(this);
    }

    private static final class ListIterator : Iterator!T
    {
        private AbstractList!T list;
        private int cursor;
        private int last = -1;

        this(AbstractList!T list) pure nothrow @nogc
        {
            this.list = list;
        }

        bool hasNext()
        {
            return cursor < list.size();
        }

        T next()
        {
            if (cursor >= list.size())
                throw new NoSuchElementException();
            last = cursor;
            return list.get(cursor++);
        }

        void remove()
        {
            if (last < 0)
                throw new IllegalStateException();
            list.removeAt(last);
            cursor = last;
            last = -1;
        }
    }

    /// Java's `List.equals`: another list with equal elements in the same order.
    bool equals(Object o)
    {
        if (o is this)
            return true;
        auto that = cast(List!T) o;
        if (that is null || that.size() != size())
            return false;
        foreach (i; 0 .. size())
            if (!javaEquals(get(i), that.get(i)))
                return false;
        return true;
    }

    /// Java's `List.hashCode`: `31 * h + hashCode(e)` over the elements, starting from 1.
    int hashCode()
    {
        int h = 1;
        foreach (i; 0 .. size())
            h = 31 * h + javaHashCode(get(i));
        return h;
    }

    override bool opEquals(Object o)
    {
        return equals(o);
    }

    override size_t toHash() @safe nothrow
    {
        try
            return cast(uint) hashCode();
        catch (Exception)
            return 0;
    }
}

private final class ImmutableList(T) : AbstractList!T
{
    private T[] items;

    this(T[] items) pure nothrow @nogc
    {
        this.items = items;
    }

    override T get(int index)
    {
        checkIndex(index, cast(int) items.length);
        return items[index];
    }

    override int size()
    {
        return cast(int) items.length;
    }

    override T[] toArray()
    {
        return items.dup;
    }

    override bool remove(T o)
    {
        throw new UnsupportedOperationException();
    }

    override void clear()
    {
        throw new UnsupportedOperationException();
    }

    override bool removeIf(bool delegate(T) @safe filter)
    {
        throw new UnsupportedOperationException();
    }

    override void sort(Comparator!T c)
    {
        throw new UnsupportedOperationException();
    }
}

private void checkIndex(int index, int length)
{
    if (index < 0 || index >= length)
        throw new IndexOutOfBoundsException("Index " ~ valueOf(index) ~ " out of bounds for length " ~ valueOf(length));
}

/// Java's `ArrayList`: a resizable array.
class ArrayList(T) : AbstractList!T
{
    /// Descriptor hook: storage is private, not JSON properties.
    enum __flintOpaque = true;

    private T[] items;

    /// An empty list.
    this() pure nothrow @nogc
    {
    }

    /// An empty list with room for `initialCapacity` elements.
    this(int initialCapacity)
    {
        if (initialCapacity < 0)
            throw new IllegalArgumentException("Illegal Capacity: " ~ valueOf(initialCapacity));
        items.reserve(initialCapacity);
    }

    /// A list of `c`'s elements, in its iteration order.
    this(Collection!T c)
    {
        items = c.toArray();
    }

    /// A list of a copy of `elements` (the D array conversion of R10).
    this(T[] elements) pure nothrow
    {
        items = elements.dup;
    }

    override T get(int index)
    {
        checkIndex(index, cast(int) items.length);
        return items[index];
    }

    override T set(int index, T element)
    {
        checkIndex(index, cast(int) items.length);
        auto previous = items[index];
        items[index] = element;
        return previous;
    }

    override void add(int index, T element)
    {
        if (index < 0 || index > items.length)
            throw new IndexOutOfBoundsException("Index: " ~ valueOf(index) ~ ", Size: " ~ valueOf(cast(int) items
                    .length));
        items ~= element;
        foreach_reverse (i; index + 1 .. items.length)
            items[i] = items[i - 1];
        items[index] = element;
    }

    override bool add(T e)
    {
        items ~= e;
        return true;
    }

    override T removeAt(int index)
    {
        checkIndex(index, cast(int) items.length);
        auto removed = items[index];
        foreach (i; index + 1 .. items.length)
            items[i - 1] = items[i];
        items = items[0 .. $ - 1];
        return removed;
    }

    alias remove = AbstractList!T.remove;

    override bool removeIf(bool delegate(T) @safe filter)
    {
        size_t kept;
        foreach (e; items)
            if (!filter(e))
                items[kept++] = e;
        const changed = kept != items.length;
        items = items[0 .. kept];
        return changed;
    }

    override int size()
    {
        return cast(int) items.length;
    }

    override void clear()
    {
        items = null;
    }

    override T[] toArray()
    {
        return items.dup;
    }

    override void sort(Comparator!T c)
    {
        if (c is null)
            stableSort(items, (T a, T b) => compareNatural(a, b));
        else
            stableSort(items, &c.compare);
    }

    /// Ensure room for `minCapacity` elements.
    void ensureCapacity(int minCapacity)
    {
        if (minCapacity > 0)
            items.reserve(minCapacity);
    }
}

/// Java's `HashSet`. Iterates in insertion order (a rulebook deviation; Java's order is unspecified).
class HashSet(T) : AbstractCollection!T, Set!T
{
    /// Descriptor hook: storage is private, not JSON properties.
    enum __flintOpaque = true;

    private T[] items;
    private size_t[T] positions;
    private bool frozen;

    /// An empty set.
    this() pure nothrow @nogc
    {
    }

    /// A set of `c`'s elements.
    this(Collection!T c)
    {
        foreach (e; c.toArray())
            insert(e);
    }

    /// A set of `elements` (the D array conversion of R10).
    this(T[] elements)
    {
        foreach (e; elements)
            insert(e);
    }

    private bool insert(T e)
    {
        if (e in positions)
            return false;
        positions[e] = items.length;
        items ~= e;
        return true;
    }

    package(flint.java) void freeze() pure nothrow @nogc
    {
        frozen = true;
    }

    private void checkModifiable()
    {
        if (frozen)
            throw new UnsupportedOperationException();
    }

    override int size()
    {
        return cast(int) items.length;
    }

    override bool contains(T o)
    {
        return (o in positions) !is null;
    }

    override bool add(T e)
    {
        checkModifiable();
        return insert(e);
    }

    override bool remove(T o)
    {
        checkModifiable();
        auto position = o in positions;
        if (position is null)
            return false;
        removeAtPosition(*position);
        return true;
    }

    private void removeAtPosition(size_t position)
    {
        positions.remove(items[position]);
        foreach (i; position + 1 .. items.length)
        {
            items[i - 1] = items[i];
            positions[items[i - 1]] = i - 1;
        }
        items = items[0 .. $ - 1];
    }

    override bool removeIf(bool delegate(T) @safe filter)
    {
        checkModifiable();
        T[] kept;
        foreach (e; items)
            if (!filter(e))
                kept ~= e;
        if (kept.length == items.length)
            return false;
        items = null;
        positions = null;
        foreach (e; kept)
            add(e);
        return true;
    }

    override void clear()
    {
        checkModifiable();
        items = null;
        positions = null;
    }

    override T[] toArray()
    {
        return items.dup;
    }

    override Iterator!T iterator()
    {
        return new SetIterator(this);
    }

    override bool isSet()
    {
        return true;
    }

    private static final class SetIterator : Iterator!T
    {
        private HashSet!T set;
        private size_t cursor;
        private bool canRemove;

        this(HashSet!T set) pure nothrow @nogc
        {
            this.set = set;
        }

        bool hasNext()
        {
            return cursor < set.items.length;
        }

        T next()
        {
            if (cursor >= set.items.length)
                throw new NoSuchElementException();
            canRemove = true;
            return set.items[cursor++];
        }

        void remove()
        {
            if (!canRemove)
                throw new IllegalStateException();
            set.checkModifiable();
            set.removeAtPosition(--cursor);
            canRemove = false;
        }
    }

    /// Java's `Set.equals`: another set with the same elements.
    bool equals(Object o)
    {
        if (o is this)
            return true;
        auto that = cast(Set!T) o;
        return that !is null && that.size() == size() && containsAll(that);
    }

    /// Java's `Set.hashCode`: the sum of the elements' hash codes.
    int hashCode()
    {
        int h;
        foreach (e; items)
            h += javaHashCode(e);
        return h;
    }

    override bool opEquals(Object o)
    {
        return equals(o);
    }

    override size_t toHash() @safe nothrow
    {
        try
            return cast(uint) hashCode();
        catch (Exception)
            return 0;
    }
}

/// Java's `LinkedHashSet`: a `HashSet` that iterates in insertion order.
class LinkedHashSet(T) : HashSet!T
{
    /// An empty set.
    this() pure nothrow @nogc
    {
    }

    /// A set of `c`'s elements.
    this(Collection!T c)
    {
        super(c);
    }

    /// A set of `elements`.
    this(T[] elements)
    {
        super(elements);
    }
}

private import flint.java.lang : IllegalStateException;

// ---------------------------------------------------------------------------------------------------------------
// Map (R10, R13: Map.Entry is hoisted as MapEntry and aliased back)

/// Java's `Map.Entry`, hoisted out of `Map` (R13).
class MapEntry(K, V)
{
    private K key_;
    private V value_;
    private Map!(K, V) owner;

    /// An entry of `owner`; `setValue` writes through to it when it is not null.
    this(K key, V value, Map!(K, V) owner = null) pure nothrow @nogc
    {
        key_ = key;
        value_ = value;
        this.owner = owner;
    }

    /// The key.
    K getKey()
    {
        return key_;
    }

    /// The value.
    V getValue()
    {
        return value_;
    }

    /// Replace the value, in the map too; the previous value.
    V setValue(V value)
    {
        auto previous = value_;
        value_ = value;
        if (owner !is null)
            owner.put(key_, value);
        return previous;
    }

    /// Equal keys and equal values.
    override bool opEquals(Object o)
    {
        auto that = cast(MapEntry!(K, V)) o;
        return that !is null && javaEquals(that.key_, key_) && javaEquals(that.value_, value_);
    }

    /// Java's `Map.Entry.hashCode`: `hashCode(key) ^ hashCode(value)`.
    override size_t toHash() @safe nothrow
    {
        try
            return cast(uint)(javaHashCode(key_) ^ javaHashCode(value_));
        catch (Exception)
            return 0;
    }

    /// `key=value`.
    override string toString()
    {
        return valueOf(key_) ~ "=" ~ valueOf(value_);
    }
}

/// Java's `Map`.
interface Map(K, V) : RawMap
{
    /// Descriptor hooks: a map from `K` to `V`.
    alias __flintElementType = V;
    /// ditto
    alias __flintKeyType = K;
    /// `Map.Entry` (R13).
    alias Entry = MapEntry!(K, V);

    /// Whether there are no entries.
    bool isEmpty();
    /// Whether `key` is mapped.
    bool containsKey(K key);
    /// Whether some key maps to `value`.
    bool containsValue(V value);
    /// The value for `key`; `V.init` (null for references and strings) when absent.
    V get(K key);
    /// The value for `key`, or `defaultValue` when absent.
    V getOrDefault(K key, V defaultValue);
    /// Map `key` to `value`; the previous value, or `V.init`.
    V put(K key, V value);
    /// Map `key` to `value` unless it is mapped; the existing value, or `V.init`.
    V putIfAbsent(K key, V value);
    /// Remove `key`; the previous value, or `V.init`.
    V remove(K key);
    /// Copy every entry of `m`.
    void putAll(Map!(K, V) m);
    /// Remove every entry.
    void clear();
    /// The keys, as a snapshot set in iteration order.
    Set!K keySet();
    /// The values, as a snapshot collection in iteration order.
    Collection!V values();
    /// The entries, as a snapshot set in iteration order; `setValue` writes through.
    Set!(MapEntry!(K, V)) entrySet();
    /// Call `action` for each entry.
    void forEach(void delegate(K, V) @safe action);
    /// Java's `equals` (declared so it can be called through the interface).
    bool equals(Object o);
    /// Java's `hashCode`.
    int hashCode();
    /// `{k1=v1, k2=v2}`.
    string toString();
    /// The value for `key`, computing and storing it with `mappingFunction` when absent.
    V computeIfAbsent(K key, V delegate(K) @safe mappingFunction);
    /// Store `value`, or `remapping(old, value)` when `key` is mapped.
    V merge(K key, V value, V delegate(V, V) @safe remapping);

    /// Descriptor builder hook (`flint.engine.aot.descriptor`): keys and values in iteration order.
    static void __flintEntries(Map!(K, V) self, out K[] keys, out V[] values)
    {
        if (self is null)
            return;
        keys = self.keySet().toArray();
        foreach (key; keys)
            values ~= self.get(key);
    }

    /// Descriptor builder hook: a new mutable map of the entries.
    static Map!(K, V) __flintFromEntries(K[] keys, V[] values)
    {
        auto result = new LinkedHashMap!(K, V)();
        foreach (i, key; keys)
            result.put(key, values[i]);
        return result;
    }

    /// An unmodifiable map of alternating keys and values.
    static Map!(K, V) of(Args...)(Args keysAndValues)
    {
        static assert(Args.length % 2 == 0, "Map.of takes keys and values in pairs");
        auto result = new LinkedHashMap!(K, V)();
        static foreach (i; 0 .. Args.length / 2)
        {
            if (result.containsKey(keysAndValues[2 * i]))
                throw new IllegalArgumentException("duplicate key: " ~ valueOf(keysAndValues[2 * i]));
            result.put(keysAndValues[2 * i], keysAndValues[2 * i + 1]);
        }
        result.freeze();
        return result;
    }

    /// An unmodifiable copy of `m`.
    static Map!(K, V) copyOf(Map!(K, V) m)
    {
        auto result = new LinkedHashMap!(K, V)();
        result.putAll(m);
        result.freeze();
        return result;
    }
}

/// Java's `HashMap`. Iterates in insertion order (a rulebook deviation; Java's order is unspecified).
class HashMap(K, V) : Map!(K, V)
{
    /// Descriptor hook: storage is private, not JSON properties.
    enum __flintOpaque = true;

    private K[] keys_;
    private V[] values_;
    private size_t[K] positions;
    private bool frozen;

    /// An empty map.
    this() pure nothrow @nogc
    {
    }

    /// A map of `m`'s entries.
    this(Map!(K, V) m)
    {
        m.forEach((K k, V v) { store(k, v); });
    }

    /// A map of a D associative array's entries (the conversion of R10), in the array's iteration order.
    this(V[K] entries)
    {
        foreach (k, v; entries)
            store(k, v);
    }

    private V store(K key, V value)
    {
        if (auto position = key in positions)
        {
            auto previous = values_[*position];
            values_[*position] = value;
            return previous;
        }
        positions[key] = keys_.length;
        keys_ ~= key;
        values_ ~= value;
        return V.init;
    }

    package(flint.java) void freeze() pure nothrow @nogc
    {
        frozen = true;
    }

    private void checkModifiable()
    {
        if (frozen)
            throw new UnsupportedOperationException();
    }

    /// Java's `size`.
    int size()
    {
        return cast(int) keys_.length;
    }

    /// Java's `isEmpty`.
    bool isEmpty()
    {
        return keys_.length == 0;
    }

    /// Java's `containsKey`.
    bool containsKey(K key)
    {
        return (key in positions) !is null;
    }

    /// Java's `containsValue`.
    bool containsValue(V value)
    {
        foreach (v; values_)
            if (javaEquals(v, value))
                return true;
        return false;
    }

    /// Java's `get`.
    V get(K key)
    {
        auto position = key in positions;
        return position is null ? V.init : values_[*position];
    }

    V getOrDefault(K key, V defaultValue)
    {
        auto position = key in positions;
        return position is null ? defaultValue : values_[*position];
    }

    /// Java's `put`.
    V put(K key, V value)
    {
        checkModifiable();
        return store(key, value);
    }

    /// Java's `putIfAbsent`.
    V putIfAbsent(K key, V value)
    {
        if (auto position = key in positions)
            return values_[*position];
        put(key, value);
        return V.init;
    }

    /// Java's `remove`.
    V remove(K key)
    {
        checkModifiable();
        auto position = key in positions;
        if (position is null)
            return V.init;
        const at = *position;
        auto previous = values_[at];
        positions.remove(key);
        foreach (i; at + 1 .. keys_.length)
        {
            keys_[i - 1] = keys_[i];
            values_[i - 1] = values_[i];
            positions[keys_[i - 1]] = i - 1;
        }
        keys_ = keys_[0 .. $ - 1];
        values_ = values_[0 .. $ - 1];
        return previous;
    }

    /// Java's `putAll`.
    void putAll(Map!(K, V) m)
    {
        m.forEach((K k, V v) { put(k, v); });
    }

    /// Java's `clear`.
    void clear()
    {
        checkModifiable();
        keys_ = null;
        values_ = null;
        positions = null;
    }

    /// Java's `keySet`.
    Set!K keySet()
    {
        return new LinkedHashSet!K(keys_);
    }

    /// Java's `values`.
    Collection!V values()
    {
        return new ArrayList!V(values_);
    }

    /// Java's `entrySet`.
    Set!(MapEntry!(K, V)) entrySet()
    {
        auto result = new LinkedHashSet!(MapEntry!(K, V))();
        foreach (i, k; keys_)
            result.add(new MapEntry!(K, V)(k, values_[i], this));
        return result;
    }

    /// Java's `forEach`.
    void forEach(void delegate(K, V) @safe action)
    {
        foreach (i, k; keys_.dup)
            action(k, values_[i]);
    }

    /// Java's `computeIfAbsent`.
    V computeIfAbsent(K key, V delegate(K) @safe mappingFunction)
    {
        if (auto position = key in positions)
            if (!Objects.isNull(values_[*position]))
                return values_[*position];
        auto value = mappingFunction(key);
        if (!Objects.isNull(value))
            put(key, value);
        return value;
    }

    /// Java's `merge`.
    V merge(K key, V value, V delegate(V, V) @safe remapping)
    {
        auto position = key in positions;
        auto merged = position is null || Objects.isNull(values_[*position]) ? value
            : remapping(values_[*position], value);
        put(key, merged);
        return merged;
    }

    /// Iterate as `foreach (key, value; map)`.
    int opApply(scope int delegate(K, V) @safe dg)
    {
        foreach (i, k; keys_.dup)
            if (const result = dg(k, values_[i]))
                return result;
        return 0;
    }

    /// Java's `keysAsAny`.
    Any[] keysAsAny()
    {
        Any[] result;
        foreach (k; keys_)
            result ~= Any.of(k);
        return result;
    }

    Any getAny(Any key)
    {
        auto position = key.get!K in positions;
        return position is null ? Any.init : Any.of(values_[*position]);
    }

    /// Java's `putAny`.
    void putAny(Any key, Any value)
    {
        put(key.get!K, value.get!V);
    }

    /// Java's `keyTypeName`.
    string keyTypeName()
    {
        return typeNameOf!K;
    }

    /// Java's `valueTypeName`.
    string valueTypeName()
    {
        return typeNameOf!V;
    }

    /// Java's `Map.equals`: another map with the same mappings.
    bool equals(Object o)
    {
        if (o is this)
            return true;
        auto that = cast(Map!(K, V)) o;
        if (that is null || that.size() != size())
            return false;
        foreach (i, k; keys_)
            if (!that.containsKey(k) || !javaEquals(that.get(k), values_[i]))
                return false;
        return true;
    }

    /// Java's `Map.hashCode`: the sum of the entries' hash codes.
    int hashCode()
    {
        int h;
        foreach (i, k; keys_)
            h += javaHashCode(k) ^ javaHashCode(values_[i]);
        return h;
    }

    override bool opEquals(Object o)
    {
        return equals(o);
    }

    override size_t toHash() @safe nothrow
    {
        try
            return cast(uint) hashCode();
        catch (Exception)
            return 0;
    }

    /// `{k1=v1, k2=v2}`.
    override string toString()
    {
        string result = "{";
        foreach (i, k; keys_)
        {
            if (i)
                result ~= ", ";
            result ~= valueOf(k) ~ "=" ~ valueOf(values_[i]);
        }
        return result ~ "}";
    }
}

/// Java's `LinkedHashMap`: a `HashMap` that iterates in insertion order.
class LinkedHashMap(K, V) : HashMap!(K, V)
{
    /// An empty map.
    this() pure nothrow @nogc
    {
    }

    /// A map of `m`'s entries.
    this(Map!(K, V) m)
    {
        super(m);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Collections, Arrays

/// Java's `Collections` statics.
struct Collections
{
    /// An empty unmodifiable list.
    static List!T emptyList(T)()
    {
        return new ImmutableList!T(null);
    }

    /// An empty unmodifiable set.
    static Set!T emptySet(T)()
    {
        auto result = new LinkedHashSet!T();
        result.freeze();
        return result;
    }

    /// An empty unmodifiable map.
    static Map!(K, V) emptyMap(K, V)()
    {
        auto result = new LinkedHashMap!(K, V)();
        result.freeze();
        return result;
    }

    /// An unmodifiable list of one element.
    static List!T singletonList(T)(T o)
    {
        return new ImmutableList!T([o]);
    }

    /// An unmodifiable set of one element.
    static Set!T singleton(T)(T o)
    {
        return Set!T.of(o);
    }

    /// An unmodifiable view of `list`: reads see its changes, writes throw.
    static List!T unmodifiableList(T)(List!T list)
    {
        return new UnmodifiableList!T(list);
    }

    /// An unmodifiable snapshot of `set`.
    static Set!T unmodifiableSet(T)(Set!T set)
    {
        return Set!T.copyOf(set);
    }

    /// An unmodifiable snapshot of `map`.
    static Map!(K, V) unmodifiableMap(K, V)(Map!(K, V) map)
    {
        return Map!(K, V).copyOf(map);
    }

    /// Sort `list` by the natural ordering (stable).
    static void sort(T)(List!T list)
    {
        list.sort(null);
    }

    /// Sort `list` with `c` (stable).
    static void sort(T)(List!T list, Comparator!T c)
    {
        list.sort(c);
    }

    /// Reverse `list` in place.
    static void reverse(T)(List!T list)
    {
        auto items = list.toArray();
        foreach (i, e; items)
            list.set(cast(int)(items.length - (i + 1)), e);
    }
}

private final class UnmodifiableList(T) : AbstractList!T
{
    private List!T backing;

    this(List!T backing) pure nothrow @nogc
    {
        this.backing = backing;
    }

    override T get(int index)
    {
        return backing.get(index);
    }

    override int size()
    {
        return backing.size();
    }

    override bool remove(T o)
    {
        throw new UnsupportedOperationException();
    }

    override void clear()
    {
        throw new UnsupportedOperationException();
    }

    override bool removeIf(bool delegate(T) @safe filter)
    {
        throw new UnsupportedOperationException();
    }
}

/// Java's `Arrays` statics.
struct Arrays
{
    /// A fixed-size list of `elements`: `set` writes through; adding or removing throws.
    static List!T asList(T)(T[] elements...)
    {
        return new FixedList!T(elements.dup);
    }

    /// `[a, b, c]`, or `"null"` for a null array.
    static string toString(T)(T[] a)
    {
        if (a is null)
            return "null";
        return new ImmutableList!T(a).toString();
    }
}

private final class FixedList(T) : AbstractList!T
{
    private T[] items;

    this(T[] items) pure nothrow @nogc
    {
        this.items = items;
    }

    override T get(int index)
    {
        checkIndex(index, cast(int) items.length);
        return items[index];
    }

    override T set(int index, T element)
    {
        checkIndex(index, cast(int) items.length);
        auto previous = items[index];
        items[index] = element;
        return previous;
    }

    override int size()
    {
        return cast(int) items.length;
    }

    override void sort(Comparator!T c)
    {
        if (c is null)
            stableSort(items, (T a, T b) => compareNatural(a, b));
        else
            stableSort(items, &c.compare);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Properties

/++
Java's `Properties`: a persistent set of string properties, loaded from the `.properties` format with Java's rules:
`#` and `!` comments, `=`, `:` or whitespace separators, backslash line continuations, escapes (`\t`, `\n`, `\f`,
`\r`, `\uXXXX`, and `\` before any other character), and a missing key's value looked up in the `defaults`.
+/
class Properties : LinkedHashMap!(string, string)
{
    /// Properties consulted when a key is missing; may be null.
    protected Properties defaults;

    /// Empty properties.
    this() pure nothrow @nogc
    {
    }

    /// Empty properties with `defaults`.
    this(Properties defaults) pure nothrow @nogc
    {
        this.defaults = defaults;
    }

    /// The value of `key`, then the defaults' value; null when neither has it.
    string getProperty(string key)
    {
        if (containsKey(key))
            return get(key);
        return defaults is null ? null : defaults.getProperty(key);
    }

    /// The value of `key`, or `defaultValue`.
    string getProperty(string key, string defaultValue)
    {
        auto value = getProperty(key);
        return value is null ? defaultValue : value;
    }

    /// Set `key` to `value`; the previous value, or null.
    string setProperty(string key, string value)
    {
        return put(key, value);
    }

    /// Every key, including the defaults' keys, in insertion order.
    Set!string stringPropertyNames()
    {
        auto result = new LinkedHashSet!string();
        if (defaults !is null)
            foreach (key; defaults.stringPropertyNames().toArray())
                result.add(key);
        foreach (key; keySet().toArray())
            result.add(key);
        return result;
    }

    /// Load properties from `text` in the `.properties` format. Throws `IllegalArgumentException` on a malformed
    /// `\uXXXX` escape, with Java's message.
    void load(string text)
    {
        size_t position;
        while (position < text.length)
        {
            auto line = logicalLine(text, position);
            if (line.length == 0)
                continue;
            parseLine(line);
        }
    }

    /// Load properties from `stream` (UTF-8, as `Properties.load(Reader)` reads text).
    void load(imported!"flint.java.io".InputStream stream)
    {
        load(cast(string) stream.readAllBytes().idup);
    }

    private static string logicalLine(string text, ref size_t position)
    {
        string line;
        bool continuing;
        while (position < text.length)
        {
            size_t end = position;
            while (end < text.length && text[end] != '\n' && text[end] != '\r')
                end++;
            auto raw = text[position .. end];
            position = end;
            if (position < text.length && text[position] == '\r')
                position++;
            if (position < text.length && text[position] == '\n')
                position++;
            raw = raw[skipBlanks(raw, 0) .. $];
            if (!continuing && isComment(raw))
                return null;
            if (trailingBackslashes(raw) % 2 == 1)
            {
                line ~= raw[0 .. $ - 1];
                continuing = true;
                continue;
            }
            return line ~ raw;
        }
        return line;
    }

    private void parseLine(string line)
    {
        size_t keyEnd;
        bool escaped;
        for (; keyEnd < line.length; keyEnd++)
        {
            const c = line[keyEnd];
            if (escaped)
                escaped = false;
            else if (c == '\\')
                escaped = true;
            else if (c == '=' || c == ':' || isBlank(c))
                break;
        }
        size_t valueStart = skipBlanks(line, keyEnd);
        if (valueStart < line.length && (line[valueStart] == '=' || line[valueStart] == ':'))
            valueStart++;
        valueStart = skipBlanks(line, valueStart);
        put(unescape(line[0 .. keyEnd]), unescape(line[valueStart .. $]));
    }

    private static bool isBlank(char c) pure nothrow @nogc
    {
        return c == ' ' || c == '\t' || c == '\f';
    }

    private static size_t skipBlanks(string text, size_t from) pure nothrow @nogc
    {
        while (from < text.length && isBlank(text[from]))
            from++;
        return from;
    }

    private static bool isComment(string line) pure nothrow @nogc
    {
        return line.length == 0 || line[0] == '#' || line[0] == '!';
    }

    private static size_t trailingBackslashes(string line) pure nothrow @nogc
    {
        size_t count;
        while (count < line.length && line[line.length - (count + 1)] == '\\')
            count++;
        return count;
    }

    private static string unescape(string text)
    {
        string result;
        for (size_t i = 0; i < text.length; i++)
        {
            if (text[i] != '\\' || i + 1 == text.length)
            {
                result ~= text[i];
                continue;
            }
            const c = text[++i];
            switch (c)
            {
            case 't':
                result ~= '\t';
                break;
            case 'n':
                result ~= '\n';
                break;
            case 'r':
                result ~= '\r';
                break;
            case 'f':
                result ~= '\f';
                break;
            case 'u':
                result ~= unicodeEscape(text, i);
                break;
            default:
                result ~= c;
            }
        }
        return result;
    }

    private static string unicodeEscape(string text, ref size_t i)
    {
        import flint.engine.aot.text : utf8;

        dchar value = 0;
        foreach (j; 1 .. 5)
        {
            if (i + j >= text.length)
                throw new IllegalArgumentException("Malformed \\uxxxx encoding.");
            const h = text[i + j];
            int digit;
            if (h >= '0' && h <= '9')
                digit = h - '0';
            else if (h >= 'a' && h <= 'f')
                digit = h - 'a' + 10;
            else if (h >= 'A' && h <= 'F')
                digit = h - 'A' + 10;
            else
                throw new IllegalArgumentException("Malformed \\uxxxx encoding.");
            value = value * 16 + digit;
        }
        i += 4;
        const encoded = utf8(value);
        return encoded is null ? "\uFFFD" : encoded; // a lone surrogate has no UTF-8 form
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Locale

/++
Java's `Locale` (clean room, from the Java SE specification): a language, a country (region) and a variant,
normalized as Java does (the language lower case, the country upper case). Like flint.java's `Charset`, it is a
value type, so its constants are `static immutable`. Scripts and extensions are not modeled: `forLanguageTag`
skips a script subtag and stops at the first extension or private-use subtag. `getDefault` reads the POSIX locale
(`LC_ALL`, then `LANG`) once per call; `setDefault` is not provided, because framework modules keep no mutable
module state.
+/
struct Locale
{
    private string language;
    private string country;
    private string variant;

    /// A locale for `language`, `country` and `variant`.
    this(string language, string country = "", string variant = "") pure nothrow
    {
        this.language = asciiCase(language, false);
        this.country = asciiCase(country, true);
        this.variant = variant;
    }

    static immutable Locale ROOT = Locale(""); ///
    static immutable Locale ENGLISH = Locale("en"); ///
    static immutable Locale FRENCH = Locale("fr"); ///
    static immutable Locale GERMAN = Locale("de"); ///
    static immutable Locale ITALIAN = Locale("it"); ///
    static immutable Locale JAPANESE = Locale("ja"); ///
    static immutable Locale CHINESE = Locale("zh"); ///
    static immutable Locale US = Locale("en", "US"); ///
    static immutable Locale UK = Locale("en", "GB"); ///
    static immutable Locale CANADA = Locale("en", "CA"); ///
    static immutable Locale FRANCE = Locale("fr", "FR"); ///
    static immutable Locale GERMANY = Locale("de", "DE"); ///
    static immutable Locale ITALY = Locale("it", "IT"); ///
    static immutable Locale JAPAN = Locale("ja", "JP"); ///

    /// The language code, lower case; empty when absent.
    string getLanguage() const pure nothrow @nogc
    {
        return language;
    }

    /// The country (region) code, upper case; empty when absent.
    string getCountry() const pure nothrow @nogc
    {
        return country;
    }

    /// The variant; empty when absent.
    string getVariant() const pure nothrow @nogc
    {
        return variant;
    }

    /// Equal language, country and variant.
    bool equals(const Locale other) const pure nothrow @nogc
    {
        return opEquals(other);
    }

    /// Equal language, country and variant.
    bool opEquals(const Locale other) const pure nothrow @nogc
    {
        return language == other.language && country == other.country && variant == other.variant;
    }

    /// The hash of the language, country and variant.
    size_t toHash() const pure nothrow
    {
        return hashOf(variant, hashOf(country, hashOf(language)));
    }

    /// Java's `hashCode`.
    int hashCode() const pure nothrow
    {
        return cast(int) toHash();
    }

    /// `language_COUNTRY_variant`, leaving out empty trailing parts: `en_US`, `en`, `_US`; empty for `ROOT`.
    string toString() const pure nothrow
    {
        if (!country.length && !variant.length)
            return language;
        string result = language ~ "_" ~ country;
        return variant.length ? result ~ "_" ~ variant : result;
    }

    /// The BCP 47 tag: `en-US`, `en`, or `und` without a language.
    string toLanguageTag() const pure nothrow
    {
        string result = language.length ? language : "und";
        if (country.length)
            result ~= "-" ~ country;
        if (variant.length)
            result ~= "-" ~ variant;
        return result;
    }

    /// The locale of a BCP 47 tag (`en-US`, `de`, `und`, `zh-Hant-TW`); an ill-formed subtag ends the parse.
    static Locale forLanguageTag(string languageTag) pure nothrow
    {
        string[] subtags;
        size_t start;
        foreach (i; 0 .. languageTag.length + 1)
            if (i == languageTag.length || languageTag[i] == '-')
            {
                subtags ~= languageTag[start .. i];
                start = i + 1;
            }
        string lang, region, variantTag;
        size_t next;
        if (subtags.length && isAlpha(subtags[0], 2, 8))
        {
            lang = subtags[0] == "und" ? "" : subtags[0];
            next = 1;
            while (next < subtags.length && next <= 3 && isAlpha(subtags[next], 3, 3))
                next++; // extended language subtags
        }
        else
            return Locale.init;
        if (next < subtags.length && isAlpha(subtags[next], 4, 4))
            next++; // script: not modeled
        if (next < subtags.length && (isAlpha(subtags[next], 2, 2) || isDigits(subtags[next], 3)))
            region = subtags[next++];
        if (next < subtags.length && isVariant(subtags[next]))
            variantTag = subtags[next];
        return Locale(lang, region, variantTag);
    }

    /// The default locale: the POSIX locale of `LC_ALL`, else `LANG` (`en_US.UTF-8` gives en-US); `C`, `POSIX` or
    /// none gives `en_US`, as the JDK does.
    static Locale getDefault()
    {
        import std.process : environment;

        string posix = environment.get("LC_ALL", "");
        if (!posix.length)
            posix = environment.get("LANG", "");
        return fromPosix(posix);
    }

    /// The locale of a POSIX locale name: `language_COUNTRY.charset@modifier`.
    static Locale fromPosix(string name) pure nothrow
    {
        size_t end = name.length;
        foreach (i, c; name)
            if (c == '.' || c == '@')
            {
                end = i;
                break;
            }
        const base = name[0 .. end];
        if (!base.length || base == "C" || base == "POSIX")
            return Locale("en", "US");
        foreach (i, c; base)
            if (c == '_')
                return Locale(base[0 .. i], base[i + 1 .. $]);
        return Locale(base);
    }

    private static string asciiCase(string text, bool upper) pure nothrow
    {
        foreach (i, c; text)
            if (upper ? (c >= 'a' && c <= 'z') : (c >= 'A' && c <= 'Z'))
            {
                char[] result = text.dup;
                foreach (ref r; result[i .. $])
                    if (upper && r >= 'a' && r <= 'z')
                        r -= 32;
                    else if (!upper && r >= 'A' && r <= 'Z')
                        r += 32;
                return result.idup;
            }
        return text;
    }

    private static bool isAlpha(string s, size_t min, size_t max) pure nothrow @nogc
    {
        if (s.length < min || s.length > max)
            return false;
        foreach (c; s)
            if (!((c | 0x20) >= 'a' && (c | 0x20) <= 'z'))
                return false;
        return true;
    }

    private static bool isDigits(string s, size_t length) pure nothrow @nogc
    {
        if (s.length != length)
            return false;
        foreach (c; s)
            if (c < '0' || c > '9')
                return false;
        return true;
    }

    private static bool isVariant(string s) pure nothrow @nogc
    {
        const digitLed = s.length == 4 && s[0] >= '0' && s[0] <= '9';
        if (!digitLed && (s.length < 5 || s.length > 8))
            return false;
        foreach (c; s)
            if (!((c >= '0' && c <= '9') || ((c | 0x20) >= 'a' && (c | 0x20) <= 'z')))
                return false;
        return true;
    }
}
