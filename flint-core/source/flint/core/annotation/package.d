// Ported from spring-framework v7.1.0: spring-core/src/main/java/org/springframework/core/annotation
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
 * spring-core/src/main/java/org/springframework/core/annotation/{AliasFor,Order}.java.
 * Annotations are D UDA structs (rulebook R2); Class-valued attributes are ClassRef (AOT contract section 2).
 */

/++
The annotations of `org.springframework.core.annotation`: `@AliasFor` and `@Order`, plus `ClassRef` and `classOf`
for `Class`-valued annotation attributes (AOT contract section 2).

This is a leaf module (rulebook R2): it imports only `flint.java.lang` (for `ClassRef`, Java's `Class`, shared with
the third-party annotation modules), so generated code and every annotation module may import it. The package's runtime types (`MergedAnnotations`, `AnnotationAwareOrderComparator`, `AnnotationUtils`) are in
`flint.core.annotation.types` (deviation D-21).
+/
module flint.core.annotation;

public import flint.java.lang : ClassRef, classOf;

@safe:

/++
`@AliasFor` declares aliases for annotation attributes.

$(UL
    $(LI Within one annotation, two attributes that name each other are mirrors: setting either sets both.)
    $(LI With `annotation` set, the attribute overrides the named attribute of that meta-annotation, as
        `@Service(value)` overrides `@Component(value)`.)
)
`attribute` and `value` alias each other; `ClassRef.init` for `annotation` means this annotation. Flint AOT and
`flint.engine.aot.descriptor.descriptorOf` apply aliases when they merge annotations (AOT contract section 2.1).
+/
struct AliasFor
{
    /// The name of the attribute this one aliases.
    string attribute;
    /// The annotation declaring the aliased attribute; `ClassRef.init` for this annotation.
    ClassRef annotation;
    /// Alias for `attribute`.
    string value;
}

/++
`@Order` defines the sort order of a component: lower values have higher priority. The default is
`Ordered.LOWEST_PRECEDENCE` (`int.max`). Ordering affects injection of collections and the order of listeners and
callbacks; it does not affect singleton startup order.
+/
struct Order
{
    /// The order value; `Ordered.LOWEST_PRECEDENCE` (`int.max`) by default.
    int value = int.max;
}
