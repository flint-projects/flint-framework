/// spring-core's NestedRuntimeException: a cause chain, its root cause and most specific cause.
module app;

import flint.core : NestedRuntimeException;
import flint.java.lang : IllegalArgumentException, RuntimeException;
import std.stdio : writeln;

@safe:

private final class DataFailure : NestedRuntimeException
{
    this(string msg, Throwable cause = null)
    {
        super(msg, cause);
    }
}

int main(string[] args)
{
    auto root = new IllegalArgumentException(args.length > 1 ? "bad column x" : "bad column");
    auto failure = new DataFailure("query failed", new RuntimeException("statement failed", root));
    const same = failure.getRootCause() is root && failure.getMostSpecificCause() is root;
    writeln(failure.getRootCause().msg ~ (same ? " root" : " other"));
    return 0;
}
