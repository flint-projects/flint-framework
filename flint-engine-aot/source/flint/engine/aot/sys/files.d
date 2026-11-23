/++
The file system behind `flint.engine.aot.host`: one `stat`, a whole-file read, and the current directory.
Private to `flint:engine-aot`; applications never import it.

Paths arrive NUL-terminated (UTF-8 on POSIX, UTF-16 on Windows) from the facade, which refuses paths holding a
NUL of their own. Reads go into GC buffers the caller owns; nothing here keeps a pointer after it returns.
+/
module flint.engine.aot.sys.files;

@safe:

/// What a failed call reports, mapped from errno or the Windows error.
enum FileError
{
    none,
    notFound, /// ENOENT, ENOTDIR; ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_INVALID_NAME
    accessDenied, /// EACCES, EPERM; ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION
    isDirectory, /// EISDIR
    other,
}

/// One `stat` of a path, following symbolic links.
struct FileFacts
{
    bool exists;
    bool regular; /// a regular file (on Windows: anything that is not a directory, as std.file.isFile)
    bool directory;
    long size;
    long modifiedTicks; /// 100 ns ticks since 1970-01-01T00:00Z, as std.datetime's stat conversion
}

version (Windows)
{
    import core.sys.windows.windef : BOOL, DWORD, HANDLE;
    import core.sys.windows.winbase : FILETIME, WIN32_FILE_ATTRIBUTE_DATA;

    private extern (Windows) nothrow @nogc
    {
        BOOL GetFileAttributesExW(scope const(wchar)* name, int level, void* information) @system;
        HANDLE CreateFileW(scope const(wchar)* name, DWORD access, DWORD share, void* security, DWORD disposition,
            DWORD flags, HANDLE template_) @system;
        BOOL ReadFile(HANDLE file, void* buffer, DWORD length, DWORD* read, void* overlapped) @system;
        BOOL CloseHandle(HANDLE handle) @system;
        DWORD GetCurrentDirectoryW(DWORD length, wchar* buffer) @system;
        DWORD GetLastError() @system;
        int MultiByteToWideChar(uint codePage, DWORD flags, scope const(char)* text, int length, wchar* wide,
            int wideLength) @system;
        int WideCharToMultiByte(uint codePage, DWORD flags, scope const(wchar)* wide, int wideLength, char* text,
            int length, const(char)* defaultChar, BOOL* usedDefault) @system;
    }

    /// An open file: a Windows handle, or null.
    alias FileHandle = HANDLE;

    private FileError mapError(DWORD error) nothrow @nogc
    {
        switch (error)
        {
        case 2, 3, 123: // ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_INVALID_NAME
            return FileError.notFound;
        case 5, 32: // ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION
            return FileError.accessDenied;
        default:
            return FileError.other;
        }
    }

    /// `text` as NUL-terminated UTF-16; null when it is not valid UTF-8 or is too long for Windows.
    // SAFETY: both calls read text.length bytes of text; the second writes at most wide.length units into the GC
    // buffer sized from the first call's count plus the NUL this function appends.
    @trusted wchar[] widen(scope const(char)[] text) nothrow
    {
        enum uint utf8 = 65_001, strict = 8; // CP_UTF8, MB_ERR_INVALID_CHARS
        if (text.length == 0)
            return ['\0'];
        if (text.length > int.max)
            return null;
        const length = MultiByteToWideChar(utf8, strict, &text[0], cast(int) text.length, null, 0);
        if (length <= 0)
            return null;
        auto wide = new wchar[](length + 1);
        if (MultiByteToWideChar(utf8, strict, &text[0], cast(int) text.length, &wide[0], length) != length)
            return null;
        wide[length] = '\0';
        return wide;
    }

    /// `wide` as UTF-8; unpaired surrogates become U+FFFD.
    // SAFETY: both calls read wide.length units of wide; the second writes at most text.length bytes into the GC
    // buffer sized from the first call's count.
    @trusted string narrow(scope const(wchar)[] wide) nothrow
    {
        enum uint utf8 = 65_001;
        if (wide.length == 0 || wide.length > int.max)
            return wide.length == 0 ? "" : null;
        const length = WideCharToMultiByte(utf8, 0, &wide[0], cast(int) wide.length, null, 0, null, null);
        if (length <= 0)
            return null;
        auto text = new char[](length);
        if (WideCharToMultiByte(utf8, 0, &wide[0], cast(int) wide.length, &text[0], length, null, null) != length)
            return null;
        return text.idup;
    }

    /// The facts about `pathz` (UTF-16, NUL-terminated); `exists` is false when Windows cannot read them.
    // SAFETY: pathz is NUL-terminated (checked); Windows writes only the local WIN32_FILE_ATTRIBUTE_DATA.
    @trusted FileFacts statPath(scope const(wchar)[] pathz) nothrow @nogc
    {
        enum ulong unixEpoch = 116_444_736_000_000_000; // 1970-01-01 in FILETIME ticks since 1601-01-01
        FileFacts facts;
        WIN32_FILE_ATTRIBUTE_DATA data;
        if (pathz.length == 0 || pathz[$ - 1] != '\0' || !GetFileAttributesExW(&pathz[0], 0, &data))
            return facts;
        facts.exists = true;
        facts.directory = (data.dwFileAttributes & 0x10) != 0; // FILE_ATTRIBUTE_DIRECTORY
        facts.regular = !facts.directory;
        facts.size = cast(long)((cast(ulong) data.nFileSizeHigh << 32) | data.nFileSizeLow);
        const written = (cast(ulong) data.ftLastWriteTime.dwHighDateTime << 32) | data.ftLastWriteTime.dwLowDateTime;
        facts.modifiedTicks = cast(long) written - cast(long) unixEpoch;
        return facts;
    }

    /// `pathz` (UTF-16, NUL-terminated) opened for reading; null with `error` set when it cannot be.
    // SAFETY: pathz is NUL-terminated (checked); CreateFileW reads only the name.
    @trusted FileHandle openRead(scope const(wchar)[] pathz, out FileError error) nothrow @nogc
    {
        enum DWORD genericRead = 0x8000_0000, shareRead = 1, openExisting = 3, sequential = 0x0800_0000;
        enum HANDLE invalid = cast(HANDLE)-1;
        if (pathz.length == 0 || pathz[$ - 1] != '\0')
        {
            error = FileError.notFound;
            return null;
        }
        auto handle = CreateFileW(&pathz[0], genericRead, shareRead, null, openExisting, sequential, null);
        if (handle is invalid || handle is null)
        {
            error = mapError(GetLastError());
            return null;
        }
        return handle;
    }

    /// Up to `buffer.length` bytes read from `file` into `buffer`: the count, 0 at the end, -1 on failure.
    // SAFETY: ReadFile writes at most the DWORD-capped buffer.length bytes into buffer, which the caller owns.
    @trusted ptrdiff_t readInto(FileHandle file, scope ubyte[] buffer) nothrow @nogc
    {
        if (file is null || buffer.length == 0)
            return -1;
        DWORD read;
        const length = buffer.length > DWORD.max ? DWORD.max : cast(DWORD) buffer.length;
        return ReadFile(file, &buffer[0], length, &read, null) ? read : -1;
    }

    /// Close a handle `openRead` returned.
    // SAFETY: CloseHandle takes the handle by value; a null handle is never passed.
    @trusted void closeFile(FileHandle file) nothrow @nogc
    {
        if (file !is null)
            CloseHandle(file);
    }

    /// The current directory written into `buffer` (UTF-16, no NUL): the length written, or the length the buffer
    /// needs (more than buffer.length) when it is too small, or 0 on failure.
    // SAFETY: GetCurrentDirectoryW writes at most buffer.length units, NUL included, into buffer.
    @trusted size_t currentDirectoryInto(scope wchar[] buffer) nothrow @nogc
    {
        if (buffer.length == 0 || buffer.length > DWORD.max)
            return 0;
        const length = GetCurrentDirectoryW(cast(DWORD) buffer.length, &buffer[0]);
        return length < buffer.length ? length : length + 1;
    }
}
else version (Posix)
{
    import core.stdc.errno : EACCES, EINTR, EISDIR, ENOENT, ENOTDIR, EPERM, errno;
    import core.sys.posix.fcntl : O_RDONLY, open;

    version (OSX)
        private enum int O_CLOEXEC = 0x0100_0000; // <sys/fcntl.h>; druntime does not declare it for macOS
    else
        import core.sys.posix.fcntl : O_CLOEXEC;
    import core.sys.posix.sys.stat : S_IFDIR, S_IFMT, S_IFREG, stat, stat_t;
    import core.sys.posix.unistd : close, getcwd, read;

    /// An open file: a descriptor, or -1.
    alias FileHandle = int;

    private FileError mapError(int code) nothrow @nogc
    {
        if (code == ENOENT || code == ENOTDIR)
            return FileError.notFound;
        if (code == EACCES || code == EPERM)
            return FileError.accessDenied;
        return code == EISDIR ? FileError.isDirectory : FileError.other;
    }

    /// The facts about `pathz` (NUL-terminated); `exists` is false when stat fails.
    // SAFETY: pathz is NUL-terminated (checked); stat writes only the local stat_t.
    @trusted FileFacts statPath(scope const(char)[] pathz) nothrow @nogc
    {
        FileFacts facts;
        stat_t buffer;
        if (pathz.length == 0 || pathz[$ - 1] != '\0' || stat(&pathz[0], &buffer) != 0)
            return facts;
        facts.exists = true;
        facts.regular = (buffer.st_mode & S_IFMT) == S_IFREG;
        facts.directory = (buffer.st_mode & S_IFMT) == S_IFDIR;
        facts.size = cast(long) buffer.st_size;
        // Seconds and nanoseconds as std.file's statTimeToStdTime reads them; the druntime st_mtime accessor
        // is not @nogc, so the fields are read directly.
        long seconds, nanoseconds;
        static if (is(typeof(buffer.st_mtim.tv_nsec)))
        {
            seconds = buffer.st_mtim.tv_sec;
            nanoseconds = buffer.st_mtim.tv_nsec;
        }
        else static if (is(typeof(buffer.st_mtimespec.tv_nsec)))
        {
            seconds = buffer.st_mtimespec.tv_sec;
            nanoseconds = buffer.st_mtimespec.tv_nsec;
        }
        else
        {
            seconds = buffer.st_mtime;
            static if (is(typeof(buffer.st_mtimensec)))
                nanoseconds = buffer.st_mtimensec;
        }
        facts.modifiedTicks = seconds * 10_000_000 + nanoseconds / 100;
        return facts;
    }

    /// `pathz` (NUL-terminated) opened for reading; -1 with `error` set when it cannot be.
    // SAFETY: pathz is NUL-terminated (checked); open reads only the name.
    @trusted FileHandle openRead(scope const(char)[] pathz, out FileError error) nothrow @nogc
    {
        if (pathz.length == 0 || pathz[$ - 1] != '\0')
        {
            error = FileError.notFound;
            return -1;
        }
        int descriptor;
        do
            descriptor = open(&pathz[0], O_RDONLY | O_CLOEXEC);
        while (descriptor < 0 && errno == EINTR);
        if (descriptor < 0)
            error = mapError(errno);
        return descriptor;
    }

    /// Up to `buffer.length` bytes read from `file` into `buffer`: the count, 0 at the end, -1 on failure.
    // SAFETY: read writes at most buffer.length bytes into buffer, which the caller owns.
    @trusted ptrdiff_t readInto(FileHandle file, scope ubyte[] buffer) nothrow @nogc
    {
        if (file < 0 || buffer.length == 0)
            return -1;
        ptrdiff_t count;
        do
            count = read(file, &buffer[0], buffer.length);
        while (count < 0 && errno == EINTR);
        return count;
    }

    /// Close a descriptor `openRead` returned.
    // SAFETY: close takes the descriptor by value; a negative one is never passed.
    @trusted void closeFile(FileHandle file) nothrow @nogc
    {
        if (file >= 0)
            close(file);
    }

    /// The current directory written into `buffer` (no NUL): the length written, buffer.length + 1 when the
    /// buffer is too small, or 0 on any other failure.
    // SAFETY: getcwd writes at most buffer.length bytes, NUL included, into buffer; the NUL is found within it.
    @trusted size_t currentDirectoryInto(scope char[] buffer) nothrow @nogc
    {
        import core.stdc.errno : ERANGE;

        if (buffer.length == 0)
            return 0;
        if (getcwd(&buffer[0], buffer.length) is null)
            return errno == ERANGE ? buffer.length + 1 : 0;
        foreach (i, c; buffer)
            if (c == '\0')
                return i;
        return 0;
    }
}
else
    static assert(0, "flint.engine.aot.sys.files: unsupported platform");

