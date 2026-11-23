/// spring-test's MockMvc: a standalone setup over one controller, one request and its status.
module app;

import flint.test.web.servlet.request : MockMvcRequestBuilders;
import flint.test.web.servlet.setup : MockMvcBuilders;
import flint.web.bind.annotation : GetMapping, RestController;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

/// Decimal text of a small non-negative number, without std.conv.
private string digits(long value) pure nothrow
{
    if (value < 0)
        return "-" ~ digits(-value);
    return value < 10 ? [cast(char)('0' + value)] : digits(value / 10) ~ cast(char)('0' + value % 10);
}

/// The probe's controller.
@RestController
class PingController
{
    /// `GET /ping`.
    @GetMapping("/ping")
    string ping()
    {
        return "pong";
    }
}

int main(string[] args)
{
    auto mockMvc = MockMvcBuilders.standaloneSetup(new PingController()).build();
    auto result = mockMvc.perform(MockMvcRequestBuilders.get(args.length > 1 ? "/nope" : "/ping")).andReturn();
    emit(digits(result.getResponse().getStatus()));
    return 0;
}
