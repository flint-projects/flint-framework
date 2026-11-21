module providers;

import codec_replay : ArchiveMemory, require;
import core.stdc.config : c_long, c_ulong;
import core.stdc.string : strcmp;

@safe:
nothrow @nogc:

private struct ZlibStream
{
    const(ubyte)* nextIn;
    uint availableIn;
    c_ulong totalIn;
    ubyte* nextOut;
    uint availableOut;
    c_ulong totalOut;
    const(char)* message;
    void* internalState;
    void* allocate;
    void* release;
    void* opaque;
    int dataType;
    c_ulong checksum;
    c_ulong reserved;
}

private struct ZstdEncoder;
private struct ZstdDecoder;
private struct BrotliEncoder;
private struct BrotliDecoder;
private struct Archive;
private struct Entry;

private struct InBuffer
{
    const(ubyte)* data;
    size_t size;
    size_t cursor;
}

private struct OutBuffer
{
    ubyte* data;
    size_t size;
    size_t cursor;
}

extern (C) private @system
{
    const(char)* zlibVersion();
    pragma(mangle, "ZSTD_isError") uint isZstdError(size_t);
    int deflateInit2_(ZlibStream*, int, int, int, int, int, const(char)*, int);
    int deflate(ZlibStream*, int);
    int deflateEnd(ZlibStream*);
    int inflateInit2_(ZlibStream*, int, const(char)*, int);
    int inflate(ZlibStream*, int);
    int inflateEnd(ZlibStream*);

    pragma(mangle, "ZSTD_createCCtx") ZstdEncoder* zstdCreateCCtx();
    pragma(mangle, "ZSTD_CCtx_setParameter") size_t zstdCCtxsetParameter(ZstdEncoder*, int, int);
    pragma(mangle, "ZSTD_compressStream2") size_t zstdCompressStream2(ZstdEncoder*, OutBuffer*, InBuffer*, int);
    pragma(mangle, "ZSTD_freeCCtx") size_t zstdFreeCCtx(ZstdEncoder*);
    pragma(mangle, "ZSTD_createDCtx") ZstdDecoder* zstdCreateDCtx();
    pragma(mangle, "ZSTD_DCtx_setParameter") size_t zstdDCtxsetParameter(ZstdDecoder*, int, int);
    pragma(mangle, "ZSTD_decompressStream") size_t zstdDecompressStream(ZstdDecoder*, OutBuffer*, InBuffer*);
    pragma(mangle, "ZSTD_freeDCtx") size_t zstdFreeDCtx(ZstdDecoder*);

    pragma(mangle, "BrotliEncoderCreateInstance") BrotliEncoder* brotliEncoderCreateInstance(void*, void*, void*);
    pragma(mangle, "BrotliEncoderDestroyInstance") void brotliEncoderDestroyInstance(BrotliEncoder*);
    pragma(mangle, "BrotliEncoderSetParameter") int brotliEncoderSetParameter(BrotliEncoder*, int, uint);
    pragma(mangle, "BrotliEncoderCompressStream") int brotliEncoderCompressStream(BrotliEncoder*,
            int, size_t*, const(ubyte)**, size_t*, ubyte**, size_t*);
    pragma(mangle, "BrotliEncoderIsFinished") int brotliEncoderIsFinished(const(BrotliEncoder)*);
    pragma(mangle, "BrotliDecoderCreateInstance") BrotliDecoder* brotliDecoderCreateInstance(void*, void*, void*);
    pragma(mangle, "BrotliDecoderDestroyInstance") void brotliDecoderDestroyInstance(BrotliDecoder*);
    pragma(mangle, "BrotliDecoderSetParameter") int brotliDecoderSetParameter(BrotliDecoder*, int, uint);
    pragma(mangle, "BrotliDecoderDecompressStream") int brotliDecoderDecompressStream(BrotliDecoder*,
            size_t*, const(ubyte)**, size_t*, ubyte**, size_t*);

    Archive* archive_write_new();
    int archive_write_set_format_zip(Archive*);
    int archive_write_set_format_pax_restricted(Archive*);
    int archive_write_set_bytes_in_last_block(Archive*, int);
    int archive_write_open_memory(Archive*, ubyte*, size_t, size_t*);
    int archive_write_header(Archive*, Entry*);
    c_long archive_write_data(Archive*, const(ubyte)*, size_t);
    int archive_write_close(Archive*);
    int archive_write_free(Archive*);
    Entry* archive_entry_new();
    void archive_entry_free(Entry*);
    void archive_entry_set_pathname_utf8(Entry*, const(char)*);
    void archive_entry_set_filetype(Entry*, uint);
    void archive_entry_set_perm(Entry*, uint);
    void archive_entry_set_mtime(Entry*, c_long, c_long);
    void archive_entry_set_size(Entry*, long);
    const(char)* archive_entry_pathname_utf8(Entry*);
    uint archive_entry_filetype(Entry*);
    long archive_entry_size(Entry*);
    Archive* archive_read_new();
    int archive_read_support_format_zip_seekable(Archive*);
    int archive_read_support_format_tar(Archive*);
    int archive_read_open_memory(Archive*, const(ubyte)*, size_t);
    int archive_read_next_header(Archive*, Entry**);
    c_long archive_read_data(Archive*, ubyte*, size_t);
    int archive_read_free(Archive*);
}

