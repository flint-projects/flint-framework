/++
Ported from spring-projects/spring-framework v7.1.0,
spring-tx/src/test/java/org/springframework/transaction/interceptor/AbstractTransactionAspectTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: only the tests that `transaction_interceptor.d` (module
`flint.transaction.transaction_interceptor_test`) does not already cover by name; they run as the subclass
TransactionInterceptorTests runs them, through a `TransactionInterceptor`. `advised` builds a hand-written proxy that
calls `TransactionInterceptor.invoke` for every method, as a `ProxyFactory` with the interceptor as its only advice
does. `ITestBean`'s methods are `MethodDescriptor`s, and `MapTransactionAttributeSource` maps them to attributes.
Mockito mocks become recording fakes: the `PlatformTransactionManager` answers `getTransaction` with the status
stubbed for an equal definition (equal `toString`, as `DefaultTransactionDefinition.equals` compares), and null
otherwise; `TransactionStatus` mocks are `BlackHole`s. Also ported: MapTransactionAttributeSource.java and, from
spring-tx/src/testFixtures, MockCallbackPreferringTransactionManager.java.
+/
module flint.transaction.abstract_transaction_aspect_upstream_tests;

import flint.dao : OptimisticLockingFailureException;
import flint.engine.aot.descriptor : Descriptor, MethodDescriptor, TypeKind;
import flint.engine.aot.proxy : Invocation;
import flint.java.lang : RuntimeException, UnsupportedOperationException, javaEquals, valueOf;
import flint.transaction;
import flint.transaction.interceptor;
import flint.transaction.support;
import std.typecons : BlackHole;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fixtures

/// `ITestBean`, reduced to the methods these tests call.
private interface ITestBean
{
    string getName();
    void setName(string name);
    ITestBean getSpouse();
    void exceptional(Exception t);
}

/// `TestBean`: `exceptional` throws what it is given.
private class TestBean : ITestBean
{
    private string name;
    private ITestBean spouse;

    string getName()
    {
        return name;
    }

    void setName(string name)
    {
        this.name = name;
    }

    ITestBean getSpouse()
    {
        return spouse;
    }

    void setSpouse(ITestBean spouse)
    {
        this.spouse = spouse;
    }

    void exceptional(Exception t)
    {
        if (t !is null)
            throw t;
    }
}

/// `@BeforeEach setup`: `ITestBean`'s methods, as the descriptor Flint AOT emits for the proxied type.
private struct Methods
{
    Descriptor descriptor;

    static Methods setup()
    {
        Methods methods;
        methods.descriptor = new Descriptor("flint.beans.testfixture.ITestBean", TypeKind.interface_);
        foreach (index, name; ["getName", "setName", "exceptional"])
        {
            MethodDescriptor method;
            method.name = name;
            method.index = cast(uint) index;
            methods.descriptor.methods ~= method;
        }
        return methods;
    }

    const(MethodDescriptor)* getNameMethod()
    {
        return &descriptor.methods[0];
    }

    const(MethodDescriptor)* setNameMethod()
    {
        return &descriptor.methods[1];
    }

    const(MethodDescriptor)* exceptionalMethod()
    {
        return &descriptor.methods[2];
    }
}

/// `MapTransactionAttributeSource`: attributes registered per method.
private final class MapTransactionAttributeSource : TransactionAttributeSource
{
    private TransactionAttribute[const(MethodDescriptor)* ] attributeMap;

    void register(const(MethodDescriptor)* method, TransactionAttribute txAtt)
    {
        attributeMap[method] = txAtt;
    }

    override TransactionAttribute getTransactionAttribute(const(MethodDescriptor)* method, const Descriptor)
    {
        auto found = method in attributeMap;
        return found is null ? null : *found;
    }
}

/// A Mockito `PlatformTransactionManager` mock: stubbed statuses, recorded commits and rollbacks.
private final class MockTransactionManager : PlatformTransactionManager
{
    private TransactionAttribute[] stubbedDefinitions;
    private TransactionStatus[] stubbedStatuses;
    Exception getTransactionFailure;
    Exception commitFailure;
    Exception rollbackFailure;
    TransactionStatus[] commits;
    TransactionStatus[] rollbacks;
    size_t interactions;

    /// `given(ptm.getTransaction(definition)).willReturn(status)`.
    void givenTransaction(TransactionAttribute definition, TransactionStatus status)
    {
        stubbedDefinitions ~= definition;
        stubbedStatuses ~= status;
    }

    override TransactionStatus getTransaction(TransactionDefinition definition)
    {
        ++interactions;
        if (getTransactionFailure !is null)
            throw getTransactionFailure;
        foreach (index, stubbed; stubbedDefinitions)
            if (valueOf(stubbed) == valueOf(definition))
                return stubbedStatuses[index];
        return null;
    }

