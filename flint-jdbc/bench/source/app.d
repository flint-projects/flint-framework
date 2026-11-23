/// spring-jdbc's SQL state translation: an SQLException becomes the matching DataAccessException.
module app;

import flint.java.sql : SQLException;
import flint.jdbc.support : SQLStateSQLExceptionTranslator;
import std.stdio : writeln;

@safe:

int main(string[] args)
{
    auto cause = new SQLException("reason", args.length > 1 ? "23505" : "42000", 0);
    auto translated = new SQLStateSQLExceptionTranslator().translate("task", "SELECT 1", cause);
    writeln(typeid(translated).name ~ (translated.getCause() is cause ? " cause" : " lost"));
    return 0;
}
