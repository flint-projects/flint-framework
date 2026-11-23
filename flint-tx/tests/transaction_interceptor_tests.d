/++
Ported from spring-projects/spring-framework v7.1.0,
spring-tx/src/test/java/org/springframework/transaction/interceptor/TransactionInterceptorTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: only TransactionInterceptorTests' own tests; the inherited AbstractTransactionAspectTests
scenarios are in `transaction_interceptor.d` and `abstract_transaction_aspect_upstream_tests.d`. A subclass exposes
the protected `determineTransactionManager`, whose `targetClass` argument Flint does not take. The mocked
`BeanFactory` is a recording fake that also does what Spring's `BeanFactoryAnnotationUtils.qualifiedBeanOfType`
does over a mock: Flint's `BeanFactory.getBeanOfType(type, qualifier)` covers both, and throws
`NoSuchBeanDefinitionException` (a local stand-in, as `flint:tx` does not depend on `flint:beans`) for an unknown
qualifier. The default `DescriptorTransactionAttributeSource` stands in for the `NameMatchTransactionAttributeSource`
the helper sets, which these tests never consult.
+/
module flint.transaction.transaction_interceptor_tests;

import flint.engine.aot.any : Any;
import flint.engine.aot.bean : BeanFactory;
import flint.java.lang : RuntimeException, UnsupportedOperationException;
import flint.transaction;
import flint.transaction.interceptor;
import flint.transaction.support;
import std.typecons : BlackHole;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fixtures

/// The `NoSuchBeanDefinitionException` a `BeanFactory` throws.
private final class NoSuchBeanDefinitionException : RuntimeException
{
    this(string message)
    {
        super(message);
    }
}

/// A Mockito `BeanFactory` mock, with `associateTransactionManager`'s stubbing and call counts for `verify`.
private final class MockBeanFactory : BeanFactory
{
    private enum string transactionManagerType = "flint.transaction.TransactionManager";
    PlatformTransactionManager[string] beans;
    /// `given(beanFactory.getBean(TransactionManager.class)).willReturn(...)`.
    PlatformTransactionManager defaultTransactionManager;
    size_t[string] containsBeanCalls;
    size_t[string] getBeanCalls;
    size_t getBeanOfTypeCalls;

    bool containsBean(string name)
    {
        ++containsBeanCalls.require(name, 0);
        return (name in beans) !is null;
    }

    Object getBean(string name)
    {
        ++getBeanCalls.require(name, 0);
        auto found = name in beans;
        return found is null ? null : cast(Object)*found;
    }

    Object getBeanOfType(string type, string qualifier = null)
    {
        assert(type == transactionManagerType, "unexpected bean type " ~ type);
        if (qualifier is null)
        {
            ++getBeanOfTypeCalls;
            return cast(Object) defaultTransactionManager;
        }
        // BeanFactoryAnnotationUtils.qualifiedBeanOfType over a BeanFactory that is not listable.
        if (containsBean(qualifier))
            return getBean(qualifier);
        throw new NoSuchBeanDefinitionException("No matching TransactionManager bean found for bean name '"
                ~ qualifier ~ "'! (Note: Qualifier matching not supported because given BeanFactory does not "
                ~ "implement ConfigurableListableBeanFactory.)");
    }

    Object findBeanOfType(string, string = null)
    {
        return null;
    }

