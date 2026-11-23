/// OpenAPI 3.1 documents generated from controllers at compile time (ADR-028 section 5).
///
/// The document is built from the same route table and argument plan that serve requests, so it cannot drift from
/// the application: paths, methods, path and query parameters, JSON bodies, and success responses with their JSON
/// schemas. Object schemas are inline and carry the D type name as `title`, which client generators use to name
/// types.
module flint.engine.web.internal.openapi;

import flint.arena : Error, Result, Text;
import flint.engine.web.types : Method, Response;

@safe:

/// The OpenAPI 3.1 document, as JSON, for the controllers of `App` (a controller, or a struct whose fields are
/// controllers, as `runApplication` takes).
string openApiDocument(App)(string title, string apiVersion)
{
    import flint.engine.web.internal.controllers : controllerOperations;

    string paths;
    string[] seen;
    string[] bodies;
    static if (__traits(compiles, controllerOperations!App))
        collect(controllerOperations!App, seen, bodies);
    else
    {
        static foreach (Field; typeof(App.tupleof))
        {
            static if (__traits(compiles, controllerOperations!Field))
                collect(controllerOperations!Field, seen, bodies);
        }
    }
    foreach (index, path; seen)
        paths ~= (index ? "," : "") ~ quote(path) ~ ":{" ~ bodies[index] ~ "}";
    return `{"openapi":"3.1.0","info":{"title":` ~ quote(title) ~ `,"version":` ~ quote(
            apiVersion) ~ `},"paths":{` ~ paths ~ `}}`;
}

/// One documented operation.
package(flint.engine.web) struct Operation
{
    /// OpenAPI path, such as `/api/notes/{id}`.
    string path;
    /// Lower-case method.
    string method;
    /// `Controller.handler`, which is the operationId.
    string id;
    /// Parameters array, as JSON.
    string parameters;
    /// Request body schema, or empty.
    string requestBody;
    /// Success status.
    string status;
    /// Success schema, or empty for no content.
    string response;
}

private void collect(scope const Operation[] operations, ref string[] paths, ref string[] bodies)
{
    foreach (ref operation; operations)
    {
        string text = quote(operation.method) ~ `:{"operationId":` ~ quote(
                operation.id) ~ `,"parameters":[` ~ operation.parameters ~ "]";
        if (operation.requestBody.length)
            text ~= `,"requestBody":{"required":true,"content":{"application/json":{"schema":`
                ~ operation.requestBody ~ "}}}";
        text ~= `,"responses":{` ~ quote(operation.status) ~ `:{"description":"Success"`;
        if (operation.response.length)
            text ~= `,"content":{"application/json":{"schema":` ~ operation.response ~ "}}";
        text ~= `},"default":{"description":"Error","content":{"application/json":{"schema":`
            ~ `{"type":"object","properties":{"error":{"type":"string"}}}}}}}}`;
        size_t index;
        while (index < paths.length && paths[index] != operation.path)
            index++;
        if (index == paths.length)
        {
            paths ~= operation.path;
            bodies ~= text;
        }
        else
            bodies[index] ~= "," ~ text;
    }
}

/// `/api/notes/:id` as `/api/notes/{id}`.
package(flint.engine.web) string openApiPath(string path) pure
{
    string result;
    size_t index;
    while (index < path.length)
    {
        if (path[index] == ':' && (index == 0 || path[index - 1] == '/'))
        {
            size_t end = index + 1;
            while (end < path.length && path[end] != '/')
                end++;
            result ~= "{" ~ path[index + 1 .. end] ~ "}";
            index = end;
        }
        else
            result ~= path[index++];
    }
    return result;
}

/// The lower-case OpenAPI method name.
package(flint.engine.web) string methodName(Method method) pure
{
    final switch (method)
    {
    case Method.get:
        return "get";
    case Method.post:
        return "post";
    case Method.put:
        return "put";
    case Method.delete_:
        return "delete";
    case Method.patch:
        return "patch";
    case Method.head:
        return "head";
    case Method.options:
        return "options";
    }
}

/// The JSON schema of a D type as flint:serde writes it.
package(flint.engine.web) string schemaOf(T)()
{
    import std.traits : isFloatingPoint, isIntegral, isSomeString, Unqual;

    alias U = Unqual!T;
    static if (is(U == Result!V, V))
        return schemaOf!V();
    else static if (is(U == bool))
        return `{"type":"boolean"}`;
    else static if (is(U == enum))
    {
        import std.traits : EnumMembers;

        string values;
        static foreach (index, member; __traits(allMembers, U))
            values ~= (index ? "," : "") ~ quote(member);
        return `{"type":"string","enum":[` ~ values ~ "]}";
    }
    else static if (isIntegral!U)
        return `{"type":"integer","format":"` ~ (U.sizeof == 8 ? "int64" : "int32") ~ `"}`;
    else static if (isFloatingPoint!U)
        return `{"type":"number"}`;
    else static if (isSomeString!U || is(U == Text))
        return `{"type":"string"}`;
    else static if (is(U == E[], E))
        return `{"type":"array","items":` ~ schemaOf!E() ~ "}";
    else static if (is(U == struct))
        return objectSchema!U();
    else
        return "{}";
}

private string objectSchema(T)()
{
    import flint.serde : JsonIgnore, JsonName;

    string properties;
    string required;
    static foreach (index, field; T.tupleof)
    {
        {
            enum name = jsonFieldName!(T, index);
            static if (name.length)
            {
                properties ~= (properties.length ? "," : "") ~ quote(name) ~ ":" ~ schemaOf!(typeof(field))();
                required ~= (required.length ? "," : "") ~ quote(name);
            }
        }
    }
    return `{"title":` ~ quote(
            T.stringof) ~ `,"type":"object","properties":{` ~ properties ~ `},"required":[` ~ required ~ "]}";
}

// A field's JSON name, or empty when serde ignores it.
private template jsonFieldName(T, size_t index)
{
    import flint.serde : JsonIgnore, JsonName;

    enum jsonFieldName = () {
        string name = __traits(identifier, T.tupleof[index]);
        static foreach (attribute; __traits(getAttributes, T.tupleof[index]))
        {
            static if (is(attribute == JsonIgnore) || is(typeof(attribute) == JsonIgnore))
                name = null;
            else static if (is(typeof(attribute) == JsonName))
                name = attribute.value;
        }
        return name;
    }();
}

/// A JSON string literal.
package(flint.engine.web) string quote(string text) pure
{
    string result = `"`;
    foreach (ch; text)
    {
        if (ch == '"' || ch == '\\')
            result ~= '\\';
        result ~= ch;
    }
    return result ~ `"`;
}
