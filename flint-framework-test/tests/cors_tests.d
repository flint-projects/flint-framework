/++
CORS through MockMvc, against the three CORS cases of benchmarks/spring/suites/golden/petclinic-rest.json
(spring-petclinic-rest's `@CrossOrigin(exposedHeaders = "errors, content-type")`), and Spring's
`CrossOriginTests` basics.
+/
module cors_tests;

import flint.http : HttpStatus, ResponseEntity;
import flint.test.web.servlet.request : MockMvcRequestBuilders;
import flint.test.web.servlet.result : MockMvcResultMatchers;
import flint.test.web.servlet.setup : MockMvcBuilders;
import flint.web.bind.annotation : CrossOrigin, GetMapping, PathVariable, PostMapping, RequestMapping, RestController;
import flint.web.servlet.config.annotation : CorsRegistry, WebMvcConfigurer;

@safe:

private alias status = MockMvcResultMatchers.status;
private alias header = MockMvcResultMatchers.header;

/// A slice of spring-petclinic-rest's controllers: class-level `@CrossOrigin` and `@RequestMapping("api")`.
@RestController
@CrossOrigin(exposedHeaders : ["errors, content-type"])
@RequestMapping("api")
class PetclinicLikeController
{
    ///
    @GetMapping("/pettypes/{petTypeId}")
    ResponseEntity getPetType(@PathVariable("petTypeId") int petTypeId)
    {
        return ResponseEntity.ok(petTypeId == 1 ? "dog" : "cat");
    }

    ///
    @GetMapping("/owners")
    ResponseEntity listOwners()
    {
        return ResponseEntity.ok("[]");
    }

    ///
    @PostMapping("/owners")
    ResponseEntity addOwner()
    {
        return ResponseEntity.status(HttpStatus.CREATED.code()).build();
    }
}

@("CORS simple request: Vary, Access-Control-Allow-Origin and the exposed headers")
unittest
{
    auto mockMvc = MockMvcBuilders.standaloneSetup(new PetclinicLikeController()).build();
    auto result = mockMvc.perform(MockMvcRequestBuilders.get("/api/pettypes/2").header("Origin",
            "http://example.com")).andExpect(status().isOk()).andExpect(header().stringValues("Vary",
            "Origin", "Access-Control-Request-Method", "Access-Control-Request-Headers")).andExpect(header()
            .string("Access-Control-Allow-Origin",
                "*")).andExpect(header().string("Access-Control-Expose-Headers", "errors, content-type")).andReturn();
    // CORS headers come before the body headers, as in the golden.
    assert(result.getResponse().getHeaderNames()[0 .. 3] == [
        "Vary", "Access-Control-Allow-Origin", "Access-Control-Expose-Headers"
    ]);
}

@("CORS preflight: the mapped method, headers, max age, and the container's Allow")
unittest
{
    auto mockMvc = MockMvcBuilders.standaloneSetup(new PetclinicLikeController()).build();
    mockMvc.perform(MockMvcRequestBuilders.options("/api/owners").header("Origin", "http://example.com")
            .header("Access-Control-Request-Method", "POST").header("Access-Control-Request-Headers", "content-type"))
        .andExpect(status().isOk()).andExpect(header()
            .stringValues("Vary",
                "Origin", "Access-Control-Request-Method", "Access-Control-Request-Headers")).andExpect(header()
            .string("Access-Control-Allow-Origin",
                "*")).andExpect(header().string("Access-Control-Allow-Methods", "POST")).andExpect(header()
            .string("Access-Control-Allow-Headers", "content-type")).andExpect(header()
            .string("Access-Control-Expose-Headers",
                "errors, content-type")).andExpect(header().string("Access-Control-Max-Age", "1800"))
        .andExpect(header().string("Allow", "GET, HEAD, PATCH, POST, PUT, DELETE, OPTIONS, TRACE"));
}

@("CORS preflight for a method that is not mapped: no CORS headers, only Allow")
unittest
{
    auto mockMvc = MockMvcBuilders.standaloneSetup(new PetclinicLikeController()).build();
    mockMvc.perform(MockMvcRequestBuilders.options("/api/owners").header("Origin",
            "http://example.com").header("Access-Control-Request-Method", "PATCH")).andExpect(status()
            .isOk()).andExpect(header().doesNotExist("Vary")).andExpect(header()
            .doesNotExist("Access-Control-Allow-Origin")).andExpect(header().string("Allow",
            "GET, HEAD, PATCH, POST, PUT, DELETE, OPTIONS, TRACE"));
}

@("Global CORS from WebMvcConfigurer.addCorsMappings, and rejection of a foreign origin")
unittest
{
    @RestController static class Plain
    {
        @GetMapping("/plain")
        string plain() @safe
        {
            return "ok";
        }
    }

    auto config = new class WebMvcConfigurer
    {
        override void addCorsMappings(CorsRegistry registry)
        {
            registry.addMapping("/**").allowedOrigins("https://allowed.example");
        }
    };
    auto mockMvc = MockMvcBuilders.standaloneSetup(new Plain()).addConfigurer(config).build();
    mockMvc.perform(MockMvcRequestBuilders.get("/plain").header("Origin",
            "https://allowed.example")).andExpect(status().isOk()).andExpect(header()
            .string("Access-Control-Allow-Origin", "https://allowed.example"));
    mockMvc.perform(MockMvcRequestBuilders.get("/plain").header("Origin", "https://other.example"))
        .andExpect(status().isForbidden()).andExpect(MockMvcResultMatchers.content().string("Invalid CORS request"));
    // Same-origin requests are not CORS requests.
    mockMvc.perform(MockMvcRequestBuilders.get("/plain").header("Origin", "http://localhost"))
        .andExpect(status().isOk()).andExpect(header().doesNotExist("Access-Control-Allow-Origin"));
}
