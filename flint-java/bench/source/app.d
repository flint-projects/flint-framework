/// java.util collections and streams: ArrayList, HashMap and a filter/map/toList pipeline.
module app;

import flint.java.util : ArrayList, HashMap;
import flint.java.util.stream : stream;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

int main(string[] args)
{
    auto pets = ["Leo", "Basil", "Rosy", "Jewel", args.length > 1 ? "Iggy" : "Max"];
    auto names = new ArrayList!string();
    auto lengths = new HashMap!(string, int)();
    foreach (pet; pets)
    {
        names.add(pet);
        lengths.put(pet, cast(int) pet.length);
    }
    auto longNames = stream(pets).filter((string s) => s.length > 3).map!string((string s) => s ~ "!").toList();
    emit(longNames.get(0) ~ " " ~ cast(char)('0' + longNames.size()) ~ " " ~ cast(char)(
            '0' + lengths.get("Basil")) ~ " " ~ cast(char)('0' + names.size()));
    return 0;
}
