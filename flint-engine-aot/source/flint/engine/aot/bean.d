/++
Bean definitions as Flint AOT emits them, and the factory services generated code calls (AOT contract 4.3).

`flint.beans.factory.support.DefaultListableBeanFactory` implements `BeanFactory` and turns each
`BeanDefinition` into a Spring `RootBeanDefinition`. Type names are canonical fully qualified D names
(`flint.engine.aot.name`).
+/
module flint.engine.aot.bean;

import flint.engine.aot.any : Any;
import flint.engine.aot.condition : ConditionContext;

@safe:

/// `@Scope` values.
enum ScopeKind
{
    singleton,
    prototype,
    request,
    session,
}

/// The container services a generated factory, initializer or proxy calls back into.
interface BeanFactory
{
    /// The bean named `name`, created on demand. Throws `NoSuchBeanDefinitionException`.
    Object getBean(string name);
    /// The single bean injectable as `type`, narrowed by `qualifier`. Throws `NoSuchBeanDefinitionException`
    /// or `NoUniqueBeanDefinitionException`.
    Object getBeanOfType(string type, string qualifier = null);
    /// Like `getBeanOfType`, but null when there is no candidate (optional injection).
    Object findBeanOfType(string type, string qualifier = null);
    /// Every bean injectable as `type`, in `@Order` order (`List!T` and `T[]` injection).
    Object[] getBeansOfType(string type);
    /// `@Value("${...}")`: the expression resolved against the environment and converted to `targetType`.
    Any resolveValue(string expression, string targetType);
    /// `@ConfigurationProperties`: bind properties under `prefix` onto `target`, JavaBean style.
    void bind(string prefix, Any target);
    /// Constructor binding: a new `type` built from the properties under `prefix`.
    Any bindConstructor(string prefix, string type);
}

/// One bean definition.
struct BeanDefinition
{
    /// The bean name.
    string name;
    /// The bean's declared type: the class, or the `@Bean` method's return type.
    string type;
    /// Every type it can be injected as: the class chain and interfaces.
    string[] types;
    /// `@DependsOn`, plus every bean name the generator saw it require.
    string[] dependsOn;
    /// `@Qualifier` values on the definition.
    string[] qualifiers;
    /// `@Scope`.
    ScopeKind scope_;
    /// `@Primary`: preferred among several candidates.
    bool primary;
    /// `@Fallback`: used only when no other candidate exists.
    bool fallback;
    /// `@Lazy`: created on first use instead of at refresh.
    bool lazyInit;
    /// `@Order`; `int.max` when absent.
    int order = int.max;
    /// Defined by an auto-configuration class.
    bool autoConfiguration;
    /// Where the definition was declared: `src/shop/owners.d:12`.
    string source;
    /// Create the instance: the constructor, or the `@Bean` method on its configuration bean.
    Object function(BeanFactory factory) @safe create;
    /// `@Autowired` fields and setters, `@PostConstruct`, `afterPropertiesSet`; or null.
    void function(Object bean, BeanFactory factory) @safe initialize;
    /// `@PreDestroy`, `destroy()`, an inferred `close`/`shutdown`; or null.
    void function(Object bean) @safe destroy;
    /// The definition's conditions, conjoined; null when unconditional.
    bool function(ConditionContext context) @safe condition;
    /// Contract 2: the registry's ordering rank (definition order across modules); 0 when unranked.
    uint rank;
    /// Wrap the target in its generated AOP proxy; null when not advised.
    Object function(Object target, BeanFactory factory) @safe proxy;
}
