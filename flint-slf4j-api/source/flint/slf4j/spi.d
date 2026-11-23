/*
 * Ported from SLF4J (slf4j-api) 2.0.20, https://github.com/qos-ch/slf4j, tag v_2.0.20:
 *   slf4j-api/src/main/java/org/slf4j/spi/{SLF4JServiceProvider,MDCAdapter,
 *   LoggingEventBuilder,DefaultLoggingEventBuilder,NOPLoggingEventBuilder,
 *   LoggingEventAware,LocationAwareLogger,CallerBoundaryAware}.java
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
 * Modified by the Flint authors: translated to D (rulebook v2). Supplier
 * overloads take delegates (R9); arguments are boxed in flint.engine.aot.Any.
 */

/// The service-provider interface: providers, MDC adapters and the fluent event builders.
module flint.slf4j.spi;

import flint.engine.aot.any : Any;
import flint.java.util : Map;
import flint.slf4j : ILoggerFactory, IMarkerFactory, Logger, Marker, toArgument;
import flint.slf4j.event : DefaultLoggingEvent, Level, LoggingEvent, toInt;

@safe:

/// This interface based on `java.util.ServiceLoader` paradigm. It replaces the old static-binding mechanism used in SLF4J versions 1.0.x to 1.7.x.
interface SLF4JServiceProvider
{
    /// Return the instance of `ILoggerFactory` that `LoggerFactory` class should bind to.
    ILoggerFactory getLoggerFactory();

    /// Return the instance of `IMarkerFactory` that `MarkerFactory` class should bind to.
    IMarkerFactory getMarkerFactory();

    /// Return the instance of `MDCAdapter` that `MDC` should bind to.
    MDCAdapter getMDCAdapter();

    /// Return the maximum API version for SLF4J that the logging implementation supports.
    string getRequestedApiVersion();

    /// Initialize the logging back-end.
    void initialize();
}

/// This interface abstracts the service offered by various MDC implementations.
interface MDCAdapter
{
    /// Put a context value (the `val` parameter) as identified with the `key` parameter into the current thread's context map.
    void put(string key, string val);

    /// Get the context identified by the `key` parameter.
    string get(string key);

    /// Remove the context identified by the `key` parameter.
    void remove(string key);

    /// Clear all entries in the MDC.
    void clear();

    /// Return a copy of the current thread's context map, or null when it is empty.
    Map!(string, string) getCopyOfContextMap();

    /// Set the current thread's context map by first clearing any existing map and then copying the map passed as parameter.
    void setContextMap(Map!(string, string) contextMap);

    /// Push a value into the deque(stack) referenced by `key`.
    void pushByKey(string key, string value);

    /// Pop the stack referenced by `key` and return the value possibly null.
    string popByKey(string key);

    /// Clear the deque(stack) referenced by `key`.
    void clearDequeByKey(string key);
}

/// A logger that accepts complete `LoggingEvent`s; `DefaultLoggingEventBuilder` hands events to it directly.
interface LoggingEventAware
{
    /// Log the event.
    void log(LoggingEvent event);
}

/// An optional interface helping integration with logging systems capable of extracting location information.
interface LocationAwareLogger : Logger
{
    ///
    enum int TRACE_INT = 00;
    ///
    enum int DEBUG_INT = 10;
    ///
    enum int INFO_INT = 20;
    ///
    enum int WARN_INT = 30;
    ///
    enum int ERROR_INT = 40;

    /// Printing method with support for location information.
    void log(Marker marker, string fqcn, int level, string message, scope Any[] argArray, Throwable t);
}

/// Accepts the fully qualified class name of the caller boundary.
interface CallerBoundaryAware
{
    /// Set the caller boundary.
    void setCallerBoundary(string fqcn);
}

/// This is the main interface in slf4j's fluent API for creating logging events.
interface LoggingEventBuilder
{
    /// Set the cause for the logging event being built.
    LoggingEventBuilder setCause(Throwable cause);

    /// A marker to the event being built.
    LoggingEventBuilder addMarker(Marker marker);

    /// Add an argument to the event being built.
    LoggingEventBuilder addArgument(Any p);

    /// Add an argument supplied by `objectSupplier`.
    LoggingEventBuilder addArgument(Any delegate() @safe objectSupplier);

    /// Add a key value pair to the event being built.
    LoggingEventBuilder addKeyValue(string key, Any value);

