/// Flint's JDBC driver: URL parsing to engine settings, ? parameter numbering and DriverManager registration.
module app;

import flint.engine.jdbc : FlintDriver, numberParameters, parseUrl;
import flint.java.sql : DriverManager;
import std.stdio : writeln;

@safe:

int main(string[] args)
{
    const url = args.length > 1 ? "jdbc:postgresql://db.example:6543/shop" : "jdbc:sqlite:/var/data/app.db";
    const settings = parseUrl(url, null);
    size_t count;
    const sql = numberParameters(args.length > 1 ? "select ? from t where a = ?" : "select ?", count);
    const registered = DriverManager.getDriver(url) !is null && new FlintDriver().acceptsURL(url);
    writeln(settings.connectionString ~ " | " ~ sql ~ (registered ? " | registered" : " | missing"));
    return 0;
}
