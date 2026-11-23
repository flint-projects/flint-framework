module flint.engine.templates.utf8;

@safe:

/// A decoded scalar and whether the input formed valid UTF-8.
struct Scalar
{
    /// Unicode scalar value.
    uint value;
    /// The scalar passed the UTF-8 range and continuation checks.
    bool valid;
}

/// Read one UTF-8 sequence at an in-range cursor.
Scalar decodeScalar(scope const(char)[] text, ref size_t cursor) pure nothrow @nogc
{
    const lead = cast(ubyte) text[cursor++];
    if (lead < 0x80)
        return Scalar(lead, true);

    uint value;
    uint minimum;
    uint trailing;
    if (lead >= 0xc2 && lead <= 0xdf)
    {
        value = lead & 0x1f;
        minimum = 0x80;
        trailing = 1;
    }
    else if (lead >= 0xe0 && lead <= 0xef)
    {
        value = lead & 0x0f;
        minimum = 0x800;
        trailing = 2;
    }
    else if (lead >= 0xf0 && lead <= 0xf4)
    {
        value = lead & 0x07;
        minimum = 0x10000;
        trailing = 3;
    }
    else
        return Scalar.init;
    if (text.length - cursor < trailing)
        return Scalar.init;

    foreach (unused; 0 .. trailing)
    {
        const next = cast(ubyte) text[cursor++];
        if ((next & 0xc0) != 0x80)
            return Scalar.init;
        value = (value << 6) | (next & 0x3f);
    }
    const surrogate = value >= 0xd800 && value <= 0xdfff;
    return Scalar(value, value >= minimum && value <= 0x10ffff && !surrogate);
}
