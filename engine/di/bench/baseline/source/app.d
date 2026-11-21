/// Manual construction control with the same dependencies and observations.
module app;

import di_probe_harness : Counter, Reader, Settings, checkArena, initializeWorker, invoke, measure;

@safe:

private ulong startup(uint count, uint input) nothrow @nogc
{
    Settings settings = Settings(input);
    uint result = settings.nonce;
    foreach (ordinal; 1 .. count)
        result = initializeWorker(settings, ordinal);
    return result + settings.initialized;
}

/// Run the fixed startup shapes and typed/virtual operation without DI.
int main()
{
    enum uint configured = 731;
    if (!checkArena() || !measure("startup-1", 0, true, (input) => startup(1, input))
            || !measure("startup-16", 135, true, (input) => startup(16, input)) || !measure("startup-64",
                2079, true, (input) => startup(64, input)) || !measure("startup-128", 8255, true,
                (input) => startup(128, input)))
        return 1;

    auto counter = new Counter;
    counter.value = configured;
    Reader reader = counter;
    return measure("direct-get", configured, false, (input) => counter.value + input)
        && measure("interface-invoke", configured, false, (input) => invoke(reader, input)) ? 0 : 1;
}
