/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/DataClassRowMapperTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: the `AbstractRowMapperTests` fixture and the `core.test` beans it maps are private
copies here. Hand-written `BlackHole` fakes replace the Mockito `Mock`: its `ResultSet` serves one scripted row
through `getObject` (the `Timestamp` and `BigDecimal` columns become a `flint.java.time.LocalDateTime` and a
`double`, as `java.util.Date` and `BigDecimal` values become `LocalDateTime` and `double`), counts `findColumn`
and `getMetaData` calls for the `verify` checks, and a fake `DataSource` hands out the connection as Spring's
`SingleConnectionDataSource` does. Java records and data classes are D classes with record-style accessors; each
test hands `DataClassRowMapper` the canonical constructor as Flint AOT records it in the generated descriptor
(`descriptorOf!T` lists only a default constructor), its invoker reading each argument with `Any.get` as generated
code does. `BeanWrapper` checks wait behind a version gate.
+/
module flint.jdbc.data_class_row_mapper_tests;

import flint.dao : DataAccessException;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : ConstructorDescriptor, Descriptor, ParameterDescriptor, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : UnsupportedOperationException;
import flint.java.sql : Connection, ResultSet, ResultSetMetaData, SQLException, Statement;
import flint.java.time : LocalDateTime;
import flint.java.util : ArrayList, List;
import flint.javax.sql : DataSource;
import flint.jdbc.core : DataClassRowMapper, JdbcTemplate;
import flint.jdbc.support : SQLStateSQLExceptionTranslator;
import std.typecons : BlackHole;

@safe:

private void expectThrows(E : Throwable)(scope void delegate() @safe action, scope void delegate(E) @safe check)
{
    try
        action();
    catch (E ex)
    {
        check(ex);
        return;
    }
    assert(false, "expected " ~ E.stringof);
}

/// `new java.util.Date(1221222L)` (and `new Timestamp(1221222L)`) as a UTC `LocalDateTime`.
private LocalDateTime birthDateTime()
{
    return LocalDateTime.of(1970, 1, 1, 0, 20, 21, 222_000_000);
}

/// `T`'s descriptor, with `invoke` as its canonical constructor over `parameters` (name and D type each).
private Descriptor dataClass(T)(string[2][] parameters, Any function(scope Any[]) @safe invoke)
{
    auto descriptor = descriptorOf!T();
    ParameterDescriptor[] params;
    foreach (p; parameters)
        params ~= ParameterDescriptor(p[0], p[1]);
    descriptor.constructors = [ConstructorDescriptor(params, null, invoke, true)];
    return descriptor;
}

/// The Flint AOT boxing of a constructed `T`.
private Any boxed(T)(T instance)
{
    return Any.ofObject(instance, typeid(T).name);
}

// ---------------------------------------------------------------------------------------------------------------
// The core.test data classes and the test's records

private enum string TIMESTAMP = typeNameOf!LocalDateTime;

private class ConstructorPerson
{
    private string name_;
    private long age_;
    private LocalDateTime birth_date_;
    private double balance_;

    this(string name, long age, LocalDateTime birth_date, double balance)
    {
        name_ = name;
        age_ = age;
        birth_date_ = birth_date;
        balance_ = balance;
    }

    string name()
    {
        return name_;
    }

    long age()
    {
        return age_;
    }

    LocalDateTime birth_date()
    {
        return birth_date_;
    }

    double balance()
    {
        return balance_;
    }

    static Descriptor descriptor()
    {
        return dataClass!ConstructorPerson([
            ["name", "string"], ["age", "long"], ["birth_date", TIMESTAMP], ["balance", "double"]
        ], (scope Any[] args) @safe => boxed(new ConstructorPerson(args[0].get!string,
                args[1].get!long, args[2].get!LocalDateTime, args[3].get!double)));
    }
}

private class ConstructorPersonWithGenerics
{
    private string name_;
    private long age_;
    private LocalDateTime bd;
    private List!double balance_;

    this(string name, long age, LocalDateTime birthDate, List!double balance)
    {
        name_ = name;
        age_ = age;
        bd = birthDate;
        balance_ = balance;
    }

    string name()
    {
        return name_;
    }

    long age()
    {
        return age_;
    }

    LocalDateTime birthDate()
    {
        return bd;
    }

    List!double balance()
    {
        return balance_;
    }

