/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/core/BeanPropertyRowMapperTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: the `AbstractRowMapperTests` fixture and the `core.test` beans it maps are private
copies here. Hand-written `BlackHole` fakes replace the Mockito `Mock`: its `ResultSet` serves one scripted row
through `getObject` (the `Timestamp` and `BigDecimal` columns become a `flint.java.time.LocalDateTime` and a
`double`, as `java.util.Date` and `BigDecimal` properties become `LocalDateTime` and `double`), and a fake
`DataSource` hands out the connection as Spring's `SingleConnectionDataSource` does. Class tokens are template
arguments (`BeanPropertyRowMapper!Person`), and the beans' properties come from their Flint AOT descriptors. A null
into a primitive property is flint.dao's `TypeMismatchDataAccessException`, as flint:jdbc has no beans
`TypeMismatchException`; `underscoreName` is `JdbcUtils.convertPropertyNameToUnderscoreName`, which the mapper uses.
`BeanWrapper` checks, `setMappedClass` and the `mappedNames` hook wait behind version gates.
+/
module flint.jdbc.bean_property_row_mapper_tests;

import flint.dao : InvalidDataAccessApiUsageException, TypeMismatchDataAccessException;
import flint.engine.aot.any : Any;
import flint.java.sql : Connection, ResultSet, ResultSetMetaData, SQLException, Statement;
import flint.java.time : LocalDate, LocalDateTime;
import flint.javax.sql : DataSource;
import flint.jdbc.core : BeanPropertyRowMapper, JdbcTemplate;
import flint.jdbc.support : JdbcUtils, SQLStateSQLExceptionTranslator;
import std.typecons : BlackHole;

@safe:

private enum SELECT_NULL_AS_AGE = "select null as age from people";

private void expectThrows(E : Throwable)(scope void delegate() @safe action)
{
    try
        action();
    catch (E)
        return;
    assert(false, "expected " ~ E.stringof);
}

// ---------------------------------------------------------------------------------------------------------------
// The core.test beans

/// `new java.util.Date(1221222L)` (and `new Timestamp(1221222L).toLocalDateTime()` in UTC).
private LocalDateTime birthDateTime()
{
    return LocalDateTime.of(1970, 1, 1, 0, 20, 21, 222_000_000);
}

/// `new java.sql.Date(1221222L).toLocalDate()` in UTC.
private LocalDate birthDate()
{
    return LocalDate.of(1970, 1, 1);
}

private class Person
{
    private string name;
    private long age;
    private LocalDateTime birth_date;
    private double balance;

    this()
    {
        age = 42; // custom "default" value for a primitive
    }

    string getName()
    {
        return name;
    }

    void setName(string name)
    {
        this.name = name;
    }

    long getAge()
    {
        return age;
    }

    void setAge(long age)
    {
        this.age = age;
    }

    LocalDateTime getBirth_date()
    {
        return birth_date;
    }

    void setBirth_date(LocalDateTime birth_date)
    {
        this.birth_date = birth_date;
    }

    double getBalance()
    {
        return balance;
    }

    void setBalance(double balance)
    {
        this.balance = balance;
    }
}

private abstract class AbstractPerson
{
    private string name;
    private long age;
    private LocalDateTime birthDate;

    string getName()
    {
        return name;
    }

    void setName(string name)
    {
        this.name = name;
    }

    long getAge()
    {
        return age;
    }

    void setAge(long age)
    {
        this.age = age;
    }

    LocalDateTime getBirthDate()
    {
        return birthDate;
    }

    void setBirthDate(LocalDateTime birthDate)
    {
        this.birthDate = birthDate;
    }
}

private class ConcretePerson : AbstractPerson
{
    private double balance;

    double getBalance()
    {
        return balance;
    }

    void setBalance(double balance)
    {
        this.balance = balance;
    }
}

private class ExtendedPerson : ConcretePerson
{
    private Any someField;

    Any getSomeField()
    {
        return someField;
    }

    void setSomeField(Any someField)
    {
        this.someField = someField;
    }
}

private class SpacePerson
{
    private string lastName;
    private long age;
    private LocalDateTime birthDate;
    private double balance;

    string getLastName()
    {
        return lastName;
    }

    void setLastName(string lastName)
    {
        this.lastName = lastName;
    }

    long getAge()
    {
        return age;
    }

    void setAge(long age)
    {
        this.age = age;
    }

    LocalDateTime getBirthDate()
    {
        return birthDate;
    }

    void setBirthDate(LocalDateTime birthDate)
    {
        this.birthDate = birthDate;
    }

    double getBalance()
    {
        return balance;
    }

    void setBalance(double balance)
    {
        this.balance = balance;
    }
}

private class DatePerson
{
    private string lastName;
    private long age;
    private LocalDate birthDate;
    private double balance;

    string getLastName()
    {
        return lastName;
    }

    void setLastName(string lastName)
    {
        this.lastName = lastName;
    }

    long getAge()
    {
        return age;
    }

    void setAge(long age)
    {
        this.age = age;
    }

    LocalDate getBirthDate()
    {
        return birthDate;
    }

