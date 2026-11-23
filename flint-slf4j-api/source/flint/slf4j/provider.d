/// Flint's default SLF4J binding: loggers over the `flint.log` engine, with the MDC in a `FiberLocal`.
///
/// Java's SLF4J finds a provider with `ServiceLoader` and falls back to a NOP logger. Flint's closed world
/// installs one with `LoggerFactory.installProvider`, and falls back to this provider, which writes through
/// `flint.log` (deviation D-SLF4J-1). Spring Boot's logging system keeps the loggers, levels and MDC and
/// replaces only the output, with `setAppender`, to print its own console format.
module flint.slf4j.provider;

import flint.conc.slot : ProcessSlot;
import flint.engine.aot.any : Any;
import flint.engine.reactor : FiberLocal;
import flint.java.util : HashMap, Map;
import flint.slf4j : ILoggerFactory, IMarkerFactory, Logger, Marker;
import flint.slf4j.event : DefaultLoggingEvent, Level, LoggingEvent;
import flint.slf4j.helpers : AbstractLogger, BasicMarkerFactory, MessageFormatter;
import flint.slf4j.spi : LoggingEventAware, MDCAdapter, SLF4JServiceProvider;

@safe:

private shared ProcessSlot!SLF4JServiceProvider bound;

/// The bound provider, binding the default one on first use.
package(flint.slf4j) SLF4JServiceProvider providerSlot()
{
    if (auto provider = bound.get())
        return provider;
    auto created = new FlintLogServiceProvider();
    created.initialize();
    return bound.setIfAbsent(created);
}

/// Bind `provider`, replacing any earlier binding.
package(flint.slf4j) void installSlot(SLF4JServiceProvider provider)
{
    bound.set(provider);
}

/// Receives each enabled logging event; Spring Boot's logging system installs one to print its console format.
alias Appender = void delegate(LoggingEvent event) @safe;

/// The default provider: `FlintLogLogger`s, a `BasicMarkerFactory` and the fiber-local `FiberMDCAdapter`.
final class FlintLogServiceProvider : SLF4JServiceProvider
{
    /// Declare the version of the SLF4J API this implementation is compiled against.
    enum string REQUESTED_API_VERSION = "2.0.99";

    private FlintLogLoggerFactory loggerFactory;
    private BasicMarkerFactory markerFactory;
    private FiberMDCAdapter mdcAdapter;

    /// Return the instance of `ILoggerFactory` that `LoggerFactory` class should bind to.
    ILoggerFactory getLoggerFactory()
    {
        return loggerFactory;
    }

    /// Return the instance of `IMarkerFactory` that `MarkerFactory` class should bind to.
    IMarkerFactory getMarkerFactory()
    {
        return markerFactory;
    }

    /// Return the instance of `MDCAdapter` that `MDC` should bind to.
    MDCAdapter getMDCAdapter()
    {
        return mdcAdapter;
    }

    /// Return the maximum API version for SLF4J that the logging implementation supports.
    string getRequestedApiVersion()
    {
        return REQUESTED_API_VERSION;
    }

    /// Initialize the logging back-end.
    void initialize()
    {
        if (loggerFactory !is null)
            return;
        mdcAdapter = new FiberMDCAdapter();
        loggerFactory = new FlintLogLoggerFactory(mdcAdapter);
        markerFactory = new BasicMarkerFactory();
    }

    /// The logger factory, for level configuration.
    FlintLogLoggerFactory loggers()
    {
        initialize();
        return loggerFactory;
    }
}

/// Manufactures `FlintLogLogger`s by name, keeps Boot-style levels by logger-name prefix, and owns the appender.
final class FlintLogLoggerFactory : ILoggerFactory
{
    private FlintLogLogger[string] loggerMap;
    private Level[string] levels;
    private Level rootLevel = Level.INFO;
    private Appender appender;
    private FiberMDCAdapter mdc;

    private this(FiberMDCAdapter mdc)
    {
        this.mdc = mdc;
        appender = (LoggingEvent event) { FlintLogAppender.append(event); };
    }

    /// Return the logger named `name`, creating it once.
    Logger getLogger(string name)
    {
        synchronized (this)
        {
            if (auto found = name in loggerMap)
                return *found;
            auto logger = new FlintLogLogger(this, name);
            loggerMap[name] = logger;
            return logger;
        }
    }

    /// Set the level of `name` and the loggers below it (`logging.level.<name>`); "ROOT" sets the root level.
    void setLevel(string name, Level level)
    {
        synchronized (this)
        {
            if (name == Logger.ROOT_LOGGER_NAME || name.length == 0)
                rootLevel = level;
            else
                levels[name] = level;
        }
    }

