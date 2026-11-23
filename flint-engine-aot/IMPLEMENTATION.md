# Flint AOT runtime

`flint:engine-aot` is the runtime half of the Flint AOT contract
([docs/spring/aot-contract.md](../../docs/spring/aot-contract.md), contract 1). Generated modules and the
framework packages (`flint:beans`, `flint:context`, web-mvc, data) meet here. Every module is a leaf; there is no
`package.d`.

| Module | Holds |
| --- | --- |
| `flint.engine.aot.name` | canonical type names: DMD's `__traits(fullyQualifiedName)`, with LDC's repeated eponymous template member removed, so both compilers agree with the generator |
| `flint.engine.aot.any` | `Any`: class references, inline scalars and strings, boxed structs, arrays and maps; `get!T` returns by `ref` for boxed structs and by value otherwise |
| `flint.engine.aot.descriptor` | `Descriptor` and its members; `DescriptorTable` with the built-in scalar descriptors; `descriptorOf!T`, the compile-time builder for hand-written code and tests, which merges annotations as section 2.1 says |
| `flint.engine.aot.bean`, `condition`, `event`, `mapping`, `query` | the generated tables |
| `flint.engine.aot.proxy` | `Invocation`, `AdviceChain`, the `Advisor` beans that build it, and `allocateProxy` |
| `flint.engine.aot.registry` | `AotRegistry`, `installRegistry`, `installedRegistry` and the contract-version check |
| `flint.engine.aot.sys.allocate` | the one `@trusted` function: druntime's `_d_newclass`, which allocates a class without running a constructor (Spring's Objenesis) |

Runtime extensions beyond section 4: `Descriptor.elementType` and `keyType` for collection element types,
`Any.holds!T`, `Any.ofObject`, `Any.box!T`, `Advisor` and `DetachedExecutor`, and `propertyMatches`, the single
implementation of `@ConditionalOnProperty`'s rule.

## Verification

`dub test :engine-aot --compiler=dmd` and `--compiler=ldc2` run `tests/aot_runtime.d`: names, descriptors, merged
annotations two levels deep with `@AliasFor` mirrors and meta-aliases, Java Beans properties over classes and boxed
structs, `Any` conversions and mismatches, the registry protocol, and a proxy built exactly as section 7 generates
it, with advisor ordering, short-circuiting and Spring's self-invocation semantics. `allocateUninitialized` has a
positive test (fields at their initial values, constructor not run) and negative tests (abstract class, null).
`tests/flint/core/annotation.d` stands in for flint:core's leaf annotation module in this package's tests only.
