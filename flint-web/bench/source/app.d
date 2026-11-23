/// spring-web: MediaType parsing of an Accept value, and HttpStatus.
module app;

import flint.http : HttpStatus, MediaType;
import std.stdio : writeln;

@safe:

int main(string[] args)
{
    auto types = MediaType.parseMediaTypes(args.length > 1 ? "text/html;q=0.5, application/json" : "application/json");
    writeln(types[$ - 1].toString() ~ " " ~ HttpStatus.NOT_FOUND.getReasonPhrase());
    return 0;
}
