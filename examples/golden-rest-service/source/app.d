module app;
import flint.arena : Error, Result, Text, Status, RequestArena;
import flint.conc : Context;
import flint.data : Table, Id, Column, CrudRepository, SqlRepository;
import flint.di : Service, BeanRegistrar, Bind, AppContext;
import flint.serde : JsonName;
import flint.validate : Valid, NotBlank;
import flint.web : RestController, Get, Post, PathVariable, RequestBody, RequestContext,
    ServerOptions, runApplication;
import flint.sql : Pool, PoolOptions, Driver;

@safe:

/// Row and JSON representation; text belongs to the current request arena.
@Table("users")
struct User
{
    /// Database primary key.
    @Id ulong id;
    /// Required display name with explicit SQL and JSON field names.
    @Column("display_name") @JsonName("displayName") @NotBlank Text displayName;
}

alias UserRepository = CrudRepository!(User, ulong);
alias UserBindings = BeanRegistrar!(Bind!(UserRepository, SqlRepository!(User, ulong)));

/// Constructor-injected application service over the repository contract.
@Service final class UserService
{
    private UserRepository repository;
    /// Receive the statically registered repository implementation.
    this(UserRepository repository)
    {
        this.repository = repository;
    }

    /// Find one row using the request arena and cancellation context.
    Result!User find(ulong id, ref scope RequestContext context) nothrow @nogc
    {
        return repository.findById(id, context.arena, context.cancellation);
    }

    /// Persist a validated row without allocating D GC memory.
    Result!User create(scope const ref User value, ref scope RequestContext context) nothrow @nogc
    {
        return repository.save(value, context.arena, context.cancellation);
    }
}

/// Compile-time route registration for the users resource.
@RestController("/api/users")
struct UserController
{
    /// Injected service used by both routes.
    UserService users;
    /// Receive the application service from the generated context.
    this(UserService users)
    {
        this.users = users;
    }

    /// Return one user or the framework error representation.
    @Get("/:id")
    Result!User get(@PathVariable("id") ulong id, ref scope RequestContext context)nothrow @nogc
    {
        return users.find(id, context);
    }

    /// Validate and create one request-scoped user value.
    @Post("")
    Result!User post(@RequestBody @Valid scope const ref User value, ref scope RequestContext context) nothrow @nogc
    {
        return users.create(value, context);
    }
}

/// Explicit root of the generated router registration.
struct Application
{
    /// Controller instance whose dependencies are already initialized.
    UserController users;
}

// Pool is externally owned; DI borrows its handle and never closes it.
int main()
{
    Pool pool;
    PoolOptions database;
    database.driver = Driver.sqlite;
    database.connectionString = "file:users.db";
    const opened = pool.open(database);
    if (opened.code != Status.ok)
        return 1;
    Context shutdownContext;
    scope (exit)
    {
        pool.close(shutdownContext);
    }

    // Standalone demonstration schema; production apps use flint:migrate.
    ubyte[4096] startupBytes;
    scope startupArena = RequestArena(startupBytes[]);
    auto leased = pool.acquire(shutdownContext);
    if (!leased.ok())
        return 2;
    auto connection = leased.value;
    auto schema = connection.execute(
            "CREATE TABLE IF NOT EXISTS users " ~ "(id INTEGER PRIMARY KEY, display_name TEXT NOT NULL)",
            null, startupArena, shutdownContext);
    const released = pool.release(connection);
    if (!schema.ok() || released.code != Status.ok)
        return 3;

    AppContext!(Pool, UserBindings, UserService, UserController) context;
    const provided = context.provide!Pool(pool);
    if (provided.code != Status.ok)
        return 4;
    const initialized = context.initialize();
    if (initialized.code != Status.ok)
        return 5;
    scope (exit)
        context.shutdown();

    auto application = Application(context.get!UserController());
    ServerOptions server;
    server.address = "127.0.0.1";
    server.port = 8080;
    return runApplication!Application(application, server);
}

static assert(__traits(getAttributes, User).length > 0);
static assert(__traits(getAttributes, UserController).length > 0);
