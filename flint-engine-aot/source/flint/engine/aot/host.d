/++
The host process for flint:java and flint:core: environment variables, file facts, whole-file reads and the
current directory, without std.process, std.file or std.path, whose templates each caller instantiated
(ADR-030 section 5, the template diet).

Everything here is `@safe` and `package(flint)`: framework modules call it, applications never do. The `@trusted`
calls live in `flint.engine.aot.sys.environment` and `flint.engine.aot.sys.files`. The behaviour is std.process's
and std.file's, except where a function's documentation says otherwise.
+/
module flint.engine.aot.host;

import flint.engine.aot.sys.environment : readVariable;
import flint.engine.aot.sys.files : closeFile, currentDirectoryInto, FileHandle, openRead, readInto, statPath;
public import flint.engine.aot.sys.files : FileError, FileFacts;

@safe:

/// One environment variable.
struct EnvironmentEntry
{
    string name;
    string value;
}

/++
The value of the environment variable `name`, as `std.process.environment.get(name, defaultValue)`: `defaultValue`
when it is not set, `""` when it is set to the empty string. A name holding a NUL is never set.
+/
package(flint) string environmentVariable(scope const(char)[] name, string defaultValue = null) nothrow
{
    if (name.length == 0 || holdsNul(name))
        return defaultValue;
    version (Windows)
    {
        import flint.engine.aot.sys.files : narrow, widen;

        auto wide = widen(name);
        if (wide is null)
            return defaultValue;
        auto value = readVariable(wide);
        return value is null ? defaultValue : (value.length == 0 ? "" : narrow(value));
    }
    else
    {
        auto value = readVariable(nulTerminated(name));
        return value is null ? defaultValue : value;
    }
}

/++
Every environment variable, as `std.process.environment.toAA()` reads them but in the environment's order: when a
name occurs twice, the first wins. On Windows names are upper-cased (by Windows' own table, not std.uni's) and the
per-drive `=C:` entries are skipped.
+/
package(flint) EnvironmentEntry[] environmentEntries() nothrow
{
    EnvironmentEntry[] entries;
    version (Windows)
    {
        import flint.engine.aot.sys.environment : environmentBlock, upperCase;
        import flint.engine.aot.sys.files : narrow;

        const block = environmentBlock();
        size_t start;
        foreach (i, c; block)
        {
            if (c != '\0')
                continue;
            const entry = block[start .. i];
            start = i + 1;
            size_t equals;
            while (equals < entry.length && entry[equals] != '=')
                equals++;
            if (equals == 0 || equals == entry.length)
                continue;
            const value = narrow(entry[equals + 1 .. $]);
            addFirst(entries, narrow(upperCase(entry[0 .. equals])), value is null ? "" : value);
        }
    }
    else
    {
        import flint.engine.aot.sys.environment : environmentStrings = environmentEntries;

        foreach (entry; environmentStrings())
        {
            foreach (i, c; entry)
            {
                if (c == '=')
                {
                    addFirst(entries, entry[0 .. i], entry[i + 1 .. $]);
                    break;
                }
            }
        }
    }
    return entries;
}

private void addFirst(ref EnvironmentEntry[] entries, string name, string value) nothrow
{
    foreach (existing; entries)
        if (existing.name == name)
            return;
    entries ~= EnvironmentEntry(name, value);
}

/++
One `stat` of `path`, following symbolic links: whether it exists, is a regular file or a directory, its size and
its modification time. A path that is empty or holds a NUL does not exist.
+/
package(flint) FileFacts fileFacts(scope const(char)[] path) nothrow
{
    if (path.length == 0 || holdsNul(path))
        return FileFacts.init;
    version (Windows)
    {
        import flint.engine.aot.sys.files : widen;

        auto wide = widen(path);
        return wide is null ? FileFacts.init : statPath(wide);
    }
    else
        return statPath(nulTerminated(path));
}

/// Milliseconds since 1970-01-01T00:00Z of `facts.modifiedTicks`, as std.file's `timeLastModified(path)
/// .toUnixTime() * 1000`: whole seconds, truncated toward zero.
package(flint) long modifiedMillis(FileFacts facts) pure nothrow @nogc
{
    return facts.modifiedTicks / 10_000_000 * 1000;
}

