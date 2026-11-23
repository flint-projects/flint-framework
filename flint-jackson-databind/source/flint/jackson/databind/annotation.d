/*
 * Ported from Jackson Databind 3.1.8, https://github.com/FasterXML/jackson-databind,
 * tag jackson-databind-3.1.8: src/main/java/tools/jackson/databind/annotation/JsonNaming.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D (rulebook v2): the annotation is a UDA
 * struct and its Class<?> element a ClassRef (R4).
 */

/// Databind-level annotations: `@JsonNaming`.
module flint.jackson.databind.annotation;

import flint.java.lang : ClassRef;

@safe:

/**
 * Annotation that can be used to indicate a `PropertyNamingStrategy` to use for annotated class. Overrides the
 * global (default) strategy. `@JsonNaming(classOf!(PropertyNamingStrategies.SnakeCaseStrategy))`.
 *
 * Flint instantiates the standard strategies of `PropertyNamingStrategies`; other classes have no binding yet.
 */
struct JsonNaming
{
    /// The strategy class.
    ClassRef value;
}
