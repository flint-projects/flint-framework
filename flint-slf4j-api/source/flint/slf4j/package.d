/*
 * Ported from SLF4J (slf4j-api) 2.0.20, https://github.com/qos-ch/slf4j, tag v_2.0.20:
 *   slf4j-api/src/main/java/org/slf4j/{Logger,LoggerFactory,ILoggerFactory,Marker,
 *   IMarkerFactory,MarkerFactory,MDC}.java
 *
 * Copyright (c) 2004-2023 QOS.ch
 * All rights reserved.
 *
 * Permission is hereby granted, free  of charge, to any person obtaining
 * a  copy  of this  software  and  associated  documentation files  (the
 * "Software"), to  deal in  the Software without  restriction, including
 * without limitation  the rights to  use, copy, modify,  merge, publish,
 * distribute,  sublicense, and/or sell  copies of  the Software,  and to
 * permit persons to whom the Software  is furnished to do so, subject to
 * the following conditions:
 *
 * The  above  copyright  notice  and  this permission  notice  shall  be
 * included in all copies or substantial portions of the Software.
 *
 * THE  SOFTWARE IS  PROVIDED  "AS  IS", WITHOUT  WARRANTY  OF ANY  KIND,
 * EXPRESS OR  IMPLIED, INCLUDING  BUT NOT LIMITED  TO THE  WARRANTIES OF
 * MERCHANTABILITY,    FITNESS    FOR    A   PARTICULAR    PURPOSE    AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
 * LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
 * OF CONTRACT, TORT OR OTHERWISE,  ARISING FROM, OUT OF OR IN CONNECTION
 * WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 *
 * Modified by the Flint authors: translated to D (rulebook v2). Object arguments
 * are boxed in flint.engine.aot.Any by (Args...) façades that check the level
 * first (R7); providers are installed explicitly instead of found by
 * ServiceLoader (deviation D-SLF4J-1 in docs/spring/phase1/third-party.md).
 */

/// The SLF4J API: loggers, logger factories, markers and the mapped diagnostic context.
module flint.slf4j;

import flint.engine.aot.any : Any;
import flint.java.util : Map;
import flint.slf4j.event : Level;
import flint.slf4j.spi : DefaultLoggingEventBuilder, LoggingEventBuilder, MDCAdapter,
    NOPLoggingEventBuilder, SLF4JServiceProvider;

@safe:

/// Whether a façade call passes an already-erased argument array, which the virtual overload takes directly.
enum bool isErasedCall(Args...) = Args.length == 1 && is(Args[0] : Any[]);

/**
 * Box one logging argument for the erased overloads: references, Strings,
 * booleans, characters, integers and doubles keep their value; floats, enums,
 * structs and arrays are boxed as Java's `String.valueOf` text, which is all a
 * message format can show of them.
 */
Any toArgument(T)(T value)
{
    import flint.slf4j.helpers : MessageFormatter;

    alias U = typeof(cast() value);
    static if (is(U == class) || is(U == interface))
    {
        static if (is(T == U))
            return value is null ? Any.init : Any.of(value);
        else
            return Any.of(MessageFormatter.valueOf(value));
    }
    else static if (is(U : const(char)[]) && !is(U == enum))
        return value is null ? Any.init : Any.of(value.idup);
    else static if (is(U == bool) || is(U == double) || is(U == char) || is(U == wchar)
            || is(U == dchar) || (__traits(isIntegral, U) && !is(U == enum)))
        return Any.of(value);
    else static if (is(U == Any))
        return value;
    else
        return Any.of(MessageFormatter.valueOf(value));
}

/**
 * The org.slf4j.Logger interface is the main user entry point of SLF4J API. It
 * is expected that logging takes place through concrete implementations of
 * this interface.
 *
 * Typical usage pattern:
 * ---
 * import flint.slf4j : Logger, LoggerFactory;
 *
 * final class Wombat
 * {
 *     private static Logger logger() { return LoggerFactory.getLogger!Wombat(); }
 *     void setTemperature(int temperature)
 *     {
 *         logger.debug_("Temperature set to {}. Old value was {}.", temperature, old);
 *     }
 * }
 * ---
 *
 * `debug` is a D keyword, so the DEBUG methods are spelled `debug_` (rule R1's
 * keyword escape, as `flint:template` uses `flint.templates`).
 */
interface Logger
{
    /// Case-insensitive String constant used to retrieve the name of the root logger.
    enum string ROOT_LOGGER_NAME = "ROOT";

    /// Return the name of this `Logger` instance.
    string getName();

    /// Is the logger instance enabled for the TRACE level?
    bool isTraceEnabled();

