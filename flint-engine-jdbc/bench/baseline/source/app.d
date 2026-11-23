/// Control for the flint:engine-jdbc probe: the same program and output without the module (PROBE_CONTRACT.md).
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
    enum sqlite = "/var/data/app.db | select $1 | registered";
    enum postgres = "host='db.example' port='6543' dbname='shop' | select $1 from t where a = $2 | registered";
    emit(args.length > 1 ? postgres : sqlite);
    return 0;
}