    override void commit(TransactionStatus status)
    {
        ++interactions;
        commits ~= status;
        if (commitFailure !is null)
            throw commitFailure;
    }

    override void rollback(TransactionStatus status)
    {
        ++interactions;
        rollbacks ~= status;
        if (rollbackFailure !is null)
            throw rollbackFailure;
    }

    /// How often `verify(ptm, times(n)).commit(status)` would count.
    size_t commitsOf(TransactionStatus status)
    {
        size_t count;
        foreach (committed; commits)
            count += committed is status;
        return count;
    }

    /// ditto, for rollbacks.
    size_t rollbacksOf(TransactionStatus status)
    {
        size_t count;
        foreach (rolledBack; rollbacks)
            count += rolledBack is status;
        return count;
    }
}

/// Reads the protected `TransactionAspectSupport.currentTransactionInfo()`.
private abstract class CurrentTransactionInfo : TransactionInterceptor
{
    static bool hasTransaction()
    {
        return currentTransactionInfo().hasTransaction();
    }

    static TransactionAttribute transactionAttribute()
    {
        return currentTransactionInfo().getTransactionAttribute();
    }
}

/// The proxy `ProxyFactory` would create, with the `TransactionInterceptor` as its only advice.
private final class TestBeanProxy : ITestBean
{
    private ITestBean target;
    private TransactionInterceptor interceptor;
    private Methods methods;

    this(ITestBean target, TransactionInterceptor interceptor, Methods methods)
    {
        this.target = target;
        this.interceptor = interceptor;
        this.methods = methods;
    }

    private void call(const(MethodDescriptor)* method, scope void delegate() @safe action)
    {
        auto invocation = Invocation(method, cast(Object) target, null);
        interceptor.invoke(invocation, (ref Invocation) @safe { action(); });
    }

    string getName()
    {
        string result;
        call(methods.getNameMethod(), () { result = target.getName(); });
        return result;
    }

    void setName(string name)
    {
        call(methods.setNameMethod(), () { target.setName(name); });
    }

    ITestBean getSpouse()
    {
        return target.getSpouse();
    }

    void exceptional(Exception t)
    {
        call(methods.exceptionalMethod(), () { target.exceptional(t); });
    }
}

/// TransactionInterceptorTests' `advised`: a proxy whose interceptor uses `ptm` and `tas`.
private ITestBean advised(ITestBean target, PlatformTransactionManager ptm,
        TransactionAttributeSource tas, Methods methods)
{
    auto ti = new TransactionInterceptor;
    ti.setTransactionManager(ptm);
    assert(ti.getTransactionManager() is ptm);
    ti.setTransactionAttributeSource(tas);
    assert(ti.getTransactionAttributeSource() is tas);
    return new TestBeanProxy(target, ti, methods);
}

private void checkTransactionStatus(bool expected)
{
    try
    {
        TransactionInterceptor.currentTransactionStatus();
        if (!expected)
            assert(false, "Should have thrown NoTransactionException");
    }
    catch (NoTransactionException ex)
    {
        if (expected)
            assert(false, "Should have current TransactionStatus");
    }
}

private TransactionStatus mockStatus()
{
    return new BlackHole!TransactionStatus;
}

// ---------------------------------------------------------------------------------------------------------------
// Tests

