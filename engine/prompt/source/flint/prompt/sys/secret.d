/// Native storage and callback-scoped secret borrowing.
module flint.prompt.sys.secret;

import flint.arena : Error, Status;

@safe:
package(flint.prompt):

// The native secret store is native/secret.c on Linux and macOS, and the D definitions of the same functions
// at the end of this module on Windows, which has no C step in the package build.
version (linux)
    version = FlintPromptC;
else version (OSX)
    version = FlintPromptC;

version (FlintPromptC)
    version = FlintPromptNative;
else version (Windows)
    version = FlintPromptNative;

struct NativeSecret;

version (FlintPromptC) private extern (C) @system nothrow @nogc
{
    NativeSecret* flint_prompt_secret_new(size_t capacity);
    size_t flint_prompt_secret_count(const NativeSecret* storage);
    int flint_prompt_secret_append(NativeSecret* storage, const(void)* data, size_t length);
    void flint_prompt_secret_trim(NativeSecret* storage, size_t length);
    const(ubyte)* flint_prompt_secret_borrow(const NativeSecret* storage, size_t* length);
    void flint_prompt_secret_release(const NativeSecret* storage);
    void flint_prompt_secret_close(NativeSecret* storage);
    void flint_prompt_wipe(void* data, size_t length);
}

// SAFETY: Native allocation checks arithmetic. The move-only caller owns the resulting handle.
@trusted NativeSecret* allocate(size_t capacity) nothrow @nogc
{
    version (FlintPromptNative)
        return flint_prompt_secret_new(capacity);
    else
        return null;
}

// SAFETY: The live owner provides a valid native handle or null. No payload pointer is returned.
@trusted size_t count(const NativeSecret* storage) nothrow @nogc
{
    version (FlintPromptNative)
        return flint_prompt_secret_count(storage);
    else
        return 0;
}

// SAFETY: Native append bounds capacity and copies the scope bytes before returning on this owner thread.
@trusted bool append(NativeSecret* storage, scope const(char)[] bytes) nothrow @nogc
{
    version (FlintPromptNative)
        return flint_prompt_secret_append(storage, bytes.ptr, bytes.length) != 0;
    else
        return false;
}

// SAFETY: Native trim bounds the requested length and wipes removed bytes while no callback is borrowing.
@trusted void trim(NativeSecret* storage, size_t length) nothrow @nogc
{
    version (FlintPromptNative)
        flint_prompt_secret_trim(storage, length);
}

// SAFETY: Only the move-only owner closes a live handle. Native close delays wipe/free through any
// active borrow, including same-thread reentry through the scoped callback.
@trusted void retire(NativeSecret* storage) nothrow @nogc
{
    version (FlintPromptNative)
        flint_prompt_secret_close(storage);
}

// SAFETY: The native borrow holds the allocation through this synchronous scoped callback. Exceptions
// stay in D and scope cleanup releases the borrow on every exit. The owning handle is thread-confined.
@trusted Error read(scope const NativeSecret* storage, scope void delegate(scope const(ubyte)[]) @safe consumer)
{
    if (consumer is null)
        return Error(Status.invalidArgument, "missing secret consumer");
    version (FlintPromptNative)
    {
        size_t length;
        const data = flint_prompt_secret_borrow(storage, &length);
        if (data is null)
            return Error(Status.invalidArgument, "secret is closed");
        scope (exit)
            flint_prompt_secret_release(storage);
        consumer(data[0 .. length]);
        return Error.init;
    }
    else
        return Error(Status.unsupported, "native secret allocation is unavailable");
}

// SAFETY: The mutable scratch slice belongs to the caller. The synchronous libc wipe does not retain it.
@trusted void wipe(scope char[] bytes) nothrow @nogc
{
    version (FlintPromptNative)
        flint_prompt_wipe(bytes.ptr, bytes.length);
}

version (Windows)
{
    import core.stdc.stdlib : calloc, free;
    import core.stdc.string : memcpy;
    import core.volatile : volatileStore;

    // native/secret.c's layout: the header, then `capacity` payload bytes.
    private struct Secret
    {
        size_t capacity;
        size_t length;
        size_t readers;
        int closed;
    }

    private Secret* header(const NativeSecret* storage) @system nothrow @nogc
    {
        return cast(Secret*) storage;
    }

    private ubyte* payload(Secret* secret) @system nothrow @nogc
    {
        return cast(ubyte*)(secret + 1);
    }

    // The counterpart of explicit_bzero: volatile stores the compiler cannot remove.
    private void flint_prompt_wipe(void* data, size_t size) @system nothrow @nogc
    {
        auto bytes = cast(ubyte*) data;
        foreach (index; 0 .. size)
            volatileStore(bytes + index, cast(ubyte) 0);
    }

    private void erase(Secret* secret) @system nothrow @nogc
    {
        flint_prompt_wipe(secret, Secret.sizeof + secret.capacity);
        free(secret);
    }

    private NativeSecret* flint_prompt_secret_new(size_t capacity) @system nothrow @nogc
    {
        if (capacity > size_t.max - Secret.sizeof)
            return null;
        auto secret = cast(Secret*) calloc(1, Secret.sizeof + capacity);
        if (secret !is null)
            secret.capacity = capacity;
        return cast(NativeSecret*) secret;
    }

    private size_t flint_prompt_secret_count(const NativeSecret* storage) @system nothrow @nogc
    {
        auto secret = header(storage);
        return secret !is null && !secret.closed ? secret.length : 0;
    }

    private int flint_prompt_secret_append(NativeSecret* storage, const(void)* data, size_t bytes) @system nothrow @nogc
    {
        auto secret = header(storage);
        if (secret is null || secret.closed || secret.readers || bytes > secret.capacity - secret.length)
            return 0;
        if (bytes)
            memcpy(payload(secret) + secret.length, data, bytes);
        secret.length += bytes;
        return 1;
    }

    private void flint_prompt_secret_trim(NativeSecret* storage, size_t length) @system nothrow @nogc
    {
        auto secret = header(storage);
        if (secret is null || secret.closed || secret.readers || length >= secret.length)
            return;
        flint_prompt_wipe(payload(secret) + length, secret.length - length);
        secret.length = length;
    }

    // A const handle borrows mutable allocation bookkeeping without changing its payload.
    private const(ubyte)* flint_prompt_secret_borrow(const NativeSecret* storage, size_t* length) @system nothrow @nogc
    {
        auto secret = header(storage);
        if (secret is null || secret.closed || secret.readers == size_t.max)
            return null;
        ++secret.readers;
        *length = secret.length;
        return payload(secret);
    }

    private void flint_prompt_secret_release(const NativeSecret* storage) @system nothrow @nogc
    {
        auto secret = header(storage);
        if (!--secret.readers && secret.closed)
            erase(secret);
    }

    private void flint_prompt_secret_close(NativeSecret* storage) @system nothrow @nogc
    {
        auto secret = header(storage);
        if (secret is null)
            return;
        secret.closed = 1;
        if (!secret.readers)
            erase(secret);
    }
}