    /// The effective level of `name`: the nearest configured ancestor's (`a.b` for `a.b.C`), else the root's.
    Level effectiveLevel(string name)
    {
        synchronized (this)
        {
            for (string candidate = name; candidate.length;)
            {
                if (auto found = candidate in levels)
                    return *found;
                size_t dot = candidate.length;
                while (dot > 0 && candidate[dot - 1] != '.')
                    --dot;
                candidate = dot == 0 ? null : candidate[0 .. dot - 1];
            }
            return rootLevel;
        }
    }

    /// Replace the appender that receives every enabled event; null restores the `flint.log` one.
    void setAppender(Appender replacement)
    {
        synchronized (this)
            appender = replacement !is null ? replacement : (LoggingEvent event) {
            FlintLogAppender.append(event);
        };
    }

    private Appender currentAppender()
    {
        synchronized (this)
            return appender;
    }
}

/// A logger whose events go to its factory's appender, with the caller's MDC snapshot.
final class FlintLogLogger : AbstractLogger, LoggingEventAware
{
    private FlintLogLoggerFactory factory;

    private this(FlintLogLoggerFactory factory, string name)
    {
        this.factory = factory;
        this.name = name;
    }

    private bool enabled(Level level)
    {
        return level >= factory.effectiveLevel(name);
    }

    /// Is the logger instance enabled for the TRACE level?
    bool isTraceEnabled()
    {
        return enabled(Level.TRACE);
    }

    /// Similar to `isTraceEnabled()`; markers do not change the decision.
    bool isTraceEnabled(Marker)
    {
        return enabled(Level.TRACE);
    }

    /// Is the logger instance enabled for the DEBUG level?
    bool isDebugEnabled()
    {
        return enabled(Level.DEBUG);
    }

    /// Similar to `isDebugEnabled()`; markers do not change the decision.
    bool isDebugEnabled(Marker)
    {
        return enabled(Level.DEBUG);
    }

    /// Is the logger instance enabled for the INFO level?
    bool isInfoEnabled()
    {
        return enabled(Level.INFO);
    }

    /// Similar to `isInfoEnabled()`; markers do not change the decision.
    bool isInfoEnabled(Marker)
    {
        return enabled(Level.INFO);
    }

    /// Is the logger instance enabled for the WARN level?
    bool isWarnEnabled()
    {
        return enabled(Level.WARN);
    }

    /// Similar to `isWarnEnabled()`; markers do not change the decision.
    bool isWarnEnabled(Marker)
    {
        return enabled(Level.WARN);
    }

    /// Is the logger instance enabled for the ERROR level?
    bool isErrorEnabled()
    {
        return enabled(Level.ERROR);
    }

    /// Similar to `isErrorEnabled()`; markers do not change the decision.
    bool isErrorEnabled(Marker)
    {
        return enabled(Level.ERROR);
    }

    /// Log a complete event built by the fluent API.
    void log(LoggingEvent event)
    {
        if (enabled(event.getLevel()))
            factory.currentAppender()(event);
    }

    /// The fully qualified class name of the caller boundary: none.
    protected override string getFullyQualifiedCallerName()
    {
        return null;
    }

    /// Build the event, copying the borrowed arguments, and hand it to the appender.
    protected override void handleNormalizedLoggingCall(Level level, Marker marker,
            string messagePattern, scope Any[] arguments, Throwable throwable)
    {
        auto event = new DefaultLoggingEvent(level, name);
        event.setMessage(messagePattern);
        event.addArguments(arguments);
        event.setThrowable(throwable);
        if (marker !is null)
            event.addMarker(marker);
        foreach (key, value; factory.mdc.snapshot())
            event.addKeyValue("mdc." ~ key, Any.of(value));
        factory.currentAppender()(event);
    }
}

/// The default appender: each event becomes one `flint.log` record.
struct FlintLogAppender
{
    private static shared ProcessSlot!EngineLogger engine;

    /// Drain and close the `flint.log` logger, if one was opened. Runs at process exit, before druntime stops
    /// threads, so the logger's consumer thread is never left running; later events are dropped.
    static void shutdown()
    {
        if (auto target = engine.get())
            target.close();
    }

    /// Write `event` through the process's `flint.log` logger: the formatted message, the logger name, the
    /// event's key-value pairs (MDC entries arrive as `mdc.<key>`) and the throwable as Java prints it.
    static void append(LoggingEvent event)
    {
        import flint.java.lang : javaToString;
        import flint.log : Field;
        import flint.slf4j.event : toInt;

        auto target = engine.get();
        if (target is null)
            target = engine.setIfAbsent(new EngineLogger());
        Field[] fields = [Field("logger", event.getLoggerName())];
        foreach (kvp; event.getKeyValuePairs())
            fields ~= Field(kvp.key, MessageFormatter.render(kvp.value));
        if (auto t = event.getThrowable())
            fields ~= Field("exception", javaToString(t));
        const message = MessageFormatter.basicArrayFormat(event.getMessage(), event.getArgumentArray());
        target.write(event.getLevel(), message is null ? "null" : message, fields);
    }
}

