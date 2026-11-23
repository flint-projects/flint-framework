/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/support/JdbcUtilsTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: Java's null result is D's null string.
+/
module flint.jdbc.jdbc_utils_tests;

import flint.java.sql : Types;
import flint.jdbc.support : JdbcUtils;

@safe:

@("JdbcUtilsTests.commonDatabaseName")
unittest
{
    assert(JdbcUtils.commonDatabaseName("Oracle") == "Oracle");
    assert(JdbcUtils.commonDatabaseName("DB2-for-Spring") == "DB2");
    assert(JdbcUtils.commonDatabaseName("Sybase SQL Server") == "Sybase");
    assert(JdbcUtils.commonDatabaseName("Adaptive Server Enterprise") == "Sybase");
    assert(JdbcUtils.commonDatabaseName("MySQL") == "MySQL");
    assert(JdbcUtils.commonDatabaseName("MariaDB") == "MariaDB");
}

version (FlintJdbcResolveTypeName)
{
    // Gap: JdbcUtils.resolveTypeName (the Types constant name of an SQL type) is not ported.
    @("JdbcUtilsTests.resolveTypeName")
    unittest
    {
        assert(JdbcUtils.resolveTypeName(Types.VARCHAR) == "VARCHAR");
        assert(JdbcUtils.resolveTypeName(Types.NUMERIC) == "NUMERIC");
        assert(JdbcUtils.resolveTypeName(Types.INTEGER) == "INTEGER");
        assert(JdbcUtils.resolveTypeName(JdbcUtils.TYPE_UNKNOWN) is null);
    }
}

@("JdbcUtilsTests.convertUnderscoreNameToPropertyName")
unittest
{
    assert(JdbcUtils.convertUnderscoreNameToPropertyName("MY_NAME") == "myName");
    assert(JdbcUtils.convertUnderscoreNameToPropertyName("yOUR_nAME") == "yourName");
    assert(JdbcUtils.convertUnderscoreNameToPropertyName("a_name") == "AName");
    assert(JdbcUtils.convertUnderscoreNameToPropertyName("someone_elses_name") == "someoneElsesName");
}
