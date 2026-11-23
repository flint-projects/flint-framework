/// spring-core's NestedRuntimeException: a cause chain, its root cause and most specific cause.
module app;

import flint.core : NestedRuntimeException;
import flint.java.lang : IllegalArgumentException, RuntimeException;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

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
    emit(failure.getRootCause().msg ~ (same ? " root" : " other"));
    return 0;
}
