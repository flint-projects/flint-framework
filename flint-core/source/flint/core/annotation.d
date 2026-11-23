/++
`org.springframework.core.annotation` as the Flint AOT contract (docs/spring/aot-contract.md section 2) defines it:
`@AliasFor`, and the `ClassRef` form of `Class`-valued annotation attributes, made with `classOf!T`. A leaf module, so
annotation modules and generated code may import it. framework-core owns this module.
+/
module flint.core.annotation;

@safe:

/// A `Class`-valued annotation attribute: the fully qualified D name of the class.
struct ClassRef
{
    /// The fully qualified D name.
    string name;
}

/// `T.class` as an annotation attribute value: `@Transactional(rollbackFor: [classOf!IOException])`.
enum ClassRef classOf(T) = ClassRef(__traits(fullyQualifiedName, T));

/// `@AliasFor`: declares that an annotation attribute aliases another, in this annotation or a meta-annotation.
struct AliasFor
{
    /// The name of the attribute that this attribute is an alias for.
    string attribute;
    /// The meta-annotation that declares the aliased attribute; `ClassRef.init` means this annotation.
    ClassRef annotation;
    /// Alias for `attribute`.
    string value;
}
