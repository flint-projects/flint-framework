/// Canonical, unpadded base64url decoding for compact JWTs and JWK fields.
module flint.security.base64url;

@safe:
nothrow @nogc:

private int digit(ubyte character) pure
{
    if (character >= 'A' && character <= 'Z')
        return character - 'A';
    if (character >= 'a' && character <= 'z')
        return character - 'a' + 26;
    if (character >= '0' && character <= '9')
        return character - '0' + 52;
    if (character == '-')
        return 62;
    return character == '_' ? 63 : -1;
}

package(flint.security) bool decodeUrl64(scope const(ubyte)[] encoded, scope ubyte[] output, out size_t written) pure
{
    const tail = encoded.length % 4;
    if (tail == 1)
        return false;
    const needed = (encoded.length / 4) * 3 + (tail ? tail - 1 : 0);
    if (needed > output.length)
        return false;

    uint accumulator;
    uint bits;
    foreach (item; encoded)
    {
        const value = digit(item);
        if (value < 0)
            return false;
        accumulator = (accumulator << 6) | cast(uint) value;
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            output[written++] = cast(ubyte)(accumulator >> bits);
        }
    }
    return (accumulator & ((1U << bits) - 1)) == 0;
}
