// Ported from spring-framework v7.1.0: spring-tx/src/test/java/org/springframework/transaction/interceptor/AbstractTransactionAspectTests.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// The scenarios of AbstractTransactionAspectTests and TransactionInterceptorTests, driven the way Flint AOT's generated
// proxies drive them: method descriptors carrying a merged @Transactional, and the runtime's adviceChain.
module flint.transaction.transaction_interceptor_test;

import flint.core.annotation : ClassRef, classOf;
import flint.engine.aot.any : Any;
import flint.engine.aot.bean : BeanFactory;
import flint.engine.aot.descriptor : Descriptor, MergedAnnotation, MethodDescriptor, TypeKind;
import flint.engine.aot.proxy : AdviceChain, Advisor, Invocation, adviceChain;
import flint.java.io : IOException;
import flint.java.lang : IllegalStateException, RuntimeException;
import flint.transaction;
import flint.transaction.annotation : Propagation, Transactional;
import flint.transaction.interceptor;
import flint.transaction.support;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fixtures

/// A transaction manager that records each transaction it begins, commits and rolls back.
private final class RecordingTransactionManager : AbstractPlatformTransactionManager
{
    string name;
    string[] events;
    TransactionDefinition lastDefinition;
    bool failCommit;

    this(string name = "tm")
    {
        this.name = name;
    }

    override protected Object doGetTransaction()
    {
        auto bound = TransactionSynchronizationManager.getResource(this);
        return new TxObject(bound !is null);
    }

    override protected bool isExistingTransaction(Object transaction)
    {
        return (cast(TxObject) transaction).existing;
    }

    override protected void doBegin(Object transaction, TransactionDefinition definition)
    {
        lastDefinition = definition;
        events ~= "begin:" ~ definition.getName();
        TransactionSynchronizationManager.bindResource(this, new Marker);
    }

    override protected Object doSuspend(Object)
    {
        events ~= "suspend";
        return TransactionSynchronizationManager.unbindResource(this);
    }

    override protected void doResume(Object, Object suspendedResources)
    {
        events ~= "resume";
        TransactionSynchronizationManager.bindResource(this, suspendedResources);
    }

    override protected void doCommit(DefaultTransactionStatus)
    {
        if (failCommit)
            throw new TransactionSystemException("commit failed");
        events ~= "commit";
    }

    override protected void doRollback(DefaultTransactionStatus)
    {
        events ~= "rollback";
    }

    override protected void doSetRollbackOnly(DefaultTransactionStatus)
    {
        events ~= "rollbackOnly";
    }

    override protected void doCleanupAfterCompletion(Object)
    {
        TransactionSynchronizationManager.unbindResourceIfPossible(this);
    }
}

private final class TxObject
{
    bool existing;

    this(bool existing)
    {
        this.existing = existing;
    }
}

private final class Marker
{
}

/// The bean factory the context would be: the interceptor as the only advisor, plus named transaction managers.
private final class Beans : BeanFactory
{
    TransactionInterceptor interceptor;
    RecordingTransactionManager[string] managers;
    RecordingTransactionManager primary;

    Object getBean(string name)
    {
        return managers[name];
    }

    Object getBeanOfType(string type, string qualifier = null)
    {
        if (type == "flint.transaction.TransactionManager")
            return qualifier is null ? primary : managers[qualifier];
        assert(false, "unexpected bean type " ~ type);
    }

    Object findBeanOfType(string, string = null)
    {
        return null;
    }

    Object[] getBeansOfType(string type)
    {
        return type == "flint.engine.aot.proxy.Advisor" ? [cast(Object) interceptor] : null;
    }

    Any resolveValue(string, string)
    {
        return Any.init;
    }

    void bind(string, Any)
    {
    }

    Any bindConstructor(string, string)
    {
        return Any.init;
    }
}

