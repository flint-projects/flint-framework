/// jakarta.servlet.http.Cookie: construction, attributes and their order.
module app;

import flint.jakarta.servlet.http : Cookie;
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
    auto cookie = new Cookie(args.length > 1 ? "session" : "visit", "v1");
    cookie.setPath("/");
    cookie.setHttpOnly(true);
    emit(cookie.getName() ~ "=" ~ cookie.getValue() ~ " " ~ cookie.getPath() ~ (cookie.isHttpOnly() ? " HttpOnly" : ""));
    return 0;
}
