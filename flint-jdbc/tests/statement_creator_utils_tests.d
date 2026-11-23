/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/StatementCreatorUtilsTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. Hand-written
`BlackHole` fakes replace the Mockito mocks: the statement and metadata log their calls, so
`verify(preparedStatement).setNull(1, Types.VARCHAR)` becomes a count of `ps.setNull(1,12)` in the log and
`never()` a count of zero; `doThrow` is a statement that throws `SQLFeatureNotSupportedException` for one SQL type.
Java's `null` is `Any.init`, and the `@ParameterizedTest` over java.time values loops over `flint.java.time`
values, whose class is the `Any`'s type name. Flint has no `OffsetTime`, no `java.sql`/`java.util` date types and
no `StatementCreatorUtils.shouldIgnoreGetParameterType`; those cases, and the ones whose bindings differ from
Spring's, wait behind version gates.
+/
module flint.jdbc.statement_creator_utils_tests;

import flint.engine.aot.any : Any;
import flint.java.sql : Connection, DatabaseMetaData, ParameterMetaData, PreparedStatement,
    SQLFeatureNotSupportedException, Types;
import flint.java.time : LocalDate, LocalDateTime, LocalTime, OffsetDateTime, ZoneOffset;
import flint.jdbc.core : SqlTypeValue, StatementCreatorUtils;
import std.typecons : BlackHole;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Fakes

private final class Log
{
    string[] entries;

    size_t count(string entry) const
    {
        size_t n;
        foreach (e; entries)
            if (e == entry)
                ++n;
        return n;
    }

    string joined() const
    {
        import std.array : join;

        return entries.join(" | ");
    }
}

private string decimal(long value)
{
    import flint.engine.aot.text : decimal;

    return decimal(value);
}

private final class FakeDatabaseMetaData : BlackHole!DatabaseMetaData
{
    private Log log;
    string databaseProductName;
    string driverName;

    this(Log log)
    {
        this.log = log;
    }

    override string getDatabaseProductName()
    {
        log.entries ~= "dbmd.getDatabaseProductName";
        return databaseProductName;
    }

    override string getDriverName()
    {
        log.entries ~= "dbmd.getDriverName";
        return driverName;
    }
}

private final class FakeConnection : BlackHole!Connection
{
    DatabaseMetaData metaData;

    override DatabaseMetaData getMetaData()
    {
        return metaData;
    }
}

private final class FakeParameterMetaData : BlackHole!ParameterMetaData
{
    private Log log;
    int[int] parameterTypes;

    this(Log log)
    {
        this.log = log;
    }

    override int getParameterType(int param)
    {
        log.entries ~= "pmd.getParameterType(" ~ decimal(param) ~ ")";
        return parameterTypes.get(param, 0);
    }
}

/// The mocked `PreparedStatement`: binds are logged as `ps.setNull(1,12)`, `ps.setNull(1,12,mytype)`,
/// `ps.setString(1,test)`, `ps.setObject(1,test)` or `ps.setObject(1,test,1)`, and each `setObject` value is kept.
private class FakePreparedStatement : BlackHole!PreparedStatement
{
    Log log;
    Connection connection;
    ParameterMetaData parameterMetaData;
    Any[] objects;
    /// `doThrow(new SQLFeatureNotSupportedException())` for a typed `setObject` or `setNull` of this SQL type.
    int unsupportedSqlType = SqlTypeValue.TYPE_UNKNOWN;

    this()
    {
        log = new Log;
    }

    protected void record(string entry)
    {
        log.entries ~= entry;
    }

    private void checkSupported(int sqlType)
    {
        if (sqlType == unsupportedSqlType)
            throw new SQLFeatureNotSupportedException("not supported");
    }

    override void setNull(int index, int sqlType)
    {
        record("ps.setNull(" ~ decimal(index) ~ "," ~ decimal(sqlType) ~ ")");
        checkSupported(sqlType);
    }

    override void setNull(int index, int sqlType, string typeName)
    {
        record("ps.setNull(" ~ decimal(index) ~ "," ~ decimal(sqlType) ~ "," ~ typeName ~ ")");
    }

    override void setString(int index, string value)
    {
        record("ps.setString(" ~ decimal(index) ~ "," ~ value ~ ")");
    }

