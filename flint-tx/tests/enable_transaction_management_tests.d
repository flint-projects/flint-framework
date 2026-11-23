/++
`@EnableTransactionManagement` and `ProxyTransactionManagementConfiguration`: the annotation imports the
configuration, and the configuration's interceptor finds the context's transaction manager by type and runs a
`@Transactional` method in a transaction. Flint's own tests: Spring's `EnableTransactionManagementTests` need an
annotation-config context that processes `@Import`, which Flint AOT does at build time.
+/
module flint.transaction.enable_transaction_management_test;

import flint.context.annotation : Import;
import flint.context.support : GenericApplicationContext;
import flint.core.annotation : classOf;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, MergedAnnotation, MethodDescriptor, TypeKind;
import flint.engine.aot.proxy : Invocation;
import flint.java.lang : RuntimeException;
import flint.transaction : TransactionDefinition;
import flint.transaction.annotation : EnableTransactionManagement, Transactional;
import flint.transaction.annotation.configuration : AbstractTransactionManagementConfiguration,
    ProxyTransactionManagementConfiguration;
import flint.transaction.interceptor : DescriptorTransactionAttributeSource, TransactionInterceptor;
import flint.transaction.support : AbstractPlatformTransactionManager, DefaultTransactionStatus,
    TransactionSynchronizationManager;

@safe:

/// A transaction manager that records each transaction it begins, commits and rolls back.
private final class RecordingTransactionManager : AbstractPlatformTransactionManager
{
    string[] events;

    override protected Object doGetTransaction()
    {
        return new Object;
    }

    override protected void doBegin(Object, TransactionDefinition definition)
    {
        events ~= "begin:" ~ definition.getName();
    }

    override protected void doCommit(DefaultTransactionStatus)
    {
        events ~= "commit";
    }

    override protected void doRollback(DefaultTransactionStatus)
    {
        events ~= "rollback";
    }
}

/// `shop.OrderService` with one `@Transactional` method, as Flint AOT describes it.
private Descriptor serviceDescriptor()
{
    auto descriptor = new Descriptor("shop.OrderService", TypeKind.class_);
    MethodDescriptor method;
    method.name = "placeOrder";
    method.returnType = "string";
    method.annotations = [
        MergedAnnotation("flint.transaction.annotation.Transactional", Any.of(Transactional()), 0)
    ];
    descriptor.methods ~= method;
    return descriptor;
}

/// The interceptor `ProxyTransactionManagementConfiguration` registers, in a context holding `manager`.
private TransactionInterceptor configuredInterceptor(RecordingTransactionManager manager)
{
    auto context = new GenericApplicationContext;
    context.getBeanFactory().registerSingleton("transactionManager", manager);
    auto configuration = new ProxyTransactionManagementConfiguration;
    return configuration.transactionInterceptor(configuration.transactionAttributeSource(), context);
}

@("@EnableTransactionManagement imports ProxyTransactionManagementConfiguration")
unittest
{
    alias imports = __traits(getAttributes, EnableTransactionManagement);
    static assert(imports.length == 1 && is(typeof(imports[0]) == Import));
    static assert(imports[0].value.length == 1);
    static assert(imports[0].value[0] == classOf!ProxyTransactionManagementConfiguration,
            "the by-name import matches the configuration's qualified name");
    static assert(is(ProxyTransactionManagementConfiguration : AbstractTransactionManagementConfiguration),
            "Boot's TransactionAutoConfiguration backs off on AbstractTransactionManagementConfiguration");
    EnableTransactionManagement defaults;
    assert(defaults.order == int.max && !defaults.proxyTargetClass);
}

@("ProxyTransactionManagementConfiguration: the interceptor reads @Transactional from descriptors")
unittest
{
    auto configuration = new ProxyTransactionManagementConfiguration;
    auto source = configuration.transactionAttributeSource();
    assert(cast(DescriptorTransactionAttributeSource) source !is null);
    auto interceptor = configuration.transactionInterceptor(source, new GenericApplicationContext);
    assert(interceptor.getTransactionAttributeSource() is source);
    auto descriptor = serviceDescriptor();
    assert(interceptor.appliesTo(descriptor, &descriptor.methods[0]));
}

@("ProxyTransactionManagementConfiguration: a @Transactional call commits through the context's manager")
unittest
{
    auto manager = new RecordingTransactionManager;
    auto interceptor = configuredInterceptor(manager);
    auto descriptor = serviceDescriptor();
    assert(interceptor.appliesTo(descriptor, &descriptor.methods[0]));

    bool active;
    auto invocation = Invocation(&descriptor.methods[0], null, null);
    interceptor.invoke(invocation, (ref Invocation i) @safe {
        active = TransactionSynchronizationManager.isActualTransactionActive();
        i.result = Any.of("placed");
    });
    assert(active, "the target ran in a transaction");
    assert(invocation.result.get!string == "placed");
    assert(manager.events == ["begin:shop.OrderService.placeOrder", "commit"], manager.events[0]);
}

@("ProxyTransactionManagementConfiguration: a RuntimeException rolls the call back")
unittest
{
    auto manager = new RecordingTransactionManager;
    auto interceptor = configuredInterceptor(manager);
    auto descriptor = serviceDescriptor();
    assert(interceptor.appliesTo(descriptor, &descriptor.methods[0]));

    auto invocation = Invocation(&descriptor.methods[0], null, null);
    try
    {
        interceptor.invoke(invocation, (ref Invocation) @safe {
            throw new RuntimeException("out of stock");
        });
        assert(false, "expected the RuntimeException");
    }
    catch (RuntimeException ex)
        assert(ex.msg == "out of stock");
    assert(manager.events == ["begin:shop.OrderService.placeOrder", "rollback"]);
}
