// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Ported from spring-framework v7.1.0 spring-core/src/test/java/org/springframework/core/io/{ClassPathResourceTests,
ResourceTests}.java (Apache-2.0; modified by the Flint authors).

Skipped, with reasons:
- ClassPathResourceTests: withClassLoaderConstructor*, withClassLiteralConstructor* (5 tests),
  resourcesWithEquivalentAbsolutePaths* (3), convertsToAbsolutePathForClassRelativeAccess: class loaders and
  class-relative lookup do not exist in D (jvm-runtime). directoryNotReadable: jar: and file: URLs (jvm-platform).
- ResourceTests: resourceIsValid, resourceCreateRelative*, (parameterized over UrlResource and class files):
  ported below for the resource types Flint has. InputStreamResourceTests (3): InputStreamResource is deferred to
  Phase 2. getFilePath, readableChannelProvidesContent, urlAndUriAreNormalized* (2), sameResourceFromFilePathIsEqual,
  filenameIsExtractedFromFilePath (UrlResource), filenameIsExtractedFromURL, filenameContainingHashTag*, UrlResourceTests (11), shutdown: java.nio paths, channels,
  URLs and HTTP connections (jvm-platform). isReadableChecksExistsFirst, isReadableChecksCanReadAfterExists:
  override java.io.File methods through an anonymous subclass of a JDK class.
+/
module flint.core.io_resource_test;

import flint.core.io : ByteArrayResource, ClassPathResource, FileSystemResource, Resource;
import flint.java.io : File, FileNotFoundException;
import flint.java.lang : equals;
import flint.java.util : HashSet;

@safe:

private enum ABSOLUTE_PATH_TO_NONEXISTENT_RESOURCE = "org/springframework/core/io/nonexistent.xml";
private enum ABSOLUTE_PATH_TO_NONEXISTENT_RESOURCE_WITH_LEADING_SLASH = "/" ~ ABSOLUTE_PATH_TO_NONEXISTENT_RESOURCE;

unittest
{
    // equalsAndHashCode
    Resource resource1 = new ClassPathResource("org/springframework/core/io/Resource.class");
    Resource resource2 = new ClassPathResource("org/springframework/core/../core/io/./Resource.class");
    Resource resource3 = new ClassPathResource("org/springframework/core/").createRelative(
            "../core/io/./Resource.class");
    assert(resource2.equals(cast(Object) resource1) && resource3.equals(cast(Object) resource1));
    assert((cast(Object) resource2).toHash() == (cast(Object) resource1).toHash());
    assert((cast(Object) resource3).toHash() == (cast(Object) resource1).toHash());
    auto resources = new HashSet!Resource();
    resources.add(resource1);
    resources.add(resource2);
    assert(resources.size() == 1);
}

unittest
{
    // resourcesWithDifferentInputPathsAreEqual (the class-loader argument does not exist in D)
    auto resource1 = new ClassPathResource("org/springframework/core/io/Resource.class");
    auto resource2 = new ClassPathResource("org/springframework/core/../core/io/./Resource.class");
    assert(resource2 == resource1);
}

unittest
{
    // relativeResourcesAreEqual (ClassPathResourceTests)
    Resource resource = new ClassPathResource("dir/");
    Resource relative = resource.createRelative("subdir");
    assert(relative.equals(new ClassPathResource("dir/subdir")));
}

unittest
{
    // withStringConstructorRaisesExceptionForNonexistentResource
    bool threw;
    try
        new ClassPathResource(ABSOLUTE_PATH_TO_NONEXISTENT_RESOURCE).getInputStream();
    catch (FileNotFoundException e)
    {
        import std.string : indexOf;

        threw = e.getMessage().indexOf(ABSOLUTE_PATH_TO_NONEXISTENT_RESOURCE) >= 0;
    }
    assert(threw);
}

unittest
{
    // withStringConstructor (GetDescription)
    assert(new ClassPathResource(ABSOLUTE_PATH_TO_NONEXISTENT_RESOURCE)
            .getDescription() == "class path resource [" ~ ABSOLUTE_PATH_TO_NONEXISTENT_RESOURCE ~ "]");
}

unittest
{
    // withStringConstructorAndLeadingSlash (GetDescription)
    assert(new ClassPathResource(ABSOLUTE_PATH_TO_NONEXISTENT_RESOURCE_WITH_LEADING_SLASH)
            .getDescription() == "class path resource [" ~ ABSOLUTE_PATH_TO_NONEXISTENT_RESOURCE ~ "]");
}