    static Descriptor descriptor()
    {
        return dataClass!ConstructorPersonWithGenerics([
            ["name", "string"], ["age", "long"], ["birthDate", TIMESTAMP],
            ["balance", typeNameOf!(List!double)]
        ], (scope Any[] args) @safe => boxed(new ConstructorPersonWithGenerics(args[0].get!string,
                args[1].get!long, args[2].get!LocalDateTime, args[3].get!(List!double))));
    }
}

private class ConstructorPersonWithSetters
{
    private string name_;
    private long age_;
    private LocalDateTime birthDate_;
    private double balance_;

    this(string name, long age, double balance)
    {
        import std.ascii : toUpper;

        foreach (c; name)
            name_ ~= toUpper(c);
        age_ = age;
        balance_ = balance;
    }

    void setName(string)
    {
        throw new UnsupportedOperationException();
    }

    void setAge(long)
    {
        throw new UnsupportedOperationException();
    }

    void setBirthDate(LocalDateTime birthDate)
    {
        birthDate_ = birthDate;
    }

    void setBalance(double)
    {
        throw new UnsupportedOperationException();
    }

    string name()
    {
        return name_;
    }

    long age()
    {
        return age_;
    }

    LocalDateTime birthDate()
    {
        return birthDate_;
    }

    double balance()
    {
        return balance_;
    }

    static Descriptor descriptor()
    {
        return dataClass!ConstructorPersonWithSetters([
            ["name", "string"], ["age", "long"], ["balance", "double"]
        ], (scope Any[] args) @safe => boxed(new ConstructorPersonWithSetters(args[0].get!string,
                args[1].get!long, args[2].get!double)));
    }
}

/// `record RecordPerson(String name, long age, Date birth_date, BigDecimal balance)`.
private final class RecordPerson
{
    private string name_;
    private long age_;
    private LocalDateTime birth_date_;
    private double balance_;

    this(string name, long age, LocalDateTime birth_date, double balance)
    {
        name_ = name;
        age_ = age;
        birth_date_ = birth_date;
        balance_ = balance;
    }

    string name()
    {
        return name_;
    }

    long age()
    {
        return age_;
    }

    LocalDateTime birth_date()
    {
        return birth_date_;
    }

    double balance()
    {
        return balance_;
    }

    static Descriptor descriptor()
    {
        return dataClass!RecordPerson([
            ["name", "string"], ["age", "long"], ["birth_date", TIMESTAMP], ["balance", "double"]
        ], (scope Any[] args) @safe => boxed(new RecordPerson(args[0].get!string,
                args[1].get!long, args[2].get!LocalDateTime, args[3].get!double)));
    }
}

/// `record EmailRecordPerson(String name, String email)`.
private final class EmailRecordPerson
{
    private string name_;
    private string email_;

    this(string name, string email)
    {
        name_ = name;
        email_ = email;
    }

    string name()
    {
        return name_;
    }

    string email()
    {
        return email_;
    }

    static Descriptor descriptor()
    {
        return dataClass!EmailRecordPerson([["name", "string"], ["email", "string"]],
                (scope Any[] args) @safe => boxed(new EmailRecordPerson(args[0].get!string, args[1].get!string)));
    }
}

// ---------------------------------------------------------------------------------------------------------------
// AbstractRowMapperTests

private void verifyPerson(ConstructorPerson person)
{
    assert(person.name() == "Bubba");
    assert(person.age() == 22);
    assert(person.birth_date() == birthDateTime());
    assert(person.balance() == 1234.56);
    version (FlintBeanWrapper) // flint.beans has no BeanWrapper
        verifyPersonViaBeanWrapper(person);
}

private void verifyPerson(RecordPerson person)
{
    assert(person.name() == "Bubba");
    assert(person.age() == 22);
    assert(person.birth_date() == birthDateTime());
    assert(person.balance() == 1234.56);
    version (FlintBeanWrapper) // flint.beans has no BeanWrapper
        verifyPersonViaBeanWrapper(person);
}

version (FlintBeanWrapper) // flint.beans has no BeanWrapper
{
    private void verifyPersonViaBeanWrapper(Object person)
    {
        import flint.beans : BeanWrapper, PropertyAccessorFactory;

        BeanWrapper bw = PropertyAccessorFactory.forBeanPropertyAccess(person);
        assert(bw.getPropertyValue("name").get!string == "Bubba");
        assert(bw.getPropertyValue("age").get!long == 22);
        LocalDateTime birthDate;
        if (bw.isReadableProperty("birth_date"))
            birthDate = bw.getPropertyValue("birth_date").get!LocalDateTime;
        else
            birthDate = bw.getPropertyValue("birthDate").get!LocalDateTime;
        assert(birthDate == birthDateTime());
        assert(bw.getPropertyValue("balance").get!double == 1234.56);
    }
}

