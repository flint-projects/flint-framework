module app;
import golden.migrations : migrations;
import flint.arena : Result, Status, Text;
import flint.conc : Context;
import flint.engine.data : Table, Id, Column, CrudRepository, SqlRepository;
import flint.engine.di : Service, BeanRegistrar, Bind, AppContext, Provided;
import flint.engine.migrate : MigrationOptions, migrate;
import flint.serde : JsonName;
import flint.validate : Valid, NotBlank;
import flint.engine.web : RestController, Get, Post, PathVariable, RequestBody, RequestContext,
    ServerOptions, runApplication;
import flint.engine.sql : Pool, PoolOptions, Driver;
import std.conv : ConvException, to;

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
int main(string[] arguments)
{
    if (arguments.length > 2)
        return 64;
    ushort port = 8080;
    if (arguments.length == 2)
    {
        try
            port = arguments[1].to!ushort;
        catch (ConvException)
            return 64;
        if (port == 0)
            return 64;
    }
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

    const schema = migrate(pool, migrations, MigrationOptions.init, shutdownContext);
    if (!schema.ok())
        return 2;

    AppContext!(Provided!Pool, UserBindings, UserService, UserController) context;
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
    server.port = port;
    return runApplication!Application(application, server);
}

static assert(__traits(getAttributes, User).length > 0);
static assert(__traits(getAttributes, UserController).length > 0);
