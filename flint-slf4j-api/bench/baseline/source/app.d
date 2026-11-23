/// Control for the flint:slf4j-api probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "Found owner Jean with 2 pets" : "Found owner George with 2 pets");
    return 0;
}
