/++
Ported from spring-projects/spring-framework v7.1.0,
spring-tx/src/test/java/org/springframework/transaction/interceptor/TransactionAttributeSourceTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: a `Method` is the `MethodDescriptor` Flint AOT emits for it, and `Properties` are
`flint.java.util.Properties`.
+/
module flint.transaction.transaction_attribute_source_tests;

@safe:

version (FlintConfiguredTransactionAttributes)
{
    // Gap: MatchAlwaysTransactionAttributeSource and NameMatchTransactionAttributeSource are not ported.
    import flint.engine.aot.descriptor : MethodDescriptor;
    import flint.java.util : Properties;
    import flint.transaction : TransactionDefinition;
    import flint.transaction.interceptor;

    /// `Class.getMethod(name)`: the descriptor of the method called `name`.
    private const(MethodDescriptor)* getMethod(string name)
    {
        auto method = new MethodDescriptor;
        method.name = name;
        return method;
    }

    @("TransactionAttributeSourceTests.matchAlwaysTransactionAttributeSource")
    unittest
    {
        auto tas = new MatchAlwaysTransactionAttributeSource;
        auto ta = tas.getTransactionAttribute(getMethod("hashCode"), null);
        assert(ta !is null);
        assert(ta.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);

        tas.setTransactionAttribute(new DefaultTransactionAttribute(TransactionDefinition.PROPAGATION_SUPPORTS));
        ta = tas.getTransactionAttribute(getMethod("getMessage"), null);
        assert(ta !is null);
        assert(ta.getPropagationBehavior() == TransactionDefinition.PROPAGATION_SUPPORTS);
    }

    @("TransactionAttributeSourceTests.nameMatchTransactionAttributeSourceWithStarAtStartOfMethodName")
    unittest
    {
        auto tas = new NameMatchTransactionAttributeSource;
        auto attributes = new Properties;
        attributes.put("*ashCode", "PROPAGATION_REQUIRED");
        tas.setProperties(attributes);
        auto ta = tas.getTransactionAttribute(getMethod("hashCode"), null);
        assert(ta !is null);
        assert(ta.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);
    }

    @("TransactionAttributeSourceTests.nameMatchTransactionAttributeSourceWithStarAtEndOfMethodName")
    unittest
    {
        auto tas = new NameMatchTransactionAttributeSource;
        auto attributes = new Properties;
        attributes.put("hashCod*", "PROPAGATION_REQUIRED");
        tas.setProperties(attributes);
        auto ta = tas.getTransactionAttribute(getMethod("hashCode"), null);
        assert(ta !is null);
        assert(ta.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED);
    }

    @("TransactionAttributeSourceTests.nameMatchTransactionAttributeSourceMostSpecificMethodNameIsDefinitelyMatched")
    unittest
    {
        auto tas = new NameMatchTransactionAttributeSource;
        auto attributes = new Properties;
        attributes.put("*", "PROPAGATION_REQUIRED");
        attributes.put("hashCode", "PROPAGATION_MANDATORY");
        tas.setProperties(attributes);
        auto ta = tas.getTransactionAttribute(getMethod("hashCode"), null);
        assert(ta !is null);
        assert(ta.getPropagationBehavior() == TransactionDefinition.PROPAGATION_MANDATORY);
    }

    @("TransactionAttributeSourceTests.nameMatchTransactionAttributeSourceWithEmptyMethodName")
    unittest
    {
        auto tas = new NameMatchTransactionAttributeSource;
        auto attributes = new Properties;
        attributes.put("", "PROPAGATION_MANDATORY");
        tas.setProperties(attributes);
        auto ta = tas.getTransactionAttribute(getMethod("hashCode"), null);
        assert(ta is null);
    }
}
