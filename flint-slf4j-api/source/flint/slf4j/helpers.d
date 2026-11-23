/*
 * Ported from SLF4J (slf4j-api) 2.0.20, https://github.com/qos-ch/slf4j, tag v_2.0.20:
 *   slf4j-api/src/main/java/org/slf4j/helpers/{MessageFormatter,FormattingTuple,
 *   NormalizedParameters,BasicMarker,BasicMarkerFactory,NOPLogger,NOPLoggerFactory,
 *   NOPMDCAdapter,AbstractLogger}.java
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
 * Modified by the Flint authors: translated to D (rulebook v2). Arguments are
 * flint.engine.aot.Any; `render` is Java's String.valueOf for them.
 */

/// Helpers for logger implementations: message formatting, markers, the NOP logger and `AbstractLogger`.
module flint.slf4j.helpers;

import flint.engine.aot.any : Any;
import flint.java.util : Map;
import flint.slf4j : ILoggerFactory, IMarkerFactory, Logger, Marker;
import flint.slf4j.event : Level;
import flint.slf4j.spi : MDCAdapter;

@safe:

/// Holds the results of formatting done by `MessageFormatter`.
final class FormattingTuple
{
    private string message;
    private Throwable throwable;
    private Any[] argArray;

    /// A message with no arguments.
    this(string message) pure nothrow
    {
        this(message, null, null);
    }

    ///
    this(string message, Any[] argArray, Throwable throwable) pure nothrow
    {
        this.message = message;
        this.throwable = throwable;
        this.argArray = argArray;
    }

    /// The formatted message.
    string getMessage() pure nothrow @nogc
    {
        return message;
    }

    /// The arguments.
    Any[] getArgArray() pure nothrow @nogc
    {
        return argArray;
    }

    /// The throwable, or null.
    Throwable getThrowable() pure nothrow @nogc
    {
        return throwable;
    }
}

/**
 * Formats messages according to very simple substitution rules. Substitutions
 * can be made 1, 2 or more arguments.
 *
 * For example, `MessageFormatter.format("Hi {}.", "there")` will return the
 * string "Hi there.". The {} pair is called the formatting anchor. It serves to
 * designate the location where arguments need to be substituted within the
 * message pattern. In case your message contains the '{' or the '}' character,
 * you do not have to do anything special unless the '}' character immediately
 * follows '{'. If for whatever reason you need to place the string "{}" in the
 * message without its formatting anchor meaning, then you need to escape the
 * '{' character with '\', that is the backslash character.
 */
struct MessageFormatter
{
    private enum string DELIM_STR = "{}";
    private enum char ESCAPE_CHAR = '\\';

    /// Performs single argument substitution for the 'messagePattern' passed as parameter.
    static FormattingTuple format(string messagePattern, Any arg)
    {
        Any[1] args = [arg];
        return arrayFormat(messagePattern, args[]);
    }

    /// Performs a two argument substitution for the 'messagePattern' passed as parameter.
    static FormattingTuple format(string messagePattern, Any arg1, Any arg2)
    {
        Any[2] args = [arg1, arg2];
        return arrayFormat(messagePattern, args[]);
    }

    /// Substitute the arguments, taking a trailing `Throwable` argument as the throwable.
    static FormattingTuple arrayFormat(string messagePattern, scope Any[] argArray)
    {
        auto throwableCandidate = getThrowableCandidate(argArray);
        Any[] args = argArray;
        if (throwableCandidate !is null)
            args = trimmedCopy(argArray);
        return arrayFormat(messagePattern, args, throwableCandidate);
    }

    /// Substitute the arguments; the throwable, if any, is given separately.
    static string basicArrayFormat(string messagePattern, scope Any[] argArray)
    {
        return arrayFormat(messagePattern, argArray, null).getMessage();
    }

    /// Substitute the normalized parameters' arguments into their message.
    static string basicArrayFormat(NormalizedParameters np)
    {
        return basicArrayFormat(np.getMessage(), np.getArguments());
    }

