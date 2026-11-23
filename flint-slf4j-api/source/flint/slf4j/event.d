/*
 * Ported from SLF4J (slf4j-api) 2.0.20, https://github.com/qos-ch/slf4j, tag v_2.0.20:
 *   slf4j-api/src/main/java/org/slf4j/event/{Level,LoggingEvent,KeyValuePair,
 *   DefaultLoggingEvent,EventConstants}.java
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
 * Modified by the Flint authors: translated to D (rulebook v2); arguments are
 * boxed in flint.engine.aot.Any.
 */

/// Logging events: levels, the event model handed to providers, and key-value pairs.
module flint.slf4j.event;

import flint.engine.aot.any : Any;
import flint.slf4j : Logger, Marker;

@safe:

/// SLF4J's internal representation of Level.
enum Level
{
    ///
    ERROR = 40,
    ///
    WARN = 30,
    ///
    INFO = 20,
    ///
    DEBUG = 10,
    ///
    TRACE = 0,
}

/// The level's integer value.
int toInt(Level level) pure nothrow @nogc
{
    return cast(int) level;
}

/// The level with integer value `levelInt`.
Level intToLevel(int levelInt) pure
{
    import flint.engine.aot.text : decimal;
    import flint.java.lang : IllegalArgumentException;

    switch (levelInt)
    {
    case EventConstants.TRACE_INT:
        return Level.TRACE;
    case EventConstants.DEBUG_INT:
        return Level.DEBUG;
    case EventConstants.INFO_INT:
        return Level.INFO;
    case EventConstants.WARN_INT:
        return Level.WARN;
    case EventConstants.ERROR_INT:
        return Level.ERROR;
    default:
        throw new IllegalArgumentException("Level integer [" ~ decimal(cast(long) levelInt) ~ "] not recognized.");
    }
}

/// The integer values of the levels.
struct EventConstants
{
    ///
    enum int ERROR_INT = 40;
    ///
    enum int WARN_INT = 30;
    ///
    enum int INFO_INT = 20;
    ///
    enum int DEBUG_INT = 10;
    ///
    enum int TRACE_INT = 0;
    ///
    enum string NA_SUBST = "NA/SubstituteLogger";
}

/// A key-value pair attached to a logging event by the fluent API.
final class KeyValuePair
{
    /// The key.
    const string key;
    /// The value, boxed.
    Any value;
    private string text;

    ///
    this(string key, Any value)
    {
        import flint.slf4j.helpers : MessageFormatter;

        this.key = key;
        this.value = value;
        text = MessageFormatter.render(value);
    }

    /// `key=value`, as SLF4J prints it.
    override string toString() const
    {
        return key ~ "=" ~ text;
    }
}

/// The minimal interface sufficient for the restitution of data passed by the user to the SLF4J API.
interface LoggingEvent
{
    /// The event's level.
    Level getLevel();
    /// The name of the logger that produced the event.
    string getLoggerName();
    /// The message pattern, with `{}` anchors.
    string getMessage();
    /// The arguments, in order.
    Any[] getArgumentArray();
    /// The markers, in order.
    Marker[] getMarkers();
    /// The key-value pairs, in order.
    KeyValuePair[] getKeyValuePairs();
    /// The throwable, or null.
    Throwable getThrowable();
    /// Milliseconds since the Unix epoch when the event was created.
    long getTimeStamp();
    /// The name of the thread, or the reactor fiber, that produced the event.
    string getThreadName();
    /// The fully qualified class name of the caller boundary, or null.
    string getCallerBoundary();
}

/// A default implementation of `LoggingEvent`.
class DefaultLoggingEvent : LoggingEvent
{
    private string loggerName;
    private Level level;
    private string message;
    private Any[] arguments;
    private Marker[] markers;
    private KeyValuePair[] keyValuePairs;
    private Throwable throwable;
    private string threadName;
    private long timeStamp;
    private string callerBoundary;

    /// An event at `level` for `logger`, stamped with the current time.
    this(Level level, Logger logger)
    {
        this(level, logger.getName());
    }

    /// An event at `level` for the logger named `loggerName`, stamped with the current time.
    this(Level level, string loggerName)
    {
        this.level = level;
        this.loggerName = loggerName;
        timeStamp = currentTimeMillis();
        threadName = currentThreadName();
    }

    /// Add a marker.
    void addMarker(Marker marker)
    {
        markers ~= marker;
    }

    /// Add an argument (copied: events outlive the call).
    void addArgument(Any p)
    {
        arguments ~= p;
    }

    /// Add arguments (copied: events outlive the call).
    void addArguments(scope Any[] args)
    {
        foreach (a; args)
            arguments ~= a;
    }

    /// Add a key-value pair.
    void addKeyValue(string key, Any value)
    {
        keyValuePairs ~= new KeyValuePair(key, value);
    }

    /// Set the message pattern.
    void setMessage(string message)
    {
        this.message = message;
    }

    /// Set the throwable.
    void setThrowable(Throwable cause)
    {
        throwable = cause;
    }

    /// Set the thread name.
    void setThreadName(string threadName)
    {
        this.threadName = threadName;
    }

    /// Set the time stamp.
    void setTimeStamp(long timeStamp)
    {
        this.timeStamp = timeStamp;
    }

    /// Set the caller boundary.
    void setCallerBoundary(string fqcn)
    {
        callerBoundary = fqcn;
    }

    /// The event's level.
    Level getLevel()
    {
        return level;
    }

    /// The name of the logger that produced the event.
    string getLoggerName()
    {
        return loggerName;
    }

    /// The message pattern, with `{}` anchors.
    string getMessage()
    {
        return message;
    }

    /// The arguments, in order.
    Any[] getArgumentArray()
    {
        return arguments;
    }

    /// The markers, in order.
    Marker[] getMarkers()
    {
        return markers;
    }

    /// The key-value pairs, in order.
    KeyValuePair[] getKeyValuePairs()
    {
        return keyValuePairs;
    }

    /// The throwable, or null.
    Throwable getThrowable()
    {
        return throwable;
    }

    /// Milliseconds since the Unix epoch when the event was created.
    long getTimeStamp()
    {
        return timeStamp;
    }

    /// The name of the thread, or the reactor fiber, that produced the event.
    string getThreadName()
    {
        return threadName;
    }

    /// The fully qualified class name of the caller boundary, or null.
    string getCallerBoundary()
    {
        return callerBoundary;
    }
}

/// Milliseconds since the Unix epoch, as `System.currentTimeMillis()`.
long currentTimeMillis() nothrow
{
    import flint.engine.aot.clock : systemMillis = currentTimeMillis;

    return systemMillis();
}

/// The name SLF4J events carry for the current thread: "main" on the main thread, else "thread-<id>".
string currentThreadName() nothrow
{
    return "main";
}