private enum MockType
{
    ONE,
    TWO,
    THREE,
    FOUR
}

private final class MockMetaData : BlackHole!ResultSetMetaData
{
    private string[] labels;

    this(string[] labels)
    {
        this.labels = labels;
    }

    override int getColumnCount()
    {
        return cast(int) labels.length;
    }

    override string getColumnLabel(int column)
    {
        return labels[column - 1];
    }
}

/// The Mock's `ResultSet`: one row of five columns, then none.
private final class MockResultSet : BlackHole!ResultSet
{
    private MockType type;
    private Any[] values;
    private string[] labels;
    private int[string] columns;
    private int rowsServed;
    /// `given(resultSet.findColumn(label)).willThrow(ex)`.
    SQLException[string] findColumnFailures;
    int closeCalls, findColumnCalls, getMetaDataCalls;

    this(MockType type)
    {
        this.type = type;
        values = [
            Any.of("Bubba"), type == MockType.TWO ? Any.init : Any.of(22L), Any.of(birthDateTime()),
            Any.of(1234.56), Any.of("hello@world.info")
        ];
        labels = [
            type == MockType.THREE ? "Last Name" : "name", "age",
            type == MockType.FOUR ? "birthdate" : "birth_date", "balance", "e_mail"
        ];
        columns = ["name": 1, "age": 2, "balance": 4, "e_mail": 5];
        if (type == MockType.FOUR)
            columns["birthdate"] = 3;
        else
            columns["birth_date"] = 3;
    }

    override bool next()
    {
        return ++rowsServed == 1;
    }

    override Any getObject(int column)
    {
        return values[column - 1];
    }

    override string getString(int column)
    {
        return column == 1 ? "Bubba" : column == 5 ? "hello@world.info" : null;
    }

    override long getLong(int column)
    {
        return column == 2 ? 22 : 0;
    }

    override int getInt(int column)
    {
        return cast(int) getLong(column);
    }

    override double getDouble(int column)
    {
        return column == 4 ? 1234.56 : 0;
    }

    override bool wasNull()
    {
        return type == MockType.TWO;
    }

    override ResultSetMetaData getMetaData()
    {
        ++getMetaDataCalls;
        return new MockMetaData(labels);
    }

    override int findColumn(string label)
    {
        ++findColumnCalls;
        if (auto failure = label in findColumnFailures)
            throw*failure;
        if (auto index = label in columns)
            return *index;
        if (label == "birthdate" || label == "birthDate")
            throw new SQLException();
        return 0;
    }

    override void close()
    {
        ++closeCalls;
    }
}

private final class MockStatement : BlackHole!Statement
{
    private MockResultSet resultSet;
    int closeCalls;

    this(MockResultSet resultSet)
    {
        this.resultSet = resultSet;
    }

    override ResultSet executeQuery(string)
    {
        return resultSet;
    }

    override void close()
    {
        ++closeCalls;
    }
}

private final class MockConnection : BlackHole!Connection
{
    private MockStatement statement;

    this(MockStatement statement)
    {
        this.statement = statement;
    }

    override Statement createStatement()
    {
        return statement;
    }
}

/// Spring's `SingleConnectionDataSource(connection, false)`: always the same connection.
private final class SingleConnection : BlackHole!DataSource
{
    private Connection connection;

    this(Connection connection)
    {
        this.connection = connection;
    }

    override Connection getConnection()
    {
        return connection;
    }
}

private final class Mock
{
    private MockResultSet resultSet;
    private MockStatement statement;
    private JdbcTemplate jdbcTemplate;

    this(MockType type = MockType.ONE)
    {
        resultSet = new MockResultSet(type);
        statement = new MockStatement(resultSet);
        jdbcTemplate = new JdbcTemplate();
        jdbcTemplate.setDataSource(new SingleConnection(new MockConnection(statement)));
        jdbcTemplate.setExceptionTranslator(new SQLStateSQLExceptionTranslator());
        jdbcTemplate.afterPropertiesSet();
    }

    JdbcTemplate getJdbcTemplate()
    {
        return jdbcTemplate;
    }

    MockResultSet getResultSet()
    {
        return resultSet;
    }

