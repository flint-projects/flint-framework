/++
spring-guides/gs-rest-service `complete/src/test/java/com/example/restservice/GreetingControllerTests.java`, ported
(2 of 2 tests), plus MockMvc checks of the behaviours benchmarks/spring/suites/golden/gs-rest-service.json pins.

The upstream test uses `@SpringBootTest` with `@AutoConfigureMockMvc`; until Boot's test support lands (flint-boot)
it builds the same `MockMvc` with `MockMvcBuilders.standaloneSetup`, which is what `@AutoConfigureMockMvc` wires for
a single controller. MockMvc has no servlet container, so error bodies (rendered by Boot's error controller after
`sendError`) are checked over real HTTP, not here; the status, `Allow` and `Accept` headers are checked here.
Copyright the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors.
+/
module gs_rest_service_tests;

import com.example.restservice : GreetingController;
import flint.http : MediaType;
import flint.test.web.servlet.request : MockMvcRequestBuilders;
import flint.test.web.servlet.result : MockMvcResultHandlers, MockMvcResultMatchers;
import flint.test.web.servlet.setup : MockMvcBuilders;

@safe:

private alias get = MockMvcRequestBuilders.get;
private alias status = MockMvcResultMatchers.status;
private alias jsonPath = MockMvcResultMatchers.jsonPath;
private alias content = MockMvcResultMatchers.content;
private alias header = MockMvcResultMatchers.header;

@("GreetingControllerTests.noParamGreetingShouldReturnDefaultMessage")
unittest
{
    auto mockMvc = MockMvcBuilders.standaloneSetup(new GreetingController()).build();
    auto printer = MockMvcResultHandlers.log();
    mockMvc.perform(get("/greeting")).andDo(printer).andExpect(status().isOk())
        .andExpect(jsonPath("$.content").value("Hello, World!"));
    assert(printer.getText().length != 0);
}

@("GreetingControllerTests.paramGreetingShouldReturnTailoredMessage")
unittest
{
    auto mockMvc = MockMvcBuilders.standaloneSetup(new GreetingController()).build();
    mockMvc.perform(get("/greeting").param("name", "Spring Community"))
        .andDo(MockMvcResultHandlers.log()).andExpect(status().isOk())
        .andExpect(jsonPath("$.content").value("Hello, Spring Community!"));
}

@("gs-rest-service golden behaviours through MockMvc")
unittest
{
    auto mockMvc = MockMvcBuilders.standaloneSetup(new GreetingController()).build();

    // default name: body bytes, content type and the record's property order
    mockMvc.perform(get("/greeting")).andExpect(status().isOk()).andExpect(content()
            .contentType(MediaType.APPLICATION_JSON)).andExpect(content().string(`{"id":1,"content":"Hello, World!"}`));
    // name parameter from the query string
    mockMvc.perform(get("/greeting?name=User")).andExpect(jsonPath("$.id").value(2L))
        .andExpect(jsonPath("$.content").value("Hello, User!"));
    // percent-encoded UTF-8 (R14)
    mockMvc.perform(get("/greeting?name=%C3%A9t%C3%A9")).andExpect(jsonPath("$.content").value("Hello, été!"));
    // '+' is not a space in a URI query; %20 is
    mockMvc.perform(get("/greeting?name=Jane+Q%20Public")).andExpect(jsonPath("$.content")
            .value("Hello, Jane+Q Public!"));
    // empty name takes the default
    mockMvc.perform(get("/greeting?name=")).andExpect(jsonPath("$.content").value("Hello, World!"));
    // repeated name joins with a comma
    mockMvc.perform(get("/greeting?name=a&name=b")).andExpect(jsonPath("$.content").value("Hello, a,b!"));
    // JSON escaping as Jackson writes it
    mockMvc.perform(get("/greeting?name=%22quoted%22%5Cslash%3C%3E")).andExpect(content()
            .string(`{"id":7,"content":"Hello, \"quoted\"\\slash<>!"}`));
    // unknown parameter is ignored
    mockMvc.perform(get("/greeting?other=1")).andExpect(jsonPath("$.id").value(8));
    // Accept application/json
    mockMvc.perform(get("/greeting").accept(MediaType.APPLICATION_JSON)).andExpect(status().isOk())
        .andExpect(jsonPath("$.id").value(9));
    // Accept application/xml: the handler runs (counter 10), then 406 with Spring's Accept header
    mockMvc.perform(get("/greeting").accept("application/xml")).andExpect(status()
            .isNotAcceptable()).andExpect(header().string("Accept", "application/json, application/*+json"));
    // HEAD reaches the handler (counter 11)
    mockMvc.perform(MockMvcRequestBuilders.head("/greeting")).andExpect(status().isOk())
        .andExpect(jsonPath("$.id").value(11));
    // OPTIONS lists the allowed methods
    mockMvc.perform(MockMvcRequestBuilders.options("/greeting")).andExpect(status().isOk())
        .andExpect(header().string("Allow", "GET,HEAD,OPTIONS")).andExpect(header()
            .string("Accept-Patch", "")).andExpect(header().string("Accept-Query", ""));
    // POST and DELETE are not allowed
    mockMvc.perform(MockMvcRequestBuilders.post("/greeting")).andExpect(status()
            .isMethodNotAllowed()).andExpect(header().string("Allow", "GET"));
    mockMvc.perform(MockMvcRequestBuilders.delete_("/greeting")).andExpect(status()
            .isMethodNotAllowed()).andExpect(status().reason("Method 'DELETE' is not supported."));
    // unknown path and trailing slash are 404 (NoResourceFoundException)
    mockMvc.perform(get("/nope")).andExpect(status().isNotFound()).andExpect(status()
            .reason("No static resource nope."));
    mockMvc.perform(get("/greeting/")).andExpect(status().isNotFound());
    // the counter after the errors: 12, as in the golden run
    mockMvc.perform(get("/greeting?name=again")).andExpect(jsonPath("$.id").value(12))
        .andExpect(jsonPath("$.content").value("Hello, again!"));
}

@("MockMvc reports failed expectations with Spring's messages")
unittest
{
    import flint.java.lang : AssertionError;

    auto mockMvc = MockMvcBuilders.standaloneSetup(new GreetingController()).build();
    string message;
    try
        mockMvc.perform(get("/nope")).andExpect(status().isOk());
    catch (AssertionError e)
        message = e.getMessage();
    assert(message == "Status expected:<200> but was:<404>", message);
    try
        mockMvc.perform(get("/greeting")).andExpect(jsonPath("$.content").value("Hi"));
    catch (AssertionError e)
        message = e.getMessage();
    assert(message == `JSON path "$.content" expected:<Hi> but was:<Hello, World!>`, message);
}
