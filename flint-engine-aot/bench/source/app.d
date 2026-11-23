/// Flint AOT's runtime contract: canonical type names and the @ConditionalOnProperty match.
module app;

import flint.engine.aot.condition : propertyMatches;
import flint.engine.aot.name : canonicalTypeName, simpleTypeName, typeNameOf;
import std.stdio : writeln;

@safe:

private struct Owner
{
}

int main(string[] args)
{
    const name = canonicalTypeName(args.length > 1 ? "app.Owner[]" : typeNameOf!Owner);
    const matches = propertyMatches(true, args.length > 1 ? "TRUE" : "false", "true", false);
    writeln(name ~ " " ~ simpleTypeName(name) ~ (matches ? " matches" : " differs"));
    return 0;
}