version (FlintCallbackPreferringTransactionAspect)
{
    // Behaviour: TransactionAspectSupport ignores CallbackPreferringPlatformTransactionManager and calls
    // getTransaction/commit instead of execute (UnsupportedOperationException from the mock).

    /// `MockCallbackPreferringTransactionManager`.
    private final class MockCallbackPreferringTransactionManager : CallbackPreferringPlatformTransactionManager
    {
        private TransactionDefinition definition;
        private TransactionStatus status;

        override void execute(TransactionDefinition definition, scope void delegate(TransactionStatus) @safe action)
        {
            this.definition = definition;
            status = new SimpleTransactionStatus();
            action(status);
        }

        TransactionDefinition getDefinition()
        {
            return definition;
        }

        TransactionStatus getStatus()
        {
            return status;
        }

        override TransactionStatus getTransaction(TransactionDefinition)
        {
            throw new UnsupportedOperationException();
        }

        override void commit(TransactionStatus)
        {
            throw new UnsupportedOperationException();
        }

        override void rollback(TransactionStatus)
        {
            throw new UnsupportedOperationException();
        }
    }

    @("AbstractTransactionAspectTests.transactionShouldSucceedWithCallbackPreference")
    unittest
    {
        auto methods = Methods.setup();
        TransactionAttribute txatt = new DefaultTransactionAttribute();

        auto tas = new MapTransactionAttributeSource;
        tas.register(methods.getNameMethod(), txatt);

        auto ptm = new MockCallbackPreferringTransactionManager;

        auto tb = new TestBean;
        auto itb = advised(tb, ptm, tas, methods);

        checkTransactionStatus(false);
        itb.getName();
        checkTransactionStatus(false);

        assert(cast(Object) ptm.getDefinition() is cast(Object) txatt);
        assert(!ptm.getStatus().isRollbackOnly());
    }

    @("AbstractTransactionAspectTests.transactionExceptionPropagatedWithCallbackPreference")
    unittest
    {
        auto methods = Methods.setup();
        TransactionAttribute txatt = new DefaultTransactionAttribute();

        auto tas = new MapTransactionAttributeSource;
        tas.register(methods.exceptionalMethod(), txatt);

        auto ptm = new MockCallbackPreferringTransactionManager;

        auto tb = new TestBean;
        auto itb = advised(tb, ptm, tas, methods);

        checkTransactionStatus(false);
        try
        {
            itb.exceptional(new OptimisticLockingFailureException(""));
            assert(false, "expected OptimisticLockingFailureException");
        }
        catch (OptimisticLockingFailureException)
        {
        }
        checkTransactionStatus(false);

        assert(cast(Object) ptm.getDefinition() is cast(Object) txatt);
        assert(!ptm.getStatus().isRollbackOnly());
    }
}

version (FlintConfiguredTransactionAttributes)
{
    // Gap: CompositeTransactionAttributeSource (advised with several attribute sources) is not ported.
    @("AbstractTransactionAspectTests.twoTransactionsShouldSucceed")
    unittest
    {
        auto methods = Methods.setup();
        TransactionAttribute txatt = new DefaultTransactionAttribute();

        auto tas1 = new MapTransactionAttributeSource;
        tas1.register(methods.getNameMethod(), txatt);
        auto tas2 = new MapTransactionAttributeSource;
        tas2.register(methods.setNameMethod(), txatt);

        auto status = mockStatus();
        auto ptm = new MockTransactionManager;
        // expect a transaction
        ptm.givenTransaction(txatt, status);

        auto tb = new TestBean;
        auto ti = new TransactionInterceptor;
        ti.setTransactionManager(ptm);
        ti.setTransactionAttributeSources(tas1, tas2);
        ITestBean itb = new TestBeanProxy(tb, ti, methods);

        checkTransactionStatus(false);
        itb.getName();
        checkTransactionStatus(false);
        itb.setName("myName");
        checkTransactionStatus(false);

        assert(ptm.commitsOf(status) == 2);
    }
}

/// The enclosing-transaction tests' `final String spouseName`.
private enum string spouseName = "innerName";

@("AbstractTransactionAspectTests.enclosingTransactionWithNonTransactionMethodOnAdvisedInside")
unittest
{
    auto methods = Methods.setup();
    TransactionAttribute txatt = new DefaultTransactionAttribute();

    auto tas = new MapTransactionAttributeSource;
    tas.register(methods.exceptionalMethod(), txatt);

    auto status = mockStatus();
    auto ptm = new MockTransactionManager;
    // Expect a transaction
    ptm.givenTransaction(txatt, status);

    auto outer = new class TestBean
    {
        override void exceptional(Exception t)
        {
            assert(CurrentTransactionInfo.hasTransaction());
            assert(getSpouse().getName() == spouseName);
        }
    };
    auto inner = new class TestBean
    {
        override string getName()
        {
            // Assert that we're in the inner proxy
            assert(!CurrentTransactionInfo.hasTransaction());
            return spouseName;
        }
    };

    auto outerProxy = advised(outer, ptm, tas, methods);
    auto innerProxy = advised(inner, ptm, tas, methods);
    outer.setSpouse(innerProxy);

    checkTransactionStatus(false);

    // Will invoke inner.getName, which is non-transactional
    outerProxy.exceptional(null);

    checkTransactionStatus(false);

    assert(ptm.commitsOf(status) == 1);
}