version (FlintNativeZlib)
{
    /// Encode and decode the fixed level-3 gzip workload over the public zlib ABI.
    // SAFETY: Scope slices and their lengths stay valid throughout these local z_stream lifetimes.
    size_t gzip(scope const(ubyte)[] input, scope ubyte[] wire, scope ubyte[] output) @trusted nothrow @nogc
    {
        ZlibStream writer;
        require(deflateInit2_(&writer, 3, 8, 31, 8, 0, zlibVersion(), ZlibStream.sizeof) == 0);
        writer.nextIn = input.ptr;
        writer.availableIn = cast(uint) input.length;
        writer.nextOut = wire.ptr;
        writer.availableOut = cast(uint) wire.length;
        require(deflate(&writer, 4) == 1 && writer.availableIn == 0);
        const size = writer.totalOut;
        require(deflateEnd(&writer) == 0);

        ZlibStream reader;
        require(inflateInit2_(&reader, 31, zlibVersion(), ZlibStream.sizeof) == 0);
        reader.nextIn = wire.ptr;
        reader.availableIn = cast(uint) size;
        reader.nextOut = output.ptr;
        reader.availableOut = cast(uint) output.length;
        require(inflate(&reader, 0) == 1 && reader.availableIn == 0 && reader.totalOut == input.length);
        require(inflateEnd(&reader) == 0);
        return size;
    }
}

version (FlintNativeZstd)
{
    /// Run the pinned streaming Zstandard APIs with identical frame options.
    // SAFETY: Both native contexts are local and destroyed before the borrowed array spans expire.
    size_t zstd(scope const(ubyte)[] input, scope ubyte[] wire, scope ubyte[] output) @trusted nothrow @nogc
    {
        auto writer = zstdCreateCCtx();
        require(writer !is null);
        require(isZstdError(zstdCCtxsetParameter(writer, 100, 3)) == 0);
        require(isZstdError(zstdCCtxsetParameter(writer, 101, 24)) == 0);
        require(isZstdError(zstdCCtxsetParameter(writer, 201, 1)) == 0);
        auto source = InBuffer(input.ptr, input.length);
        auto result = OutBuffer(wire.ptr, wire.length);
        require(zstdCompressStream2(writer, &result, &source, 2) == 0 && source.cursor == input.length);
        require(zstdFreeCCtx(writer) == 0);
        const size = result.cursor;

        auto reader = zstdCreateDCtx();
        require(reader !is null);
        require(zstdDCtxsetParameter(reader, 100, 24) == 0);
        source = InBuffer(wire.ptr, size);
        result = OutBuffer(output.ptr, output.length);
        require(zstdDecompressStream(reader, &result, &source) == 0 && source.cursor == size);
        require(result.cursor == input.length && zstdFreeDCtx(reader) == 0);
        return size;
    }
}