version (Posix) unittest
{
    import std.file : remove, tempDir, write;

    // Positive: a regular file's facts and bytes, and a directory.
    const path = tempDir ~ "/flint-sys-files-test";
    write(path, "abc");
    scope (exit)
        remove(path);
    const file = statPath(path ~ '\0');
    assert(file.exists && file.regular && !file.directory && file.size == 3 && file.modifiedTicks > 0);
    const directory = statPath(tempDir ~ '\0');
    assert(directory.exists && directory.directory && !directory.regular);
    FileError error;
    auto handle = openRead(path ~ '\0', error);
    assert(handle >= 0 && error == FileError.none);
    ubyte[8] bytes;
    assert(readInto(handle, bytes[]) == 3 && bytes[0 .. 3] == "abc");
    assert(readInto(handle, bytes[]) == 0);
    closeFile(handle);
    char[4096] cwd;
    const length = currentDirectoryInto(cwd[]);
    assert(length > 0 && length < cwd.length && cwd[0] == '/');

    // Negative: missing paths, names without their NUL, a closed descriptor, a buffer too small for the directory.
    assert(!statPath(path ~ ".missing\0").exists);
    assert(!statPath(path).exists && !statPath("").exists);
    assert(openRead(path ~ ".missing\0", error) < 0 && error == FileError.notFound);
    assert(openRead(path, error) < 0 && error == FileError.notFound);
    assert(readInto(-1, bytes[]) == -1 && readInto(handle, bytes[0 .. 0]) == -1);
    char[1] tiny;
    assert(currentDirectoryInto(tiny[]) == 2 && currentDirectoryInto(tiny[0 .. 0]) == 0);
}