/++
Every byte of the file at `path`, read to its end, as std.file's `read`; null with `error` set when it cannot be
opened or read. An empty file gives a non-null empty array.
+/
package(flint) ubyte[] readFile(scope const(char)[] path, out FileError error) nothrow
{
    if (path.length == 0 || holdsNul(path))
    {
        error = FileError.notFound;
        return null;
    }
    version (Windows)
    {
        import flint.engine.aot.sys.files : widen;

        auto name = widen(path);
        if (name is null)
        {
            error = FileError.notFound;
            return null;
        }
        enum FileHandle closed = null;
    }
    else
    {
        auto name = nulTerminated(path);
        enum FileHandle closed = -1;
    }
    auto file = openRead(name, error);
    if (file == closed)
        return null;
    scope (exit)
        closeFile(file);
    const facts = statPath(name);
    auto bytes = new ubyte[](facts.size > 0 && facts.size < int.max ? cast(size_t) facts.size + 1 : 4096);
    size_t length;
    for (;;)
    {
        if (length == bytes.length)
            bytes.length = bytes.length * 2;
        const count = readInto(file, bytes[length .. $]);
        if (count < 0)
        {
            error = FileError.other;
            return null;
        }
        if (count == 0)
            return bytes[0 .. length];
        length += count;
    }
}

/// The message Java's `FileInputStream` gives after the path for `error`: `No such file or directory`, ...
package(flint) string describe(FileError error) pure nothrow @nogc
{
    final switch (error)
    {
    case FileError.none:
        return "Success";
    case FileError.notFound:
        return "No such file or directory";
    case FileError.accessDenied:
        return "Permission denied";
    case FileError.isDirectory:
        return "Is a directory";
    case FileError.other:
        return "Input/output error";
    }
}

/// The current working directory, as std.file's `getcwd`; null when it cannot be read.
package(flint) string currentDirectory() nothrow
{
    version (Windows)
    {
        import flint.engine.aot.sys.files : narrow;

        auto buffer = new wchar[](260);
    }
    else
        auto buffer = new char[](1024);
    for (;;)
    {
        const length = currentDirectoryInto(buffer);
        if (length == 0)
            return null;
        if (length <= buffer.length)
        {
            version (Windows)
                return narrow(buffer[0 .. length]);
            else
                return buffer[0 .. length].idup;
        }
        if (buffer.length >= 1 << 20)
            return null;
        buffer = new typeof(buffer[0])[](length > buffer.length * 2 ? length : buffer.length * 2);
    }
}

