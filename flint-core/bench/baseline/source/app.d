/// Control for the flint:core probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "bad column x root" : "bad column root");
    return 0;
}
