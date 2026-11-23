/++
`java.lang` as Spring's APIs expose it (rulebook R8 and R11).

$(UL
    $(LI The exception hierarchy keeps Java's names and shape, with `RuntimeException : Exception` (R8). Java's
        checked `Exception` is D's `Exception`; `throws` clauses are dropped (deviation D-8). Each exception keeps
        Java's `getMessage`, `getCause`, `initCause` and the four-argument constructor whose
        `writableStackTrace = false` skips stack-trace capture, which framework control-flow exceptions use
        (ADR-030 section 4).)
    $(LI `mixin JavaObject;` maps `equals`, `hashCode` and `compareTo` onto D's `opEquals`, `toHash` and `opCmp`
        (R11). Free functions `equals` and `hashCode` give every class Java's identity defaults through UFCS.)
    $(LI `Runnable`, `Comparable`, `Iterable` and `AutoCloseable`, and the parsing statics of `Integer`, `Long`,
        `Boolean` and `Double` that Spring's converters call.)
)
+/
module flint.java.lang;

import flint.engine.aot.objects : objectEquals, objectToHash, objectToString;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Exceptions (R8)

/// A trace that records nothing: set before throwing, druntime captures no stack trace.
private final class NoTrace : Throwable.TraceInfo
{
    override int opApply(scope int delegate(ref const(char[])) dg) const
    {
        return 0;
    }

    override int opApply(scope int delegate(ref size_t, ref const(char[])) dg) const
    {
        return 0;
    }

    override string toString() const
    {
        return "";
    }
}

/++
Java's `RuntimeException`: the root of the unchecked exceptions Spring throws.

D's `Throwable.next` chains collateral exceptions; Java's cause is kept separately and read with `getCause`.
+/
class RuntimeException : Exception
{
    private Throwable cause_;
    private bool causeSet;

    /// No message and no cause.
    this() pure nothrow
    {
        super(null);
    }

    /// `message`, and optionally a `cause`.
    this(string message, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, file, line);
        cause_ = cause;
        causeSet = cause !is null;
    }

    /// Java's `RuntimeException(Throwable cause)`: the message is `cause.toString()`, or null.
    this(Throwable cause, string file = __FILE__, size_t line = __LINE__)
    {
        super(cause is null ? null : javaToString(cause), file, line);
        cause_ = cause;
        causeSet = true;
    }

    /++
    Java's protected four-argument constructor. With `writableStackTrace` false, throwing captures no stack
    trace: the framework's control-flow exceptions use it. Suppression is always enabled in D.
    +/
    protected this(string message, Throwable cause, bool enableSuppression, bool writableStackTrace,
            string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        this(message, cause, file, line);
        // druntime captures a trace only while `info` is null (rt.deh._d_createTrace).
        if (!writableStackTrace)
            info = new NoTrace;
    }

    /// The detail message; null when there is none.
    string getMessage() const pure nothrow @nogc
    {
        return msg;
    }

    /// `getMessage()`; subclasses may localize.
    string getLocalizedMessage() const pure nothrow @nogc
    {
        return getMessage();
    }

    /// The cause; null when unknown.
    inout(Throwable) getCause() inout pure nothrow @nogc
    {
        return cause_;
    }

    /// Set the cause once, as Java allows. Throws `IllegalStateException` when it was already set and
    /// `IllegalArgumentException` for a self-cause.
    RuntimeException initCause(Throwable cause)
    {
        if (causeSet)
            throw new IllegalStateException("Can't overwrite cause with " ~ (cause is null ? "a null" : javaToString(
                    cause)));
        if (cause is this)
            throw new IllegalArgumentException("Self-causation not permitted");
        cause_ = cause;
        causeSet = true;
        return this;
    }

    /// Java's `Throwable.toString()`: the class name, then `: message` when there is one.
    override string toString() const
    {
        return javaToString(this);
    }
}

/// Java's `Throwable.toString()` for any throwable: its class name, then `: message` when there is one.
string javaToString(const Throwable t) pure nothrow
{
    string message = t.msg;
    if (auto runtime = cast(const RuntimeException) t)
        message = runtime.getLocalizedMessage();
    const name = typeid(t).name;
    return message is null ? name : name ~ ": " ~ message;
}

/// Declares the five Java constructors of an exception class that forwards to its superclass.
private mixin template JavaExceptionConstructors()
{
    /// No message and no cause.
    this() pure nothrow
    {
        super();
    }

    /// `message`, and optionally a `cause`.
    this(string message, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }

    /// The message is `cause.toString()`.
    this(Throwable cause, string file = __FILE__, size_t line = __LINE__)
    {
        super(cause, file, line);
    }

    /// See `RuntimeException`'s four-argument constructor.
    protected this(string message, Throwable cause, bool enableSuppression, bool writableStackTrace,
            string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, enableSuppression, writableStackTrace, file, line);
    }
}

