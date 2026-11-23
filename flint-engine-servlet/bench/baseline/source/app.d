/// Control for the flint:engine-servlet probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln("registered -1");
    return 0;
}
