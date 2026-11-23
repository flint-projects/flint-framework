/// Control for the flint:hibernate-validator probe: the same program and output without the module (PROBE_CONTRACT.md).
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
    enum blank = "firstName:must not be blank;";
    enum city = "city:size must be between 2 and 30;";
    emit(args.length > 1 ? city : blank ~ city);
    return 0;
}