    /// Substitute the arguments into the pattern, keeping `throwable` as given.
    static FormattingTuple arrayFormat(string messagePattern, scope Any[] argArray, Throwable throwable)
    {
        if (messagePattern is null)
            return new FormattingTuple(null, argArray.dup, throwable);
        if (argArray is null)
            return new FormattingTuple(messagePattern);
        string buffer;
        size_t i;
        for (size_t l = 0; l < argArray.length; ++l)
        {
            immutable j = indexOf(messagePattern, i);
            if (j == size_t.max)
            {
                if (i == 0)
                    return new FormattingTuple(messagePattern, argArray.dup, throwable);
                return new FormattingTuple(buffer ~ messagePattern[i .. $], argArray.dup, throwable);
            }
            if (isEscapedDelimeter(messagePattern, j))
            {
                if (!isDoubleEscaped(messagePattern, j))
                {
                    --l; // DELIM_START was escaped, thus should not be incremented
                    buffer ~= messagePattern[i .. j - 1];
                    buffer ~= '{';
                    i = j + 1;
                }
                else
                {
                    // The escape character preceding the delimiter start is itself escaped: "abc x:\\{}"
                    buffer ~= messagePattern[i .. j - 1];
                    buffer ~= render(argArray[l]);
                    i = j + 2;
                }
            }
            else
            {
                buffer ~= messagePattern[i .. j];
                buffer ~= render(argArray[l]);
                i = j + 2;
            }
        }
        return new FormattingTuple(buffer ~ messagePattern[i .. $], argArray.dup, throwable);
    }

    private static size_t indexOf(string pattern, size_t from) pure nothrow @nogc
    {
        for (size_t k = from; k + 1 < pattern.length; ++k)
            if (pattern[k] == '{' && pattern[k + 1] == '}')
                return k;
        return size_t.max;
    }

    private static bool isEscapedDelimeter(string messagePattern, size_t delimeterStartIndex) pure nothrow @nogc
    {
        return delimeterStartIndex != 0 && messagePattern[delimeterStartIndex - 1] == ESCAPE_CHAR;
    }

    private static bool isDoubleEscaped(string messagePattern, size_t delimeterStartIndex) pure nothrow @nogc
    {
        return delimeterStartIndex >= 2 && messagePattern[delimeterStartIndex - 2] == ESCAPE_CHAR;
    }

    /// The last argument when it is a `Throwable`, else null.
    static Throwable getThrowableCandidate(scope Any[] argArray)
    {
        return NormalizedParameters.getThrowableCandidate(argArray);
    }

    /// A copy of the arguments without the last one.
    static Any[] trimmedCopy(scope Any[] argArray)
    {
        return NormalizedParameters.trimmedCopy(argArray);
    }

    /// Java's `String.valueOf` of a boxed argument: "null", the object's `toString()`, Java's number text.
    static string render(Any value)
    {
        if (value.isNull())
            return "null";
        if (auto o = value.asObject())
            return renderObject(o);
        return renderScalar(value);
    }

    private static string renderObject(Object o)
    {
        import flint.engine.aot.objects : objectToString;
        import flint.java.lang : javaToString;

        if (auto t = cast(Throwable) o)
            return javaToString(t);
        // MessageFormatter.safeObjectAppend: a failing toString() must not abort logging.
        try
            return objectToString(o);
        catch (Exception)
            return "[FAILED toString()]";
    }

    private static string renderScalar(Any value)
    {
        import flint.serde.java_number : javaDoubleString;
        import std.conv : to;

        if (value.holds!string())
            return value.get!string();
        if (value.holds!bool())
            return value.get!bool() ? "true" : "false";
        if (value.holds!dchar())
            return [value.get!dchar()].to!string;
        if (value.holds!long() || value.holds!ulong())
            return value.toString();
        if (value.holds!double())
            return javaDoubleString(value.get!double());
        return value.toString();
    }

    /// Java's `String.valueOf` for values that are boxed as text: enums print their name, arrays as `[a, b]`.
    static string valueOf(T)(T value)
    {
        import flint.serde.java_number : javaFloatString;
        import std.conv : to;

        alias U = typeof(cast() value);
        static if (is(U == float))
            return javaFloatString(value);
        else static if (is(U == enum))
            return value.to!string;
        else static if (is(U == class) || is(U == interface))
        {
            import flint.engine.aot.objects : objectToString;

            return value is null ? "null" : objectToString(cast(Object) value);
        }
        else static if (is(U : const(char)[]))
            return value is null ? "null" : value.idup;
        else static if (is(U == E[], E) || is(U == E[n], E, size_t n))
        {
            string text = "[";
            foreach (i, element; value)
            {
                if (i)
                    text ~= ", ";
                text ~= render(toArgumentAny(element));
            }
            return text ~ "]";
        }
        else
            return value.to!string;
    }

