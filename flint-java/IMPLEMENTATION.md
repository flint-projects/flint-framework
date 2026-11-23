# flint:java

Java's standard types as Spring's public APIs expose them (rulebook v2, `flint.java.X`; rules R5, R8–R11). They are
written from the Java SE API specification; no OpenJDK source is used.

| Module | Holds |
| --- | --- |
| `flint.java.lang` | `RuntimeException : Exception` and the unchecked hierarchy (R8) with `getMessage`, `getCause`, `initCause`, and the four-argument constructor whose `writableStackTrace = false` captures no stack trace; `Runnable`, `Iterable`, `Comparable`, `AutoCloseable`; `mixin JavaObject` (R11); `Integer`, `Long`, `Boolean`, `Double` parsing with Java's `NumberFormatException` messages; `String.valueOf`, `String.hashCode` over UTF-16 units |
| `flint.java.io` | `IOException`, `FileNotFoundException`, `UncheckedIOException`, `InputStream`, `ByteArrayInputStream`, `FileInputStream`, `File` |
| `flint.java.util` | `Optional` (R5); `Collection`, `List`, `Set`, `Map`, `Iterator`, `Comparator` with `ArrayList`, `HashSet`, `LinkedHashSet`, `HashMap`, `LinkedHashMap`; the erased `RawCollection` and `RawMap` views; `Objects`, `Collections`, `Arrays` |
| `flint.java.util.function_` | `Supplier`, `Function`, `BiFunction`, `Consumer`, `BiConsumer`, `Predicate`, `BiPredicate`, `UnaryOperator`, `BinaryOperator` with `of(delegate)` and `asDelegate()` (R9) |
| `flint.java.util.stream` | a lazy, sequential `Stream` and `Collectors` (R10) |

## `@safe` and Java's `Object` methods

druntime's `Object.opEquals`, `toHash` and `toString` carry no attributes, so `@safe` code cannot call them through
an `Object` reference, and `a == b` between two class references is `@safe` only when the class declares a typed
`@safe opEquals`. The API layer therefore never uses `==` or `toString` on an arbitrary class type: it calls
`javaEquals`, `javaHashCode` and `valueOf`, which reach references through `flint.engine.aot.objects`, the one
audited `@trusted` bridge (in flint:engine-aot's allowlisted `sys` directory). `mixin JavaObject` adds a typed
`opEquals`, so `a == b` stays `@safe` between instances of a user class. Comparing two collections held as
interfaces uses `equals`, as Java code does.

## Deviations (proposed to the rulebook)

- D-15: `java.util.function` is `flint.java.util.function_` (`function` is a D keyword).
- D-16: `HashMap` and `HashSet` iterate in insertion order; Java leaves the order unspecified.
- D-17: `Map.keySet`, `values` and `entrySet` are snapshots, not live views; `Map.Entry.setValue` writes through.
- D-18: `Map.get` of a missing key returns `V.init` (null for references and strings), since D has no boxed null.
- D-19: `List!int` names index removal `removeAt` only; other lists also offer Java's `remove(int)`.
- D-20: streams are sequential; `parallel()` returns the same stream.

## Verification

`dub test :java --compiler=dmd` and `--compiler=ldc2` run `tests/java_types.d`: the exception hierarchy, messages,
causes and trace-free control-flow exceptions; `mixin JavaObject` with `==`, associative arrays and `<`; Java's
`String.hashCode` on non-ASCII and surrogate-pair input (R14); number parsing at the limits and its error
messages; `Optional`; lists, sets and maps including unmodifiable variants, stable sorting, comparators, the erased
views and descriptors; lazy, short-circuiting streams and the collectors with Java's duplicate-key message; the
functional interfaces; `java.io`.