    /// Add a key value pair whose value is supplied by `valueSupplier`.
    LoggingEventBuilder addKeyValue(string key, Any delegate() @safe valueSupplier);

    /// Sets the message of the logging event.
    LoggingEventBuilder setMessage(string message);

    /// Sets the message of the event via a message supplier.
    LoggingEventBuilder setMessage(string delegate() @safe messageSupplier);

    /// After the logging event is built, performs actual logging.
    void log();

    /// Equivalent to calling `setMessage(message)` followed by `log()`.
    void log(string message);

    /// Set the message and arguments, then log (Java's `log(String, Object...)`).
    void log(string message, scope Any[] args);

    /// Equivalent to calling `setMessage(messageSupplier)` followed by `log()`.
    void log(string delegate() @safe messageSupplier);

    /// Add an argument of any type, boxed (Java's `addArgument(Object)`).
    LoggingEventBuilder addArgument(T)(T p) if (!is(T == Any) && !is(T == Any delegate()@safe))
    {
        return addArgument(toArgument(p));
    }

    /// Add a key-value pair of any value type, boxed (Java's `addKeyValue(String, Object)`).
    LoggingEventBuilder addKeyValue(T)(string key, T value)
            if (!is(T == Any) && !is(T == Any delegate()@safe))
    {
        return addKeyValue(key, toArgument(value));
    }

    /// Set the message and arguments of any type, then log (Java's `log(String, Object...)`).
    void log(Args...)(string message, Args args) if (Args.length > 0 && !is(Args[0] : Any[]))
    {
        Any[Args.length] boxed;
        static foreach (i; 0 .. Args.length)
            boxed[i] = toArgument(args[i]);
        log(message, boxed[]);
    }
}

/// Default implementation of `LoggingEventBuilder`.
class DefaultLoggingEventBuilder : LoggingEventBuilder, CallerBoundaryAware
{
    alias addArgument = LoggingEventBuilder.addArgument;
    alias addKeyValue = LoggingEventBuilder.addKeyValue;
    alias log = LoggingEventBuilder.log;

    /// The caller boundary when the log() methods are invoked, is this class itself.
    enum string DLEB_FQCN = "flint.slf4j.spi.DefaultLoggingEventBuilder";

    /// The event being built.
    protected DefaultLoggingEvent loggingEvent;
    /// The logger the event goes to.
    protected Logger logger;

    /// A builder for an event at `level` on `logger`.
    this(Logger logger, Level level)
    {
        this.logger = logger;
        loggingEvent = new DefaultLoggingEvent(level, logger);
    }

    /// A marker to the event being built.
    LoggingEventBuilder addMarker(Marker marker)
    {
        loggingEvent.addMarker(marker);
        return this;
    }

    /// Set the cause for the logging event being built.
    LoggingEventBuilder setCause(Throwable t)
    {
        loggingEvent.setThrowable(t);
        return this;
    }

    /// Add an argument to the event being built.
    LoggingEventBuilder addArgument(Any p)
    {
        loggingEvent.addArgument(p);
        return this;
    }

    /// Add an argument supplied by `objectSupplier`.
    LoggingEventBuilder addArgument(Any delegate() @safe objectSupplier)
    {
        loggingEvent.addArgument(objectSupplier());
        return this;
    }

    /// Add a key value pair to the event being built.
    LoggingEventBuilder addKeyValue(string key, Any value)
    {
        loggingEvent.addKeyValue(key, value);
        return this;
    }

    /// Add a key value pair whose value is supplied by `valueSupplier`.
    LoggingEventBuilder addKeyValue(string key, Any delegate() @safe valueSupplier)
    {
        loggingEvent.addKeyValue(key, valueSupplier());
        return this;
    }

    /// Set the caller boundary.
    void setCallerBoundary(string fqcn)
    {
        loggingEvent.setCallerBoundary(fqcn);
    }

    /// After the logging event is built, performs actual logging.
    void log()
    {
        log(loggingEvent);
    }

    /// Sets the message of the logging event.
    LoggingEventBuilder setMessage(string message)
    {
        loggingEvent.setMessage(message);
        return this;
    }

    /// Sets the message of the event via a message supplier.
    LoggingEventBuilder setMessage(string delegate() @safe messageSupplier)
    {
        loggingEvent.setMessage(messageSupplier());
        return this;
    }

    /// Equivalent to calling `setMessage(message)` followed by `log()`.
    void log(string message)
    {
        loggingEvent.setMessage(message);
        log(loggingEvent);
    }