    private static Any toArgumentAny(T)(T value)
    {
        import flint.slf4j : toArgument;

        return toArgument(value);
    }
}

/// Holds normalized call parameters: the message, the arguments and the throwable.
final class NormalizedParameters
{
    private string message;
    private Any[] arguments;
    private Throwable throwable;

    ///
    this(string message, Any[] arguments, Throwable throwable = null) pure nothrow
    {
        this.message = message;
        this.arguments = arguments;
        this.throwable = throwable;
    }

    /// The message pattern.
    string getMessage() pure nothrow @nogc
    {
        return message;
    }

    /// The arguments.
    Any[] getArguments() pure nothrow @nogc
    {
        return arguments;
    }

    /// The throwable, or null.
    Throwable getThrowable() pure nothrow @nogc
    {
        return throwable;
    }

    /// The last argument when it is a `Throwable`, else null.
    static Throwable getThrowableCandidate(scope Any[] argArray)
    {
        if (argArray.length == 0)
            return null;
        return cast(Throwable) argArray[$ - 1].asObject();
    }

    /// A copy of the arguments without the last one.
    static Any[] trimmedCopy(scope Any[] argArray)
    {
        import flint.java.lang : IllegalStateException;

        if (argArray.length == 0)
            throw new IllegalStateException("non-sensical empty or null argument array");
        return argArray[0 .. $ - 1].dup;
    }

    /// Normalize: a trailing `Throwable` argument becomes the throwable unless one was given.
    static NormalizedParameters normalize(string msg, scope Any[] arguments, Throwable t)
    {
        if (t !is null || arguments.length == 0)
            return new NormalizedParameters(msg, arguments.dup, t);
        auto candidate = getThrowableCandidate(arguments);
        if (candidate !is null)
            return new NormalizedParameters(msg, trimmedCopy(arguments), candidate);
        return new NormalizedParameters(msg, arguments.dup);
    }
}

/// A simple implementation of the `Marker` interface.
class BasicMarker : Marker
{
    private string name;
    private Marker[] referenceList;

    /// A marker named `name`; null is rejected.
    this(string name)
    {
        import flint.java.lang : IllegalArgumentException;

        if (name is null)
            throw new IllegalArgumentException("A marker name cannot be null");
        this.name = name;
    }

    /// Get the name of this Marker.
    string getName()
    {
        return name;
    }

    /// Add a reference to another Marker.
    void add(Marker reference)
    {
        import flint.java.lang : IllegalArgumentException;

        if (reference is null)
            throw new IllegalArgumentException("A null value cannot be added to a Marker as reference.");
        if (contains(reference) || reference.contains(this))
            return;
        referenceList ~= reference;
    }

    /// Remove a marker reference.
    bool remove(Marker referenceToRemove)
    {
        foreach (i, r; referenceList)
        {
            if (r is referenceToRemove)
            {
                referenceList = referenceList[0 .. i] ~ referenceList[i + 1 .. $];
                return true;
            }
        }
        return false;
    }

    /// Does this marker have any references?
    bool hasReferences()
    {
        return referenceList.length > 0;
    }

    /// The referenced markers, in insertion order.
    Marker[] references()
    {
        return referenceList.dup;
    }

    /// Whether this marker is `other` or references it, directly or transitively.
    bool contains(Marker other)
    {
        import flint.java.lang : IllegalArgumentException;

        if (other is null)
            throw new IllegalArgumentException("Other cannot be null");
        if (this is other)
            return true;
        foreach (r; referenceList)
            if (r.contains(other))
                return true;
        return false;
    }

    /// Whether this marker, or one it references, is named `name`.
    bool contains(string name)
    {
        import flint.java.lang : IllegalArgumentException;

        if (name is null)
            throw new IllegalArgumentException("Other cannot be null");
        if (this.name == name)
            return true;
        foreach (r; referenceList)
            if (r.contains(name))
                return true;
        return false;
    }

    /// Markers are equal by name.
    override bool opEquals(Object obj) const
    {
        auto other = cast(const BasicMarker) obj;
        return other !is null && other.name == name;
    }

    /// The name's hash.
    override size_t toHash() const nothrow
    {
        return hashOf(name);
    }

