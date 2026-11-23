/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/datasource/init/CompositeDatabasePopulatorTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: the Mockito connection is a `BlackHole!Connection`, and each mocked populator records
the connections it populated, in place of `verify(...).populate(connection)`. `scripts.d` also checks a composite's
ordering against a recording connection.
+/
module flint.jdbc.composite_database_populator_tests;

import flint.java.sql : Connection;
import flint.jdbc.datasource.init : CompositeDatabasePopulator, DatabasePopulator;
import std.typecons : BlackHole;

@safe:

/// The mocked `DatabasePopulator`: remembers every connection `populate` was called with.
private final class RecordingDatabasePopulator : DatabasePopulator
{
    Connection[] populated;

    override void populate(Connection connection)
    {
        populated ~= connection;
    }

    /// `verify(populator, times(n)).populate(connection)`.
    void verifyPopulate(size_t times, Connection connection)
    {
        size_t count;
        foreach (each; populated)
            if (each is connection)
                ++count;
        assert(count == times, "populate(connection) calls");
    }
}

private struct Mocks
{
    Connection mockedConnection;
    RecordingDatabasePopulator mockedDatabasePopulator1;
    RecordingDatabasePopulator mockedDatabasePopulator2;

    static Mocks create()
    {
        return Mocks(new BlackHole!Connection, new RecordingDatabasePopulator, new RecordingDatabasePopulator);
    }
}

@("CompositeDatabasePopulatorTests.addPopulators")
unittest
{
    auto mocks = Mocks.create();
    auto populator = new CompositeDatabasePopulator();
    populator.addPopulators(mocks.mockedDatabasePopulator1, mocks.mockedDatabasePopulator2);

    populator.populate(mocks.mockedConnection);

    mocks.mockedDatabasePopulator1.verifyPopulate(1, mocks.mockedConnection);
    mocks.mockedDatabasePopulator2.verifyPopulate(1, mocks.mockedConnection);
}

@("CompositeDatabasePopulatorTests.setPopulatorsWithMultiple")
unittest
{
    auto mocks = Mocks.create();
    auto populator = new CompositeDatabasePopulator();
    populator.setPopulators(mocks.mockedDatabasePopulator1, mocks.mockedDatabasePopulator2); // multiple

    populator.populate(mocks.mockedConnection);

    mocks.mockedDatabasePopulator1.verifyPopulate(1, mocks.mockedConnection);
    mocks.mockedDatabasePopulator2.verifyPopulate(1, mocks.mockedConnection);
}

@("CompositeDatabasePopulatorTests.setPopulatorsForOverride")
unittest
{
    auto mocks = Mocks.create();
    auto populator = new CompositeDatabasePopulator();
    populator.setPopulators(mocks.mockedDatabasePopulator1);
    populator.setPopulators(mocks.mockedDatabasePopulator2); // override

    populator.populate(mocks.mockedConnection);

    mocks.mockedDatabasePopulator1.verifyPopulate(0, mocks.mockedConnection);
    mocks.mockedDatabasePopulator2.verifyPopulate(1, mocks.mockedConnection);
}

@("CompositeDatabasePopulatorTests.constructWithVarargs")
unittest
{
    auto mocks = Mocks.create();
    auto populator = new CompositeDatabasePopulator(mocks.mockedDatabasePopulator1, mocks.mockedDatabasePopulator2);

    populator.populate(mocks.mockedConnection);

    mocks.mockedDatabasePopulator1.verifyPopulate(1, mocks.mockedConnection);
    mocks.mockedDatabasePopulator2.verifyPopulate(1, mocks.mockedConnection);
}

version (FlintCompositePopulatorCollection)
{
    // Gap: CompositeDatabasePopulator has no constructor taking a Collection<DatabasePopulator>, only varargs.
    @("CompositeDatabasePopulatorTests.constructWithCollection")
    unittest
    {
        import flint.java.util : LinkedHashSet, Set;

        auto mocks = Mocks.create();
        Set!DatabasePopulator populators = new LinkedHashSet!DatabasePopulator;
        populators.add(mocks.mockedDatabasePopulator1);
        populators.add(mocks.mockedDatabasePopulator2);

        auto populator = new CompositeDatabasePopulator(populators);
        populator.populate(mocks.mockedConnection);

        mocks.mockedDatabasePopulator1.verifyPopulate(1, mocks.mockedConnection);
        mocks.mockedDatabasePopulator2.verifyPopulate(1, mocks.mockedConnection);
    }
}
