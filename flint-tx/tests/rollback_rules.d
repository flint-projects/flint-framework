// Ported from spring-framework v7.1.0: spring-tx/src/test/java/org/springframework/transaction/interceptor/RollbackRuleAttributeTests.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: RuleBasedTransactionAttributeTests.java, and MyRuntimeException.java from the same package.
module flint.transaction.rollback_rules_test;

import flint.core : NestedRuntimeException;
import flint.java.io : IOException;
import flint.java.lang : IllegalArgumentException, RuntimeException;
import flint.java.util : ArrayList, Collections, List;
import flint.transaction : TransactionDefinition;
import flint.transaction.interceptor;

@safe:

/// `MyRuntimeException`: Exception -> RuntimeException -> NestedRuntimeException -> MyRuntimeException.
private class MyRuntimeException : NestedRuntimeException
{
    this()
    {
        super("my runtime exception");
    }
}

private class EnclosingException : RuntimeException
{
    static class NestedException : RuntimeException
    {
    }
}

private class MyException : RuntimeException
{
}

// Name intentionally starts with MyException (including module) but does NOT extend MyException.
private class MyException2 : RuntimeException
{
}

/// A stand-in for Spring's FatalBeanException, which flint.beans does not have yet: another nested runtime type.
private class FatalFailure : NestedRuntimeException
{
    this()
    {
        super(null);
    }
}

/// A stand-in for java.rmi.RemoteException: a checked exception (a D `Exception` outside `RuntimeException`).
private class RemoteException : IOException
{
}

private void throwsIllegalArgument(scope void delegate() @safe action)
{
    try
    {
        action();
        assert(false, "expected IllegalArgumentException");
    }
    catch (IllegalArgumentException)
    {
    }
}

// RollbackRuleAttributeTests.ExceptionPatternTests

@("RollbackRuleAttributeTests.ExceptionPatternTests.constructorPreconditions")
unittest
{
    throwsIllegalArgument(() { new RollbackRuleAttribute(cast(string) null); });
}

@("RollbackRuleAttributeTests.ExceptionPatternTests.notFound")
unittest
{
    auto rr = new RollbackRuleAttribute(typeid(IOException).name);
    assert(rr.getDepth(new MyRuntimeException) == -1);
}

@("RollbackRuleAttributeTests.ExceptionPatternTests.foundImmediatelyWhenDirectMatch")
unittest
{
    auto rr = new RollbackRuleAttribute(typeid(Exception).name);
    assert(rr.getDepth(new Exception("x")) == 0);
}

@("RollbackRuleAttributeTests.ExceptionPatternTests."
        ~ "foundImmediatelyWhenExceptionThrownIsNestedTypeOfRegisteredException")
unittest
{
    auto rr = new RollbackRuleAttribute(typeid(EnclosingException).name);
    assert(rr.getDepth(new EnclosingException.NestedException) == 0);
}

@("RollbackRuleAttributeTests.ExceptionPatternTests."
        ~ "foundImmediatelyWhenNameOfExceptionThrownStartsWithNameOfRegisteredException")
unittest
{
    // Precondition for this use case.
    assert(!typeid(MyException).isBaseOf(typeid(MyException2)));
    auto rr = new RollbackRuleAttribute(typeid(MyException).name);
    assert(rr.getDepth(new MyException2) == 0);
}

@("RollbackRuleAttributeTests.ExceptionPatternTests.foundInSuperclassHierarchy")
unittest
{
    auto rr = new RollbackRuleAttribute(typeid(Exception).name);
    // Exception -> RuntimeException -> NestedRuntimeException -> MyRuntimeException
    assert(rr.getDepth(new MyRuntimeException) == 3);
}

@("RollbackRuleAttributeTests.ExceptionPatternTests.alwaysFoundForThrowable")
unittest
{
    auto rr = new RollbackRuleAttribute(typeid(Throwable).name);
    assert(rr.getDepth(new MyRuntimeException) > 0);
    assert(rr.getDepth(new IOException) > 0);
    assert(rr.getDepth(new FatalFailure) > 0);
    assert(rr.getDepth(new RuntimeException) > 0);
}

// RollbackRuleAttributeTests.ExceptionTypeTests

@("RollbackRuleAttributeTests.ExceptionTypeTests.constructorPreconditions")
unittest
{
    throwsIllegalArgument(() { new RollbackRuleAttribute(typeid(Object)); });
    throwsIllegalArgument(() { new RollbackRuleAttribute(cast(TypeInfo_Class) null); });
}