    void verifyClosed()
    {
        assert(resultSet.closeCalls == 1, "verify(resultSet).close()");
        assert(statement.closeCalls == 1, "verify(statement).close()");
    }
}

// ---------------------------------------------------------------------------------------------------------------
// DataClassRowMapperTests

@("DataClassRowMapperTests.staticQueryWithDataClass")
unittest
{
    auto mock = new Mock;
    auto person = mock.getJdbcTemplate().queryForObject("select name, age, birth_date, balance from people",
            new DataClassRowMapper!ConstructorPerson(ConstructorPerson.descriptor()));
    verifyPerson(person);
    mock.verifyClosed();
}

// The row mappers pass the raw column value on: no conversion of a decimal to a List parameter
version (FlintJdbcRowMapperValueConversion)
{
    @("DataClassRowMapperTests.staticQueryWithDataClassAndGenerics")
    unittest
    {
        auto mock = new Mock;
        auto person = mock.getJdbcTemplate().queryForObject("select name, age, birth_date, balance from people",
                new DataClassRowMapper!ConstructorPersonWithGenerics(ConstructorPersonWithGenerics.descriptor()));
        assert(person.name() == "Bubba");
        assert(person.age() == 22);
        assert(person.birthDate() == birthDateTime());
        assert(person.balance().toArray() == [1234.56]);
        mock.verifyClosed();
    }
}

@("DataClassRowMapperTests.staticQueryWithDataClassAndSetters")
unittest
{
    foreach (checkFullyPopulated; [true, false])
    {
        auto mapper = new DataClassRowMapper!ConstructorPersonWithSetters(ConstructorPersonWithSetters.descriptor());
        mapper.setCheckFullyPopulated(checkFullyPopulated);
        auto mock = new Mock(MockType.FOUR);
        auto person = mock.getJdbcTemplate().queryForObject("select name, age, birthdate, balance from people", mapper);
        assert(person.name() == "BUBBA");
        assert(person.age() == 22);
        assert(person.birthDate() == birthDateTime());
        assert(person.balance() == 1234.56);
        mock.verifyClosed();
    }
}

@("DataClassRowMapperTests.staticQueryWithDataRecord")
unittest
{
    auto mock = new Mock;
    auto person = mock.getJdbcTemplate().queryForObject("select name, age, birth_date, balance from people",
            new DataClassRowMapper!RecordPerson(RecordPerson.descriptor()));
    verifyPerson(person);
    mock.verifyClosed();
}

// The row mappers pass the raw column value on: no conversion of a decimal to a List parameter
version (FlintJdbcRowMapperValueConversion)
{
    @("DataClassRowMapperTests.staticQueryWithDataClassResolvesColumnsViaMetaData")
    unittest
    {
        auto mock = new Mock;
        auto person = mock.getJdbcTemplate().queryForObject("select name, age, birth_date, balance from people",
                new DataClassRowMapper!ConstructorPersonWithGenerics(ConstructorPersonWithGenerics.descriptor()));
        assert(person.birthDate() == birthDateTime());
        assert(mock.getResultSet().findColumnCalls == 0, "verify(resultSet, never()).findColumn(anyString())");
        mock.verifyClosed();
    }
}

@("DataClassRowMapperTests.staticQueryWithDataRecordSkipsSetterPopulation")
unittest
{
    auto mock = new Mock;
    auto rowMapper = new DataClassRowMapper!RecordPerson(RecordPerson.descriptor());
    rowMapper.setCheckFullyPopulated(true);
    auto person = mock.getJdbcTemplate().queryForObject("select name, age, birth_date, balance from people", rowMapper);
    verifyPerson(person);
    assert(mock.getResultSet().getMetaDataCalls == 1, "verify(resultSet).getMetaData()");
    mock.verifyClosed();
}

@("DataClassRowMapperTests.staticQueryWithDataRecordAndMissingColumn")
unittest
{
    auto mock = new Mock;
    auto ex = new SQLException("No such column");
    mock.getResultSet().findColumnFailures["email"] = ex;
    expectThrows!DataAccessException({
        mock.getJdbcTemplate().queryForObject("select name, age, birth_date, balance, e_mail from people",
            new DataClassRowMapper!EmailRecordPerson(EmailRecordPerson.descriptor()));
    }, (DataAccessException thrown) { assert(thrown.getCause() is ex, "withCause(ex)"); });
    mock.verifyClosed();
}
