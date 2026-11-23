/// Control for the flint:context probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "refreshed closed audit inactive" : "refreshed closed recorder inactive");
    return 0;
}
