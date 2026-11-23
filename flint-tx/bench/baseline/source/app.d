/// Control for the flint:tx probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "Jean 1" : "George 1");
    return 0;
}