/// One advised service: what Flint AOT emits as the service's descriptor.
private Descriptor serviceDescriptor(Transactional[] attributes)
{
    auto descriptor = new Descriptor("shop.OrderService", TypeKind.class_);
    foreach (index, attribute; attributes)
    {
        MethodDescriptor method;
        method.name = "method" ~ cast(char)('0' + index);
        method.returnType = "string";
        method.index = cast(uint) index;
        method.annotations = [
            MergedAnnotation("flint.transaction.annotation.Transactional", Any.of(attribute), 0)
        ];
        descriptor.methods ~= method;
    }
    MethodDescriptor plain;
    plain.name = "plain";
    plain.index = cast(uint) attributes.length;
    descriptor.methods ~= plain;
    return descriptor;
}

private struct Fixture
{
    Beans beans;
    RecordingTransactionManager tm;
    Descriptor descriptor;
    AdviceChain chain;

    static Fixture create(Transactional[] attributes...)
    {
        Fixture fixture;
        fixture.tm = new RecordingTransactionManager;
        fixture.beans = new Beans;
        fixture.beans.primary = fixture.tm;
        fixture.beans.managers["tm"] = fixture.tm;
        fixture.beans.interceptor = new TransactionInterceptor;
        fixture.beans.interceptor.setBeanFactory(fixture.beans);
        fixture.descriptor = serviceDescriptor(attributes.dup);
        fixture.chain = adviceChain(fixture.beans, fixture.descriptor);
        return fixture;
    }

    /// Call method `index` through the advice chain, running `body` as the target.
    string call(size_t index, scope void delegate() @safe body)
    {
        auto invocation = Invocation(&descriptor.methods[index], null, null);
        chain.invoke(invocation, (ref Invocation i) @safe { body(); i.result = Any.of("done"); });
        return invocation.result.isNull ? null : invocation.result.get!string;
    }
}

private void expectThrows(E : Throwable)(scope void delegate() @safe action, E expected = null)
{
    try
    {
        action();
        assert(false, "expected " ~ E.stringof);
    }
    catch (E caught)
        assert(expected is null || caught is expected, "a different " ~ E.stringof ~ " was thrown");
}

// ---------------------------------------------------------------------------------------------------------------
// Tests

@("AbstractTransactionAspectTests.noTransaction")
unittest
{
    auto fixture = Fixture.create(Transactional());
    // The plain method has no attribute: the interceptor does not apply to it.
    assert(!fixture.beans.interceptor.appliesTo(fixture.descriptor, &fixture.descriptor.methods[1]));
    assert(fixture.call(1, () {}) == "done");
    assert(fixture.tm.events.length == 0);
}

@("AbstractTransactionAspectTests.transactionShouldSucceed")
unittest
{
    auto fixture = Fixture.create(Transactional());
    bool sawStatus;
    assert(fixture.call(0, () {
            auto status = TransactionAspectSupport.currentTransactionStatus();
            sawStatus = status.isNewTransaction() && TransactionSynchronizationManager.isActualTransactionActive();
        }) == "done");
    assert(sawStatus, "the target saw the current transaction");
    // With no name declared, the transaction is named after the method.
    assert(fixture.tm.events == ["begin:shop.OrderService.method0", "commit"]);
    expectThrows!NoTransactionException(() { TransactionAspectSupport.currentTransactionStatus(); });
}

@("AbstractTransactionAspectTests.transactionShouldSucceedWithNotNew and enclosing transactions")
unittest
{
    // method0 joins (REQUIRED); method1 starts a new one (REQUIRES_NEW), suspending the outer.
    auto fixture = Fixture.create(Transactional(), Transactional(propagation: Propagation.REQUIRES_NEW));
    fixture.call(0, () {
        fixture.call(0, () {
            assert(!TransactionAspectSupport.currentTransactionStatus().isNewTransaction());
        });
        fixture.call(1, () {
            assert(TransactionAspectSupport.currentTransactionStatus().isNewTransaction());
        });
        // The outer status is current again.
        assert(TransactionAspectSupport.currentTransactionStatus().isNewTransaction());
    });
    assert(fixture.tm.events.length == 6, "events");
    assert(fixture.tm.events[1 .. $] == [
        "suspend", "begin:shop.OrderService.method1", "commit", "resume", "commit"
    ]);
}