    /// Similar to `isTraceEnabled()` method except that the marker data is also taken into account.
    bool isTraceEnabled(Marker marker);

    /// Log a message at the TRACE level.
    void trace(string msg);

    /// Log a message at the TRACE level according to the specified format and arguments: Java's
    /// `trace(String format, Object... arguments)`, the erased target of the `(Args...)` façade below.
    void trace(string format, scope Any[] arguments);

    /// Log an exception (throwable) at the TRACE level with an accompanying message.
    void trace(string msg, Throwable t);

    /// Log a message with the specific Marker at the TRACE level.
    void trace(Marker marker, string msg);

    /// This method is similar to `trace(string, Any[])` except that the marker data is also taken into consideration.
    void trace(Marker marker, string format, scope Any[] arguments);

    /// This method is similar to `trace(string, Throwable)` except that the marker data is also taken into consideration.
    void trace(Marker marker, string msg, Throwable t);

    /// Log a message at the TRACE level according to the specified format and arguments, boxing them only when
    /// TRACE is enabled: Java's `trace(String, Object)`, `trace(String, Object, Object)` and `trace(String, Object...)`.
    void trace(Args...)(string format, Args args) if (Args.length > 0 && !isErasedCall!Args)
    {
        if (!isTraceEnabled())
            return;
        Any[Args.length] boxed;
        static foreach (i; 0 .. Args.length)
            boxed[i] = toArgument(args[i]);
        trace(format, boxed[]);
    }

    /// ditto, with a marker.
    void trace(Args...)(Marker marker, string format, Args args)
            if (Args.length > 0 && !isErasedCall!Args)
    {
        if (!isTraceEnabled(marker))
            return;
        Any[Args.length] boxed;
        static foreach (i; 0 .. Args.length)
            boxed[i] = toArgument(args[i]);
        trace(marker, format, boxed[]);
    }

    /// Is the logger instance enabled for the DEBUG level?
    bool isDebugEnabled();

    /// Similar to `isDebugEnabled()` method except that the marker data is also taken into account.
    bool isDebugEnabled(Marker marker);

    /// Log a message at the DEBUG level.
    void debug_(string msg);

    /// Log a message at the DEBUG level according to the specified format and arguments: Java's
    /// `debug(String format, Object... arguments)`, the erased target of the `(Args...)` façade below.
    void debug_(string format, scope Any[] arguments);

    /// Log an exception (throwable) at the DEBUG level with an accompanying message.
    void debug_(string msg, Throwable t);

    /// Log a message with the specific Marker at the DEBUG level.
    void debug_(Marker marker, string msg);

    /// This method is similar to `debug_(string, Any[])` except that the marker data is also taken into consideration.
    void debug_(Marker marker, string format, scope Any[] arguments);

    /// This method is similar to `debug_(string, Throwable)` except that the marker data is also taken into consideration.
    void debug_(Marker marker, string msg, Throwable t);

    /// Log a message at the DEBUG level according to the specified format and arguments, boxing them only when
    /// DEBUG is enabled: Java's `debug(String, Object)`, `debug(String, Object, Object)` and `debug(String, Object...)`.
    void debug_(Args...)(string format, Args args) if (Args.length > 0 && !isErasedCall!Args)
    {
        if (!isDebugEnabled())
            return;
        Any[Args.length] boxed;
        static foreach (i; 0 .. Args.length)
            boxed[i] = toArgument(args[i]);
        debug_(format, boxed[]);
    }

    /// ditto, with a marker.
    void debug_(Args...)(Marker marker, string format, Args args)
            if (Args.length > 0 && !isErasedCall!Args)
    {
        if (!isDebugEnabled(marker))
            return;
        Any[Args.length] boxed;
        static foreach (i; 0 .. Args.length)
            boxed[i] = toArgument(args[i]);
        debug_(marker, format, boxed[]);
    }

    /// Is the logger instance enabled for the INFO level?
    bool isInfoEnabled();

    /// Similar to `isInfoEnabled()` method except that the marker data is also taken into account.
    bool isInfoEnabled(Marker marker);

    /// Log a message at the INFO level.
    void info(string msg);

    /// Log a message at the INFO level according to the specified format and arguments: Java's
    /// `info(String format, Object... arguments)`, the erased target of the `(Args...)` façade below.
    void info(string format, scope Any[] arguments);

    /// Log an exception (throwable) at the INFO level with an accompanying message.
    void info(string msg, Throwable t);

    /// Log a message with the specific Marker at the INFO level.
    void info(Marker marker, string msg);

