/// Control for the flint:jackson-core probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "{\"id\":2,\"name\":\"Leo\",\"visits\":[\"2013-01-01\"]}"
            : "{\"id\":1,\"name\":\"Leo\",\"visits\":[\"2013-01-01\"]}");
    return 0;
}