    /// `name [ child, child ]`, as SLF4J prints a marker.
    override string toString() const
    {
        if (referenceList.length == 0)
            return name;
        string text = name ~ " [ ";
        foreach (i, r; referenceList)
        {
            if (i)
                text ~= ", ";
            auto child = cast(const BasicMarker) r;
            text ~= child is null ? "?" : child.name;
        }
        return text ~ " ]";
    }
}

/**
 * An almost trivial implementation of the `IMarkerFactory` interface which
 * creates `BasicMarker` instances. Markers are kept by name for the factory's
 * lifetime; the registry is guarded so fibers on several threads may share it.
 */
class BasicMarkerFactory : IMarkerFactory
{
    private Marker[string] markerMap;

    /// Manufacture a `BasicMarker` instance by name. If the instance has been created earlier, return the previously created instance.
    Marker getMarker(string name)
    {
        import flint.java.lang : IllegalArgumentException;

        if (name is null)
            throw new IllegalArgumentException("Marker name cannot be null");
        synchronized (this)
        {
            if (auto found = name in markerMap)
                return *found;
            auto marker = new BasicMarker(name);
            markerMap[name] = marker;
            return marker;
        }
    }

    /// Does the name marked already exist?
    bool exists(string name)
    {
        synchronized (this)
            return name !is null && (name in markerMap) !is null;
    }

    /// Detach the marker named `name`.
    bool detachMarker(string name)
    {
        synchronized (this)
            return name !is null && markerMap.remove(name);
    }

    /// Create a marker which is detached (even at birth) from this IMarkerFactory.
    Marker getDetachedMarker(string name)
    {
        return new BasicMarker(name);
    }
}

/// A direct NOP (no operation) implementation of `Logger`.
class NOPLogger : Logger
{
    /// The unique instance of NOPLogger.
    static NOPLogger NOP_LOGGER() pure nothrow
    {
        return new NOPLogger();
    }

    /// There is no point in creating multiple instances of NOPLogger.
    protected this() pure nothrow @nogc
    {
    }

    /// Always returns the string value "NOP".
    string getName()
    {
        return "NOP";
    }

    /// Always false.
    bool isTraceEnabled()
    {
        return false;
    }

    /// ditto
    bool isTraceEnabled(Marker)
    {
        return false;
    }

    /// A NOP implementation.
    void trace(string)
    {
    }

    /// ditto
    void trace(string, scope Any[])
    {
    }

    /// ditto
    void trace(string, Throwable)
    {
    }

    /// ditto
    void trace(Marker, string)
    {
    }

    /// ditto
    void trace(Marker, string, scope Any[])
    {
    }

    /// ditto
    void trace(Marker, string, Throwable)
    {
    }

    /// Always false.
    bool isDebugEnabled()
    {
        return false;
    }

    /// ditto
    bool isDebugEnabled(Marker)
    {
        return false;
    }

    /// A NOP implementation.
    void debug_(string)
    {
    }

    /// ditto
    void debug_(string, scope Any[])
    {
    }

    /// ditto
    void debug_(string, Throwable)
    {
    }

    /// ditto
    void debug_(Marker, string)
    {
    }

    /// ditto
    void debug_(Marker, string, scope Any[])
    {
    }

    /// ditto
    void debug_(Marker, string, Throwable)
    {
    }

    /// Always false.
    bool isInfoEnabled()
    {
        return false;
    }

    /// ditto
    bool isInfoEnabled(Marker)
    {
        return false;
    }

    /// A NOP implementation.
    void info(string)
    {
    }

    /// ditto
    void info(string, scope Any[])
    {
    }

    /// ditto
    void info(string, Throwable)
    {
    }

    /// ditto
    void info(Marker, string)
    {
    }

    /// ditto
    void info(Marker, string, scope Any[])
    {
    }

    /// ditto
    void info(Marker, string, Throwable)
    {
    }

    /// Always false.
    bool isWarnEnabled()
    {
        return false;
    }

    /// ditto
    bool isWarnEnabled(Marker)
    {
        return false;
    }

    /// A NOP implementation.
    void warn(string)
    {
    }

    /// ditto
    void warn(string, scope Any[])
    {
    }

    /// ditto
    void warn(string, Throwable)
    {
    }

    /// ditto
    void warn(Marker, string)
    {
    }

    /// ditto
    void warn(Marker, string, scope Any[])
    {
    }

    /// ditto
    void warn(Marker, string, Throwable)
    {
    }

