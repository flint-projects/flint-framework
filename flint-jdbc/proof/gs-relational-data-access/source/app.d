/++
spring-guides/gs-relational-data-access `complete/` (commit 39ee641, the reference pinned in benchmarks/spring/apps.json):
`RelationalDataAccessApplication.java` and `Customer.java`, written in Flint under the rulebook. Copyright the original
author or authors. Licensed under the Apache License, Version 2.0.

gs-relational-data-access on Flint: the guide's `CommandLineRunner`, one to one, on `flint:jdbc`'s `JdbcTemplate`
over the Flint JDBC driver, logging through Boot's console format.

This is the data-access proof fixture, not the Boot port. The port is a Boot application under
`benchmarks/spring/flint/gs-relational-data-access/`; it arrives with Boot's JDBC auto-configuration, which builds
this same data source and template from `flint.datasource.url`. Until then `main` wires them by hand.

As in the Go comparator and docs/spring/phase1/data-access.md, the database is SQLite in memory (H2 is JVM-only), so
the guide's H2 column type `id SERIAL` becomes `id INTEGER PRIMARY KEY`. `FLINT_DATASOURCE_URL` selects another
database, such as `jdbc:postgresql://127.0.0.1:5432/app`, where `SERIAL` is kept.
+/
module app;

import flint.boot.logging : ConsoleLogFormat;
import flint.boot.logging.slf4j : Slf4jLoggingSystem;
import flint.engine.jdbc : FlintDataSource;
import flint.java.sql : ResultSet;
import flint.jdbc.core : JdbcTemplate;
import flint.slf4j : Logger, LoggerFactory;

@safe:

/// `com.example.relationaldataaccess.Customer`.
final class Customer
{
    private long id;
    private string firstName, lastName;

    /// A customer record.
    this(long id, string firstName, string lastName)
    {
        this.id = id;
        this.firstName = firstName;
        this.lastName = lastName;
    }

    /// The guide's `toString`, which the log lines print.
    override string toString() const
    {
        import std.format : format;

        return format("Customer[id=%d, firstName='%s', lastName='%s']", id, firstName, lastName);
    }
}

/// `com.example.relationaldataaccess.RelationalDataAccessApplication`, a `CommandLineRunner`.
final class RelationalDataAccessApplication
{
    private enum loggerName = "com.example.relationaldataaccess.RelationalDataAccessApplication";

    private JdbcTemplate jdbcTemplate;
    private bool sqlite;

    /// Run on `jdbcTemplate`; `sqlite` selects the SQLite column type for `id`.
    this(JdbcTemplate jdbcTemplate, bool sqlite)
    {
        this.jdbcTemplate = jdbcTemplate;
        this.sqlite = sqlite;
    }

    /// `CommandLineRunner.run`: the guide's steps, logged as it logs them.
    void run(string[]...)
    {
        import std.algorithm.iteration : map, splitter;
        import std.array : array;

        auto log = LoggerFactory.getLogger(loggerName);
        log.info("Creating tables");

        jdbcTemplate.execute("DROP TABLE IF EXISTS customers");
        jdbcTemplate.execute("CREATE TABLE customers(" ~ (sqlite
                ? "id INTEGER PRIMARY KEY" : "id SERIAL") ~ ", first_name VARCHAR(255), last_name VARCHAR(255))");

        // Split up the array of whole names into an array of first/last names
        string[][] splitUpNames = ["John Woo", "Jeff Dean", "Josh Bloch", "Josh Long"].map!(
                name => name.splitter(" ").array).array;

        // Print out each tuple of the list
        foreach (name; splitUpNames)
            log.info("Inserting customer record for {} {}", name[0], name[1]);

        // Use JdbcTemplate's batchUpdate operation to bulk load data
        jdbcTemplate.batchUpdate("INSERT INTO customers(first_name, last_name) VALUES (?,?)", splitUpNames);

        log.info("Querying for customer records where first_name = 'Josh':");
        jdbcTemplate.query("SELECT id, first_name, last_name FROM customers WHERE first_name = ?",
                (ResultSet rs, int) => new Customer(rs.getLong("id"), rs.getString("first_name"),
                    rs.getString("last_name")), "Josh").forEach((Customer customer) {
            log.info(customer.toString());
        });
    }
}

version (unittest)
{
}
else
    int main(string[] args)
{
    import std.process : environment;

    auto logging = new Slf4jLoggingSystem(ConsoleLogFormat());
    logging.initialize();
    scope (exit)
        logging.cleanUp();

    const url = environment.get("FLINT_DATASOURCE_URL", "jdbc:sqlite::memory:");
    auto dataSource = new FlintDataSource(url);
    dataSource.setUsername(environment.get("FLINT_DATASOURCE_USERNAME", null));
    dataSource.setPassword(environment.get("FLINT_DATASOURCE_PASSWORD", null));
    scope (exit)
        dataSource.close();

    const sqlite = url.length >= 12 && url[0 .. 12] == "jdbc:sqlite:";
    new RelationalDataAccessApplication(new JdbcTemplate(dataSource), sqlite).run(args[1 .. $]);
    return 0;
}
