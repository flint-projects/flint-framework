/// Control for the flint:java probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "Basil! 4 5 5" : "Basil! 3 5 5");
    return 0;
}
