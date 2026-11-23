/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/datasource/init/ResourceDatabasePopulatorTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: the mocked scripts are `ByteArrayResource`s; the Java varargs `Resource...` is D's
typesafe variadic `Resource[]...`. `scripts.d` also runs a populator end to end against a recording connection.
+/
module flint.jdbc.resource_database_populator_tests;

import flint.core.io : ByteArrayResource, Resource;
import flint.java.lang : IllegalArgumentException;
import flint.jdbc.datasource.init : ResourceDatabasePopulator;

@safe:

private Resource script(string name)
{
    return new ByteArrayResource(cast(immutable(ubyte)[]) "select 1;", name);
}

private Resource script1()
{
    return script("script1");
}

private Resource script2()
{
    return script("script2");
}

private Resource script3()
{
    return script("script3");
}

private void assertThrowsIllegalArgument(scope void delegate() @safe action)
{
    try
    {
        action();
        assert(false, "expected IllegalArgumentException");
    }
    catch (IllegalArgumentException)
    {
    }
}

@("ResourceDatabasePopulatorTests.constructWithNullResource")
unittest
{
    assertThrowsIllegalArgument(() { new ResourceDatabasePopulator(cast(Resource) null); });
}

version (FlintNullVarargsArray)
{
    // Gap: a null D array is the empty array, so a null Resource[] cannot be told apart from no scripts.
    @("ResourceDatabasePopulatorTests.constructWithNullResourceArray")
    unittest
    {
        assertThrowsIllegalArgument(() { new ResourceDatabasePopulator(cast(Resource[]) null); });
    }
}

@("ResourceDatabasePopulatorTests.constructWithResource")
unittest
{
    auto databasePopulator = new ResourceDatabasePopulator(script1);
    assert(databasePopulator.scripts.length == 1);
}

@("ResourceDatabasePopulatorTests.constructWithMultipleResources")
unittest
{
    auto databasePopulator = new ResourceDatabasePopulator(script1, script2);
    assert(databasePopulator.scripts.length == 2);
}

@("ResourceDatabasePopulatorTests.constructWithMultipleResourcesAndThenAddScript")
unittest
{
    auto databasePopulator = new ResourceDatabasePopulator(script1, script2);
    assert(databasePopulator.scripts.length == 2);

    databasePopulator.addScript(script3);
    assert(databasePopulator.scripts.length == 3);
}

@("ResourceDatabasePopulatorTests.addScriptsWithNullResource")
unittest
{
    auto databasePopulator = new ResourceDatabasePopulator();
    assertThrowsIllegalArgument(() { databasePopulator.addScripts(cast(Resource) null); });
}

version (FlintNullVarargsArray)
{
    // Gap: a null D array is the empty array, so a null Resource[] cannot be told apart from no scripts.
    @("ResourceDatabasePopulatorTests.addScriptsWithNullResourceArray")
    unittest
    {
        auto databasePopulator = new ResourceDatabasePopulator();
        assertThrowsIllegalArgument(() { databasePopulator.addScripts(cast(Resource[]) null); });
    }
}

@("ResourceDatabasePopulatorTests.setScriptsWithNullResource")
unittest
{
    auto databasePopulator = new ResourceDatabasePopulator();
    assertThrowsIllegalArgument(() { databasePopulator.setScripts(cast(Resource) null); });
}

version (FlintNullVarargsArray)
{
    // Gap: a null D array is the empty array, so a null Resource[] cannot be told apart from no scripts.
    @("ResourceDatabasePopulatorTests.setScriptsWithNullResourceArray")
    unittest
    {
        auto databasePopulator = new ResourceDatabasePopulator();
        assertThrowsIllegalArgument(() { databasePopulator.setScripts(cast(Resource[]) null); });
    }
}

@("ResourceDatabasePopulatorTests.setScriptsAndThenAddScript")
unittest
{
    auto databasePopulator = new ResourceDatabasePopulator();
    assert(databasePopulator.scripts.length == 0);

    databasePopulator.setScripts(script1, script2);
    assert(databasePopulator.scripts.length == 2);

    databasePopulator.addScript(script3);
    assert(databasePopulator.scripts.length == 3);
}