    override void setObject(int index, Any value)
    {
        record("ps.setObject(" ~ decimal(index) ~ "," ~ value.toString() ~ ")");
        objects ~= value;
    }

    override void setObject(int index, Any value, int sqlType)
    {
        record("ps.setObject(" ~ decimal(index) ~ "," ~ value.toString() ~ "," ~ decimal(sqlType) ~ ")");
        objects ~= value;
        checkSupported(sqlType);
    }

    override Connection getConnection()
    {
        record("ps.getConnection");
        return connection;
    }

    override ParameterMetaData getParameterMetaData()
    {
        return parameterMetaData;
    }

    /// `verify(preparedStatement).call()`: exactly once.
    final void verify(string entry)
    {
        assert(log.count(entry) == 1, entry ~ " in " ~ log.joined());
    }
}

/// A `Connection` mock whose `DatabaseMetaData` names the given database and driver, logging into `log`.
private FakeConnection connectionTo(Log log, string databaseProductName, string driverName = null)
{
    auto dbmd = new FakeDatabaseMetaData(log);
    dbmd.databaseProductName = databaseProductName;
    dbmd.driverName = driverName;
    auto con = new FakeConnection;
    con.metaData = dbmd;
    return con;
}

/// A row of `javaTimeTypes()`: the value and its expected SQL type.
private struct JavaTimeType
{
    string name;
    Any value;
    int sqlType;
}

private JavaTimeType[] javaTimeTypes()
{
    const PLUS_NINE = ZoneOffset.ofHours(9);
    const now = LocalDateTime.now();
    JavaTimeType[] rows = [
        JavaTimeType("LocalTime -> TIME", Any.of(LocalTime.NOON), Types.TIME),
        JavaTimeType("LocalDate -> DATE", Any.of(LocalDate.EPOCH), Types.DATE),
        JavaTimeType("LocalDateTime -> TIMESTAMP", Any.of(now), Types.TIMESTAMP),
    ];
    // Gap: flint.java.time has no OffsetTime (LocalTime.atOffset).
    version (FlintJavaTimeOffsetTime)
        rows ~= JavaTimeType("OffsetTime -> TIME_WITH_TIMEZONE",
                Any.of(LocalTime.NOON.atOffset(PLUS_NINE)), Types.TIME_WITH_TIMEZONE);
    rows ~= JavaTimeType("OffsetDateTime -> TIMESTAMP_WITH_TIMEZONE",
            Any.of(now.atOffset(PLUS_NINE)), Types.TIMESTAMP_WITH_TIMEZONE);
    return rows;
}

// ---------------------------------------------------------------------------------------------------------------
// StatementCreatorUtilsTests

@("StatementCreatorUtilsTests.setParameterValueWithNullAndType")
unittest
{
    auto preparedStatement = new FakePreparedStatement;
    StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.VARCHAR, Any.init);
    preparedStatement.verify("ps.setNull(1,12)");
}

// Behaviour (likely bug): a null value with an SQL type name binds setNull(1, VARCHAR) and drops the type name,
// where Spring binds setNull(1, VARCHAR, "mytype").
version (FlintStatementCreatorUtilsNullTypeName)
{
    @("StatementCreatorUtilsTests.setParameterValueWithNullAndTypeName")
    unittest
    {
        auto preparedStatement = new FakePreparedStatement;
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.VARCHAR, "mytype", Any.init);
        preparedStatement.verify("ps.setNull(1,12,mytype)");
    }
}

