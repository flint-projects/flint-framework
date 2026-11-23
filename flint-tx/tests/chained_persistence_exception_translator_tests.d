/++
Ported from spring-projects/spring-framework v7.1.0,
spring-tx/src/test/java/org/springframework/dao/support/ChainedPersistenceExceptionTranslatorTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: AssertJ's `as` descriptions are assertion messages. Also ported:
MapPersistenceExceptionTranslator.java.
+/
module flint.dao.chained_persistence_exception_translator_tests;

import flint.dao : DataAccessException, InvalidDataAccessApiUsageException, OptimisticLockingFailureException;
import flint.dao.support : ChainedPersistenceExceptionTranslator, DataAccessUtils, PersistenceExceptionTranslator;
import flint.java.lang : RuntimeException;

@safe:

/// `MapPersistenceExceptionTranslator`: translates the exceptions it was given, by identity.
private final class MapPersistenceExceptionTranslator : PersistenceExceptionTranslator
{
    private RuntimeException[] sources;
    private DataAccessException[] targets;

    void addTranslation(RuntimeException in_, DataAccessException out_)
    {
        sources ~= in_;
        targets ~= out_;
    }

    override DataAccessException translateExceptionIfPossible(RuntimeException ex)
    {
        foreach (index, source; sources)
            if (source is ex)
                return targets[index];
        return null;
    }
}

@("ChainedPersistenceExceptionTranslatorTests.empty")
unittest
{
    auto pet = new ChainedPersistenceExceptionTranslator;
    auto in_ = new RuntimeException("in");
    assert(DataAccessUtils.translateIfNecessary(in_, pet) is in_);
}

@("ChainedPersistenceExceptionTranslatorTests.exceptionTranslationWithTranslation")
unittest
{
    auto mpet1 = new MapPersistenceExceptionTranslator;
    auto in1 = new RuntimeException("in");
    auto out1 = new InvalidDataAccessApiUsageException("out");
    auto out2 = new InvalidDataAccessApiUsageException("out");
    mpet1.addTranslation(in1, out1);

    auto chainedPet1 = new ChainedPersistenceExceptionTranslator;
    assert(DataAccessUtils.translateIfNecessary(in1, chainedPet1) is in1, "Should not translate yet");
    chainedPet1.addDelegate(mpet1);
    assert(DataAccessUtils.translateIfNecessary(in1, chainedPet1) is out1, "Should now translate");

    // Now add a new translator and verify it wins
    auto mpet2 = new MapPersistenceExceptionTranslator;
    mpet2.addTranslation(in1, out2);
    chainedPet1.addDelegate(mpet2);
    assert(DataAccessUtils.translateIfNecessary(in1, chainedPet1) is out1,
            "Should still translate the same due to ordering");

    auto chainedPet2 = new ChainedPersistenceExceptionTranslator;
    chainedPet2.addDelegate(mpet2);
    chainedPet2.addDelegate(mpet1);
    assert(DataAccessUtils.translateIfNecessary(in1, chainedPet2) is out2,
            "Should translate differently due to ordering");

    auto in2 = new RuntimeException("in2");
    auto out3 = new OptimisticLockingFailureException("out2");
    assert(chainedPet2.translateExceptionIfPossible(in2) is null);
    auto mpet3 = new MapPersistenceExceptionTranslator;
    mpet3.addTranslation(in2, out3);
    chainedPet2.addDelegate(mpet3);
    assert(chainedPet2.translateExceptionIfPossible(in2) is out3);
}
