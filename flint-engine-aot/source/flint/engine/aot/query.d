/++
Derived repository queries as Flint AOT parses them from method names (AOT contract section 4.8, section 8).
+/
module flint.engine.aot.query;

@safe:

/// What a derived query returns.
enum QueryKind
{
    list,
    single,
    optional,
    count,
    exists,
    delete_,
    stream,
}

/// One derived query.
struct DerivedQuery
{
    /// The repository interface.
    string repository;
    /// The repository method.
    string method;
    /// The repository's domain type.
    string domainType;
    /// ANSI SQL with `?` placeholders in parameter order.
    string sql;
    /// The method parameter feeding each placeholder.
    string[] parameters;
    /// Per placeholder: `""`, `"starting"`, `"ending"` or `"containing"`.
    string[] likeTransforms;
    /// What the query returns.
    QueryKind kind;
    /// `First`/`Top` N; 0 when absent.
    int limit;
    /// Where the method was declared.
    string source;
}
