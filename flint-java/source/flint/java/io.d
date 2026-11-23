/++
`java.io` as `flint.core.io.Resource` exposes it: the checked `IOException` family, `InputStream`, and `File`.

`IOException` is checked in Java; in D it is an `Exception` and the `throws` clauses are dropped (deviation D-8).
`OutputStream`, `Writer`, `StringWriter`, `OutputStreamWriter` and `PrintWriter` carry UTF-8 text.
`File` wraps a path and answers the questions `Resource` asks (`exists`, `isFile`, `length`, `lastModified`); it
does not open streams itself.
+/
module flint.java.io;

import flint.java.lang : RuntimeException;

@safe:

/// Java's checked `IOException`.
class IOException : Exception
{
    private Throwable cause_;

    /// `message`, and optionally a `cause`.
    this(string message = null, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, file, line);
        cause_ = cause;
    }

    /// The detail message; null when there is none.
    string getMessage() const pure nothrow @nogc
    {
        return msg;
    }

    /// The cause; null when unknown.
    inout(Throwable) getCause() inout pure nothrow @nogc
    {
        return cause_;
    }
}

/// Thrown when a file or resource does not exist or cannot be opened.
class FileNotFoundException : IOException
{
    /// `message` names the missing file.
    this(string message = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, null, file, line);
    }
}

/// Wraps an `IOException` where an API may not throw checked exceptions.
class UncheckedIOException : RuntimeException
{
    /// `message` and the wrapped `cause`.
    this(string message, IOException cause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }

    /// The message is `cause.toString()`.
    this(IOException cause, string file = __FILE__, size_t line = __LINE__)
    {
        super(cast(Throwable) cause, file, line);
    }
}

/// Java's `InputStream`: a source of bytes.
abstract class InputStream
{
    /// The next byte as 0..255, or -1 at the end.
    abstract int read();

    /// Read up to `buffer.length` bytes; the count read, or -1 at the end.
    int read(scope ubyte[] buffer)
    {
        if (buffer.length == 0)
            return 0;
        int count;
        foreach (ref b; buffer)
        {
            const next = read();
            if (next < 0)
                break;
            b = cast(ubyte) next;
            count++;
        }
        return count == 0 ? -1 : count;
    }

    /// Every remaining byte.
    ubyte[] readAllBytes()
    {
        ubyte[] result;
        ubyte[4096] chunk;
        for (;;)
        {
            const n = read(chunk[]);
            if (n < 0)
                return result;
            result ~= chunk[0 .. n];
        }
    }

    /// Release the stream. The default does nothing.
    void close()
    {
    }
}

/// Java's `OutputStream`: a sink of bytes.
abstract class OutputStream
{
    /// Write one byte (the low 8 bits of `b`).
    abstract void write(int b);

    /// Write every byte of `b`.
    void write(scope const(ubyte)[] b)
    {
        foreach (value; b)
            write(value);
    }

    /// Write `len` bytes of `b` from `off`.
    void write(scope const(ubyte)[] b, int off, int len)
    {
        write(b[off .. off + len]);
    }

    /// Flush buffered bytes. The default does nothing.
    void flush()
    {
    }

    /// Release the stream. The default does nothing.
    void close()
    {
    }
}

/// An `OutputStream` collecting bytes in memory.
class ByteArrayOutputStream : OutputStream
{
    private ubyte[] bytes;

    override void write(int b)
    {
        bytes ~= cast(ubyte) b;
    }

    override void write(scope const(ubyte)[] b)
    {
        bytes ~= b;
    }

    /// A copy of the bytes written.
    ubyte[] toByteArray() const pure nothrow
    {
        return bytes.dup;
    }

    /// How many bytes were written.
    int size() const pure nothrow @nogc
    {
        return cast(int) bytes.length;
    }

    /// Discard the bytes written.
    void reset() pure nothrow @nogc
    {
        bytes = null;
    }

    /// The bytes as UTF-8 text.
    override string toString() const
    {
        return cast(string) bytes.idup;
    }
}

/// Java's `Writer`: a sink of characters (UTF-8 text in Flint).
abstract class Writer
{
    /// Write `text`.
    abstract void write(scope const(char)[] text);

    /// Write one character.
    void write(dchar c)
    {
        import flint.engine.aot.text : utf8;

        const text = utf8(c);
        write(text is null ? "\uFFFD" : text); // a surrogate or out-of-range code point is the replacement character
    }

    /// Write `text`; this writer.
    Writer append(scope const(char)[] text)
    {
        write(text);
        return this;
    }

    /// Flush. The default does nothing.
    void flush()
    {
    }

    /// Close. The default does nothing.
    void close()
    {
    }
}

/// A `Writer` collecting text in memory.
class StringWriter : Writer
{
    private string buffer;

    alias write = Writer.write;

    override void write(scope const(char)[] text)
    {
        buffer ~= text;
    }

    /// The text written.
    override string toString() const
    {
        return buffer;
    }
}

/// A `Writer` encoding UTF-8 text onto an `OutputStream`.
class OutputStreamWriter : Writer
{
    private OutputStream output;

    /// A writer over `output`.
    this(OutputStream output) pure nothrow @nogc
    {
        this.output = output;
    }