    /// Set the message and arguments, then log.
    void log(string message, scope Any[] args)
    {
        loggingEvent.setMessage(message);
        loggingEvent.addArguments(args);
        log(loggingEvent);
    }

    /// Equivalent to calling `setMessage(messageSupplier)` followed by `log()`.
    void log(string delegate() @safe messageSupplier)
    {
        log(messageSupplier is null ? null : messageSupplier());
    }

    /// Hand the event to the logger: whole when it is `LoggingEventAware`, else through the public API.
    protected void log(LoggingEvent aLoggingEvent)
    {
        if (aLoggingEvent.getCallerBoundary() is null)
            setCallerBoundary(DLEB_FQCN);
        if (auto aware = cast(LoggingEventAware) logger)
            aware.log(aLoggingEvent);
        else if (auto located = cast(LocationAwareLogger) logger)
        {
            auto markers = aLoggingEvent.getMarkers();
            located.log(markers.length ? markers[0] : null, aLoggingEvent.getCallerBoundary(),
                    aLoggingEvent.getLevel().toInt(), mergeMarkersAndKeyValuePairsAndMessage(aLoggingEvent),
                    aLoggingEvent.getArgumentArray(), aLoggingEvent.getThrowable());
        }
        else
            logViaPublicSLF4JLoggerAPI(aLoggingEvent);
    }

    private void logViaPublicSLF4JLoggerAPI(LoggingEvent aLoggingEvent)
    {
        Any[] combined = aLoggingEvent.getArgumentArray().dup;
        if (auto t = aLoggingEvent.getThrowable())
            combined ~= Any.of(t);
        const merged = mergeMarkersAndKeyValuePairsAndMessage(aLoggingEvent);
        final switch (aLoggingEvent.getLevel())
        {
        case Level.TRACE:
            logger.trace(merged, combined);
            break;
        case Level.DEBUG:
            logger.debug_(merged, combined);
            break;
        case Level.INFO:
            logger.info(merged, combined);
            break;
        case Level.WARN:
            logger.warn(merged, combined);
            break;
        case Level.ERROR:
            logger.error(merged, combined);
            break;
        }
    }

    private static string mergeMarkersAndKeyValuePairsAndMessage(LoggingEvent aLoggingEvent)
    {
        string prefix;
        foreach (marker; aLoggingEvent.getMarkers())
            prefix ~= marker.getName() ~ " ";
        foreach (kvp; aLoggingEvent.getKeyValuePairs())
            prefix ~= kvp.toString() ~ " ";
        return prefix.length ? prefix ~ aLoggingEvent.getMessage() : aLoggingEvent.getMessage();
    }
}

/// A no-operation implementation of `LoggingEventBuilder`, returned by `Logger.atLevel` for disabled levels.
final class NOPLoggingEventBuilder : LoggingEventBuilder
{
    alias addArgument = LoggingEventBuilder.addArgument;
    alias addKeyValue = LoggingEventBuilder.addKeyValue;
    alias log = LoggingEventBuilder.log;

    private this() pure nothrow @nogc
    {
    }

    /// The instance to use: it holds no state, so a fresh one is as good as a shared one.
    static LoggingEventBuilder singleton() pure nothrow
    {
        return new NOPLoggingEventBuilder();
    }

    /// Ignored.
    LoggingEventBuilder addMarker(Marker)
    {
        return this;
    }

    /// Ignored.
    LoggingEventBuilder addArgument(Any)
    {
        return this;
    }

    /// Ignored; the supplier is not called.
    LoggingEventBuilder addArgument(Any delegate() @safe)
    {
        return this;
    }

    /// Ignored.
    LoggingEventBuilder addKeyValue(string, Any)
    {
        return this;
    }

    /// Ignored; the supplier is not called.
    LoggingEventBuilder addKeyValue(string, Any delegate() @safe)
    {
        return this;
    }

    /// Ignored.
    LoggingEventBuilder setCause(Throwable)
    {
        return this;
    }

    /// Ignored.
    LoggingEventBuilder setMessage(string)
    {
        return this;
    }

    /// Ignored; the supplier is not called.
    LoggingEventBuilder setMessage(string delegate() @safe)
    {
        return this;
    }

    /// Does nothing.
    void log()
    {
    }

    /// Does nothing.
    void log(string)
    {
    }

    /// Does nothing.
    void log(string, scope Any[])
    {
    }

    /// Does nothing; the supplier is not called.
    void log(string delegate() @safe)
    {
    }
}
