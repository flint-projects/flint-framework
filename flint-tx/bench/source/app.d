/// spring-tx's DataAccessUtils over java.util collections, and its DataAccessException hierarchy.
module app;

import flint.dao : EmptyResultDataAccessException;
import flint.dao.support : DataAccessUtils;
import flint.java.util : ArrayList;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

int main(string[] args)
{
    auto rows = new ArrayList!string();
    rows.add(args.length > 1 ? "Jean" : "George");
    string outcome = DataAccessUtils.singleResult(rows);
    try
    {
        DataAccessUtils.requiredSingleResult(new ArrayList!string());
    }
    catch (EmptyResultDataAccessException ex)
    {
        outcome ~= " " ~ cast(char)('0' + ex.getExpectedSize());
    }
    emit(outcome);
    return 0;
}
