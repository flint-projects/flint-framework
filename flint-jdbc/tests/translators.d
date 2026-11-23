// Ported from spring-framework v7.1.0: spring-jdbc/src/test/java/org/springframework/jdbc/support/SQLStateSQLExceptionTranslatorTests.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
// Also ported: SQLExceptionSubclassTranslatorTests.java.
module flint.jdbc.translators_test;

import flint.dao;
import flint.java.lang : IllegalArgumentException;
import flint.java.sql;
import flint.jdbc : BadSqlGrammarException, UncategorizedSQLException;
import flint.jdbc.support;

@safe:

private void assertTranslation(DataAccessException dae, SQLException ex, const TypeInfo_Class type)
{
    assert(dae !is null, "Specific translation must not result in null");
    assert(typeid(dae) is type, "Wrong DataAccessException type returned: " ~ typeid(dae).name);
    assert(dae.getCause() is ex, "The exact same original SQLException must be preserved");
}

private void stateTranslation(SQLException ex, const TypeInfo_Class type)
{
    auto dae = new SQLStateSQLExceptionTranslator().translate("task", "SQL", ex);
    if (type is null)
    {
        assert(dae is null, "Expected translation to null");
        return;
    }
    assertTranslation(dae, ex, type);
}

private void stateTranslation(string sqlState, const TypeInfo_Class type)
{
    stateTranslation(new SQLException("reason", sqlState, 0), type);
}

private void stateTranslation(string sqlState, int errorCode, const TypeInfo_Class type)
{
    stateTranslation(new SQLException("reason", sqlState, errorCode), type);
}

private BatchUpdateException buildBatchUpdateException(string sqlState, SQLException next)
{
    auto ex = new BatchUpdateException("", sqlState, 0, null);
    ex.setNextException(next);
    return ex;
}

@("SQLStateSQLExceptionTranslatorTests.translateNullException")
unittest
{
    try
    {
        new SQLStateSQLExceptionTranslator().translate("", "", null);
        assert(false, "expected IllegalArgumentException");
    }
    catch (IllegalArgumentException)
    {
    }
}

@("SQLStateSQLExceptionTranslatorTests: SQL state classes and duplicate-key codes")
unittest
{
    // translateBadSqlGrammar, translateDataIntegrityViolation, translateDuplicateKey and its vendor variants,
    // translateDataAccessResourceFailure, translateTransientDataAccessResourceFailure,
    // translatePessimisticLockingFailure, translateCannotAcquireLock, translateQueryTimeout.
    stateTranslation("07", typeid(BadSqlGrammarException));
    stateTranslation("23", typeid(DataIntegrityViolationException));
    stateTranslation("23505", typeid(DuplicateKeyException));
    foreach (code; [1, 1062, 2601, 2627, 301, -239, -268])
        stateTranslation("23000", code, typeid(DuplicateKeyException));
    stateTranslation("53", typeid(DataAccessResourceFailureException));
    stateTranslation("S1", typeid(TransientDataAccessResourceException));
    stateTranslation("40", typeid(PessimisticLockingFailureException));
    stateTranslation("40001", typeid(CannotAcquireLockException));
    stateTranslation("57014", typeid(QueryTimeoutException));
}

@("SQLStateSQLExceptionTranslatorTests.translateWithinQualifiedBatch")
unittest
{
    stateTranslation(buildBatchUpdateException("JZ", new SQLException("", "23505", 0)), typeid(DuplicateKeyException));
}

@("SQLStateSQLExceptionTranslatorTests.translateWithinUnqualifiedBatch")
unittest
{
    stateTranslation(buildBatchUpdateException(null, new SQLException("", "23505", 0)), typeid(DuplicateKeyException));
}

@("SQLStateSQLExceptionTranslatorTests.translateUncategorized, invalidSqlStateCode, malformedSqlStateCodes")
unittest
{
    stateTranslation("00000000", null);
    stateTranslation("NO SUCH CODE", null);
    stateTranslation(cast(string) null, null);
    stateTranslation("", null);
    stateTranslation("I", null);
}