    Object[] getBeansOfType(string)
    {
        return null;
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

/// Exposes the protected `determineTransactionManager`.
private final class TestTransactionInterceptor : TransactionInterceptor
{
    TransactionManager determineTransactionManager(TransactionAttribute txAttr, Object)
    {
        return super.determineTransactionManager(txAttr);
    }
}

private PlatformTransactionManager mockTransactionManager()
{
    return new BlackHole!PlatformTransactionManager;
}

private TestTransactionInterceptor createTransactionInterceptor(BeanFactory beanFactory,
        string transactionManagerName, PlatformTransactionManager transactionManager)
{
    auto ti = new TestTransactionInterceptor;
    if (beanFactory !is null)
        ti.setBeanFactory(beanFactory);
    if (transactionManagerName !is null)
        ti.setTransactionManagerBeanName(transactionManagerName);
    if (transactionManager !is null)
        ti.setTransactionManager(transactionManager);
    ti.setTransactionAttributeSource(new DescriptorTransactionAttributeSource);
    ti.afterPropertiesSet();
    return ti;
}

private TestTransactionInterceptor transactionInterceptorWithTransactionManager(
        PlatformTransactionManager transactionManager, BeanFactory beanFactory)
{
    return createTransactionInterceptor(beanFactory, null, transactionManager);
}

private TestTransactionInterceptor transactionInterceptorWithTransactionManagerName(
        string transactionManagerName, BeanFactory beanFactory)
{
    return createTransactionInterceptor(beanFactory, transactionManagerName, null);
}

private TestTransactionInterceptor simpleTransactionInterceptor(BeanFactory beanFactory)
{
    return createTransactionInterceptor(beanFactory, null, null);
}

private PlatformTransactionManager associateTransactionManager(MockBeanFactory beanFactory, string name)
{
    auto transactionManager = mockTransactionManager();
    beanFactory.beans[name] = transactionManager;
    return transactionManager;
}

private bool same(TransactionManager actual, PlatformTransactionManager expected)
{
    return cast(Object) actual is cast(Object) expected;
}

// ---------------------------------------------------------------------------------------------------------------
// Tests

version (FlintJavaSerialization)
{
    // Gap: Java serialization, setTransactionAttributes(Properties) and the NameMatch/Composite attribute sources
    // are not ported.

    /// We won't use this: we just want to know it's serializable.
    private final class SerializableTransactionManager : PlatformTransactionManager, Serializable
    {
        override TransactionStatus getTransaction(TransactionDefinition definition)
        {
            throw new UnsupportedOperationException();
        }

        override void commit(TransactionStatus status)
        {
            throw new UnsupportedOperationException();
        }

        override void rollback(TransactionStatus status)
        {
            throw new UnsupportedOperationException();
        }
    }

    /// A TransactionInterceptor should be serializable if its PlatformTransactionManager is.
    @("TransactionInterceptorTests.serializableWithAttributeProperties")
    unittest
    {
        auto ti = new TransactionInterceptor;
        auto props = new Properties;
        props.setProperty("methodName", "PROPAGATION_REQUIRED");
        ti.setTransactionAttributes(props);
        PlatformTransactionManager ptm = new SerializableTransactionManager;
        ti.setTransactionManager(ptm);
        ti = SerializationTestUtils.serializeAndDeserialize(ti);

        // Check that logger survived deserialization
        assert(ti.logger !is null);
        assert(cast(SerializableTransactionManager) ti.getTransactionManager() !is null);
        assert(ti.getTransactionAttributeSource() !is null);
    }

    @("TransactionInterceptorTests.serializableWithCompositeSource")
    unittest
    {
        auto tas1 = new NameMatchTransactionAttributeSource;
        auto props = new Properties;
        props.setProperty("methodName", "PROPAGATION_REQUIRED");
        tas1.setProperties(props);

        auto tas2 = new NameMatchTransactionAttributeSource;
        props = new Properties;
        props.setProperty("otherMethodName", "PROPAGATION_REQUIRES_NEW");
        tas2.setProperties(props);

        auto ti = new TransactionInterceptor;
        ti.setTransactionAttributeSources(tas1, tas2);
        PlatformTransactionManager ptm = new SerializableTransactionManager;
        ti.setTransactionManager(ptm);
        ti = SerializationTestUtils.serializeAndDeserialize(ti);

        assert(cast(SerializableTransactionManager) ti.getTransactionManager() !is null);
        auto ctas = cast(CompositeTransactionAttributeSource) ti.getTransactionAttributeSource();
        assert(ctas !is null);
        assert(cast(NameMatchTransactionAttributeSource) ctas.getTransactionAttributeSources()[0]!is null);
        assert(cast(NameMatchTransactionAttributeSource) ctas.getTransactionAttributeSources()[1]!is null);
    }
}

@("TransactionInterceptorTests.determineTransactionManagerWithNoBeanFactory")
unittest
{
    auto transactionManager = mockTransactionManager();
    auto ti = transactionInterceptorWithTransactionManager(transactionManager, null);

    assert(same(ti.determineTransactionManager(new DefaultTransactionAttribute(), null), transactionManager));
}

@("TransactionInterceptorTests.determineTransactionManagerWithNoBeanFactoryAndNoTransactionAttribute")
unittest
{
    auto transactionManager = mockTransactionManager();
    auto ti = transactionInterceptorWithTransactionManager(transactionManager, null);

    assert(same(ti.determineTransactionManager(null, null), transactionManager));
}

@("TransactionInterceptorTests.determineTransactionManagerWithNoTransactionAttribute")
unittest
{
    auto beanFactory = new MockBeanFactory;
    auto ti = simpleTransactionInterceptor(beanFactory);

    assert(ti.determineTransactionManager(null, null) is null);
}

@("TransactionInterceptorTests.determineTransactionManagerWithQualifierUnknown")
unittest
{
    auto beanFactory = new MockBeanFactory;
    auto ti = simpleTransactionInterceptor(beanFactory);
    auto attribute = new DefaultTransactionAttribute();
    attribute.setQualifier("fooTransactionManager");

    try
    {
        ti.determineTransactionManager(attribute, null);
        assert(false, "expected NoSuchBeanDefinitionException");
    }
    catch (NoSuchBeanDefinitionException ex)
    {
        import std.algorithm.searching : canFind;

        assert(ex.msg.canFind("'fooTransactionManager'"));
    }
}

@("TransactionInterceptorTests.determineTransactionManagerWithQualifierAndDefault")
unittest
{
    auto beanFactory = new MockBeanFactory;
    auto transactionManager = mockTransactionManager();
    auto ti = transactionInterceptorWithTransactionManager(transactionManager, beanFactory);
    auto fooTransactionManager = associateTransactionManager(beanFactory, "fooTransactionManager");

    auto attribute = new DefaultTransactionAttribute();
    attribute.setQualifier("fooTransactionManager");

    assert(same(ti.determineTransactionManager(attribute, null), fooTransactionManager));
}

@("TransactionInterceptorTests.determineTransactionManagerWithQualifierAndDefaultName")
unittest
{
    auto beanFactory = new MockBeanFactory;
    associateTransactionManager(beanFactory, "defaultTransactionManager");
    auto ti = transactionInterceptorWithTransactionManagerName("defaultTransactionManager", beanFactory);

    auto fooTransactionManager = associateTransactionManager(beanFactory, "fooTransactionManager");
    auto attribute = new DefaultTransactionAttribute();
    attribute.setQualifier("fooTransactionManager");

    assert(same(ti.determineTransactionManager(attribute, null), fooTransactionManager));
}

@("TransactionInterceptorTests.determineTransactionManagerWithEmptyQualifierAndDefaultName")
unittest
{
    auto beanFactory = new MockBeanFactory;
    auto defaultTransactionManager = associateTransactionManager(beanFactory, "defaultTransactionManager");
    auto ti = transactionInterceptorWithTransactionManagerName("defaultTransactionManager", beanFactory);

    auto attribute = new DefaultTransactionAttribute();
    attribute.setQualifier("");

    assert(same(ti.determineTransactionManager(attribute, null), defaultTransactionManager));
}

version (FlintTransactionManagerCache)
{
    // Behaviour: TransactionAspectSupport does not cache the transaction managers it looks up, so every call asks
    // the BeanFactory again (two lookups where Spring's transactionManagerCache makes one).

    @("TransactionInterceptorTests.determineTransactionManagerWithQualifierSeveralTimes")
    unittest
    {
        auto beanFactory = new MockBeanFactory;
        auto ti = simpleTransactionInterceptor(beanFactory);

        auto txManager = associateTransactionManager(beanFactory, "fooTransactionManager");

        auto attribute = new DefaultTransactionAttribute();
        attribute.setQualifier("fooTransactionManager");
        auto actual = ti.determineTransactionManager(attribute, null);
        assert(same(actual, txManager));

        // Call again, should be cached
        auto actual2 = ti.determineTransactionManager(attribute, null);
        assert(same(actual2, txManager));
        assert(beanFactory.containsBeanCalls["fooTransactionManager"] == 1);
        assert(beanFactory.getBeanCalls["fooTransactionManager"] == 1);
    }

    @("TransactionInterceptorTests.determineTransactionManagerWithBeanNameSeveralTimes")
    unittest
    {
        auto beanFactory = new MockBeanFactory;
        auto ti = transactionInterceptorWithTransactionManagerName("fooTransactionManager", beanFactory);

        auto txManager = associateTransactionManager(beanFactory, "fooTransactionManager");

        auto attribute = new DefaultTransactionAttribute();
        auto actual = ti.determineTransactionManager(attribute, null);
        assert(same(actual, txManager));

        // Call again, should be cached
        auto actual2 = ti.determineTransactionManager(attribute, null);
        assert(same(actual2, txManager));
        assert(beanFactory.getBeanCalls["fooTransactionManager"] == 1);
    }

    @("TransactionInterceptorTests.determineTransactionManagerDefaultSeveralTimes")
    unittest
    {
        auto beanFactory = new MockBeanFactory;
        auto ti = simpleTransactionInterceptor(beanFactory);

        auto txManager = mockTransactionManager();
        beanFactory.defaultTransactionManager = txManager;

        auto attribute = new DefaultTransactionAttribute();
        auto actual = ti.determineTransactionManager(attribute, null);
        assert(same(actual, txManager));

        // Call again, should be cached
        auto actual2 = ti.determineTransactionManager(attribute, null);
        assert(same(actual2, txManager));
        assert(beanFactory.getBeanOfTypeCalls == 1);
    }
}
