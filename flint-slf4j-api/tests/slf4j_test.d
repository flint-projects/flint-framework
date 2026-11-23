/// Logger behaviour through the default provider: levels by name, lazy boxing, the trailing throwable, MDC in
/// events, markers, the fluent API and provider installation.
module slf4j_test;

import flint.slf4j : Logger, LoggerFactory, MDC, MarkerFactory;
import flint.slf4j.event : Level, LoggingEvent;
import flint.slf4j.helpers : MessageFormatter;
import flint.slf4j.provider : FlintLogServiceProvider;

@safe:

private final class Captured
{
    LoggingEvent[] events;

    string last()
    {
        auto e = events[$ - 1];
        return MessageFormatter.basicArrayFormat(e.getMessage(), e.getArgumentArray());
    }
}

private Captured capture()
{
    auto provider = cast(FlintLogServiceProvider) LoggerFactory.getProvider();
    assert(provider !is null, "the default provider is bound until one is installed");
    auto captured = new Captured();
    provider.loggers().setAppender((LoggingEvent event) { captured.events ~= event; });
    return captured;
}

private final class Expensive
{
    static int renders;

    override string toString() const
    {
        ++renders;
        return "expensive";
    }
}

@("Logger: {} placeholders, levels by logger name and the root level INFO")
unittest
{
    auto captured = capture();
    auto log = LoggerFactory.getLogger("org.example.petclinic.OwnerController");
    log.info("Found owner {} with {} pets", "George", 2);
    assert(captured.last() == "Found owner George with 2 pets");
    assert(captured.events[$ - 1].getLevel() == Level.INFO);
    assert(captured.events[$ - 1].getLoggerName() == "org.example.petclinic.OwnerController");
    immutable before = captured.events.length;
    log.debug_("not at INFO {}", 1);
    assert(captured.events.length == before && !log.isDebugEnabled());

    auto provider = cast(FlintLogServiceProvider) LoggerFactory.getProvider();
    provider.loggers().setLevel("org.example", Level.DEBUG);
    assert(log.isDebugEnabled() && !log.isTraceEnabled());
    log.debug_("now {}", "visible");
    assert(captured.last() == "now visible");
    assert(!LoggerFactory.getLogger("org.other.Thing").isDebugEnabled());
    provider.loggers().setLevel("org.example", Level.INFO);
}

@("Logger: a disabled level boxes and renders nothing")
unittest
{
    auto captured = capture();
    auto log = LoggerFactory.getLogger("lazy.Logger");
    Expensive.renders = 0;
    log.trace("value {}", new Expensive());
    assert(Expensive.renders == 0);
    log.info("value {}", new Expensive());
    assert(captured.last() == "value expensive" && Expensive.renders == 1);
}

@("Logger: a trailing Throwable argument becomes the event's throwable")
unittest
{
    auto captured = capture();
    auto log = LoggerFactory.getLogger("errors");
    auto failure = new Exception("database down");
    log.error("Could not load owner {}", 7, failure);
    assert(captured.last() == "Could not load owner 7");
    assert(captured.events[$ - 1].getThrowable() is failure);
    log.warn("plain", failure);
    assert(captured.events[$ - 1].getThrowable() is failure && captured.last() == "plain");
}

@("Logger: the caller's MDC entries travel with the event")
unittest
{
    auto captured = capture();
    MDC.put("requestId", "r-42");
    scope (exit)
        MDC.clear();
    LoggerFactory.getLogger("mdc").info("handled");
    auto pairs = captured.events[$ - 1].getKeyValuePairs();
    assert(pairs.length == 1 && pairs[0].key == "mdc.requestId" && pairs[0].toString() == "mdc.requestId=r-42");
    assert(MDC.get("requestId") == "r-42");
    MDC.remove("requestId");
    assert(MDC.get("requestId") is null);
}

@("Logger: markers reach the event, and the fluent API builds events")
unittest
{
    auto captured = capture();
    auto log = LoggerFactory.getLogger("fluent");
    auto audit = MarkerFactory.getMarker("AUDIT");
    log.info(audit, "owner {} renamed", 3);
    assert(captured.events[$ - 1].getMarkers()[0] is audit && captured.last() == "owner 3 renamed");

    log.atInfo().addKeyValue("owner", 3).addArgument("Betty").log("renamed to {}");
    assert(captured.last() == "renamed to Betty");
    assert(captured.events[$ - 1].getKeyValuePairs()[0].toString() == "owner=3");
    immutable before = captured.events.length;
    log.atDebug().addArgument("x").log("disabled {}");
    assert(captured.events.length == before);
}

@("LoggerFactory.getLogger!T names the logger after the D type, as getLogger(Class) does")
unittest
{
    static final class OwnerService
    {
    }

    auto log = LoggerFactory.getLogger!OwnerService();
    import std.algorithm.searching : endsWith;

    assert(log.getName().endsWith("OwnerService"));
    assert(LoggerFactory.getLogger(log.getName()) is log, "loggers are cached by name");
}
