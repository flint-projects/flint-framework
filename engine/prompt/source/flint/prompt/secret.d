/// Explicitly wiped, move-only secret storage.
module flint.prompt.secret;

import flint.arena : Error, Status;
import flint.prompt.sys.secret : NativeSecret, allocate, append, count, readBytes = read, retire, trim, wipe;
import flint.tui : Event, EventKind, KeyCode;
import flint.widgets.editing : acceptedInput, printable, priorBoundary;
import std.utf : encode;

@safe:

/// One thread-confined native secret owner. Explicitly clear it after consumption.
struct Secret
{
    @disable this(this);

    private NativeSecret* storage;

    ~this() nothrow @nogc
    {
        clear();
    }

    /// Borrow bytes for the duration of one synchronous callback.
    Error read(scope void delegate(scope const(ubyte)[]) @safe consumer) const scope
    {
        return readBytes(storage, consumer);
    }

    /// Close intake and wipe the native allocation when its last callback returns.
    void clear() nothrow @nogc
    {
        auto current = storage;
        storage = null;
        retire(current);
    }

    package(flint.prompt) bool opened() const pure nothrow @nogc
    {
        return storage !is null;
    }

    package(flint.prompt) bool open(size_t capacity) nothrow @nogc
    {
        if (storage is null)
            storage = allocate(capacity);
        return storage !is null;
    }

    package(flint.prompt) size_t length() const nothrow @nogc
    {
        return count(storage);
    }

    package(flint.prompt) void edit(Event event, size_t capacity)
    {
        if (event.error.code != Status.ok)
            return;
        if (event.kind == EventKind.paste)
            insert(event.paste, capacity);
        else if (event.kind == EventKind.key)
            key(event, capacity);
    }

    private void key(Event event, size_t capacity)
    {
        if (event.key.code == KeyCode.backspace)
        {
            size_t boundary;
            const measured = read((scope const(ubyte)[] bytes) @safe {
                boundary = priorBoundary(cast(const(char)[]) bytes, bytes.length);
            });
            if (measured.code == Status.ok)
                trim(storage, boundary);
        }
        else if (event.key.control && event.key.character == 'u')
            trim(storage, 0);
        else if (event.key.code == KeyCode.character && !event.key.control && !event.key.alt
                && printable(event.key.character))
        {
            char[4] scratch;
            scope (exit)
                wipe(scratch[]);
            const used = encode(scratch, event.key.character);
            insert(scratch[0 .. used], capacity);
        }
    }

    private void insert(scope const(char)[] text, size_t capacity)
    {
        const present = length();
        if (present > capacity)
            return;
        const accepted = acceptedInput(text, capacity - present);
        if (accepted != 0)
            append(storage, text[0 .. accepted]);
    }
}
