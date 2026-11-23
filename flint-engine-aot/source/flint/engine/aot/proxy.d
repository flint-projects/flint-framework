/++
AOP proxies: what generated proxy subclasses call (AOT contract section 4.7, section 7).

A generated `X__FlintProxy : X` forwards every overridable public method to a separately constructed target, so a
call from inside the target runs no advice, as with Spring's JDK and CGLIB proxies. Advised methods build an
`Invocation` and run it through the `AdviceChain` that `adviceChain` assembles from the `Advisor` beans the
context registered (transactions, caching, async, validation, method security, retry).
+/
module flint.engine.aot.proxy;

import flint.engine.aot.any : Any;
import flint.engine.aot.bean : BeanFactory;
import flint.engine.aot.descriptor : Descriptor, MethodDescriptor;
import flint.engine.aot.name : typeNameOf;

@safe:

/// One call of an advised method.
struct Invocation
{
    /// The advised method's descriptor.
    const(MethodDescriptor)* method;
    /// The target the proxy forwards to.
    Object target;
    /// Every argument, boxed, in order.
    Any[] arguments;
    /// Set by `proceed`, or by an interceptor that short-circuits.
    Any result;
}

/// Continue with the next interceptor, or call the target.
alias Proceed = void delegate(ref Invocation invocation) @safe;

/// The interceptors of one proxied bean.
interface AdviceChain
{
    /// Run the interceptors that apply to `invocation.method`, then `proceed` unless one short-circuits.
    void invoke(ref Invocation invocation, scope Proceed proceed);
    /// For `@Async`: run the same chain later on the task executor; `proceed` owns copies of the arguments.
    void invokeDetached(Invocation invocation, Proceed proceed);
}

/++
An interceptor the context registers as a bean: the runtime side of `@Transactional`, `@Cacheable`, `@Async`,
`@Validated`, `@PreAuthorize` and `@Retryable` (Spring's `Advisor` plus its `MethodInterceptor`).
+/
interface Advisor
{
    /// Whether this advisor intercepts `method` of `descriptor`, judged by its merged annotations.
    bool appliesTo(const Descriptor descriptor, const(MethodDescriptor)* method);
    /// `Ordered.getOrder()`: lower values run first, outermost.
    int getOrder();
    /// Intercept: call `proceed` to continue, or set `invocation.result` and return to short-circuit.
    void invoke(ref Invocation invocation, scope Proceed proceed);
}

/// Where `invokeDetached` runs work: the `@Async` task executor bean. Without one, detached work runs inline.
interface DetachedExecutor
{
    /// Run `task` later.
    void execute(void delegate() @safe task);
}

/// Build the chain for one proxied bean from the `Advisor` beans, ordered by `getOrder()`.
AdviceChain adviceChain(BeanFactory factory, const Descriptor descriptor)
{
    Advisor[] advisors;
    foreach (bean; factory.getBeansOfType(typeNameOf!Advisor))
        if (auto advisor = cast(Advisor) bean)
            advisors ~= advisor;
    // Stable insertion sort: advisors with equal order keep registration order.
    foreach (i; 1 .. advisors.length)
    {
        auto current = advisors[i];
        size_t j = i;
        while (j > 0 && advisors[j - 1].getOrder() > current.getOrder())
        {
            advisors[j] = advisors[j - 1];
            j--;
        }
        advisors[j] = current;
    }
    Advisor[][] perMethod;
    perMethod.length = descriptor.methods.length;
    foreach (index, ref method; descriptor.methods)
        foreach (advisor; advisors)
            if (advisor.appliesTo(descriptor, &method))
                perMethod[index] ~= advisor;
    auto executor = cast(DetachedExecutor) factory.findBeanOfType(typeNameOf!DetachedExecutor);
    return new OrderedChain(perMethod, executor);
}

private final class OrderedChain : AdviceChain
{
    private Advisor[][] perMethod;
    private DetachedExecutor executor;

    this(Advisor[][] perMethod, DetachedExecutor executor) pure nothrow
    {
        this.perMethod = perMethod;
        this.executor = executor;
    }

    void invoke(ref Invocation invocation, scope Proceed proceed)
    {
        Advisor[] chain;
        if (invocation.method !is null && invocation.method.index < perMethod.length)
            chain = perMethod[invocation.method.index];
        step(chain, 0, invocation, proceed);
    }

    private static void step(Advisor[] chain, size_t position, ref Invocation invocation, scope Proceed proceed)
    {
        if (position == chain.length)
        {
            proceed(invocation);
            return;
        }
        chain[position].invoke(invocation, (ref Invocation next) @safe {
            step(chain, position + 1, next, proceed);
        });
    }

    void invokeDetached(Invocation invocation, Proceed proceed)
    {
        void run() @safe
        {
            invoke(invocation, proceed);
        }

        if (executor is null)
            run();
        else
            executor.execute(&run);
    }
}

/++
Spring's Objenesis: an instance of `proxyClass` whose fields hold their initial values and whose constructor did
not run. The proxy's base-class state is never read: every overridable public method forwards to the target.
+/
Object allocateProxy(const TypeInfo_Class proxyClass) nothrow
{
    import flint.engine.aot.sys.allocate : allocateUninitialized;

    return allocateUninitialized(proxyClass);
}
