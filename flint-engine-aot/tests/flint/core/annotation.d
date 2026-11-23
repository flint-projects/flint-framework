/++
Test stand-in for flint:core's leaf module `flint.core.annotation`: the `@AliasFor` and `ClassRef` shapes of AOT
contract section 2, so flint:engine-aot tests its merging without depending on a higher package. It is compiled
only into engine-aot's unittest configuration.
+/
module flint.core.annotation;

@safe:

/// A `Class`-valued annotation attribute: the fully qualified D name.
struct ClassRef
{
    /// The fully qualified D name.
    string name;
}

/// `T.class` for annotation attributes.
enum ClassRef classOf(T) = ClassRef(__traits(fullyQualifiedName, T));

/// `@AliasFor`.
struct AliasFor
{
    /// The aliased attribute.
    string attribute;
    /// The meta-annotation declaring it; `ClassRef.init` for this annotation.
    ClassRef annotation;
    /// Alias of `attribute`.
    string value;
}