@("RollbackRuleAttributeTests.ExceptionTypeTests.notFound")
unittest
{
    auto rr = new RollbackRuleAttribute(typeid(IOException));
    assert(rr.getDepth(new MyRuntimeException) == -1);
}

@("RollbackRuleAttributeTests.ExceptionTypeTests.notFoundWhenNameOfExceptionThrownStartsWithNameOfRegisteredException")
unittest
{
    // Precondition for this use case.
    assert(!typeid(MyException).isBaseOf(typeid(MyException2)));
    auto rr = new RollbackRuleAttribute(typeid(MyException));
    assert(rr.getDepth(new MyException2) == -1);
}

@("RollbackRuleAttributeTests.ExceptionTypeTests.notFoundWhenExceptionThrownIsNestedTypeOfRegisteredException")
unittest
{
    auto rr = new RollbackRuleAttribute(typeid(EnclosingException));
    assert(rr.getDepth(new EnclosingException.NestedException) == -1);
}

@("RollbackRuleAttributeTests.ExceptionTypeTests.foundImmediatelyWhenDirectMatch")
unittest
{
    auto rr = new RollbackRuleAttribute(typeid(Exception));
    assert(rr.getDepth(new Exception("x")) == 0);
}

@("RollbackRuleAttributeTests.ExceptionTypeTests.foundInSuperclassHierarchy")
unittest
{
    auto rr = new RollbackRuleAttribute(typeid(Exception));
    // Exception -> RuntimeException -> NestedRuntimeException -> MyRuntimeException
    assert(rr.getDepth(new MyRuntimeException) == 3);
}

@("RollbackRuleAttributeTests.ExceptionTypeTests.alwaysFoundForThrowable")
unittest
{
    auto rr = new RollbackRuleAttribute(typeid(Throwable));
    assert(rr.getDepth(new MyRuntimeException) > 0);
    assert(rr.getDepth(new IOException) > 0);
    assert(rr.getDepth(new FatalFailure) > 0);
    assert(rr.getDepth(new RuntimeException) > 0);
}

// RuleBasedTransactionAttributeTests

private List!RollbackRuleAttribute rules(RollbackRuleAttribute[] items...)
{
    auto list = new ArrayList!RollbackRuleAttribute;
    foreach (item; items)
        list.add(item);
    return list;
}

@("RuleBasedTransactionAttributeTests.defaultRule")
unittest
{
    auto rta = new RuleBasedTransactionAttribute;
    assert(rta.rollbackOn(new RuntimeException));
    assert(rta.rollbackOn(new MyRuntimeException));
    assert(!rta.rollbackOn(new Exception("x")));
    assert(!rta.rollbackOn(new IOException));
}

@("RuleBasedTransactionAttributeTests.ruleForRollbackOnChecked")
unittest
{
    auto rta = new RuleBasedTransactionAttribute(TransactionDefinition.PROPAGATION_REQUIRED,
            rules(new RollbackRuleAttribute(typeid(IOException).name)));
    assert(rta.rollbackOn(new RuntimeException));
    assert(rta.rollbackOn(new MyRuntimeException));
    assert(!rta.rollbackOn(new Exception("x")));
    // Check that default behavior is overridden
    assert(rta.rollbackOn(new IOException));
}

@("RuleBasedTransactionAttributeTests.ruleForCommitOnUnchecked")
unittest
{
    auto rta = new RuleBasedTransactionAttribute(TransactionDefinition.PROPAGATION_REQUIRED,
            rules(new NoRollbackRuleAttribute(typeid(MyRuntimeException)
                .name), new RollbackRuleAttribute(typeid(IOException).name)));
    assert(rta.rollbackOn(new RuntimeException));
    // Check default behavior is overridden
    assert(!rta.rollbackOn(new MyRuntimeException));
    assert(!rta.rollbackOn(new Exception("x")));
    // Check that default behavior is overridden
    assert(rta.rollbackOn(new IOException));
}

private void doTestRuleForSelectiveRollbackOnChecked(RuleBasedTransactionAttribute rta)
{
    assert(rta.rollbackOn(new RuntimeException));
    // Check default behavior is overridden
    assert(!rta.rollbackOn(new Exception("x")));
    // Check that default behavior is overridden
    assert(rta.rollbackOn(new RemoteException));
}

@("RuleBasedTransactionAttributeTests.ruleForSelectiveRollbackOnCheckedWithString")
unittest
{
    auto list = rules(new RollbackRuleAttribute(typeid(RemoteException).name));
    doTestRuleForSelectiveRollbackOnChecked(
            new RuleBasedTransactionAttribute(TransactionDefinition.PROPAGATION_REQUIRED, list));
}

