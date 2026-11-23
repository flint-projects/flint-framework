/// jakarta.servlet.http.Cookie: construction, attributes and their order.
module app;

import flint.jakarta.servlet.http : Cookie;
import std.stdio : writeln;

@safe:

int main(string[] args)
{
    auto cookie = new Cookie(args.length > 1 ? "session" : "visit", "v1");
    cookie.setPath("/");
    cookie.setHttpOnly(true);
    writeln(cookie.getName() ~ "=" ~ cookie.getValue() ~ " " ~ cookie.getPath() ~ (cookie.isHttpOnly() ? " HttpOnly"
            : ""));
    return 0;
}
