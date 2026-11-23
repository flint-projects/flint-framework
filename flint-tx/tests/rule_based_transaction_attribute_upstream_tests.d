/++
Ported from spring-projects/spring-framework v7.1.0,
spring-tx/src/test/java/org/springframework/transaction/interceptor/RuleBasedTransactionAttributeTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: only the test that `rollback_rules.d` (module `flint.transaction.rollback_rules_test`)
does not already cover by name. Also ported: MyRuntimeException.java from the same package.
+/
module flint.transaction.rule_based_transaction_attribute_upstream_tests;

@safe:

version (FlintConfiguredTransactionAttributes)
{
    // Gap: TransactionAttributeEditor (text-configured transaction attributes) is not ported.
    import flint.core : NestedRuntimeException;
    import flint.java.io : IOException;
    import flint.java.lang : RuntimeException;
    import flint.java.util : ArrayList, List;
    import flint.transaction : TransactionDefinition;
    import flint.transaction.interceptor;

    /// `MyRuntimeException`.
    private class MyRuntimeException : NestedRuntimeException
    {
        this()
        {
            super("");
        }
    }

    @("RuleBasedTransactionAttributeTests.toStringMatchesEditor")
    unittest
    {
        List!RollbackRuleAttribute list = new ArrayList!RollbackRuleAttribute;
        list.add(new NoRollbackRuleAttribute("Throwable"));
        auto rta = new RuleBasedTransactionAttribute(TransactionDefinition.PROPAGATION_REQUIRED, list);

        auto tae = new TransactionAttributeEditor;
        tae.setAsText(rta.toString());
        rta = cast(RuleBasedTransactionAttribute) tae.getValue();

        assert(!rta.rollbackOn(new Throwable("")));
        assert(!rta.rollbackOn(new RuntimeException()));
        assert(!rta.rollbackOn(new MyRuntimeException()));
        assert(!rta.rollbackOn(new Exception("")));
        assert(!rta.rollbackOn(new IOException()));
    }
}
