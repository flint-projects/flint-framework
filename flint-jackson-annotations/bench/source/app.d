/// Jackson annotations: @JsonProperty, @JsonIgnore and @JsonPropertyOrder read at compile time.
module app;

import flint.jackson.annotation : JsonIgnore, JsonProperty, JsonPropertyOrder;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

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
    emit(args.length > 1 ? renamed : renamed ~ " " ~ first ~ " " ~ cast(char)('0' + ignored));
    return 0;
}
