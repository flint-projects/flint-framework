/*
 * Ported from Jackson Databind 3.1.8, https://github.com/FasterXML/jackson-databind,
 * tag jackson-databind-3.1.8: src/main/java/tools/jackson/databind/module/SimpleModule.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D (rulebook v2); `module` is a D keyword, so the package is
 * `module_`. SimpleModule's serializer and deserializer registries are not ported yet (Flint has no
 * ValueSerializer/ValueDeserializer types), so it carries a name and dependencies only. JavaUtilDateModule is
 * Flint's: it holds the java.util.Date reading and @JsonFormat pattern formatting that Jackson builds in, so that
 * only applications that use them link them (deviation D-JACKSON-10).
 */

/// Jackson's `SimpleModule`, and Flint's `JavaUtilDateModule`.
module flint.jackson.databind.module_;

import flint.jackson.databind : JacksonModule, ModuleContext;

@safe:

/// Jackson's `SimpleModule`: a module identified by its name.
class SimpleModule : JacksonModule
{
    /// The module name.
    protected string _name;

    /// A module named "SimpleModule-" and its identity.
    this()
    {
        import flint.engine.aot.text : decimal;

        _name = "SimpleModule-" ~ decimal(cast(long) toHash());
    }

    /// A module named `name`.
    this(string name) pure nothrow @nogc
    {
        _name = name;
    }

    override string getModuleName()
    {
        return _name;
    }

    /// Nothing to configure until the serializer and deserializer registries are ported.
    override void setupModule(SetupContext context)
    {
    }
}

/++
Flint: `java.util.Date` reading (ISO-8601, RFC 1123, timestamps, `@JsonFormat` patterns, zones and leniency) and
`@JsonFormat` pattern writing, which Jackson builds into every mapper. Plain writes (ISO-8601 text, timestamps,
map keys) need no module.

Flint registers it for you: the generated Jackson configuration adds it when the application's types hold a
`Date`, and `ObjectMapper`'s templated methods (`readValue!T`, `convertValue!T`, `writeValueAsString!T`...) when their
type does. Register it yourself only for a mapper used through the erased methods over descriptors you add by hand.
+/
final class JavaUtilDateModule : JacksonModule
{
    override string getModuleName()
    {
        return "JavaUtilDateModule";
    }

    override void setupModule(SetupContext context)
    {
        import flint.jackson.databind.stddateformat : installJavaUtilDate;

        if (auto c = cast(ModuleContext) context)
            installJavaUtilDate(c.config);
    }
}