// Gap: a null of unknown SQL type always binds setNull(i, Types.NULL): there is no shouldIgnoreGetParameterType,
// no ParameterMetaData.getParameterType lookup and no database-specific (Informix, Derby, Oracle) handling.
version (FlintStatementCreatorUtilsNullTypeResolution)
{
    @("StatementCreatorUtilsTests.setParameterValueWithNullAndUnknownType")
    unittest
    {
        StatementCreatorUtils.shouldIgnoreGetParameterType = true;
        auto preparedStatement = new FakePreparedStatement;
        preparedStatement.connection = connectionTo(preparedStatement.log, "Oracle", "Oracle Driver");
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, SqlTypeValue.TYPE_UNKNOWN, Any.init);
        preparedStatement.verify("ps.setNull(1,0)");
        StatementCreatorUtils.shouldIgnoreGetParameterType = false;
    }

    @("StatementCreatorUtilsTests.setParameterValueWithNullAndUnknownTypeOnInformix")
    unittest
    {
        StatementCreatorUtils.shouldIgnoreGetParameterType = true;
        auto preparedStatement = new FakePreparedStatement;
        auto con = connectionTo(preparedStatement.log, "Informix Dynamic Server", "Informix Driver");
        preparedStatement.connection = con;
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, SqlTypeValue.TYPE_UNKNOWN, Any.init);
        preparedStatement.verify("dbmd.getDatabaseProductName");
        preparedStatement.verify("dbmd.getDriverName");
        preparedStatement.verify("ps.setObject(1,null)");
        StatementCreatorUtils.shouldIgnoreGetParameterType = false;
    }

    @("StatementCreatorUtilsTests.setParameterValueWithNullAndUnknownTypeOnDerbyEmbedded")
    unittest
    {
        StatementCreatorUtils.shouldIgnoreGetParameterType = true;
        auto preparedStatement = new FakePreparedStatement;
        preparedStatement.connection = connectionTo(preparedStatement.log, "Apache Derby",
                "Apache Derby Embedded Driver");
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, SqlTypeValue.TYPE_UNKNOWN, Any.init);
        preparedStatement.verify("dbmd.getDatabaseProductName");
        preparedStatement.verify("dbmd.getDriverName");
        preparedStatement.verify("ps.setNull(1,12)");
        StatementCreatorUtils.shouldIgnoreGetParameterType = false;
    }

    @("StatementCreatorUtilsTests.setParameterValueWithNullAndGetParameterTypeWorking")
    unittest
    {
        auto preparedStatement = new FakePreparedStatement;
        auto pmd = new FakeParameterMetaData(preparedStatement.log);
        preparedStatement.parameterMetaData = pmd;
        pmd.parameterTypes[1] = Types.SMALLINT;
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, SqlTypeValue.TYPE_UNKNOWN, Any.init);
        preparedStatement.verify("pmd.getParameterType(1)");
        assert(preparedStatement.log.count("ps.getConnection") == 0);
        preparedStatement.verify("ps.setNull(1,5)");
    }
}

@("StatementCreatorUtilsTests.setParameterValueWithString")
unittest
{
    auto preparedStatement = new FakePreparedStatement;
    StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.VARCHAR, Any.of("test"));
    preparedStatement.verify("ps.setString(1,test)");
}

// Behaviour: a string of SQL type CHAR binds setString(1, "test"), where Spring binds setObject(1, "test", CHAR).
version (FlintStatementCreatorUtilsCharType)
{
    @("StatementCreatorUtilsTests.setParameterValueWithStringAndSpecialType")
    unittest
    {
        auto preparedStatement = new FakePreparedStatement;
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.CHAR, Any.of("test"));
        preparedStatement.verify("ps.setObject(1,test,1)");
    }
}

@("StatementCreatorUtilsTests.setParameterValueWithStringAndUnknownType")
unittest
{
    auto preparedStatement = new FakePreparedStatement;
    StatementCreatorUtils.setParameterValue(preparedStatement, 1, SqlTypeValue.TYPE_UNKNOWN, Any.of("test"));
    preparedStatement.verify("ps.setString(1,test)");
}

