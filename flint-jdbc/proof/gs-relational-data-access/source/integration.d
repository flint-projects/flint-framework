/++
`flint:jdbc` on the real Flint driver, as spring-petclinic-rest's JDBC repositories use it: `SimpleJdbcInsert` with
table metadata and a generated key, `NamedParameterJdbcTemplate` with `BeanPropertySqlParameterSource` and
`MapSqlParameterSource`, `BeanPropertyRowMapper`, and `ObjectRetrievalFailureException` for "not found". It runs on
SQLite, and on PostgreSQL when `FLINT_JDBC_PG_TEST_URL` names a server.
+/
module integration;

import flint.dao : EmptyResultDataAccessException;
import flint.engine.aot.any : Any;
import flint.engine.jdbc : FlintDataSource;
import flint.java.util : HashMap;
import flint.jdbc.core : BeanPropertyRowMapper, JdbcTemplate;
import flint.jdbc.core.namedparam : BeanPropertySqlParameterSource, MapSqlParameterSource, NamedParameterJdbcTemplate;
import flint.jdbc.core.simple : SimpleJdbcInsert;
import flint.orm : ObjectRetrievalFailureException;

@safe:

/// An owner, as petclinic's `Owner` bean.
class Owner
{
    private long id;
    private string firstName, lastName, city;

    long getId()
    {
        return id;
    }

    void setId(long id)
    {
        this.id = id;
    }

    string getFirstName()
    {
        return firstName;
    }

    void setFirstName(string firstName)
    {
        this.firstName = firstName;
    }

    string getLastName()
    {
        return lastName;
    }

    void setLastName(string lastName)
    {
        this.lastName = lastName;
    }

    string getCity()
    {
        return city;
    }

    void setCity(string city)
    {
        this.city = city;
    }
}

private void exercise(FlintDataSource dataSource, string idColumn)
{
    auto jdbcTemplate = new JdbcTemplate(dataSource);
    jdbcTemplate.execute("DROP TABLE IF EXISTS owners");
    jdbcTemplate.execute(
            "CREATE TABLE owners (" ~ idColumn ~ ", first_name VARCHAR(30), last_name VARCHAR(30), city VARCHAR(80))");

    auto insertOwner = new SimpleJdbcInsert(dataSource).withTableName("owners").usingGeneratedKeyColumns("id");
    auto owner = new Owner;
    owner.setFirstName("George");
    owner.setLastName("Franklin");
    owner.setCity("Madison");
    const firstKey = insertOwner.executeAndReturnKey(new BeanPropertySqlParameterSource(owner)).get!long;
    owner.setFirstName("Betty");
    owner.setLastName("Davis");
    const secondKey = insertOwner.executeAndReturnKey(new BeanPropertySqlParameterSource(owner)).get!long;
    assert(secondKey == firstKey + 1, "generated keys increase");
    assert(insertOwner.getInsertString() == "INSERT INTO owners (first_name, last_name, city) VALUES(?, ?, ?)",
            insertOwner.getInsertString());

    auto named = new NamedParameterJdbcTemplate(dataSource);
    auto params = new HashMap!(string, Any);
    params.put("lastName", Any.of("Dav%"));
    auto owners = named.query("SELECT id, first_name, last_name, city FROM owners WHERE last_name LIKE :lastName",
            params, new BeanPropertyRowMapper!Owner);
    assert(owners.size() == 1 && owners.get(0).getFirstName() == "Betty" && owners.get(0).getId() == secondKey);

    auto update = new MapSqlParameterSource("id", firstKey).addValue("city", "Sun Prairie");
    assert(named.update("UPDATE owners SET city = :city WHERE id = :id", update) == 1);
    assert(named.queryForObject!string("SELECT city FROM owners WHERE id = :id",
            new MapSqlParameterSource("id", firstKey)) == "Sun Prairie");

    // petclinic's findById: EmptyResultDataAccessException becomes ObjectRetrievalFailureException.
    try
    {
        try
            named.queryForObject("SELECT id, first_name, last_name, city FROM owners WHERE id = :id",
                    new MapSqlParameterSource("id", 999), new BeanPropertyRowMapper!Owner);
        catch (EmptyResultDataAccessException ex)
            throw new ObjectRetrievalFailureException(typeid(Owner), Any.of(999L));
        assert(false, "expected ObjectRetrievalFailureException");
    }
    catch (ObjectRetrievalFailureException ex)
        assert(ex.msg == "Object of class [integration.Owner] with identifier [999]: not found", ex.msg);
    jdbcTemplate.execute("DROP TABLE owners");
}

@("SimpleJdbcInsert, NamedParameterJdbcTemplate and BeanPropertyRowMapper on SQLite")
unittest
{
    auto dataSource = new FlintDataSource("jdbc:sqlite:file:petclinic-integration?mode=memory&cache=shared");
    scope (exit)
        dataSource.close();
    exercise(dataSource, "id INTEGER PRIMARY KEY");
}

@("SimpleJdbcInsert, NamedParameterJdbcTemplate and BeanPropertyRowMapper on PostgreSQL")
unittest
{
    import std.process : environment;

    const url = environment.get("FLINT_JDBC_PG_TEST_URL");
    if (url.length == 0)
        return;
    auto dataSource = new FlintDataSource(url);
    dataSource.setUsername(environment.get("FLINT_JDBC_PG_TEST_USER", null));
    scope (exit)
        dataSource.close();
    exercise(dataSource, "id SERIAL PRIMARY KEY");
}
