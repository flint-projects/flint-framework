module migration_embed;

import flint.engine.migrate : embeddedMigration;
import std.digest : LetterCase, toHexString;
import std.stdio : write, writeln;

@safe:

int main()
{
    enum plan = embeddedMigration!("V000001__bootstrap.sql", 1, "bootstrap")();
    writeln(toHexString!(LetterCase.lower)(plan.sha256));
    write(plan.sql);
    return 0;
}