private void subclassTranslation(SQLException ex, const TypeInfo_Class type)
{
    assertTranslation(new SQLExceptionSubclassTranslator().translate("task", "SQL", ex), ex, type);
}

@("SQLExceptionSubclassTranslatorTests.exceptionClassTranslation")
unittest
{
    subclassTranslation(new SQLDataException("", "", 0), typeid(DataIntegrityViolationException));
    subclassTranslation(new SQLFeatureNotSupportedException("", "", 0), typeid(InvalidDataAccessApiUsageException));
    subclassTranslation(new SQLIntegrityConstraintViolationException("", "", 0),
            typeid(DataIntegrityViolationException));
    subclassTranslation(new SQLIntegrityConstraintViolationException("", "23505", 0), typeid(DuplicateKeyException));
    foreach (code; [1, 1062, 2601, 2627])
        subclassTranslation(new SQLIntegrityConstraintViolationException("", "23000", code),
                typeid(DuplicateKeyException));
    subclassTranslation(new SQLInvalidAuthorizationSpecException("", "", 0),
            typeid(PermissionDeniedDataAccessException));
    subclassTranslation(new SQLNonTransientConnectionException("", "", 0), typeid(DataAccessResourceFailureException));
    subclassTranslation(new SQLRecoverableException("", "", 0), typeid(RecoverableDataAccessException));
    subclassTranslation(new SQLSyntaxErrorException("", "", 0), typeid(BadSqlGrammarException));
    subclassTranslation(new SQLTimeoutException("", "", 0), typeid(QueryTimeoutException));
    subclassTranslation(new SQLTransactionRollbackException("", "", 0), typeid(PessimisticLockingFailureException));
    subclassTranslation(new SQLTransactionRollbackException("", "40001", 0), typeid(CannotAcquireLockException));
    subclassTranslation(new SQLTransientConnectionException("", "", 0), typeid(TransientDataAccessResourceException));
}

@("SQLExceptionSubclassTranslatorTests.batchExceptionTranslation")
unittest
{
    subclassTranslation(buildBatchUpdateException("JZ",
            new SQLIntegrityConstraintViolationException("", "23505", 0)), typeid(DuplicateKeyException));
    subclassTranslation(buildBatchUpdateException(null,
            new SQLIntegrityConstraintViolationException("", "23505", 0)), typeid(DuplicateKeyException));
}

@("SQLExceptionSubclassTranslatorTests.fallbackStateTranslation")
unittest
{
    // 07xxx will be bad grammar picked up by the fallback SQLState translator
    subclassTranslation(new SQLException("", "07xxx", 666_666_666), typeid(BadSqlGrammarException));
    // and 08xxx will be data resource failure (non-transient) picked up by the fallback SQLState translator
    subclassTranslation(new SQLException("", "08xxx", 666_666_666), typeid(DataAccessResourceFailureException));
}

@("UncategorizedSQLException and BadSqlGrammarException describe the failure as Spring does")
unittest
{
    auto ex = new SQLException("syntax error at or near \"SELEC\"", "42601", 0);
    auto uncategorized = new UncategorizedSQLException("StatementCallback", "SELEC 1", ex);
    assert(uncategorized.getMessage() == "StatementCallback; uncategorized SQLException for SQL [SELEC 1]; "
            ~ "SQL state [42601]; error code [0]; syntax error at or near \"SELEC\"");
    assert(uncategorized.getSQLException() is ex && uncategorized.getSql() == "SELEC 1");
    auto grammar = new BadSqlGrammarException("PreparedStatementCallback", "SELEC 1", ex);
    assert(grammar.getMessage() == "PreparedStatementCallback; bad SQL grammar [SELEC 1]");
    assert(grammar.getSQLException() is ex);
}
