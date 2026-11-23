/// `std.typecons.Nullable!T` (rulebook R5) through its descriptor: unwrap to the value or null, wrap back.
module nullable_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : descriptorOf;
import std.typecons : Nullable;

@safe:

@("descriptorOf!(Nullable!T) unwraps and wraps, and names its element type")
unittest
{
    auto d = descriptorOf!(Nullable!int)();
    assert(d.elementType == "int" && d.unwrap !is null && d.wrap !is null);
    auto present = Any.of(Nullable!int(7));
    assert(d.unwrap(present).get!int() == 7);
    auto absent = Any.of(Nullable!int.init);
    assert(d.unwrap(absent).isNull());
    assert(d.wrap(Any.of(5)).get!(Nullable!int)().get == 5);
    assert(d.wrap(Any.init).get!(Nullable!int)().isNull);

    auto text = descriptorOf!(Nullable!string)();
    assert(text.elementType == "string");
    assert(text.wrap(Any.of("")).get!(Nullable!string)().get == "");
    assert(text.wrap(Any.init).get!(Nullable!string)().isNull);
}