/++
`path` made absolute against the current directory, as std.path's `absolutePath(path)`: null for an empty path,
`path` itself when it is already absolute, else the directory and the path joined by one separator. When the
current directory cannot be read, `path` itself (std.path throws; Java's `getAbsolutePath` never does).
+/
package(flint) string absolutePath(string path) nothrow
{
    if (path.length == 0)
        return null;
    if (isAbsolute(path))
        return path;
    const base = currentDirectory();
    if (base is null || !isAbsolute(base))
        return path;
    return joinPath(base, path);
}

version (Windows)
{
    private enum char separator = '\\';

    private bool isSeparator(char c) pure nothrow @nogc
    {
        return c == '\\' || c == '/';
    }

    // std.path: a drive root (`C:\`) or a UNC path (`\\server`).
    private bool isAbsolute(scope const(char)[] path) pure nothrow @nogc
    {
        return path.length >= 3 && ((path[1] == ':' && isSeparator(path[2]))
                || (isSeparator(path[0]) && isSeparator(path[1]) && !isSeparator(path[2])));
    }

    // std.path's rootName length for an absolute path: `C:\`, or `\\server\share`.
    private size_t rootLength(scope const(char)[] path) pure nothrow @nogc
    {
        if (path[1] == ':')
            return 3;
        size_t i = 3;
        while (i < path.length && !isSeparator(path[i]))
            i++;
        if (i < path.length)
        {
            size_t j = i + 1;
            while (j < path.length && isSeparator(path[j]))
                j++;
            if (j < path.length)
            {
                while (j < path.length && !isSeparator(path[j]))
                    j++;
                i = j;
            }
        }
        return i;
    }

    // std.path's chainPath(base, path) for an absolute base and a relative path: a path rooted without a drive
    // (`\x`) keeps only the base's root.
    private string joinPath(string base, string path) pure nothrow
    {
        size_t keep = base.length;
        if (isSeparator(path[0]))
        {
            keep = rootLength(base);
            if (keep > 0 && isSeparator(base[keep - 1]))
                keep--;
            return base[0 .. keep] ~ path;
        }
        return isSeparator(base[$ - 1]) ? base ~ path : base ~ separator ~ path;
    }
}
else
{
    private bool isAbsolute(scope const(char)[] path) pure nothrow @nogc
    {
        return path.length != 0 && path[0] == '/';
    }

    private string joinPath(string base, string path) pure nothrow
    {
        return base[$ - 1] == '/' ? base ~ path : base ~ '/' ~ path;
    }
}

private bool holdsNul(scope const(char)[] text) pure nothrow @nogc
{
    foreach (c; text)
        if (c == '\0')
            return true;
    return false;
}

private immutable(char)[] nulTerminated(scope const(char)[] text) pure nothrow
{
    return (text ~ '\0').idup;
}

version (Posix) unittest
{
    import std.file : getcwd, mkdir, remove, rmdir, tempDir, write;
    import std.process : environment;

    // Environment, positive: set, empty (not the default) and listed once.
    environment["FLINT_HOST_TEST"] = "a=b";
    environment["FLINT_HOST_EMPTY"] = "";
    scope (exit)
    {
        environment.remove("FLINT_HOST_TEST");
        environment.remove("FLINT_HOST_EMPTY");
    }
    assert(environmentVariable("FLINT_HOST_TEST") == "a=b");
    const empty = environmentVariable("FLINT_HOST_EMPTY", "fallback");
    assert(empty !is null && empty.length == 0);
    size_t seen;
    foreach (entry; environmentEntries())
        seen += entry.name == "FLINT_HOST_TEST" && entry.value == "a=b";
    assert(seen == 1);
    // Environment, negative: unset, empty or NUL-holding names give the default.
    assert(environmentVariable("FLINT_HOST_UNSET_EVER") is null);
    assert(environmentVariable("FLINT_HOST_UNSET_EVER", "d") == "d");
    assert(environmentVariable("", "d") == "d" && environmentVariable("FLINT_HOST_TEST\0x", "d") == "d");

    // Files, positive: facts, bytes (larger than the first buffer) and an empty file.
    const directory = tempDir ~ "/flint-host-test";
    mkdir(directory);
    const path = directory ~ "/data.bin";
    const blank = directory ~ "/empty.txt";
    auto content = new ubyte[](70_000);
    foreach (i, ref b; content)
        b = cast(ubyte)(i * 7);
    write(path, content);
    write(blank, "");
    scope (exit)
    {
        remove(path);
        remove(blank);
        rmdir(directory);
    }
    const facts = fileFacts(path);
    assert(facts.exists && facts.regular && !facts.directory && facts.size == content.length);
    assert(fileFacts(directory).directory && !fileFacts(directory).regular);
    assert(modifiedMillis(facts) % 1000 == 0 && modifiedMillis(facts) > 1_767_225_600_000);
    FileError error;
    assert(readFile(path, error) == content && error == FileError.none);
    const none = readFile(blank, error);
    assert(none !is null && none.length == 0 && error == FileError.none);
    // Files, negative: missing, a directory, empty or NUL-holding paths.
    assert(!fileFacts(path ~ ".missing").exists && !fileFacts("").exists && !fileFacts(path ~ "\0x").exists);
    assert(readFile(path ~ ".missing", error) is null && error == FileError.notFound);
    assert(describe(error) == "No such file or directory");
    assert(readFile(directory, error) is null && error == FileError.other);
    assert(readFile(path ~ "\0", error) is null && error == FileError.notFound);

    // Paths: std.path's absolutePath and std.file's getcwd.
    assert(currentDirectory() == getcwd());
    assert(absolutePath("") is null && absolutePath("/x/y") == "/x/y");
    assert(absolutePath("a/b") == getcwd() ~ "/a/b");
    assert(joinPath("/", "a") == "/a" && joinPath("/r/", "a") == "/r/a");
    // modifiedMillis truncates toward zero, as SysTime.toUnixTime.
    assert(modifiedMillis(FileFacts(true, true, false, 0, -5_000_000)) == 0);
    assert(modifiedMillis(FileFacts(true, true, false, 0, 15_000_000)) == 1000);
}
