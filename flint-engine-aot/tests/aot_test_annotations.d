/++
Annotation shapes as flint:core and the stereotype module declare them (AOT contract section 2), for testing
the descriptor builder's merging. `flint.core.annotation` here is the test stand-in in tests/flint/core.
+/
module flint.engine.aot_test_annotations;

public import flint.core.annotation : AliasFor, ClassRef, classOf;

@safe:

/// `@Component`.
struct Component
{
    /// The bean name.
    string value;
}

/// `@Service`, a `@Component`.
@Component
struct Service
{
    /// Aliases `Component.value`.
    @AliasFor(null, classOf!Component)
    string value;
}

/// A `@Service` two levels above `@Component`.
@Service
struct Special
{
    /// Aliases `Service.value`.
    @AliasFor("value", classOf!Service)
    string name;
}

/// `@RequestMapping`-shaped: `value` and `path` mirror each other.
struct Mapping
{
    /// Mirrors `path`.
    @AliasFor("path")
    string value;
    /// Mirrors `value`.
    @AliasFor("value")
    string path;
    /// The HTTP method.
    string method = "ANY";
}

/// `@GetMapping`-shaped.
@Mapping(null, null, "GET")
struct GetMapping
{
    /// Aliases `Mapping.value`.
    @AliasFor(null, classOf!Mapping)
    string value;
}