// Gap: flint.java.sql has no Date, Time or Timestamp (nor setDate, setTime and setTimestamp), and flint.java.util
// no Date or Calendar.
version (FlintJdbcSqlDateTypes)
{
    import flint.java.sql : SqlDate = Date, Time, Timestamp;
    import flint.java.util : Calendar, GregorianCalendar, UtilDate = Date;

    /// The statement fake with the date and time setters.
    private final class DatedPreparedStatement : FakePreparedStatement
    {
        Calendar calendar;

        override void setDate(int index, SqlDate x)
        {
            record("ps.setDate(" ~ decimal(index) ~ "," ~ decimal(x.getTime()) ~ ")");
        }

        override void setDate(int index, SqlDate x, Calendar cal)
        {
            calendar = cal;
            record("ps.setDate(" ~ decimal(index) ~ "," ~ decimal(x.getTime()) ~ ",cal)");
        }

        override void setTime(int index, Time x)
        {
            record("ps.setTime(" ~ decimal(index) ~ "," ~ decimal(x.getTime()) ~ ")");
        }

        override void setTime(int index, Time x, Calendar cal)
        {
            calendar = cal;
            record("ps.setTime(" ~ decimal(index) ~ "," ~ decimal(x.getTime()) ~ ",cal)");
        }

        override void setTimestamp(int index, Timestamp x)
        {
            record("ps.setTimestamp(" ~ decimal(index) ~ "," ~ decimal(x.getTime()) ~ ")");
        }

        override void setTimestamp(int index, Timestamp x, Calendar cal)
        {
            calendar = cal;
            record("ps.setTimestamp(" ~ decimal(index) ~ "," ~ decimal(x.getTime()) ~ ",cal)");
        }
    }

    private Any anyOf(Object value)
    {
        return Any.ofObject(value, typeid(value).name);
    }

    @("StatementCreatorUtilsTests.setParameterValueWithSqlDate")
    unittest
    {
        auto preparedStatement = new DatedPreparedStatement;
        auto date = new SqlDate(1000);
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.DATE, anyOf(date));
        preparedStatement.verify("ps.setDate(1,1000)");
    }

    @("StatementCreatorUtilsTests.setParameterValueWithDateAndUtilDate")
    unittest
    {
        auto preparedStatement = new DatedPreparedStatement;
        auto date = new UtilDate(1000);
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.DATE, anyOf(date));
        preparedStatement.verify("ps.setDate(1,1000)");
    }

    @("StatementCreatorUtilsTests.setParameterValueWithDateAndCalendar")
    unittest
    {
        auto preparedStatement = new DatedPreparedStatement;
        Calendar cal = new GregorianCalendar();
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.DATE, anyOf(cal));
        preparedStatement.verify("ps.setDate(1," ~ decimal(cal.getTime().getTime()) ~ ",cal)");
        assert(preparedStatement.calendar is cal);
    }

    @("StatementCreatorUtilsTests.setParameterValueWithSqlTime")
    unittest
    {
        auto preparedStatement = new DatedPreparedStatement;
        auto time = new Time(1000);
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.TIME, anyOf(time));
        preparedStatement.verify("ps.setTime(1,1000)");
    }

    @("StatementCreatorUtilsTests.setParameterValueWithTimeAndUtilDate")
    unittest
    {
        auto preparedStatement = new DatedPreparedStatement;
        auto date = new UtilDate(1000);
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.TIME, anyOf(date));
        preparedStatement.verify("ps.setTime(1,1000)");
    }

    @("StatementCreatorUtilsTests.setParameterValueWithTimeAndCalendar")
    unittest
    {
        auto preparedStatement = new DatedPreparedStatement;
        Calendar cal = new GregorianCalendar();
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.TIME, anyOf(cal));
        preparedStatement.verify("ps.setTime(1," ~ decimal(cal.getTime().getTime()) ~ ",cal)");
        assert(preparedStatement.calendar is cal);
    }

    @("StatementCreatorUtilsTests.setParameterValueWithSqlTimestamp")
    unittest
    {
        auto preparedStatement = new DatedPreparedStatement;
        auto timestamp = new Timestamp(1000);
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.TIMESTAMP, anyOf(timestamp));
        preparedStatement.verify("ps.setTimestamp(1,1000)");
    }

    @("StatementCreatorUtilsTests.setParameterValueWithTimestampAndUtilDate")
    unittest
    {
        auto preparedStatement = new DatedPreparedStatement;
        auto date = new UtilDate(1000);
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.TIMESTAMP, anyOf(date));
        preparedStatement.verify("ps.setTimestamp(1,1000)");
    }

    @("StatementCreatorUtilsTests.setParameterValueWithTimestampAndCalendar")
    unittest
    {
        auto preparedStatement = new DatedPreparedStatement;
        Calendar cal = new GregorianCalendar();
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.TIMESTAMP, anyOf(cal));
        preparedStatement.verify("ps.setTimestamp(1," ~ decimal(cal.getTime().getTime()) ~ ",cal)");
        assert(preparedStatement.calendar is cal);
    }

    @("StatementCreatorUtilsTests.setParameterValueWithDateAndUnknownType")
    unittest
    {
        auto preparedStatement = new DatedPreparedStatement;
        auto date = new UtilDate(1000);
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, SqlTypeValue.TYPE_UNKNOWN, anyOf(date));
        preparedStatement.verify("ps.setTimestamp(1,1000)");
    }

    @("StatementCreatorUtilsTests.setParameterValueWithCalendarAndUnknownType")
    unittest
    {
        auto preparedStatement = new DatedPreparedStatement;
        Calendar cal = new GregorianCalendar();
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, SqlTypeValue.TYPE_UNKNOWN, anyOf(cal));
        preparedStatement.verify("ps.setTimestamp(1," ~ decimal(cal.getTime().getTime()) ~ ",cal)");
        assert(preparedStatement.calendar is cal);
    }
}

