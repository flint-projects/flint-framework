/// Control for the flint:jakarta-validation probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    writeln(args.length > 1 ? "{jakarta.validation.constraints.NotNull.message} no-provider"
            : "{jakarta.validation.constraints.NotNull.message} 1 no-provider");
    return 0;
}