/// Thrown when a method receives an illegal or inappropriate argument.
class IllegalArgumentException : RuntimeException
{
    mixin JavaExceptionConstructors;
}

/// Thrown when a method is invoked at an illegal or inappropriate time.
class IllegalStateException : RuntimeException
{
    mixin JavaExceptionConstructors;
}

/// Thrown when an operation is not supported, such as a write to an unmodifiable collection.
class UnsupportedOperationException : RuntimeException
{
    mixin JavaExceptionConstructors;
}

/// Thrown when `null` is used where an object is required.
class NullPointerException : RuntimeException
{
    mixin JavaExceptionConstructors;
}

/// Thrown when a cast is not possible.
class ClassCastException : RuntimeException
{
    mixin JavaExceptionConstructors;
}

/// Thrown on an exceptional arithmetic condition, such as integer division by zero.
class ArithmeticException : RuntimeException
{
    mixin JavaExceptionConstructors;
}

/// Thrown when an index is out of range.
class IndexOutOfBoundsException : RuntimeException
{
    /// No message.
    this() pure nothrow
    {
        super();
    }

    /// `message`, and optionally a `cause`.
    this(string message, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }

    /// Java's `IndexOutOfBoundsException(int index)`: "Index out of range: " and the index.
    this(long index, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super("Index out of range: " ~ decimal(index), null, file, line);
    }
}

/// Thrown when a string cannot be converted to a number.
class NumberFormatException : IllegalArgumentException
{
    mixin JavaExceptionConstructors;

    /// Java's message for unparsable input: `For input string: "s"`.
    static NumberFormatException forInputString(string s, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        return new NumberFormatException("For input string: \"" ~ s ~ "\"", null, file, line);
    }
}

/// Thrown when an instance of an abstract class or an interface would be created.
class InstantiationException : RuntimeException
{
    mixin JavaExceptionConstructors;
}

// ---------------------------------------------------------------------------------------------------------------
// Core interfaces

/// Java's `Runnable`: a task with no arguments and no result (R9: APIs also accept `void delegate()`).
interface Runnable
{
    /// Run the task.
    void run();
}

/// Java's `AutoCloseable`: a resource released by `close`.
interface AutoCloseable
{
    /// Release the resource.
    void close();
}

/// Java's `Iterable`: a source of an `Iterator`, usable in `foreach`.
interface Iterable(T)
{
    import flint.java.util : Iterator;

    /// An iterator over the elements.
    Iterator!T iterator();

    /// Call `action` for each element, in iteration order.
    void forEach(void delegate(T) @safe action);

    /// `foreach (e; iterable)`.
    int opApply(scope int delegate(T) @safe dg);
}

/// Java's `Comparable`: a natural ordering.
interface Comparable(T)
{
    /// Negative, zero or positive as this is less than, equal to or greater than `other`.
    int compareTo(T other);
}

// ---------------------------------------------------------------------------------------------------------------
// Object methods (R11)

/++
Maps Java's `equals`, `hashCode` and `compareTo` onto D's `opEquals`, `toHash` and `opCmp`, so `==`, associative
arrays and sorting use the Java methods. Mix it into a class that declares `bool equals(Object)` and
`int hashCode()` (and optionally `int compareTo(T)`); `toString` keeps its name in both languages.
+/
mixin template JavaObject()
{
    static if (is(typeof(this) == class))
    {
        /// `==` through an `Object` reference calls `equals`.
        override bool opEquals(Object other)
        {
            return this.equals(other);
        }

        /// `==` between two instances calls `equals`, and stays `@safe`.
        bool opEquals(typeof(this) other)
        {
            return this is other || (other !is null && this.equals(other));
        }

        /// Associative arrays call `hashCode`. An exception from `hashCode` hashes to 0.
        override size_t toHash() @safe nothrow
        {
            try
                return cast(size_t) cast(uint) this.hashCode();
            catch (Exception)
                return 0;
        }

        static if (__traits(hasMember, typeof(this), "compareTo"))
        {
            /// `<` calls `compareTo`; another class compares as unordered (0), as Java would throw.
            override int opCmp(Object other)
            {
                auto that = cast(typeof(this)) other;
                return that is null ? 0 : this.compareTo(that);
            }
        }
    }
    else
    {
        /// `==` calls `equals`.
        bool opEquals(const typeof(this) other) const
        {
            return this.equals(other);
        }

        /// Associative arrays call `hashCode`.
        size_t toHash() const @safe nothrow
        {
            try
                return cast(size_t) cast(uint) this.hashCode();
            catch (Exception)
                return 0;
        }
    }
}

