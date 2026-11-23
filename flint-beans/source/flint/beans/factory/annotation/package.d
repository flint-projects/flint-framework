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
 * spring-beans/src/main/java/org/springframework/beans/factory/annotation/{Autowired,Qualifier,Value}.java.
 * Annotations are D UDA structs (rulebook R2). Flint AOT generates the injection AutowiredAnnotationBeanPostProcessor
 * performs reflectively in Spring (AOT contract section 5.2).
 */

/++
The injection annotations of `org.springframework.beans.factory.annotation`: `@Autowired`, `@Qualifier` and
`@Value`. A leaf module (rulebook R2).
+/
module flint.beans.factory.annotation;

@safe:

/++
Marks a constructor, field or setter to be autowired by Flint's dependency injection. With `required` false, a
missing dependency leaves the field unset (or passes null) instead of failing.
+/
struct Autowired
{
    /// Whether the dependency is required.
    bool required = true;
}

/++
Narrows autowiring candidates to the bean with this qualifier value or bean name. Also a meta-annotation for custom
qualifier annotations.
+/
struct Qualifier
{
    /// The qualifier value.
    string value;
}

/++
A default value expression for a field or parameter: typically a `${property:default}` placeholder. `#{...}` SpEL
is compiled by Flint AOT (contract section 9).
+/
struct Value
{
    /// The value expression.
    string value;
}