@("StatementCreatorUtilsTests.setParameterValueWithJavaTimeTypes")
unittest
{
    foreach (row; javaTimeTypes())
    {
        auto preparedStatement = new FakePreparedStatement;
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, row.sqlType, row.value);
        preparedStatement.verify("ps.setObject(1," ~ row.value.toString() ~ "," ~ decimal(row.sqlType) ~ ")");
        assert(preparedStatement.objects.length == 1 && preparedStatement.objects[0] == row.value, row.name);
    }
}

// Behaviour (likely bug): javaTypeToSqlParameterType maps no java.time type (TYPE_UNKNOWN for LocalTime,
// LocalDate, LocalDateTime and OffsetDateTime), so a BeanPropertySqlParameterSource gives such a property no SQL
// type.
version (FlintJavaTimeSqlParameterTypes)
{
    @("StatementCreatorUtilsTests.javaTimeTypesToSqlParameterType")
    unittest
    {
        foreach (row; javaTimeTypes())
            assert(StatementCreatorUtils.javaTypeToSqlParameterType(row.value.typeName) == row.sqlType, row.name);
    }
}

// Behaviour (likely bug): a driver's SQLFeatureNotSupportedException from a typed setObject or setNull
// propagates, where Spring (gh-30556) retries with setObject(i, value) or setNull(i, Types.NULL).
version (FlintStatementCreatorUtilsUnsupportedTypeFallback)
{
    @("StatementCreatorUtilsTests.setParameterValueWithOffsetDateTimeAndNotSupported")
    unittest
    {
        auto time = Any.of(OffsetDateTime.now());
        auto preparedStatement = new FakePreparedStatement;
        preparedStatement.unsupportedSqlType = Types.TIMESTAMP_WITH_TIMEZONE;
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.TIMESTAMP_WITH_TIMEZONE, time);
        preparedStatement.verify("ps.setObject(1," ~ time.toString() ~ ",2014)");
        preparedStatement.verify("ps.setObject(1," ~ time.toString() ~ ")");
        assert(preparedStatement.objects == [time, time]);
    }

    @("StatementCreatorUtilsTests.setParameterValueWithNullAndNotSupported")
    unittest
    {
        auto preparedStatement = new FakePreparedStatement;
        preparedStatement.unsupportedSqlType = Types.TIMESTAMP_WITH_TIMEZONE;
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.TIMESTAMP_WITH_TIMEZONE, Any.init);
        preparedStatement.verify("ps.setNull(1,2014)");
        preparedStatement.verify("ps.setNull(1,0)");
    }
}

// Behaviour: a string of SQL type OTHER on Oracle binds setObject(1, "test", OTHER), where Spring (SPR-8571) binds
// setString(1, "test").
version (FlintStatementCreatorUtilsOracleOtherType)
{
    @("StatementCreatorUtilsTests.setParameterValueWithStringAndVendorSpecificType")
    unittest
    {
        auto preparedStatement = new FakePreparedStatement;
        preparedStatement.connection = connectionTo(preparedStatement.log, "Oracle");
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.OTHER, Any.of("test"));
        preparedStatement.verify("ps.setString(1,test)");
    }
}

version (FlintStatementCreatorUtilsNullTypeResolution)
{
    @("StatementCreatorUtilsTests.setParameterValueWithNullAndVendorSpecificType")
    unittest
    {
        StatementCreatorUtils.shouldIgnoreGetParameterType = true;
        auto preparedStatement = new FakePreparedStatement;
        preparedStatement.connection = connectionTo(preparedStatement.log, "Oracle", "Oracle Driver");
        StatementCreatorUtils.setParameterValue(preparedStatement, 1, Types.OTHER, Any.init);
        preparedStatement.verify("ps.setNull(1,0)");
        StatementCreatorUtils.shouldIgnoreGetParameterType = false;
    }
}
