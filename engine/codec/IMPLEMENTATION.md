# Flint codecs

The Linux native build selects pinned zlib, Zstandard, Brotli and libarchive. Run
`python3 tools/native_build.py --profile codec --target linux-x86_64-glibc --phase build --emit-dub`
before building the full profile. Select only `--library zlib --library zstd --library brotli` in a
fresh native prefix for compression without archive support.

An encoder or decoder owns one thread-confined stream. Re-supply each unconsumed input prefix and
advance output by the reported byte count. An empty output span leaves the stream unchanged.
Repeat a flush with empty input until it makes no progress, and repeat end steps until the stream
finishes. Close releases the native state and invalidates copied handles.

Decoding permits one member or frame and checks cumulative decoded bytes, expansion ratio and
the provider window. The default decoded limits are 64 MiB and an expansion ratio of 100, using
an input denominator floor of 1 KiB. Required external dictionaries return `unsupported`.
The Zstandard encoder emits checksummed frames.

Archives accept TAR and ZIP with regular files and directories. `next` returns a validated UTF-8
path in the caller's arena and the declared size. Consume the body with `read`, or use `read(null)`
to discard it under the same limits. TAR pulls input incrementally. ZIP buffers up to 128 MiB of
input for seekable central-directory validation before returning entry metadata. The reader
enforces 10,000 entries, 4,096 UTF-8 path bytes and 1 GiB of decoded data. The writer requires the
declared file length exactly. Callbacks are rooted until close and receive scoped byte slices.

The DMD and LDC tests exercise the real pinned providers. `negative/check.py` checks borrow and
handle misuse with either compiler. The equivalent provider baseline under `bench/baseline` uses
the upstream C ABI directly and exercises the same encode, decode, ZIP and TAR workloads.
Use `--measure` on the linked probe for fixed level-3 replay measurements.