    /// This method is similar to `info(string, Any[])` except that the marker data is also taken into consideration.
    void info(Marker marker, string format, scope Any[] arguments);

    /// This method is similar to `info(string, Throwable)` except that the marker data is also taken into consideration.
    void info(Marker marker, string msg, Throwable t);

    /// Log a message at the INFO level according to the specified format and arguments, boxing them only when
    /// INFO is enabled: Java's `info(String, Object)`, `info(String, Object, Object)` and `info(String, Object...)`.
    void info(Args...)(string format, Args args) if (Args.length > 0 && !isErasedCall!Args)
    {
        if (!isInfoEnabled())
            return;
        Any[Args.length] boxed;
        static foreach (i; 0 .. Args.length)
            boxed[i] = toArgument(args[i]);
        info(format, boxed[]);
    }

    /// ditto, with a marker.
    void info(Args...)(Marker marker, string format, Args args)
            if (Args.length > 0 && !isErasedCall!Args)
    {
        if (!isInfoEnabled(marker))
            return;
        Any[Args.length] boxed;
        static foreach (i; 0 .. Args.length)
            boxed[i] = toArgument(args[i]);
        info(marker, format, boxed[]);
    }

    /// Is the logger instance enabled for the WARN level?
    bool isWarnEnabled();

    /// Similar to `isWarnEnabled()` method except that the marker data is also taken into account.
    bool isWarnEnabled(Marker marker);

    /// Log a message at the WARN level.
    void warn(string msg);

    /// Log a message at the WARN level according to the specified format and arguments: Java's
    /// `warn(String format, Object... arguments)`, the erased target of the `(Args...)` façade below.
    void warn(string format, scope Any[] arguments);

    /// Log an exception (throwable) at the WARN level with an accompanying message.
    void warn(string msg, Throwable t);

    /// Log a message with the specific Marker at the WARN level.
    void warn(Marker marker, string msg);

    /// This method is similar to `warn(string, Any[])` except that the marker data is also taken into consideration.
    void warn(Marker marker, string format, scope Any[] arguments);

    /// This method is similar to `warn(string, Throwable)` except that the marker data is also taken into consideration.
    void warn(Marker marker, string msg, Throwable t);

    /// Log a message at the WARN level according to the specified format and arguments, boxing them only when
    /// WARN is enabled: Java's `warn(String, Object)`, `warn(String, Object, Object)` and `warn(String, Object...)`.
    void warn(Args...)(string format, Args args) if (Args.length > 0 && !isErasedCall!Args)
    {
        if (!isWarnEnabled())
            return;
        Any[Args.length] boxed;
        static foreach (i; 0 .. Args.length)
            boxed[i] = toArgument(args[i]);
        warn(format, boxed[]);
    }

    /// ditto, with a marker.
    void warn(Args...)(Marker marker, string format, Args args)
            if (Args.length > 0 && !isErasedCall!Args)
    {
        if (!isWarnEnabled(marker))
            return;
        Any[Args.length] boxed;
        static foreach (i; 0 .. Args.length)
            boxed[i] = toArgument(args[i]);
        warn(marker, format, boxed[]);
    }

    /// Is the logger instance enabled for the ERROR level?
    bool isErrorEnabled();

    /// Similar to `isErrorEnabled()` method except that the marker data is also taken into account.
    bool isErrorEnabled(Marker marker);

    /// Log a message at the ERROR level.
    void error(string msg);

    /// Log a message at the ERROR level according to the specified format and arguments: Java's
    /// `error(String format, Object... arguments)`, the erased target of the `(Args...)` façade below.
    void error(string format, scope Any[] arguments);

    /// Log an exception (throwable) at the ERROR level with an accompanying message.
    void error(string msg, Throwable t);

    /// Log a message with the specific Marker at the ERROR level.
    void error(Marker marker, string msg);

    /// This method is similar to `error(string, Any[])` except that the marker data is also taken into consideration.
    void error(Marker marker, string format, scope Any[] arguments);

    /// This method is similar to `error(string, Throwable)` except that the marker data is also taken into consideration.
    void error(Marker marker, string msg, Throwable t);

    /// Log a message at the ERROR level according to the specified format and arguments, boxing them only when
    /// ERROR is enabled: Java's `error(String, Object)`, `error(String, Object, Object)` and `error(String, Object...)`.
    void error(Args...)(string format, Args args) if (Args.length > 0 && !isErasedCall!Args)
    {
        if (!isErrorEnabled())
            return;
        Any[Args.length] boxed;
        static foreach (i; 0 .. Args.length)
            boxed[i] = toArgument(args[i]);
        error(format, boxed[]);
    }