// The process's flint.log logger, opened on first use with console output.
private final class EngineLogger
{
    import flint.arena : Result;
    import flint.log : Field, Format, LogLevel = Level, LogOptions, FlintLog = Logger;

    private FlintLog logger;
    private bool open;

    this()
    {
        LogOptions options;
        options.level = LogLevel.trace;
        options.format = Format.console;
        auto created = FlintLog.create(options);
        adopt(created);
    }

    private void adopt(ref Result!FlintLog created)
    {
        open = created.ok;
        if (open)
            logger = created.value;
    }

    void close()
    {
        synchronized (this)
        {
            if (!open)
                return;
            open = false;
            logger.flush();
            logger.close();
        }
    }

    void write(Level level, string message, scope const(Field)[] fields)
    {
        if (!open)
            return;
        static immutable LogLevel[5] map = [
            LogLevel.trace, LogLevel.debug_, LogLevel.info, LogLevel.warn, LogLevel.error
        ];
        logger.write(map[cast(int) level / 10], message, fields);
    }
}

// The flint.log consumer thread must stop before druntime terminates (it faults if it is still parked).
shared static ~this()
{
    FlintLogAppender.shutdown();
}

// A fiber's MDC: copy-on-write, so events keep a stable snapshot.
private final class MdcContext
{
    string[string] values;
    string[][string] deques;
}

private shared FiberLocal!MdcContext mdcLocal;

/**
 * The MDC adapter: each reactor fiber (Spring's virtual thread) has its own
 * context, as each Java thread has its own; off a fiber the context belongs
 * to the thread. Updates replace the context, so snapshots never change.
 */
final class FiberMDCAdapter : MDCAdapter
{
    private static MdcContext current()
    {
        return mdcLocal.get();
    }

    private static void replace(MdcContext next)
    {
        import flint.java.lang : IllegalStateException;

        const error = mdcLocal.set(next);
        if (error.code)
            throw new IllegalStateException("MDC: " ~ error.message);
    }

    private static MdcContext copy()
    {
        auto next = new MdcContext();
        if (auto now = current())
        {
            foreach (k, v; now.values)
                next.values[k] = v;
            foreach (k, v; now.deques)
                next.deques[k] = v.dup;
        }
        return next;
    }

    /// The current context's entries; the returned map is never modified afterwards.
    const(string[string]) snapshot()
    {
        const now = current();
        return now is null ? null : now.values;
    }

    /// Put a context value as identified with the `key` parameter into the current fiber's context map.
    void put(string key, string val)
    {
        auto next = copy();
        next.values[key] = val;
        replace(next);
    }

    /// Get the context identified by the `key` parameter.
    string get(string key)
    {
        const now = current();
        if (now is null)
            return null;
        if (auto found = key in now.values)
            return *found;
        return null;
    }

    /// Remove the context identified by the `key` parameter.
    void remove(string key)
    {
        const now = current();
        if (now is null || (key in now.values) is null)
            return;
        auto next = copy();
        next.values.remove(key);
        replace(next);
    }

    /// Clear all entries in the MDC.
    void clear()
    {
        mdcLocal.remove();
    }

    /// Return a copy of the current fiber's context map, or null when it is empty.
    Map!(string, string) getCopyOfContextMap()
    {
        const now = current();
        if (now is null || now.values.length == 0)
            return null;
        return new HashMap!(string, string)(now.values.dup);
    }

    /// Set the current fiber's context map by first clearing any existing map and then copying `contextMap`.
    void setContextMap(Map!(string, string) contextMap)
    {
        auto next = new MdcContext();
        if (contextMap !is null)
            contextMap.forEach((string k, string v) { next.values[k] = v; });
        replace(next);
    }

    /// Push a value into the deque(stack) referenced by `key`.
    void pushByKey(string key, string value)
    {
        auto next = copy();
        next.deques[key] ~= value;
        replace(next);
    }

    /// Pop the stack referenced by `key` and return the value possibly null.
    string popByKey(string key)
    {
        const now = current();
        if (now is null)
            return null;
        const stack = key in now.deques;
        if (stack is null || stack.length == 0)
            return null;
        immutable top = (*stack)[$ - 1];
        auto next = copy();
        next.deques[key] = next.deques[key][0 .. $ - 1];
        replace(next);
        return top;
    }

    /// Clear the deque(stack) referenced by `key`.
    void clearDequeByKey(string key)
    {
        auto next = copy();
        next.deques.remove(key);
        replace(next);
    }
}
