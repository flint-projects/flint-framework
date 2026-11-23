# Flint AOT runtime

`flint:engine-aot` (`framework/engine-aot`, a Spring-layer module of `policy/framework.json` whose `sys` directory is the audited `unsafe` root) is the runtime half of the Flint AOT contract
([docs/spring/aot-contract.md](../../docs/spring/aot-contract.md), contract 3, accepting contract-1 and contract-2 code). Generated modules and the
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

## Contract 2

Additive fields, so contract-1 generated code still runs (`checkContractVersion` accepts 1 and 2):
`HandlerMapping.beanType`/`typeAnnotations`, `ExceptionHandlerSpec.beanType`/`adviceAssignableTypes`/
`adviceAnnotations`/`produces`, `ArgumentSpec.elementType`, `ConstructorDescriptor.canonical`,
`BeanDefinition.rank`, `ConditionContext.isAutoConfigurationExcluded`, and on `Descriptor` the erased builders
`enumValue`, `length`/`element`/`fromElements`, `toKeys`/`toValues`/`fromEntries` and `unwrap`/`wrap`.
`descriptorOf!T` fills the builders for enums, arrays and associative arrays directly, and for other types through
static hooks (`__flintElements`/`__flintFromElements`, `__flintEntries`/`__flintFromEntries`,
`__flintUnwrap`/`__flintWrap`) that flint:java's collections and `Optional` declare.

## Contract 3

Additive, so contract-1 and contract-2 generated code still runs (`checkContractVersion` accepts 1 to 3).
`flint.engine.aot.expression` holds method-level SpEL compiled to D: `EvaluationContext` (arguments, result,
method name, root functions and properties, beans, placeholders), `CompiledExpression` and `ExpressionSpec`.
`MethodDescriptor.expressions` lists a method's compiled attributes (`expression(annotation, attribute)` finds
one), and `EventListenerSpec.conditionExpression` is a listener's compiled condition. flint:context evaluates it
before each dispatch (`isTrue`: a `bool` true or the string `true`); a condition without its compiled form fails at
refresh.

