/// Control for the flint:jackson-annotations probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "owner_id" : "owner_id id 1");
    return 0;
}
