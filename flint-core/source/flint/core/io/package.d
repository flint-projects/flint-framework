// Ported from spring-framework v7.1.0: spring-core/src/main/java/org/springframework/core/io
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/*
 * Copyright 2002-present the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by the Flint authors: ported from spring-framework v7.1.0,
 * spring-core/src/main/java/org/springframework/core/io/{InputStreamSource,Resource,AbstractResource,
 * ClassPathResource,FileSystemResource,ByteArrayResource,DescriptiveResource,ResourceLoader,DefaultResourceLoader,
 * ProtocolResolver}.java. The class path is the application's embedded resources, then the class path roots on
 * the file system (see ClassPathResource); URL, URI, NIO path and channel methods are excluded (jvm-platform).
 */

/++
`org.springframework.core.io`: the resource abstraction.

$(UL
    $(LI A class path in Flint is the set of resources the application embeds at build time (installed with
        `installEmbeddedResources`, which `flint build` generates from `src/main/resources`), followed by the
        directories in the `FLINT_CLASSPATH` environment variable (colon-separated; default `resources` and
        `src/main/resources` under the working directory).)
    $(LI `getURL`, `getURI`, `getFilePath` and `readableChannel` are not offered: Flint has no `java.net` or NIO.)
    $(LI `getContentAsString` decodes UTF-8 (Java's `Charset` parameter is dropped).)
)
+/
module flint.core.io;

import core.atomic : atomicLoad, atomicStore;
import flint.java.io : ByteArrayInputStream, File, FileInputStream, FileNotFoundException, IOException, InputStream;
import flint.java.lang : IllegalArgumentException;
import flint.util : Assert, StringUtils;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Embedded class path resources

/// Returns the embedded bytes of a class path resource, or null when the application embeds none at `path`.
alias EmbeddedResourceProvider = immutable(ubyte)[]function(string path) @safe nothrow;

private shared EmbeddedResourceProvider embedded;

/// Install the application's embedded resources. Called once, from a generated module constructor.
void installEmbeddedResources(EmbeddedResourceProvider provider) nothrow @nogc
{
    atomicStore(embedded, provider);
}

/// The installed provider; null when the application embeds no resources.
EmbeddedResourceProvider installedEmbeddedResources() nothrow @nogc
{
    return atomicLoad(embedded);
}

/// The class path roots on the file system: `FLINT_CLASSPATH`, else `resources` and `src/main/resources`.
string[] classPathRoots()
{
    import flint.engine.aot.host : environmentVariable;

    const configured = environmentVariable("FLINT_CLASSPATH", null);
    if (configured is null)
        return ["resources", "src/main/resources"];
    string[] roots;
    size_t start;
    foreach (i, c; configured)
    {
        if (c == ':')
        {
            if (i > start)
                roots ~= configured[start .. i];
            start = i + 1;
        }
    }
    if (start < configured.length)
        roots ~= configured[start .. $];
    return roots;
}

// ---------------------------------------------------------------------------------------------------------------
// Resource

/// Simple interface for objects that are sources for an `InputStream`.
interface InputStreamSource
{
    /// A fresh stream over the content. Throws `IOException` when it cannot be opened.
    InputStream getInputStream();
}

/++
Interface for a resource descriptor that abstracts from the actual type of underlying resource, such as a file or
class path resource.
+/
interface Resource : InputStreamSource
{
    /// Whether the resource exists.
    bool exists();
    /// Whether the content can be read.
    bool isReadable();
    /// Whether this represents an open stream that can be read only once.
    bool isOpen();
    /// Whether this is a file in the file system.
    bool isFile();
    /// The resource as a `File`. Throws `FileNotFoundException` when it is not a file.
    File getFile();
    /// The content length in bytes.
    long contentLength();
    /// The last-modified time, in milliseconds since the epoch.
    long lastModified();
    /// A resource relative to this one.
    Resource createRelative(string relativePath);
    /// The file name, or null.
    string getFilename();
    /// A description for error output, such as `class path resource [x]`.
    string getDescription();
    /// The whole content.
    ubyte[] getContentAsByteArray();
    /// The whole content, decoded as UTF-8.
    string getContentAsString();
}

/// Convenience base class for `Resource` implementations.
abstract class AbstractResource : Resource
{
    /// Whether the file exists, else whether a stream can be opened.
    bool exists()
    {
        if (isFile())
        {
            try
                return getFile().exists();
            catch (IOException)
            {
            }
        }
        try
        {
            getInputStream().close();
            return true;
        }
        catch (Exception)
            return false;
    }

    /// `exists()`.
    bool isReadable()
    {
        return exists();
    }

    /// `false`.
    bool isOpen()
    {
        return false;
    }

    /// `false`.
    bool isFile()
    {
        return false;
    }

    /// Throws `FileNotFoundException`: not a file.
    File getFile()
    {
        throw new FileNotFoundException(getDescription() ~ " cannot be resolved to absolute file path");
    }

    /// The length, by reading the stream.
    long contentLength()
    {
        auto stream = getInputStream();
        scope (exit)
            stream.close();
        long size;
        ubyte[256] buffer;
        for (int read = stream.read(buffer[]); read != -1; read = stream.read(buffer[]))
            size += read;
        return size;
    }

    /// The file's last-modified time. Throws `FileNotFoundException` when it is not in the file system.
    long lastModified()
    {
        auto file = getFileForLastModifiedCheck();
        const modified = file.lastModified();
        if (modified == 0 && !file.exists())
            throw new FileNotFoundException(getDescription()
                    ~ " cannot be resolved in the file system for checking its last-modified timestamp");
        return modified;
    }

    /// The file whose timestamp `lastModified` reads.
    protected File getFileForLastModifiedCheck()
    {
        return getFile();
    }

    /// Throws `FileNotFoundException`: no relative resources.
    Resource createRelative(string)
    {
        throw new FileNotFoundException("Cannot create a relative resource for " ~ getDescription());
    }

    /// null.
    string getFilename()
    {
        return null;
    }

    /// The stream's bytes.
    ubyte[] getContentAsByteArray()
    {
        auto stream = getInputStream();
        scope (exit)
            stream.close();
        return stream.readAllBytes();
    }

    /// The content as UTF-8 text. Throws `IOException` when it is not valid UTF-8.
    string getContentAsString()
    {
        import flint.engine.aot.text : isValidUtf8;

        auto text = cast(string) getContentAsByteArray().idup;
        if (!isValidUtf8(text))
            throw new IOException("Malformed UTF-8 input in " ~ getDescription());
        return text;
    }

    abstract InputStream getInputStream();
    abstract string getDescription();

    /// Equal descriptions.
    override bool opEquals(Object other)
    {
        auto that = cast(Resource) other;
        return that !is null && (that is this || that.getDescription() == getDescription());
    }

    /// Java's `equals`: `opEquals`.
    bool equals(Object other)
    {
        return opEquals(other);
    }

    /// Java's `hashCode`: the hash of the description.
    int hashCode()
    {
        return cast(int) toHash();
    }

    /// Hash of the description.
    override size_t toHash() nothrow
    {
        try
            return hashOf(getDescription());
        catch (Exception)
            return 0;
    }

    /// The description.
    override string toString()
    {
        return getDescription();
    }
}

/++
A `Resource` on the class path: an embedded resource when the application embeds one at the path, else the first
class path root holding the file.
+/
class ClassPathResource : AbstractResource
{
    private string path;
    private string absolutePath;

    /// A class path resource at `path`; a leading `/` is ignored, as with a class loader.
    this(string path)
    {
        Assert.notNull(path, "Path must not be null");
        auto pathToUse = StringUtils.cleanPath(path);
        if (pathToUse.length && pathToUse[0] == '/')
            pathToUse = pathToUse[1 .. $];
        this.path = pathToUse;
        absolutePath = pathToUse;
    }

    /// The path within the class path.
    final string getPath() const pure nothrow @nogc
    {
        return path;
    }

    /// The bytes embedded at this path, or null.
    private immutable(ubyte)[] embeddedBytes()
    {
        auto provider = installedEmbeddedResources();
        return provider is null ? null : provider(absolutePath);
    }

    /// The first class path root holding this path as a file, or null.
    private File resolveFile()
    {
        foreach (root; classPathRoots())
        {
            auto file = new File(root, absolutePath);
            if (file.isFile())
                return file;
        }
        return null;
    }

    /// Whether the resource is embedded or found on a class path root.
    override bool exists()
    {
        return embeddedBytes() !is null || resolveFile() !is null;
    }

    /// Whether it exists and is not a directory.
    override bool isReadable()
    {
        return exists();
    }

    /// Whether it resolves to a file on a class path root (embedded resources are not files).
    override bool isFile()
    {
        return embeddedBytes() is null && resolveFile() !is null;
    }

    /// The file on a class path root. Throws `FileNotFoundException` for an embedded or missing resource.
    override File getFile()
    {
        if (embeddedBytes() is null)
            if (auto file = resolveFile())
                return file;
        throw new FileNotFoundException(getDescription() ~ " cannot be resolved to absolute file path "
                ~ "because it does not reside in the file system");
    }

    /// A stream over the content. Throws `FileNotFoundException` when it does not exist.
    override InputStream getInputStream()
    {
        if (auto bytes = embeddedBytes())
            return new ByteArrayInputStream(bytes);
        if (auto file = resolveFile())
            return new FileInputStream(file);
        throw new FileNotFoundException(getDescription() ~ " cannot be opened because it does not exist");
    }

    /// The length of the embedded bytes or the file.
    override long contentLength()
    {
        if (auto bytes = embeddedBytes())
            return cast(long) bytes.length;
        return super.contentLength();
    }

    /// A class path resource at `relativePath` from this one.
    override Resource createRelative(string relativePath)
    {
        return new ClassPathResource(StringUtils.applyRelativePath(path, relativePath));
    }

    /// The last path component.
    override string getFilename()
    {
        return StringUtils.getFilename(absolutePath);
    }

    /// `class path resource [path]`.
    override string getDescription()
    {
        return "class path resource [" ~ absolutePath ~ "]";
    }

    /// Equal absolute paths.
    override bool opEquals(Object other)
    {
        auto that = cast(ClassPathResource) other;
        return that !is null && that.absolutePath == absolutePath;
    }

    /// Hash of the absolute path.
    override size_t toHash() nothrow
    {
        return hashOf(absolutePath);
    }
}

/// A `Resource` for a file system path.
class FileSystemResource : AbstractResource
{
    private string path;
    private File file;

    /// The resource at `path`.
    this(string path)
    {
        Assert.notNull(path, "Path must not be null");
        this.path = StringUtils.cleanPath(path);
        file = new File(path);
    }

    /// The resource for `file`.
    this(File file)
    {
        Assert.notNull(file, "File must not be null");
        path = StringUtils.cleanPath(file.getPath());
        this.file = file;
    }

    /// The path.
    final string getPath() const pure nothrow @nogc
    {
        return path;
    }

    /// Whether the file exists.
    override bool exists()
    {
        return file.exists();
    }

    /// Whether it is a readable regular file.
    override bool isReadable()
    {
        return file.canRead() && !file.isDirectory();
    }

    /// `true`.
    override bool isFile()
    {
        return true;
    }

    /// The file.
    override File getFile()
    {
        return file;
    }

    /// A stream over the file. Throws `FileNotFoundException`.
    override InputStream getInputStream()
    {
        return new FileInputStream(file);
    }

    /// The file length.
    override long contentLength()
    {
        if (!file.exists())
            throw new FileNotFoundException(getDescription()
                    ~ " cannot be resolved in the file system " ~ "for checking its content length");
        return file.length();
    }

    /// A file resource at `relativePath` from this one.
    override Resource createRelative(string relativePath)
    {
        return new FileSystemResource(StringUtils.applyRelativePath(path, relativePath));
    }

    /// The file name.
    override string getFilename()
    {
        return file.getName();
    }

    /// `file [absolute path]`.
    override string getDescription()
    {
        return "file [" ~ file.getAbsolutePath() ~ "]";
    }

    /// Equal paths.
    override bool opEquals(Object other)
    {
        auto that = cast(FileSystemResource) other;
        return that !is null && that.path == path;
    }

    /// Hash of the path.
    override size_t toHash() nothrow
    {
        return hashOf(path);
    }
}

/// A `Resource` over a byte array.
class ByteArrayResource : AbstractResource
{
    private immutable(ubyte)[] byteArray;
    private string description;

    /// A resource over `byteArray`, described by `description`.
    this(immutable(ubyte)[] byteArray, string description = null)
    {
        Assert.notNull(byteArray, "Byte array must not be null");
        this.byteArray = byteArray;
        this.description = description !is null ? description : "";
    }

    /// The bytes.
    final immutable(ubyte)[] getByteArray() const pure nothrow @nogc
    {
        return byteArray;
    }

    /// `true`.
    override bool exists()
    {
        return true;
    }

    /// The array length.
    override long contentLength()
    {
        return cast(long) byteArray.length;
    }

    /// A stream over the bytes.
    override InputStream getInputStream()
    {
        return new ByteArrayInputStream(byteArray);
    }

    /// A copy of the bytes.
    override ubyte[] getContentAsByteArray()
    {
        return byteArray.dup;
    }

    /// `Byte array resource [description]`.
    override string getDescription()
    {
        return "Byte array resource [" ~ description ~ "]";
    }

    /// Equal bytes.
    override bool opEquals(Object other)
    {
        auto that = cast(ByteArrayResource) other;
        return that !is null && that.byteArray == byteArray;
    }

    /// Hash of the bytes.
    override size_t toHash() nothrow
    {
        return hashOf(byteArray);
    }
}

/// A placeholder `Resource` that holds a description and no content.
class DescriptiveResource : AbstractResource
{
    private string description;

    /// A resource described by `description`.
    this(string description)
    {
        this.description = description !is null ? description : "";
    }

    /// `false`.
    override bool exists()
    {
        return false;
    }

    /// `false`.
    override bool isReadable()
    {
        return false;
    }

    /// Throws `FileNotFoundException`.
    override InputStream getInputStream()
    {
        throw new FileNotFoundException(
                getDescription() ~ " cannot be opened because it does not point to a readable resource");
    }

    /// The description.
    override string getDescription()
    {
        return description;
    }
}

/// Strategy interface for loading resources by location.
interface ResourceLoader
{
    /// The pseudo-URL prefix for class path locations: `classpath:`.
    enum CLASSPATH_URL_PREFIX = "classpath:";

    /// The resource at `location`: `classpath:x`, a file path, or a relative path. The resource may not exist.
    Resource getResource(string location);
}

/// Resolution strategy for protocol-specific resource handles, consulted by `DefaultResourceLoader`.
interface ProtocolResolver
{
    /// The resource for `location`, or null when this resolver does not handle it.
    Resource resolve(string location, ResourceLoader resourceLoader);
}

/++
The default `ResourceLoader`: `classpath:` locations are class path resources, other locations go through the
protocol resolvers, then absolute paths through `getResourceByPath`, and everything else is a class path resource.
+/
class DefaultResourceLoader : ResourceLoader
{
    private ProtocolResolver[] protocolResolvers;

    /// Register a protocol resolver, consulted before the standard resolution.
    void addProtocolResolver(ProtocolResolver resolver)
    {
        Assert.notNull(resolver, "ProtocolResolver must not be null");
        protocolResolvers ~= resolver;
    }

    /// The registered protocol resolvers.
    ProtocolResolver[] getProtocolResolvers()
    {
        return protocolResolvers.dup;
    }

    /// The resource at `location`.
    Resource getResource(string location)
    {
        Assert.notNull(location, "Location must not be null");
        foreach (resolver; protocolResolvers)
            if (auto resource = resolver.resolve(location, this))
                return resource;
        if (location.length && location[0] == '/')
            return getResourceByPath(location);
        if (StringUtils.startsWithIgnoreCase(location, CLASSPATH_URL_PREFIX))
            return new ClassPathResource(location[CLASSPATH_URL_PREFIX.length .. $]);
        enum filePrefix = "file:";
        if (location.length > filePrefix.length && location[0 .. filePrefix.length] == filePrefix)
            return new FileSystemResource(location[filePrefix.length .. $]);
        return getResourceByPath(location);
    }

    /// The resource for a path: a class path resource by default.
    protected Resource getResourceByPath(string path)
    {
        return new ClassPathResource(path);
    }
}
