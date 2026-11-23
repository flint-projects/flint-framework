module flint.engine.web.openapi_behavior;

import flint.arena : Result;
import flint.serde : JsonIgnore, JsonName;
import flint.engine.web : Delete, Get, PathVariable, Post, QueryParam, RequestBody, RestController, openApiDocument;

@safe:

private enum Priority
{
    low,
    high
}

private struct Note
{
    ulong id;
    string title;
    @JsonName("body_text") string body;
    Priority priority;
    string[] tags;
    @JsonIgnore string secret;
}

private struct NewNote
{
    string title;
    double weight;
    bool pinned;
}

@RestController("/api/notes")
private struct NoteController
{
    @Get("/:id")
    Result!Note get(@PathVariable("id") ulong id)
    {
        return Result!Note(Note(id));
    }

    @Get("")
    Result!(Note[]) list(@QueryParam("tag") string tag)
    {
        return Result!(Note[])([Note(1, tag)]);
    }

    @Post("")
    Result!Note create(@RequestBody NewNote note)
    {
        return Result!Note(Note(1, note.title));
    }

    @Delete("/:id")
    void remove(@PathVariable("id") ulong id)
    {
        assert(id != 0);
    }
}

private struct Application
{
    NoteController notes;
}

@("the OpenAPI document lists every route with its parameters, body and response schema")
unittest
{
    import std.json : JSONValue, parseJSON;

    enum text = openApiDocument!Application("Notes", "1.2.0");
    const document = parseJSON(text);
    assert(document["openapi"].str == "3.1.0" && document["info"]["title"].str == "Notes");
    const one = document["paths"]["/api/notes/{id}"];
    const get = one["get"];
    assert(get["operationId"].str == "NoteController.get");
    assert(get["parameters"][0]["name"].str == "id" && get["parameters"][0]["in"].str == "path");
    assert(get["parameters"][0]["schema"]["format"].str == "int64");
    const note = get["responses"]["200"]["content"]["application/json"]["schema"];
    assert(note["title"].str == "Note" && note["type"].str == "object");
    assert("body_text" in note["properties"] && "secret" !in note["properties"] && "body" !in note["properties"]);
    assert(note["properties"]["priority"]["enum"][1].str == "high");
    assert(note["properties"]["tags"]["items"]["type"].str == "string");
    assert("204" in one["delete"]["responses"]);
    const all = document["paths"]["/api/notes"];
    assert(all["get"]["parameters"][0]["in"].str == "query" && all["get"]["parameters"][0]["name"].str == "tag");
    assert(all["get"]["responses"]["200"]["content"]["application/json"]["schema"]["type"].str == "array");
    const create = all["post"];
    assert(create["requestBody"]["content"]["application/json"]["schema"]["title"].str == "NewNote");
    assert(
            create["requestBody"]["content"]["application/json"]["schema"]["properties"]["weight"]["type"].str
            == "number");
    assert("201" in create["responses"]);
}