    void setBirthDate(LocalDate birthDate)
    {
        this.birthDate = birthDate;
    }

    double getBalance()
    {
        return balance;
    }

    void setBalance(double balance)
    {
        this.balance = balance;
    }
}

private class EmailPerson
{
    private string name;
    private long age;
    private LocalDateTime birth_date;
    private double balance;
    private string eMail;

    string getName()
    {
        return name;
    }

    void setName(string name)
    {
        this.name = name;
    }

    long getAge()
    {
        return age;
    }

    void setAge(long age)
    {
        this.age = age;
    }

    LocalDateTime getBirth_date()
    {
        return birth_date;
    }

    void setBirth_date(LocalDateTime birth_date)
    {
        this.birth_date = birth_date;
    }

    double getBalance()
    {
        return balance;
    }

    void setBalance(double balance)
    {
        this.balance = balance;
    }

    void setEMail(string email)
    {
        this.eMail = email;
    }

    string getEMail()
    {
        return eMail;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// AbstractRowMapperTests

private void verifyPerson(Person person)
{
    assert(person.getName() == "Bubba");
    assert(person.getAge() == 22);
    assert(person.getBirth_date() == birthDateTime());
    assert(person.getBalance() == 1234.56);
    version (FlintBeanWrapper) // flint.beans has no BeanWrapper
        verifyPersonViaBeanWrapper(person);
}

private void verifyPerson(ConcretePerson person)
{
    assert(person.getName() == "Bubba");
    assert(person.getAge() == 22);
    assert(person.getBirthDate() == birthDateTime());
    assert(person.getBalance() == 1234.56);
    version (FlintBeanWrapper) // flint.beans has no BeanWrapper
        verifyPersonViaBeanWrapper(person);
}

private void verifyPerson(SpacePerson person)
{
    assert(person.getLastName() == "Bubba");
    assert(person.getAge() == 22);
    assert(person.getBirthDate() == birthDateTime());
    assert(person.getBalance() == 1234.56);
}

private void verifyPerson(DatePerson person)
{
    assert(person.getLastName() == "Bubba");
    assert(person.getAge() == 22);
    assert(person.getBirthDate() == birthDate());
    assert(person.getBalance() == 1234.56);
}

private void verifyPerson(EmailPerson person)
{
    assert(person.getName() == "Bubba");
    assert(person.getAge() == 22);
    assert(person.getBirth_date() == birthDateTime());
    assert(person.getBalance() == 1234.56);
    assert(person.getEMail() == "hello@world.info");
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
    int closeCalls;

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
        return new MockMetaData(labels);
    }

    override int findColumn(string label)
    {
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
// BeanPropertyRowMapperTests

version (FlintJdbcRowMapperMappedClass) // BeanPropertyRowMapper!T fixes its class; there is no setMappedClass
{
    @("BeanPropertyRowMapperTests.overridingDifferentClassDefinedForMapping")
    unittest
    {
        auto mapper = new BeanPropertyRowMapper!Person;
        expectThrows!InvalidDataAccessApiUsageException({ mapper.setMappedClass(typeid(long)); });
    }

    @("BeanPropertyRowMapperTests.overridingSameClassDefinedForMapping")
    unittest
    {
        auto mapper = new BeanPropertyRowMapper!Person;
        mapper.setMappedClass(typeid(Person));
    }
}

@("BeanPropertyRowMapperTests.staticQueryWithRowMapper")
unittest
{
    auto mock = new Mock;
    auto person = mock.getJdbcTemplate().queryForObject("select name, age, birth_date, balance from people",
            new BeanPropertyRowMapper!Person);
    verifyPerson(person);
    mock.verifyClosed();
}

// BeanPropertyRowMapper maps only T's own setters: inherited bean properties stay unset
version (FlintJdbcRowMapperInheritedProperties)
{
    @("BeanPropertyRowMapperTests.mappingWithInheritance")
    unittest
    {
        auto mock = new Mock;
        auto person = mock.getJdbcTemplate().queryForObject("select name, age, birth_date, balance from people",
                new BeanPropertyRowMapper!ConcretePerson);
        verifyPerson(person);
        mock.verifyClosed();
    }
}

// BeanPropertyRowMapper maps only T's own setters: inherited bean properties stay unset
version (FlintJdbcRowMapperInheritedProperties)
{
    @("BeanPropertyRowMapperTests.mappingWithNoUnpopulatedFieldsFound")
    unittest
    {
        auto mock = new Mock;
        auto person = mock.getJdbcTemplate().queryForObject("select name, age, birth_date, balance from people",
                new BeanPropertyRowMapper!ConcretePerson(true));
        verifyPerson(person);
        mock.verifyClosed();
    }
}

// BeanPropertyRowMapper maps only T's own setters: inherited bean properties stay unset
version (FlintJdbcRowMapperInheritedProperties)
{
    @("BeanPropertyRowMapperTests.mappingWithUnpopulatedFieldsNotChecked")
    unittest
    {
        auto mock = new Mock;
        auto person = mock.getJdbcTemplate().queryForObject("select name, age, birth_date, balance from people",
                new BeanPropertyRowMapper!ExtendedPerson);
        verifyPerson(person);
        mock.verifyClosed();
    }
}

@("BeanPropertyRowMapperTests.mappingWithUnpopulatedFieldsNotAccepted")
unittest
{
    auto mapper = new BeanPropertyRowMapper!ExtendedPerson(true);
    auto mock = new Mock;
    expectThrows!InvalidDataAccessApiUsageException({
        mock.getJdbcTemplate().query("select name, age, birth_date, balance from people", mapper);
    });
}

@("BeanPropertyRowMapperTests.mappingNullValue")
unittest
{
    auto mapper = new BeanPropertyRowMapper!Person;
    auto mock = new Mock(MockType.TWO);
    expectThrows!TypeMismatchDataAccessException({
        mock.getJdbcTemplate().query(SELECT_NULL_AS_AGE, mapper);
    });
}

@("BeanPropertyRowMapperTests.mappingNullValueWithPrimitivesDefaultedForNullValue")
unittest
{
    auto mapper = new BeanPropertyRowMapper!Person;
    mapper.setPrimitivesDefaultedForNullValue(true);
    auto mock = new Mock(MockType.TWO);
    auto person = mock.getJdbcTemplate().queryForObject(SELECT_NULL_AS_AGE, mapper);
    assert(person.getAge() == 42);
    mock.verifyClosed();
}

@("BeanPropertyRowMapperTests.queryWithSpaceInColumnNameAndLocalDateTime")
unittest
{
    auto mock = new Mock(MockType.THREE);
    auto person = mock.getJdbcTemplate().queryForObject(
            "select last_name as \"Last Name\", age, birth_date, balance from people",
            new BeanPropertyRowMapper!SpacePerson);
    verifyPerson(person);
    mock.verifyClosed();
}

// The row mappers pass the raw column value on: no conversion of a timestamp to a LocalDate property
version (FlintJdbcRowMapperValueConversion)
{
    @("BeanPropertyRowMapperTests.queryWithSpaceInColumnNameAndLocalDate")
    unittest
    {
        auto mock = new Mock(MockType.THREE);
        auto person = mock.getJdbcTemplate()
            .queryForObject("select last_name as \"Last Name\", age, birth_date, balance from people",
                    new BeanPropertyRowMapper!DatePerson);
        verifyPerson(person);
        mock.verifyClosed();
    }
}

// BeanPropertyRowMapper maps only T's own setters: inherited bean properties stay unset
version (FlintJdbcRowMapperInheritedProperties)
{
    @("BeanPropertyRowMapperTests.queryWithDirectNameMatchOnBirthDate")
    unittest
    {
        auto mock = new Mock(MockType.FOUR);
        auto person = mock.getJdbcTemplate().queryForObject("select name, age, birthdate, balance from people",
                new BeanPropertyRowMapper!ConcretePerson);
        verifyPerson(person);
        mock.verifyClosed();
    }
}

version (FlintJdbcRowMapperMappedNames) // BeanPropertyRowMapper has no mappedNames(PropertyDescriptor) hook
{
    /// `@MyColumnName`: a custom column name for a setter.
    private struct MyColumnName
    {
        string value;
    }

    private class CustomPerson : Person
    {
        @MyColumnName("birthdate") override void setBirth_date(LocalDateTime date)
        {
            super.setBirth_date(date);
        }
    }

    private class CustomBeanPropertyRowMapper : BeanPropertyRowMapper!CustomPerson
    {
        import flint.engine.aot.descriptor : PropertyDescriptor, findAnnotation;

        protected override bool[string] mappedNames(ref const PropertyDescriptor pd)
        {
            auto mappedNames = super.mappedNames(pd);
            if (auto customName = findAnnotation(pd.annotations, "MyColumnName"))
                mappedNames[customName.value.get!MyColumnName.value] = true;
            return mappedNames;
        }
    }

    @("BeanPropertyRowMapperTests.queryWithCustomNameMatchOnBirthDate")
    unittest
    {
        auto mock = new Mock(MockType.FOUR);
        Person person = mock.getJdbcTemplate()
            .queryForObject("select name, age, birthdate, balance from people", new CustomBeanPropertyRowMapper);
        verifyPerson(person);
        mock.verifyClosed();
    }
}

@("BeanPropertyRowMapperTests.queryWithUnderscoreInColumnNameAndPerson"
        ~ "WithMultipleAdjacentUppercaseLettersInPropertyName")
unittest
{
    auto mock = new Mock;
    auto person = mock.getJdbcTemplate().queryForObject(
            "select name, age, birth_date, balance, e_mail from people", new BeanPropertyRowMapper!EmailPerson);
    verifyPerson(person);
    mock.verifyClosed();
}

@("BeanPropertyRowMapperTests.underscoreName")
unittest
{
    static immutable string[2][] cases = [
        ["age", "age"], ["lastName", "last_name"], ["Name", "name"], ["FirstName", "first_name"],
        ["EMail", "e_mail"], ["URL", "u_r_l"], // likely undesirable, but that's the status quo
    ];
    foreach (c; cases)
        assert(JdbcUtils.convertPropertyNameToUnderscoreName(c[0]) == c[1], c[0]);
}