@("RuleBasedTransactionAttributeTests.ruleForSelectiveRollbackOnCheckedWithClass")
unittest
{
    auto list = Collections.singletonList!RollbackRuleAttribute(new RollbackRuleAttribute(typeid(RemoteException)));
    doTestRuleForSelectiveRollbackOnChecked(
            new RuleBasedTransactionAttribute(TransactionDefinition.PROPAGATION_REQUIRED, list));
}

@("RuleBasedTransactionAttributeTests.ruleForCommitOnSubclassOfChecked")
unittest
{
    // Note that it's important to ensure that we have this as a fully-qualified class name: otherwise it will
    // match everything! D's Exception is object.Exception.
    auto rta = new RuleBasedTransactionAttribute(TransactionDefinition.PROPAGATION_REQUIRED,
            rules(new RollbackRuleAttribute("object.Exception"), new NoRollbackRuleAttribute("IOException")));
    assert(rta.rollbackOn(new RuntimeException));
    assert(rta.rollbackOn(new Exception("x")));
    // Check that default behavior is overridden
    assert(!rta.rollbackOn(new IOException));
}

@("RuleBasedTransactionAttributeTests.rollbackNever")
unittest
{
    auto rta = new RuleBasedTransactionAttribute(TransactionDefinition.PROPAGATION_REQUIRED,
            rules(new NoRollbackRuleAttribute("Throwable")));
    assert(!rta.rollbackOn(new Throwable("x")));
    assert(!rta.rollbackOn(new RuntimeException));
    assert(!rta.rollbackOn(new MyRuntimeException));
    assert(!rta.rollbackOn(new Exception("x")));
    assert(!rta.rollbackOn(new IOException));
}

// RuleBasedTransactionAttributeTests.toStringMatchesEditor waits for TransactionAttributeEditor (flint.beans).

private class MyBusinessException : Exception
{
    this()
    {
        super("business");
    }
}

private final class MyBusinessWarningException : MyBusinessException
{
}

@("RuleBasedTransactionAttributeTests.conflictingRulesToDetermineExactContract")
unittest
{
    auto rta = new RuleBasedTransactionAttribute(TransactionDefinition.PROPAGATION_REQUIRED,
            rules(new NoRollbackRuleAttribute(typeid(MyBusinessWarningException)),
                new RollbackRuleAttribute(typeid(MyBusinessException))));
    assert(rta.rollbackOn(new MyBusinessException));
    assert(!rta.rollbackOn(new MyBusinessWarningException));
}

@("RuleBasedTransactionAttribute describes its rules and copies them")
unittest
{
    auto rta = new RuleBasedTransactionAttribute(TransactionDefinition.PROPAGATION_REQUIRED,
            rules(new NoRollbackRuleAttribute("Throwable"), new RollbackRuleAttribute("flint.java.io.IOException")));
    rta.setQualifier("orders");
    assert(rta.toString() == "PROPAGATION_REQUIRED,ISOLATION_DEFAULT; 'orders',+Throwable,-flint.java.io.IOException");
    auto copy = new RuleBasedTransactionAttribute(rta);
    assert(copy.getRollbackRules().size() == 2 && copy.getRollbackRules() !is rta.getRollbackRules());
    assert(new RollbackRuleAttribute("A") == new NoRollbackRuleAttribute("A"));
    assert(new NoRollbackRuleAttribute("A").toString() == "NoRollbackRuleAttribute with pattern [A]");
    assert(RollbackRuleAttribute.ROLLBACK_ON_RUNTIME_EXCEPTIONS()
            .getExceptionName() == "flint.java.lang.RuntimeException");
}

@("DefaultTransactionAttribute resolves its timeout, qualifier and labels")
unittest
{
    auto attribute = new DefaultTransactionAttribute;
    attribute.setTimeoutString("${tx.timeout}");
    attribute.setQualifier("${tx.manager}");
    auto labels = new ArrayList!string;
    labels.add("${tx.label}");
    attribute.setLabels(labels);
    attribute.resolveAttributeStrings((string value) => value == "${tx.timeout}"
            ? "30" : value == "${tx.manager}" ? "ordersTx" : "nightly");
    assert(attribute.getTimeout() == 30 && attribute.getQualifier() == "ordersTx");
    assert(attribute.getLabels().size() == 1 && attribute.getLabels().contains("nightly"));

    attribute.setTimeoutString("soon");
    throwsIllegalArgument(() { attribute.resolveAttributeStrings(null); });
}
