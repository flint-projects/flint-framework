/// Flint AOT's runtime contract: canonical type names and the @ConditionalOnProperty match.
module app;

import flint.engine.aot.condition : propertyMatches;
import flint.engine.aot.name : canonicalTypeName, simpleTypeName, typeNameOf;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

private struct Owner
{
}

int main(string[] args)
{
    const name = canonicalTypeName(args.length > 1 ? "app.Owner[]" : typeNameOf!Owner);
    const matches = propertyMatches(true, args.length > 1 ? "TRUE" : "false", "true", false);
    emit(name ~ " " ~ simpleTypeName(name) ~ (matches ? " matches" : " differs"));
    return 0;
}
