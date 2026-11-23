/// spring-web: MediaType parsing of an Accept value, and HttpStatus.
module app;

import flint.http : HttpStatus, MediaType;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

int main(string[] args)
{
    auto types = MediaType.parseMediaTypes(args.length > 1 ? "text/html;q=0.5, application/json" : "application/json");
    emit(types[$ - 1].toString() ~ " " ~ HttpStatus.NOT_FOUND.getReasonPhrase());
    return 0;
}
