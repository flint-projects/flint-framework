/// Control for the flint:slf4j-api probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

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
    emit(args.length > 1 ? "Found owner Jean with 2 pets" : "Found owner George with 2 pets");
    return 0;
}