    alias write = Writer.write;

    override void write(scope const(char)[] text)
    {
        output.write(cast(const(ubyte)[]) text);
    }

    override void flush()
    {
        output.flush();
    }

    override void close()
    {
        output.close();
    }
}

/// Java's `PrintWriter`: formatted text over a `Writer` or an `OutputStream`.
class PrintWriter : Writer
{
    private Writer target;

    /// A print writer over `target`.
    this(Writer target) pure nothrow @nogc
    {
        this.target = target;
    }

    /// A print writer over `output`, encoding UTF-8.
    this(OutputStream output) pure nothrow
    {
        target = new OutputStreamWriter(output);
    }

    alias write = Writer.write;

    override void write(scope const(char)[] text)
    {
        target.write(text);
    }

    /// Java's `print(String)`.
    void print(scope const(char)[] text)
    {
        write(text);
    }

    /// Java's `print` of any value: `String.valueOf(value)`.
    void print(T)(T value) if (!is(T : const(char)[]))
    {
        import flint.java.lang : valueOf;

        write(valueOf(value));
    }

    /// Java's `println(String)`; a line separator alone without an argument.
    void println(scope const(char)[] text = null)
    {
        write(text);
        write("\n");
    }

    /// Java's `println` of any value.
    void println(T)(T value) if (!is(T : const(char)[]))
    {
        print(value);
        write("\n");
    }

    /// Java's `append(CharSequence)`.
    override PrintWriter append(scope const(char)[] text)
    {
        write(text);
        return this;
    }

    override void flush()
    {
        target.flush();
    }

    override void close()
    {
        target.close();
    }
}

/// An `InputStream` over bytes in memory.
class ByteArrayInputStream : InputStream
{
    private const(ubyte)[] bytes;
    private size_t position;

    /// Read from `bytes`, which the stream does not copy.
    this(const(ubyte)[] bytes) pure nothrow @nogc
    {
        this.bytes = bytes;
    }

    override int read()
    {
        return position < bytes.length ? bytes[position++] : -1;
    }

    override int read(scope ubyte[] buffer)
    {
        if (buffer.length == 0)
            return 0;
        if (position >= bytes.length)
            return -1;
        const n = buffer.length < bytes.length - position ? buffer.length : bytes.length - position;
        buffer[0 .. n] = bytes[position .. position + n];
        position += n;
        return cast(int) n;
    }

    /// How many bytes remain.
    int available() const pure nothrow @nogc
    {
        return cast(int)(bytes.length - position);
    }
}

/// Java's `File`: a filesystem path.
class File
{
    private string path_;

    /// The file at `pathname`.
    this(string pathname) pure nothrow @nogc
    {
        path_ = pathname;
    }

    /// The file `child` inside `parent`.
    this(string parent, string child) pure nothrow
    {
        path_ = parent.length == 0 ? child : (parent[$ - 1] == '/' ? parent ~ child : parent ~ "/" ~ child);
    }

    /// The path as given.
    string getPath() const pure nothrow @nogc
    {
        return path_;
    }

    /// The last path component.
    string getName() const pure nothrow @nogc
    {
        size_t start;
        foreach (i, c; path_)
            if (c == '/')
                start = i + 1;
        return path_[start .. $];
    }

    /// The parent path, or null.
    string getParent() const pure nothrow @nogc
    {
        size_t end = path_.length;
        while (end > 0 && path_[end - 1] != '/')
            end--;
        if (end == 0)
            return null;
        return end == 1 ? "/" : path_[0 .. end - 1];
    }

    /// The absolute path.
    string getAbsolutePath() const
    {
        import std.path : absolutePath;

        return absolutePath(path_);
    }

    /// Whether the path exists.
    bool exists() const
    {
        import std.file : exists;

        return path_.length != 0 && exists(path_);
    }

    /// Whether the path is a regular file.
    bool isFile() const
    {
        import std.file : exists, isFile;

        return path_.length != 0 && exists(path_) && isFile(path_);
    }

    /// Whether the path is a directory.
    bool isDirectory() const
    {
        import std.file : exists, isDir;

        return path_.length != 0 && exists(path_) && isDir(path_);
    }

    /// Whether the file can be read: it exists. (D offers no portable access check without opening the file.)
    bool canRead() const
    {
        return exists();
    }

    /// The size in bytes; 0 when it does not exist.
    long length() const
    {
        import std.file : getSize;

        return isFile() ? cast(long) getSize(path_) : 0;
    }

    /// Milliseconds since the epoch of the last modification; 0 when it does not exist.
    long lastModified() const
    {
        import std.file : timeLastModified;

        if (!exists())
            return 0;
        return timeLastModified(path_).toUnixTime() * 1000L;
    }

    /// The path.
    override string toString() const
    {
        return path_;
    }
}

/// An `InputStream` over a file's bytes, read at construction.
class FileInputStream : ByteArrayInputStream
{
    /// Open `file`. Throws `FileNotFoundException` when it is missing or not a regular file.
    this(File file)
    {
        import std.file : read;

        if (!file.isFile())
            throw new FileNotFoundException(file.getPath() ~ " (No such file or directory)");
        super(cast(const(ubyte)[]) read(file.getPath()));
    }
}
