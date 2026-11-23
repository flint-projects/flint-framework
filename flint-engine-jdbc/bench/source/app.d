/// Flint's JDBC driver: URL parsing to engine settings, ? parameter numbering and DriverManager registration.
module app;

import flint.engine.jdbc : FlintDriver, numberParameters, parseUrl;
import flint.java.sql : DriverManager;
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
    const url = args.length > 1 ? "jdbc:postgresql://db.example:6543/shop" : "jdbc:sqlite:/var/data/app.db";
    const settings = parseUrl(url, null);
    size_t count;
    const sql = numberParameters(args.length > 1 ? "select ? from t where a = ?" : "select ?", count);
    const registered = DriverManager.getDriver(url) !is null && new FlintDriver().acceptsURL(url);
    emit(settings.connectionString ~ " | " ~ sql ~ (registered ? " | registered" : " | missing"));
    return 0;
}
