/// SLF4J through Flint's default provider: a logger by name, {} placeholders and the formatted event.
module app;

import flint.slf4j : LoggerFactory;
import flint.slf4j.event : LoggingEvent;
import flint.slf4j.helpers : MessageFormatter;
import flint.slf4j.provider : FlintLogServiceProvider;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

int main(string[] args)
{
    string formatted;
    auto provider = cast(FlintLogServiceProvider) LoggerFactory.getProvider();
    provider.loggers().setAppender((LoggingEvent event) {
        formatted = MessageFormatter.basicArrayFormat(event.getMessage(), event.getArgumentArray());
    });
    auto log = LoggerFactory.getLogger("org.example.petclinic.OwnerController");
    log.info("Found owner {} with {} pets", args.length > 1 ? "Jean" : "George", 2);
    emit(formatted);
    return 0;
}
