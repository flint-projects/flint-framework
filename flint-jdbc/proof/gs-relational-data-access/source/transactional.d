/++
`@Transactional` around the guide's inserts, on the real Flint driver: a commit keeps the rows, and a runtime
exception rolls them back (docs/spring/phase1/data-access.md, "The sample").

`CustomerService__FlintProxy` is what Flint AOT emits for a bean with `@Transactional` methods: a subclass that
forwards each advised call through the runtime's `adviceChain`, whose only advisor here is `TransactionInterceptor`.
It is written out by hand until the Boot port generates it. `Beans` stands in for the application context.
+/
module transactional;

import flint.engine.aot.any : Any;
import flint.engine.aot.bean : BeanFactory;
import flint.engine.aot.descriptor : Descriptor, MergedAnnotation, MethodDescriptor, TypeKind;
import flint.engine.aot.proxy : AdviceChain, Invocation, adviceChain;
import flint.engine.jdbc : FlintDataSource;
import flint.java.lang : RuntimeException;
import flint.jdbc.core : JdbcTemplate;
import flint.jdbc.datasource : DataSourceTransactionManager;
import flint.transaction.annotation : Transactional;
import flint.transaction.interceptor : TransactionInterceptor;

@safe:

/// A service with transactional methods, as an application writes it.
class CustomerService
{
    private JdbcTemplate jdbcTemplate;

    /// Use `jdbcTemplate` for every statement.
    this(JdbcTemplate jdbcTemplate)
    {
        this.jdbcTemplate = jdbcTemplate;
    }

    /// Insert every name in one transaction.
    @Transactional
    void insertAll(string[][] names)
    {
        jdbcTemplate.batchUpdate("INSERT INTO customers(first_name, last_name) VALUES (?,?)", names);
    }

    /// Insert a name, then fail: the transaction rolls back.
    @Transactional
    void insertThenFail(string firstName, string lastName)
    {
        jdbcTemplate.update("INSERT INTO customers(first_name, last_name) VALUES (?,?)", firstName, lastName);
        throw new RuntimeException("Simulated failure after the insert");
    }
}

/// What Flint AOT emits for `CustomerService`: the proxy forwards to a separate target through the advice chain.
final class CustomerService__FlintProxy : CustomerService
{
    private CustomerService target;
    private Descriptor descriptor;
    private AdviceChain chain;

    /// Advise `target`, whose methods `descriptor` describes, with `chain`.
    this(CustomerService target, Descriptor descriptor, AdviceChain chain)
    {
        super(null);
        this.target = target;
        this.descriptor = descriptor;
        this.chain = chain;
    }

    override void insertAll(string[][] names)
    {
        auto invocation = Invocation(&descriptor.methods[0], target, [Any.of(names)]);
        chain.invoke(invocation, (ref Invocation) @safe { target.insertAll(names); });
    }

    override void insertThenFail(string firstName, string lastName)
    {
        auto invocation = Invocation(&descriptor.methods[1], target, [
            Any.of(firstName), Any.of(lastName)
        ]);
        chain.invoke(invocation, (ref Invocation) @safe {
            target.insertThenFail(firstName, lastName);
        });
    }
}

/// `CustomerService`'s descriptor, with each method's merged `@Transactional`, as Flint AOT records it.
Descriptor customerServiceDescriptor()
{
    auto descriptor = new Descriptor("transactional.CustomerService", TypeKind.class_);
    foreach (index, name; ["insertAll", "insertThenFail"])
    {
        MethodDescriptor method;
        method.name = name;
        method.returnType = "void";
        method.index = cast(uint) index;
        method.annotations = [
            MergedAnnotation("flint.transaction.annotation.Transactional", Any.of(Transactional()), 0)
        ];
        descriptor.methods ~= method;
    }
    return descriptor;
}

/// The beans the context would hold: the transaction manager and the interceptor, the only advisor.
final class Beans : BeanFactory
{
    /// The `transactionManager` bean.
    DataSourceTransactionManager transactionManager;
    /// The interceptor, the only `Advisor` bean.
    TransactionInterceptor interceptor;

    /// The bean factory call the advice chain makes.
    Object getBean(string name)
    {
        return name == "transactionManager" ? transactionManager : null;
    }

    /// The bean factory call the advice chain makes.
    Object getBeanOfType(string type, string = null)
    {
        if (auto bean = findBeanOfType(type))
            return bean;
        throw new RuntimeException("No qualifying bean of type '" ~ type ~ "' available");
    }

    /// The bean factory call the advice chain makes.
    Object findBeanOfType(string type, string = null)
    {
        return type == "flint.transaction.TransactionManager" ? transactionManager : null;
    }

    /// The bean factory call the advice chain makes.
    Object[] getBeansOfType(string type)
    {
        return type == "flint.engine.aot.proxy.Advisor" ? [cast(Object) interceptor] : null;
    }

    /// The bean factory call the advice chain makes.
    Any resolveValue(string, string)
    {
        return Any.init;
    }

    /// Not used by the proxy.
    void bind(string, Any)
    {
    }

    /// Not used by the proxy.
    Any bindConstructor(string, string)
    {
        return Any.init;
    }
}

@("@Transactional on the Flint driver: the inserts commit together, and a runtime exception rolls back")
unittest
{
    auto dataSource = new FlintDataSource("jdbc:sqlite:file:gs-relational-transactional?mode=memory&cache=shared");
    scope (exit)
        dataSource.close();
    auto jdbcTemplate = new JdbcTemplate(dataSource);
    jdbcTemplate.execute("DROP TABLE IF EXISTS customers");
    jdbcTemplate.execute(
            "CREATE TABLE customers(id INTEGER PRIMARY KEY, first_name VARCHAR(255), last_name VARCHAR(255))");

    auto beans = new Beans;
    beans.transactionManager = new DataSourceTransactionManager(dataSource);
    beans.interceptor = new TransactionInterceptor;
    beans.interceptor.setBeanFactory(beans);
    auto descriptor = customerServiceDescriptor();
    CustomerService service = new CustomerService__FlintProxy(new CustomerService(jdbcTemplate),
            descriptor, adviceChain(beans, descriptor));

    service.insertAll([["John", "Woo"], ["Jeff", "Dean"], ["Josh", "Bloch"], ["Josh", "Long"]]);
    assert(jdbcTemplate.queryForObject!long("SELECT count(*) FROM customers") == 4, "the batch committed");

    try
    {
        service.insertThenFail("Rod", "Johnson");
        assert(false, "expected the runtime exception");
    }
    catch (RuntimeException ex)
        assert(ex.msg == "Simulated failure after the insert");
    assert(jdbcTemplate.queryForObject!long("SELECT count(*) FROM customers WHERE first_name = ?",
            "Rod") == 0, "the failed insert rolled back");
    assert(jdbcTemplate.queryForObject!long("SELECT count(*) FROM customers") == 4);
}
