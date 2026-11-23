/// spring-jdbc's SQL state translation: an SQLException becomes the matching DataAccessException.
module app;

import flint.java.sql : SQLException;
import flint.jdbc.support : SQLStateSQLExceptionTranslator;
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
    auto cause = new SQLException("reason", args.length > 1 ? "23505" : "42000", 0);
    auto translated = new SQLStateSQLExceptionTranslator().translate("task", "SELECT 1", cause);
    emit(typeid(translated).name ~ (translated.getCause() is cause ? " cause" : " lost"));
    return 0;
}
