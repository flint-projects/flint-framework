/++
Java's `Object` methods over `Object` references, for the API layer: `objectEquals`, `objectToHash` and
`objectToString` (see `flint.engine.aot.sys.objects` for why they exist).
+/
module flint.engine.aot.objects;

public import flint.engine.aot.sys.objects : objectEquals, objectToHash, objectToString;

@safe:
