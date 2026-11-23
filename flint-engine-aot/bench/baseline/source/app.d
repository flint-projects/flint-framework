/// Control for the flint:engine-aot probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "app.Owner[] Owner[] matches" : "app.Owner Owner differs");
    return 0;
}
