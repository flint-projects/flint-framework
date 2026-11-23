/// spring-test's MockMvc: a standalone setup over one controller, one request and its status.
module app;

import flint.test.web.servlet.request : MockMvcRequestBuilders;
import flint.test.web.servlet.setup : MockMvcBuilders;
import flint.web.bind.annotation : GetMapping, RestController;
import std.conv : to;
import std.stdio : writeln;

@safe:

@RestController class PingController
{
    @GetMapping("/ping") string ping()
    {
        return "pong";
    }
}

int main(string[] args)
{
    auto mockMvc = MockMvcBuilders.standaloneSetup(new PingController()).build();
    auto result = mockMvc.perform(MockMvcRequestBuilders.get(args.length > 1 ? "/nope" : "/ping")).andReturn();
    writeln(result.getResponse().getStatus().to!string);
    return 0;
}
