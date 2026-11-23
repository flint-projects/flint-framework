// Ported from spring-framework v7.1.0: spring-context/src/main/java/org/springframework/validation/annotation/Validated.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.

/++
`org.springframework.validation.annotation`: the `@Validated` marker.

`@Validated` is a Spring variant of Jakarta's `@Valid` that names validation groups. Flint AOT recognizes it on
handler parameters (`flint.validation.annotation.Validated`) and on beans whose methods are validated.
+/
module flint.validation.annotation;

import flint.java.lang : ClassRef;

@safe:

/// Validate the annotated parameter, field or bean, optionally with validation groups (Java's `Class<?>[] value`).
struct Validated
{
    /// The validation groups (`classOf!Group`); empty for the default group.
    ClassRef[] value;
}
