/// Jackson annotations: @JsonProperty, @JsonIgnore and @JsonPropertyOrder read at compile time.
module app;

import flint.jackson.annotation : JsonIgnore, JsonProperty, JsonPropertyOrder;
import std.stdio : writeln;

@safe:

@JsonPropertyOrder(["id", "name"]) private struct Owner
{
    @JsonProperty("owner_id") long id;
    @JsonIgnore string password;
}

int main(string[] args)
{
    enum renamed = __traits(getAttributes, Owner.id)[0].value;
    enum first = __traits(getAttributes, Owner)[0].value[0];
    enum ignored = __traits(getAttributes, Owner.password).length;
    writeln(args.length > 1 ? renamed : renamed ~ " " ~ first ~ " " ~ cast(char)('0' + ignored));
    return 0;
}