/// Java's `a.equals(b)` for any class through UFCS: the class's `opEquals` (identity unless overridden).
bool equals(Object a, Object b)
{
    return objectEquals(a, b);
}

/// Java's `o.hashCode()` for any class through UFCS: its `toHash`, folded to Java's 32-bit `int`.
int hashCode(Object o) nothrow
{
    return cast(int) objectToHash(o);
}

/// Java's `Objects.equals` semantics for any `T`: `objectEquals` for references, `==` for values.
bool javaEquals(T)(T a, T b)
{
    static if (is(T == class) || is(T == interface))
        return objectEquals(cast(Object) a, cast(Object) b);
    else
        return a == b;
}

// ---------------------------------------------------------------------------------------------------------------
// String.valueOf and boxed-number statics

/// Java's `String.valueOf`: `"null"` for null, decimal numbers, `true`/`false`, and `toString()` otherwise.
string valueOf(T)(T value)
{
    import std.conv : to;

    static if (is(T == class) || is(T == interface))
        return objectToString(cast(Object) value);
    else static if (is(T : const(char)[]))
        return value is null ? "null" : value.idup;
    else static if (is(T == bool))
        return value ? "true" : "false";
    else static if (__traits(isFloating, T))
        return doubleToString(value);
    else
        return value.to!string;
}

/// Java's `Double.toString` for the values Spring formats: integral values keep `.0`; NaN and infinities by name.
string doubleToString(double value)
{
    import std.conv : to;

    if (value != value)
        return "NaN";
    if (value == double.infinity)
        return "Infinity";
    if (value == -double.infinity)
        return "-Infinity";
    if (value == cast(long) value && value > -1e16 && value < 1e16)
        return (cast(long) value).to!string ~ ".0";
    return value.to!string;
}

private string decimal(long value) pure nothrow
{
    if (value == 0)
        return "0";
    const negative = value < 0;
    ulong magnitude = negative ? -(cast(ulong) value) : cast(ulong) value;
    char[20] buffer;
    size_t position = buffer.length;
    while (magnitude)
    {
        buffer[--position] = cast(char)('0' + magnitude % 10);
        magnitude /= 10;
    }
    return (negative ? "-" : "") ~ buffer[position .. $].idup;
}

/// Parse a decimal or radix integer with Java's rules: an optional sign, digits only, no whitespace.
private long parseIntegral(string s, int radix, long min, long max)
{
    if (s.length == 0 || radix < 2 || radix > 36)
        throw NumberFormatException.forInputString(s);
    size_t i;
    const negative = s[0] == '-';
    if (s[0] == '-' || s[0] == '+')
        i = 1;
    if (i == s.length)
        throw NumberFormatException.forInputString(s);
    // Accumulate negatively so long.min parses, as Java does.
    long result;
    const limit = negative ? min : -max;
    for (; i < s.length; i++)
    {
        const digit = digitValue(s[i]);
        if (digit < 0 || digit >= radix)
            throw NumberFormatException.forInputString(s);
        if (result < limit / radix || result * radix < limit + digit)
            throw NumberFormatException.forInputString(s);
        result = result * radix - digit;
    }
    return negative ? result : -result;
}

private int digitValue(char c) pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'z')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z')
        return c - 'A' + 10;
    return -1;
}

/// Java's `Integer` statics.
struct Integer
{
    /// The largest `int`.
    enum int MAX_VALUE = int.max;
    /// The smallest `int`.
    enum int MIN_VALUE = int.min;

    /// Parse a signed decimal `int`. Throws `NumberFormatException`.
    static int parseInt(string s, int radix = 10)
    {
        return cast(int) parseIntegral(s, radix, int.min, int.max);
    }

    /// `parseInt`, as Java's boxing factory.
    static int valueOf(string s)
    {
        return parseInt(s);
    }

    /// The decimal text of `i`.
    static string toString(int i) pure nothrow
    {
        return decimal(i);
    }

    /// Java's `Integer.compare`.
    static int compare(int x, int y) pure nothrow @nogc
    {
        return x < y ? -1 : (x == y ? 0 : 1);
    }
}

/// Java's `Long` statics.
struct Long
{
    /// The largest `long`.
    enum long MAX_VALUE = long.max;
    /// The smallest `long`.
    enum long MIN_VALUE = long.min;

    /// Parse a signed decimal `long`. Throws `NumberFormatException`.
    static long parseLong(string s, int radix = 10)
    {
        return parseIntegral(s, radix, long.min, long.max);
    }

    /// `parseLong`, as Java's boxing factory.
    static long valueOf(string s)
    {
        return parseLong(s);
    }

    /// The decimal text of `l`.
    static string toString(long l) pure nothrow
    {
        return decimal(l);
    }

    /// Java's `Long.compare`.
    static int compare(long x, long y) pure nothrow @nogc
    {
        return x < y ? -1 : (x == y ? 0 : 1);
    }

