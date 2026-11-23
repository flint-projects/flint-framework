/// Control for the flint:jakarta-annotation probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "jdbc/petclinic" : "jdbc/petclinic 7 1");
    return 0;
}
