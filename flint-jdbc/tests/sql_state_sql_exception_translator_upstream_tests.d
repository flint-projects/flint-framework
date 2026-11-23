/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/support/SQLStateSQLExceptionTranslatorTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: the companion of `translators.d`, which holds translateNullException,
translateWithinQualifiedBatch, translateWithinUnqualifiedBatch, translateUncategorized, invalidSqlStateCode and
malformedSqlStateCodes; its combined "SQL state classes and duplicate-key codes" test asserts the fifteen cases below
without naming them, so here each runs as its own labelled test. Java's `Class` is a `TypeInfo_Class` (R4).
+/
module flint.jdbc.sql_state_sql_exception_translator_upstream_tests;

import flint.dao;
import flint.java.sql : SQLException;
import flint.jdbc : BadSqlGrammarException;
import flint.jdbc.support : SQLExceptionTranslator, SQLStateSQLExceptionTranslator;

@safe:

private SQLExceptionTranslator translator()
{
    return new SQLStateSQLExceptionTranslator();
}

private void assertTranslation(string sqlState, const TypeInfo_Class dataAccessExceptionType)
{
    assertTranslation(new SQLException("reason", sqlState, 0), dataAccessExceptionType);
}

private void assertTranslation(string sqlState, int errorCode, const TypeInfo_Class dataAccessExceptionType)
{
    assertTranslation(new SQLException("reason", sqlState, errorCode), dataAccessExceptionType);
}

private void assertTranslation(SQLException ex, const TypeInfo_Class dataAccessExceptionType)
{
    auto dae = translator().translate("task", "SQL", ex);
    if (dataAccessExceptionType is null)
    {
        assert(dae is null, "Expected translation to null");
        return;
    }
    assert(dae !is null, "Specific translation must not result in null");
    assert(typeid(dae) is dataAccessExceptionType, "Wrong DataAccessException type returned: " ~ typeid(dae).name);
    assert(dae.getCause() is ex, "The exact same original SQLException must be preserved");
}

@("SQLStateSQLExceptionTranslatorTests.translateBadSqlGrammar")
unittest
{
    assertTranslation("07", typeid(BadSqlGrammarException));
}

@("SQLStateSQLExceptionTranslatorTests.translateDataIntegrityViolation")
unittest
{
    assertTranslation("23", typeid(DataIntegrityViolationException));
}

@("SQLStateSQLExceptionTranslatorTests.translateDuplicateKey")
unittest
{
    assertTranslation("23505", typeid(DuplicateKeyException));
}

@("SQLStateSQLExceptionTranslatorTests.translateDuplicateKeyOracle")
unittest
{
    assertTranslation("23000", 1, typeid(DuplicateKeyException));
}

@("SQLStateSQLExceptionTranslatorTests.translateDuplicateKeyMySQL")
unittest
{
    assertTranslation("23000", 1062, typeid(DuplicateKeyException));
}

@("SQLStateSQLExceptionTranslatorTests.translateDuplicateKeyMSSQL1")
unittest
{
    assertTranslation("23000", 2601, typeid(DuplicateKeyException));
}

@("SQLStateSQLExceptionTranslatorTests.translateDuplicateKeyMSSQL2")
unittest
{
    assertTranslation("23000", 2627, typeid(DuplicateKeyException));
}

@("SQLStateSQLExceptionTranslatorTests.translateDuplicateKeySapHana")
unittest
{
    // gh-31554
    assertTranslation("23000", 301, typeid(DuplicateKeyException));
}

@("SQLStateSQLExceptionTranslatorTests.translateDuplicateKeyInformix1")
unittest
{
    assertTranslation("23000", -239, typeid(DuplicateKeyException));
}

@("SQLStateSQLExceptionTranslatorTests.translateDuplicateKeyInformix2")
unittest
{
    assertTranslation("23000", -268, typeid(DuplicateKeyException));
}

@("SQLStateSQLExceptionTranslatorTests.translateDataAccessResourceFailure")
unittest
{
    assertTranslation("53", typeid(DataAccessResourceFailureException));
}

@("SQLStateSQLExceptionTranslatorTests.translateTransientDataAccessResourceFailure")
unittest
{
    assertTranslation("S1", typeid(TransientDataAccessResourceException));
}

@("SQLStateSQLExceptionTranslatorTests.translatePessimisticLockingFailure")
unittest
{
    assertTranslation("40", typeid(PessimisticLockingFailureException));
}

@("SQLStateSQLExceptionTranslatorTests.translateCannotAcquireLock")
unittest
{
    assertTranslation("40001", typeid(CannotAcquireLockException));
}

@("SQLStateSQLExceptionTranslatorTests.translateQueryTimeout")
unittest
{
    assertTranslation("57014", typeid(QueryTimeoutException));
}
