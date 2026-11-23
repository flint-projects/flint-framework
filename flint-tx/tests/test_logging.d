module flint.transaction.test_logging;

import flint.slf4j : LoggerFactory;
import flint.slf4j.event : LoggingEvent;
import flint.slf4j.provider : FlintLogLoggerFactory;

@safe:

// The tests log through flint.slf4j. Its default appender starts a flint.log consumer thread that outlives
// druntime at process exit, so the suite records events here instead.
private shared size_t loggedEvents;

shared static this()
{
    auto factory = cast(FlintLogLoggerFactory) LoggerFactory.getILoggerFactory();
    if (factory !is null)
        factory.setAppender((LoggingEvent) {
            import core.atomic : atomicOp;

            atomicOp!"+="(loggedEvents, 1);
        });
}