    /// Always false.
    bool isErrorEnabled()
    {
        return false;
    }

    /// ditto
    bool isErrorEnabled(Marker)
    {
        return false;
    }

    /// A NOP implementation.
    void error(string)
    {
    }

    /// ditto
    void error(string, scope Any[])
    {
    }

    /// ditto
    void error(string, Throwable)
    {
    }

    /// ditto
    void error(Marker, string)
    {
    }

    /// ditto
    void error(Marker, string, scope Any[])
    {
    }

    /// ditto
    void error(Marker, string, Throwable)
    {
    }
}

/// NOPLoggerFactory is a trivial implementation of `ILoggerFactory` which always returns the unique instance of NOPLogger.
class NOPLoggerFactory : ILoggerFactory
{
    /// The NOP logger, whatever the name.
    Logger getLogger(string)
    {
        return NOPLogger.NOP_LOGGER();
    }
}

/// This adapter is an empty implementation of the `MDCAdapter` interface.
class NOPMDCAdapter : MDCAdapter
{
    /// Ignored.
    void clear()
    {
    }

    /// Always null.
    string get(string)
    {
        return null;
    }

    /// Ignored.
    void put(string, string)
    {
    }

    /// Ignored.
    void remove(string)
    {
    }

    /// Always null.
    Map!(string, string) getCopyOfContextMap()
    {
        return null;
    }

    /// Ignored.
    void setContextMap(Map!(string, string))
    {
    }

    /// Ignored.
    void pushByKey(string, string)
    {
    }

    /// Always null.
    string popByKey(string)
    {
        return null;
    }

    /// Ignored.
    void clearDequeByKey(string)
    {
    }
}

/**
 * An abstract implementation which delegates actual logging work to the
 * `handleNormalizedLoggingCall` method.
 */
abstract class AbstractLogger : Logger
{
    /// The logger's name.
    protected string name;

    /// Return the name of this `Logger` instance.
    string getName()
    {
        return name;
    }

    /// Logs at TRACE when enabled.
    void trace(string msg)
    {
        if (isTraceEnabled())
            handleNormalizedLoggingCall(Level.TRACE, null, msg, null, null);
    }

    /// ditto
    void trace(string format, scope Any[] arguments)
    {
        if (isTraceEnabled())
            handleArgArrayCall(Level.TRACE, null, format, arguments);
    }

    /// ditto
    void trace(string msg, Throwable t)
    {
        if (isTraceEnabled())
            handleNormalizedLoggingCall(Level.TRACE, null, msg, null, t);
    }

    /// ditto
    void trace(Marker marker, string msg)
    {
        if (isTraceEnabled(marker))
            handleNormalizedLoggingCall(Level.TRACE, marker, msg, null, null);
    }

    /// ditto
    void trace(Marker marker, string format, scope Any[] arguments)
    {
        if (isTraceEnabled(marker))
            handleArgArrayCall(Level.TRACE, marker, format, arguments);
    }

    /// ditto
    void trace(Marker marker, string msg, Throwable t)
    {
        if (isTraceEnabled(marker))
            handleNormalizedLoggingCall(Level.TRACE, marker, msg, null, t);
    }

    /// Logs at DEBUG when enabled.
    void debug_(string msg)
    {
        if (isDebugEnabled())
            handleNormalizedLoggingCall(Level.DEBUG, null, msg, null, null);
    }

    /// ditto
    void debug_(string format, scope Any[] arguments)
    {
        if (isDebugEnabled())
            handleArgArrayCall(Level.DEBUG, null, format, arguments);
    }

    /// ditto
    void debug_(string msg, Throwable t)
    {
        if (isDebugEnabled())
            handleNormalizedLoggingCall(Level.DEBUG, null, msg, null, t);
    }

    /// ditto
    void debug_(Marker marker, string msg)
    {
        if (isDebugEnabled(marker))
            handleNormalizedLoggingCall(Level.DEBUG, marker, msg, null, null);
    }

    /// ditto
    void debug_(Marker marker, string format, scope Any[] arguments)
    {
        if (isDebugEnabled(marker))
            handleArgArrayCall(Level.DEBUG, marker, format, arguments);
    }

    /// ditto
    void debug_(Marker marker, string msg, Throwable t)
    {
        if (isDebugEnabled(marker))
            handleNormalizedLoggingCall(Level.DEBUG, marker, msg, null, t);
    }

