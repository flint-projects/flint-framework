/// The default appender writes through flint.log, and the process exits cleanly afterwards: the engine logger is
/// closed before druntime terminates, so its consumer thread is not left running.
module zz_default_appender_test;

import flint.slf4j : LoggerFactory;
import flint.slf4j.provider : FlintLogServiceProvider;

@("the default appender logs through flint.log and is closed at exit")
unittest
{
    auto provider = cast(FlintLogServiceProvider) LoggerFactory.getProvider();
    provider.loggers().setAppender(null);
    LoggerFactory.getLogger("exit.Check").error("one record through the flint.log engine: {}", 1);
}