    /// ditto, with a marker.
    void error(Args...)(Marker marker, string format, Args args)
            if (Args.length > 0 && !isErasedCall!Args)
    {
        if (!isErrorEnabled(marker))
            return;
        Any[Args.length] boxed;
        static foreach (i; 0 .. Args.length)
            boxed[i] = toArgument(args[i]);
        error(marker, format, boxed[]);
    }

    /// Returns whether this Logger is enabled for a given `Level`.
    final bool isEnabledForLevel(Level level)
    {
        final switch (level)
        {
        case Level.TRACE:
            return isTraceEnabled();
        case Level.DEBUG:
            return isDebugEnabled();
        case Level.INFO:
            return isInfoEnabled();
        case Level.WARN:
            return isWarnEnabled();
        case Level.ERROR:
            return isErrorEnabled();
        }
    }

    /// Make a new `LoggingEventBuilder` instance as appropriate for this logger implementation.
    final LoggingEventBuilder makeLoggingEventBuilder(Level level)
    {
        return new DefaultLoggingEventBuilder(this, level);
    }

    /// Make a new `LoggingEventBuilder` instance for `level`, or a no-operation one when it is disabled.
    final LoggingEventBuilder atLevel(Level level)
    {
        if (isEnabledForLevel(level))
            return makeLoggingEventBuilder(level);
        return NOPLoggingEventBuilder.singleton();
    }

    /// Entry point for fluent-logging for `Level.TRACE` level.
    final LoggingEventBuilder atTrace()
    {
        return atLevel(Level.TRACE);
    }

    /// Entry point for fluent-logging for `Level.DEBUG` level.
    final LoggingEventBuilder atDebug()
    {
        return atLevel(Level.DEBUG);
    }

    /// Entry point for fluent-logging for `Level.INFO` level.
    final LoggingEventBuilder atInfo()
    {
        return atLevel(Level.INFO);
    }

    /// Entry point for fluent-logging for `Level.WARN` level.
    final LoggingEventBuilder atWarn()
    {
        return atLevel(Level.WARN);
    }

    /// Entry point for fluent-logging for `Level.ERROR` level.
    final LoggingEventBuilder atError()
    {
        return atLevel(Level.ERROR);
    }
}

/**
 * `ILoggerFactory` instances manufacture `Logger` instances by name. Most users
 * retrieve `Logger` instances through the static `LoggerFactory.getLogger`
 * method.
 */
interface ILoggerFactory
{
    /// Return an appropriate `Logger` instance as specified by the `name` parameter.
    Logger getLogger(string name);
}

/**
 * Markers are named objects used to enrich log statements. Conforming logging
 * system implementations of SLF4J should determine how information conveyed
 * by any markers are used, if at all. Many conforming logging systems ignore
 * marker data entirely.
 */
interface Marker
{
    /// This constant represents any marker, including a null marker.
    enum string ANY_MARKER = "*";
    /// This constant represents any non-null marker.
    enum string ANY_NON_NULL_MARKER = "+";

    /// Get the name of this Marker.
    string getName();

    /// Add a reference to another Marker.
    void add(Marker reference);

    /// Remove a marker reference.
    bool remove(Marker reference);

    /// Does this marker have any references?
    bool hasReferences();

    /// The referenced markers, in insertion order (Java's `iterator()`).
    Marker[] references();

    /// Does this marker contain a reference to the `other` marker? Marker A is defined to contain marker B if A == B or if B is referenced by A, or if B is referenced by any one of A's references (recursively).
    bool contains(Marker other);

    /// Does this marker contain the marker named `name`?
    bool contains(string name);
}

/// Implementations of this interface are used to manufacture `Marker` instances.
interface IMarkerFactory
{
    /// Manufacture a `Marker` instance by name. If the instance has been created earlier, return the previously created instance.
    Marker getMarker(string name);

    /// Checks if the marker with the name already exists.
    bool exists(string name);

    /// Detach an existing marker.
    bool detachMarker(string name);

    /// Create a marker which is detached (even at birth) from this IMarkerFactory.
    Marker getDetachedMarker(string name);
}

/**
 * The `LoggerFactory` is a utility class producing Loggers for various logging
 * APIs, e.g. logback, reload4j, log4j and JDK 1.4 logging. Other
 * implementations such as `NOPLogger` and `SimpleLogger` are also supported.
 *
 * Java binds a provider with `ServiceLoader`. Flint's closed world installs
 * one with `installProvider` (deviation D-SLF4J-1); until then the default
 * provider writes through Flint's `flint.log` engine.
 */
final class LoggerFactory
{
    /// The API version this port implements.
    enum string API_VERSION = "2.0.99";