    /// Logs at INFO when enabled.
    void info(string msg)
    {
        if (isInfoEnabled())
            handleNormalizedLoggingCall(Level.INFO, null, msg, null, null);
    }

    /// ditto
    void info(string format, scope Any[] arguments)
    {
        if (isInfoEnabled())
            handleArgArrayCall(Level.INFO, null, format, arguments);
    }

    /// ditto
    void info(string msg, Throwable t)
    {
        if (isInfoEnabled())
            handleNormalizedLoggingCall(Level.INFO, null, msg, null, t);
    }

    /// ditto
    void info(Marker marker, string msg)
    {
        if (isInfoEnabled(marker))
            handleNormalizedLoggingCall(Level.INFO, marker, msg, null, null);
    }

    /// ditto
    void info(Marker marker, string format, scope Any[] arguments)
    {
        if (isInfoEnabled(marker))
            handleArgArrayCall(Level.INFO, marker, format, arguments);
    }

    /// ditto
    void info(Marker marker, string msg, Throwable t)
    {
        if (isInfoEnabled(marker))
            handleNormalizedLoggingCall(Level.INFO, marker, msg, null, t);
    }

    /// Logs at WARN when enabled.
    void warn(string msg)
    {
        if (isWarnEnabled())
            handleNormalizedLoggingCall(Level.WARN, null, msg, null, null);
    }

    /// ditto
    void warn(string format, scope Any[] arguments)
    {
        if (isWarnEnabled())
            handleArgArrayCall(Level.WARN, null, format, arguments);
    }

    /// ditto
    void warn(string msg, Throwable t)
    {
        if (isWarnEnabled())
            handleNormalizedLoggingCall(Level.WARN, null, msg, null, t);
    }

    /// ditto
    void warn(Marker marker, string msg)
    {
        if (isWarnEnabled(marker))
            handleNormalizedLoggingCall(Level.WARN, marker, msg, null, null);
    }

    /// ditto
    void warn(Marker marker, string format, scope Any[] arguments)
    {
        if (isWarnEnabled(marker))
            handleArgArrayCall(Level.WARN, marker, format, arguments);
    }

    /// ditto
    void warn(Marker marker, string msg, Throwable t)
    {
        if (isWarnEnabled(marker))
            handleNormalizedLoggingCall(Level.WARN, marker, msg, null, t);
    }

    /// Logs at ERROR when enabled.
    void error(string msg)
    {
        if (isErrorEnabled())
            handleNormalizedLoggingCall(Level.ERROR, null, msg, null, null);
    }

    /// ditto
    void error(string format, scope Any[] arguments)
    {
        if (isErrorEnabled())
            handleArgArrayCall(Level.ERROR, null, format, arguments);
    }

    /// ditto
    void error(string msg, Throwable t)
    {
        if (isErrorEnabled())
            handleNormalizedLoggingCall(Level.ERROR, null, msg, null, t);
    }

    /// ditto
    void error(Marker marker, string msg)
    {
        if (isErrorEnabled(marker))
            handleNormalizedLoggingCall(Level.ERROR, marker, msg, null, null);
    }

    /// ditto
    void error(Marker marker, string format, scope Any[] arguments)
    {
        if (isErrorEnabled(marker))
            handleArgArrayCall(Level.ERROR, marker, format, arguments);
    }

    /// ditto
    void error(Marker marker, string msg, Throwable t)
    {
        if (isErrorEnabled(marker))
            handleNormalizedLoggingCall(Level.ERROR, marker, msg, null, t);
    }

    private void handleArgArrayCall(Level level, Marker marker, string msg, scope Any[] args)
    {
        auto throwableCandidate = MessageFormatter.getThrowableCandidate(args);
        if (throwableCandidate !is null)
            handleNormalizedLoggingCall(level, marker, msg, MessageFormatter.trimmedCopy(args), throwableCandidate);
        else
            handleNormalizedLoggingCall(level, marker, msg, args, null);
    }

    /// The fully qualified class name of the caller boundary, or null.
    protected abstract string getFullyQualifiedCallerName();

    /// Given various arguments passed as parameters, perform actual logging. The arguments are borrowed for the call.
    protected abstract void handleNormalizedLoggingCall(Level level, Marker marker,
            string messagePattern, scope Any[] arguments, Throwable throwable);
}
