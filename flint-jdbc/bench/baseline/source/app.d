/// Control for the flint:jdbc probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "flint.dao.DuplicateKeyException cause" : "flint.jdbc.BadSqlGrammarException cause");
    return 0;
}