@("AbstractTransactionAspectTests.rollbackOnUncheckedException")
unittest
{
    auto fixture = Fixture.create(Transactional());
    auto ex = new RuntimeException("unchecked");
    expectThrows!RuntimeException(() { fixture.call(0, () { throw ex; }); }, ex);
    assert(fixture.tm.events[$ - 1] == "rollback");
}

@("AbstractTransactionAspectTests.noRollbackOnCheckedException")
unittest
{
    auto fixture = Fixture.create(Transactional());
    auto ex = new IOException("checked");
    expectThrows!IOException(() { fixture.call(0, () { throw ex; }); }, ex);
    assert(fixture.tm.events[$ - 1] == "commit", "a checked exception commits by default");
}

@("AbstractTransactionAspectTests.rollbackOnCheckedException (rollbackFor)")
unittest
{
    auto fixture = Fixture.create(Transactional(rollbackFor: [classOf!IOException]));
    expectThrows!IOException(() { fixture.call(0, () { throw new IOException("checked"); }); });
    assert(fixture.tm.events[$ - 1] == "rollback");
}

private final class BusinessWarning : RuntimeException
{
}

@("AbstractTransactionAspectTests.noRollbackOnUncheckedException (noRollbackFor)")
unittest
{
    auto fixture = Fixture.create(Transactional(noRollbackFor: [classOf!BusinessWarning]));
    expectThrows!BusinessWarning(() { fixture.call(0, () { throw new BusinessWarning; }); });
    assert(fixture.tm.events[$ - 1] == "commit");
    // Another runtime exception still rolls back.
    expectThrows!RuntimeException(() { fixture.call(0, () { throw new RuntimeException("x"); }); });
    assert(fixture.tm.events[$ - 1] == "rollback");
}

@("AbstractTransactionAspectTests.rollbackOnCustomException (rollbackForClassName)")
unittest
{
    auto fixture = Fixture.create(Transactional(rollbackForClassName: ["IOException"]));
    expectThrows!IOException(() { fixture.call(0, () { throw new IOException("checked"); }); });
    assert(fixture.tm.events[$ - 1] == "rollback");
}

@("AbstractTransactionAspectTests.programmaticRollback")
unittest
{
    auto fixture = Fixture.create(Transactional());
    fixture.call(0, () { TransactionAspectSupport.currentTransactionStatus().setRollbackOnly(); });
    assert(fixture.tm.events[$ - 1] == "rollback");
}

@("AbstractTransactionAspectTests.cannotCommitTransaction")
unittest
{
    auto fixture = Fixture.create(Transactional());
    fixture.tm.failCommit = true;
    expectThrows!TransactionSystemException(() { fixture.call(0, () {}); });
}

@("TransactionInterceptor reads the attribute's settings and resolves the qualified transaction manager")
unittest
{
    auto fixture = Fixture.create(Transactional(value: "orders", readOnly: true, timeout: 30,
propagation: Propagation.REQUIRES_NEW));
    auto orders = new RecordingTransactionManager("orders");
    fixture.beans.managers["orders"] = orders;
    fixture.call(0, () {});
    assert(fixture.tm.events.length == 0, "the qualifier selects the orders manager");
    assert(orders.events[$ - 1] == "commit");
    auto definition = orders.lastDefinition;
    assert(definition.isReadOnly() && definition.getTimeout() == 30);
    assert(definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    assert((cast(TransactionAttribute) definition).getQualifier() == "orders");
}

@("the attribute parser rejects both timeout and timeoutString, and keeps labels and rules")
unittest
{
    try
    {
        DescriptorTransactionAttributeSource.parseTransactionAnnotation(Transactional(timeout: 5,
    timeoutString: "${tx.timeout}"));
        assert(false, "expected IllegalArgumentException");
    }
    catch (Exception)
    {
    }
    auto attribute = DescriptorTransactionAttributeSource.parseTransactionAnnotation(Transactional(label: [
        "nightly"
    ], rollbackFor: [classOf!IOException], noRollbackForClassName: ["Warning"]));
    assert(attribute.getLabels().contains("nightly"));
    assert(attribute.getRollbackRules().size() == 2);
    assert(attribute.rollbackOn(new IOException("x")));
    assert(!attribute.rollbackOn(new BusinessWarning));
}
