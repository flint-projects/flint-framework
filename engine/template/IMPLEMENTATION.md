# Flint HTML templates

Import `flint.engine.templates` and add the resource directory to DUB's `stringImportPaths`. Call
`render!"invoice.html"(model, arena)` with a typed model and a request arena. The compiler checks the
resource and emits direct field reads and writes. The result is an arena `Buffer` whose lifetime
follows that arena's generation.

Templates support `{{model.customer.name}}`, boolean `if` and `else` blocks, array loops, and
relative includes. Interpolation escapes text and quoted attributes. A dynamic URL occupies the
entire quoted attribute value and accepts relative, HTTP, HTTPS and mailto URLs under the fixed URL
policy. The compiler reports invalid syntax, context and model fields with resource coordinates.

Rendering counts the escaped bytes before allocating the result. Includes have a depth limit of
16 and an aggregate source limit of 1 MiB. Each render has a 16 MiB output limit and a 100,000-iteration
loop limit. The default raw-HTML trust type has no public conversion from an arena buffer.

Treat embedded resource bytes and compiler flags as build inputs. The scaling fixture uses their
digests to invalidate the owning leaf after a resource-only edit and compiles a shared partial once
per compiler invocation.

- Run the DUB unit suite with both DMD and LDC.
- Run `python3 packages/engine-template/negative/check.py dmd` and repeat with `ldc2` for compiler rejection cases.
- Run `packages/engine-template/bench/scaling.py` with the pinned compiler paths and an output directory.
- Build the feature and equivalent baseline under `bench` to replay the 1 KiB and 64 KiB fixtures.
