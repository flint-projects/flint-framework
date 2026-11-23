module flint.dao.dao_exceptions_test;

import flint.core : NestedRuntimeException;
import flint.dao;
import flint.java.lang : IllegalStateException, RuntimeException;

@safe:

@("the data access exceptions keep Spring's hierarchy")
unittest
{
    static assert(is(DataAccessException : NestedRuntimeException) && is(NestedRuntimeException : RuntimeException));
    static assert(is(DuplicateKeyException : DataIntegrityViolationException));
    static assert(is(DataIntegrityViolationException : NonTransientDataAccessException));
    static assert(is(EmptyResultDataAccessException : IncorrectResultSizeDataAccessException));
    static assert(is(IncorrectResultSizeDataAccessException : DataRetrievalFailureException));
    static assert(is(CannotAcquireLockException : PessimisticLockingFailureException));
    static assert(is(PessimisticLockingFailureException : ConcurrencyFailureException));
    static assert(is(OptimisticLockingFailureException : ConcurrencyFailureException));
    static assert(is(ConcurrencyFailureException : TransientDataAccessException));
    static assert(is(QueryTimeoutException : TransientDataAccessException));
    static assert(is(TypeMismatchDataAccessException : InvalidDataAccessResourceUsageException));
    static assert(is(IncorrectUpdateSemanticsDataAccessException : InvalidDataAccessResourceUsageException));
    static assert(is(DataAccessResourceFailureException : NonTransientDataAccessResourceException));
    static assert(is(RecoverableDataAccessException : DataAccessException));
    static assert(__traits(isAbstractClass, DataAccessException));
    static assert(__traits(isAbstractClass, UncategorizedDataAccessException));
    static assert(!__traits(isAbstractClass, DuplicateKeyException));
}

@("an exception keeps its message and Java cause")
unittest
{
    auto cause = new IllegalStateException("socket");
    auto ex = new DuplicateKeyException("duplicate key value", cause);
    assert(ex.getMessage() == "duplicate key value" && ex.getCause() is cause);
    assert(ex.getRootCause() is cause && ex.contains!IllegalStateException());
    assert(new QueryTimeoutException("slow").getCause() is null);
    assert(new PermissionDeniedDataAccessException("denied", cause).getCause() is cause);
}

@("result-size exceptions describe the sizes")
unittest
{
    auto expected = new IncorrectResultSizeDataAccessException(1);
    assert(expected.getMessage() == "Incorrect result size: expected 1");
    assert(expected.getExpectedSize() == 1 && expected.getActualSize() == -1);

    auto both = new IncorrectResultSizeDataAccessException(1, 12);
    assert(both.getMessage() == "Incorrect result size: expected 1, actual 12");
    assert(both.getActualSize() == 12);

    auto negative = new IncorrectResultSizeDataAccessException(-3, -20);
    assert(negative.getMessage() == "Incorrect result size: expected -3, actual -20");

    auto custom = new IncorrectResultSizeDataAccessException("too many", 1, 3, new RuntimeException("x"));
    assert(custom.getMessage() == "too many" && custom.getActualSize() == 3 && custom.getCause() !is null);
    assert(new IncorrectResultSizeDataAccessException("one", 1).getActualSize() == -1);

    auto empty = new EmptyResultDataAccessException(1);
    assert(empty.getMessage() == "Incorrect result size: expected 1, actual 0");
    assert(empty.getExpectedSize() == 1 && empty.getActualSize() == 0);
    assert(new EmptyResultDataAccessException("none", 2).getActualSize() == 0);
}

@("IncorrectUpdateSemanticsDataAccessException reports that data was updated")
unittest
{
    assert(new IncorrectUpdateSemanticsDataAccessException("two rows").wasDataUpdated());
}
