/// Control for the flint:jakarta-servlet probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "session=v1 / HttpOnly" : "visit=v1 / HttpOnly");
    return 0;
}