@("AbstractTransactionAspectTests.enclosingTransactionWithNestedTransactionOnAdvisedInside")
unittest
{
    auto methods = Methods.setup();
    TransactionAttribute outerTxatt = new DefaultTransactionAttribute();
    TransactionAttribute innerTxatt = new DefaultTransactionAttribute(TransactionDefinition.PROPAGATION_NESTED);

    const outerMethod = methods.exceptionalMethod();
    const innerMethod = methods.getNameMethod();
    auto tas = new MapTransactionAttributeSource;
    tas.register(outerMethod, outerTxatt);
    tas.register(innerMethod, innerTxatt);

    auto outerStatus = mockStatus();
    auto innerStatus = mockStatus();

    auto ptm = new MockTransactionManager;
    // Expect a transaction
    ptm.givenTransaction(outerTxatt, outerStatus);
    ptm.givenTransaction(innerTxatt, innerStatus);

    auto outer = new class TestBean
    {
        override void exceptional(Exception t)
        {
            assert(CurrentTransactionInfo.hasTransaction());
            assert(javaEquals(CurrentTransactionInfo.transactionAttribute(), outerTxatt));
            assert(getSpouse().getName() == spouseName);
        }
    };
    auto inner = new class TestBean
    {
        override string getName()
        {
            // Assert that we're in the inner proxy
            // Has nested transaction
            assert(CurrentTransactionInfo.hasTransaction());
            assert(javaEquals(CurrentTransactionInfo.transactionAttribute(), innerTxatt));
            return spouseName;
        }
    };

    auto outerProxy = advised(outer, ptm, tas, methods);
    auto innerProxy = advised(inner, ptm, tas, methods);
    outer.setSpouse(innerProxy);

    checkTransactionStatus(false);

    // Will invoke inner.getName, which is non-transactional
    outerProxy.exceptional(null);

    checkTransactionStatus(false);

    assert(ptm.commitsOf(innerStatus) == 1);
    assert(ptm.commitsOf(outerStatus) == 1);
}

/++
Check that the given exception thrown by the target can produce the desired behavior with the appropriate
transaction attribute: `ex` is thrown by the target, and `shouldRollback` says whether it should cause a rollback.
+/
private void doTestRollbackOnException(Exception ex, bool shouldRollback, bool rollbackException)
{
    auto methods = Methods.setup();
    TransactionAttribute txatt = new class DefaultTransactionAttribute
    {
        override bool rollbackOn(Throwable t)
        {
            assert(t is ex);
            return shouldRollback;
        }
    };

    const m = methods.exceptionalMethod();
    auto tas = new MapTransactionAttributeSource;
    tas.register(m, txatt);

    auto status = mockStatus();
    auto ptm = new MockTransactionManager;
    // Gets additional call(s) from TransactionControl

    ptm.givenTransaction(txatt, status);

    auto tex = new TransactionSystemException("system exception");
    if (rollbackException)
    {
        if (shouldRollback)
            ptm.rollbackFailure = tex;
        else
            ptm.commitFailure = tex;
    }

    auto tb = new TestBean;
    auto itb = advised(tb, ptm, tas, methods);

    try
    {
        itb.exceptional(ex);
        assert(false, "Should have thrown exception");
    }
    catch (Exception t)
    {
        if (rollbackException)
            assert(t is tex, "Caught wrong exception");
        else
            assert(t is ex, "Caught wrong exception");
    }

    if (!rollbackException)
    {
        if (shouldRollback)
            assert(ptm.rollbacksOf(status) == 1);
        else
            assert(ptm.commitsOf(status) == 1);
    }
}

@("AbstractTransactionAspectTests.rollbackOnCheckedExceptionWithRollbackException")
unittest
{
    doTestRollbackOnException(new Exception(""), true, true);
}

@("AbstractTransactionAspectTests.noRollbackOnCheckedExceptionWithRollbackException")
unittest
{
    doTestRollbackOnException(new Exception(""), false, true);
}

@("AbstractTransactionAspectTests.rollbackOnUncheckedExceptionWithRollbackException")
unittest
{
    doTestRollbackOnException(new RuntimeException(), true, true);
}

@("AbstractTransactionAspectTests.noRollbackOnUncheckedExceptionWithRollbackException")
unittest
{
    doTestRollbackOnException(new RuntimeException(), false, true);
}

/// Simulate a transaction infrastructure failure. Shouldn't invoke target method.
@("AbstractTransactionAspectTests.cannotCreateTransaction")
unittest
{
    auto methods = Methods.setup();
    TransactionAttribute txatt = new DefaultTransactionAttribute();

    const m = methods.getNameMethod();
    auto tas = new MapTransactionAttributeSource;
    tas.register(m, txatt);

    auto ptm = new MockTransactionManager;
    // Expect a transaction
    auto ex = new CannotCreateTransactionException("foobar", null);
    ptm.getTransactionFailure = ex;

    auto tb = new class TestBean
    {
        override string getName()
        {
            throw new UnsupportedOperationException(
                    "Shouldn't have invoked target method when couldn't create transaction for transactional method");
        }
    };
    auto itb = advised(tb, ptm, tas, methods);

    try
    {
        itb.getName();
        assert(false, "Shouldn't have invoked method");
    }
    catch (CannotCreateTransactionException thrown)
        assert(thrown is ex);
}
