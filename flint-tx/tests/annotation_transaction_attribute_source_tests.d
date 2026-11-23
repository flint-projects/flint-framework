/++
Ported from spring-projects/spring-framework v7.1.0,
spring-tx/src/test/java/org/springframework/transaction/annotation/AnnotationTransactionAttributeSourceTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: Flint resolves `@Transactional` in two steps. Flint AOT merges the annotations at build
time (aot-contract section 2.1: meta-annotations and `@AliasFor`, then the annotations of the interface and
superclass methods a method implements, then the class's own class-level advice for a method without its own),
and `DescriptorTransactionAttributeSource`, which replaces `AnnotationTransactionAttributeSource`, parses the merged
`@Transactional` of a `MethodDescriptor`. So each upstream test bean is the descriptor Flint AOT emits for it, and
a `Method` is the descriptor's method; a comment on each bean names the merging rule that applies. A
`Class`-valued attribute is a `ClassRef`; Java's `Exception` and `IOException` are `object.Exception` and
`flint.java.io.IOException`.
+/
module flint.transaction.annotation_transaction_attribute_source_tests;

import flint.core.annotation : AliasFor, classOf;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, MergedAnnotation, MethodDescriptor, TypeKind;
import flint.engine.aot.name : typeNameOf;
import flint.java.io : IOException;
import flint.transaction : TransactionDefinition;
import flint.transaction.annotation : Isolation, Propagation, Transactional;
import flint.transaction.interceptor;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fixtures: the annotations and the descriptors Flint AOT emits for the upstream test beans

/// `@Transactional(rollbackFor = Exception.class)`. Merged values are built field by field, as generated code
/// builds them.
private Transactional rollbackForException()
{
    Transactional result;
    result.rollbackFor = [classOf!Exception];
    return result;
}

/// `@Transactional(rollbackFor = Exception.class, noRollbackFor = IOException.class)`: also what `@Tx` merges into.
private Transactional txRules()
{
    auto result = rollbackForException();
    result.noRollbackFor = [classOf!IOException];
    return result;
}

/// The `@Transactional` that `@TxWithAttribute(readOnly = true)` merges into.
private Transactional txReadOnlyRules()
{
    auto result = txRules();
    result.readOnly = true;
    return result;
}

/// `@Transactional(label = labels)`.
private Transactional labelled(string[] labels...)
{
    Transactional result;
    result.label = labels.dup;
    return result;
}

/// `@Tx`: composed of `@Transactional(rollbackFor = Exception.class, noRollbackFor = IOException.class)`.
@(txRules())
private struct Tx
{
}

/// `@TxWithAttribute`: `@Tx` with `readOnly` aliased onto `@Transactional`.
@(txRules())
private struct TxWithAttribute
{
    @AliasFor("readOnly", classOf!Transactional) bool readOnly;
}

private MergedAnnotation transactional(Transactional value, ubyte distance = 0)
{
    return MergedAnnotation(typeNameOf!Transactional, Any.of(value), distance);
}

private MergedAnnotation tx()
{
    return MergedAnnotation(typeNameOf!Tx, Any.of(Tx()), 0);
}

private MergedAnnotation txWithAttribute(bool readOnly)
{
    return MergedAnnotation(typeNameOf!TxWithAttribute, Any.of(TxWithAttribute(readOnly)), 0);
}

private MethodDescriptor method(string name, MergedAnnotation[] annotations...)
{
    MethodDescriptor result;
    result.name = name;
    result.annotations = annotations.dup;
    return result;
}

private Descriptor type(string name, TypeKind kind, MergedAnnotation[] annotations, MethodDescriptor[] methods...)
{
    enum string testClass = "flint.transaction.annotation.AnnotationTransactionAttributeSourceTests.";
    auto result = new Descriptor(testClass ~ name, kind);
    result.annotations = annotations;
    foreach (index, method; methods)
    {
        result.methods ~= method;
        result.methods[$ - 1].index = cast(uint) index;
    }
    return result;
}

/// `Empty`: no annotations at all.
private Descriptor empty()
{
    return type("Empty", TypeKind.class_, null, method("getAge"));
}

/// `TestBean1`: `@Transactional(rollbackFor = Exception.class)` on `getAge`.
private Descriptor testBean1()
{
    return type("TestBean1", TypeKind.class_, null, method("getAge", transactional(rollbackForException())));
}

/// `ITestBean2X extends ITestBean2`: `@Transactional` on `getAge`, declared on both interfaces.
private Descriptor iTestBean2X()
{
    return type("ITestBean2X", TypeKind.interface_, null, method("getAge", transactional(Transactional())));
}

/// `TestBean2 implements ITestBean2X`: `getAge` takes the `@Transactional` of the interface methods it implements.
private Descriptor testBean2()
{
    return type("TestBean2", TypeKind.class_, null, method("getAge", transactional(Transactional())));
}

/// `TestBean3 implements ITestBean3`: its own method-level attributes. `getName` declares none, and the
/// type-level `@Transactional` of `ITestBean3` is not merged: a class takes only its own class-level advice.
private Descriptor testBean3()
{
    // Built field by field, as generated code builds a merged annotation.
    Transactional getAge;
    getAge.propagation = Propagation.REQUIRES_NEW;
    getAge.isolation = Isolation.REPEATABLE_READ;
    getAge.timeout = 5;
    getAge.readOnly = true;
    getAge.rollbackFor = [classOf!Exception];
    getAge.noRollbackFor = [classOf!IOException];
    auto setAge = getAge;
    setAge.timeout = -1;
    setAge.timeoutString = "${myTimeout}";
    return type("TestBean3", TypeKind.class_, null, method("getAge", transactional(getAge)),
            method("setAge", transactional(setAge)), method("getName"));
}

/// `@Transactional(rollbackFor = Exception.class, noRollbackFor = IOException.class) TestBean4`: the class-level
/// advice applies to `getAge`, which declares none.
private Descriptor testBean4()
{
    return type("TestBean4", TypeKind.class_, [transactional(txRules())], method("getAge", transactional(txRules())));
}

/// `@Tx TestBean5`: the class-level `@Transactional` is a meta-annotation, one level up.
private Descriptor testBean5()
{
    return type("TestBean5", TypeKind.class_, [tx(), transactional(txRules(), 1)], method("getAge",
            transactional(txRules(), 1)));
}

/// `TestBean6`: `@Tx` on `getAge`.
private Descriptor testBean6()
{
    return type("TestBean6", TypeKind.class_, null, method("getAge", tx(), transactional(txRules(), 1)));
}

/// `@TxWithAttribute(readOnly = true) TestBean7`: `readOnly` is merged into the meta-annotation.
private Descriptor testBean7()
{
    return type("TestBean7", TypeKind.class_, [
        txWithAttribute(true), transactional(txReadOnlyRules(), 1)
    ], method("getAge", transactional(txReadOnlyRules(), 1)));
}

/// `TestBean8`: `@TxWithAttribute(readOnly = true)` on `getAge`.
private Descriptor testBean8()
{
    return type("TestBean8", TypeKind.class_, null, method("getAge", txWithAttribute(true),
            transactional(txReadOnlyRules(), 1)));
}

/// `@TxWithAttribute(readOnly = true) TestInterface9`.
private Descriptor testInterface9()
{
    return type("TestInterface9", TypeKind.interface_, [
        txWithAttribute(true), transactional(txReadOnlyRules(), 1)
    ], method("getAge"));
}

/// `TestBean9 implements TestInterface9`: the interface's type-level annotation is not merged into the class.
private Descriptor testBean9()
{
    return type("TestBean9", TypeKind.class_, null, method("getAge"));
}

/// `TestInterface10`: `@TxWithAttribute(readOnly = true)` on `getAge`.
private Descriptor testInterface10()
{
    return type("TestInterface10", TypeKind.interface_, null, method("getAge",
            txWithAttribute(true), transactional(txReadOnlyRules(), 1)));
}

/// `TestBean10 implements TestInterface10`: `getAge` takes the annotations of the interface method.
private Descriptor testBean10()
{
    return type("TestBean10", TypeKind.class_, null, method("getAge", txWithAttribute(true),
            transactional(txReadOnlyRules(), 1)));
}

/// `@Transactional(label = {"retryable", "long-running"}) TestBean11`, with `@Transactional(label =
/// "short-running")` on `setAge`.
private Descriptor testBean11()
{
    return type("TestBean11", TypeKind.class_, [
        transactional(labelled("retryable", "long-running"))
    ], method("getAge", transactional(labelled("retryable", "long-running"))), method("setAge",
            transactional(labelled("short-running"))));
}

/// `ReflectionUtils.findMethod`: the descriptor's method called `methodName`.
private const(MethodDescriptor)* getMethod(const Descriptor declaringType, string methodName)
{
    foreach (ref method; declaringType.methods)
        if (method.name == methodName)
            return &method;
    assert(false, "no method " ~ methodName);
}

/// `AnnotationUtils.findAnnotation(method, Transactional.class) != null`.
private bool hasTransactional(const(MethodDescriptor)* method)
{
    foreach (ref annotation; method.annotations)
        if (annotation.type == typeNameOf!Transactional)
            return true;
    return false;
}

private TransactionAttribute getTransactionAttribute(TransactionAttributeSource attributeSource,
        const Descriptor targetType, const(MethodDescriptor)* method)
{
    auto transactionAttribute = attributeSource.getTransactionAttribute(method, targetType);
    assert(transactionAttribute !is null);
    return transactionAttribute;
}

/// A method declared by `declaringType` and invoked on `targetType`: Flint AOT's proxy of `targetType` passes its
/// own descriptor of the method, merged with the annotations of the declaring interface method.
private TransactionAttribute getTransactionAttribute(TransactionAttributeSource attributeSource,
        const Descriptor targetType, string methodName)
{
    return getTransactionAttribute(attributeSource, targetType, getMethod(targetType, methodName));
}

private void assertRollbackRules(TransactionAttribute transactionAttribute,
        RollbackRuleAttribute[] rollbackRuleAttributes...)
{
    auto rbta = new RuleBasedTransactionAttribute;
    foreach (rule; rollbackRuleAttributes)
        rbta.getRollbackRules().add(rule);
    auto attribute = cast(RuleBasedTransactionAttribute) transactionAttribute;
    assert(attribute !is null, "a RuleBasedTransactionAttribute");
    assert(attribute.getRollbackRules().equals(cast(Object) rbta.getRollbackRules()));
}

private void assertNoRollbackRule(TransactionAttribute transactionAttribute)
{
    assertRollbackRules(transactionAttribute);
}

// ---------------------------------------------------------------------------------------------------------------
// Tests

version (FlintJavaSerialization)
{
    // Gap: Java serialization of proxies (and ProxyFactory, Advised) is not ported.
    import flint.transaction : TransactionManager;
    import flint.transaction.support : AbstractPlatformTransactionManager, DefaultTransactionStatus;

    /// `CallCountingTransactionManager`, from spring-tx/src/testFixtures.
    private final class CallCountingTransactionManager : AbstractPlatformTransactionManager, Serializable
    {
        TransactionDefinition lastDefinition;
        int begun;
        int commits;
        int rollbacks;
        int inflight;

        override protected Object doGetTransaction()
        {
            return new Object();
        }

        override protected void doBegin(Object transaction, TransactionDefinition definition)
        {
            lastDefinition = definition;
            ++begun;
            ++inflight;
        }

        override protected void doCommit(DefaultTransactionStatus status)
        {
            ++commits;
            --inflight;
        }

        override protected void doRollback(DefaultTransactionStatus status)
        {
            ++rollbacks;
            --inflight;
        }
    }

    private interface ITestBean1
    {
        int getAge();
    }

    /// `TestBean1`: `@Transactional(rollbackFor = Exception.class)` on `getAge`.
    private class TestBean1 : ITestBean1, Serializable
    {
        private int age;

        @(rollbackForException()) int getAge()
        {
            return age;
        }
    }

    @("AnnotationTransactionAttributeSourceTests.serializable")
    unittest
    {
        auto attributeSource = new DescriptorTransactionAttributeSource;
        auto tb = new TestBean1();
        auto ptm = new CallCountingTransactionManager();
        auto ti = new TransactionInterceptor(cast(TransactionManager) ptm, attributeSource);

        auto proxyFactory = new ProxyFactory();
        proxyFactory.setInterfaces(typeid(ITestBean1));
        proxyFactory.addAdvice(ti);
        proxyFactory.setTarget(tb);
        auto proxy = cast(ITestBean1) proxyFactory.getProxy();
        proxy.getAge();
        assert(ptm.commits == 1);

        auto serializedProxy = SerializationTestUtils.serializeAndDeserialize(proxy);
        serializedProxy.getAge();
        auto advised = cast(Advised) serializedProxy;
        auto serializedTi = cast(TransactionInterceptor) advised.getAdvisors()[0].getAdvice();
        auto serializedPtm = cast(CallCountingTransactionManager) serializedTi.getTransactionManager();
        assert(serializedPtm.commits == 2);
    }
}

@("AnnotationTransactionAttributeSourceTests.nullOrEmpty")
unittest
{
    auto attributeSource = new DescriptorTransactionAttributeSource;
    const method = getMethod(empty(), "getAge");
    assert(attributeSource.getTransactionAttribute(method, null) is null);

    // Try again in case of caching
    assert(attributeSource.getTransactionAttribute(method, null) is null);
}

/// Test the important case where the invocation is on a proxied interface method but the attribute is defined on
/// the target class.
@("AnnotationTransactionAttributeSourceTests.transactionAttributeDeclaredOnClassMethod")
unittest
{
    auto attributeSource = new DescriptorTransactionAttributeSource;
    auto actual = getTransactionAttribute(attributeSource, testBean1(), "getAge");
    assertRollbackRules(actual, new RollbackRuleAttribute(typeid(Exception)));
}

/// Test the important case where the invocation is on a proxied interface method but the attribute is defined on
/// the target class. Flint AOT's proxy is a subclass of the target, as a CGLIB proxy is, and carries the target's
/// descriptor.
@("AnnotationTransactionAttributeSourceTests.transactionAttributeDeclaredOnCglibClassMethod")
unittest
{
    auto attributeSource = new DescriptorTransactionAttributeSource;
    const proxyClass = testBean1();

    auto actual = getTransactionAttribute(attributeSource, proxyClass, "getAge");
    assertRollbackRules(actual, new RollbackRuleAttribute(typeid(Exception)));
}

/// Test case where attribute is on the interface method.
@("AnnotationTransactionAttributeSourceTests.transactionAttributeDeclaredOnInterfaceMethodOnly")
unittest
{
    auto attributeSource = new DescriptorTransactionAttributeSource;
    auto actual = getTransactionAttribute(attributeSource, testBean2(), "getAge");
    assertNoRollbackRule(actual);
    const bean2 = testBean2();
    actual = getTransactionAttribute(attributeSource, bean2, getMethod(bean2, "getAge"));
    assertNoRollbackRule(actual);
    const bean2X = iTestBean2X();
    actual = getTransactionAttribute(attributeSource, bean2X, getMethod(bean2X, "getAge"));
    assertNoRollbackRule(actual);
}

version (FlintTransactionAttributeValueResolver)
{
    // Gap: DescriptorTransactionAttributeSource has no setEmbeddedValueResolver and never resolves timeoutString;
    // getName would also find no attribute, as ITestBean3's type-level @Transactional is not merged.

    /// Test that when an attribute exists on both class and interface, class takes precedence.
    @("AnnotationTransactionAttributeSourceTests."
            ~ "transactionAttributeOnTargetClassMethodOverridesAttributeOnInterfaceMethod")
    unittest
    {
        auto attributeSource = new DescriptorTransactionAttributeSource;
        attributeSource.setEmbeddedValueResolver((string strVal) => strVal == "${myTimeout}" ? "5" : strVal);

        auto actual = getTransactionAttribute(attributeSource, testBean3(), "getAge");
        assert(actual.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        assert(actual.getIsolationLevel() == TransactionDefinition.ISOLATION_REPEATABLE_READ);
        assert(actual.getTimeout() == 5);
        assert(actual.isReadOnly());
        assertRollbackRules(actual, new RollbackRuleAttribute(typeid(Exception)),
                new NoRollbackRuleAttribute(typeid(IOException)));

        auto actual2 = getTransactionAttribute(attributeSource, testBean3(), "setAge");
        assert(actual2.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        assert(actual2.getIsolationLevel() == TransactionDefinition.ISOLATION_REPEATABLE_READ);
        assert(actual2.getTimeout() == 5);
        assert(actual2.isReadOnly());
        assertRollbackRules(actual2, new RollbackRuleAttribute(typeid(Exception)),
                new NoRollbackRuleAttribute(typeid(IOException)));

        auto actual3 = getTransactionAttribute(attributeSource, testBean3(), "getName");
        assert(actual3.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);
    }
}

@("AnnotationTransactionAttributeSourceTests.rollbackRulesAreApplied")
unittest
{
    auto attributeSource = new DescriptorTransactionAttributeSource;
    const bean3 = testBean3();
    const method = getMethod(bean3, "getAge");

    auto actual = getTransactionAttribute(attributeSource, bean3, method);
    assertRollbackRules(actual, new RollbackRuleAttribute("object.Exception"),
            new NoRollbackRuleAttribute(typeid(IOException)));
    assert(actual.rollbackOn(new Exception("")));
    assert(!actual.rollbackOn(new IOException()));

    // The declaring class is TestBean3 itself.
    auto actual2 = getTransactionAttribute(attributeSource, bean3, method);
    assertRollbackRules(actual2, new RollbackRuleAttribute("object.Exception"),
            new NoRollbackRuleAttribute(typeid(IOException)));
    assert(actual2.rollbackOn(new Exception("")));
    assert(!actual2.rollbackOn(new IOException()));
}

@("AnnotationTransactionAttributeSourceTests.labelsAreApplied")
unittest
{
    auto attributeSource = new DescriptorTransactionAttributeSource;
    const bean11 = testBean11();
    auto actual = getTransactionAttribute(attributeSource, bean11, "getAge");
    assert(actual.getLabels().size() == 2);
    assert(actual.getLabels().contains("retryable") && actual.getLabels().contains("long-running"));

    auto actual2 = getTransactionAttribute(attributeSource, bean11, "setAge");
    assert(actual2.getLabels().size() == 1 && actual2.getLabels().contains("short-running"));
}

/// Test that transaction attribute is inherited from class if not specified on method.
@("AnnotationTransactionAttributeSourceTests.defaultsToClassTransactionAttribute")
unittest
{
    auto attributeSource = new DescriptorTransactionAttributeSource;
    auto actual = getTransactionAttribute(attributeSource, testBean4(), "getAge");
    assertRollbackRules(actual, new RollbackRuleAttribute(typeid(Exception)),
            new NoRollbackRuleAttribute(typeid(IOException)));
}

@("AnnotationTransactionAttributeSourceTests.customClassAttributeDetected")
unittest
{
    auto attributeSource = new DescriptorTransactionAttributeSource;
    auto actual = getTransactionAttribute(attributeSource, testBean5(), "getAge");
    assertRollbackRules(actual, new RollbackRuleAttribute(typeid(Exception)),
            new NoRollbackRuleAttribute(typeid(IOException)));
}

@("AnnotationTransactionAttributeSourceTests.customMethodAttributeDetected")
unittest
{
    auto attributeSource = new DescriptorTransactionAttributeSource;
    auto actual = getTransactionAttribute(attributeSource, testBean6(), "getAge");
    assertRollbackRules(actual, new RollbackRuleAttribute(typeid(Exception)),
            new NoRollbackRuleAttribute(typeid(IOException)));
}

@("AnnotationTransactionAttributeSourceTests.customClassAttributeWithReadOnlyOverrideDetected")
unittest
{
    auto attributeSource = new DescriptorTransactionAttributeSource;
    auto actual = getTransactionAttribute(attributeSource, testBean7(), "getAge");
    assertRollbackRules(actual, new RollbackRuleAttribute(typeid(Exception)),
            new NoRollbackRuleAttribute(typeid(IOException)));
    assert(actual.isReadOnly());
}

@("AnnotationTransactionAttributeSourceTests.customMethodAttributeWithReadOnlyOverrideDetected")
unittest
{
    auto attributeSource = new DescriptorTransactionAttributeSource;
    auto actual = getTransactionAttribute(attributeSource, testBean8(), "getAge");
    assertRollbackRules(actual, new RollbackRuleAttribute(typeid(Exception)),
            new NoRollbackRuleAttribute(typeid(IOException)));
    assert(actual.isReadOnly());
}

version (FlintInterfaceTypeLevelTransactional)
{
    // Behaviour: Flint AOT does not merge an interface's type-level @Transactional into the implementing class
    // (aot-contract 2.1 applies a class's own class-level advice only), so TestBean9.getAge is not transactional.
    @("AnnotationTransactionAttributeSourceTests.customClassAttributeWithReadOnlyOverrideOnInterface")
    unittest
    {
        auto attributeSource = new DescriptorTransactionAttributeSource;
        const method = getMethod(testInterface9(), "getAge");

        assert(!hasTransactional(method),
                "AnnotationUtils.findAnnotation should not find @Transactional for TestBean9.getAge()");
        assert(testBean9().annotation(typeNameOf!Transactional) !is null,
                "AnnotationUtils.findAnnotation failed to find @Transactional for TestBean9");

        const bean9 = testBean9();
        auto actual = getTransactionAttribute(attributeSource, bean9, getMethod(bean9, "getAge"));
        assertRollbackRules(actual, new RollbackRuleAttribute(typeid(Exception)),
                new NoRollbackRuleAttribute(typeid(IOException)));
        assert(actual.isReadOnly());
    }
}

@("AnnotationTransactionAttributeSourceTests.customMethodAttributeWithReadOnlyOverrideOnInterface")
unittest
{
    auto attributeSource = new DescriptorTransactionAttributeSource;
    const method = getMethod(testInterface10(), "getAge");

    assert(hasTransactional(method),
            "AnnotationUtils.findAnnotation failed to find @Transactional for TestBean10.getAge()");
    assert(testBean10().annotation(typeNameOf!Transactional) is null,
            "AnnotationUtils.findAnnotation should not find @Transactional for TestBean10");

    // The invocation reaches TestBean10's proxy, whose getAge carries the interface method's annotations.
    const bean10 = testBean10();
    auto actual = getTransactionAttribute(attributeSource, bean10, getMethod(bean10, "getAge"));
    assertRollbackRules(actual, new RollbackRuleAttribute(typeid(Exception)),
            new NoRollbackRuleAttribute(typeid(IOException)));
    assert(actual.isReadOnly());
}

version (FlintJtaEjbTransactionAnnotations)
{
    // Gap: jakarta.transaction.Transactional and jakarta.ejb.TransactionAttribute (and their parsers) are not
    // ported.
    import flint.jakarta.ejb : TransactionAttributeType, EjbTransactionAttribute = TransactionAttribute;
    import flint.jakarta.transaction : JtaTransactional = Transactional, TxType;

    /// `@jakarta.transaction.Transactional(txType)`.
    private MergedAnnotation jta(TxType txType = TxType.REQUIRED)
    {
        return MergedAnnotation(typeNameOf!JtaTransactional, Any.of(JtaTransactional(txType)), 0);
    }

    /// `@jakarta.ejb.TransactionAttribute(type)`.
    private MergedAnnotation ejb(TransactionAttributeType type = TransactionAttributeType.REQUIRED)
    {
        return MergedAnnotation(typeNameOf!EjbTransactionAttribute, Any.of(EjbTransactionAttribute(type)), 0);
    }

    /// `JtaAnnotatedBean1`: `@jakarta.transaction.Transactional(SUPPORTS)` on `getName`, plain on `getAge`.
    private Descriptor jtaAnnotatedBean1()
    {
        return type("JtaAnnotatedBean1", TypeKind.class_, null, method("getName",
                jta(TxType.SUPPORTS)), method("getAge", jta()));
    }

    /// `@jakarta.transaction.Transactional(SUPPORTS) JtaAnnotatedBean2`, plain on `getAge`.
    private Descriptor jtaAnnotatedBean2()
    {
        return type("JtaAnnotatedBean2", TypeKind.class_, [jta(TxType.SUPPORTS)], method("getName",
                jta(TxType.SUPPORTS)), method("getAge", jta()));
    }

    /// `JtaAnnotatedBean3 implements ITestJta`: `getAge` takes the interface method's annotation; the interface's
    /// type-level one is not merged.
    private Descriptor jtaAnnotatedBean3()
    {
        return type("JtaAnnotatedBean3", TypeKind.class_, null, method("getName"), method("getAge", jta()));
    }

    @("AnnotationTransactionAttributeSourceTests.JtaAttributeTests.transactionAttributeDeclaredOnClassMethod")
    unittest
    {
        auto attributeSource = new DescriptorTransactionAttributeSource;
        auto getAgeAttr = getTransactionAttribute(attributeSource, jtaAnnotatedBean1(), "getAge");
        assert(getAgeAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);
        auto getNameAttr = getTransactionAttribute(attributeSource, jtaAnnotatedBean1(), "getName");
        assert(getNameAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_SUPPORTS);
    }

    @("AnnotationTransactionAttributeSourceTests.JtaAttributeTests.transactionAttributeDeclaredOnClass")
    unittest
    {
        auto attributeSource = new DescriptorTransactionAttributeSource;
        auto getAgeAttr = getTransactionAttribute(attributeSource, jtaAnnotatedBean2(), "getAge");
        assert(getAgeAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);
        auto getNameAttr = getTransactionAttribute(attributeSource, jtaAnnotatedBean2(), "getName");
        assert(getNameAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_SUPPORTS);
    }

    @("AnnotationTransactionAttributeSourceTests.JtaAttributeTests.transactionAttributeDeclaredOnInterface")
    unittest
    {
        auto attributeSource = new DescriptorTransactionAttributeSource;
        auto getAgeAttr = getTransactionAttribute(attributeSource, jtaAnnotatedBean3(), "getAge");
        assert(getAgeAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);
        auto getNameAttr = getTransactionAttribute(attributeSource, jtaAnnotatedBean3(), "getName");
        assert(getNameAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_SUPPORTS);
    }

    /// `Ejb3AnnotatedBean1`: `@jakarta.ejb.TransactionAttribute(SUPPORTS)` on `getName`, plain on `getAge`.
    private Descriptor ejb3AnnotatedBean1()
    {
        return type("Ejb3AnnotatedBean1", TypeKind.class_, null, method("getName",
                ejb(TransactionAttributeType.SUPPORTS)), method("getAge", ejb()));
    }

    /// `@jakarta.ejb.TransactionAttribute(SUPPORTS) Ejb3AnnotatedBean2`, plain on `getAge`.
    private Descriptor ejb3AnnotatedBean2()
    {
        return type("Ejb3AnnotatedBean2", TypeKind.class_, [ejb(TransactionAttributeType.SUPPORTS)],
                method("getName", ejb(TransactionAttributeType.SUPPORTS)), method("getAge", ejb()));
    }

    /// `Ejb3AnnotatedBean3 implements ITestEjb`: `getAge` takes the interface method's annotation; the interface's
    /// type-level one is not merged.
    private Descriptor ejb3AnnotatedBean3()
    {
        return type("Ejb3AnnotatedBean3", TypeKind.class_, null, method("getName"), method("getAge", ejb()));
    }

    @("AnnotationTransactionAttributeSourceTests.Ejb3AttributeTests.transactionAttributeDeclaredOnClassMethod")
    unittest
    {
        auto attributeSource = new DescriptorTransactionAttributeSource;
        auto getAgeAttr = getTransactionAttribute(attributeSource, ejb3AnnotatedBean1(), "getAge");
        assert(getAgeAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);
        auto getNameAttr = getTransactionAttribute(attributeSource, ejb3AnnotatedBean1(), "getName");
        assert(getNameAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_SUPPORTS);
    }

    @("AnnotationTransactionAttributeSourceTests.Ejb3AttributeTests.transactionAttributeDeclaredOnClass")
    unittest
    {
        auto attributeSource = new DescriptorTransactionAttributeSource;
        auto getAgeAttr = getTransactionAttribute(attributeSource, ejb3AnnotatedBean2(), "getAge");
        assert(getAgeAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);
        auto getNameAttr = getTransactionAttribute(attributeSource, ejb3AnnotatedBean2(), "getName");
        assert(getNameAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_SUPPORTS);
    }

    @("AnnotationTransactionAttributeSourceTests.Ejb3AttributeTests.transactionAttributeDeclaredOnInterface")
    unittest
    {
        auto attributeSource = new DescriptorTransactionAttributeSource;
        auto getAgeAttr = getTransactionAttribute(attributeSource, ejb3AnnotatedBean3(), "getAge");
        assert(getAgeAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);
        auto getNameAttr = getTransactionAttribute(attributeSource, ejb3AnnotatedBean3(), "getName");
        assert(getNameAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_SUPPORTS);
    }
}

version (FlintGroovy)
{
    // Gap: Groovy has no D counterpart (GroovyObject's synthetic methods must not be transactional).
    import flint.groovy.lang : GroovyObject;

    /// `@Transactional GroovyTestBean implements ITestBean1, GroovyObject`: the class-level advice applies to
    /// every method `ITestBean1` declares, but not to `GroovyObject`'s.
    private Descriptor groovyTestBean()
    {
        return type("GroovyTestBean", TypeKind.class_, [transactional(Transactional())],
                method("getAge", transactional(Transactional())), method("getName",
                    transactional(Transactional())), method("getMetaClass"));
    }

    @("AnnotationTransactionAttributeSourceTests.GroovyTests.transactionAttributeDeclaredOnGroovyClass")
    unittest
    {
        auto attributeSource = new DescriptorTransactionAttributeSource;
        auto getAgeAttr = getTransactionAttribute(attributeSource, groovyTestBean(), "getAge");
        assert(getAgeAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);
        auto getNameAttr = getTransactionAttribute(attributeSource, groovyTestBean(), "getName");
        assert(getNameAttr.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);
        const getMetaClassMethod = getMethod(groovyTestBean(), "getMetaClass");
        assert(attributeSource.getTransactionAttribute(getMetaClassMethod, groovyTestBean()) is null);
    }
}
