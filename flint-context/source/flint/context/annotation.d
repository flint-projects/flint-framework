// Ported from spring-framework v7.1.0: spring-context/src/main/java/org/springframework/context/annotation
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
 * spring-context/src/main/java/org/springframework/context/annotation/{Configuration,Bean,Profile,Primary,
 * Fallback,Lazy,Scope,ScopedProxyMode,DependsOn,Description,Role,ComponentScan,Import,PropertySource,
 * AnnotationConfigApplicationContext}.java. Annotations are D UDA structs (rulebook R2), merged and acted on by
 * Flint AOT (AOT contract section 2.2); Class-valued attributes are ClassRef.
 */

/++
`org.springframework.context.annotation`: the configuration annotations and `AnnotationConfigApplicationContext`.

The annotation structs import only other annotation modules, so generated code may spell out their merged values.
`AnnotationConfigApplicationContext` loads the bean definitions Flint AOT generated for the application's
configuration classes and components (the installed registry), in place of Spring's runtime class scanning.
+/
module flint.context.annotation;

import flint.context.support : GenericApplicationContext;
import flint.core.annotation : AliasFor, ClassRef, classOf;
import flint.engine.aot.registry : RegistryPopulator;
import flint.stereotype : Component;

@safe:

/++
Indicates that a class declares `@Bean` methods and may be processed by the container to generate bean definitions.
With `proxyBeanMethods` true, Flint AOT generates a `X__FlintConfiguration` subclass so inter-bean method calls
return the container's singletons (contract section 5.3).
+/
@Component
struct Configuration
{
    /// Alias for `Component.value`.
    @AliasFor(null, classOf!Component)
    string value;
    /// Whether `@Bean` methods are proxied to enforce singleton semantics.
    bool proxyBeanMethods = true;
    /// Whether `@Bean` methods must have unique names.
    bool enforceUniqueMethods = true;
}

/// Indicates that a method produces a bean managed by the container.
struct Bean
{
    /// Alias for `name`.
    @AliasFor("name")
    string[] value;
    /// The bean name and aliases; empty for the method name.
    @AliasFor("value")
    string[] name;
    /// Whether this bean is a candidate for autowiring other beans.
    bool autowireCandidate = true;
    /// Whether this bean is a candidate for autowiring by type by default.
    bool defaultCandidate = true;
    /// An initialization method name on the bean.
    string initMethod;
    /// A destruction method name; `(inferred)` finds a public `close` or `shutdown`.
    string destroyMethod = "(inferred)";
}

/// Indicates that a component is eligible for registration when the profile expressions match.
struct Profile
{
    /// The profile expressions (`prod`, `!test`, `prod & cloud`); any matching suffices.
    string[] value;
}

/// The bean is preferred when several candidates qualify for a single-valued dependency.
struct Primary
{
}

/// The bean is a fallback, used only when no other candidate qualifies.
struct Fallback
{
}

/// The bean is initialized on first use instead of at startup.
struct Lazy
{
    /// Whether lazy initialization applies.
    bool value = true;
}

/// Scoped-proxy options for `@Scope`.
enum ScopedProxyMode
{
    /// The default: `NO` unless configured otherwise.
    DEFAULT,
    /// No scoped proxy.
    NO,
    /// An interface-based proxy.
    INTERFACES,
    /// A class-based proxy.
    TARGET_CLASS,
}

/// The scope of a bean: `singleton` (default) or `prototype`.
struct Scope
{
    /// Alias for `scopeName`.
    @AliasFor("scopeName")
    string value;
    /// The scope name.
    @AliasFor("value")
    string scopeName;
    /// Whether a scoped proxy is created.
    ScopedProxyMode proxyMode = ScopedProxyMode.DEFAULT;
}

/// Beans that must be initialized before this one.
struct DependsOn
{
    /// The bean names.
    string[] value;
}

/// A textual description of a bean.
struct Description
{
    /// The description.
    string value;
}

/// The role hint of a bean (`BeanDefinition.ROLE_APPLICATION` by default).
struct Role
{
    /// The role.
    int value;
}

/// Component scanning roots (Flint AOT decides the scanned modules at build time).
struct ComponentScan
{
    /// Alias for `basePackages`.
    @AliasFor("basePackages")
    string[] value;
    /// Base packages (D module prefixes) to scan.
    @AliasFor("value")
    string[] basePackages;
    /// Classes whose modules mark base packages.
    ClassRef[] basePackageClasses;
    /// Whether `@Component` classes are detected.
    bool useDefaultFilters = true;
    /// Whether scanned beans are lazy.
    bool lazyInit;
}

/// Additional component classes to import.
struct Import
{
    /// The classes.
    ClassRef[] value;
}

/// Adds a property source to the environment (resolved at startup).
struct PropertySource
{
    /// The name of the property source; empty for a generated name.
    string name;
    /// The resource locations (`classpath:app.properties`).
    string[] value;
    /// Whether a missing resource is ignored.
    bool ignoreResourceNotFound;
    /// The resource encoding; UTF-8 when empty.
    string encoding;
}

/++
A standalone application context for annotated configuration: the bean definitions Flint AOT generated, loaded at
construction, then refreshed.
+/
class AnnotationConfigApplicationContext : GenericApplicationContext
{
    /// A context over the installed registry, loaded (and its conditions evaluated) during `refresh()`; register
    /// further beans and singletons first.
    this()
    {
        super();
        deferAotRegistry();
    }

    /// A context over `populate` (a generated registry), refreshed: Java's
    /// `new AnnotationConfigApplicationContext(AppConfig.class)`, with the configuration resolved at build time.
    this(RegistryPopulator populate)
    {
        super();
        deferAotRegistry(populate);
        refresh();
    }

    /// Register component classes that have no generated definitions (created with `new T()`), then refresh
    /// separately (Java's `register(Class...)`).
    void register(Classes...)()
    {
        static foreach (T; Classes)
            registerBean!T();
    }

    /// The name `AnnotationBeanNameGenerator` gives a bean registered without one: the simple class name with its
    /// first letter lowered, unless the first two letters are capitals (`URLService`).
    protected override string generateBeanName(string typeName)
    {
        import flint.engine.aot.name : simpleTypeName;

        const simple = simpleTypeName(typeName);
        if (simple.length == 0 || (simple.length >= 2 && isUpper(simple[0]) && isUpper(simple[1])))
            return simple;
        immutable char first = isUpper(simple[0]) ? cast(char)(simple[0] + 32) : simple[0];
        return first ~ simple[1 .. $];
    }

    private static bool isUpper(char c) pure nothrow @nogc
    {
        return c >= 'A' && c <= 'Z';
    }
}
