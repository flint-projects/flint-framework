/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/SingleColumnRowMapperTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: hand-written `BlackHole` fakes replace the Mockito mocks; `Class<T>` arguments are
template parameters. Every case maps a `java.sql.Timestamp` column through `SingleColumnRowMapper`'s
`ConversionService` fallback, and flint.java.sql has no `Timestamp` or `getTimestamp`, nor flint.jdbc a
`SingleColumnRowMapper.newInstance(type, conversionService)`: the cases wait behind a version gate.
+/
module flint.jdbc.single_column_row_mapper_tests;

@safe:

// java.sql.Timestamp and SingleColumnRowMapper's ConversionService fallback are not ported.
version (FlintSingleColumnRowMapperConversionService)
{
    import flint.core.convert.support : DefaultConversionService;
    import flint.dao : TypeMismatchDataAccessException;
    import flint.engine.aot.any : Any;
    import flint.java.sql : ResultSet, ResultSetMetaData, SQLFeatureNotSupportedException, Timestamp;
    import flint.java.time : LocalDateTime;
    import flint.jdbc.core : SingleColumnRowMapper;
    import std.typecons : BlackHole;

    private final class OneColumnMetaData : BlackHole!ResultSetMetaData
    {
        override int getColumnCount()
        {
            return 1;
        }
    }

    /// `getObject(1, T)` throws `SQLFeatureNotSupportedException`; `getTimestamp(1)` and `getObject(1)` answer
    /// the timestamp.
    private final class TimestampResultSet : BlackHole!ResultSet
    {
        private Timestamp timestamp;

        this(Timestamp timestamp)
        {
            this.timestamp = timestamp;
        }

        override ResultSetMetaData getMetaData()
        {
            return new OneColumnMetaData;
        }

        T getObject(T)(int column)
        {
            throw new SQLFeatureNotSupportedException();
        }

        override Any getObject(int column)
        {
            return Any.of(timestamp);
        }

        override Timestamp getTimestamp(int column)
        {
            return timestamp;
        }
    }

    private final class MyLocalDateTime
    {
        private const LocalDateTime value;

        this(LocalDateTime value)
        {
            this.value = value;
        }
    }

    private void expectThrows(E : Exception)(scope void delegate() @safe action)
    {
        try
            action();
        catch (E)
            return;
        assert(false, "expected " ~ E.stringof);
    }

    @("SingleColumnRowMapperTests.useDefaultConversionService")
    unittest
    {
        auto timestamp = new Timestamp(0);

        auto rowMapper = SingleColumnRowMapper!LocalDateTime.newInstance();
        auto resultSet = new TimestampResultSet(timestamp);

        const actualLocalDateTime = rowMapper.mapRow(resultSet, 1);

        assert(actualLocalDateTime == timestamp.toLocalDateTime());
    }

    @("SingleColumnRowMapperTests.useCustomConversionService")
    unittest
    {
        auto timestamp = new Timestamp(0);

        auto myConversionService = new DefaultConversionService();
        myConversionService.addConverter!(Timestamp,
                MyLocalDateTime)((Timestamp source) => new MyLocalDateTime(source.toLocalDateTime()));
        auto rowMapper = SingleColumnRowMapper!MyLocalDateTime.newInstance(myConversionService);
        auto resultSet = new TimestampResultSet(timestamp);

        auto actualMyLocalDateTime = rowMapper.mapRow(resultSet, 1);

        assert(actualMyLocalDateTime !is null);
        assert(actualMyLocalDateTime.value == timestamp.toLocalDateTime());
    }

    @("SingleColumnRowMapperTests.doesNotUseConversionService")
    unittest
    {
        auto rowMapper = SingleColumnRowMapper!LocalDateTime.newInstance(null);
        auto resultSet = new TimestampResultSet(new Timestamp(0));

        expectThrows!TypeMismatchDataAccessException({ rowMapper.mapRow(resultSet, 1); });
    }
}
