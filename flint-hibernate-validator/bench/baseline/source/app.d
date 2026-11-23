/// Control for the flint:hibernate-validator probe: the same program and output without the module (PROBE_CONTRACT.md).
module app;

import std.stdio : writeln;

@safe:

int main(string[] args)
{
    enum blank = "firstName:must not be blank;";
    enum city = "city:size must be between 2 and 30;";
    writeln(args.length > 1 ? city : blank ~ city);
    return 0;
}
