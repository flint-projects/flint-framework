/// spring-tx's DataAccessUtils over java.util collections, and its DataAccessException hierarchy.
module app;

import flint.dao : EmptyResultDataAccessException;
import flint.dao.support : DataAccessUtils;
import flint.java.util : ArrayList;
import std.stdio : writeln;

@safe:

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
    writeln(outcome);
    return 0;
}