version (FlintNativeBrotli)
{
    /// Run level-3 Brotli using the pinned enc and dec streaming ABIs.
    // SAFETY: Local provider instances receive scoped buffers and scalar consumption counters by address.
    size_t brotli(scope const(ubyte)[] input, scope ubyte[] wire, scope ubyte[] output) @trusted nothrow @nogc
    {
        auto writer = brotliEncoderCreateInstance(null, null, null);
        require(writer !is null && brotliEncoderSetParameter(writer, 1, 3) != 0);
        auto availableIn = input.length;
        auto nextIn = input.ptr;
        auto availableOut = wire.length;
        auto nextOut = wire.ptr;
        require(brotliEncoderCompressStream(writer, 2, &availableIn, &nextIn, &availableOut, &nextOut, null) != 0);
        require(availableIn == 0 && brotliEncoderIsFinished(writer) != 0);
        const size = wire.length - availableOut;
        brotliEncoderDestroyInstance(writer);

        auto reader = brotliDecoderCreateInstance(null, null, null);
        require(reader !is null && brotliDecoderSetParameter(reader, 1, 0) != 0);
        availableIn = size;
        nextIn = wire.ptr;
        availableOut = output.length;
        nextOut = output.ptr;
        require(brotliDecoderDecompressStream(reader, &availableIn, &nextIn, &availableOut, &nextOut, null) == 1);
        require(availableIn == 0 && output.length - availableOut == input.length);
        brotliDecoderDestroyInstance(reader);
        return size;
    }
}

version (FlintNativeLibarchive)
{
    /// Exercise the same archive metadata and payload over the pinned upstream C ABI.
    // SAFETY: Memory owns valid input/output storage throughout the synchronous libarchive handles.
    size_t archive(bool zip)(scope const(ubyte)[] input, ArchiveMemory memory) @trusted nothrow @nogc
    {
        auto writer = archive_write_new();
        require(writer !is null);
        require((zip ? archive_write_set_format_zip(writer) : archive_write_set_format_pax_restricted(writer)) == 0);
        require(archive_write_set_bytes_in_last_block(writer, 1) == 0);
        require(archive_write_open_memory(writer, memory.wire.ptr, memory.wire.length, &memory.encoded) == 0);
        auto entry = archive_entry_new();
        require(entry !is null);
        archive_entry_set_pathname_utf8(entry, "fixture.bin");
        archive_entry_set_filetype(entry, 0x8000);
        archive_entry_set_perm(entry, 0x1a4);
        archive_entry_set_mtime(entry, 0, 0);
        archive_entry_set_size(entry, cast(long) input.length);
        require(archive_write_header(writer, entry) == 0);
        archive_entry_free(entry);
        require(archive_write_data(writer, input.ptr, input.length) == input.length);
        require(archive_write_close(writer) == 0 && archive_write_free(writer) == 0);

        auto reader = archive_read_new();
        require(reader !is null);
        const format = zip ? archive_read_support_format_zip_seekable(reader) : archive_read_support_format_tar(reader);
        require(format == 0);
        require(archive_read_open_memory(reader, memory.wire.ptr, memory.encoded) == 0);
        require(archive_read_next_header(reader, &entry) == 0 && entry !is null);
        require(archive_entry_size(entry) == input.length && archive_entry_filetype(entry) == 0x8000);
        const name = archive_entry_pathname_utf8(entry);
        require(name !is null && strcmp(name, "fixture.bin") == 0);
        const size = archive_read_data(reader, memory.body.ptr, memory.body.length);
        require(size == input.length);
        memory.decoded = cast(size_t) size;
        require(archive_read_next_header(reader, &entry) == 1 && archive_read_free(reader) == 0);
        return memory.encoded;
    }
}