unittest
{
    // dropsLeadingSlashForClassLoaderAccess
    assert(new ClassPathResource("/test.html").getPath() == "test.html");
    assert((cast(ClassPathResource) new ClassPathResource("").createRelative("/test.html")).getPath() == "test.html");
}

unittest
{
    // emptyFileReadable (the class path root is FLINT_CLASSPATH instead of a URLClassLoader)
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : environment;

    const root = buildPath(tempDir, "flint-core-io-test");
    mkdirRecurse(root);
    scope (exit)
        rmdirRecurse(root);
    write(buildPath(root, "empty.txt"), "");
    const previous = environment.get("FLINT_CLASSPATH", null);
    environment["FLINT_CLASSPATH"] = root;
    scope (exit)
    {
        if (previous is null)
            environment.remove("FLINT_CLASSPATH");
        else
            environment["FLINT_CLASSPATH"] = previous;
    }
    auto emptyFile = new ClassPathResource("empty.txt");
    assert(emptyFile.exists() && emptyFile.isReadable() && emptyFile.contentLength() == 0 && emptyFile.isFile());
}

unittest
{
    // hasContent (ByteArrayResourceTests)
    immutable(ubyte)[] testBytes = cast(immutable(ubyte)[]) "testString";
    Resource resource = new ByteArrayResource(testBytes);
    assert(resource.exists() && !resource.isOpen());
    assert(resource.getContentAsByteArray() == testBytes);
    assert(resource.getContentAsString() == "testString");
    assert(resource.getInputStream().readAllBytes() == testBytes);
    assert(new ByteArrayResource(testBytes).equals(cast(Object) resource));
}

unittest
{
    // isNotOpen (ByteArrayResourceTests)
    Resource resource = new ByteArrayResource(cast(immutable(ubyte)[]) "testString");
    assert(resource.exists() && !resource.isOpen());
}

unittest
{
    // hasDescription (ByteArrayResourceTests)
    import std.string : indexOf;

    Resource resource = new ByteArrayResource(cast(immutable(ubyte)[]) "testString", "my description");
    assert(resource.getDescription().indexOf("my description") >= 0);
}

private string tempResourceFile()
{
    import std.file : tempDir, write;
    import std.path : buildPath;

    const path = buildPath(tempDir, "flint-core-io-ResourceTests.class");
    write(path, "class bytes");
    return path;
}

unittest
{
    // sameResourceIsEqual
    const file = tempResourceFile();
    Resource resource = new FileSystemResource(file);
    assert(resource.equals(new FileSystemResource(file)));
}

unittest
{
    // sameResourceFromFileIsEqual
    auto file = new File(tempResourceFile());
    Resource resource = new FileSystemResource(file);
    assert(resource.equals(new FileSystemResource(file)));
}

unittest
{
    // sameResourceFromDotPathIsEqual
    Resource resource = new FileSystemResource("core/io/ResourceTests.class");
    assert((new FileSystemResource("core/../core/io/./ResourceTests.class")).equals(cast(Object) resource));
}

unittest
{
    // relativeResourcesAreEqual (FileSystemResourceTests)
    Resource resource = new FileSystemResource("dir/");
    Resource relative = resource.createRelative("subdir");
    assert(relative.equals(new FileSystemResource("dir/subdir")));
}

unittest
{
    // resourceIsValid, resourceCreateRelative and resourceCreateRelativeUnknown, for FileSystemResource
    const path = tempResourceFile();
    Resource resource = new FileSystemResource(path);
    assert(resource.getFilename() == "flint-core-io-ResourceTests.class" && resource.exists());
    assert(resource.contentLength() == "class bytes".length && resource.lastModified() > 0);
    auto relative = resource.createRelative("ClassPathResource.class");
    assert(relative.getFilename() == "ClassPathResource.class" && !relative.exists());
    auto unknown = resource.createRelative("X.class");
    assert(!unknown.exists());
    bool threw;
    try
        unknown.contentLength();
    catch (FileNotFoundException)
        threw = true;
    assert(threw);
}

unittest
{
    // missingResourceIsNotReadable, hasContentLength (ClassPathResource variants)
    assert(!new ClassPathResource("org/springframework/core/io/missing").isReadable());
    auto bytes = new ByteArrayResource(cast(immutable(ubyte)[]) "12345");
    assert(bytes.contentLength() == 5);
}