    /// Java's `Long.hashCode(long)`.
    static int hashCode(long value) pure nothrow @nogc
    {
        return cast(int)(value ^ (cast(ulong) value >>> 32));
    }
}

/// Java's `Boolean` statics.
struct Boolean
{
    /// `true` exactly when `s` equals `"true"`, ignoring case; anything else, null included, is false.
    static bool parseBoolean(string s) pure nothrow @nogc
    {
        if (s.length != 4)
            return false;
        foreach (i, c; "true")
            if ((s[i] | 0x20) != c)
                return false;
        return true;
    }

    /// `"true"` or `"false"`.
    static string toString(bool b) pure nothrow @nogc
    {
        return b ? "true" : "false";
    }

    /// Java's `Boolean.hashCode(boolean)`: 1231 or 1237.
    static int hashCode(bool value) pure nothrow @nogc
    {
        return value ? 1231 : 1237;
    }
}

/// Java's `Double` statics.
struct Double
{
    /// Parse a decimal floating-point number, trimming ASCII whitespace as Java does.
    /// Throws `NumberFormatException`.
    static double parseDouble(string s)
    {
        import std.conv : ConvException, to;

        size_t start, end = s.length;
        while (start < end && s[start] <= ' ')
            start++;
        while (end > start && s[end - 1] <= ' ')
            end--;
        auto text = s[start .. end];
        if (text.length && (text[$ - 1] == 'd' || text[$ - 1] == 'D' || text[$ - 1] == 'f' || text[$ - 1] == 'F'))
            text = text[0 .. $ - 1];
        if (text.length == 0)
            throw new NumberFormatException(s.length ? "For input string: \"" ~ s ~ "\"" : "empty String");
        try
            return text.to!double;
        catch (ConvException)
            throw NumberFormatException.forInputString(s);
    }

    /// Java's `Double.toString`.
    static string toString(double d)
    {
        return doubleToString(d);
    }
}

/// Java's `String.hashCode`: `s[0]*31^(n-1) + ... + s[n-1]` over UTF-16 code units.
int stringHashCode(scope const(char)[] s) pure nothrow @nogc
{
    int h;
    size_t i;
    while (i < s.length)
    {
        dchar c = s[i];
        size_t width = 1;
        if (c >= 0x80)
        {
            if ((c & 0xE0) == 0xC0 && i + 1 < s.length)
            {
                c = ((c & 0x1F) << 6) | (s[i + 1] & 0x3F);
                width = 2;
            }
            else if ((c & 0xF0) == 0xE0 && i + 2 < s.length)
            {
                c = ((c & 0x0F) << 12) | ((s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F);
                width = 3;
            }
            else if ((c & 0xF8) == 0xF0 && i + 3 < s.length)
            {
                c = ((c & 0x07) << 18) | ((s[i + 1] & 0x3F) << 12) | ((s[i + 2] & 0x3F) << 6) | (s[i + 3] & 0x3F);
                width = 4;
            }
        }
        if (c >= 0x10000)
        {
            h = 31 * h + cast(int)(0xD800 + ((c - 0x10000) >> 10));
            h = 31 * h + cast(int)(0xDC00 + ((c - 0x10000) & 0x3FF));
        }
        else
            h = 31 * h + cast(int) c;
        i += width;
    }
    return h;
}

/// Java's `hashCode()` of a value: `String.hashCode` for strings, the boxed type's rule for scalars,
/// `hashCode()` for classes that declare it, and `toHash` otherwise.
int javaHashCode(T)(T value)
{
    static if (is(T : const(char)[]))
        return stringHashCode(value);
    else static if (is(T == bool))
        return Boolean.hashCode(value);
    else static if (is(T == long) || is(T == ulong))
        return Long.hashCode(cast(long) value);
    else static if (__traits(isIntegral, T) || is(T == char) || is(T == wchar) || is(T == dchar))
        return cast(int) value;
    else static if (__traits(isFloating, T))
    {
        const bits = doubleBits(cast(double) value);
        return cast(int)(bits ^ (bits >>> 32));
    }
    else static if (is(T == class) || is(T == interface))
    {
        if (value is null)
            return 0;
        static if (__traits(hasMember, T, "hashCode") && is(typeof(value.hashCode()) : int))
            return value.hashCode();
        else
            return hashCode(cast(Object) value);
    }
    else static if (__traits(hasMember, T, "hashCode"))
        return value.hashCode();
    else
        return cast(int) hashOf(value);
}

private ulong doubleBits(double value) pure nothrow @nogc
{
    if (value != value)
        return 0x7ff8000000000000UL; // Java's canonical NaN
    union Bits
    {
        double d;
        ulong u;
    }

    Bits bits;
    bits.d = value;
    return bits.u;
}
