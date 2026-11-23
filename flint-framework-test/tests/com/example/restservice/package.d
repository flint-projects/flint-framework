/++
spring-guides/gs-rest-service `complete/` (commit e15fec6, the reference pinned in benchmarks/spring/apps.json):
`Greeting.java` and `GreetingController.java`, written in Flint under the rulebook.
Copyright the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: Java → D syntax only (record → struct, R11; annotations, R2).
+/
module com.example.restservice;

import flint.java.util.concurrent.atomic : AtomicLong;
import flint.web.bind.annotation : GetMapping, RequestParam, RestController;
import std.format : format;

@safe:

/// `public record Greeting(long id, String content) { }`
struct Greeting
{
    long id; ///
    string content; ///
}

/// The guide's controller.
@RestController class GreetingController
{
    private enum string template_ = "Hello, %s!";
    private AtomicLong counter;

    ///
    this()
    {
        counter = new AtomicLong();
    }

    ///
    @GetMapping("/greeting") Greeting greeting(@RequestParam(value : "name", defaultValue:
            "World") string name)
    {
        return Greeting(counter.incrementAndGet(), format(template_, name));
    }
}
