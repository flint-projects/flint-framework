/++
Java's standard types, as Spring's public APIs expose them (rulebook v2, "Namespaces").

`java.X` becomes `flint.java.X`:
$(UL
    $(LI `flint.java.lang`: the exception hierarchy (R8), `Runnable`, `Comparable`, `Iterable`, boxed-number
        parsing and `mixin JavaObject` (R11);)
    $(LI `flint.java.io`: `IOException` and the minimal stream and file types `Resource` returns;)
    $(LI `flint.java.util`: `Optional` (R5), `Collection`, `List`, `Set`, `Map`, `Iterator`, `Comparator`,
        `Objects` and `Collections` (R10);)
    $(LI `flint.java.util.function_`: `Supplier`, `Function`, `Consumer`, `Predicate` and the rest (R9);)
    $(LI `flint.java.util.stream`: `Stream` and `Collectors` (R10).)
)
`java.util.function` is `flint.java.util.function_` because `function` is a D keyword (deviation D-15). This module
declares nothing; import the module that declares what you use, as Java imports a package.
+/
module flint.java;

@safe:
