// Ported from spring-framework v7.1.0: spring-context/src/main/java/org/springframework/stereotype
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/*
 * Copyright 2002-present the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by the Flint authors: ported from spring-framework v7.1.0,
 * spring-context/src/main/java/org/springframework/stereotype/{Component,Service,Repository,Controller,Indexed}.java.
 * Annotations are D UDA structs (rulebook R2); meta-annotations and @AliasFor are merged by Flint AOT.
 */

/++
`org.springframework.stereotype`: the component stereotypes. A leaf module (rulebook R2).

A class carrying `@Component`, or an annotation meta-annotated with it, in a scanned module becomes a bean
(AOT contract section 5.1). The value is the bean name; empty means the decapitalized simple class name.
+/
module flint.stereotype;

import flint.core.annotation : AliasFor, classOf;

@safe:

/// Indicates that the annotated element is a candidate for index-based scanning (no effect in Flint: AOT indexes).
struct Indexed
{
}

/// Indicates that a class is a component: a candidate for auto-detection.
@Indexed
struct Component
{
    /// The suggested bean name; empty for the default name.
    string value;
}

/// A component holding business logic: a specialization of `@Component`.
@Component
struct Service
{
    /// Alias for `Component.value`.
    @AliasFor(null, classOf!Component)
    string value;
}

/// A component encapsulating storage, retrieval and search: a specialization of `@Component`.
@Component
struct Repository
{
    /// Alias for `Component.value`.
    @AliasFor(null, classOf!Component)
    string value;
}

/// A web controller: a specialization of `@Component`.
@Component
struct Controller
{
    /// Alias for `Component.value`.
    @AliasFor(null, classOf!Component)
    string value;
}