    private this()
    {
    }

    /// Return a logger named according to the name parameter using the statically bound `ILoggerFactory` instance.
    static Logger getLogger(string name)
    {
        return getILoggerFactory().getLogger(name);
    }

    /// Return a logger named corresponding to the class passed as parameter (rulebook R4: `Class<?>` is a template parameter).
    static Logger getLogger(T)()
    {
        import flint.engine.aot.name : typeNameOf;

        return getLogger(typeNameOf!T);
    }

    /// Return the `ILoggerFactory` instance in use.
    static ILoggerFactory getILoggerFactory()
    {
        return getProvider().getLoggerFactory();
    }

    /// The provider in use, initializing the default one on first use.
    static SLF4JServiceProvider getProvider()
    {
        import flint.slf4j.provider : providerSlot;

        return providerSlot();
    }

    /// Install `provider` as the process's SLF4J binding and initialize it (Flint's replacement for `ServiceLoader` discovery).
    static void installProvider(SLF4JServiceProvider provider)
    {
        import flint.slf4j.provider : installSlot;

        provider.initialize();
        installSlot(provider);
    }
}

/// MarkerFactory is a utility class producing `Marker` instances as appropriate for the logging system currently in use.
final class MarkerFactory
{
    private this()
    {
    }

    /// Return a Marker instance as specified by the name parameter using the previously bound `IMarkerFactory` instance.
    static Marker getMarker(string name)
    {
        return getIMarkerFactory().getMarker(name);
    }

    /// Create a marker which is detached (even at birth) from the MarkerFactory.
    static Marker getDetachedMarker(string name)
    {
        return getIMarkerFactory().getDetachedMarker(name);
    }

    /// Return the `IMarkerFactory` instance in use.
    static IMarkerFactory getIMarkerFactory()
    {
        return LoggerFactory.getProvider().getMarkerFactory();
    }
}

/**
 * This class hides and serves as a substitute for the underlying logging
 * system's MDC implementation.
 *
 * The MDC manages contextual information on a per-thread basis in Java; in
 * Flint each reactor fiber (Spring's virtual thread) has its own context,
 * kept in a `FiberLocal` (ADR-030 section 4).
 */
final class MDC
{
    private this()
    {
    }

    /// An adapter to remove the key when done.
    static final class MDCCloseable
    {
        private string key;

        private this(string key) pure nothrow @nogc
        {
            this.key = key;
        }

        /// Remove the key.
        void close()
        {
            MDC.remove(key);
        }
    }

    /// Put a diagnostic context value (the `val` parameter) as identified with the `key` parameter into the current thread's diagnostic context map.
    static void put(string key, string val)
    {
        checkKey(key);
        getMDCAdapter().put(key, val);
    }

    /// Put a diagnostic context value as identified with the key parameter into the current thread's diagnostic context map, and return an object that removes it on `close()`.
    static MDCCloseable putCloseable(string key, string val)
    {
        put(key, val);
        return new MDCCloseable(key);
    }

    /// Get the diagnostic context identified by the `key` parameter.
    static string get(string key)
    {
        checkKey(key);
        return getMDCAdapter().get(key);
    }

    /// Remove the diagnostic context identified by the `key` parameter using the underlying system's MDC implementation.
    static void remove(string key)
    {
        checkKey(key);
        getMDCAdapter().remove(key);
    }

    /// Clear all entries in the MDC of the underlying implementation.
    static void clear()
    {
        getMDCAdapter().clear();
    }

    /// Return a copy of the current thread's context map, or null when it is empty.
    static Map!(string, string) getCopyOfContextMap()
    {
        return getMDCAdapter().getCopyOfContextMap();
    }

    /// Set the current thread's context map by first clearing any existing map and then copying the map passed as parameter.
    static void setContextMap(Map!(string, string) contextMap)
    {
        getMDCAdapter().setContextMap(contextMap);
    }

    /// Push a value into the deque(stack) referenced by `key`.
    static void pushByKey(string key, string value)
    {
        getMDCAdapter().pushByKey(key, value);
    }

    /// Pop the stack referenced by `key` and return the value possibly null.
    static string popByKey(string key)
    {
        return getMDCAdapter().popByKey(key);
    }

    /// Returns the MDCAdapter instance currently in use.
    static MDCAdapter getMDCAdapter()
    {
        return LoggerFactory.getProvider().getMDCAdapter();
    }

    private static void checkKey(string key)
    {
        import flint.java.lang : IllegalArgumentException;

        if (key is null)
            throw new IllegalArgumentException("key parameter cannot be null");
    }
}
