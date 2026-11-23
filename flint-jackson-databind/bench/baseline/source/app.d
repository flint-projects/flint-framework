/// Control for the flint:jackson-databind probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "{\"id\":2,\"content\":\"Hello, World!\"}" : "{\"id\":1,\"content\":\"Hello, World!\"}");
    return 0;
}
